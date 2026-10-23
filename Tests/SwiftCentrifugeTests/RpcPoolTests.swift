import Foundation
import Testing
@testable import SwiftCentrifuge

// The rpc pool: the admission order, the line bound, the idle close on the fake clock, close, and a
// delegate callback that calls the pool's stats and close. Connections go to the in-process fake server; the idle
// timer runs on the main client's ManualScheduler, so no test sleeps.

/// The outcome of one pool call, filled on the pool's queue and awaited by the test.
private final class PoolOutcome: @unchecked Sendable {
    let done: Expectation
    private let value: LockedBox<Result<CentrifugeRpcResult, Error>?> = LockedBox(nil)


    init(_ description: String) {
        self.done = Expectation(description)
    }


    var error: CentrifugeError? {
        guard case .failure(let error)? = value.current else {
            return nil
        }
        return error as? CentrifugeError
    }


    func record(_ result: Result<CentrifugeRpcResult, Error>) {
        value.set(result)
        done.fulfill()
    }
}


/// A main client, the delegate it keeps weakly (the test holds both), and the scheduler it runs its timers on.
private struct MainHarness {
    let client: CentrifugeClient
    let delegate: CentrifugeClientDelegate
    let scheduler: ManualScheduler
}


/// A short name for the outcome of a call, so a test checks the kind and the code.
private func kindOf(_ error: CentrifugeError?) -> String {
    guard let value: CentrifugeError = error else {
        return "none"
    }
    switch value {
    case .unauthorized:
        return "unauthorized"
    case .clientDisconnected:
        return "clientDisconnected"
    case .connectionClosed:
        return "connectionClosed"
    case .timeout:
        return "timeout"
    case .clientRejected(let code, let message):
        return "clientRejected \(code) \(message)"
    case .configurationError:
        return "configurationError"
    case .replyError(let code, _, _):
        return "replyError \(code)"
    case .replyErrorDetails(let details):
        return "replyErrorDetails \(details.code)"
    default:
        return "other"
    }
}


/// Whether a command is an rpc command.
private func isRpcCommand(_ command: RpcCommand) -> Bool {
    return command.hasRpc
}


/// The reply of a server refusal with the later retry signal, as the server sends it.
private func laterRefusalReply() -> RpcReply {
    return rpcErrorReply(
        code: 111,
        message: "too many requests",
        temporary: true,
        metadata: [rpcRetryMetadataKey: rpcRetryValueLater]
    )
}


/// The reply of a server error that moves the call to the endpoint key "b".
private func moveReply() -> RpcReply {
    return rpcErrorReply(code: 1000, message: "moved", metadata: ["x-example-relocate": "b"])
}


/// The reply of a raw connect command: a connect result with no ping and no pong.
private func connectReply(_ id: UInt32) -> RpcReply {
    var reply: RpcReply = RpcReply()
    reply.id = id
    reply.connect = Centrifugal_Centrifuge_Protocol_ConnectResult()
    return reply
}


@Suite(.serialized, .timeLimit(.minutes(1)))
final class RpcPoolTests: @unchecked Sendable {
    private let fake: FakeRpcServer


    init() throws {
        fake = try FakeRpcServer()
    }


    deinit {
        fake.server.stop()
    }


    // MARK: helpers

    private func poolOptions(
        maxConnectionsPerEndpoint: Int = 2,
        maxQueued: Int = 64,
        idleTimeout: TimeInterval = 60,
        affinityHeader: String? = nil,
        retries: Int = 3
    ) -> CentrifugeRpcPoolOptions {
        let url: String = fake.server.url
        return CentrifugeRpcPoolOptions(
            endpoints: { (_: String) -> [String] in
                return [url]
            },
            affinityHeader: affinityHeader,
            maxConnectionsPerEndpoint: maxConnectionsPerEndpoint,
            maxQueued: maxQueued,
            idleTimeout: idleTimeout,
            retries: retries
        )
    }


    /// A main client on the manual clock and scheduler, connected to the fake server, returned once its connect is
    /// reported. The random source is the test's when one is given.
    private func connectedMain(random: ClientRandom? = nil) async -> MainHarness {
        let delegate: RecordingClientDelegate = RecordingClientDelegate(connected: Expectation("connected"))
        let setup: ManualClientSetup = makeManualClient(
            endpoint: fake.server.url,
            config: CentrifugeClientConfig(),
            delegate: delegate,
            random: random
        )
        setup.client.connect()
        await delegate.awaitConnected(times: 1)
        return MainHarness(client: setup.client, delegate: delegate, scheduler: setup.scheduler)
    }


    /// A main client whose token getter fails with `unauthorized`: its session ends, and it reports the disconnect.
    private func endedMain() async -> MainHarness {
        var config: CentrifugeClientConfig = CentrifugeClientConfig()
        config.tokenGetter = { (_: CentrifugeConnectionTokenEvent, completion: @escaping (Result<String, Error>) -> Void) -> Void in
            completion(.failure(CentrifugeError.unauthorized))
        }
        let disconnected: Expectation = Expectation("session ended")
        let delegate: ClosureClientDelegate = ClosureClientDelegate()
        delegate.onDisc = { (_: CentrifugeDisconnectedEvent) -> Void in
            disconnected.fulfill()
        }
        let setup: ManualClientSetup = makeManualClient(endpoint: fake.server.url, config: config, delegate: delegate)
        setup.client.connect()
        await fulfillment(of: disconnected, within: 5)
        return MainHarness(client: setup.client, delegate: delegate, scheduler: setup.scheduler)
    }


    // MARK: tests

    @Test func poolAdmissionOrderIsClosedEndedDisconnectedThenOptions() async throws {
        let badCall: CentrifugeRpcPoolCallOptions = CentrifugeRpcPoolCallOptions(affinity: "one")

        // A main client that never connected: disconnected, and the call's options are bad too.
        let neverConnected: CentrifugeClient = makeManualClient(endpoint: fake.server.url, config: CentrifugeClientConfig()).client
        let disconnectedPool: CentrifugeRpcPool = CentrifugeRpcPool(main: neverConnected, options: poolOptions())
        let first: PoolOutcome = PoolOutcome("disconnected refusal")
        disconnectedPool.rpc(endpointKey: "", method: "m", data: Data(), options: badCall) { (result: Result<CentrifugeRpcResult, Error>) -> Void in
            first.record(result)
        }
        await fulfillment(of: first.done, within: 5)
        #expect(kindOf(first.error) == "clientDisconnected")

        // A main client whose session ended: ended, and the options are bad too.
        let ended: MainHarness = await endedMain()
        let endedPool: CentrifugeRpcPool = CentrifugeRpcPool(main: ended.client, options: poolOptions())
        let second: PoolOutcome = PoolOutcome("ended refusal")
        endedPool.rpc(endpointKey: "", method: "m", data: Data(), options: badCall) { (result: Result<CentrifugeRpcResult, Error>) -> Void in
            second.record(result)
        }
        await fulfillment(of: second.done, within: 5)
        #expect(kindOf(second.error) == "unauthorized")

        // The same ended client, once its pool is closed: closed comes first.
        let closed: Expectation = Expectation("pool closed")
        endedPool.close {
            closed.fulfill()
        }
        await fulfillment(of: closed, within: 5)
        let third: PoolOutcome = PoolOutcome("closed refusal")
        endedPool.rpc(endpointKey: "", method: "m", data: Data(), options: badCall) { (result: Result<CentrifugeRpcResult, Error>) -> Void in
            third.record(result)
        }
        await fulfillment(of: third.done, within: 5)
        #expect(kindOf(third.error) == "clientRejected 4 rpc pool is closed")

        // A connected main client: the options are checked, and the affinity needs the affinity header.
        let connected: MainHarness = await connectedMain()
        let connectedPool: CentrifugeRpcPool = CentrifugeRpcPool(main: connected.client, options: poolOptions())
        let fourth: PoolOutcome = PoolOutcome("options refusal")
        connectedPool.rpc(endpointKey: "", method: "m", data: Data(), options: badCall) { (result: Result<CentrifugeRpcResult, Error>) -> Void in
            fourth.record(result)
        }
        await fulfillment(of: fourth.done, within: 5)
        #expect(kindOf(fourth.error) == "configurationError")
    }


    @Test func poolCreateRefusesOptionsThatCannotWork() async throws {
        let main: CentrifugeClient = makeManualClient(endpoint: fake.server.url, config: CentrifugeClientConfig()).client
        let bad: CentrifugeRpcPoolOptions = poolOptions(maxConnectionsPerEndpoint: 0)
        var refused: Bool = false
        do {
            _ = try CentrifugeRpcPool.create(main: main, options: bad)
        } catch {
            refused = true
        }
        #expect(refused)

        // The pool made by init fails every call with the same error, at once.
        let pool: CentrifugeRpcPool = CentrifugeRpcPool(main: main, options: bad)
        let outcome: PoolOutcome = PoolOutcome("configuration refusal")
        pool.rpc(endpointKey: "", method: "m", data: Data(), options: CentrifugeRpcPoolCallOptions()) { (result: Result<CentrifugeRpcResult, Error>) -> Void in
            outcome.record(result)
        }
        await fulfillment(of: outcome.done, within: 5)
        #expect(kindOf(outcome.error) == "configurationError")
    }


    @Test func poolRejectsCallsBeyondMaxQueued() async throws {
        fake.setDrop { (command: RpcCommand) -> Bool in
            return command.hasRpc
        }
        let main: MainHarness = await connectedMain()
        let pool: CentrifugeRpcPool = CentrifugeRpcPool(
            main: main.client,
            options: poolOptions(maxConnectionsPerEndpoint: 1, maxQueued: 0)
        )
        // The first call opens the connection and is sent on it; the server never answers it.
        let first: PoolOutcome = PoolOutcome("first call")
        let firstCall: CentrifugeRpcCall = pool.rpc(endpointKey: "", method: "m", data: Data(), options: CentrifugeRpcPoolCallOptions()) { (result: Result<CentrifugeRpcResult, Error>) -> Void in
            first.record(result)
        }
        await fake.awaitArrivals("first rpc") { (command: RpcCommand) -> Bool in
            return command.hasRpc
        }
        // The one connection is full, no other may open, and the line has no room.
        let second: PoolOutcome = PoolOutcome("second call")
        pool.rpc(endpointKey: "", method: "m", data: Data(), options: CentrifugeRpcPoolCallOptions()) { (result: Result<CentrifugeRpcResult, Error>) -> Void in
            second.record(result)
        }
        await fulfillment(of: second.done, within: 5)
        #expect(kindOf(second.error) == "replyError 16")
        #expect(pool.stats() == CentrifugeRpcPoolStats(connections: 1, inflight: 1, queued: 0))

        firstCall.cancel()
        await fulfillment(of: first.done, within: 5)
        #expect(kindOf(first.error) == "replyError 17")
    }


    @Test func idleConnectionIsClosedAfterTheIdleTimeout() async throws {
        let delegate: RecordingClientDelegate = RecordingClientDelegate(connected: Expectation("connected"))
        let setup: ManualClientSetup = makeManualClient(
            endpoint: fake.server.url,
            config: CentrifugeClientConfig(),
            delegate: delegate
        )
        setup.client.connect()
        await delegate.awaitConnected(times: 1)

        let pool: CentrifugeRpcPool = CentrifugeRpcPool(main: setup.client, options: poolOptions(idleTimeout: 1.0))
        let outcome: PoolOutcome = PoolOutcome("call on the pool connection")
        pool.rpc(endpointKey: "", method: "m", data: Data(), options: CentrifugeRpcPoolCallOptions()) { (result: Result<CentrifugeRpcResult, Error>) -> Void in
            outcome.record(result)
        }
        await fulfillment(of: outcome.done, within: 5)
        #expect(kindOf(outcome.error) == "none")
        #expect(pool.stats() == CentrifugeRpcPoolStats(connections: 1, inflight: 0, queued: 0))

        // The connection stays until the idle span has passed on the fake clock, then the idle timer closes it.
        await setup.scheduler.advance(by: 0.5)
        #expect(pool.stats() == CentrifugeRpcPoolStats(connections: 1, inflight: 0, queued: 0))
        await setup.scheduler.advance(by: 0.5)
        #expect(pool.stats() == CentrifugeRpcPoolStats(connections: 0, inflight: 0, queued: 0))
        withExtendedLifetime(delegate) {}
    }


    @Test func closeSettlesWaitingAndInFlightCallsAndRejectsLaterOnes() async throws {
        fake.setDrop { (command: RpcCommand) -> Bool in
            return command.hasRpc
        }
        let main: MainHarness = await connectedMain()
        let pool: CentrifugeRpcPool = CentrifugeRpcPool(
            main: main.client,
            options: poolOptions(maxConnectionsPerEndpoint: 1)
        )
        let inFlight: PoolOutcome = PoolOutcome("call in flight")
        pool.rpc(endpointKey: "", method: "m", data: Data(), options: CentrifugeRpcPoolCallOptions()) { (result: Result<CentrifugeRpcResult, Error>) -> Void in
            inFlight.record(result)
        }
        await fake.awaitArrivals("rpc in flight") { (command: RpcCommand) -> Bool in
            return command.hasRpc
        }
        let waiting: PoolOutcome = PoolOutcome("call waiting for a slot")
        pool.rpc(endpointKey: "", method: "m", data: Data(), options: CentrifugeRpcPoolCallOptions()) { (result: Result<CentrifugeRpcResult, Error>) -> Void in
            waiting.record(result)
        }
        // The pool queue runs in order, so the admission of the waiting call has run once this returns.
        await awaitSyncQueue(main.client)
        #expect(pool.stats() == CentrifugeRpcPoolStats(connections: 1, inflight: 1, queued: 1))

        let closed: Expectation = Expectation("pool closed")
        pool.close {
            closed.fulfill()
        }
        await fulfillment(of: [closed, inFlight.done, waiting.done], within: 5)
        #expect(kindOf(inFlight.error) == "connectionClosed")
        #expect(kindOf(waiting.error) == "replyError 17")
        #expect(pool.stats() == CentrifugeRpcPoolStats(connections: 0, inflight: 0, queued: 0))

        let late: PoolOutcome = PoolOutcome("call after close")
        pool.rpc(endpointKey: "", method: "m", data: Data(), options: CentrifugeRpcPoolCallOptions()) { (result: Result<CentrifugeRpcResult, Error>) -> Void in
            late.record(result)
        }
        await fulfillment(of: late.done, within: 5)
        #expect(kindOf(late.error) == "clientRejected 4 rpc pool is closed")
    }


    @Test func callbackMayCallStatsAndCloseWithoutHanging() async throws {
        let main: MainHarness = await connectedMain()
        let pool: CentrifugeRpcPool = CentrifugeRpcPool(main: main.client, options: poolOptions())
        let answered: Expectation = Expectation("call answered")
        let closed: Expectation = Expectation("close completed")
        pool.rpc(endpointKey: "", method: "m", data: Data(), options: CentrifugeRpcPoolCallOptions()) { (_: Result<CentrifugeRpcResult, Error>) -> Void in
            // The completion runs on the pool's queue: stats, the server time and close must all return here.
            _ = pool.stats()
            _ = main.client.serverTimeMillis()
            pool.close {
                closed.fulfill()
            }
            answered.fulfill()
        }
        await fulfillment(of: [answered, closed], within: 5)
    }


    // MARK: resends

    @Test func poolLostCallOnMessageSizeCloseIsNotResent() async throws {
        let raw: RawWebSocketServer = RawWebSocketServer()
        let arrivals: ArrivalLog<RpcCommand> = ArrivalLog()
        raw.onCommand = { (command: RpcCommand) -> Void in
            if command.hasConnect {
                raw.write(RawWebSocketServer.frame(RawWebSocketServer.payload([connectReply(command.id)])))
            }
            arrivals.record(command)
        }
        try raw.start()
        defer {
            raw.stop()
        }

        let main: MainHarness = await connectedMain()
        let options: CentrifugeRpcPoolOptions = CentrifugeRpcPoolOptions(
            endpoints: { (_: String) -> [String] in
                return [raw.url]
            },
            maxConnectionsPerEndpoint: 1
        )
        let pool: CentrifugeRpcPool = CentrifugeRpcPool(main: main.client, options: options)
        let outcome: PoolOutcome = PoolOutcome("call lost to the size close")
        pool.rpc(endpointKey: "", method: "m", data: Data("A".utf8), options: CentrifugeRpcPoolCallOptions()) { (result: Result<CentrifugeRpcResult, Error>) -> Void in
            outcome.record(result)
        }
        await arrivals.awaitArrivals("rpc sent", count: 1, isRpcCommand)

        // Close code 1009 (message too big): the client ends for good with the size code, and the call is not sent again.
        raw.write(Data([0x88, 0x02, 0x03, 0xF1]))
        await fulfillment(of: outcome.done, within: 5)
        #expect(kindOf(outcome.error) == "connectionClosed")
        #expect(arrivals.all.filter(isRpcCommand).count == 1)
        #expect(pool.stats() == CentrifugeRpcPoolStats(connections: 0, inflight: 0, queued: 0))
    }


    @Test func poolLostCallIsResentAfterTheConnectionReconnects() async throws {
        let aData: Data = Data("A".utf8)
        let dropped: LockedBox<Bool> = LockedBox(false)
        fake.setDrop { (command: RpcCommand) -> Bool in
            guard command.hasRpc && command.rpc.data == aData else {
                return false
            }
            if dropped.current {
                return false
            }
            dropped.set(true)
            return true
        }
        let main: MainHarness = await connectedMain()
        let pool: CentrifugeRpcPool = CentrifugeRpcPool(main: main.client, options: poolOptions(maxConnectionsPerEndpoint: 1))
        let outcome: PoolOutcome = PoolOutcome("call lost with its connection")
        pool.rpc(endpointKey: "", method: "m", data: aData, options: CentrifugeRpcPoolCallOptions()) { (result: Result<CentrifugeRpcResult, Error>) -> Void in
            outcome.record(result)
        }
        await fake.awaitArrivals("A sent", count: 1) { (command: RpcCommand) -> Bool in
            return command.hasRpc && command.rpc.data == aData
        }

        // The transport drops with the call in flight: the pool resends it once the connection is back.
        fake.server.closeConnection()
        await fake.awaitArrivals("A resent", count: 2) { (command: RpcCommand) -> Bool in
            return command.hasRpc && command.rpc.data == aData
        }
        await fulfillment(of: outcome.done, within: 5)
        #expect(kindOf(outcome.error) == "none")
        withExtendedLifetime(main.delegate) {}
    }


    @Test func laterRefusalIsResentAtTheCeilingOfItsDelayAndStopsAtRetries() async throws {
        fake.setAnswer { (command: RpcCommand) -> RpcReply? in
            if command.hasRpc {
                return laterRefusalReply()
            }
            return nil
        }
        // Draw 1 gives the ceiling of the delay: 250 ms for the first resend, as `min(250 ms * 2^0, remaining)`.
        let main: MainHarness = await connectedMain(random: ManualRandom(draw: 1))
        let pool: CentrifugeRpcPool = CentrifugeRpcPool(main: main.client, options: poolOptions(retries: 1))
        let armed: Expectation = Expectation("later resend armed")
        main.scheduler.observe { (call: ScheduledCall) -> Void in
            if call.delay == 0.25 {
                armed.fulfill()
            }
        }
        let outcome: PoolOutcome = PoolOutcome("refused call")
        pool.rpc(endpointKey: "", method: "m", data: Data(), options: CentrifugeRpcPoolCallOptions()) { (result: Result<CentrifugeRpcResult, Error>) -> Void in
            outcome.record(result)
        }
        await fulfillment(of: armed, within: 5)

        // The resend waits on the manual clock: nothing is sent before the clock moves past the delay.
        #expect(fake.allCommands().filter(isRpcCommand).count == 1)
        await main.scheduler.advance(by: 0.25)
        await fake.awaitArrivals("resend after its delay", count: 2, isRpcCommand)

        // The one resend is spent, so the second refusal reaches the call unchanged.
        await fulfillment(of: outcome.done, within: 5)
        #expect(kindOf(outcome.error) == "replyErrorDetails 111")
        #expect(fake.allCommands().filter(isRpcCommand).count == 2)
        withExtendedLifetime(main.delegate) {}
    }


    @Test func laterDelayCountsOnlyLaterResends() async throws {
        let aData: Data = Data("A".utf8)
        let dropped: LockedBox<Bool> = LockedBox(false)
        let refused: LockedBox<Bool> = LockedBox(false)
        // The first send of A is lost with its connection, the second is refused with the later signal, the third is
        // answered.
        fake.setDrop { (command: RpcCommand) -> Bool in
            guard command.hasRpc && command.rpc.data == aData else {
                return false
            }
            if dropped.current {
                return false
            }
            dropped.set(true)
            return true
        }
        fake.setAnswer { (command: RpcCommand) -> RpcReply? in
            guard command.hasRpc && command.rpc.data == aData else {
                return nil
            }
            if refused.current {
                return nil
            }
            refused.set(true)
            return laterRefusalReply()
        }
        // Draw 1 gives the ceiling. The loss resend is not a later resend, so the first later resend is drawn over 250 ms,
        // where counting every resend would draw over 500 ms.
        let random: ManualRandom = ManualRandom(draw: 1)
        let main: MainHarness = await connectedMain(random: random)
        let pool: CentrifugeRpcPool = CentrifugeRpcPool(main: main.client, options: poolOptions(maxConnectionsPerEndpoint: 1))
        let armed: Expectation = Expectation("later resend armed")
        main.scheduler.observe { (call: ScheduledCall) -> Void in
            if call.delay == 0.25 {
                armed.fulfill()
            }
        }
        let outcome: PoolOutcome = PoolOutcome("call with a loss and a later refusal")
        pool.rpc(endpointKey: "", method: "m", data: aData, options: CentrifugeRpcPoolCallOptions()) { (result: Result<CentrifugeRpcResult, Error>) -> Void in
            outcome.record(result)
        }
        await fake.awaitArrivals("A lost", count: 1) { (command: RpcCommand) -> Bool in
            return command.hasRpc && command.rpc.data == aData
        }

        // The transport drops with A in flight: the pool resends it once the connection is back, and that send is refused.
        fake.server.closeConnection()
        await fake.awaitArrivals("A refused", count: 2) { (command: RpcCommand) -> Bool in
            return command.hasRpc && command.rpc.data == aData
        }
        await fulfillment(of: armed, within: 5)
        let firstLaterRange: ClosedRange<UInt64> = 0 ... 250_000_000
        #expect(random.requestedRanges.last == firstLaterRange, "the later delay is drawn over 250 ms * 2^0")

        await main.scheduler.advance(by: 0.25)
        await fake.awaitArrivals("A sent after its delay", count: 3) { (command: RpcCommand) -> Bool in
            return command.hasRpc && command.rpc.data == aData
        }
        await fulfillment(of: outcome.done, within: 5)
        #expect(kindOf(outcome.error) == "none")
        withExtendedLifetime(main.delegate) {}
    }


    @Test func poolLaterResendDelayIsCappedAtTheRemainingDeadline() async throws {
        fake.setAnswer { (command: RpcCommand) -> RpcReply? in
            if command.hasRpc {
                return laterRefusalReply()
            }
            return nil
        }
        // The call's deadline is 0.2 s away, which is less than the 250 ms base of the first later resend: the draw is
        // capped at the remaining 200 ms. With draw 1 the delay is the remaining deadline, 0.2 s.
        let random: ManualRandom = ManualRandom(draw: 1)
        let main: MainHarness = await connectedMain(random: random)
        let pool: CentrifugeRpcPool = CentrifugeRpcPool(main: main.client, options: poolOptions(retries: 3))
        let remainingRange: ClosedRange<UInt64> = 0 ... 200_000_000
        let armed: Expectation = Expectation("later resend armed at the deadline")
        // The admission also arms a 0.2 s timer (the call's deadline, while its connection opens). The later resend's
        // timer is the one armed after its draw, so the observer waits until the draw is on record.
        main.scheduler.observe { (call: ScheduledCall) -> Void in
            if call.delay == 0.2 && random.requestedRanges.contains(remainingRange) {
                armed.fulfill()
            }
        }
        let outcome: PoolOutcome = PoolOutcome("refused call with a short deadline")
        pool.rpc(
            endpointKey: "",
            method: "m",
            data: Data(),
            options: CentrifugeRpcPoolCallOptions(timeout: 0.2)
        ) { (result: Result<CentrifugeRpcResult, Error>) -> Void in
            outcome.record(result)
        }
        await fulfillment(of: armed, within: 5)
        #expect(random.requestedRanges.last == remainingRange, "the later delay is drawn over the remaining 200 ms")

        // The first send is on record at the server, so the count below is final: only the refused send.
        await fake.awaitArrivals("first send refused", count: 1, isRpcCommand)
        // The resend is due at the deadline, so the call times out and nothing else is sent.
        await main.scheduler.advance(by: 0.2)
        await fulfillment(of: outcome.done, within: 5)
        #expect(kindOf(outcome.error) == "timeout")
        #expect(fake.allCommands().filter(isRpcCommand).count == 1)
        withExtendedLifetime(main.delegate) {}
    }


    @Test func poolDoesNotCallTheRerouteHookWhenNoResendIsPossible() async throws {
        fake.setAnswer { (command: RpcCommand) -> RpcReply? in
            if command.hasRpc {
                return moveReply()
            }
            return nil
        }
        let hookCalls: LockedBox<Int> = LockedBox(0)
        let main: MainHarness = await connectedMain()
        var options: CentrifugeRpcPoolOptions = poolOptions(retries: 0)
        options.reroute = { (reply: CentrifugeReplyError) -> String? in
            hookCalls.update { (count: inout Int) -> Void in
                count += 1
            }
            return reply.metadata["x-example-relocate"]
        }
        let pool: CentrifugeRpcPool = CentrifugeRpcPool(main: main.client, options: options)
        let outcome: PoolOutcome = PoolOutcome("refused with no resend left")
        pool.rpc(endpointKey: "a", method: "m", data: Data(), options: CentrifugeRpcPoolCallOptions()) { (result: Result<CentrifugeRpcResult, Error>) -> Void in
            outcome.record(result)
        }
        await fulfillment(of: outcome.done, within: 5)
        // The completion runs after the hook would have run, so the count is final here.
        #expect(kindOf(outcome.error) == "replyErrorDetails 1000")
        #expect(hookCalls.current == 0, "with retries 0 the reroute hook is not called")
        #expect(fake.allCommands().filter(isRpcCommand).count == 1)
        withExtendedLifetime(main.delegate) {}
    }


    @Test func poolCountsWaitingResendsAgainstMaxQueued() async throws {
        let aData: Data = Data("A".utf8)
        let bData: Data = Data("B".utf8)
        let cData: Data = Data("C".utf8)
        // A is refused with the later signal, so it waits for its resend. C is never answered and holds the one slot.
        fake.setDrop { (command: RpcCommand) -> Bool in
            return command.hasRpc && command.rpc.data == cData
        }
        fake.setAnswer { (command: RpcCommand) -> RpcReply? in
            if command.hasRpc && command.rpc.data == aData {
                return laterRefusalReply()
            }
            return nil
        }
        let main: MainHarness = await connectedMain(random: ManualRandom(draw: 1))
        let pool: CentrifugeRpcPool = CentrifugeRpcPool(
            main: main.client,
            options: poolOptions(maxConnectionsPerEndpoint: 1, maxQueued: 1)
        )
        let waiting: Expectation = Expectation("A waits for its resend")
        main.scheduler.observe { (call: ScheduledCall) -> Void in
            if call.delay == 0.25 {
                waiting.fulfill()
            }
        }
        let first: PoolOutcome = PoolOutcome("call A")
        let firstCall: CentrifugeRpcCall = pool.rpc(endpointKey: "", method: "m", data: aData, options: CentrifugeRpcPoolCallOptions()) { (result: Result<CentrifugeRpcResult, Error>) -> Void in
            first.record(result)
        }
        await fulfillment(of: waiting, within: 5)

        // C takes the free slot, so B finds no slot and waits in the line. A's resend wait is not counted toward
        // maxQueued (spec C 2.3), so B is queued, not refused with code 16.
        let second: PoolOutcome = PoolOutcome("call C")
        let secondCall: CentrifugeRpcCall = pool.rpc(endpointKey: "", method: "m", data: cData, options: CentrifugeRpcPoolCallOptions()) { (result: Result<CentrifugeRpcResult, Error>) -> Void in
            second.record(result)
        }
        await fake.awaitArrivals("C sent", count: 1) { (command: RpcCommand) -> Bool in
            return command.hasRpc && command.rpc.data == cData
        }
        let third: PoolOutcome = PoolOutcome("call B")
        let thirdCall: CentrifugeRpcCall = pool.rpc(endpointKey: "", method: "m", data: bData, options: CentrifugeRpcPoolCallOptions()) { (result: Result<CentrifugeRpcResult, Error>) -> Void in
            third.record(result)
        }
        await awaitSyncQueue(main.client)
        #expect(third.error == nil, "B is queued, not refused")
        #expect(pool.stats().queued == 1, "only the line counts toward maxQueued")

        // C ends and frees the slot: B is sent from the line, before A's resend wait ends.
        secondCall.cancel()
        await fulfillment(of: second.done, within: 5)
        await fake.awaitArrivals("B sent", count: 1) { (command: RpcCommand) -> Bool in
            return command.hasRpc && command.rpc.data == bData
        }

        thirdCall.cancel()
        firstCall.cancel()
        await fulfillment(of: [first.done, second.done, third.done], within: 5)
        #expect(kindOf(first.error) == "replyError 17")
        #expect(kindOf(second.error) == "replyError 17")
        #expect(kindOf(third.error) == "replyError 17")
        withExtendedLifetime(main.delegate) {}
    }


    /// A pool released while a call waits in its line still settles the call: the wait timer keeps the pool until the
    /// call's deadline, and the deadline fails the call with `timeout` (spec F15).
    @Test func releasedPoolStillSettlesItsWaitingCalls() async throws {
        fake.setDrop { (command: RpcCommand) -> Bool in
            return command.hasRpc
        }
        let main: MainHarness = await connectedMain(random: ManualRandom(draw: 0))
        var pool: CentrifugeRpcPool? = CentrifugeRpcPool(main: main.client, options: poolOptions(maxConnectionsPerEndpoint: 1))
        // The first call holds the one connection and is never answered.
        let first: PoolOutcome = PoolOutcome("first call")
        _ = pool?.rpc(endpointKey: "", method: "m", data: Data(), options: CentrifugeRpcPoolCallOptions()) { (result: Result<CentrifugeRpcResult, Error>) -> Void in
            first.record(result)
        }
        await fake.awaitArrivals("first rpc") { (command: RpcCommand) -> Bool in
            return command.hasRpc
        }
        // The second call waits in the line for the slot.
        let second: PoolOutcome = PoolOutcome("waiting call")
        _ = pool?.rpc(endpointKey: "", method: "m", data: Data(), options: CentrifugeRpcPoolCallOptions()) { (result: Result<CentrifugeRpcResult, Error>) -> Void in
            second.record(result)
        }
        await awaitSyncQueue(main.client)
        // The app drops its last reference to the pool while the call waits.
        pool = nil
        await main.scheduler.advance(by: 30)
        await fulfillment(of: second.done, within: 5)
        #expect(kindOf(second.error) == "timeout", "a released pool still settles its waiting call")
        withExtendedLifetime(main.delegate) {}
    }


    @Test func poolRoutesMoveBeforeLater() async throws {
        let aData: Data = Data("A".utf8)
        let wData: Data = Data("W".utf8)
        let dropped: LockedBox<Bool> = LockedBox(false)
        // The first send of A gets no answer; the test sends the move itself, once W waits in its line.
        fake.setDrop { (command: RpcCommand) -> Bool in
            guard command.hasRpc && command.rpc.data == aData else {
                return false
            }
            if dropped.current {
                return false
            }
            dropped.set(true)
            return true
        }
        let main: MainHarness = await connectedMain()
        var options: CentrifugeRpcPoolOptions = poolOptions(maxConnectionsPerEndpoint: 1)
        options.reroute = { (reply: CentrifugeReplyError) -> String? in
            return reply.metadata["x-example-relocate"]
        }
        let pool: CentrifugeRpcPool = CentrifugeRpcPool(main: main.client, options: options)

        let first: PoolOutcome = PoolOutcome("call A")
        pool.rpc(endpointKey: "a", method: "m", data: aData, options: CentrifugeRpcPoolCallOptions()) { (result: Result<CentrifugeRpcResult, Error>) -> Void in
            first.record(result)
        }
        await fake.awaitArrivals("A sent", count: 1) { (command: RpcCommand) -> Bool in
            return command.hasRpc && command.rpc.data == aData
        }

        // W waits in the line of key "b": the one connection is full with A.
        let second: PoolOutcome = PoolOutcome("call W")
        pool.rpc(endpointKey: "b", method: "m", data: wData, options: CentrifugeRpcPoolCallOptions()) { (result: Result<CentrifugeRpcResult, Error>) -> Void in
            second.record(result)
        }
        await awaitSyncQueue(main.client)
        #expect(pool.stats() == CentrifugeRpcPoolStats(connections: 1, inflight: 1, queued: 1))

        // The move of A joins the front of key "b", so the slot that frees takes A before W.
        let aCommand: RpcCommand? = fake.allCommands().first(where: { (command: RpcCommand) -> Bool in
            return command.hasRpc && command.rpc.data == aData
        })
        let sent: RpcCommand = try #require(aCommand)
        var refusal: RpcReply = moveReply()
        refusal.id = sent.id
        fake.server.sendReply(refusal)

        await fake.awaitArrivals("A moved and resent", count: 2) { (command: RpcCommand) -> Bool in
            return command.hasRpc && command.rpc.data == aData
        }
        await fake.awaitArrivals("W sent", count: 1) { (command: RpcCommand) -> Bool in
            return command.hasRpc && command.rpc.data == wData
        }
        await fulfillment(of: [first.done, second.done], within: 5)
        #expect(kindOf(first.error) == "none")
        #expect(kindOf(second.error) == "none")
        let order: [String] = fake.allCommands().filter(isRpcCommand).map { (command: RpcCommand) -> String in
            return String(decoding: command.rpc.data, as: UTF8.self)
        }
        #expect(order == ["A", "A", "W"])
    }
}
