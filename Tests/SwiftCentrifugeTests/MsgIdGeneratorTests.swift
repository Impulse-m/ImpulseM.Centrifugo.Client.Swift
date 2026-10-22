import Foundation
import Testing
@testable import SwiftCentrifuge

/// The msg_id generator (MsgIdGenerator.swift). Pure: no client, no clock, no sleep.
/// The lanes come from a scripted random source, so every id is exact.
@Suite(.timeLimit(.minutes(1)))
final class MsgIdGeneratorTests: @unchecked Sendable {

    /// Returns the scripted values in order, then the lower bound. Records each range asked for.
    private final class ScriptedRandom: @unchecked Sendable {
        private let lock: NSLock = NSLock()
        private var values: [UInt64]
        private(set) var ranges: [ClosedRange<UInt64>] = []

        init(_ values: [UInt64]) {
            self.values = values
        }

        func draw(_ range: ClosedRange<UInt64>) -> UInt64 {
            lock.lock()
            defer {
                lock.unlock()
            }
            ranges.append(range)
            if values.isEmpty {
                return range.lowerBound
            }
            return values.removeFirst()
        }
    }

    private let secondsMask: UInt64 = (1 << 33) - 1
    private let sequenceMask: UInt64 = (1 << 20) - 1
    private let lowerLane: UInt64 = 0
    private let laneTop: UInt64 = (1 << 19) - 1

    private func timePart(_ id: UInt64) -> UInt64 {
        return id >> MsgIdGenerator.sequenceBits
    }

    private func sequencePart(_ id: UInt64) -> UInt64 {
        return id & sequenceMask
    }

    @Test func sameSecondIncrements() {
        let script: ScriptedRandom = ScriptedRandom([7])
        var generator: MsgIdGenerator = MsgIdGenerator(now: 100_000, random: script.draw)
        let first: UInt64 = generator.next(serverTimeMillis: 100_000)
        let second: UInt64 = generator.next(serverTimeMillis: 100_500)
        #expect(second - first == 1)
        #expect(timePart(first) == 100)
        #expect(sequencePart(first) == 7)
    }

    @Test func laterSecondRestartsAtTheLane() {
        let script: ScriptedRandom = ScriptedRandom([7])
        var generator: MsgIdGenerator = MsgIdGenerator(now: 100_000, random: script.draw)
        _ = generator.next(serverTimeMillis: 100_000)
        _ = generator.next(serverTimeMillis: 100_900)
        let later: UInt64 = generator.next(serverTimeMillis: 101_000)
        #expect(timePart(later) == 101)
        #expect(sequencePart(later) == 7)
    }

    @Test func backwardCorrectionHoldsTheTimePartAndKeepsIncreasing() {
        let script: ScriptedRandom = ScriptedRandom([7])
        var generator: MsgIdGenerator = MsgIdGenerator(now: 100_000, random: script.draw)
        let before: UInt64 = generator.next(serverTimeMillis: 100_000)
        let behind: UInt64 = generator.next(serverTimeMillis: 99_000)
        #expect(timePart(behind) == 100)
        #expect(behind > before)
    }

    @Test func overflowMovesToTheNextSecond() {
        let script: ScriptedRandom = ScriptedRandom([7])
        var generator: MsgIdGenerator = MsgIdGenerator(now: 100_000, random: script.draw)
        // The sequence of second 100 runs from the lane 7 up to 2^20 - 1.
        var inSecond: UInt64 = 0
        while true {
            let id: UInt64 = generator.next(serverTimeMillis: 100_000)
            if timePart(id) != 100 {
                #expect(timePart(id) == 101)
                #expect(sequencePart(id) == 7)
                break
            }
            inSecond += 1
        }
        #expect(inSecond == MsgIdGenerator.sequenceLimit - 7)
    }

    @Test func resyncLowersTheTimePartAndChangesTheLane() {
        let script: ScriptedRandom = ScriptedRandom([7, 300_000])
        var generator: MsgIdGenerator = MsgIdGenerator(now: 100_000, random: script.draw)
        _ = generator.next(serverTimeMillis: 100_000)
        generator.resync(serverTimeMillis: 50_000)
        let after: UInt64 = generator.next(serverTimeMillis: 50_000)
        #expect(timePart(after) == 50)
        #expect(sequencePart(after) == 300_000)
        #expect(script.ranges.count == 2, "a new second draws a new lane")
    }

    @Test func resyncToTheSameSecondContinuesTheSequence() {
        let script: ScriptedRandom = ScriptedRandom([7])
        var generator: MsgIdGenerator = MsgIdGenerator(now: 100_000, random: script.draw)
        _ = generator.next(serverTimeMillis: 100_000)
        _ = generator.next(serverTimeMillis: 100_000)
        generator.resync(serverTimeMillis: 100_500)
        let third: UInt64 = generator.next(serverTimeMillis: 100_000)
        #expect(sequencePart(third) == 9)
        #expect(script.ranges.count == 1, "the same second draws no lane")
    }

    @Test func twoDefaultGeneratorsInTheSameSecondGiveDifferentFirstIds() {
        let systemRandom: (ClosedRange<UInt64>) -> UInt64 = { (range: ClosedRange<UInt64>) -> UInt64 in
            return UInt64.random(in: range)
        }
        for _ in 0 ..< 20 {
            var first: MsgIdGenerator = MsgIdGenerator(now: 100_000, random: systemRandom)
            var second: MsgIdGenerator = MsgIdGenerator(now: 100_000, random: systemRandom)
            let firstId: UInt64 = first.next(serverTimeMillis: 100_000)
            let secondId: UInt64 = second.next(serverTimeMillis: 100_000)
            #expect(firstId != secondId)
        }
    }

    @Test func largestTimePartFitsFiftyThreeBits() {
        let script: ScriptedRandom = ScriptedRandom([])
        var generator: MsgIdGenerator = MsgIdGenerator(now: 0, random: script.draw)
        let id: UInt64 = generator.next(serverTimeMillis: Int64(secondsMask) * 1000)
        #expect(timePart(id) == secondsMask)
        #expect(id < UInt64(1) << 53)
    }

    @Test func timePartBeyondThirtyThreeBitsIsClamped() {
        let script: ScriptedRandom = ScriptedRandom([])
        var generator: MsgIdGenerator = MsgIdGenerator(now: 0, random: script.draw)
        let id: UInt64 = generator.next(serverTimeMillis: Int64.max)
        #expect(timePart(id) == secondsMask)
    }

    @Test func laneIsDrawnFromTheTwentyBitsRange() {
        let low: ScriptedRandom = ScriptedRandom([lowerLane])
        var lowGenerator: MsgIdGenerator = MsgIdGenerator(now: 0, random: low.draw)
        #expect(sequencePart(lowGenerator.next(serverTimeMillis: 0)) == lowerLane)

        let high: ScriptedRandom = ScriptedRandom([laneTop])
        var highGenerator: MsgIdGenerator = MsgIdGenerator(now: 0, random: high.draw)
        #expect(sequencePart(highGenerator.next(serverTimeMillis: 0)) == laneTop)

        #expect(low.ranges == [0 ... laneTop], "the lane range is [0, 2^19)")
        #expect(high.ranges == [0 ... laneTop], "the lane range is [0, 2^19)")
    }
}
