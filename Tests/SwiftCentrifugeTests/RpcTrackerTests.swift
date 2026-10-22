import Foundation
import Testing
@testable import SwiftCentrifuge

// The tracked rpc calls (parity spec F7 to F9, sections 4.3 "tracked", "cancel", "legacy", "bound"
// and "retry"). The clock, the random source and the timers are the test seams: every timer runs
// when a test advances the ManualScheduler, and no test sleeps. Each test first drains the client's
// queue (`drain`), so a timer that the client arms on its queue is in place before the advance.

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
    let delegate: RpcTestDelegate
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
        let delegate: RpcTestDelegate = RpcTestDelegate()
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

    @Test func repliesAreAckedWithTheNextCall() async {
        let harness: Harness = await connectedHarness()
        let first: (call: CentrifugeRpcCall, outcome: CallOutcome) = startCall(harness.client)
        await fulfillment(of: first.outcome.done, within: 5)
        let second: (call: CentrifugeRpcCall, outcome: CallOutcome) = startCall(harness.client)
        await fulfillment(of: second.outcome.done, within: 5)

        let sent: [RpcCommand] = callCommands()
        #expect(sent.count == 2)
        #expect(sent[0].rpc.ack.isEmpty, "nothing was acked before the first call")
        #expect(sent[1].rpc.ack == [sent[0].rpc.msgID], "the next command carries the ack of the first reply")
    }


    @Test func droppedCallRunsOnceAndTheResendGetsTheSameReply() async {
        let harness: Harness = await connectedHarness()
        let dropping: LockedBox<Bool> = LockedBox(true)
        fake.setDrop { (command: RpcCommand) -> Bool in
            return command.hasRpc && dropping.current
        }
        let call: (call: CentrifugeRpcCall, outcome: CallOutcome) = startCall(harness.client)
        await fake.awaitArrivals("first call arrived") { (command: RpcCommand) -> Bool in
            return command.hasRpc && command.rpc.msgID != 0
        }

        dropping.set(false)
        await reconnect(harness, connectsSoFar: 1)
        await fulfillment(of: call.outcome.done, within: 5)

        let sent: [RpcCommand] = callCommands()
        #expect(sent.count == 2)
        #expect(sent[0].rpc.msgID == sent[1].rpc.msgID, "the resend keeps the msg_id")
        #expect(sent[1].rpc.retransmit, "the resend is marked as a retransmit")
        #expect(sent[0].id != sent[1].id, "the resend takes a fresh command id")
        #expect(succeeded(call.outcome.result))
    }


    @Test func lostCallsAreSentAgainInMsgIdOrder() async {
        let harness: Harness = await connectedHarness()
        let dropping: LockedBox<Bool> = LockedBox(true)
        fake.setDrop { (command: RpcCommand) -> Bool in
            return command.hasRpc && dropping.current
        }
        let first: (call: CentrifugeRpcCall, outcome: CallOutcome) = startCall(harness.client)
        let second: (call: CentrifugeRpcCall, outcome: CallOutcome) = startCall(harness.client)
        await fake.awaitArrivals("two calls arrived", count: 2) { (command: RpcCommand) -> Bool in
            return command.hasRpc
        }

        dropping.set(false)
        await reconnect(harness, connectsSoFar: 1)
        await fulfillment(of: first.outcome.done, within: 5)
        await fulfillment(of: second.outcome.done, within: 5)

        let sent: [RpcCommand] = callCommands()
        #expect(sent.count == 4)
        let resent: [RpcCommand] = Array(sent.suffix(2))
        #expect(resent[0].rpc.msgID < resent[1].rpc.msgID, "the resends go out in msg_id order")
        #expect(resent.allSatisfy { (command: RpcCommand) -> Bool in command.rpc.retransmit })
        #expect(Set(sent.map { (command: RpcCommand) -> UInt32 in command.id }).count == 4, "every write takes a fresh command id")
    }


    @Test func aCallDroppedFromTheBatchBeforeItsWriteIsSentAsAFirstSend() async {
        let harness: Harness = await connectedHarness()
        await dropConnection(harness)
        // The call is admitted while the client waits for its connection: it is not written yet.
        let call: (call: CentrifugeRpcCall, outcome: CallOutcome) = startCall(harness.client)
        await drain(harness)
        await harness.scheduler.advance(by: 1.5)
        await harness.delegate.awaitConnected(times: 2)
        await fulfillment(of: call.outcome.done, within: 5)

        let sent: [RpcCommand] = callCommands()
        #expect(sent.count == 1)
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
        let call: (call: CentrifugeRpcCall, outcome: CallOutcome) = startCall(harness.client)
        await fake.awaitArrivals("call arrived") { (command: RpcCommand) -> Bool in
            return command.hasRpc && command.rpc.cancel == 0
        }
        await drain(harness)
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
    private func waitingClient(config: CentrifugeClientConfig) async -> (client: CentrifugeClient, delegate: RpcTestDelegate) {
        fake.server.connectResult = capabilityResult(true)
        fake.setDrop { (command: RpcCommand) -> Bool in
            return command.hasConnect
        }
        let delegate: RpcTestDelegate = RpcTestDelegate()
        let setup: ManualClientSetup = makeManualClient(endpoint: fake.server.url, config: config, delegate: delegate)
        setup.client.connect()
        return (setup.client, delegate)
    }


    @Test func callsBeyondTheQueueBoundFailWithLimitExceeded() async {
        let waiting: (client: CentrifugeClient, delegate: RpcTestDelegate) = await waitingClient(config: instanceConfig())
        var queued: [CallOutcome] = []
        for _ in 0 ..< 32 {
            queued.append(startCall(waiting.client).outcome)
        }
        let refused: (call: CentrifugeRpcCall, outcome: CallOutcome) = startCall(waiting.client)
        await fulfillment(of: refused.outcome.done, within: 5)
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


    @Test func aRefusedCallHoldsNoSlotOfTheBound() async {
        let waiting: (client: CentrifugeClient, delegate: RpcTestDelegate) = await waitingClient(config: instanceConfig())
        var handles: [(call: CentrifugeRpcCall, outcome: CallOutcome)] = []
        for _ in 0 ..< 32 {
            handles.append(startCall(waiting.client))
        }
        let refused: (call: CentrifugeRpcCall, outcome: CallOutcome) = startCall(waiting.client)
        await fulfillment(of: refused.outcome.done, within: 5)

        // One settled call frees one slot; the refused call took none, so the next call is admitted.
        handles[0].call.cancel()
        await fulfillment(of: handles[0].outcome.done, within: 5)
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
        let waiting: (client: CentrifugeClient, delegate: RpcTestDelegate) = await waitingClient(config: instanceConfig(instance: nil))
        var outcomes: [CallOutcome] = []
        for _ in 0 ..< 40 {
            outcomes.append(startCall(waiting.client).outcome)
        }
        waiting.client.disconnect()
        var limited: Int = 0
        for outcome: CallOutcome in outcomes {
            await fulfillment(of: outcome.done, within: 5)
            if case CentrifugeError.replyError(16, _, _)? = failure(outcome.result) {
                limited += 1
            }
        }
        #expect(limited == 0, "a client without an instance has no bound")
    }


    // MARK: retry

    private func errorReply(code: UInt32, metadata: [String: String]) -> RpcReply {
        var error: Centrifugal_Centrifuge_Protocol_Error = Centrifugal_Centrifuge_Protocol_Error()
        error.code = code
        error.message = "refused"
        error.metadata = metadata
        var reply: RpcReply = RpcReply()
        reply.error = error
        return reply
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


    @Test func aRefusalWithTheNewMsgIdSignalIsSentAgainWithANewId() async {
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
        #expect(sent.count == 2)
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
    @Test func aRefusalWithTheLaterSignalIsSentAgainWithTheSameMsgIdAfterItsDelay() async {
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
        await harness.scheduler.advance(by: 0.25)
        await fulfillment(of: call.outcome.done, within: 5)

        let sent: [RpcCommand] = callCommands()
        #expect(sent.count == 2)
        #expect(sent[1].rpc.msgID == sent[0].rpc.msgID, "a later resend keeps the msg_id")
        #expect(sent[1].rpc.retransmit)
        #expect(sent[1].id != sent[0].id)
        #expect(succeeded(call.outcome.result))
    }


    @Test func laterResendDelayIsCappedAtTheRemainingDeadline() async {
        let harness: Harness = await connectedHarness(random: ManualRandom(draw: 1))
        let metadata: [String: String] = [rpcRetryMetadataKey: rpcRetryValueLater]
        refuseFirst(1) { () -> RpcReply in
            return self.errorReply(code: 100, metadata: metadata)
        }
        let armed: Expectation = Expectation("resend armed at the deadline")
        harness.scheduler.observe { (scheduled: ScheduledCall) in
            if abs(scheduled.delay - 0.2) < 0.000_001 {
                armed.fulfill()
            }
        }
        let options: CentrifugeRpcOptions = CentrifugeRpcOptions(timeout: 0.2)
        _ = startCall(harness.client, options: options)
        // The remaining deadline (0.2 s) is below 250 ms, so the resend waits for 0.2 s, not 0.25 s.
        await fulfillment(of: armed, within: 5)
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


    @Test func aResendCrossingALostConnectionGoesOutWithTheReconnect() async {
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
        #expect(sent.count == 2)
        #expect(sent[1].rpc.msgID == sent[0].rpc.msgID)
        #expect(sent[1].rpc.retransmit)
        #expect(succeeded(call.outcome.result))
    }


    @Test func theDeadlineDuringTheDelayRejectsWithTimeoutAndSendsACancel() async {
        let harness: Harness = await connectedHarness(random: ManualRandom(draw: 1))
        let metadata: [String: String] = [rpcRetryMetadataKey: rpcRetryValueLater]
        fake.setAnswer { (command: RpcCommand) -> RpcReply? in
            guard command.hasRpc, command.rpc.cancel == 0 else {
                return nil
            }
            return self.errorReply(code: 100, metadata: metadata)
        }
        let armed: Expectation = Expectation("resend armed at the deadline")
        harness.scheduler.observe { (scheduled: ScheduledCall) in
            if abs(scheduled.delay - 0.2) < 0.000_001 {
                armed.fulfill()
            }
        }
        let options: CentrifugeRpcOptions = CentrifugeRpcOptions(timeout: 0.2)
        let call: (call: CentrifugeRpcCall, outcome: CallOutcome) = startCall(harness.client, options: options)
        await fulfillment(of: armed, within: 5)
        await drain(harness)
        await harness.scheduler.advance(by: 0.2)
        await fulfillment(of: call.outcome.done, within: 5)

        if case CentrifugeError.timeout? = failure(call.outcome.result) {
        } else {
            Issue.record("expected timeout, got \(String(describing: call.outcome.result))")
        }
        let msgID: UInt64 = callCommands().first?.rpc.msgID ?? 0
        await fake.awaitArrivals("cancel arrived") { (command: RpcCommand) -> Bool in
            return command.hasRpc && command.rpc.cancel == msgID
        }
        #expect(cancelCommands().count == 1)
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
