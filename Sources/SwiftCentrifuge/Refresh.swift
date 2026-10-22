import Foundation

// The explicit token refresh, refresh(token:), and the state it shares with the timer refreshes of
// Client.swift (table T4 of the parity spec). The calls run one at a time, in the order they were
// made. Everything here runs on syncQueue.

/// The most refresh() calls in progress at once, the one that runs included. Beyond it a call fails with
/// `replyError(code: 16)`.
internal let maxRefreshCalls: Int = 32

/// The result of an accepted refresh: the expiry the server reports, and the identity it confirms.
public struct CentrifugeRefreshResult {
    /// Whether the server reports an expiry of the connection token.
    public let expires: Bool
    /// Seconds until the connection token expires, when `expires` is set.
    public let ttl: UInt32
    /// The user the server confirms for the connection.
    public let user: String
    /// The auth class the server confirms for the connection.
    public let authClass: String


    public init(expires: Bool, ttl: UInt32, user: String, authClass: String) {
        self.expires = expires
        self.ttl = ttl
        self.user = user
        self.authClass = authClass
    }
}


/// One refresh() call from its admission until it settles. The call is the one running when it is first in
/// `RefreshState.calls`.
internal final class RefreshCall {
    // The token of the call, nil when the token comes from the token getter.
    internal let token: String?
    // The completions of this call and of the calls that shared it.
    internal var completions: [(Result<CentrifugeRefreshResult, Error>) -> Void]
    // Whether the call put its token on the client before the server accepted it. Then the previous token is
    // put back when the server refuses the call, or when the client is disconnected for good.
    internal var holdsToken: Bool = false
    // The token the client had before the call put its own on it.
    internal var previousToken: String?
    // The token of the command that waits for the connection, nil when no command waits.
    internal var waitingToken: String?


    internal init(token: String?, completion: @escaping (Result<CentrifugeRefreshResult, Error>) -> Void) {
        self.token = token
        self.completions = [completion]
    }
}


/// The refresh state of a client: the explicit calls in progress, and the marks the timer refreshes read.
/// Touched only on syncQueue.
internal final class RefreshState {
    // The explicit calls in progress, the running one first. At most `maxRefreshCalls`.
    internal var calls: [RefreshCall] = []
    // Whether the first call of `calls` has been started.
    internal var running: Bool = false
    // Moves on with each refresh() call admitted. A token fetch of a timer refresh that started before a move
    // is superseded: its token is not sent.
    internal var generation: UInt64 = 0
    // Moves on with each refresh() call admitted that brings its own token. A token fetch of an explicit call
    // that started before a move is superseded by that call.
    internal var tokenCallGeneration: UInt64 = 0
    // Whether a token fetch of a timer refresh is in flight.
    internal var timerFetchInFlight: Bool = false
    // Set when a refresh() call was admitted while a timer fetch was in flight. The refusal of that call then
    // arms the retry of the timer refresh.
    internal var timerSuperseded: Bool = false
    // The consecutive failed timer refreshes of the connection: the step of the next retry.
    internal var failures: Int = 0
    // The token the server refused as expired, for the stopOnRefusedToken rule.
    internal var refusedToken: String?
}


public extension CentrifugeClient {
    /// Refreshes the connection token now, instead of at the expiry the server reports. A call with a token
    /// sends that token; a call without one fetches it from `tokenGetter`. The completion is called once, on the
    /// client's queue. It gets the server's answer: an error reply is passed through unchanged, and no retry
    /// follows it. An accepted token becomes the token of the connection; a refusal keeps the previous one.
    ///
    /// A call made while disconnected waits for the next connection, and its token is the one that connection
    /// carries. Calls run one at a time, in order. A call with the same token as the last call, or without a
    /// token, shares that call's answer. At most 32 calls are in progress; a call beyond that fails with
    /// `replyError(code: 16)`.
    ///
    /// - Parameters:
    ///   - token: the token to send. Nil fetches one from `tokenGetter`; without a getter the call fails with
    ///   `configurationError`. An empty token fails with `configurationError` as well.
    ///   - completion: called once with the result, on the client's queue.
    func refresh(token: String? = nil, completion: @escaping (Result<CentrifugeRefreshResult, Error>) -> Void) {
        self.syncQueue.async { [weak self] in
            guard let strongSelf: CentrifugeClient = self else {
                return
            }
            strongSelf.admitRefresh(token: token, completion: completion)
        }
    }
}


internal extension CentrifugeClient {
    /// Admits a refresh() call on syncQueue. It is refused at once when it cannot run, shares the last call
    /// when that call has the same token or none, and otherwise waits behind the calls in progress.
    func admitRefresh(token: String?, completion: @escaping (Result<CentrifugeRefreshResult, Error>) -> Void) {
        assertIsOnQueue(syncQueue)
        if token == nil && config.tokenGetter == nil {
            completion(.failure(CentrifugeError.configurationError(message: "refresh needs a token: pass one to refresh() or set getToken")))
            return
        }
        if let last: RefreshCall = refreshState.calls.last, token == nil || token == last.token {
            last.completions.append(completion)
            return
        }
        if refreshState.calls.count >= maxRefreshCalls {
            completion(.failure(CentrifugeError.replyError(code: rpcCodeLimitExceeded, message: "limit exceeded", temporary: false)))
            return
        }
        let call: RefreshCall = RefreshCall(token: token, completion: completion)
        refreshState.calls.append(call)
        refreshState.generation += 1
        if token != nil {
            refreshState.tokenCallGeneration += 1
        }
        if refreshState.timerFetchInFlight {
            refreshState.timerSuperseded = true
        }
        if !refreshState.running {
            refreshState.running = true
            runFirstRefreshCall()
        }
    }


    /// Starts the first call in progress. A call without a token fetches one first.
    func runFirstRefreshCall() {
        guard let call: RefreshCall = refreshState.calls.first else {
            refreshState.running = false
            return
        }
        guard let token: String = call.token else {
            fetchRefreshToken(for: call)
            return
        }
        sendRefreshCall(call, token: token)
    }


    /// Fetches the token of a call without one from the getter. A refresh() call with its own token admitted
    /// meanwhile supersedes the fetch: the fetched token is not sent, and the call ends with the identity the
    /// connection has.
    func fetchRefreshToken(for call: RefreshCall) {
        let tokenCalls: UInt64 = refreshState.tokenCallGeneration
        getConnectionToken(completion: { [weak self] result in
            guard let strongSelf: CentrifugeClient = self, strongSelf.refreshState.calls.first === call else {
                return
            }
            switch result {
            case .success(let fetched):
                if strongSelf.refreshState.tokenCallGeneration != tokenCalls {
                    strongSelf.finishRefreshCall(call, outcome: .success(strongSelf.currentRefreshResult()))
                    return
                }
                strongSelf.sendRefreshCall(call, token: fetched)
            case .failure(let error):
                strongSelf.finishRefreshCall(call, outcome: .failure(error))
            }
        })
    }


    /// Sends the refresh command of a call, or waits for the connection to send it. A call that waits puts its token
    /// on the client now, so the next connect carries it; the command follows that connect.
    func sendRefreshCall(_ call: RefreshCall, token: String) {
        if token.isEmpty {
            finishRefreshCall(call, outcome: .failure(CentrifugeError.configurationError(message: "refresh token is empty")))
            return
        }
        guard self.state == .connected else {
            if !call.holdsToken {
                call.previousToken = self.token
                call.holdsToken = true
                self.token = token
            }
            call.waitingToken = token
            return
        }
        call.waitingToken = nil
        sendRefresh(token: token, completion: { [weak self] result, error in
            guard let strongSelf: CentrifugeClient = self, strongSelf.refreshState.calls.first === call else {
                return
            }
            let superseded: Bool = strongSelf.refreshState.timerSuperseded
            strongSelf.refreshState.timerSuperseded = false
            if let err = error {
                if isServerRefusal(err) {
                    if call.holdsToken && strongSelf.token == token {
                        strongSelf.token = call.previousToken
                    }
                    call.holdsToken = false
                    if superseded {
                        strongSelf.scheduleTimerRefreshRetry()
                    }
                }
                strongSelf.finishRefreshCall(call, outcome: .failure(err))
                return
            }
            guard let res: Centrifugal_Centrifuge_Protocol_RefreshResult = result else {
                strongSelf.finishRefreshCall(call, outcome: .failure(CentrifugeError.connectionClosed))
                return
            }
            call.holdsToken = false
            strongSelf.token = token
            strongSelf.refreshState.failures = 0
            strongSelf.refreshState.refusedToken = nil
            strongSelf.acceptRefreshReply(res)
            if !res.expires {
                strongSelf.stopConnectionRefresh()
            }
            strongSelf.finishRefreshCall(call, outcome: .success(CentrifugeRefreshResult(expires: res.expires, ttl: res.ttl, user: res.user, authClass: res.authClass)))
        })
    }


    /// Settles the first call with the outcome, then starts the next one. The completions run inline, so a
    /// completion may make another call; that call starts only when no call is running.
    func finishRefreshCall(_ call: RefreshCall, outcome: Result<CentrifugeRefreshResult, Error>) {
        guard refreshState.calls.first === call else {
            return
        }
        refreshState.calls.removeFirst()
        refreshState.running = false
        for completion in call.completions {
            completion(outcome)
        }
        if !refreshState.running, !refreshState.calls.isEmpty {
            refreshState.running = true
            runFirstRefreshCall()
        }
    }


    /// Called once the connection is confirmed. The failure count of the timer refreshes restarts, and a call that
    /// waits for the connection sends its command.
    func refreshConnected() {
        refreshState.failures = 0
        guard let call: RefreshCall = refreshState.calls.first, let token: String = call.waitingToken else {
            return
        }
        sendRefreshCall(call, token: token)
    }


    /// Called once the connection is lost. A reconnect keeps the calls waiting for the next connection. A disconnect
    /// for good fails them, and puts back the previous token of each call that put its own on the client.
    func refreshDisconnected(terminal: Bool) {
        guard terminal else {
            return
        }
        let pending: [RefreshCall] = refreshState.calls
        refreshState.calls.removeAll()
        refreshState.running = false
        for call in pending {
            if call.holdsToken && self.token == call.token {
                self.token = call.previousToken
            }
            call.holdsToken = false
            call.waitingToken = nil
            for completion in call.completions {
                completion(.failure(CentrifugeError.clientDisconnected))
            }
        }
    }


    /// Applies an accepted refresh reply to the connection: the identity, and the timer from the new expiry. The
    /// caller has set the token and the failure count.
    func acceptRefreshReply(_ res: Centrifugal_Centrifuge_Protocol_RefreshResult) {
        if identity.applyRefresh(user: res.user, authClass: res.authClass) {
            delegate?.onAuth(self, CentrifugeAuthEvent(user: identity.user, authClass: identity.authClass))
        }
        if res.expires {
            startConnectionRefresh(after: Double(res.ttl))
        }
    }


    /// Arms the retry of a failed timer refresh, after the delay of the failure count. The count moves on.
    func scheduleTimerRefreshRetry() {
        let delay: TimeInterval = refreshRetryDelay(step: refreshState.failures, tokenRetryCap: config.tokenRetryCap, random: random)
        refreshState.failures += 1
        startConnectionRefresh(after: delay)
    }


    /// The result that a call without a token gets when a refresh() call superseded its fetch: the identity the
    /// connection has, and no expiry.
    func currentRefreshResult() -> CentrifugeRefreshResult {
        return CentrifugeRefreshResult(expires: false, ttl: 0, user: identity.user, authClass: identity.authClass)
    }
}


/// Whether an error is a server error reply, which is a refusal of the call.
private func isServerRefusal(_ error: Error) -> Bool {
    guard let centrifugeError: CentrifugeError = error as? CentrifugeError else {
        return false
    }
    if case .replyError = centrifugeError {
        return true
    }
    return false
}
