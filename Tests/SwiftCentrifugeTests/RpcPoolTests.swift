import Foundation
import Testing
@testable import SwiftCentrifuge

// The rpc pool of this slice: the admission order, the line bound, the idle close on the fake clock, close, and a
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


/// A main client and the delegate it keeps weakly: the test holds both.
private struct MainHarness {
    let client: CentrifugeClient
    let delegate: CentrifugeClientDelegate
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
    default:
        return "other"
    }
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
        affinityHeader: String? = nil
    ) -> CentrifugeRpcPoolOptions {
        let url: String = fake.server.url
        return CentrifugeRpcPoolOptions(
            endpoints: { (_: String) -> [String] in
                return [url]
            },
            affinityHeader: affinityHeader,
            maxConnectionsPerEndpoint: maxConnectionsPerEndpoint,
            maxQueued: maxQueued,
            idleTimeout: idleTimeout
        )
    }


    /// A main client connected to the fake server, returned once its connect is reported.
    private func connectedMain() async -> MainHarness {
        let delegate: RecordingClientDelegate = RecordingClientDelegate(connected: Expectation("connected"))
        let setup: ManualClientSetup = makeManualClient(
            endpoint: fake.server.url,
            config: CentrifugeClientConfig(),
            delegate: delegate
        )
        setup.client.connect()
        await delegate.awaitConnected(times: 1)
        return MainHarness(client: setup.client, delegate: delegate)
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
        return MainHarness(client: setup.client, delegate: delegate)
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
        await setup.scheduler.advance(by: 1.0)
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
}
