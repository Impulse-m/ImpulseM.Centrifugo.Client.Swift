import Foundation

// The ping watchdog of the connection. Client.swift arms it at connect (startWaitPing), stops it at disconnect
// (stopWaitPing) and records the clock time of every reply in lastReplyNanos. The timer and its re-arming live here.
// Everything runs on syncQueue.

internal extension CentrifugeClient {
    // Arms the one watchdog timer of the connection. Replies do not re-arm it: handleData only records lastReplyNanos,
    // and the timer re-arms itself when it fires.
    func startWaitPing() {
        if self.pingInterval == 0 {
            return
        }
        self.pingTimer?.cancel()
        self.lastReplyNanos = self.clock.monotonicNanos()
        self.armPingTimer(transportId: self.transportId, after: self.pingWindowSeconds())
    }


    func stopWaitPing() {
        self.pingTimer?.cancel()
    }


    // Arms the one watchdog timer of the connection to fire after `delay`.
    fileprivate func armPingTimer(transportId: UInt64, after delay: TimeInterval) {
        let pingTimer: DispatchWorkItem = DispatchWorkItem { [weak self] in
            guard let strongSelf: CentrifugeClient = self else {
                return
            }
            strongSelf.pingTimerFired(transportId: transportId)
        }
        self.pingTimer = pingTimer
        self.scheduleTimeout(after: delay, pingTimer)
    }


    // Fires once per window at most. A reply since the timer was armed moves the check to one window after that reply;
    // otherwise the connection has been silent for a whole window.
    fileprivate func pingTimerFired(transportId: UInt64) {
        guard self.isCurrentConnection(transportId) else {
            return
        }
        let window: UInt64 = clientNanos(self.pingWindowSeconds())
        let now: UInt64 = self.clock.monotonicNanos()
        let silent: UInt64 = now > self.lastReplyNanos ? now - self.lastReplyNanos : 0
        if silent < window {
            self.armPingTimer(transportId: transportId, after: clientSeconds(nanos: window - silent))
            return
        }
        self.processDisconnect(code: connectingCodeNoPing, reason: "no ping", reconnect: true)
    }


    fileprivate func pingWindowSeconds() -> TimeInterval {
        return Double(self.pingInterval) + self.config.maxServerPingDelay
    }
}
