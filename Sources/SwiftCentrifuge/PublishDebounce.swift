import Foundation

// The publish debounce of a subscription. The server gives the window in the subscribe result
// (publishDebounce, ms; 0 is off). The first publish of a window is sent at once. The publishes that
// follow inside the window replace one pending value, which is sent when the window ends. The windows
// live in CentrifugeClient.publishDebounce, and one client-level timer runs at the earliest window end,
// so no subscription has a timer of its own. Everything here runs on syncQueue.

/// The largest window in ms that is honoured (2^31 - 1), the same cap in every SDK.
internal let publishDebounceMaxMillis: UInt32 = 2147483647


/// The debounce window of one subscription. A channel has at most one subscription in a client, so the
/// channel names the window.
internal struct PublishDebounceWindow {
    /// The window length in nanoseconds.
    let lengthNanos: UInt64
    /// The end of the open window in monotonic nanoseconds, or nil when no window is open.
    var deadline: UInt64?
    /// The latest value published while the window was open. It is sent when the window ends.
    var pending: Data?
}


/// The windows of a client and the one timer that ends the earliest of them.
internal struct PublishDebounceState {
    /// The windows of the subscriptions that have a nonzero window, by channel.
    var windows: [String: PublishDebounceWindow] = [:]
    /// The timer at the earliest open window end.
    var timer: ClientDeadlineTimer = ClientDeadlineTimer()
}


internal extension CentrifugeClient {
    /// Sets the window of a subscription from its subscribe result. Zero keeps every publish. A window
    /// starts closed; any open window or pending value of the channel is dropped first.
    func setPublishDebounceWindow(channel: String, millis: UInt32) {
        self.dropPublishDebounce(channel: channel)
        guard millis > 0 else {
            return
        }
        let capped: UInt32 = min(millis, publishDebounceMaxMillis)
        let length: UInt64 = UInt64(capped) * 1_000_000
        self.publishDebounce.windows[channel] = PublishDebounceWindow(lengthNanos: length, deadline: nil, pending: nil)
    }


    /// Drops the window of a channel: its open window and its pending value. Called when the subscription is
    /// unsubscribed.
    func dropPublishDebounce(channel: String) {
        guard self.publishDebounce.windows.removeValue(forKey: channel) != nil else {
            return
        }
        self.rearmPublishDebounce()
    }


    /// Drops every window and cancels the timer. Called at a disconnect: pending values are dropped, and the
    /// subscribe reply of the next connect sets the window again.
    func resetPublishDebounce() {
        self.publishDebounce.windows.removeAll()
        self.publishDebounce.timer.cancel()
    }


    /// Publishes for a subscription that has its window. The first publish of a window is sent at once and
    /// opens the window; a publish inside an open window replaces the pending value and completes at once.
    /// A window stays open until its timer runs, even when its deadline has passed, so a publish that arrives
    /// before the timer is coalesced into the pending value (as the JS and Java SDKs do). A channel without a
    /// window is published as it is.
    func publishThroughDebounce(channel: String, data: Data, completion: @escaping (Result<CentrifugePublishResult, Error>) -> ()) {
        let now: UInt64 = self.clock.monotonicNanos()
        guard var window: PublishDebounceWindow = self.publishDebounce.windows[channel] else {
            self.publish(channel: channel, data: data, completion: completion)
            return
        }
        if window.deadline != nil {
            window.pending = data
            self.publishDebounce.windows[channel] = window
            self.rearmPublishDebounce()
            completion(.success(CentrifugePublishResult()))
            return
        }
        window.deadline = now + window.lengthNanos
        self.publishDebounce.windows[channel] = window
        self.rearmPublishDebounce()
        self.publish(channel: channel, data: data, completion: completion)
    }


    /// Ends the window of a channel when its deadline has passed. A pending value is sent and a new window
    /// starts; without one the window goes idle. The error of that send is not reported, as its completion has
    /// already run. The caller re-arms the timer.
    private func endPublishDebounceWindowIfDue(channel: String, now: UInt64) {
        guard var window: PublishDebounceWindow = self.publishDebounce.windows[channel],
              let deadline: UInt64 = window.deadline,
              deadline <= now else {
            return
        }
        guard let value: Data = window.pending else {
            window.deadline = nil
            self.publishDebounce.windows[channel] = window
            return
        }
        window.pending = nil
        window.deadline = now + window.lengthNanos
        self.publishDebounce.windows[channel] = window
        self.publish(channel: channel, data: value, completion: { (_: Result<CentrifugePublishResult, Error>) in })
    }


    /// Runs when the one timer fires: ends every window that is due, then waits for the next earliest end.
    private func publishDebounceTimerFired() {
        self.publishDebounce.timer.forget()
        let now: UInt64 = self.clock.monotonicNanos()
        for channel: String in Array(self.publishDebounce.windows.keys) {
            self.endPublishDebounceWindowIfDue(channel: channel, now: now)
        }
        self.rearmPublishDebounce()
    }


    /// Keeps the one timer at the earliest open window end, or cancels it when no window is open.
    private func rearmPublishDebounce() {
        let earliest: UInt64? = self.earliestPublishDebounceDeadline()
        self.publishDebounce.timer.rearm(at: earliest, on: self, lateGrace: false) { [weak self] in
            self?.publishDebounceTimerFired()
        }
    }


    /// The earliest open window end, or nil when no window is open. It scans the windows on each window open
    /// and each timer fire. The bound is the subscriptions of one client: only a subscription with a nonzero
    /// window has an entry, so the scan never grows with the number of calls or of connections.
    private func earliestPublishDebounceDeadline() -> UInt64? {
        var earliest: UInt64? = nil
        for window: PublishDebounceWindow in self.publishDebounce.windows.values {
            if let deadline: UInt64 = window.deadline {
                earliest = earlierNanos(earliest, deadline)
            }
        }
        return earliest
    }
}
