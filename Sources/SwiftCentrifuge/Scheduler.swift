import Foundation

// The clock, random and scheduler seams of the client. Library code reads time and
// randomness only through these protocols, so tests drive them by hand (see
// ManualScheduler.swift in the test target). The System and Dispatch types below
// are the production values.

/// Monotonic and wall-clock time.
internal protocol ClientClock {
    /// Monotonic time in nanoseconds, for deadlines.
    func monotonicNanos() -> UInt64

    /// Wall-clock time in milliseconds since the Unix epoch.
    func wallMillis() -> Int64
}

/// Uniform random numbers in a closed range of Doubles.
internal protocol ClientRandom {
    func uniform(_ range: ClosedRange<Double>) -> Double
}

/// Runs a work item on the client's queue after a delay. The caller keeps the item
/// as its cancel handle.
internal protocol ClientScheduler {
    func schedule(after delay: TimeInterval, _ item: DispatchWorkItem)
}

/// Builds the scheduler of a client from its queue and clock.
internal typealias ClientSchedulerFactory = (DispatchQueue, ClientClock) -> ClientScheduler

internal struct SystemClientClock: ClientClock {
    internal func monotonicNanos() -> UInt64 {
        return DispatchTime.now().uptimeNanoseconds
    }

    internal func wallMillis() -> Int64 {
        return Int64(Date().timeIntervalSince1970 * 1000)
    }
}

internal struct SystemClientRandom: ClientRandom {
    internal func uniform(_ range: ClosedRange<Double>) -> Double {
        return Double.random(in: range)
    }
}

/// Production scheduler: a DispatchQueue timer on the client's queue. A timer that
/// fires much later than scheduled means the process was suspended (frozen in the
/// background, stopped in a debugger): replies and pings that arrived meanwhile may
/// still be waiting in the socket, so the item runs after a short grace period
/// instead, letting them be handled first.
internal final class DispatchClientScheduler: ClientScheduler {
    private let queue: DispatchQueue
    private let clock: ClientClock

    internal init(queue: DispatchQueue, clock: ClientClock) {
        self.queue = queue
        self.clock = clock
    }

    internal func schedule(after delay: TimeInterval, _ item: DispatchWorkItem) {
        let deadlineNanos: UInt64 = clock.monotonicNanos() + clientNanos(delay)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let strongSelf = self, !item.isCancelled else {
                return
            }
            let now: UInt64 = strongSelf.clock.monotonicNanos()
            let late: Double = now > deadlineNanos ? Double(now - deadlineNanos) / 1e9 : 0
            if late > lateTimerGrace {
                strongSelf.queue.asyncAfter(deadline: .now() + lateTimerGrace, execute: item)
            } else {
                item.perform()
            }
        }
    }
}

/// Nanoseconds of a delay in seconds, for deadlines computed from an injected clock.
/// Negative delays count as zero; the value is capped far beyond any timer.
internal func clientNanos(_ delay: TimeInterval) -> UInt64 {
    let seconds: Double = min(max(delay, 0), 9e9)
    return UInt64(seconds * 1e9)
}

extension CentrifugeClient {
    /// Runs `item` on syncQueue once `delay` has passed. The hook of the timers that
    /// are not timeouts (reconnect, connection and subscription refresh, resubscribe).
    internal func scheduleAfter(_ delay: TimeInterval, _ item: DispatchWorkItem) {
        self.scheduler.schedule(after: delay, item)
    }
}
