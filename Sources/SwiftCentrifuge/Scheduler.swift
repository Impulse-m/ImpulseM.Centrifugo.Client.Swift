import Foundation

// The clock, random and scheduler seams of the client. Library code reads time and
// randomness through these protocols, so tests drive them by hand (see
// ManualScheduler.swift in the test target). The System and Dispatch types below
// are the production values. One exception: getBackoffDelay (Client.swift) keeps
// Double.random for its other callers.

/// Monotonic and wall-clock time.
internal protocol ClientClock {
    /// Monotonic time in nanoseconds, for deadlines.
    func monotonicNanos() -> UInt64

    /// Wall-clock time in milliseconds since the unix epoch, for the server time offset.
    func wallMillis() -> Int64
}

/// Uniform random numbers in a closed range.
internal protocol ClientRandom {
    /// A UInt64 in the range (msg_id lanes).
    func uniform(_ range: ClosedRange<UInt64>) -> UInt64
}

/// Runs a work item on the client's queue after a delay. The caller keeps the item
/// as its cancel handle.
internal protocol ClientScheduler {
    /// Runs `item` after `delay`. With `lateGrace`, an item that fires much later than
    /// scheduled (a suspended process) runs after the grace period instead; timeouts
    /// pass true, the other timers false.
    func schedule(after delay: TimeInterval, lateGrace: Bool, _ item: DispatchWorkItem)
}

/// Builds the scheduler of a client from its queue and clock.
internal typealias ClientSchedulerFactory = (DispatchQueue, ClientClock) -> ClientScheduler

internal struct SystemClientClock: ClientClock {
    internal func monotonicNanos() -> UInt64 {
        return DispatchTime.now().uptimeNanoseconds
    }


    internal func wallMillis() -> Int64 {
        let millis: Double = Date().timeIntervalSince1970 * 1000
        return Int64(millis)
    }
}

internal struct SystemClientRandom: ClientRandom {
    internal func uniform(_ range: ClosedRange<UInt64>) -> UInt64 {
        return UInt64.random(in: range)
    }
}

/// How long a timeout that fired late (after the process was suspended) waits for what arrived
/// meanwhile. See `DispatchClientScheduler.schedule`.
internal let lateTimerGrace: TimeInterval = 1

/// Production scheduler: a DispatchQueue timer on the client's queue. With `lateGrace`,
/// a timer that fires much later than scheduled means the process was suspended (frozen
/// in the background, stopped in a debugger): replies and pings that arrived meanwhile
/// may still be waiting in the socket, so the item runs after a short grace period
/// instead, letting them be handled first. The late-timer rule lives only here.
internal final class DispatchClientScheduler: ClientScheduler {
    private let queue: DispatchQueue
    private let clock: ClientClock


    internal init(queue: DispatchQueue, clock: ClientClock) {
        self.queue = queue
        self.clock = clock
    }


    internal func schedule(after delay: TimeInterval, lateGrace: Bool, _ item: DispatchWorkItem) {
        if !lateGrace {
            self.queue.asyncAfter(deadline: .now() + delay, execute: item)
            return
        }
        let deadlineNanos: UInt64 = self.clock.monotonicNanos() + clientNanos(delay)
        self.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let strongSelf: DispatchClientScheduler = self, !item.isCancelled else {
                return
            }
            let now: UInt64 = strongSelf.clock.monotonicNanos()
            let late: Double = now > deadlineNanos ? clientSeconds(nanos: now - deadlineNanos) : 0
            if late > lateTimerGrace {
                strongSelf.queue.asyncAfter(deadline: .now() + lateTimerGrace, execute: item)
            } else {
                item.perform()
            }
        }
    }
}


/// Nanoseconds of a delay in seconds, for deadlines computed from an injected clock.
/// A delay that is not above zero (negative or NaN) counts as zero; the value is capped
/// far beyond any timer.
internal func clientNanos(_ delay: TimeInterval) -> UInt64 {
    if !(delay > 0) {
        return 0
    }
    let seconds: Double = min(delay, 9e9)
    return UInt64(seconds * 1e9)
}

/// Seconds of a duration in nanoseconds, the inverse of clientNanos.
internal func clientSeconds(nanos: UInt64) -> TimeInterval {
    return Double(nanos) / 1e9
}

/// The earlier of an optional moment and a candidate; the candidate when there is none yet.
internal func earlierNanos(_ current: UInt64?, _ candidate: UInt64) -> UInt64 {
    guard let known: UInt64 = current else {
        return candidate
    }
    return min(known, candidate)
}

extension CentrifugeClient {
    /// Runs `item` on syncQueue once `delay` has passed. The hook of the timers that
    /// are not timeouts (reconnect, connection and subscription refresh, resubscribe).
    /// They get no late-timer grace, as before the seams.
    internal func scheduleAfter(_ delay: TimeInterval, _ item: DispatchWorkItem) {
        self.scheduler.schedule(after: delay, lateGrace: false, item)
    }
}


/// A full-jitter delay in nanoseconds: uniform over `0 ... min(cap, base * 2^attempt)`, drawn from the
/// injected source. The exponent is capped, so the product cannot overflow. The draw is never above
/// `cap`, so no further clamp is needed. The backoff of getBackoffDelay (Client.swift) keeps Double.random
/// for its other callers.
internal func fullJitterNanos(base: UInt64, attempt: Int, cap: UInt64, random: ClientRandom) -> UInt64 {
    let shift: Int = max(0, min(attempt, 62))
    let scaled: (partialValue: UInt64, overflow: Bool) = base.multipliedReportingOverflow(by: UInt64(1) << UInt64(shift))
    let ceiling: UInt64 = scaled.overflow ? cap : min(scaled.partialValue, cap)
    return random.uniform(0 ... ceiling)
}


/// A backoff delay in nanoseconds, the shape of the Java SDK's Backoff: min(ceiling, minimum + jitter), where the
/// jitter is a full-jitter draw over `0 ... min(ceiling, minimum * 2^attempt)` from the injected source.
internal func boundedBackoffNanos(
    minimumNanos: UInt64,
    ceilingNanos: UInt64,
    attempt: Int,
    random: ClientRandom
) -> UInt64 {
    let jitter: UInt64 = fullJitterNanos(base: minimumNanos, attempt: attempt, cap: ceilingNanos, random: random)
    return min(ceilingNanos, minimumNanos + jitter)
}


/// A uniform fraction in [0, 1] from the injected source: a count out of one billion steps, divided by it.
internal func uniformFraction(_ random: ClientRandom) -> Double {
    let steps: UInt64 = 1_000_000_000
    return Double(random.uniform(0 ... steps - 1)) / Double(steps)
}


/// A client's timer for the earliest of the moments that wait for it: the tracker's deadlines, the window
/// ends of the publish debounce. The timer is re-armed only when that moment changes, so a client holds one
/// of these per use and never one per call or subscription.
internal struct ClientDeadlineTimer {
    /// The work item of the armed timer, or nil when none is armed.
    private var item: DispatchWorkItem? = nil
    /// The moment the armed timer runs at, in monotonic nanoseconds, or nil when none is armed.
    private var due: UInt64? = nil


    /// Keeps the timer at `next`. A timer armed for that moment stays. Any other timer is cancelled, and a
    /// new one is scheduled at `next` unless it is nil. `onFire` runs on the client's queue when the timer runs.
    mutating func rearm(
        at next: UInt64?,
        on client: CentrifugeClient,
        lateGrace: Bool,
        onFire: @escaping () -> Void
    ) {
        if next == self.due {
            return
        }
        self.cancel()
        guard let moment: UInt64 = next else {
            return
        }
        let now: UInt64 = client.clock.monotonicNanos()
        let delay: TimeInterval = moment > now ? clientSeconds(nanos: moment - now) : 0
        let item: DispatchWorkItem = DispatchWorkItem {
            onFire()
        }
        self.item = item
        self.due = moment
        client.scheduler.schedule(after: delay, lateGrace: lateGrace, item)
    }


    /// Whether a timer is armed and has not run yet.
    var isArmed: Bool {
        return self.item != nil
    }


    /// Cancels the armed timer, if any.
    mutating func cancel() {
        self.item?.cancel()
        self.forget()
    }


    /// Drops the handle of a timer that has run, so the next `rearm` schedules afresh. It does not cancel.
    mutating func forget() {
        self.item = nil
        self.due = nil
    }
}
