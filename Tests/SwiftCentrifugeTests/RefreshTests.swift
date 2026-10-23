import Foundation
import Testing
@testable import SwiftCentrifuge

// The explicit refresh, refresh(token:), and the retry rules of the timer refreshes. The timer refreshes run on
// the test clock: `advance(by:)` fires them, and the delay of a retry is read from the scheduler's record. A wait
// is on a server arrival or a delegate callback, never on time.


/// A failure of a token getter in these tests.
private struct FetchFailure: Error {
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
    /// seconds, so the timer refresh is armed. `draw` is the random source's position in each range. Returns once the
    /// client is connected and its timer is armed.
    private func startClient(_ config: CentrifugeClientConfig, delegate: ClosureClientDelegate, ttl: UInt32?, draw: Double = 0) async -> ManualClientSetup {
        if let expiry: UInt32 = ttl {
            server.connectResult.expires = true
            server.connectResult.ttl = expiry
        }
        let connected: Expectation = Expectation("connected")
        delegate.onConn = {
            connected.fulfill()
        }
        let setup: ManualClientSetup = makeManualClient(endpoint: server.url, config: config, delegate: delegate, random: ManualRandom(draw: draw))
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
        let delegate: ClosureClientDelegate = ClosureClientDelegate()
        delegate.onErr = { (event: CentrifugeErrorEvent) in
            if case CentrifugeError.refreshError = event.error {
                reported.fulfill()
            }
        }
        let setup: ManualClientSetup = await startClient(tokenConfig(tokenSequence(["T1", "T2"])), delegate: delegate, ttl: 10)
        await setup.scheduler.advance(by: 10)
        await fulfillment(of: [reported], within: 5)
        let delay: TimeInterval? = lastNonLateTimerDelay(setup.scheduler)
        await setup.scheduler.advance(by: 10)
        await fulfillment(of: [retried], within: 5)
        withExtendedLifetime(delegate) {}
        return (tokens: refreshTokens(), delay: delay)
    }


    @Test func refreshBeyondThe32InProgressIsRefusedWithLimitExceeded() async {
        // Not connected: every call waits for a connection, so none settles, and the 33rd is refused at once.
        let delegate: ClosureClientDelegate = ClosureClientDelegate()
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


    @Test func tokenLessCallSendsItsTokenBeforeALaterCall() async {
        server.onCommand = { (command: Centrifugal_Centrifuge_Protocol_Command) -> Centrifugal_Centrifuge_Protocol_Reply? in
            guard command.hasRefresh else {
                return nil
            }
            return acceptedReply(to: command)
        }
        // The test completes the getter's fetch by hand, so the later call is admitted while the fetch is pending.
        let fetches: EventCounter = EventCounter()
        let completions: LockedBox<[(Result<String, Error>) -> Void]> = LockedBox([])
        let getter: CentrifugeConnectionTokenGetter = { (_: CentrifugeConnectionTokenEvent, completion: @escaping (Result<String, Error>) -> Void) in
            completions.update { (values: inout [(Result<String, Error>) -> Void]) in
                values.append(completion)
            }
            fetches.record()
        }
        var config: CentrifugeClientConfig = CentrifugeClientConfig()
        config.token = "initial"
        config.tokenGetter = getter
        let delegate: ClosureClientDelegate = ClosureClientDelegate()
        let setup: ManualClientSetup = await startClient(config, delegate: delegate, ttl: nil)

        let first: Expectation = Expectation("token-less call succeeded")
        let second: Expectation = Expectation("call with a token succeeded")
        let order: LockedBox<[String]> = LockedBox([])
        setup.client.refresh { (result: Result<CentrifugeRefreshResult, Error>) in
            if case .success = result {
                order.update { (values: inout [String]) in
                    values.append("token-less")
                }
                first.fulfill()
            }
        }
        await fetches.awaitCount(times: 1)
        setup.client.refresh(token: "B") { (result: Result<CentrifugeRefreshResult, Error>) in
            if case .success = result {
                order.update { (values: inout [String]) in
                    values.append("B")
                }
                second.fulfill()
            }
        }
        let fetched: (Result<String, Error>) -> Void = completions.current[0]
        fetched(.success("A-token"))
        await fulfillment(of: [first, second], within: 5)
        // The fetched token of the first call is sent before the token of the later call.
        #expect(refreshTokens() == ["A-token", "B"])
        #expect(order.current == ["token-less", "B"])
        withExtendedLifetime(delegate) {}
    }


    @Test func acceptedExplicitRefreshUpdatesTheIdentityAndTheTimer() async {
        server.connectResult.user = "alice"
        server.onCommand = { (command: Centrifugal_Centrifuge_Protocol_Command) -> Centrifugal_Centrifuge_Protocol_Reply? in
            guard command.hasRefresh else {
                return nil
            }
            var reply: Centrifugal_Centrifuge_Protocol_Reply = Centrifugal_Centrifuge_Protocol_Reply()
            reply.id = command.id
            reply.refresh.expires = true
            reply.refresh.ttl = 30
            reply.refresh.user = "bob"
            return reply
        }
        let delegate: ClosureClientDelegate = ClosureClientDelegate()
        let identities: LockedBox<[String]> = LockedBox([])
        delegate.onAuthEvent = { (event: CentrifugeAuthEvent) in
            identities.update { (values: inout [String]) in
                values.append(event.user)
            }
        }
        var config: CentrifugeClientConfig = CentrifugeClientConfig()
        config.token = "initial"
        let setup: ManualClientSetup = await startClient(config, delegate: delegate, ttl: nil)

        let accepted: Expectation = Expectation("refresh accepted")
        setup.client.refresh(token: "new-token") { (result: Result<CentrifugeRefreshResult, Error>) in
            if case .success(let refreshed) = result, refreshed.expires, refreshed.ttl == 30, refreshed.user == "bob" {
                accepted.fulfill()
            }
        }
        await fulfillment(of: [accepted], within: 5)
        // The connect reported alice; the refresh changes the user once.
        #expect(identities.current == ["alice", "bob"])
        // The timer is armed from the ttl of the accepted refresh.
        #expect(lastNonLateTimerDelay(setup.scheduler) == 30)

        // The next connect carries the accepted token.
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
        #expect(server.received().filter(\.hasConnect).map(\.connect.token) == ["initial", "new-token"])
        withExtendedLifetime(delegate) {}
    }


    @Test func refusedRefreshKeepsTheIdentityAndTheToken() async {
        server.connectResult.user = "alice"
        server.onCommand = { (command: Centrifugal_Centrifuge_Protocol_Command) -> Centrifugal_Centrifuge_Protocol_Reply? in
            guard command.hasRefresh else {
                return nil
            }
            return errorReply(to: command, code: 103, temporary: false)
        }
        let delegate: ClosureClientDelegate = ClosureClientDelegate()
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
        let delegate: ClosureClientDelegate = ClosureClientDelegate()
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


    @Test func refusalAfterASupersedingCallThatFailedLocallyArmsNoRetry() async {
        server.onCommand = { (command: Centrifugal_Centrifuge_Protocol_Command) -> Centrifugal_Centrifuge_Protocol_Reply? in
            guard command.hasRefresh else {
                return nil
            }
            return errorReply(to: command, code: 25, temporary: false)
        }
        // The test completes each getter fetch by hand: the timer fetch first, then the explicit call's fetch.
        let fetches: EventCounter = EventCounter()
        let completions: LockedBox<[(Result<String, Error>) -> Void]> = LockedBox([])
        let getter: CentrifugeConnectionTokenGetter = { (_: CentrifugeConnectionTokenEvent, completion: @escaping (Result<String, Error>) -> Void) in
            completions.update { (values: inout [(Result<String, Error>) -> Void]) in
                values.append(completion)
            }
            fetches.record()
        }
        let delegate: ClosureClientDelegate = ClosureClientDelegate()
        let setup: ManualClientSetup = await startClient(tokenConfig(getter), delegate: delegate, ttl: 10)

        await setup.scheduler.advance(by: 10)
        await fetches.awaitCount(times: 1)
        // The timer fetch is in flight. A refresh() without a token supersedes it and fetches its own token.
        let failed: Expectation = Expectation("explicit call failed locally")
        setup.client.refresh { (result: Result<CentrifugeRefreshResult, Error>) in
            if case .failure = result {
                failed.fulfill()
            }
        }
        await fetches.awaitCount(times: 2)
        let armedBeforeFailure: Int = nonLateTimerCount(setup.scheduler)
        let explicitFetch: (Result<String, Error>) -> Void = completions.current[1]
        explicitFetch(.failure(FetchFailure()))
        await fulfillment(of: [failed], within: 5)
        // The superseding call failed locally with the connection up, so the timer refresh is retried once.
        #expect(nonLateTimerCount(setup.scheduler) == armedBeforeFailure + 1)

        // The superseded timer fetch ends later: its token is dropped, and nothing is armed.
        let timerFetch: (Result<String, Error>) -> Void = completions.current[0]
        timerFetch(.success("timer-token"))
        await awaitSyncQueue(setup.client)
        let armedBeforeRefusal: Int = nonLateTimerCount(setup.scheduler)

        // A refusal of a later call that superseded nothing arms no retry.
        let refused: Expectation = Expectation("unrelated refresh refused")
        setup.client.refresh(token: "unrelated") { (result: Result<CentrifugeRefreshResult, Error>) in
            if case .failure = result {
                refused.fulfill()
            }
        }
        await fulfillment(of: [refused], within: 5)
        #expect(nonLateTimerCount(setup.scheduler) == armedBeforeRefusal)
        #expect(refreshTokens() == ["unrelated"])
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
        let delegate: ClosureClientDelegate = ClosureClientDelegate()
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


    @Test func refusedTimerRefreshKeepsTheConnection() async {
        server.onCommand = { (command: Centrifugal_Centrifuge_Protocol_Command) -> Centrifugal_Centrifuge_Protocol_Reply? in
            guard command.hasRefresh else {
                return nil
            }
            return errorReply(to: command, code: 103, temporary: false)
        }
        let reported: Expectation = Expectation("refresh error reported")
        let delegate: ClosureClientDelegate = ClosureClientDelegate()
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
        let delegate: ClosureClientDelegate = ClosureClientDelegate()
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
        let delegate: ClosureClientDelegate = ClosureClientDelegate()
        let setup: ManualClientSetup = await startClient(config, delegate: delegate, ttl: 10)
        await setup.scheduler.advance(by: 10)
        await fulfillment(of: [dropped], within: 5)
        // The dropped command has been written and its timeout armed on the queue before the clock moves on.
        await awaitSyncQueue(setup.client)
        server.dropCommand = nil
        await setup.scheduler.advance(by: 2)
        // The retry is armed with the same backoff as a refusal: 10 s with draw 0.
        #expect(lastNonLateTimerDelay(setup.scheduler) == 10)
        await setup.scheduler.advance(by: 10)
        await fulfillment(of: [retried], within: 5)
        withExtendedLifetime(delegate) {}
    }


    /// Refresh commands go out one at a time (contract 4.3): a refresh() call admitted while a timer refresh command is
    /// in flight is sent only after that command has ended.
    @Test func explicitRefreshWaitsForAnInFlightTimerCommand() async {
        let dropped: Expectation = Expectation("timer refresh arrived")
        let answered: Expectation = Expectation("explicit refresh answered")
        let explicitDone: Expectation = Expectation("explicit refresh completed")
        server.dropCommand = { (command: Centrifugal_Centrifuge_Protocol_Command) -> Bool in
            guard command.hasRefresh, command.refresh.token == "T1" else {
                return false
            }
            dropped.fulfill()
            return true
        }
        server.onCommand = { (command: Centrifugal_Centrifuge_Protocol_Command) -> Centrifugal_Centrifuge_Protocol_Reply? in
            guard command.hasRefresh else {
                return nil
            }
            answered.fulfill()
            return acceptedReply(to: command)
        }
        let config: CentrifugeClientConfig = tokenConfig(tokenSequence(["T1"]))
        let delegate: ClosureClientDelegate = ClosureClientDelegate()
        let setup: ManualClientSetup = await startClient(config, delegate: delegate, ttl: 10)
        // The timer refresh is sent with T1 and its reply never comes.
        await setup.scheduler.advance(by: 10)
        await fulfillment(of: [dropped], within: 5)
        await awaitSyncQueue(setup.client)

        // The explicit call is admitted while that command is in flight: it waits and sends nothing.
        setup.client.refresh(token: "E1") { (_: Result<CentrifugeRefreshResult, Error>) -> Void in
            explicitDone.fulfill()
        }
        await awaitSyncQueue(setup.client)
        #expect(!refreshTokens().contains("E1"), "the explicit refresh does not overlap the timer command")

        // The timer command times out; its end sends the explicit refresh, which the server accepts.
        server.dropCommand = nil
        await setup.scheduler.advance(by: config.timeout)
        await fulfillment(of: [answered, explicitDone], within: 5)
        #expect(refreshTokens().last == "E1")
        withExtendedLifetime(delegate) {}
    }


    /// rpc() waits while a refresh command is in flight (contract 4.3, table T2): the call is written after the
    /// command has ended.
    @Test func rpcWaitsWhileARefreshCommandIsInFlight() async {
        let dropped: Expectation = Expectation("timer refresh arrived")
        let rpcArrived: Expectation = Expectation("rpc arrived")
        server.dropCommand = { (command: Centrifugal_Centrifuge_Protocol_Command) -> Bool in
            guard command.hasRefresh else {
                return false
            }
            dropped.fulfill()
            return true
        }
        server.onCommand = { (command: Centrifugal_Centrifuge_Protocol_Command) -> Centrifugal_Centrifuge_Protocol_Reply? in
            if command.hasRpc {
                rpcArrived.fulfill()
                return nil
            }
            return nil
        }
        let config: CentrifugeClientConfig = tokenConfig(tokenSequence(["T1"]))
        let delegate: ClosureClientDelegate = ClosureClientDelegate()
        let setup: ManualClientSetup = await startClient(config, delegate: delegate, ttl: 10)
        await setup.scheduler.advance(by: 10)
        await fulfillment(of: [dropped], within: 5)
        await awaitSyncQueue(setup.client)

        setup.client.rpc(method: "m", data: Data()) { (_: Result<CentrifugeRpcResult, Error>) -> Void in
        }
        await awaitSyncQueue(setup.client)
        #expect(server.received().filter(\.hasRpc).isEmpty, "the rpc waits for the refresh command")

        // The timer command ends by its timeout: the waiting rpc is written then.
        server.dropCommand = nil
        await setup.scheduler.advance(by: config.timeout)
        await fulfillment(of: [rpcArrived], within: 5)
        withExtendedLifetime(delegate) {}
    }


    @Test func refusedTokenIsNotSentAgainWithStopOnRefusedToken() async {
        server.onCommand = { (command: Centrifugal_Centrifuge_Protocol_Command) -> Centrifugal_Centrifuge_Protocol_Reply? in
            guard command.hasRefresh else {
                return nil
            }
            // The sentinel token is accepted; the refused token gets 109.
            if command.refresh.token == "T2" {
                return acceptedReply(to: command)
            }
            return errorReply(to: command, code: 109, temporary: false)
        }
        let reported: Expectation = Expectation("refresh error reported")
        let refetched: Expectation = Expectation("retry fetched the token again")
        let refetchedOnConnect: Expectation = Expectation("connect fetched a token again")
        let delegate: ClosureClientDelegate = ClosureClientDelegate()
        delegate.onErr = { (event: CentrifugeErrorEvent) in
            if case CentrifugeError.refreshError = event.error {
                reported.fulfill()
            }
        }
        let getter: CentrifugeConnectionTokenGetter = tokenSequence(["T1"], afterCall: { (count: Int) in
            if count == 2 {
                refetched.fulfill()
            }
            if count == 3 {
                refetchedOnConnect.fulfill()
            }
        })
        let setup: ManualClientSetup = await startClient(tokenConfig(getter), delegate: delegate, ttl: 10)
        await setup.scheduler.advance(by: 10)
        await fulfillment(of: [reported], within: 5)
        // The refusal armed the retry (10 s at draw 0). The retry fetches the refused token again: it is not sent, and
        // no timer is armed after it.
        let armedBeforeRetry: Int = nonLateTimerCount(setup.scheduler)
        await setup.scheduler.advance(by: 10)
        await fulfillment(of: [refetched], within: 5)
        // The fetch ran and its decision is on the queue before this block. A resend would be written on the connection
        // in that decision and would reach the fake server after this point, so a sentinel orders after it: an explicit
        // refresh with another token, which the server accepts. The connection is one ordered stream, so when the sentinel
        // has been answered, every command written before it has been received.
        await awaitSyncQueue(setup.client)
        #expect(nonLateTimerCount(setup.scheduler) == armedBeforeRetry)
        let sentinel: Expectation = Expectation("sentinel refresh answered")
        setup.client.refresh(token: "T2") { (_: Result<CentrifugeRefreshResult, Error>) -> Void in
            sentinel.fulfill()
        }
        await fulfillment(of: [sentinel], within: 5)
        #expect(refreshTokens() == ["T1", "T2"], "the refused token is not sent again")

        // The skipped token leaves the refresh required: the next connect fetches a token from the getter.
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
        await fulfillment(of: [reconnected, refetchedOnConnect], within: 5)
        withExtendedLifetime(delegate) {}
    }
}
