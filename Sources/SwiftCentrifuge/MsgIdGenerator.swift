import Foundation

/// Issues the msg_id of each tracked rpc call. A msg_id is the server-corrected unix
/// second in its high 33 bits and a sequence in its low 20 bits. The sequence of a second
/// starts at a lane drawn from [0, 2^19), so two generators in one second rarely issue the
/// same id. A clock that moves backwards keeps the last time part. `resync` moves the time
/// part to the second the server refused the id in, and takes a fresh lane when that
/// second is new.
///
/// The first id of a generator takes the second of the start
/// time it was created with, even when a backward correction moved the server time before
/// that second. The second of the first call is not used. JS and Java take the second of
/// the first call instead; the difference only shows for such a correction.
///
/// Every id is below 2^53, so it is exact as a JavaScript number. In the largest second
/// the generator refuses the id after 2^20 ids (see `next`).
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
    ///   - now: the corrected server time in milliseconds when the generator starts. The
    ///     first id takes the time part of `now` (see the type comment).
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
    /// At the largest time part the generator has 2^20 ids. Once they are issued, the next
    /// call throws `configurationError` ("msg_id space exhausted") and changes nothing, as
    /// the JS (RangeError) and Java (IllegalStateException) generators refuse. The caller
    /// completes the call that needed the id with that error.
    internal mutating func next(serverTimeMillis: Int64) throws -> UInt64 {
        var seconds: UInt64 = max(MsgIdGenerator.clampSeconds(serverTimeMillis), self.lastSeconds)
        var seq: UInt64 = self.lane
        if seconds == self.lastSeconds {
            seq = self.nextSeq
        }
        if seq >= MsgIdGenerator.sequenceLimit {
            if seconds >= MsgIdGenerator.maxSeconds {
                throw CentrifugeError.configurationError(message: "msg_id space exhausted")
            }
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
