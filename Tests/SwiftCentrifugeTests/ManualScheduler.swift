import Foundation
@testable import SwiftCentrifuge

// Test doubles of the clock, random and scheduler seams (Scheduler.swift).
//
// ManualScheduler and ManualClock are one coupled object: advancing the scheduler
// moves the clock by the same delta. The test body calls `advance(by:)`; a delegate
// callback never does. Nothing here calls `syncQueue.sync`.

/// A clock the test moves by hand.
final class ManualClock: ClientClock, @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var nanos: UInt64 = 1_000_000_000
    private let baseWallMillis: Int64 = 1_700_000_000_000

    func monotonicNanos() -> UInt64 {
        lock.lock()
        defer {
            lock.unlock()
        }
        return nanos
    }

    func wallMillis() -> Int64 {
        lock.lock()
        defer {
            lock.unlock()
        }
        return baseWallMillis + Int64(nanos / 1_000_000)
    }

    func advance(by delta: TimeInterval) {
        lock.lock()
        nanos += clientNanos(delta)
        lock.unlock()
    }
}

/// A random source whose draw the test sets. Draw 0 gives the lower bound of a range,
/// draw 1 the upper bound.
final class ManualRandom: ClientRandom, @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var draw: Double

    init(draw: Double) {
        self.draw = draw
    }

    func setDraw(_ value: Double) {
        lock.lock()
        draw = value
        lock.unlock()
    }

    func uniform(_ range: ClosedRange<Double>) -> Double {
        lock.lock()
        let current: Double = draw
        lock.unlock()
        return range.lowerBound + (range.upperBound - range.lowerBound) * current
    }

    /// The same draw for an integer range, as the msg_id random source of MsgIdGenerator.
    func uint64(_ range: ClosedRange<UInt64>) -> UInt64 {
        lock.lock()
        let current: Double = draw
        lock.unlock()
        let span: Double = Double(range.upperBound - range.lowerBound)
        return range.lowerBound + UInt64(span * current)
    }
}

/// Holds work items until the test advances the clock past their due time.
final class ManualScheduler: ClientScheduler, @unchecked Sendable {
    private struct Pending {
        let due: UInt64
        let item: DispatchWorkItem
    }

    private let lock: NSLock = NSLock()
    private let queue: DispatchQueue
    private let clock: ManualClock
    // In insertion order; among equal due times the earlier insertion runs first.
    private var pending: [Pending] = []
    private var delays: [TimeInterval] = []

    init(queue: DispatchQueue, clock: ManualClock) {
        self.queue = queue
        self.clock = clock
    }

    /// The delay of every item scheduled so far, in order.
    var scheduledDelays: [TimeInterval] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return delays
    }

    func schedule(after delay: TimeInterval, _ item: DispatchWorkItem) {
        lock.lock()
        let due: UInt64 = clock.monotonicNanos() + clientNanos(delay)
        pending.append(Pending(due: due, item: item))
        delays.append(delay)
        lock.unlock()
    }

    /// Moves the clock by `delta`, then runs every due item on the client's queue, in due
    /// order. Items that the run schedules and that are due by then run too. Returns once
    /// no item is due.
    func advance(by delta: TimeInterval) async {
        clock.advance(by: delta)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.queue.async {
                self.runDueItems()
                continuation.resume()
            }
        }
    }

    private func runDueItems() {
        while let item = takeNextDue() {
            item.perform()
        }
    }

    /// The earliest due item that is not cancelled, removed from the pending list.
    private func takeNextDue() -> DispatchWorkItem? {
        lock.lock()
        defer {
            lock.unlock()
        }
        let now: UInt64 = clock.monotonicNanos()
        while let index = earliestDueIndex(now: now) {
            let entry: Pending = pending.remove(at: index)
            if !entry.item.isCancelled {
                return entry.item
            }
        }
        return nil
    }

    private func earliestDueIndex(now: UInt64) -> Int? {
        var best: Int? = nil
        for index in pending.indices where pending[index].due <= now {
            guard let current = best else {
                best = index
                continue
            }
            if pending[index].due < pending[current].due {
                best = index
            }
        }
        return best
    }
}
