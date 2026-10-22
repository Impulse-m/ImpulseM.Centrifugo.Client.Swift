import Foundation
import Testing
@testable import SwiftCentrifuge

// The due queues of the rpc tracker (RpcDeadlines.swift). The heap yields its entries in time order,
// and the expiry queue keeps its order across compaction. The values come from a fixed sequence, so
// every run sees the same entries.

@Suite(.serialized, .timeLimit(.minutes(1)))
struct RpcDeadlinesTests {
    /// A fixed pseudo-random sequence (a linear congruential generator).
    private func sequence(count: Int) -> [UInt64] {
        var state: UInt64 = 1
        var values: [UInt64] = []
        values.reserveCapacity(count)
        for _ in 0 ..< count {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            values.append(state >> 20)
        }
        return values
    }


    @Test func theHeapPopsTenThousandEntriesInTimeOrder() {
        var heap: RpcDueHeap = RpcDueHeap()
        let values: [UInt64] = sequence(count: 10_000)
        for entry: (offset: Int, element: UInt64) in values.enumerated() {
            heap.push(RpcDue(nanos: entry.element, seq: entry.offset, resend: false))
        }
        var popped: [UInt64] = []
        while let due: RpcDue = heap.earliest {
            popped.append(due.nanos)
            heap.pop()
        }
        #expect(popped.count == 10_000)
        #expect(popped == values.sorted(), "every entry comes out, earliest first")
    }


    @Test func theExpiryQueueKeepsItsOrderWhilePushesAndPopsInterleave() {
        var queue: RpcExpiryQueue = RpcExpiryQueue()
        var seen: [UInt32] = []
        for index: Int in 0 ..< 1_000 {
            queue.push(RpcRouteExpiry(commandId: UInt32(index), nanos: UInt64(index)))
            if index % 2 == 1, let entry: RpcRouteExpiry = queue.earliest {
                seen.append(entry.commandId)
                queue.pop()
            }
        }
        while let entry: RpcRouteExpiry = queue.earliest {
            seen.append(entry.commandId)
            queue.pop()
        }
        let expected: [UInt32] = (0 ..< 1_000).map { (value: Int) -> UInt32 in
            return UInt32(value)
        }
        #expect(seen == expected, "the routes expire in the order they were set, across compaction")
    }
}
