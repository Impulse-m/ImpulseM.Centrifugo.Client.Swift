import Foundation
import Testing
@testable import SwiftCentrifuge

// The wait timer of the rpc pool (RpcPool.swift, updateWaitTimer). Its earliest moment is read from heaps of due
// moments, so an event costs no scan of the waiting calls. These tests check the timer's behaviour with many waiting
// calls: they fire in deadline order, each at its own deadline, with one armed timer per moment, and a settled call
// leaves no entry that fires. The arms are counted on the main client's ManualScheduler. Every timeout is a multiple of
// 1/128 s, so the fake clock lands on each deadline exactly.

/// The label of a completion in a log: the outcome of the call.
private func waitLabelOf(_ result: Result<CentrifugeRpcResult, Error>) -> String {
    guard case .failure(let error) = result else {
        return "ok"
    }
    guard let known: CentrifugeError = error as? CentrifugeError else {
        return "other"
    }
    switch known {
    case .timeout:
        return "timeout"
    case .replyError(let code, _, _):
        return "replyError \(code)"
    default:
        return "other"
    }
}


/// The timeout of the waiting call with the given index: 0.5 s plus index/128 s. Each one is exact in binary and in nanoseconds.
private func waitDeadline(_ index: Int) -> TimeInterval {
    return 0.5 + Double(index) / 128.0
}


/// The reply of a server refusal with the later retry signal, as the server sends it (the same as RpcPoolTests).
private func waitLaterRefusalReply() -> RpcReply {
    return rpcErrorReply(
        code: 111,
        message: "too many requests",
        temporary: true,
        metadata: [rpcRetryMetadataKey: rpcRetryValueLater]
    )
}


/// Admits a waiting call. Its completion appends the label and the outcome of the call to the log, on the pool's queue.
@discardableResult
private func admitWaiting(
    _ pool: CentrifugeRpcPool,
    _ label: String,
    timeout: TimeInterval,
    log: LockedBox<[String]>
) -> CentrifugeRpcCall {
    let options: CentrifugeRpcPoolCallOptions = CentrifugeRpcPoolCallOptions(timeout: timeout)
    return pool.rpc(endpointKey: "", method: "m", data: Data(), options: options) { (result: Result<CentrifugeRpcResult, Error>) -> Void in
        log.update { (labels: inout [String]) -> Void in
            labels.append(label + ":" + waitLabelOf(result))
        }
    }
}


/// A main client connected to the fake server, on the manual clock and scheduler.
private struct WaitHarness {
    let client: CentrifugeClient
    let delegate: RecordingClientDelegate
    let scheduler: ManualScheduler
}


@Suite(.serialized, .timeLimit(.minutes(1)))
final class RpcPoolWaitHeapTests: @unchecked Sendable {
    private let fake: FakeRpcServer


    init() throws {
        fake = try FakeRpcServer()
    }


    deinit {
        fake.server.stop()
    }


    // MARK: helpers

    /// A main client connected to the fake server, on the manual clock and scheduler.
    private func connectedMain() async -> WaitHarness {
        let delegate: RecordingClientDelegate = RecordingClientDelegate(connected: Expectation("connected"))
        let setup: ManualClientSetup = makeManualClient(
            endpoint: fake.server.url,
            config: CentrifugeClientConfig(),
            delegate: delegate
        )
        setup.client.connect()
        await delegate.awaitConnected(times: 1)
        return WaitHarness(client: setup.client, delegate: delegate, scheduler: setup.scheduler)
    }


    /// A pool of one connection that takes one call at a time, with that call in flight. The fake server never answers
    /// it, so every later call waits in the line. The in-flight call is returned so the test can cancel it.
    private func startFullPool(_ main: WaitHarness) async -> (CentrifugeRpcPool, CentrifugeRpcCall) {
        let url: String = fake.server.url
        let options: CentrifugeRpcPoolOptions = CentrifugeRpcPoolOptions(
            endpoints: { (_: String) -> [String] in
                return [url]
            },
            maxConnectionsPerEndpoint: 1,
            maxInflightPerConnection: 1
        )
        let pool: CentrifugeRpcPool = CentrifugeRpcPool(main: main.client, options: options)
        let holding: CentrifugeRpcCall = pool.rpc(
            endpointKey: "",
            method: "m",
            data: Data(),
            options: CentrifugeRpcPoolCallOptions()
        ) { (_: Result<CentrifugeRpcResult, Error>) -> Void in
        }
        await fake.awaitArrivals("holding rpc") { (command: RpcCommand) -> Bool in
            return command.hasRpc
        }
        return (pool, holding)
    }


    /// Counts the timers that the pool arms on the main client's scheduler. The pool's wait timer is one with late grace;
    /// the connections' idle timers are not, and nothing else arms a timer of the main client in these tests.
    private func countArms(_ main: WaitHarness) -> LockedBox<Int> {
        let arms: LockedBox<Int> = LockedBox<Int>(0)
        main.scheduler.observe { (call: ScheduledCall) -> Void in
            guard call.lateGrace else {
                return
            }
            arms.update { (count: inout Int) -> Void in
                count += 1
            }
        }
        return arms
    }


    // MARK: tests

    @Test func manyWaitingCallsFireInDeadlineOrderOnOneArmedTimer() async throws {
        fake.setDrop { (command: RpcCommand) -> Bool in
            return command.hasRpc
        }
        let main: WaitHarness = await connectedMain()
        let (pool, holding): (CentrifugeRpcPool, CentrifugeRpcCall) = await startFullPool(main)
        let arms: LockedBox<Int> = countArms(main)
        let fired: LockedBox<[String]> = LockedBox<[String]>([])
        let waiting: Int = 20

        // The waiting calls are admitted from the latest deadline to the earliest, so every admission moves the earliest moment.
        for index: Int in (0 ..< waiting).reversed() {
            admitWaiting(pool, "\(index)", timeout: waitDeadline(index), log: fired)
        }
        await awaitSyncQueue(main.client)
        #expect(arms.current == waiting, "each admission moves the earliest moment once, so it arms the timer once")
        #expect(fired.current.isEmpty, "no waiting call is due before its deadline")

        // The clock moves from deadline to deadline, so each step fires exactly the next call.
        var expected: [String] = []
        for index: Int in 0 ..< waiting {
            let step: TimeInterval = index == 0 ? waitDeadline(0) : 1.0 / 128.0
            await main.scheduler.advance(by: step)
            expected.append("\(index):timeout")
            #expect(fired.current == expected, "call \(index) fires at its own deadline, after the earlier ones")
        }
        // Each firing arms the timer for the next deadline. The last firing has no next deadline to arm.
        #expect(arms.current == 2 * waiting - 1, "one arm per firing, except the last")

        holding.cancel()
        await awaitSyncQueue(main.client)
        withExtendedLifetime(main.delegate) {}
    }


    @Test func settledWaitingCallLeavesNoDueEntryThatFires() async throws {
        fake.setDrop { (command: RpcCommand) -> Bool in
            return command.hasRpc
        }
        let main: WaitHarness = await connectedMain()
        let (pool, holding): (CentrifugeRpcPool, CentrifugeRpcCall) = await startFullPool(main)
        let arms: LockedBox<Int> = countArms(main)
        let fired: LockedBox<[String]> = LockedBox<[String]>([])

        // Three waiting calls: C at 1.0 s, B at 0.75 s and A at 0.5 s. A is the earliest.
        admitWaiting(pool, "C", timeout: waitDeadline(64), log: fired)
        admitWaiting(pool, "B", timeout: waitDeadline(32), log: fired)
        let callA: CentrifugeRpcCall = admitWaiting(pool, "A", timeout: waitDeadline(0), log: fired)
        await awaitSyncQueue(main.client)
        #expect(arms.current == 3, "each admission moves the earliest moment once")

        // A settles now. Its entry stays in the heap, but the timer moves on to B at once.
        callA.cancel()
        await awaitSyncQueue(main.client)
        #expect(fired.current == ["A:replyError 17"], "A settles with the cancel")
        #expect(arms.current == 4, "the cancel moves the timer to B, once")

        // A's old deadline passes. Its entry does not stand, so nothing is due and the timer does not run.
        await main.scheduler.advance(by: waitDeadline(0))
        #expect(fired.current == ["A:replyError 17"], "nothing fires at the deadline of the settled call")
        #expect(arms.current == 4, "the entry of the settled call arms nothing")

        // B's deadline: B times out, and the timer moves on to C.
        await main.scheduler.advance(by: waitDeadline(32) - waitDeadline(0))
        #expect(fired.current == ["A:replyError 17", "B:timeout"], "B times out at its own deadline")
        #expect(arms.current == 5, "B's firing arms the timer for C, once")

        // C's deadline: C times out, and nothing is left to arm.
        await main.scheduler.advance(by: waitDeadline(64) - waitDeadline(32))
        #expect(fired.current == ["A:replyError 17", "B:timeout", "C:timeout"], "C times out last")
        #expect(arms.current == 5, "C's firing leaves nothing to arm")

        holding.cancel()
        await awaitSyncQueue(main.client)
        withExtendedLifetime(main.delegate) {}
    }


    @Test func settledCallsBehindALongWaitingCallLeaveABoundedDueHeap() async throws {
        fake.setDrop { (command: RpcCommand) -> Bool in
            return command.hasRpc
        }
        let main: WaitHarness = await connectedMain()
        let (pool, holding): (CentrifugeRpcPool, CentrifugeRpcCall) = await startFullPool(main)
        let fired: LockedBox<[String]> = LockedBox<[String]>([])

        // One call waits for a long time. Each later call is cancelled at once, so each leaves an entry behind.
        admitWaiting(pool, "long", timeout: 60, log: fired)
        for index: Int in 0 ..< 200 {
            let call: CentrifugeRpcCall = admitWaiting(pool, "\(index)", timeout: waitDeadline(index), log: fired)
            call.cancel()
        }
        await awaitSyncQueue(main.client)
        let entries: Int = main.client.syncQueue.sync { () -> Int in
            return pool.dueEntryCount
        }
        #expect(fired.current.count == 200, "every cancelled call settles")
        #expect(entries <= 2, "the heap keeps about one entry per waiting call, not one per settled call")

        holding.cancel()
        await awaitSyncQueue(main.client)
        withExtendedLifetime(main.delegate) {}
    }


    @Test func aLaterResendArmsTheTimerOnceAtItsDelay() async throws {
        fake.setAnswer { (command: RpcCommand) -> RpcReply? in
            if command.hasRpc {
                return waitLaterRefusalReply()
            }
            return nil
        }
        let main: WaitHarness = await connectedMain()
        let url: String = fake.server.url
        let options: CentrifugeRpcPoolOptions = CentrifugeRpcPoolOptions(
            endpoints: { (_: String) -> [String] in
                return [url]
            },
            retries: 1
        )
        let pool: CentrifugeRpcPool = CentrifugeRpcPool(main: main.client, options: options)
        let armed: Expectation = Expectation("later resend armed")
        let arms: LockedBox<Int> = LockedBox<Int>(0)
        main.scheduler.observe { (call: ScheduledCall) -> Void in
            guard call.lateGrace else {
                return
            }
            if arms.current == 0 {
                armed.fulfill()
            }
            arms.update { (count: inout Int) -> Void in
                count += 1
            }
        }
        pool.rpc(endpointKey: "", method: "m", data: Data(), options: CentrifugeRpcPoolCallOptions()) { (_: Result<CentrifugeRpcResult, Error>) -> Void in
        }
        await fulfillment(of: armed, within: 5)
        await awaitSyncQueue(main.client)
        #expect(arms.current == 1, "the refusal arms the timer once, for the end of the resend's delay")
        withExtendedLifetime(main.delegate) {}
    }
}
