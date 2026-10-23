import Foundation

// The explicit token refresh, refresh(token:), and the state it shares with the timer refreshes of
// Client.swift. The calls run one at a time, in the order they were made. Everything here runs on syncQueue.

/// The most refresh() calls in progress at once, the one that runs included. Beyond it a call fails with
/// `replyError(code: 16)`.
internal let maxRefreshCalls: Int = 32

/// The completion of one refresh() call.
internal typealias RefreshCompletion = (Result<CentrifugeRefreshResult, Error>) -> Void


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


    internal init(expires: Bool, ttl: UInt32, user: String, authClass: String) {
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
    internal var completions: [RefreshCompletion]
    // Whether the call put its token on the client before the server accepted it. Then the previous token is
    // put back when the server refuses the call, or when the client is disconnected for good.
    internal var holdsToken: Bool = false
    // The token the client had before the call put its own on it.
    internal var previousToken: String?
    // The token the call put on the client while `holdsToken` is set. It is nil for a call without a token until
    // the getter has given one.
    internal var heldToken: String?
    // The token of the command that waits for the connection, nil when no command waits.
    internal var waitingToken: String?
    // Whether the call was admitted while a timer token fetch was in flight. Its failure then arms the retry of
    // that timer refresh, which the fetch no longer does.
    internal var supersedesTimer: Bool = false
    // Whether a call without a token waits for the connection before its token exchange starts (token exchange only).
    internal var awaitsConnection: Bool = false


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
    // Whether a token fetch of a timer refresh is in flight.
    internal var timerFetchInFlight: Bool = false
    // Whether a refresh command is on the wire, of either kind: a refresh() call or a timer refresh. Refresh
    // commands go out one at a time, and rpc calls wait while one is in flight (contract 4.3). Cleared by the
    // command's completion, which the transport loss fails too.
    internal var commandInFlight: Bool = false
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
        // A call without a token fetches one from the token getter, or exchanges the stored refresh token.
        if token == nil && config.tokenGetter == nil && config.tokenExchange == nil {
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
        call.supersedesTimer = refreshState.timerFetchInFlight
        refreshState.calls.append(call)
        refreshState.generation += 1
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
            // A token exchange renews over the connection, so a call without a token waits for the connection, as a
            // call with a token-getter fetch does (the fetch is sent on the next connect).
            if self.state != .connected && self.config.tokenExchange != nil {
                call.awaitsConnection = true
                return
            }
            fetchRefreshToken(for: call)
            return
        }
        sendRefreshCall(call, token: token)
    }


    /// Fetches the token of a call without one from the getter. The fetched token is sent, as any token of a
    /// call: a call admitted meanwhile waits behind this one.
    func fetchRefreshToken(for call: RefreshCall) {
        getConnectionToken(completion: { [weak self] result in
            guard let strongSelf: CentrifugeClient = self, strongSelf.refreshState.calls.first === call else {
                return
            }
            switch result {
            case .success(let fetched):
                strongSelf.sendRefreshCall(call, token: fetched)
            case .failure(let error):
                strongSelf.finishRefreshCall(call, outcome: .failure(error))
            }
        })
    }


    /// Whether a refresh() call is in progress or a refresh command is in flight. rpc calls wait meanwhile.
    var refreshBusy: Bool {
        return !refreshState.calls.isEmpty || refreshState.commandInFlight
    }


    /// Sends a refresh command of either kind and marks it in flight until its completion. Every refresh command goes
    /// through here, so two of them never overlap on the wire.
    func sendRefreshCommand(token: String, completion: @escaping (Centrifugal_Centrifuge_Protocol_RefreshResult?, Error?) -> ()) {
        refreshState.commandInFlight = true
        sendRefresh(token: token, completion: { [weak self] result, error in
            guard let strongSelf: CentrifugeClient = self else {
                return
            }
            strongSelf.refreshState.commandInFlight = false
            completion(result, error)
            strongSelf.refreshIdleChanged()
        })
    }


    /// Runs after a refresh command settles or a call finishes. A waiting call sends its command now, when the
    /// connection is up and no command is in flight; then the rpc calls that waited for the refresh state go out.
    func refreshIdleChanged() {
        if let call: RefreshCall = refreshState.calls.first, !refreshState.commandInFlight, self.state == .connected,
           let token: String = call.waitingToken {
            sendRefreshCall(call, token: token)
        }
        if !refreshBusy {
            rpcTracker.onRefreshIdle()
        }
    }


    /// Sends the refresh command of a call, or waits for the connection to send it. A call that waits puts its token
    /// on the client now, so the next connect carries it; the command follows that connect, or the settled command in
    /// flight (refreshIdleChanged).
    func sendRefreshCall(_ call: RefreshCall, token: String) {
        if token.isEmpty {
            finishRefreshCall(call, outcome: .failure(CentrifugeError.configurationError(message: "refresh token is empty")))
            return
        }
        guard self.state == .connected, !refreshState.commandInFlight else {
            if !call.holdsToken {
                call.previousToken = self.token
                call.holdsToken = true
                call.heldToken = token
                self.token = token
            }
            call.waitingToken = token
            return
        }
        call.waitingToken = nil
        sendRefreshCommand(token: token, completion: { [weak self] result, error in
            guard let strongSelf: CentrifugeClient = self, strongSelf.refreshState.calls.first === call else {
                return
            }
            if let err = error {
                // A refusal puts back the previous token, when this call had put its own on the client.
                if isServerRefusal(err) && call.holdsToken && strongSelf.token == call.heldToken {
                    strongSelf.token = call.previousToken
                }
                call.holdsToken = false
                strongSelf.finishRefreshCall(call, outcome: .failure(err))
                return
            }
            guard let res: Centrifugal_Centrifuge_Protocol_RefreshResult = result else {
                strongSelf.finishRefreshCall(call, outcome: .failure(CentrifugeError.connectionClosed))
                return
            }
            call.holdsToken = false
            strongSelf.token = token
            strongSelf.acceptRefreshReply(res)
            strongSelf.finishRefreshCall(call, outcome: .success(CentrifugeRefreshResult(expires: res.expires, ttl: res.ttl, user: res.user, authClass: res.authClass)))
        })
    }


    /// Settles the first call with the outcome, then starts the next one. A call that superseded a timer fetch and
    /// fails while the connection is up arms the retry of the timer refresh: the fetch will not arm it. The completions
    /// run inline, so a completion may make another call; that call starts only when no call is running.
    func finishRefreshCall(_ call: RefreshCall, outcome: Result<CentrifugeRefreshResult, Error>) {
        guard refreshState.calls.first === call else {
            return
        }
        refreshState.calls.removeFirst()
        refreshState.running = false
        if call.supersedesTimer, self.state == .connected, case .failure(let error) = outcome, rearmsTimerAfter(error) {
            scheduleTimerRefreshRetry()
        }
        for completion: RefreshCompletion in call.completions {
            completion(outcome)
        }
        if !refreshState.running, !refreshState.calls.isEmpty {
            refreshState.running = true
            runFirstRefreshCall()
        }
        refreshIdleChanged()
    }


    /// Called once the connection is confirmed. The failure count of the timer refreshes restarts, and a call that
    /// waits for the connection sends its command.
    func refreshConnected() {
        refreshState.failures = 0
        guard let call: RefreshCall = refreshState.calls.first else {
            return
        }
        if call.awaitsConnection {
            call.awaitsConnection = false
            fetchRefreshToken(for: call)
            return
        }
        guard let token: String = call.waitingToken else {
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
        for call: RefreshCall in pending {
            if call.holdsToken && self.token == call.heldToken {
                self.token = call.previousToken
            }
            call.holdsToken = false
            call.waitingToken = nil
            for completion: RefreshCompletion in call.completions {
                completion(.failure(CentrifugeError.clientDisconnected))
            }
        }
    }


    /// Applies an accepted refresh reply to the connection: the failure count and the refusal memory restart, the
    /// identity is updated, and the timer is armed from the new expiry, or stopped when the server reports none.
    /// The caller has set the token.
    func acceptRefreshReply(_ res: Centrifugal_Centrifuge_Protocol_RefreshResult) {
        refreshState.failures = 0
        refreshState.refusedToken = nil
        observeTokenExpiry(expires: res.expires, ttl: res.ttl)
        // The server accepted the token: an open refusal run of the token exchange is over.
        closeRefusalRun()
        if identity.applyRefresh(user: res.user, authClass: res.authClass) {
            delegate?.onAuth(self, CentrifugeAuthEvent(user: identity.user, authClass: identity.authClass))
        }
        if res.expires {
            startConnectionRefresh(after: connectionRenewalDelay(ttl: res.ttl))
        } else {
            stopConnectionRefresh()
        }
        poolTokenSource?.refreshAccepted()
    }


    /// Starts the timer refresh chain of the connection after `delay`. One chain per connection: a new step replaces
    /// the pending one, and the chain stops at its next step once the connection it was started for is gone.
    func startConnectionRefresh(after delay: TimeInterval) {
        self.refreshTask?.cancel()
        let transportId = self.transportId
        let refreshTask = DispatchWorkItem { [weak self] in
            guard let strongSelf = self, strongSelf.isCurrentConnection(transportId) else { return }
            guard strongSelf.config.tokenGetter != nil || strongSelf.config.tokenExchange != nil else { return }
            // Go through getConnectionToken rather than calling config.tokenGetter
            // directly: the app completes the getter on whatever thread it likes,
            // and everything below - failUnauthorized (which runs processDisconnect,
            // asserted to be on syncQueue), the delegate callback, and rescheduling
            // the refresh - is only safe on syncQueue.
            let generation: UInt64 = strongSelf.beginTimerFetch()
            strongSelf.getConnectionToken(completion: { [weak self] result in
                guard let strongSelf = self else { return }
                strongSelf.endTimerFetch()
                // A refresh() call admitted since the fetch started supersedes it: the token is not sent.
                guard strongSelf.isCurrentConnection(transportId), !strongSelf.timerFetchIsSuperseded(generation) else { return }
                // A refresh() call or a refresh command in flight goes first (refreshBusy): this fetch is not sent, and
                // the chain tries again after the retry delay, so it does not end. The deferral is not a failed refresh.
                if strongSelf.refreshBusy {
                    strongSelf.deferTimerRefresh()
                    return
                }
                switch result {
                case .success(let token):
                    if token == "" {
                        strongSelf.failUnauthorized()
                        return
                    }
                    // A token the server refused as expired is not sent again (stopOnRefusedToken): the
                    // connection is left to expire, and the next connect asks the getter.
                    if strongSelf.connectionTokenIsRefused(token) {
                        strongSelf.refreshRequired = true
                        return
                    }
                    strongSelf.refreshWithToken(token: token, transportId: transportId)
                case .failure(let error):
                    if let centrifugeError = error as? CentrifugeError {
                        switch centrifugeError {
                        case .unauthorized:
                            strongSelf.failUnauthorized()
                            return
                        default:
                            break
                        }
                    }
                    // Retry with backoff. Without rescheduling here a single failing
                    // token getter stops the refresh loop for the entire lifetime of
                    // the connection, and the server drops the client once the token
                    // expires. Scheduled before the callout because delegate callbacks run
                    // inline and may re-enter the client.
                    strongSelf.scheduleTimerRefreshRetry()
                    strongSelf.delegate?.onError(
                        strongSelf,
                        CentrifugeErrorEvent(error: CentrifugeError.tokenError(error: error))
                    )
                }
            })
        }

        self.scheduleAfter(delay, refreshTask)
        self.refreshTask = refreshTask
    }

    /// Cancels the timer refresh chain of the connection.
    func stopConnectionRefresh() {
        self.refreshTask?.cancel()
    }


    /// Arms the retry of a failed timer refresh, after the delay of the failure count. The count moves on.
    func scheduleTimerRefreshRetry() {
        let delay: TimeInterval = refreshRetryDelay(step: refreshState.failures, tokenRetryCap: config.tokenRetryCap, random: random)
        refreshState.failures += 1
        startConnectionRefresh(after: delay)
    }


    /// Arms the timer refresh again after the delay of the current failure count, without counting a failure. A timer
    /// fetch that a refresh in flight defers did not fail, so the next retry keeps its step.
    func deferTimerRefresh() {
        let delay: TimeInterval = refreshRetryDelay(step: refreshState.failures, tokenRetryCap: config.tokenRetryCap, random: random)
        startConnectionRefresh(after: delay)
    }


    /// Marks a timer token fetch as in flight. Returns the generation the fetch starts in: a refresh() call admitted
    /// before the fetch completes moves the generation on, and supersedes the fetch.
    func beginTimerFetch() -> UInt64 {
        refreshState.timerFetchInFlight = true
        return refreshState.generation
    }


    /// Marks the timer token fetch as finished.
    func endTimerFetch() {
        refreshState.timerFetchInFlight = false
    }


    /// Whether a refresh() call was admitted after the timer fetch that started in `generation`.
    func timerFetchIsSuperseded(_ generation: UInt64) -> Bool {
        return refreshState.generation != generation
    }
}


/// Whether a failed call that superseded a timer fetch arms the retry of that timer refresh. A loss of the
/// connection does not: its reconnect arms the timer again.
private func rearmsTimerAfter(_ error: Error) -> Bool {
    guard let centrifugeError: CentrifugeError = error as? CentrifugeError else {
        return true
    }
    switch centrifugeError {
    case .clientDisconnected, .connectionClosed:
        return false
    default:
        return true
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
