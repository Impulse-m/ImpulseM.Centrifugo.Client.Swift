import Foundation

// The server time of a client. A command reply carries the server's Unix time
// in `Reply.time`. The client keeps the offset of that time from its own wall clock, and the
// server time is the local wall clock plus the offset. A reply without a time keeps the last
// offset. Before any reply the offset is zero, so the server time is the local time.
//
// The server is untrusted input. A reply time more
// than 365 days from the local clock is ignored, and every subtraction and addition reports
// overflow instead of trapping, so a hostile time cannot crash the app.

/// The largest offset a reply may set, in milliseconds (365 days). A larger one is ignored.
internal let serverTimeMaxOffsetMillis: Int64 = 365 * 86_400_000

/// The last server time offset, in milliseconds. It is written on syncQueue only, and read by
/// any thread through the lock, so `serverTimeMillis()` never waits for the queue.
internal final class ServerTimeOffset: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var millis: Int64 = 0


    /// The offset in milliseconds.
    internal var current: Int64 {
        lock.lock()
        defer {
            lock.unlock()
        }
        return millis
    }


    internal func set(_ value: Int64) {
        lock.lock()
        millis = value
        lock.unlock()
    }
}


/// The offset a reply sets: its server time minus the local wall clock. A reply without a time
/// (0, the value of an unset field) sets nothing. So does a time more than 365 days from the
/// local clock, and a difference that overflows: the caller keeps the previous offset.
internal func serverTimeOffsetFrom(time: Int64, localMillis: Int64) -> Int64? {
    if time == 0 {
        return nil
    }
    let difference: (partialValue: Int64, overflow: Bool) = time.subtractingReportingOverflow(localMillis)
    if difference.overflow {
        return nil
    }
    if difference.partialValue > serverTimeMaxOffsetMillis || difference.partialValue < -serverTimeMaxOffsetMillis {
        return nil
    }
    return difference.partialValue
}


public extension CentrifugeClient {
    /// The server time in milliseconds since the unix epoch: the local wall clock plus the
    /// offset of the last command reply that carried a time. Before such a reply it is the
    /// local time. Safe to call from a delegate callback.
    func serverTimeMillis() -> Int64 {
        let localMillis: Int64 = self.clock.wallMillis()
        let offset: Int64 = self.serverTimeOffset.current
        let sum: (partialValue: Int64, overflow: Bool) = localMillis.addingReportingOverflow(offset)
        if !sum.overflow {
            return sum.partialValue
        }
        return offset > 0 ? Int64.max : Int64.min
    }


    /// Takes the server time of a command reply that answers a pending command, the connect reply
    /// included. The hook of `handleData` calls it only for such a reply, so a push, a ping and a
    /// late reply to an expired call never set the offset.
    internal func serverTimeFrom(reply: Centrifugal_Centrifuge_Protocol_Reply) {
        let localMillis: Int64 = self.clock.wallMillis()
        guard let offset: Int64 = serverTimeOffsetFrom(time: reply.time, localMillis: localMillis) else {
            return
        }
        self.serverTimeOffset.set(offset)
    }
}
