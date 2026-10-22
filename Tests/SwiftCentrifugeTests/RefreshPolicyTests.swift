import Foundation
import Testing
@testable import SwiftCentrifuge

// The retry policy of the timer refreshes (RefreshPolicy.swift), as pure functions. The random source is
// ManualRandom, so the delays are exact: draw 0 gives the minimum of the range, draw 1 its upper bound.

@Suite(.serialized, .timeLimit(.minutes(1)))
final class RefreshPolicyTests: @unchecked Sendable {
    /// The delay at draw 1 for steps 0 to 5 with the default cap of 300 s: min(ceiling, 10 s + 10 s * 2^step).
    private let upperDelays: [TimeInterval] = [20, 30, 50, 90, 170, 300]


    @Test func retryDelayEscalatesAndStopsAtTheCap() {
        for step: Int in 0 ... 5 {
            let low: TimeInterval = refreshRetryDelay(step: step, tokenRetryCap: 300, random: ManualRandom(draw: 0))
            #expect(low == 10, "draw 0 gives the minimum at step \(step)")
            let random: ManualRandom = ManualRandom(draw: 1)
            let high: TimeInterval = refreshRetryDelay(step: step, tokenRetryCap: 300, random: random)
            #expect(high == upperDelays[step], "draw 1 at step \(step)")
            // The jitter is drawn over [0, min(ceiling, 10 s * 2^step)].
            let expectedSpan: UInt64 = UInt64(min(300, 10 * pow(2, Double(step))) * 1e9)
            #expect(random.requestedRanges.last?.upperBound == expectedSpan, "jitter range at step \(step)")
        }
        // Past the cap the delay stays at the cap.
        let capped: TimeInterval = refreshRetryDelay(step: 9, tokenRetryCap: 300, random: ManualRandom(draw: 1))
        #expect(capped == 300)
    }


    @Test func retryDelayUsesTheConfiguredCap() {
        // A cap of 60 s: the ceiling of step 5 is 60 s, and the delay at draw 1 is 60 s.
        #expect(refreshRetryDelay(step: 5, tokenRetryCap: 60, random: ManualRandom(draw: 1)) == 60)
        // A step below the cap is not affected by it: step 1 gives 30 s at draw 1.
        #expect(refreshRetryDelay(step: 1, tokenRetryCap: 60, random: ManualRandom(draw: 1)) == 30)
    }


    @Test func retryClassificationFollowsTheRetryTable() {
        #expect(refreshRetries(code: 109, temporary: false))
        #expect(refreshRetries(code: 25, temporary: false))
        #expect(refreshRetries(code: 100, temporary: true))
        #expect(!refreshRetries(code: 103, temporary: false))
        #expect(!refreshRetries(code: 3500, temporary: false))
        #expect(refreshKeepsConnection(code: 103))
        #expect(!refreshKeepsConnection(code: 109))
    }


    @Test func refusedTokenIsNotResentOnlyWhenTheRuleIsOn() {
        #expect(refusedTokenIsNotResent(token: "T1", refused: "T1", stopOnRefusedToken: true))
        #expect(!refusedTokenIsNotResent(token: "T1", refused: "T1", stopOnRefusedToken: false))
        #expect(!refusedTokenIsNotResent(token: "T2", refused: "T1", stopOnRefusedToken: true))
        #expect(!refusedTokenIsNotResent(token: "T1", refused: nil, stopOnRefusedToken: true))
    }
}
