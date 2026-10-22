import Foundation
import Testing
@testable import SwiftCentrifuge

// The explicit refresh, refresh(token:), and the retry rules of the timer refreshes (tables T4 and T5 of
// the parity spec). The timer refreshes run on the test clock: `advance(by:)` fires them, and the delay of a
// retry is read from the scheduler's record. A wait is on a server arrival or a delegate callback, never on time.

/// Delegate of these tests: each callback calls the closure the test set.
private final class RefreshDelegate: CentrifugeClientDelegate, @unchecked Sendable {
    var onConn: (() -> Void)?
    var onErr: ((CentrifugeErrorEvent) -> Void)?
    var onDisc: ((CentrifugeDisconnectedEvent) -> Void)?
    var onAuthEvent: ((CentrifugeAuthEvent) -> Void)?


    func onConnected(_ client: CentrifugeClient, _ event: CentrifugeConnectedEvent) {
        onConn?()
    }


    func onError(_ client: CentrifugeClient, _ event: CentrifugeErrorEvent) {
        onErr?(event)
    }


    func onDisconnected(_ client: CentrifugeClient, _ event: CentrifugeDisconnectedEvent) {
        onDisc?(event)
    }


    func onAuth(_ client: CentrifugeClient, _ event: CentrifugeAuthEvent) {
        onAuthEvent?(event)
    }
}


/// The reply the server gives to a refresh command: an error with the code given.
private func errorReply(to command: Centrifugal_Centrifuge_Protocol_Command, code: UInt32, temporary: Bool) -> Centrifugal_Centrifuge_Protocol_Reply {
    var reply: Centrifugal_Centrifuge_Protocol_Reply = Centrifugal_Centrifuge_Protocol_Reply()
    reply.id = command.id
    reply.error.code = code
    reply.error.message = "refused"
    reply.error.temporary = temporary
    return reply
}


/// The reply the server gives to a refresh command that is accepted: no expiry, the identity the connect gave.
private func acceptedReply(to command: Centrifugal_Centrifuge_Protocol_Command) -> Centrifugal_Centrifuge_Protocol_Reply {
    var reply: Centrifugal_Centrifuge_Protocol_Reply = Centrifugal_Centrifuge_Protocol_Reply()
    reply.id = command.id
    reply.refresh = Centrifugal_Centrifuge_Protocol_RefreshResult()
    return reply
}


/// A token getter that returns the tokens in order, the last one for every later call. `afterCall` runs after each
/// call, with the number of calls so far; it runs after the completion, so the work the completion queued is ahead of
/// anything the test queues after it.
private func tokenSequence(_ tokens: [String], afterCall: @escaping (Int) -> Void = { (_: Int) in }) -> CentrifugeConnectionTokenGetter {
    let calls: LockedBox<Int> = LockedBox(0)
    return { (_: CentrifugeConnectionTokenEvent, completion: @escaping (Result<String, Error>) -> Void) in
        var index: Int = 0
        calls.update { (count: inout Int) in
            index = count
            count += 1
        }
        completion(.success(tokens[min(index, tokens.count - 1)]))
        afterCall(index + 1)
    }
}


@Suite(.serialized, .timeLimit(.minutes(1)))
final class RefreshTests: @unchecked Sendable {
    private let server: FakeCentrifugoServer


    init() throws {
        server = FakeCentrifugoServer()
        try server.start()
    }


    deinit {
        server.stop()
    }


    /// Returns once every block enqueued on the client's queue before this call has run.
    private func awaitSyncQueue(_ client: CentrifugeClient) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            client.syncQueue.async {
                continuation.resume()
            }
        }
    }


    /// The tokens of the refresh commands the server received, in order.
    private func refreshTokens() -> [String] {
        return server.received().filter(\.hasRefresh).map(\.refresh.token)
    }


    private func tokenConfig(_ getter: @escaping CentrifugeConnectionTokenGetter) -> CentrifugeClientConfig {
        var config: CentrifugeClientConfig = CentrifugeClientConfig()
        config.token = "initial"
        config.tokenGetter = getter
        return config
    }


    /// Connects a client on the manual clock. With `ttl`, the connect result says the token expires after that many
    /// seconds, so the timer refresh is armed. Returns once the client is connected and its timer is armed.
    private func startClient(_ config: CentrifugeClientConfig, delegate: RefreshDelegate, ttl: UInt32?) async -> ManualClientSetup {
        if let expiry: UInt32 = ttl {
            server.connectResult.expires = true
            server.connectResult.ttl = expiry
        }
        let connected: Expectation = Expectation("connected")
        delegate.onConn = {
            connected.fulfill()
        }
        let setup: ManualClientSetup = makeManualClient(endpoint: server.url, config: config, delegate: delegate, random: ManualRandom(draw: 0))
        setup.client.connect()
        await fulfillment(of: [connected], within: 5)
        // onConnected runs before the connect handler arms the timer, on the same queue block.
        await awaitSyncQueue(setup.client)
        return setup
    }


    /// A timer refresh that the server refuses with `code`, then the retry with a fresh token. Returns the tokens of
    /// the refresh commands and the delay of the retry, which is the last timer armed that is not a command timeout.
    private func retryAfterRefusal(code: UInt32, temporary: Bool) async -> (tokens: [String], delay: TimeInterval?) {
        let refused: LockedBox<Int> = LockedBox(0)
        let retried: Expectation = Expectation("retry sent with the fresh token")
        server.onCommand = { (command: Centrifugal_Centrifuge_Protocol_Command) -> Centrifugal_Centrifuge_Protocol_Reply? in
            guard command.hasRefresh else {
                return nil
            }
            var count: Int = 0
            refused.update { (value: inout Int) in
                value += 1
                count = value
            }
            if count == 1 {
                return errorReply(to: command, code: code, temporary: temporary)
            }
            if command.refresh.token == "T2" {
                retried.fulfill()
            }
            return acceptedReply(to: command)
        }
        let reported: Expectation = Expectation("refresh error reported")
        let delegate: RefreshDelegate = RefreshDelegate()
        delegate.onErr = { (event: CentrifugeErrorEvent) in
            if case CentrifugeError.refreshError = event.error {
                reported.fulfill()
            }
        }
        let setup: ManualClientSetup = await startClient(tokenConfig(tokenSequence(["T1", "T2"])), delegate: delegate, ttl: 10)
        await setup.scheduler.advance(by: 10)
        await fulfillment(of: [reported], within: 5)
        let delay: TimeInterval? = setup.scheduler.scheduledCalls.last(where: { (call: ScheduledCall) -> Bool in
            return !call.lateGrace
        })?.delay
        await setup.scheduler.advance(by: 10)
        await fulfillment(of: [retried], within: 5)
        withExtendedLifetime(delegate) {}
        return (tokens: refreshTokens(), delay: delay)
    }


    @Test func refreshBeyondThe32InProgressIsRefusedWithLimitExceeded() async {
        // Not connected: every call waits for a connection, so none settles, and the 33rd is refused at once.
        let delegate: RefreshDelegate = RefreshDelegate()
        let client: CentrifugeClient = CentrifugeClient(endpoint: server.url, config: CentrifugeClientConfig(), delegate: delegate)
        for index: Int in 0 ..< maxRefreshCalls {
            client.refresh(token: "token-\(index)") { (_: Result<CentrifugeRefreshResult, Error>) in }
        }
        let limited: Expectation = Expectation("33rd call refused with limit exceeded")
        client.refresh(token: "token-last") { (result: Result<CentrifugeRefreshResult, Error>) in
            if case .failure(let error) = result, case CentrifugeError.replyError(let code, _, _) = error, code == 16 {
                limited.fulfill()
            }
        }
        await fulfillment(of: [limited], within: 5)
        withExtendedLifetime(client) {}
    }


    @Test func refreshWithoutTokenOrGetterIsConfigurationError() async {
        let client: CentrifugeClient = CentrifugeClient(endpoint: server.url, config: CentrifugeClientConfig())
        let refused: Expectation = Expectation("refused with the configuration error")
        client.refresh { (result: Result<CentrifugeRefreshResult, Error>) in
            if case .failure(let error) = result, case CentrifugeError.configurationError(let message) = error, message == "refresh needs a token: pass one to refresh() or set getToken" {
                refused.fulfill()
            }
        }
        await fulfillment(of: [refused], within: 5)
        withExtendedLifetime(client) {}
    }


    @Test func refusedRefreshKeepsTheIdentityAndTheToken() async {
        server.connectResult.user = "alice"
        server.onCommand = { (command: Centrifugal_Centrifuge_Protocol_Command) -> Centrifugal_Centrifuge_Protocol_Reply? in
            guard command.hasRefresh else {
                return nil
            }
            return errorReply(to: command, code: 103, temporary: false)
        }
        let delegate: RefreshDelegate = RefreshDelegate()
        let identities: LockedBox<[String]> = LockedBox([])
        delegate.onAuthEvent = { (event: CentrifugeAuthEvent) in
            identities.update { (values: inout [String]) in
                values.append(event.user)
            }
        }
        var config: CentrifugeClientConfig = CentrifugeClientConfig()
        config.token = "initial"
        let setup: ManualClientSetup = await startClient(config, delegate: delegate, ttl: nil)

        let refused: Expectation = Expectation("refusal reported")
        setup.client.refresh(token: "new") { (result: Result<CentrifugeRefreshResult, Error>) in
            if case .failure(let error) = result, case CentrifugeError.replyError(let code, _, _) = error, code == 103 {
                refused.fulfill()
            }
        }
        await fulfillment(of: [refused], within: 5)
        #expect(identities.current.count == 1, "a refused refresh reports no identity change")

        // The connection keeps the old token: the next connect carries it.
        let disconnected: Expectation = Expectation("disconnected")
        delegate.onDisc = { (_: CentrifugeDisconnectedEvent) in
            disconnected.fulfill()
        }
        setup.client.disconnect()
        await fulfillment(of: [disconnected], within: 5)
        let reconnected: Expectation = Expectation("reconnected")
        delegate.onConn = {
            reconnected.fulfill()
        }
        setup.client.connect()
        await fulfillment(of: [reconnected], within: 5)
        #expect(server.received().filter(\.hasConnect).map(\.connect.token) == ["initial", "initial"])
        withExtendedLifetime(delegate) {}
    }


    @Test func refusedRefreshWhileDisconnectedRestoresThePreviousToken() async {
        server.onCommand = { (command: Centrifugal_Centrifuge_Protocol_Command) -> Centrifugal_Centrifuge_Protocol_Reply? in
            guard command.hasRefresh else {
                return nil
            }
            return errorReply(to: command, code: 103, temporary: false)
        }
        let delegate: RefreshDelegate = RefreshDelegate()
        var config: CentrifugeClientConfig = CentrifugeClientConfig()
        config.token = "initial"
        let setup: ManualClientSetup = await startClient(config, delegate: delegate, ttl: nil)

        let disconnected: Expectation = Expectation("disconnected")
        delegate.onDisc = { (_: CentrifugeDisconnectedEvent) in
            disconnected.fulfill()
        }
        setup.client.disconnect()
        await fulfillment(of: [disconnected], within: 5)

        // Called while disconnected: the call waits, and the connect that follows carries its token.
        let refused: Expectation = Expectation("refusal reported")
        setup.client.refresh(token: "new") { (result: Result<CentrifugeRefreshResult, Error>) in
            if case .failure(let error) = result, case CentrifugeError.replyError(let code, _, _) = error, code == 103 {
                refused.fulfill()
            }
        }
        let reconnected: Expectation = Expectation("reconnected with the refreshed token")
        delegate.onConn = {
            reconnected.fulfill()
        }
        setup.client.connect()
        await fulfillment(of: [reconnected, refused], within: 5)

        // The server refused the token, so the previous one is back: the next connect carries it.
        let droppedAgain: Expectation = Expectation("disconnected after the refusal")
        delegate.onDisc = { (_: CentrifugeDisconnectedEvent) in
            droppedAgain.fulfill()
        }
        setup.client.disconnect()
        await fulfillment(of: [droppedAgain], within: 5)
        let reconnectedAgain: Expectation = Expectation("reconnected")
        delegate.onConn = {
            reconnectedAgain.fulfill()
        }
        setup.client.connect()
        await fulfillment(of: [reconnectedAgain], within: 5)
        #expect(server.received().filter(\.hasConnect).map(\.connect.token) == ["initial", "new", "initial"])
        withExtendedLifetime(delegate) {}
    }


    @Test func refusedTimerRefreshKeepsTheConnection() async {
        server.onCommand = { (command: Centrifugal_Centrifuge_Protocol_Command) -> Centrifugal_Centrifuge_Protocol_Reply? in
            guard command.hasRefresh else {
                return nil
            }
            return errorReply(to: command, code: 103, temporary: false)
        }
        let reported: Expectation = Expectation("refresh error reported")
        let delegate: RefreshDelegate = RefreshDelegate()
        delegate.onErr = { (event: CentrifugeErrorEvent) in
            if case CentrifugeError.refreshError = event.error {
                reported.fulfill()
            }
        }
        let setup: ManualClientSetup = await startClient(tokenConfig(tokenSequence(["T1"])), delegate: delegate, ttl: 10)
        await setup.scheduler.advance(by: 10)
        await fulfillment(of: [reported], within: 5)
        #expect(setup.client.state == .connected)
        withExtendedLifetime(delegate) {}
    }


    @Test func refusedTimerRefreshIsNotRetried() async {
        server.onCommand = { (command: Centrifugal_Centrifuge_Protocol_Command) -> Centrifugal_Centrifuge_Protocol_Reply? in
            guard command.hasRefresh else {
                return nil
            }
            return errorReply(to: command, code: 103, temporary: false)
        }
        let reported: Expectation = Expectation("refresh error reported")
        let delegate: RefreshDelegate = RefreshDelegate()
        delegate.onErr = { (event: CentrifugeErrorEvent) in
            if case CentrifugeError.refreshError = event.error {
                reported.fulfill()
            }
        }
        let setup: ManualClientSetup = await startClient(tokenConfig(tokenSequence(["T1"])), delegate: delegate, ttl: 10)
        let armedBefore: Int = setup.scheduler.scheduledCalls.count
        await setup.scheduler.advance(by: 10)
        await fulfillment(of: [reported], within: 5)
        // Nothing but command timeouts is armed after the refusal. The advance stays before the ping window of the
        // fake server ends (its connect result carries ping 25 s, and it never pings), so no reconnect is armed.
        await setup.scheduler.advance(by: 20)
        let armedAfter: [ScheduledCall] = Array(setup.scheduler.scheduledCalls.dropFirst(armedBefore))
        #expect(armedAfter.allSatisfy { (call: ScheduledCall) -> Bool in
            return call.lateGrace
        })
        #expect(refreshTokens().count == 1)
        withExtendedLifetime(delegate) {}
    }


    @Test func timerRefreshRefusedWithAnotherCodeDisconnectsWithIt() async {
        server.onCommand = { (command: Centrifugal_Centrifuge_Protocol_Command) -> Centrifugal_Centrifuge_Protocol_Reply? in
            guard command.hasRefresh else {
                return nil
            }
            return errorReply(to: command, code: 3500, temporary: false)
        }
        let disconnected: Expectation = Expectation("disconnected with the refusal code")
        let delegate: RefreshDelegate = RefreshDelegate()
        delegate.onDisc = { (event: CentrifugeDisconnectedEvent) in
            if event.code == 3500 {
                disconnected.fulfill()
            }
        }
        let setup: ManualClientSetup = await startClient(tokenConfig(tokenSequence(["T1"])), delegate: delegate, ttl: 10)
        await setup.scheduler.advance(by: 10)
        await fulfillment(of: [disconnected], within: 5)
        #expect(setup.client.state == .disconnected)
        withExtendedLifetime(delegate) {}
    }


    @Test func timerRefreshWithAnExpiredTokenRetriesWithAFreshToken() async {
        let result: (tokens: [String], delay: TimeInterval?) = await retryAfterRefusal(code: 109, temporary: false)
        #expect(result.tokens == ["T1", "T2"])
        #expect(result.delay == 10)
    }


    @Test func timerRefreshWithAClientErrorCodeIsRetriedWithAFreshToken() async {
        let result: (tokens: [String], delay: TimeInterval?) = await retryAfterRefusal(code: 25, temporary: false)
        #expect(result.tokens == ["T1", "T2"])
        #expect(result.delay == 10)
    }


    @Test func timerRefreshWithATransportErrorIsRetriedWithTheSameBackoff() async {
        let dropped: Expectation = Expectation("first refresh arrived")
        let retried: Expectation = Expectation("retry arrived")
        server.dropCommand = { (command: Centrifugal_Centrifuge_Protocol_Command) -> Bool in
            guard command.hasRefresh else {
                return false
            }
            dropped.fulfill()
            return true
        }
        server.onCommand = { (command: Centrifugal_Centrifuge_Protocol_Command) -> Centrifugal_Centrifuge_Protocol_Reply? in
            guard command.hasRefresh else {
                return nil
            }
            retried.fulfill()
            return acceptedReply(to: command)
        }
        var config: CentrifugeClientConfig = tokenConfig(tokenSequence(["T1"]))
        // A short reply timeout: the dropped refresh fails with a timeout, which is a transport error for the retry rule.
        config.timeout = 2
        let delegate: RefreshDelegate = RefreshDelegate()
        let setup: ManualClientSetup = await startClient(config, delegate: delegate, ttl: 10)
        await setup.scheduler.advance(by: 10)
        await fulfillment(of: [dropped], within: 5)
        // The dropped command has been written and its timeout armed on the queue before the clock moves on.
        await awaitSyncQueue(setup.client)
        server.dropCommand = nil
        await setup.scheduler.advance(by: 2)
        // The retry is armed with the same backoff as a refusal: 10 s with draw 0.
        let delay: TimeInterval? = setup.scheduler.scheduledCalls.last(where: { (call: ScheduledCall) -> Bool in
            return !call.lateGrace
        })?.delay
        #expect(delay == 10)
        await setup.scheduler.advance(by: 10)
        await fulfillment(of: [retried], within: 5)
        withExtendedLifetime(delegate) {}
    }


    @Test func refusedTokenIsNotSentAgainWithStopOnRefusedToken() async {
        server.onCommand = { (command: Centrifugal_Centrifuge_Protocol_Command) -> Centrifugal_Centrifuge_Protocol_Reply? in
            guard command.hasRefresh else {
                return nil
            }
            return errorReply(to: command, code: 109, temporary: false)
        }
        let reported: Expectation = Expectation("refresh error reported")
        let refetched: Expectation = Expectation("retry fetched the token again")
        let delegate: RefreshDelegate = RefreshDelegate()
        delegate.onErr = { (event: CentrifugeErrorEvent) in
            if case CentrifugeError.refreshError = event.error {
                reported.fulfill()
            }
        }
        let getter: CentrifugeConnectionTokenGetter = tokenSequence(["T1"], afterCall: { (count: Int) in
            if count == 2 {
                refetched.fulfill()
            }
        })
        let setup: ManualClientSetup = await startClient(tokenConfig(getter), delegate: delegate, ttl: 10)
        await setup.scheduler.advance(by: 10)
        await fulfillment(of: [reported], within: 5)
        await setup.scheduler.advance(by: 10)
        await fulfillment(of: [refetched], within: 5)
        // The fetch ran and its decision is on the queue before this block: the refused token was not sent.
        await awaitSyncQueue(setup.client)
        #expect(refreshTokens() == ["T1"])
        withExtendedLifetime(delegate) {}
    }
}
