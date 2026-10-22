import Foundation
import Testing
@testable import SwiftCentrifuge

/// The msg_id generator (MsgIdGenerator.swift). Pure: no client, no clock, no sleep.
/// The lanes come from ManualRandom, so every id is exact.
@Suite(.serialized, .timeLimit(.minutes(1)))
final class MsgIdGeneratorTests: @unchecked Sendable {

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
        let random: ManualRandom = ManualRandom(lanes: [7])
        var generator: MsgIdGenerator = MsgIdGenerator(now: 100_000, random: random)
        let first: UInt64 = generator.next(serverTimeMillis: 100_000)
        let second: UInt64 = generator.next(serverTimeMillis: 100_500)
        #expect(second - first == 1)
        #expect(timePart(first) == 100)
        #expect(sequencePart(first) == 7)
    }

    @Test func laterSecondRestartsAtTheLane() {
        let random: ManualRandom = ManualRandom(lanes: [7])
        var generator: MsgIdGenerator = MsgIdGenerator(now: 100_000, random: random)
        _ = generator.next(serverTimeMillis: 100_000)
        _ = generator.next(serverTimeMillis: 100_900)
        let later: UInt64 = generator.next(serverTimeMillis: 101_000)
        #expect(timePart(later) == 101)
        #expect(sequencePart(later) == 7)
    }

    @Test func backwardCorrectionHoldsTheTimePartAndKeepsIncreasing() {
        let random: ManualRandom = ManualRandom(lanes: [7])
        var generator: MsgIdGenerator = MsgIdGenerator(now: 100_000, random: random)
        let before: UInt64 = generator.next(serverTimeMillis: 100_000)
        let behind: UInt64 = generator.next(serverTimeMillis: 99_000)
        #expect(timePart(behind) == 100)
        #expect(behind > before)
    }

    @Test func overflowMovesToTheNextSecond() throws {
        let random: ManualRandom = ManualRandom(lanes: [7])
        var generator: MsgIdGenerator = MsgIdGenerator(now: 100_000, random: random)
        // The sequence of second 100 runs from the lane 7 up to 2^20 - 1. The loop is bounded
        // by one more than that run, so a generator that never moves on fails instead of hanging.
        let bound: UInt64 = MsgIdGenerator.sequenceLimit + 2
        var inSecond: UInt64 = 0
        var moved: UInt64? = nil
        for _ in 0 ..< bound {
            let id: UInt64 = generator.next(serverTimeMillis: 100_000)
            if timePart(id) != 100 {
                moved = id
                break
            }
            inSecond += 1
        }
        let overflowId: UInt64 = try #require(moved, "the second moves on within the sequence limit")
        #expect(timePart(overflowId) == 101)
        #expect(sequencePart(overflowId) == 7)
        #expect(inSecond == MsgIdGenerator.sequenceLimit - 7)
    }

    @Test func resyncLowersTheTimePartAndChangesTheLane() {
        let random: ManualRandom = ManualRandom(lanes: [7, 300_000])
        var generator: MsgIdGenerator = MsgIdGenerator(now: 100_000, random: random)
        _ = generator.next(serverTimeMillis: 100_000)
        generator.resync(serverTimeMillis: 50_000)
        let after: UInt64 = generator.next(serverTimeMillis: 50_000)
        #expect(timePart(after) == 50)
        #expect(sequencePart(after) == 300_000)
        #expect(random.requestedRanges.count == 2, "a new second draws a new lane")
    }

    @Test func resyncToTheSameSecondContinuesTheSequence() {
        let random: ManualRandom = ManualRandom(lanes: [7])
        var generator: MsgIdGenerator = MsgIdGenerator(now: 100_000, random: random)
        _ = generator.next(serverTimeMillis: 100_000)
        _ = generator.next(serverTimeMillis: 100_000)
        generator.resync(serverTimeMillis: 100_500)
        let third: UInt64 = generator.next(serverTimeMillis: 100_000)
        #expect(sequencePart(third) == 9)
        #expect(random.requestedRanges.count == 1, "the same second draws no lane")
    }

    // Two generators with the production random source, started in the same second. A lane
    // is drawn from 2^19 values, so the 20 pairs are all equal only if the source is ignored.
    @Test func twoDefaultGeneratorsInTheSameSecondGiveDifferentFirstIds() {
        var equalPairs: Int = 0
        for _ in 0 ..< 20 {
            var first: MsgIdGenerator = MsgIdGenerator(now: 100_000, random: SystemClientRandom())
            var second: MsgIdGenerator = MsgIdGenerator(now: 100_000, random: SystemClientRandom())
            let firstId: UInt64 = first.next(serverTimeMillis: 100_000)
            let secondId: UInt64 = second.next(serverTimeMillis: 100_000)
            if firstId == secondId {
                equalPairs += 1
            }
        }
        #expect(equalPairs < 20, "the default random source gives different lanes")
    }

    @Test func largestTimePartFitsFiftyThreeBits() {
        let random: ManualRandom = ManualRandom()
        var generator: MsgIdGenerator = MsgIdGenerator(now: 0, random: random)
        let id: UInt64 = generator.next(serverTimeMillis: Int64(secondsMask) * 1000)
        #expect(timePart(id) == secondsMask)
        #expect(id < UInt64(1) << 53)
    }

    @Test func timePartBeyondThirtyThreeBitsIsClamped() {
        let random: ManualRandom = ManualRandom()
        var generator: MsgIdGenerator = MsgIdGenerator(now: 0, random: random)
        let id: UInt64 = generator.next(serverTimeMillis: Int64.max)
        #expect(timePart(id) == secondsMask)
    }

    // The range [0, 2^19) holds 2^19 values, 19 bits; the name is the spec's canonical row name.
    @Test func laneIsDrawnFromTheNineteenBitsRange() {
        let low: ManualRandom = ManualRandom(lanes: [lowerLane])
        var lowGenerator: MsgIdGenerator = MsgIdGenerator(now: 0, random: low)
        #expect(sequencePart(lowGenerator.next(serverTimeMillis: 0)) == lowerLane)

        let high: ManualRandom = ManualRandom(lanes: [laneTop])
        var highGenerator: MsgIdGenerator = MsgIdGenerator(now: 0, random: high)
        #expect(sequencePart(highGenerator.next(serverTimeMillis: 0)) == laneTop)

        #expect(low.requestedRanges == [0 ... laneTop], "the lane range is [0, 2^19)")
        #expect(high.requestedRanges == [0 ... laneTop], "the lane range is [0, 2^19)")
    }
}
