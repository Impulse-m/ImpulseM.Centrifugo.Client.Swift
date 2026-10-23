import Foundation
import Testing
@testable import SwiftCentrifuge

// The tracked rpc calls: tracked and plain calls, cancels, the capability, the bound and the retry
// signals. The clock, the random source and the timers are the test seams: every timer runs when a
// test advances the ManualScheduler, and no test sleeps. Each test first drains the client's queue
// (`drain`), so a timer that the client arms on its queue is in place before the advance.

private let rpcTestInstance: String = "rpc-instance-0123456789abcdef"


/// The outcome of one call, filled on the client's queue and awaited by the test.
private final class CallOutcome: @unchecked Sendable {
    let done: Expectation = Expectation("rpc completed")
    private let value: LockedBox<Result<CentrifugeRpcResult, Error>?> = LockedBox(nil)


    var result: Result<CentrifugeRpcResult, Error>? {
        return value.current
    }


    func record(_ result: Result<CentrifugeRpcResult, Error>) {
        value.set(result)
        done.fulfill()
    }
}


/// A client connected to the fake server, with the seams of the test.
private struct Harness {
    let client: CentrifugeClient
    let scheduler: ManualScheduler
    let clock: ManualClock
    let delegate: RecordingClientDelegate
}


/// A weak handle on a client, so a test can check that the client was released.
private struct WeakClient {
    weak var client: CentrifugeClient?
}


@Suite(.serialized, .timeLimit(.minutes(1)))
final class RpcTrackerTests: @unchecked Sendable {
    private let fake: FakeRpcServer


    init() throws {
        fake = try FakeRpcServer()
    }


    deinit {
        fake.server.stop()
    }


    // MARK: helpers

    private func capabilityResult(_ capable: Bool) -> FakeCentrifugoServer.PConnectResult {
        var result: FakeCentrifugoServer.PConnectResult = FakeCentrifugoServer.PConnectResult()
        result.client = "fake-client"
        result.version = "0.0.0"
        result.ping = 25
        result.flag = capable ? ConnectFlags.rpcOptions : 0
        return result
    }


    private func instanceConfig(
        timeout: Double = 5,
        maxPendingRpc: Int = 32,
        instance: String? = rpcTestInstance
    ) -> CentrifugeClientConfig {
        var config: CentrifugeClientConfig = CentrifugeClientConfig()
        config.timeout = timeout
        config.maxPendingRpc = maxPendingRpc
        config.instance = instance
        return config
    }


    /// Connects a client to the fake server and returns once its connect is reported.
    private func connectedHarness(
        capable: Bool = true,
        config: CentrifugeClientConfig? = nil,
        random: ManualRandom = ManualRandom()
    ) async -> Harness {
        fake.server.connectResult = capabilityResult(capable)
        let delegate: RecordingClientDelegate = RecordingClientDelegate(connected: Expectation("connected"))
        let setup: ManualClientSetup = makeManualClient(
            endpoint: fake.server.url,
            config: config ?? instanceConfig(),
            delegate: delegate,
            random: random
        )
        setup.client.connect()
        await delegate.awaitConnected(times: 1)
        return Harness(client: setup.client, scheduler: setup.scheduler, clock: setup.clock, delegate: delegate)
    }


    /// Returns once every block the client enqueued before this call has run, so a timer the client
    /// arms on its queue is in place.
    private func drain(_ harness: Harness) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            harness.client.syncQueue.async {
                continuation.resume()
            }
        }
    }


    /// Returns once the client's queue has run every block submitted before this call.
    private func drainQueue(_ client: CentrifugeClient) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            client.syncQueue.async {
                continuation.resume()
            }
        }
    }


    private func startCall(
        _ client: CentrifugeClient,
        options: CentrifugeRpcOptions = CentrifugeRpcOptions()
    ) -> (call: CentrifugeRpcCall, outcome: CallOutcome) {
        let outcome: CallOutcome = CallOutcome()
        let call: CentrifugeRpcCall = client.rpc(method: "method", data: Data(), options: options) { (result: Result<CentrifugeRpcResult, Error>) in
            outcome.record(result)
        }
        return (call, outcome)
    }


    /// The rpc commands of the calls (not the cancels), in arrival order.
    private func callCommands() -> [RpcCommand] {
        return fake.allCommands().filter { (command: RpcCommand) -> Bool in
            return command.hasRpc && command.rpc.cancel == 0
        }
    }


    /// The cancel commands, in arrival order.
    private func cancelCommands() -> [RpcCommand] {
        return fake.allCommands().filter { (command: RpcCommand) -> Bool in
            return command.hasRpc && command.rpc.cancel != 0
        }
    }


    private func succeeded(_ result: Result<CentrifugeRpcResult, Error>?) -> Bool {
        if case .success? = result {
            return true
        }
        return false
    }


    /// The error of a failed call, or nil.
    private func failure(_ result: Result<CentrifugeRpcResult, Error>?) -> CentrifugeError? {
        guard case .failure(let error)? = result else {
            return nil
        }
        return error as? CentrifugeError
    }


    /// The data of a successful call, or nil.
    private func resultData(_ result: Result<CentrifugeRpcResult, Error>?) -> Data? {
        guard case .success(let value)? = result else {
            return nil
        }
        return value.data
    }


    /// Drops the connection and returns once the client has reported the disconnect and run the
    /// rest of its disconnect path, so the reconnect it scheduled is in place.
    private func dropConnection(_ harness: Harness) async {
        let before: Int = harness.delegate.connectingEvents
        fake.server.closeConnection()
        await harness.delegate.awaitConnecting(times: before + 1)
        await drain(harness)
    }


    /// Drops the connection and runs the reconnect that the client scheduled.
    private func reconnect(_ harness: Harness, connectsSoFar: Int) async {
        await dropConnection(harness)
        await harness.scheduler.advance(by: 1.5)
        await harness.delegate.awaitConnected(times: connectsSoFar + 1)
    }


    // MARK: tracked calls

    @Test func repliesAreAckedWithTheNextCall() async throws {
        let harness: Harness = await connectedHarness()
        let first: (call: CentrifugeRpcCall, outcome: CallOutcome) = startCall(harness.client)
        await fulfillment(of: first.outcome.done, within: 5)
        let second: (call: CentrifugeRpcCall, outcome: CallOutcome) = startCall(harness.client)
        await fulfillment(of: second.outcome.done, within: 5)

        let sent: [RpcCommand] = callCommands()
        try #require(sent.count == 2)
        #expect(sent[0].rpc.ack.isEmpty, "nothing was acked before the first call")
        #expect(sent[1].rpc.ack == [sent[0].rpc.msgID], "the next command carries the ack of the first reply")
    }


    @Test func droppedCallRunsOnceAndTheResendGetsTheSameReply() async throws {
        let harness: Harness = await connectedHarness()
        let dropping: LockedBox<Bool> = LockedBox(true)
        // The msg_ids of the calls the server ran: a dropped command is never run.
        let executions: LockedBox<[UInt64]> = LockedBox([])
        fake.setDrop { (command: RpcCommand) -> Bool in
            return command.hasRpc && dropping.current
        }
        fake.setAnswer { (command: RpcCommand) -> RpcReply? in
            guard command.hasRpc, command.rpc.cancel == 0 else {
                return nil
            }
            executions.update { (values: inout [UInt64]) in
                values.append(command.rpc.msgID)
            }
            var result: Centrifugal_Centrifuge_Protocol_RPCResult = Centrifugal_Centrifuge_Protocol_RPCResult()
            result.data = Data("once".utf8)
            var reply: RpcReply = RpcReply()
            reply.rpc = result
            return reply
        }
        let call: (call: CentrifugeRpcCall, outcome: CallOutcome) = startCall(harness.client)
        await fake.awaitArrivals("first call arrived") { (command: RpcCommand) -> Bool in
            return command.hasRpc && command.rpc.msgID != 0
        }

        dropping.set(false)
        await reconnect(harness, connectsSoFar: 1)
        await fulfillment(of: call.outcome.done, within: 5)

        let sent: [RpcCommand] = callCommands()
        try #require(sent.count == 2)
        #expect(sent[0].rpc.msgID == sent[1].rpc.msgID, "the resend keeps the msg_id")
        #expect(sent[1].rpc.retransmit, "the resend is marked as a retransmit")
        #expect(sent[0].id != sent[1].id, "the resend takes a fresh command id")
        #expect(executions.current == [sent[1].rpc.msgID], "the server ran the call once, on the resend")
        #expect(resultData(call.outcome.result) == Data("once".utf8), "the resend gets the reply of that run")
    }


    /// The first call is refused with new_msg_id on the first reconnect, so its resend gets a msg_id above
    /// the second call's. Admission order and msg_id order then differ, and the resends must follow the
    /// msg_id. Every other command is dropped; the refusal is the only reply.
    @Test func lostCallsAreSentAgainInMsgIdOrder() async throws {
        let harness: Harness = await connectedHarness()
        let dropping: LockedBox<Bool> = LockedBox(true)
        let refusing: LockedBox<Bool> = LockedBox(false)
        let refused: LockedBox<Bool> = LockedBox(false)
        fake.setDrop { (command: RpcCommand) -> Bool in
            guard command.hasRpc && command.rpc.cancel == 0 else {
                return false
            }
            if refusing.current && !refused.current {
                return false
            }
            return dropping.current
        }
        let metadata: [String: String] = [rpcRetryMetadataKey: rpcRetryValueNewMsgID]
        fake.setAnswer { (command: RpcCommand) -> RpcReply? in
            guard command.hasRpc, command.rpc.cancel == 0, refusing.current, !refused.current else {
                return nil
            }
            refused.set(true)
            return self.errorReply(code: 107, metadata: metadata)
        }
        let first: (call: CentrifugeRpcCall, outcome: CallOutcome) = startCall(harness.client)
        let second: (call: CentrifugeRpcCall, outcome: CallOutcome) = startCall(harness.client)
        await fake.awaitArrivals("two calls arrived", count: 2) { (command: RpcCommand) -> Bool in
            return command.hasRpc && command.rpc.cancel == 0
        }

        refusing.set(true)
        await reconnect(harness, connectsSoFar: 1)
        // The first call is resent with its msg_id, refused, and sent again with a new one: 5 arrivals.
        await fake.awaitArrivals("the refused call was sent again", count: 5) { (command: RpcCommand) -> Bool in
            return command.hasRpc && command.rpc.cancel == 0
        }

        dropping.set(false)
        refusing.set(false)
        await reconnect(harness, connectsSoFar: 2)
        await fulfillment(of: first.outcome.done, within: 5)
        await fulfillment(of: second.outcome.done, within: 5)

        let sent: [RpcCommand] = callCommands()
        try #require(sent.count == 7, "two first sends, two resends, the new id of the refused call, and two last resends")
        let refusedNewID: UInt64 = sent[4].rpc.msgID
        try #require(sent[1].rpc.msgID < refusedNewID, "the second call's msg_id is below the refused call's new one")
        let lastResends: [RpcCommand] = Array(sent.suffix(2))
        #expect(lastResends[0].rpc.msgID == sent[1].rpc.msgID, "the second call is resent first, by msg_id")
        #expect(lastResends[1].rpc.msgID == refusedNewID, "the refused call is resent after it, by msg_id")
        #expect(lastResends[0].rpc.msgID < lastResends[1].rpc.msgID, "the resends go out in msg_id order")
        let resentWithRetransmit: Bool = lastResends.allSatisfy { (command: RpcCommand) -> Bool in
            return command.rpc.retransmit
        }
        #expect(resentWithRetransmit)
        let commandIds: Set<UInt32> = Set(sent.map { (command: RpcCommand) -> UInt32 in
            return command.id
        })
        #expect(commandIds.count == 7, "every write takes a fresh command id")
    }


    /// A call that never reached the wire (admitted while the connection was down, so it was never written)
    /// goes out as a first send with its msg_id when the connection returns. The tracker has no batch
    /// concept, so a batch dropped at a disconnect has no separate path in Swift; this covers admission
    /// during a reconnect, which is the case that path would have covered.
    @Test func aCallDroppedFromTheBatchBeforeItsWriteIsSentAsAFirstSend() async throws {
        let harness: Harness = await connectedHarness()
        await dropConnection(harness)
        // The call is admitted while the client waits for its connection: it is not written yet.
        let call: (call: CentrifugeRpcCall, outcome: CallOutcome) = startCall(harness.client)
        await drain(harness)
        await harness.scheduler.advance(by: 1.5)
        await harness.delegate.awaitConnected(times: 2)
        await fulfillment(of: call.outcome.done, within: 5)

        let sent: [RpcCommand] = callCommands()
        try #require(sent.count == 1)
        #expect(!sent[0].rpc.retransmit, "a call that was never written is a first send")
        #expect(sent[0].rpc.msgID != 0)
        #expect(succeeded(call.outcome.result))
    }


    // MARK: cancel

    @Test func unansweredCancelIsDroppedAfterTheTimeoutAndNotSentAgain() async {
        let harness: Harness = await connectedHarness(config: instanceConfig(timeout: 1))
        fake.setDrop { (command: RpcCommand) -> Bool in
            return command.hasRpc
        }
        let call: (call: CentrifugeRpcCall, outcome: CallOutcome) = startCall(harness.client)
        await fake.awaitArrivals("call arrived") { (command: RpcCommand) -> Bool in
            return command.hasRpc && command.rpc.cancel == 0
        }
        await drain(harness)
        call.call.cancel()
        await fake.awaitArrivals("cancel arrived") { (command: RpcCommand) -> Bool in
            return command.hasRpc && command.rpc.cancel != 0
        }
        await fulfillment(of: call.outcome.done, within: 5)
        if case CentrifugeError.replyError(let code, _, _)? = failure(call.outcome.result) {
            #expect(code == 17)
        } else {
            Issue.record("expected cancelled (17), got \(String(describing: call.outcome.result))")
        }

        // The cancel gets no reply: after one call timeout its callbacks are dropped.
        await drain(harness)
        await harness.scheduler.advance(by: 1.1)
        await reconnect(harness, connectsSoFar: 1)
        #expect(cancelCommands().count == 1, "an unanswered cancel is not sent again")
        #expect(callCommands().count == 1, "a cancelled call is not resent")
    }


    @Test func deadlineOfASentCallCancelsItOnTheServer() async {
        let harness: Harness = await connectedHarness(config: instanceConfig(timeout: 1))
        fake.setDrop { (command: RpcCommand) -> Bool in
            return command.hasRpc && command.rpc.cancel == 0
        }
        await drain(harness)
        let armedBeforeCall: Int = harness.scheduler.scheduledCalls.count
        let call: (call: CentrifugeRpcCall, outcome: CallOutcome) = startCall(harness.client)
        await fake.awaitArrivals("call arrived") { (command: RpcCommand) -> Bool in
            return command.hasRpc && command.rpc.cancel == 0
        }
        await drain(harness)
        #expect(harness.scheduler.scheduledCalls.count - armedBeforeCall == 1, "the call arms the tracker's one timer, and no timer of its own")
        await harness.scheduler.advance(by: 1.1)
        await fulfillment(of: call.outcome.done, within: 5)
        if case CentrifugeError.timeout? = failure(call.outcome.result) {
        } else {
            Issue.record("expected timeout, got \(String(describing: call.outcome.result))")
        }

        let msgID: UInt64 = callCommands().first?.rpc.msgID ?? 0
        await fake.awaitArrivals("cancel arrived") { (command: RpcCommand) -> Bool in
            return command.hasRpc && command.rpc.cancel == msgID
        }
        #expect(msgID != 0)
        #expect(cancelCommands().count == 1, "the deadline of a sent call sends one cancel")
    }


    /// Calls with one timeout share the tracker's timer: admitting more of them does not arm another.
    @Test func theTimerIsNotArmedAgainForEachCall() async {
        let harness: Harness = await connectedHarness(config: instanceConfig(timeout: 5))
        fake.setDrop { (command: RpcCommand) -> Bool in
            return command.hasRpc && command.rpc.cancel == 0
        }
        _ = startCall(harness.client)
        await drain(harness)
        let armedForFirst: Int = harness.scheduler.scheduledCalls.count
        for _ in 0 ..< 9 {
            _ = startCall(harness.client)
        }
        await drain(harness)
        await fake.awaitArrivals("ten calls arrived", count: 10) { (command: RpcCommand) -> Bool in
            return command.hasRpc && command.rpc.cancel == 0
        }
        #expect(harness.scheduler.scheduledCalls.count == armedForFirst, "ten calls with one timeout arm the timer once")
    }


    @Test func abortOfASentCallSendsACancelAndRejectsCancelled() async {
        let harness: Harness = await connectedHarness()
        fake.setDrop { (command: RpcCommand) -> Bool in
            return command.hasRpc && command.rpc.cancel == 0
        }
        let call: (call: CentrifugeRpcCall, outcome: CallOutcome) = startCall(harness.client)
        await fake.awaitArrivals("call arrived") { (command: RpcCommand) -> Bool in
            return command.hasRpc && command.rpc.cancel == 0
        }
        call.call.cancel()
        await fulfillment(of: call.outcome.done, within: 5)
        if case CentrifugeError.replyError(let code, _, _)? = failure(call.outcome.result) {
            #expect(code == 17)
        } else {
            Issue.record("expected cancelled (17), got \(String(describing: call.outcome.result))")
        }
        await fake.awaitArrivals("cancel arrived") { (command: RpcCommand) -> Bool in
            return command.hasRpc && command.rpc.cancel != 0
        }
        #expect(cancelCommands().count == 1)
    }


    @Test func cancelsLostWithTheTransportAreCappedAtTheBound() async {
        let harness: Harness = await connectedHarness(config: instanceConfig(maxPendingRpc: 2))
        let dropping: LockedBox<Bool> = LockedBox(true)
        fake.setDrop { (command: RpcCommand) -> Bool in
            return command.hasRpc && dropping.current
        }
        let first: (call: CentrifugeRpcCall, outcome: CallOutcome) = startCall(harness.client)
        let second: (call: CentrifugeRpcCall, outcome: CallOutcome) = startCall(harness.client)
        await fake.awaitArrivals("two calls arrived", count: 2) { (command: RpcCommand) -> Bool in
            return command.hasRpc && command.rpc.cancel == 0
        }
        // Each cancel frees its slot before the next call is admitted, so the bound of two holds.
        first.call.cancel()
        let third: (call: CentrifugeRpcCall, outcome: CallOutcome) = startCall(harness.client)
        second.call.cancel()
        let fourth: (call: CentrifugeRpcCall, outcome: CallOutcome) = startCall(harness.client)
        third.call.cancel()
        await fake.awaitArrivals("three cancels arrived", count: 3) { (command: RpcCommand) -> Bool in
            return command.hasRpc && command.rpc.cancel != 0
        }
        let lost: [UInt64] = cancelCommands().map { (command: RpcCommand) -> UInt64 in command.rpc.cancel }

        dropping.set(false)
        await reconnect(harness, connectsSoFar: 1)
        await fake.awaitArrivals("pending cancels sent", count: 5) { (command: RpcCommand) -> Bool in
            return command.hasRpc && command.rpc.cancel != 0
        }
        let cancels: [RpcCommand] = cancelCommands()
        #expect(cancels.count == 5)
        let afterReconnect: [UInt64] = Array(cancels.suffix(2)).map { (command: RpcCommand) -> UInt64 in command.rpc.cancel }
        #expect(lost.count == 3)
        #expect(afterReconnect == Array(lost.suffix(2)), "only the newest two cancels are kept")
        await fulfillment(of: fourth.outcome.done, within: 5)
        #expect(succeeded(fourth.outcome.result))
    }


    // MARK: capability

    @Test func legacyServerGetsPlainCallsAndRejectsHeaders() async {
        let harness: Harness = await connectedHarness(capable: false)
        let plain: (call: CentrifugeRpcCall, outcome: CallOutcome) = startCall(harness.client)
        await fulfillment(of: plain.outcome.done, within: 5)
        #expect(succeeded(plain.outcome.result))

        let headers: CentrifugeRpcOptions = CentrifugeRpcOptions(headers: ["x-trace": "1"])
        let withHeaders: (call: CentrifugeRpcCall, outcome: CallOutcome) = startCall(harness.client, options: headers)
        await fulfillment(of: withHeaders.outcome.done, within: 5)
        if case CentrifugeError.replyError(let code, _, _)? = failure(withHeaders.outcome.result) {
            #expect(code == 15)
        } else {
            Issue.record("expected unsupported (15), got \(String(describing: withHeaders.outcome.result))")
        }

        let sent: [RpcCommand] = callCommands()
        #expect(sent.count == 1, "the call with headers is not sent")
        #expect(sent.first?.rpc.msgID == 0, "a legacy connection gets a plain request")
    }


    @Test func capabilityWithoutInstanceSendsPlainCalls() async {
        let harness: Harness = await connectedHarness(config: instanceConfig(instance: nil))
        let call: (call: CentrifugeRpcCall, outcome: CallOutcome) = startCall(harness.client)
        await fulfillment(of: call.outcome.done, within: 5)
        #expect(succeeded(call.outcome.result))
        #expect(callCommands().first?.rpc.msgID == 0, "no msg_id without an instance")
    }


    // MARK: bound

    /// A client whose connect is never answered, so every call waits for its connection.
    private func waitingClient(config: CentrifugeClientConfig) async -> (client: CentrifugeClient, delegate: RecordingClientDelegate) {
        fake.server.connectResult = capabilityResult(true)
        fake.setDrop { (command: RpcCommand) -> Bool in
            return command.hasConnect
        }
        let delegate: RecordingClientDelegate = RecordingClientDelegate(connected: Expectation("connected"))
        let setup: ManualClientSetup = makeManualClient(
            endpoint: fake.server.url,
            config: config,
            delegate: delegate,
            random: ManualRandom()
        )
        setup.client.connect()
        return (setup.client, delegate)
    }


    @Test func callsBeyondTheQueueBoundFailWithLimitExceeded() async {
        let waiting: (client: CentrifugeClient, delegate: RecordingClientDelegate) = await waitingClient(config: instanceConfig())
        var queued: [CallOutcome] = []
        for _ in 0 ..< 32 {
            queued.append(startCall(waiting.client).outcome)
        }
        let refused: (call: CentrifugeRpcCall, outcome: CallOutcome) = startCall(waiting.client)
        // The refusal is decided on the client's queue at admission, so it is already set once the
        // queue has run the block that follows the call. No connection is needed for it.
        await drainQueue(waiting.client)
        if case CentrifugeError.replyError(let code, _, _)? = failure(refused.outcome.result) {
            #expect(code == 16)
        } else {
            Issue.record("expected limit exceeded (16), got \(String(describing: refused.outcome.result))")
        }

        waiting.client.disconnect()
        for outcome: CallOutcome in queued {
            await fulfillment(of: outcome.done, within: 5)
        }
    }


    @Test func aRefusedCallHoldsNoSlotOfTheBound() async throws {
        let waiting: (client: CentrifugeClient, delegate: RecordingClientDelegate) = await waitingClient(config: instanceConfig())
        var handles: [(call: CentrifugeRpcCall, outcome: CallOutcome)] = []
        for _ in 0 ..< 32 {
            handles.append(startCall(waiting.client))
        }
        let refused: (call: CentrifugeRpcCall, outcome: CallOutcome) = startCall(waiting.client)
        await fulfillment(of: refused.outcome.done, within: 5)

        // One settled call frees one slot; the refused call took none, so the next call is admitted.
        let firstHandle: (call: CentrifugeRpcCall, outcome: CallOutcome) = try #require(handles.first)
        firstHandle.call.cancel()
        await fulfillment(of: firstHandle.outcome.done, within: 5)
        let next: (call: CentrifugeRpcCall, outcome: CallOutcome) = startCall(waiting.client)
        waiting.client.disconnect()
        await fulfillment(of: next.outcome.done, within: 5)
        if case CentrifugeError.clientDisconnected? = failure(next.outcome.result) {
        } else {
            Issue.record("the next call should wait, not be refused: \(String(describing: next.outcome.result))")
        }
        for handle: (call: CentrifugeRpcCall, outcome: CallOutcome) in handles.dropFirst() {
            await fulfillment(of: handle.outcome.done, within: 5)
        }
    }


    @Test func withoutAnInstanceThereIsNoBound() async {
        let waiting: (client: CentrifugeClient, delegate: RecordingClientDelegate) = await waitingClient(config: instanceConfig(instance: nil))
        var outcomes: [CallOutcome] = []
        for _ in 0 ..< 40 {
            outcomes.append(startCall(waiting.client).outcome)
        }
        // Every call waited for the connection, so each one is failed by the disconnect and none by the bound.
        waiting.client.disconnect()
        var failedByDisconnect: Int = 0
        for outcome: CallOutcome in outcomes {
            await fulfillment(of: outcome.done, within: 5)
            if case CentrifugeError.clientDisconnected? = failure(outcome.result) {
                failedByDisconnect += 1
            }
        }
        #expect(failedByDisconnect == 40, "a client without an instance has no bound: all 40 calls were queued")
    }


    // MARK: retry

    private func errorReply(code: UInt32, metadata: [String: String]) -> RpcReply {
        return rpcErrorReply(code: code, message: "refused", metadata: metadata)
    }


    private func successReply() -> RpcReply {
        var reply: RpcReply = RpcReply()
        reply.rpc = Centrifugal_Centrifuge_Protocol_RPCResult()
        return reply
    }


    /// Answers the first `refusals` calls with `refusal`, then answers the rest with success. Cancels
    /// get the default answer.
    private func refuseFirst(_ refusals: Int, with refusal: @escaping () -> RpcReply) {
        let served: LockedBox<Int> = LockedBox(0)
        fake.setAnswer { (command: RpcCommand) -> RpcReply? in
            guard command.hasRpc, command.rpc.cancel == 0 else {
                return nil
            }
            let index: Int = served.current
            served.set(index + 1)
            if index < refusals {
                return refusal()
            }
            return RpcReply()
        }
    }


    @Test func aRefusalWithTheNewMsgIdSignalIsSentAgainWithANewId() async throws {
        let harness: Harness = await connectedHarness()
        let metadata: [String: String] = [rpcRetryMetadataKey: rpcRetryValueNewMsgID]
        let serverTime: Int64 = harness.clock.wallMillis() + 5_000
        refuseFirst(1) { () -> RpcReply in
            var reply: RpcReply = self.errorReply(code: 107, metadata: metadata)
            reply.time = serverTime
            return reply
        }
        let call: (call: CentrifugeRpcCall, outcome: CallOutcome) = startCall(harness.client)
        await fulfillment(of: call.outcome.done, within: 5)

        let sent: [RpcCommand] = callCommands()
        try #require(sent.count == 2)
        #expect(sent[1].rpc.msgID >> 20 > sent[0].rpc.msgID >> 20, "the resend has the corrected, later time part")
        #expect(sent[1].rpc.msgID != sent[0].rpc.msgID)
        #expect(!sent[1].rpc.retransmit, "a new msg_id is a first send")
        #expect(succeeded(call.outcome.result))
    }


    @Test func threeRefusalsWithTheNewMsgIdSignalSurfaceTheError() async {
        let harness: Harness = await connectedHarness()
        let metadata: [String: String] = [rpcRetryMetadataKey: rpcRetryValueNewMsgID]
        refuseFirst(3) { () -> RpcReply in
            return self.errorReply(code: 107, metadata: metadata)
        }
        let call: (call: CentrifugeRpcCall, outcome: CallOutcome) = startCall(harness.client)
        await fulfillment(of: call.outcome.done, within: 5)

        #expect(callCommands().count == 3)
        if case CentrifugeError.replyErrorDetails(let details)? = failure(call.outcome.result) {
            #expect(details.metadata[rpcRetryMetadataKey] == rpcRetryValueNewMsgID, "the error arrives unchanged")
        } else {
            Issue.record("expected the server error, got \(String(describing: call.outcome.result))")
        }
    }


    /// The resend is armed at the drawn delay (the ceiling, 250 ms, with the draw at 1); the test
    /// advances the clock past it and the same msg_id goes out again.
    @Test func aRefusalWithTheLaterSignalIsSentAgainWithTheSameMsgIdAfterItsDelay() async throws {
        let harness: Harness = await connectedHarness(random: ManualRandom(draw: 1))
        let metadata: [String: String] = [rpcRetryMetadataKey: rpcRetryValueLater]
        refuseFirst(1) { () -> RpcReply in
            return self.errorReply(code: 100, metadata: metadata)
        }
        let armed: Expectation = Expectation("resend armed")
        harness.scheduler.observe { (scheduled: ScheduledCall) in
            if abs(scheduled.delay - 0.25) < 0.000_001 {
                armed.fulfill()
            }
        }
        let call: (call: CentrifugeRpcCall, outcome: CallOutcome) = startCall(harness.client)
        await fulfillment(of: armed, within: 5)
        await drain(harness)
        #expect(callCommands().count == 1, "nothing is written before the delay ends")
        await harness.scheduler.advance(by: 0.25)
        await fulfillment(of: call.outcome.done, within: 5)

        let sent: [RpcCommand] = callCommands()
        try #require(sent.count == 2)
        #expect(sent[1].rpc.msgID == sent[0].rpc.msgID, "a later resend keeps the msg_id")
        #expect(sent[1].rpc.retransmit)
        #expect(sent[1].id != sent[0].id)
        #expect(succeeded(call.outcome.result))
    }


    /// The resend is drawn over the remaining deadline (0.2 s, below the 250 ms base), so it is due at the
    /// deadline at the latest. The deadline settles the call first, so the resend that waited is never written.
    /// The range of the draw is pinned by `laterResendDelayIsCappedAtTheRemainingDeadline`.
    @Test func aLaterResendDueAtTheDeadlineIsNeverWritten() async {
        let harness: Harness = await connectedHarness(random: ManualRandom(draw: 1))
        let metadata: [String: String] = [rpcRetryMetadataKey: rpcRetryValueLater]
        // The server never answers the call itself: the test sends its refusal, so the refusal is handled
        // at a known point, and the barrier call (answered, and after the refusal on the connection) shows
        // that it was handled.
        fake.setDrop { (command: RpcCommand) -> Bool in
            return command.hasRpc && command.rpc.method == "method"
        }
        fake.setAnswer { (command: RpcCommand) -> RpcReply? in
            guard command.hasRpc, command.rpc.cancel == 0, command.rpc.method == "barrier" else {
                return nil
            }
            return self.successReply()
        }
        let options: CentrifugeRpcOptions = CentrifugeRpcOptions(timeout: 0.2)
        let call: (call: CentrifugeRpcCall, outcome: CallOutcome) = startCall(harness.client, options: options)
        await fake.awaitArrivals("rpc arrived") { (command: RpcCommand) -> Bool in
            return command.hasRpc && command.rpc.cancel == 0 && command.rpc.method == "method"
        }
        let originalId: UInt32 = callCommands().first { (command: RpcCommand) -> Bool in
            return command.rpc.method == "method"
        }?.id ?? 0
        var refusal: RpcReply = errorReply(code: 100, metadata: metadata)
        refusal.id = originalId
        fake.server.sendReply(refusal)

        let barrier: CallOutcome = CallOutcome()
        harness.client.rpc(method: "barrier", data: Data()) { (result: Result<CentrifugeRpcResult, Error>) in
            barrier.record(result)
        }
        await fulfillment(of: barrier.done, within: 5)

        await harness.scheduler.advance(by: 0.25)
        await fulfillment(of: call.outcome.done, within: 5)
        if case CentrifugeError.timeout? = failure(call.outcome.result) {
        } else {
            Issue.record("expected timeout, got \(String(describing: call.outcome.result))")
        }
        let methodCommands: [RpcCommand] = callCommands().filter { (command: RpcCommand) -> Bool in
            return command.rpc.method == "method"
        }
        #expect(methodCommands.count == 1, "the resend due at the deadline is never written")
    }


    /// With a 0.2 s deadline and a later refusal before it, the draw of the resend delay is over
    /// `0 ... 200 ms` (the remaining deadline), not `0 ... 250 ms`. With the draw at 1 the delay is the
    /// cap itself. The deadline still settles the call with `timeout`.
    @Test func laterResendDelayIsCappedAtTheRemainingDeadline() async {
        let random: ManualRandom = ManualRandom(draw: 1)
        let harness: Harness = await connectedHarness(random: random)
        let metadata: [String: String] = [rpcRetryMetadataKey: rpcRetryValueLater]
        // As in aLaterResendDueAtTheDeadlineIsNeverWritten: the test sends the refusal, and the barrier shows
        // that the refusal was handled, because its reply follows the refusal on the connection.
        fake.setDrop { (command: RpcCommand) -> Bool in
            return command.hasRpc && command.rpc.method == "method"
        }
        fake.setAnswer { (command: RpcCommand) -> RpcReply? in
            guard command.hasRpc, command.rpc.cancel == 0, command.rpc.method == "barrier" else {
                return nil
            }
            return self.successReply()
        }
        // The connect handler arms the ping watchdog after it has called onConnected, so the test waits for
        // that handler to finish before it observes: otherwise the 35 s watchdog arm could be recorded.
        await drain(harness)
        // The observer is set before the call starts, so the arm of the call's deadline is seen too. The
        // resend is due at that same moment (its delay is capped at the deadline), so the one timer is
        // never re-armed for it: every arm of the call is at or before the deadline.
        let armedDelays: LockedBox<[TimeInterval]> = LockedBox([])
        harness.scheduler.observe { (scheduled: ScheduledCall) in
            armedDelays.update { (delays: inout [TimeInterval]) in
                delays.append(scheduled.delay)
            }
        }
        let options: CentrifugeRpcOptions = CentrifugeRpcOptions(timeout: 0.2)
        let call: (call: CentrifugeRpcCall, outcome: CallOutcome) = startCall(harness.client, options: options)
        await fake.awaitArrivals("rpc arrived") { (command: RpcCommand) -> Bool in
            return command.hasRpc && command.rpc.cancel == 0 && command.rpc.method == "method"
        }
        let originalId: UInt32 = callCommands().first { (command: RpcCommand) -> Bool in
            return command.rpc.method == "method"
        }?.id ?? 0
        var refusal: RpcReply = errorReply(code: 100, metadata: metadata)
        refusal.id = originalId
        fake.server.sendReply(refusal)

        let barrier: CallOutcome = CallOutcome()
        harness.client.rpc(method: "barrier", data: Data()) { (result: Result<CentrifugeRpcResult, Error>) in
            barrier.record(result)
        }
        await fulfillment(of: barrier.done, within: 5)

        let expectedRange: ClosedRange<UInt64> = 0 ... 200_000_000
        #expect(random.requestedRanges.last == expectedRange, "the later resend is drawn over the remaining 200 ms, not 250 ms")
        let delays: [TimeInterval] = armedDelays.current
        let noArmBeyondTheDeadline: Bool = !delays.isEmpty && delays.allSatisfy { (delay: TimeInterval) -> Bool in
            return delay <= 0.2 + 0.000_001
        }
        #expect(noArmBeyondTheDeadline, "no timer waits past the remaining deadline, 0.2 s")

        await harness.scheduler.advance(by: 0.2)
        await fulfillment(of: call.outcome.done, within: 5)
        if case CentrifugeError.timeout? = failure(call.outcome.result) {
        } else {
            Issue.record("expected timeout, got \(String(describing: call.outcome.result))")
        }
    }


    /// Refuses the call of a test after its deadline, with the given retry signal, before the timer runs.
    /// Returns the outcome of the call and the rpc commands sent by then.
    private func refuseAfterDeadline(signal: String) async -> (outcome: CallOutcome, sent: [RpcCommand]) {
        let harness: Harness = await connectedHarness(config: instanceConfig(timeout: 1))
        fake.setDrop { (command: RpcCommand) -> Bool in
            return command.hasRpc && command.rpc.method == "method"
        }
        fake.setAnswer { (command: RpcCommand) -> RpcReply? in
            guard command.hasRpc, command.rpc.cancel == 0, command.rpc.method == "barrier" else {
                return nil
            }
            return self.successReply()
        }
        let options: CentrifugeRpcOptions = CentrifugeRpcOptions(timeout: 0.2)
        let call: (call: CentrifugeRpcCall, outcome: CallOutcome) = startCall(harness.client, options: options)
        await fake.awaitArrivals("rpc arrived") { (command: RpcCommand) -> Bool in
            return command.hasRpc && command.rpc.cancel == 0 && command.rpc.method == "method"
        }
        let originalId: UInt32 = callCommands().first { (command: RpcCommand) -> Bool in
            return command.rpc.method == "method"
        }?.id ?? 0
        // The clock passes the deadline, but the timer does not run: the refusal is handled first.
        harness.scheduler.passTime(by: 0.3)
        var refusal: RpcReply = errorReply(code: 107, metadata: [rpcRetryMetadataKey: signal])
        refusal.id = originalId
        fake.server.sendReply(refusal)

        let barrier: CallOutcome = CallOutcome()
        harness.client.rpc(method: "barrier", data: Data()) { (result: Result<CentrifugeRpcResult, Error>) in
            barrier.record(result)
        }
        await fulfillment(of: barrier.done, within: 5)
        await fulfillment(of: call.outcome.done, within: 5)
        return (outcome: call.outcome, sent: callCommands())
    }


    @Test func aRefusalWithTheNewMsgIdSignalPastItsDeadlineSurfacesTheError() async {
        let result: (outcome: CallOutcome, sent: [RpcCommand]) = await refuseAfterDeadline(signal: rpcRetryValueNewMsgID)
        if case CentrifugeError.replyErrorDetails(let details)? = failure(result.outcome.result) {
            #expect(details.metadata[rpcRetryMetadataKey] == rpcRetryValueNewMsgID, "the server error arrives unchanged")
        } else {
            Issue.record("expected the server error, got \(String(describing: result.outcome.result))")
        }
        let methodCommands: [RpcCommand] = result.sent.filter { (command: RpcCommand) -> Bool in
            return command.rpc.method == "method"
        }
        #expect(methodCommands.count == 1, "a refusal past the deadline is not resent with a new msg_id")
    }


    @Test func aRefusalWithTheLaterSignalPastItsDeadlineSurfacesTheError() async {
        let result: (outcome: CallOutcome, sent: [RpcCommand]) = await refuseAfterDeadline(signal: rpcRetryValueLater)
        if case CentrifugeError.replyErrorDetails(let details)? = failure(result.outcome.result) {
            #expect(details.metadata[rpcRetryMetadataKey] == rpcRetryValueLater, "the server error arrives unchanged")
        } else {
            Issue.record("expected the server error, got \(String(describing: result.outcome.result))")
        }
        let methodCommands: [RpcCommand] = result.sent.filter { (command: RpcCommand) -> Bool in
            return command.rpc.method == "method"
        }
        #expect(methodCommands.count == 1, "a refusal past the deadline is not resent later")
    }


    @Test func fourRefusalsWithTheLaterSignalSurfaceTheError() async {
        let harness: Harness = await connectedHarness(random: ManualRandom(draw: 0))
        let metadata: [String: String] = [rpcRetryMetadataKey: rpcRetryValueLater]
        refuseFirst(4) { () -> RpcReply in
            return self.errorReply(code: 100, metadata: metadata)
        }
        // Three resends, each armed with a zero delay after the refusal before it.
        let armed: [Expectation] = [Expectation("first resend armed"), Expectation("second resend armed"), Expectation("third resend armed")]
        let armedCount: LockedBox<Int> = LockedBox(0)
        harness.scheduler.observe { (scheduled: ScheduledCall) in
            guard scheduled.delay == 0 else {
                return
            }
            let index: Int = armedCount.current
            armedCount.set(index + 1)
            if index < armed.count {
                armed[index].fulfill()
            }
        }
        let call: (call: CentrifugeRpcCall, outcome: CallOutcome) = startCall(harness.client)
        for expectation: Expectation in armed {
            await fulfillment(of: expectation, within: 5)
            await drain(harness)
            await harness.scheduler.advance(by: 0)
        }
        await fulfillment(of: call.outcome.done, within: 5)

        #expect(callCommands().count == 4)
        if case CentrifugeError.replyErrorDetails(let details)? = failure(call.outcome.result) {
            #expect(details.metadata[rpcRetryMetadataKey] == rpcRetryValueLater)
        } else {
            Issue.record("expected the server error after the fourth refusal, got \(String(describing: call.outcome.result))")
        }
    }


    @Test func aRefusalWithNoSignalIsSurfacedAtOnce() async {
        let harness: Harness = await connectedHarness()
        refuseFirst(1) { () -> RpcReply in
            return self.errorReply(code: 107, metadata: [:])
        }
        let call: (call: CentrifugeRpcCall, outcome: CallOutcome) = startCall(harness.client)
        await fulfillment(of: call.outcome.done, within: 5)
        #expect(callCommands().count == 1, "nothing is resent without the signal")
        if case CentrifugeError.replyError(let code, _, _)? = failure(call.outcome.result) {
            #expect(code == 107)
        } else {
            Issue.record("expected the server error, got \(String(describing: call.outcome.result))")
        }
    }


    @Test func aResendCrossingALostConnectionGoesOutWithTheReconnect() async throws {
        let harness: Harness = await connectedHarness(random: ManualRandom(draw: 1))
        let metadata: [String: String] = [rpcRetryMetadataKey: rpcRetryValueLater]
        refuseFirst(1) { () -> RpcReply in
            return self.errorReply(code: 100, metadata: metadata)
        }
        let armed: Expectation = Expectation("resend armed")
        harness.scheduler.observe { (scheduled: ScheduledCall) in
            if abs(scheduled.delay - 0.25) < 0.000_001 {
                armed.fulfill()
            }
        }
        let call: (call: CentrifugeRpcCall, outcome: CallOutcome) = startCall(harness.client)
        await fulfillment(of: armed, within: 5)

        // The connection is lost while the resend waits: the call goes out with the reconnect.
        await reconnect(harness, connectsSoFar: 1)
        await fulfillment(of: call.outcome.done, within: 5)

        let sent: [RpcCommand] = callCommands()
        try #require(sent.count == 2)
        #expect(sent[1].rpc.msgID == sent[0].rpc.msgID)
        #expect(sent[1].rpc.retransmit)
        #expect(succeeded(call.outcome.result))
    }


    @Test func theDeadlineDuringTheDelayRejectsWithTimeoutAndSendsACancel() async {
        let harness: Harness = await connectedHarness(random: ManualRandom(draw: 1))
        let metadata: [String: String] = [rpcRetryMetadataKey: rpcRetryValueLater]
        // The server never answers the call itself: the test sends its refusal, so the refusal is
        // handled at a known point. The barrier call is answered, and its reply follows the refusal
        // on the connection, so once the barrier completes the refusal has been handled.
        fake.setDrop { (command: RpcCommand) -> Bool in
            return command.hasRpc && command.rpc.method == "method"
        }
        fake.setAnswer { (command: RpcCommand) -> RpcReply? in
            guard command.hasRpc, command.rpc.cancel == 0, command.rpc.method == "barrier" else {
                return nil
            }
            return self.successReply()
        }
        let options: CentrifugeRpcOptions = CentrifugeRpcOptions(timeout: 0.2)
        let call: (call: CentrifugeRpcCall, outcome: CallOutcome) = startCall(harness.client, options: options)
        await fake.awaitArrivals("rpc arrived") { (command: RpcCommand) -> Bool in
            return command.hasRpc && command.rpc.cancel == 0 && command.rpc.method == "method"
        }
        let msgID: UInt64 = callCommands().first { (command: RpcCommand) -> Bool in
            return command.rpc.method == "method"
        }?.rpc.msgID ?? 0

        let originalId: UInt32 = callCommands().first { (command: RpcCommand) -> Bool in
            return command.rpc.method == "method"
        }?.id ?? 0
        var refusal: RpcReply = errorReply(code: 100, metadata: metadata)
        refusal.id = originalId
        fake.server.sendReply(refusal)

        let barrier: CallOutcome = CallOutcome()
        harness.client.rpc(method: "barrier", data: Data()) { (result: Result<CentrifugeRpcResult, Error>) in
            barrier.record(result)
        }
        await fulfillment(of: barrier.done, within: 5)

        await harness.scheduler.advance(by: 0.2)
        await fulfillment(of: call.outcome.done, within: 5)

        if case CentrifugeError.timeout? = failure(call.outcome.result) {
        } else {
            Issue.record("expected timeout, got \(String(describing: call.outcome.result))")
        }
        await fake.awaitArrivals("cancel arrived") { (command: RpcCommand) -> Bool in
            return command.hasRpc && command.rpc.cancel != 0
        }
        #expect(cancelCommands().count == 1)
        #expect(cancelCommands().first?.rpc.cancel == msgID)
    }


    // MARK: released client

    /// Starts a tracked call on a client that waits for its connection, so the call's deadline item is
    /// pending. Returns once that item is armed, with the scheduler, the call's outcome and a weak
    /// handle on the client. Every strong reference to the client lives in this function and ends with it.
    private func startCallThenReleaseClient() async -> (scheduler: ManualScheduler, outcome: CallOutcome, weakClient: WeakClient) {
        fake.server.connectResult = capabilityResult(true)
        fake.setDrop { (command: RpcCommand) -> Bool in
            return command.hasConnect
        }
        let delegate: RecordingClientDelegate = RecordingClientDelegate(connected: Expectation("connected"))
        let setup: ManualClientSetup = makeManualClient(
            endpoint: fake.server.url,
            config: instanceConfig(timeout: 1),
            delegate: delegate,
            random: ManualRandom()
        )
        setup.client.connect()
        let call: (call: CentrifugeRpcCall, outcome: CallOutcome) = startCall(setup.client)
        // The client's queue runs in order: once this block has run, the admit of the call and its arming are done.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            setup.client.syncQueue.async {
                continuation.resume()
            }
        }
        return (setup.scheduler, call.outcome, WeakClient(client: setup.client))
    }


    /// Releases the client while its deadline item is pending, then runs the scheduler past the deadline.
    /// The tracker is released with the client and cancels its item, so nothing runs and nothing traps.
    /// The call's completion is never called: a client that is gone settles no call.
    @Test func trackerTimerAfterTheClientIsReleasedDoesNotTrap() async throws {
        let parts: (scheduler: ManualScheduler, outcome: CallOutcome, weakClient: WeakClient) = await startCallThenReleaseClient()
        try #require(!parts.scheduler.scheduledCalls.isEmpty, "a timer was armed before the release")
        try #require(parts.weakClient.client == nil, "the client was released")

        await parts.scheduler.advance(by: 2)

        #expect(parts.outcome.result == nil, "a call of a released client is never completed")
    }


    // MARK: parameters

    @Test func boundBelowOneIsRefusedAtCreate() {
        let config: CentrifugeClientConfig = instanceConfig(maxPendingRpc: 0)
        do {
            _ = try CentrifugeClient.create(endpoint: "ws://127.0.0.1:1/connection/websocket", config: config)
            Issue.record("create should refuse maxPendingRpc below 1")
        } catch {
            if case CentrifugeError.configurationError = error {
            } else {
                Issue.record("expected configurationError, got \(error)")
            }
        }
    }
}
