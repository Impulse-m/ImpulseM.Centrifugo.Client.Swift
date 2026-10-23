import Foundation
import Testing
@testable import SwiftCentrifuge

// The token exchange (TokenExchange.swift, TokenExchangeFlow.swift): the anonymous connect is completed over the same
// connection, a rotated refresh token is stored before the refresh command, a refused refresh token is presented again
// once inside the grace and the session ends at the second refusal, and the renewal window is drawn from the injected
// random source. The exchange of the application is a plain rpc to the fake server, which answers "access|rotated".
// A wait is on a server arrival, a delegate callback or a clock advance, never on time.


/// The exchange of one test: it completes its callback with an outcome.
private typealias ExchangeAnswer = (CentrifugeTokenExchangeEvent, @escaping (Result<CentrifugeTokenExchangeResult, Error>) -> Void) -> Void


/// The application's storage and exchange for the tests. Every store and every exchange is recorded in `events`,
/// in order, as "store:<token>" and "exchange:<token>". The fake server records its refresh commands in the same list.
private final class TestTokenExchange: CentrifugeTokenExchange, @unchecked Sendable {
    let events: LockedBox<[String]>
    private let stored: LockedBox<String?>
    private let answer: ExchangeAnswer
    private let graceSeconds: TimeInterval
    private let earlyRenewalFlag: Bool


    init(
        stored: String?,
        events: LockedBox<[String]>,
        grace: TimeInterval = 30,
        earlyRenewal: Bool = false,
        answer: @escaping ExchangeAnswer
    ) {
        self.stored = LockedBox(stored)
        self.events = events
        self.graceSeconds = grace
        self.earlyRenewalFlag = earlyRenewal
        self.answer = answer
    }


    var grace: TimeInterval {
        return graceSeconds
    }


    var earlyRenewal: Bool {
        return earlyRenewalFlag
    }


    var storedToken: String? {
        return stored.current
    }


    /// The refresh tokens the exchange was asked for, in order.
    var exchangedTokens: [String] {
        let prefix: String = "exchange:"
        return events.current.compactMap { (event: String) -> String? in
            guard event.hasPrefix(prefix) else {
                return nil
            }
            return String(event.dropFirst(prefix.count))
        }
    }


    func load(completion: @escaping (Result<CentrifugeStoredTokens?, Error>) -> Void) {
        let token: String? = stored.current
        let tokens: CentrifugeStoredTokens? = token.map { (value: String) -> CentrifugeStoredTokens in
            return CentrifugeStoredTokens(refreshToken: value)
        }
        completion(.success(tokens))
    }


    func store(_ tokens: CentrifugeStoredTokens, completion: @escaping (Error?) -> Void) {
        events.update { (values: inout [String]) in
            values.append("store:" + tokens.refreshToken)
        }
        stored.set(tokens.refreshToken)
        completion(nil)
    }


    func exchange(_ event: CentrifugeTokenExchangeEvent, completion: @escaping (Result<CentrifugeTokenExchangeResult, Error>) -> Void) {
        events.update { (values: inout [String]) in
            values.append("exchange:" + event.refreshToken)
        }
        answer(event, completion)
    }
}


/// The exchange of the tests: a plain rpc over the connection, which the fake server answers.
private func rpcAnswer() -> ExchangeAnswer {
    return { event, completion in
        event.rpc(method: "exchange", data: Data(event.refreshToken.utf8), completion: { (result: Result<CentrifugeRpcResult, Error>) in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let reply):
                completion(.success(parsedExchange(reply.data)))
            }
        })
    }
}


/// The exchange of a refresh token the issuer refuses.
private func refusingAnswer() -> ExchangeAnswer {
    return { _, completion in
        completion(.failure(CentrifugeError.unauthorized))
    }
}


/// The data the fake server answers an exchange with, "access" or "access|rotated", as the result of the exchange.
private func parsedExchange(_ data: Data) -> CentrifugeTokenExchangeResult {
    let text: String = String(decoding: data, as: UTF8.self)
    let parts: [String] = text.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map { (part: Substring) -> String in
        return String(part)
    }
    let token: String = parts.first ?? ""
    let rotated: String? = parts.count > 1 ? parts[1] : nil
    return CentrifugeTokenExchangeResult(token: token, refreshToken: rotated)
}


/// The fake server's answers for a token exchange. The rpc of the exchange answers `exchangeData`. A refresh command is
/// accepted with the expiry given, and when `timeline` is set it is recorded there as "refresh".
private func exchangeServerAnswers(
    server: FakeCentrifugoServer,
    exchangeData: String,
    refreshExpires: Bool,
    ttl: UInt32,
    timeline: LockedBox<[String]>?
) {
    server.onCommand = { (command: Centrifugal_Centrifuge_Protocol_Command) -> Centrifugal_Centrifuge_Protocol_Reply? in
        if command.hasRpc {
            var rpcResult: Centrifugal_Centrifuge_Protocol_RPCResult = Centrifugal_Centrifuge_Protocol_RPCResult()
            rpcResult.data = Data(exchangeData.utf8)
            var reply: Centrifugal_Centrifuge_Protocol_Reply = Centrifugal_Centrifuge_Protocol_Reply()
            reply.id = command.id
            reply.rpc = rpcResult
            return reply
        }
        if command.hasRefresh {
            timeline?.update { (values: inout [String]) in
                values.append("refresh")
            }
            var refreshResult: Centrifugal_Centrifuge_Protocol_RefreshResult = Centrifugal_Centrifuge_Protocol_RefreshResult()
            refreshResult.expires = refreshExpires
            refreshResult.ttl = ttl
            var reply: Centrifugal_Centrifuge_Protocol_Reply = Centrifugal_Centrifuge_Protocol_Reply()
            reply.id = command.id
            reply.refresh = refreshResult
            return reply
        }
        return nil
    }
}


/// A configuration that uses the token exchange.
private func tokenExchangeConfig(_ exchange: CentrifugeTokenExchange) -> CentrifugeClientConfig {
    var config: CentrifugeClientConfig = CentrifugeClientConfig()
    config.tokenExchange = exchange
    return config
}


/// Whether an error is a configuration error of the client.
private func isConfigurationError(_ error: Error) -> Bool {
    guard let centrifugeError: CentrifugeError = error as? CentrifugeError else {
        return false
    }
    if case .configurationError = centrifugeError {
        return true
    }
    return false
}


/// The reply of a refresh command the server accepts without an expiry, or nil for any other command.
private func refreshAnswer(_ command: Centrifugal_Centrifuge_Protocol_Command) -> Centrifugal_Centrifuge_Protocol_Reply? {
    guard command.hasRefresh else {
        return nil
    }
    var reply: Centrifugal_Centrifuge_Protocol_Reply = Centrifugal_Centrifuge_Protocol_Reply()
    reply.id = command.id
    reply.refresh = Centrifugal_Centrifuge_Protocol_RefreshResult()
    return reply
}


/// The fake server's answers for an exchange that pushes the given pushes before its rpc reply, as a server does when a
/// subscription is made while the connection bootstraps. The refresh command is accepted without an expiry.
private func exchangeServerPushesBeforeReply(
    server: FakeCentrifugoServer,
    pushes: [FakeCentrifugoServer.PPush]
) {
    server.onCommand = { [weak server] (command: Centrifugal_Centrifuge_Protocol_Command) -> Centrifugal_Centrifuge_Protocol_Reply? in
        if command.hasRpc {
            for push: FakeCentrifugoServer.PPush in pushes {
                server?.sendPush(push)
            }
            var rpcResult: Centrifugal_Centrifuge_Protocol_RPCResult = Centrifugal_Centrifuge_Protocol_RPCResult()
            rpcResult.data = Data("access-1|refresh-2".utf8)
            var reply: Centrifugal_Centrifuge_Protocol_Reply = Centrifugal_Centrifuge_Protocol_Reply()
            reply.id = command.id
            reply.rpc = rpcResult
            return reply
        }
        return refreshAnswer(command)
    }
}


/// A push that subscribes the channel on the server side.
private func subscribePush(_ channel: String) -> FakeCentrifugoServer.PPush {
    var push: FakeCentrifugoServer.PPush = FakeCentrifugoServer.PPush()
    push.channel = channel
    push.subscribe = Centrifugal_Centrifuge_Protocol_Subscribe()
    return push
}


/// A push that removes the channel's server-side subscription.
private func unsubscribePush(_ channel: String) -> FakeCentrifugoServer.PPush {
    var unsubscribe: Centrifugal_Centrifuge_Protocol_Unsubscribe = Centrifugal_Centrifuge_Protocol_Unsubscribe()
    unsubscribe.code = 0
    unsubscribe.reason = "gone"
    var push: FakeCentrifugoServer.PPush = FakeCentrifugoServer.PPush()
    push.channel = channel
    push.unsubscribe = unsubscribe
    return push
}


/// "ok" or "error", the outcome of a refresh() call.
private func outcomeLabel(_ result: Result<CentrifugeRefreshResult, Error>) -> String {
    switch result {
    case .success:
        return "ok"
    case .failure:
        return "error"
    }
}


/// Records the order of the callbacks the subscribe tests check, and counts the connects.
private final class OrderDelegate: CentrifugeClientDelegate, @unchecked Sendable {
    private let order: LockedBox<[String]>
    private let connected: EventCounter


    init(order: LockedBox<[String]>, connected: EventCounter) {
        self.order = order
        self.connected = connected
    }


    func onConnected(_ client: CentrifugeClient, _ event: CentrifugeConnectedEvent) {
        order.update { (values: inout [String]) in
            values.append("connected")
        }
        connected.record()
    }


    func onSubscribed(_ client: CentrifugeClient, _ event: CentrifugeServerSubscribedEvent) {
        order.update { (values: inout [String]) in
            values.append("subscribed:" + event.channel)
        }
    }


    func onUnsubscribed(_ client: CentrifugeClient, _ event: CentrifugeServerUnsubscribedEvent) {
        order.update { (values: inout [String]) in
            values.append("unsubscribed:" + event.channel)
        }
    }
}


@Suite(.serialized, .timeLimit(.minutes(1)))
final class TokenExchangeTests: @unchecked Sendable {
    private let server: FakeCentrifugoServer
    // A client holds its delegate weakly, so the test keeps every delegate it makes until it ends.
    private var delegates: [ClosureClientDelegate] = []
    private var orderDelegates: [OrderDelegate] = []


    init() throws {
        server = FakeCentrifugoServer()
        try server.start()
    }


    deinit {
        server.stop()
    }


    @Test
    func rotatedRefreshTokenIsStoredBeforeTheRefreshCommand() async throws {
        let timeline: LockedBox<[String]> = LockedBox([])
        exchangeServerAnswers(server: server, exchangeData: "access-1|refresh-2", refreshExpires: false, ttl: 0, timeline: timeline)
        let exchange: TestTokenExchange = TestTokenExchange(stored: "refresh-1", events: timeline, answer: rpcAnswer())
        let connected: Expectation = Expectation("connected")
        let delegate: ClosureClientDelegate = ClosureClientDelegate()
        delegate.onConn = {
            connected.fulfill()
        }
        delegates.append(delegate)
        let client: CentrifugeClient = CentrifugeClient(endpoint: server.url, config: tokenExchangeConfig(exchange), delegate: delegate)

        client.connect()

        await fulfillment(of: [connected], within: 5)
        #expect(timeline.current == ["exchange:refresh-1", "store:refresh-2", "refresh"])
        #expect(exchange.storedToken == "refresh-2")
    }


    @Test
    func storeIsNotCalledForTheSameRefreshToken() async throws {
        let timeline: LockedBox<[String]> = LockedBox([])
        exchangeServerAnswers(server: server, exchangeData: "access-1|refresh-1", refreshExpires: false, ttl: 0, timeline: timeline)
        let exchange: TestTokenExchange = TestTokenExchange(stored: "refresh-1", events: timeline, answer: rpcAnswer())
        let connected: Expectation = Expectation("connected")
        let delegate: ClosureClientDelegate = ClosureClientDelegate()
        delegate.onConn = {
            connected.fulfill()
        }
        delegates.append(delegate)
        let client: CentrifugeClient = CentrifugeClient(endpoint: server.url, config: tokenExchangeConfig(exchange), delegate: delegate)

        client.connect()

        await fulfillment(of: [connected], within: 5)
        #expect(exchange.exchangedTokens == ["refresh-1"])
        #expect(timeline.current.filter { (event: String) -> Bool in
            return event.hasPrefix("store:")
        }.isEmpty)
    }


    @Test
    func renewalDelayStaysInItsWindowOverTwentyRuns() async throws {
        exchangeServerAnswers(server: server, exchangeData: "access-1|refresh-2", refreshExpires: true, ttl: 10, timeline: nil)
        for run in 0 ..< 20 {
            let early: Bool = run % 2 == 1
            // The draws run from the lower end of the window to its upper end: 0 and 1 are the endpoints.
            let draw: Double = Double(run / 2) / 9.0
            let timeline: LockedBox<[String]> = LockedBox([])
            let exchange: TestTokenExchange = TestTokenExchange(stored: "refresh-1", events: timeline, earlyRenewal: early, answer: rpcAnswer())
            let connected: Expectation = Expectation("connected in run \(run)")
            let delegate: ClosureClientDelegate = ClosureClientDelegate()
            delegate.onConn = {
                connected.fulfill()
            }
            delegates.append(delegate)
            let setup: ManualClientSetup = makeManualClient(
                endpoint: server.url,
                config: tokenExchangeConfig(exchange),
                delegate: delegate,
                random: ManualRandom(draw: draw)
            )

            setup.client.connect()

            await fulfillment(of: [connected], within: 5)
            // onConnected runs before the timer of the renewal is armed, on the same queue block.
            await awaitSyncQueue(setup.client)
            let delay: TimeInterval = lastNonLateTimerDelay(setup.scheduler) ?? -1
            let windowStart: Double = early ? 0.6 : 0.7
            #expect(delay >= 10 * windowStart - 1e-6 && delay < 9.0, "run \(run) renews after \(delay) seconds")
            setup.client.disconnect()
        }
    }


    @Test
    func unchangedRefreshTokenIsPresentedAgainOnceInsideTheGrace() async throws {
        let timeline: LockedBox<[String]> = LockedBox([])
        let exchange: TestTokenExchange = TestTokenExchange(stored: "refresh-1", events: timeline, answer: refusingAnswer())
        let disconnected: Expectation = Expectation("disconnected with code 1")
        let delegate: ClosureClientDelegate = ClosureClientDelegate()
        delegate.onDisc = { (event: CentrifugeDisconnectedEvent) in
            if event.code == 1 {
                disconnected.fulfill()
            }
        }
        delegates.append(delegate)
        // The retry comes at the middle of the remaining grace: 15 of the 30 seconds.
        let setup: ManualClientSetup = makeManualClient(
            endpoint: server.url,
            config: tokenExchangeConfig(exchange),
            delegate: delegate,
            random: ManualRandom(draw: 0.5)
        )
        let retryArmed: EventCounter = EventCounter()
        setup.scheduler.observe { (call: ScheduledCall) in
            if !call.lateGrace {
                retryArmed.record()
            }
        }

        setup.client.connect()

        await retryArmed.awaitCount(times: 1)
        #expect(exchange.exchangedTokens == ["refresh-1"])
        await setup.scheduler.advance(by: 15)
        await fulfillment(of: [disconnected], within: 5)
        #expect(exchange.exchangedTokens == ["refresh-1", "refresh-1"])
        #expect(exchange.storedToken == "refresh-1")
        #expect(setup.client.state == .disconnected)
    }


    @Test
    func secondRefusalOfAnUnchangedTokenEndsTheSessionBeforeTheHorizon() async throws {
        let timeline: LockedBox<[String]> = LockedBox([])
        let exchange: TestTokenExchange = TestTokenExchange(stored: "refresh-1", events: timeline, grace: 300, answer: refusingAnswer())
        let disconnected: Expectation = Expectation("disconnected with code 1")
        let delegate: ClosureClientDelegate = ClosureClientDelegate()
        delegate.onDisc = { (event: CentrifugeDisconnectedEvent) in
            if event.code == 1 {
                disconnected.fulfill()
            }
        }
        delegates.append(delegate)
        // The one retry comes at the middle of the 300 seconds of the grace: 150 seconds after the first refusal.
        let setup: ManualClientSetup = makeManualClient(
            endpoint: server.url,
            config: tokenExchangeConfig(exchange),
            delegate: delegate,
            random: ManualRandom(draw: 0.5)
        )
        let retryArmed: EventCounter = EventCounter()
        setup.scheduler.observe { (call: ScheduledCall) in
            if !call.lateGrace {
                retryArmed.record()
            }
        }

        setup.client.connect()

        await retryArmed.awaitCount(times: 1)
        await setup.scheduler.advance(by: 150)
        await fulfillment(of: [disconnected], within: 5)
        #expect(exchange.exchangedTokens == ["refresh-1", "refresh-1"])

        // Nothing is left after the verdict: no further exchange, whatever the clock does.
        await setup.scheduler.advance(by: 600)
        await awaitSyncQueue(setup.client)
        #expect(exchange.exchangedTokens.count == 2)
    }


    @Test
    func tokenExchangeAndTokenGetterAreExclusive() throws {
        let timeline: LockedBox<[String]> = LockedBox([])
        let exchange: TestTokenExchange = TestTokenExchange(stored: nil, events: timeline, answer: refusingAnswer())
        var config: CentrifugeClientConfig = tokenExchangeConfig(exchange)
        config.tokenGetter = { (_: CentrifugeConnectionTokenEvent, completion: @escaping (Result<String, Error>) -> Void) in
            completion(.success("token"))
        }
        var thrown: Error? = nil
        do {
            _ = try CentrifugeClient.create(endpoint: server.url, config: config)
        } catch {
            thrown = error
        }
        guard let error: Error = thrown else {
            Issue.record("create accepted a token exchange together with a token getter")
            return
        }
        #expect(isConfigurationError(error))
    }


    @Test
    func pingDuringBootstrapIsAnsweredWithAPong() async throws {
        server.connectResult.pong = true
        let pongs: EventCounter = EventCounter()
        server.onCommand = { (command: Centrifugal_Centrifuge_Protocol_Command) -> Centrifugal_Centrifuge_Protocol_Reply? in
            // A command with id 0 is the pong: the client answers each server ping with one.
            if command.id == 0 {
                pongs.record()
                return nil
            }
            return refreshAnswer(command)
        }
        let held: LockedBox<((Result<CentrifugeTokenExchangeResult, Error>) -> Void)?> = LockedBox(nil)
        let started: EventCounter = EventCounter()
        let exchange: TestTokenExchange = TestTokenExchange(
            stored: "refresh-1",
            events: LockedBox([]),
            answer: { (_: CentrifugeTokenExchangeEvent, completion: @escaping (Result<CentrifugeTokenExchangeResult, Error>) -> Void) in
                // The exchange stalls until the test completes it, so the ping arrives during the bootstrap.
                held.set(completion)
                started.record()
            }
        )
        let connected: Expectation = Expectation("connected")
        let delegate: ClosureClientDelegate = ClosureClientDelegate()
        delegate.onConn = {
            connected.fulfill()
        }
        delegates.append(delegate)
        let client: CentrifugeClient = CentrifugeClient(endpoint: server.url, config: tokenExchangeConfig(exchange), delegate: delegate)

        client.connect()

        await started.awaitCount(times: 1)
        server.sendReply(FakeCentrifugoServer.PReply())
        await pongs.awaitCount(times: 1)
        held.current?(.success(CentrifugeTokenExchangeResult(token: "access-1", refreshToken: nil)))
        await fulfillment(of: [connected], within: 5)
        #expect(client.state == .connected)
    }


    @Test
    func subscribePushDuringBootstrapIsMergedIntoConnect() async throws {
        let order: LockedBox<[String]> = LockedBox([])
        let connected: EventCounter = EventCounter()
        exchangeServerPushesBeforeReply(server: server, pushes: [subscribePush("news")])
        let delegate: OrderDelegate = OrderDelegate(order: order, connected: connected)
        orderDelegates.append(delegate)
        let exchange: TestTokenExchange = TestTokenExchange(stored: "refresh-1", events: LockedBox([]), answer: rpcAnswer())
        let client: CentrifugeClient = CentrifugeClient(endpoint: server.url, config: tokenExchangeConfig(exchange), delegate: delegate)

        client.connect()

        await connected.awaitCount(times: 1)
        // The subscribed event follows the connected event on the same queue block: a sync point before the check.
        await awaitSyncQueue(client)
        #expect(order.current == ["connected", "subscribed:news"])
    }


    @Test
    func unsubscribePushDuringBootstrapLeavesNoEvent() async throws {
        let order: LockedBox<[String]> = LockedBox([])
        let connected: EventCounter = EventCounter()
        exchangeServerPushesBeforeReply(server: server, pushes: [subscribePush("news"), unsubscribePush("news")])
        let delegate: OrderDelegate = OrderDelegate(order: order, connected: connected)
        orderDelegates.append(delegate)
        let exchange: TestTokenExchange = TestTokenExchange(stored: "refresh-1", events: LockedBox([]), answer: rpcAnswer())
        let client: CentrifugeClient = CentrifugeClient(endpoint: server.url, config: tokenExchangeConfig(exchange), delegate: delegate)

        client.connect()

        await connected.awaitCount(times: 1)
        await awaitSyncQueue(client)
        #expect(order.current == ["connected"])
    }


    @Test
    func explicitRefreshIsNotFailedByALaterRefreshWithToken() async throws {
        exchangeServerAnswers(server: server, exchangeData: "access-1|refresh-2", refreshExpires: false, ttl: 0, timeline: nil)
        let calls: LockedBox<Int> = LockedBox(0)
        let held: LockedBox<((Result<CentrifugeTokenExchangeResult, Error>) -> Void)?> = LockedBox(nil)
        let stalled: EventCounter = EventCounter()
        let immediate: ExchangeAnswer = rpcAnswer()
        let exchange: TestTokenExchange = TestTokenExchange(
            stored: "refresh-1",
            events: LockedBox([]),
            answer: { (event: CentrifugeTokenExchangeEvent, completion: @escaping (Result<CentrifugeTokenExchangeResult, Error>) -> Void) in
                // The bootstrap exchange completes at once. The exchange of refresh() stalls until the test completes it.
                let number: Int = calls.current
                calls.set(number + 1)
                if number == 0 {
                    immediate(event, completion)
                    return
                }
                held.set(completion)
                stalled.record()
            }
        )
        let connected: Expectation = Expectation("connected")
        let delegate: ClosureClientDelegate = ClosureClientDelegate()
        delegate.onConn = {
            connected.fulfill()
        }
        delegates.append(delegate)
        let client: CentrifugeClient = CentrifugeClient(endpoint: server.url, config: tokenExchangeConfig(exchange), delegate: delegate)
        client.connect()
        await fulfillment(of: [connected], within: 5)

        let outcomes: LockedBox<[String]> = LockedBox([])
        let secondSettled: Expectation = Expectation("second refresh settled")
        client.refresh(completion: { (result: Result<CentrifugeRefreshResult, Error>) in
            outcomes.update { (values: inout [String]) in
                values.append(outcomeLabel(result))
            }
        })
        await stalled.awaitCount(times: 1)
        client.refresh(token: "explicit-token", completion: { (result: Result<CentrifugeRefreshResult, Error>) in
            outcomes.update { (values: inout [String]) in
                values.append(outcomeLabel(result))
            }
            secondSettled.fulfill()
        })
        // The exchange of the first call completes after the second call is admitted, which must not fail the first.
        held.current?(.success(CentrifugeTokenExchangeResult(token: "access-2", refreshToken: "refresh-3")))
        await fulfillment(of: [secondSettled], within: 5)
        #expect(outcomes.current == ["ok", "ok"])
        #expect(exchange.storedToken == "refresh-3")
        #expect(server.received().filter(\.hasRefresh).map(\.refresh.token) == ["access-1", "access-2", "explicit-token"])
    }
}
