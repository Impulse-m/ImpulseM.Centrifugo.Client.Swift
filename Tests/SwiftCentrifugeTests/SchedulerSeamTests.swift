import Foundation
import Testing
@testable import SwiftCentrifuge

/// The clock and scheduler seams of Scheduler.swift, driven by ManualScheduler.swift.
@Suite(.serialized, .timeLimit(.minutes(1)))
final class SchedulerSeamTests: @unchecked Sendable {
    /// Records the names of the work items that ran, in order.
    private final class Recorder: @unchecked Sendable {
        private let names: LockedBox<[String]> = LockedBox([])


        func add(_ name: String) {
            names.update { (values: inout [String]) in
                values.append(name)
            }
        }


        var all: [String] {
            return names.current
        }
    }


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


    @Test func manualSchedulerRunsDueItemsOnceAndKeepsTheRest() async {
        let queue: DispatchQueue = DispatchQueue(label: "scheduler-seam-test")
        let clock: ManualClock = ManualClock()
        let scheduler: ManualScheduler = ManualScheduler(queue: queue, clock: clock)
        let recorder: Recorder = Recorder()
        scheduler.schedule(after: 1, lateGrace: false, DispatchWorkItem { recorder.add("first") })
        scheduler.schedule(after: 5, lateGrace: false, DispatchWorkItem { recorder.add("second") })

        await scheduler.advance(by: 2)
        #expect(recorder.all == ["first"])

        await scheduler.advance(by: 3)
        #expect(recorder.all == ["first", "second"])

        await scheduler.advance(by: 100)
        #expect(recorder.all == ["first", "second"], "an item runs once")
    }


    /// The 5 s item is scheduled first, so insertion order is the reverse of due order.
    /// Both are due when the advance ends; the 1 s item must run first.
    @Test func manualSchedulerRunsTheEarliestDueItemFirst() async {
        let queue: DispatchQueue = DispatchQueue(label: "scheduler-seam-test")
        let clock: ManualClock = ManualClock()
        let scheduler: ManualScheduler = ManualScheduler(queue: queue, clock: clock)
        let recorder: Recorder = Recorder()
        scheduler.schedule(after: 5, lateGrace: false, DispatchWorkItem { recorder.add("five") })
        scheduler.schedule(after: 1, lateGrace: false, DispatchWorkItem { recorder.add("one") })

        await scheduler.advance(by: 6)
        #expect(recorder.all == ["one", "five"], "due order, not insertion order")
    }


    @Test func cancelledItemsDoNotRun() async {
        let queue: DispatchQueue = DispatchQueue(label: "scheduler-seam-test")
        let clock: ManualClock = ManualClock()
        let scheduler: ManualScheduler = ManualScheduler(queue: queue, clock: clock)
        let recorder: Recorder = Recorder()
        let item: DispatchWorkItem = DispatchWorkItem { recorder.add("cancelled") }
        scheduler.schedule(after: 1, lateGrace: false, item)
        item.cancel()

        await scheduler.advance(by: 2)
        #expect(recorder.all.isEmpty)
    }


    @Test func itemsScheduledDuringAnAdvanceRunWhenTheyAreDue() async {
        let queue: DispatchQueue = DispatchQueue(label: "scheduler-seam-test")
        let clock: ManualClock = ManualClock()
        let scheduler: ManualScheduler = ManualScheduler(queue: queue, clock: clock)
        let recorder: Recorder = Recorder()
        let later: DispatchWorkItem = DispatchWorkItem { recorder.add("later") }
        let distant: DispatchWorkItem = DispatchWorkItem { recorder.add("distant") }
        let first: DispatchWorkItem = DispatchWorkItem {
            recorder.add("first")
            scheduler.schedule(after: 0, lateGrace: false, later)
            scheduler.schedule(after: 10, lateGrace: false, distant)
        }
        scheduler.schedule(after: 0, lateGrace: false, first)

        await scheduler.advance(by: 0)
        #expect(recorder.all == ["first", "later"])
    }


    /// The factory's clock argument must be the clock the client was given, and the open
    /// timeout must go through the scheduler it returns. No token getter is set, so the
    /// connect attempt reaches the open timeout before `awaitSyncQueue` returns.
    @Test func timeoutsAreScheduledThroughTheInjectedScheduler() async {
        let manualClock: ManualClock = ManualClock()
        let holder: LockedBox<ManualScheduler?> = LockedBox(nil)
        let receivedClock: LockedBox<ClientClock?> = LockedBox(nil)
        var config: CentrifugeClientConfig = CentrifugeClientConfig()
        config.timeout = 7
        let client: CentrifugeClient = CentrifugeClient(
            endpoint: server.url,
            config: config,
            delegate: nil,
            clock: manualClock,
            schedulerFactory: { (queue: DispatchQueue, factoryClock: ClientClock) -> ClientScheduler in
                receivedClock.set(factoryClock)
                let manual: ManualScheduler = ManualScheduler(
                    queue: queue,
                    clock: factoryClock as? ManualClock ?? ManualClock()
                )
                holder.set(manual)
                return manual
            }
        )
        client.connect()
        await awaitSyncQueue(client)
        defer {
            client.disconnect()
        }

        #expect(receivedClock.current as? ManualClock === manualClock, "the client passes its own clock to the factory")
        let scheduler: ManualScheduler? = holder.current
        #expect(scheduler != nil)
        let openTimeout: ScheduledCall? = scheduler?.scheduledCalls.first { (call: ScheduledCall) -> Bool in
            call.delay == 7
        }
        #expect(openTimeout != nil, "the open timeout goes through the injected scheduler")
        #expect(openTimeout?.lateGrace == true, "a timeout asks for the late-timer grace")
    }


    /// Timeouts pass `lateGrace` true; the reconnect, refresh and resubscribe timers pass false.
    @Test func timeoutsPassLateGraceAndOtherTimersDoNot() {
        let manualClock: ManualClock = ManualClock()
        let holder: LockedBox<ManualScheduler?> = LockedBox(nil)
        let client: CentrifugeClient = CentrifugeClient(
            endpoint: server.url,
            config: CentrifugeClientConfig(),
            delegate: nil,
            clock: manualClock,
            schedulerFactory: { (queue: DispatchQueue, factoryClock: ClientClock) -> ClientScheduler in
                let manual: ManualScheduler = ManualScheduler(
                    queue: queue,
                    clock: factoryClock as? ManualClock ?? ManualClock()
                )
                holder.set(manual)
                return manual
            }
        )
        client.scheduleTimeout(after: 3, DispatchWorkItem {})
        client.scheduleAfter(4, DispatchWorkItem {})

        let calls: [ScheduledCall] = holder.current?.scheduledCalls ?? []
        #expect(calls.count == 2)
        #expect(calls.first?.delay == 3)
        #expect(calls.first?.lateGrace == true, "a timeout passes lateGrace true")
        #expect(calls.last?.delay == 4)
        #expect(calls.last?.lateGrace == false, "a non-timeout timer passes lateGrace false")
    }


    @Test func clientNanosTreatsNonPositiveAndNaNDelaysAsZero() {
        #expect(clientNanos(-1) == 0)
        #expect(clientNanos(Double.nan) == 0)
        #expect(clientNanos(0.5) == 500_000_000)
        #expect(clientNanos(Double.infinity) == 9_000_000_000_000_000_000, "the delay is capped at 9e9 seconds")
    }
}
