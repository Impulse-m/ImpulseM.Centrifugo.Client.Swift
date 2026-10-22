import Foundation

// The server time of a client (parity spec F4). A command reply carries the server's Unix time
// in `Reply.time`. The client keeps the offset of that time from its own wall clock, and the
// server time is the local wall clock plus the offset. A reply without a time keeps the last
// offset. Before any reply the offset is zero, so the server time is the local time.

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
/// (0, the value of an unset field) sets nothing.
internal func serverTimeOffsetFrom(time: Int64, localMillis: Int64) -> Int64? {
    if time == 0 {
        return nil
    }
    return time - localMillis
}


public extension CentrifugeClient {
    /// The server time in milliseconds since the unix epoch: the local wall clock plus the
    /// offset of the last command reply that carried a time. Before such a reply it is the
    /// local time. Safe to call from a delegate callback.
    func serverTimeMillis() -> Int64 {
        return self.clock.wallMillis() + self.serverTimeOffset.current
    }


    /// Takes the server time of a decoded reply. The hook of `handleData` calls it for every
    /// reply before the reply is routed. Only command replies (id > 0) carry the time, so pushes
    /// and pings never set the offset.
    internal func serverTimeFrom(reply: Centrifugal_Centrifuge_Protocol_Reply) {
        guard reply.id > 0 else {
            return
        }
        let localMillis: Int64 = self.clock.wallMillis()
        guard let offset: Int64 = serverTimeOffsetFrom(time: reply.time, localMillis: localMillis) else {
            return
        }
        self.serverTimeOffset.set(offset)
    }
}
