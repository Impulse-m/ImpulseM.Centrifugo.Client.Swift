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

    @Test func timeoutsAreScheduledThroughTheInjectedScheduler() async {
        let manualClock: ManualClock = ManualClock()
        let holder: LockedBox<ManualScheduler?> = LockedBox(nil)
        var config: CentrifugeClientConfig = CentrifugeClientConfig()
        config.timeout = 7
        let client: CentrifugeClient = CentrifugeClient(
            endpoint: server.url,
            config: config,
            delegate: nil,
            clock: manualClock,
            random: ManualRandom(draw: 0.5),
            schedulerFactory: { (queue: DispatchQueue, clock: ClientClock) -> ClientScheduler in
                let manual: ManualScheduler = ManualScheduler(queue: queue, clock: manualClock)
                holder.set(manual)
                return manual
            }
        )
        client.connect()
        await awaitSyncQueue(client)
        defer {
            client.disconnect()
        }

        let scheduler: ManualScheduler? = holder.current
        #expect(scheduler != nil)
        #expect(scheduler?.scheduledDelays.contains(7) == true, "the open timeout goes through the injected scheduler")
    }

    @Test func clientNanosTreatsNonPositiveAndNaNDelaysAsZero() {
        #expect(clientNanos(-1) == 0)
        #expect(clientNanos(Double.nan) == 0)
        #expect(clientNanos(0.5) == 500_000_000)
        #expect(clientNanos(Double.infinity) == 9_000_000_000_000_000_000, "the delay is capped at 9e9 seconds")
    }
}
