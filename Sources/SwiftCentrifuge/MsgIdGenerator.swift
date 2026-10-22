import Foundation

/// Issues the msg_id of each tracked rpc call. A msg_id is the server-corrected unix
/// second in its high 33 bits and a sequence in its low 20 bits. The sequence of a second
/// starts at a lane drawn from [0, 2^19), so two generators in one second rarely issue the
/// same id. A clock that moves backwards keeps the last time part. `resync` moves the time
/// part to the second the server refused the id in, and takes a fresh lane when that
/// second is new.
///
/// While the time part is below its maximum, every id is below 2^53, so it is exact as a
/// JavaScript number. The largest second is the exception (see `next`).
///
/// A pure value type: the start time and the random source are parameters, so the
/// generator runs without a client.
internal struct MsgIdGenerator {
    /// Bits of the sequence part of a msg_id.
    internal static let sequenceBits: UInt64 = 20


    /// The sequence of a second moves on to the next second when it reaches this value.
    internal static let sequenceLimit: UInt64 = 1 << MsgIdGenerator.sequenceBits


    /// Largest time part: 33 bits of unix seconds.
    internal static let maxSeconds: UInt64 = (1 << 33) - 1


    /// Lanes are drawn from [0, laneBound): a second holds at least 2^19 msg_ids from its lane on.
    internal static let laneBound: UInt64 = 1 << 19

    private let random: ClientRandom
    private var lane: UInt64
    // The time part of the last msg_id issued.
    private var lastSeconds: UInt64
    // The sequence the next msg_id of lastSeconds takes.
    private var nextSeq: UInt64

    /// - Parameters:
    ///   - now: the corrected server time in milliseconds when the generator starts.
    ///   - random: draws the lanes.
    internal init(now: Int64, random: ClientRandom) {
        self.random = random
        let drawn: UInt64 = random.uniform(0 ... MsgIdGenerator.laneBound - 1)
        self.lane = drawn
        self.lastSeconds = MsgIdGenerator.clampSeconds(now)
        self.nextSeq = drawn
    }

    /// The msg_id of a call written now, for the corrected server time in milliseconds.
    /// The time part never moves back on its own: an earlier server time keeps the last
    /// time part, and the sequence goes on.
    ///
    /// At the largest time part the sequence keeps counting instead of wrapping, so no
    /// msg_id repeats. Past 2^20 ids in that second an id no longer fits in 53 bits, so it
    /// is not exact as a JavaScript number. Reaching that takes over a million ids in one
    /// second, and it is not refused here.
    internal mutating func next(serverTimeMillis: Int64) -> UInt64 {
        var seconds: UInt64 = max(MsgIdGenerator.clampSeconds(serverTimeMillis), self.lastSeconds)
        var seq: UInt64 = self.lane
        if seconds == self.lastSeconds {
            seq = self.nextSeq
        }
        if seq >= MsgIdGenerator.sequenceLimit && seconds < MsgIdGenerator.maxSeconds {
            seconds += 1
            seq = self.lane
        }
        self.lastSeconds = seconds
        self.nextSeq = seq + 1
        return (seconds << MsgIdGenerator.sequenceBits) + seq
    }

    /// Re-syncs the time part to the corrected second of a reply that refused a msg_id
    /// as outside the server window. A second equal to the last keeps its sequence, so
    /// its ids continue. Any other second takes a fresh lane. A backward re-sync can
    /// re-cover seconds already used, so its ids can overlap with theirs, with the
    /// collision risk of a lane overlap.
    internal mutating func resync(serverTimeMillis: Int64) {
        let seconds: UInt64 = MsgIdGenerator.clampSeconds(serverTimeMillis)
        if seconds == self.lastSeconds {
            return
        }
        self.lastSeconds = seconds
        self.lane = self.random.uniform(0 ... MsgIdGenerator.laneBound - 1)
        self.nextSeq = self.lane
    }

    /// Seconds of a server time, clamped to the 33-bit time part.
    private static func clampSeconds(_ serverTimeMillis: Int64) -> UInt64 {
        if serverTimeMillis <= 0 {
            return 0
        }
        let seconds: UInt64 = UInt64(serverTimeMillis / 1000)
        return min(seconds, MsgIdGenerator.maxSeconds)
    }
}
