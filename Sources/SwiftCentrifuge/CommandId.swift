import Foundation

/// Issues the command ids of a client. The server answers a reply with the id of its
/// command, so ids must not repeat among the commands in flight. Id 0 is reserved:
/// the server sends pushes and pings with id 0, so the counter skips it when it wraps.
/// The caller holds its own lock, as the client does for `nextCommandId`.
internal struct CommandIdCounter {
    private var last: UInt32


    internal init() {
        self.last = 0
    }


    /// Starts the counter at `last`, so the next id is `last + 1` (wrapping, skipping 0).
    /// Only the wrap test uses it: reaching the wrap by 2^32 calls is too slow for a unit test.
    internal init(last: UInt32) {
        self.last = last
    }


    internal mutating func next() -> UInt32 {
        self.last = self.last &+ 1
        if self.last == 0 {
            self.last = 1
        }
        return self.last
    }
}
