import Foundation
import Testing
@testable import SwiftCentrifuge

// The publish debounce of a subscription, on the manual clock. A test moves the clock with the scheduler's
// advance and waits for the server's arrivals (FakeRpcServer.awaitArrivals), so no test sleeps. A check that
// something is not sent yet is closed by a marked publish on the same connection: the server records the frames
// of one connection in order, so once that marker has arrived, no earlier send can still come.

private let debounceChannel: String = "debounced"
private let markerChannel: String = "marker"
private let debounceWindowMillis: UInt32 = 30
private let debounceWindowSeconds: TimeInterval = 0.03
private let refusedPayload: String = "refused"
private let refusedCode: UInt32 = 103


/// The outcome of the publishes of one test, as their completions reported them. `finished` is fulfilled by
/// the first completion, so a test can wait for a publish to settle.
private final class CompletionLog: @unchecked Sendable {
    let finished: Expectation = Expectation("publish completed")
    private let outcomes: LockedBox<[Bool]> = LockedBox([])


    /// The completions reported so far.
    var count: Int {
        return outcomes.current.count
    }


    /// The completions that reported success.
    var successes: Int {
        return outcomes.current.filter { (succeeded: Bool) -> Bool in
            return succeeded
        }.count
    }


    func record(_ result: Result<CentrifugePublishResult, Error>) {
        var succeeded: Bool = false
        if case .success = result {
            succeeded = true
        }
        outcomes.update { (values: inout [Bool]) in
            values.append(succeeded)
        }
        finished.fulfill()
    }
}


/// A subscribed session of one client on the manual clock.
private struct DebounceSession {
    let client: CentrifugeClient
    let scheduler: ManualScheduler
    let connected: RecordingClientDelegate
    let subscription: CentrifugeSubscription
    let subDelegate: ClosureSubscriptionDelegate
}


/// Whether a command is a publish to the debounced channel with `text` as its data.
private func isDebouncedPublish(_ command: RpcCommand, _ text: String) -> Bool {
    return command.hasPublish && command.publish.channel == debounceChannel && command.publish.data == Data(text.utf8)
}


/// The data of the debounced publishes the server has received, in arrival order.
private func debouncedPayloads(_ fake: FakeRpcServer) -> [String] {
    return fake.allCommands().filter { (command: RpcCommand) -> Bool in
        return command.hasPublish && command.publish.channel == debounceChannel
    }.map { (command: RpcCommand) -> String in
        return String(decoding: command.publish.data, as: UTF8.self)
    }
}


/// The scheduled timers that are not timeouts. A publish arms no such timer; the window timer is one.
private func nonLateCallCount(_ scheduler: ManualScheduler) -> Int {
    return scheduler.scheduledCalls.filter { (call: ScheduledCall) -> Bool in
        return !call.lateGrace
    }.count
}


@Suite(.serialized, .timeLimit(.minutes(1)))
final class PublishDebounceTests: @unchecked Sendable {
    private let fake: FakeRpcServer


    init() throws {
        fake = try FakeRpcServer()
    }


    deinit {
        fake.server.stop()
    }


    // MARK: helpers

    /// Connects a client on the manual clock, and subscribes the debounced channel with the window the server
    /// gives in its subscribe result. Returns once the subscription is subscribed.
    private func connectAndSubscribe(windowMillis: UInt32) async throws -> DebounceSession {
        fake.server.connectResult.ping = 0
        fake.server.onSubscribe = { (_: String, _: FakeCentrifugoServer.PSubscribeRequest) -> FakeCentrifugoServer.PSubscribeResult in
            var result: FakeCentrifugoServer.PSubscribeResult = FakeCentrifugoServer.PSubscribeResult()
            result.publishDebounce = windowMillis
            return result
        }
        fake.setAnswer { (command: RpcCommand) -> RpcReply? in
            guard command.hasPublish else {
                return nil
            }
            var reply: RpcReply = RpcReply()
            if command.publish.data == Data(refusedPayload.utf8) {
                reply.error.code = refusedCode
                reply.error.message = "refused"
            } else {
                reply.publish = Centrifugal_Centrifuge_Protocol_PublishResult()
            }
            return reply
        }
        let connected: RecordingClientDelegate = RecordingClientDelegate(connected: Expectation("connected"))
        let setup: ManualClientSetup = makeManualClient(
            endpoint: fake.server.url,
            config: CentrifugeClientConfig(),
            delegate: connected,
            random: ManualRandom()
        )
        setup.client.connect()
        await connected.awaitConnected(times: 1)
        let subDelegate: ClosureSubscriptionDelegate = ClosureSubscriptionDelegate()
        let subscribed: Expectation = Expectation("subscribed")
        subDelegate.onSub = {
            subscribed.fulfill()
        }
        let subscription: CentrifugeSubscription = try setup.client.newSubscription(channel: debounceChannel, delegate: subDelegate)
        subscription.subscribe()
        await fulfillment(of: subscribed, within: 5)
        return DebounceSession(
            client: setup.client,
            scheduler: setup.scheduler,
            connected: connected,
            subscription: subscription,
            subDelegate: subDelegate
        )
    }


    /// Publishes `text` on the debounced subscription, recording its completion in `log`.
    private func publish(_ session: DebounceSession, _ text: String, _ log: CompletionLog) {
        session.subscription.publish(data: Data(text.utf8)) { (result: Result<CentrifugePublishResult, Error>) in
            log.record(result)
        }
    }


    /// Returns once every block the client's queue had before this call has run.
    private func drain(_ client: CentrifugeClient) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            client.syncQueue.async {
                continuation.resume()
            }
        }
    }


    /// Returns once the server has received a marker publish that the client sent after everything it had queued.
    private func syncWithServer(_ client: CentrifugeClient) async {
        let marker: Data = Data(UUID().uuidString.utf8)
        client.publish(channel: markerChannel, data: marker) { (_: Result<CentrifugePublishResult, Error>) in
        }
        await fake.awaitArrivals("marker publish") { (command: RpcCommand) -> Bool in
            return command.hasPublish && command.publish.channel == markerChannel && command.publish.data == marker
        }
    }


    // MARK: publish debounce

    @Test func publishFirstIsSentAtOnceAndWindowCoalescesTheRest() async throws {
        let session: DebounceSession = try await connectAndSubscribe(windowMillis: debounceWindowMillis)
        let first: CompletionLog = CompletionLog()
        let second: CompletionLog = CompletionLog()
        let third: CompletionLog = CompletionLog()

        publish(session, "1", first)
        await fake.awaitArrivals("first publish") { (command: RpcCommand) -> Bool in
            return isDebouncedPublish(command, "1")
        }
        publish(session, "2", second)
        publish(session, "3", third)
        await drain(session.client)

        #expect(second.successes == 1, "a coalesced publish completes at once")
        #expect(third.successes == 1, "a coalesced publish completes at once")
        await syncWithServer(session.client)
        #expect(debouncedPayloads(fake) == ["1"], "nothing is sent inside the window")

        await session.scheduler.advance(by: debounceWindowSeconds)
        await fake.awaitArrivals("pending publish") { (command: RpcCommand) -> Bool in
            return isDebouncedPublish(command, "3")
        }
        await syncWithServer(session.client)
        #expect(debouncedPayloads(fake) == ["1", "3"], "the window sends the latest value only")
        await fulfillment(of: first.finished, within: 5)
        #expect(first.successes == 1)
    }


    @Test func idleWindowEndsAndNextPublishIsSentAtOnce() async throws {
        let session: DebounceSession = try await connectAndSubscribe(windowMillis: debounceWindowMillis)
        let first: CompletionLog = CompletionLog()
        let second: CompletionLog = CompletionLog()

        publish(session, "1", first)
        await fake.awaitArrivals("first publish") { (command: RpcCommand) -> Bool in
            return isDebouncedPublish(command, "1")
        }
        await fulfillment(of: first.finished, within: 5)
        await session.scheduler.advance(by: debounceWindowSeconds)
        await session.scheduler.advance(by: debounceWindowSeconds)
        await drain(session.client)

        publish(session, "2", second)
        await fake.awaitArrivals("publish after an idle window") { (command: RpcCommand) -> Bool in
            return isDebouncedPublish(command, "2")
        }
        #expect(debouncedPayloads(fake) == ["1", "2"])
        await fulfillment(of: second.finished, within: 5)
        #expect(second.successes == 1)
    }


    @Test func unsubscribeDropsPendingValue() async throws {
        let session: DebounceSession = try await connectAndSubscribe(windowMillis: debounceWindowMillis)
        let first: CompletionLog = CompletionLog()
        let second: CompletionLog = CompletionLog()

        publish(session, "1", first)
        await fake.awaitArrivals("first publish") { (command: RpcCommand) -> Bool in
            return isDebouncedPublish(command, "1")
        }
        await fulfillment(of: first.finished, within: 5)
        publish(session, "2", second)
        await drain(session.client)
        session.subscription.unsubscribe()
        await drain(session.client)
        await session.scheduler.advance(by: 2 * debounceWindowSeconds)
        await syncWithServer(session.client)

        #expect(debouncedPayloads(fake) == ["1"], "the pending value is not sent after unsubscribe")
    }


    @Test func reconnectDropsPendingValue() async throws {
        let session: DebounceSession = try await connectAndSubscribe(windowMillis: debounceWindowMillis)
        let first: CompletionLog = CompletionLog()
        let second: CompletionLog = CompletionLog()
        let third: CompletionLog = CompletionLog()

        publish(session, "1", first)
        await fake.awaitArrivals("first publish") { (command: RpcCommand) -> Bool in
            return isDebouncedPublish(command, "1")
        }
        await fulfillment(of: first.finished, within: 5)
        publish(session, "2", second)
        await drain(session.client)

        let connectsBefore: Int = session.connected.connectingEvents
        fake.server.closeConnection()
        await session.connected.awaitConnecting(times: connectsBefore + 1)
        await drain(session.client)
        let resubscribed: Expectation = Expectation("resubscribed")
        session.subDelegate.onSub = {
            resubscribed.fulfill()
        }
        await session.scheduler.advance(by: 1.5)
        await session.connected.awaitConnected(times: 2)
        await fulfillment(of: resubscribed, within: 5)

        publish(session, "3", third)
        await fake.awaitArrivals("publish after the reconnect") { (command: RpcCommand) -> Bool in
            return isDebouncedPublish(command, "3")
        }
        await syncWithServer(session.client)
        #expect(debouncedPayloads(fake) == ["1", "3"], "the pending value of the lost connection is not sent")
    }


    @Test func zeroWindowSendsEveryPublish() async throws {
        let session: DebounceSession = try await connectAndSubscribe(windowMillis: 0)
        let first: CompletionLog = CompletionLog()
        let second: CompletionLog = CompletionLog()
        let third: CompletionLog = CompletionLog()
        await drain(session.client)
        let timedBefore: Int = nonLateCallCount(session.scheduler)

        publish(session, "1", first)
        publish(session, "2", second)
        publish(session, "3", third)
        await fake.awaitArrivals("three publishes", count: 3) { (command: RpcCommand) -> Bool in
            return command.hasPublish && command.publish.channel == debounceChannel
        }

        #expect(debouncedPayloads(fake) == ["1", "2", "3"])
        #expect(nonLateCallCount(session.scheduler) == timedBefore, "no window timer is armed")
    }


    @Test func windowAboveSignedIntRangeIsCapped() async throws {
        // 2^31 + 1 ms: above the cap of 2^31 - 1 ms that every SDK honours.
        let session: DebounceSession = try await connectAndSubscribe(windowMillis: 2_147_483_649)
        let first: CompletionLog = CompletionLog()
        let second: CompletionLog = CompletionLog()

        publish(session, "1", first)
        await fake.awaitArrivals("first publish") { (command: RpcCommand) -> Bool in
            return isDebouncedPublish(command, "1")
        }
        await fulfillment(of: first.finished, within: 5)
        #expect(lastNonLateTimerDelay(session.scheduler) == 2147483.647, "the window is capped at 2^31 - 1 ms")

        publish(session, "2", second)
        await drain(session.client)
        // One millisecond short of the cap: the window is still open.
        await session.scheduler.advance(by: 2147483.646)
        await syncWithServer(session.client)
        #expect(debouncedPayloads(fake) == ["1"], "the window is still open before the cap")

        // Two milliseconds more: past the cap, so the pending value goes out.
        await session.scheduler.advance(by: 0.002)
        await fake.awaitArrivals("pending publish after the cap") { (command: RpcCommand) -> Bool in
            return isDebouncedPublish(command, "2")
        }
        #expect(debouncedPayloads(fake) == ["1", "2"])
    }


    @Test func timerDrivenPublishRefusedByServerDoesNotStopTheNextWindow() async throws {
        let session: DebounceSession = try await connectAndSubscribe(windowMillis: debounceWindowMillis)
        let first: CompletionLog = CompletionLog()
        let refused: CompletionLog = CompletionLog()
        let third: CompletionLog = CompletionLog()

        publish(session, "1", first)
        await fake.awaitArrivals("first publish") { (command: RpcCommand) -> Bool in
            return isDebouncedPublish(command, "1")
        }
        await fulfillment(of: first.finished, within: 5)
        publish(session, refusedPayload, refused)
        await drain(session.client)

        await session.scheduler.advance(by: debounceWindowSeconds)
        await fake.awaitArrivals("refused publish sent by the timer") { (command: RpcCommand) -> Bool in
            return isDebouncedPublish(command, refusedPayload)
        }
        await syncWithServer(session.client)
        #expect(refused.successes == 1, "the coalesced publish completed at once")

        publish(session, "3", third)
        await drain(session.client)
        await session.scheduler.advance(by: debounceWindowSeconds)
        await fake.awaitArrivals("publish of the next window") { (command: RpcCommand) -> Bool in
            return isDebouncedPublish(command, "3")
        }
        await syncWithServer(session.client)

        #expect(debouncedPayloads(fake) == ["1", refusedPayload, "3"])
        #expect(session.subscription.state == .subscribed)
    }


    @Test func throwingCallbackOfCoalescedPublishRunsOnce() async throws {
        // A Swift completion cannot throw. The row checks the part of it that the debounce controls: the
        // completion of a coalesced publish runs once, when it is coalesced, and not again when its value is sent.
        let session: DebounceSession = try await connectAndSubscribe(windowMillis: debounceWindowMillis)
        let first: CompletionLog = CompletionLog()
        let second: CompletionLog = CompletionLog()

        publish(session, "1", first)
        await fake.awaitArrivals("first publish") { (command: RpcCommand) -> Bool in
            return isDebouncedPublish(command, "1")
        }
        await fulfillment(of: first.finished, within: 5)
        publish(session, "2", second)
        await drain(session.client)

        await session.scheduler.advance(by: debounceWindowSeconds)
        await fake.awaitArrivals("coalesced publish sent") { (command: RpcCommand) -> Bool in
            return isDebouncedPublish(command, "2")
        }
        await syncWithServer(session.client)

        #expect(second.count == 1, "the callback runs once")
        #expect(second.successes == 1)
    }
}
