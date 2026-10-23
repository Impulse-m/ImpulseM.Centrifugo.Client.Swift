import Foundation

// The timer queues of the rpc tracker and the rpc pool. Each one answers "what is due first" without a scan of the
// calls or the routes. Entries are never removed from the middle: an entry whose call or route has
// gone is dropped when it reaches the front, so every operation stays logarithmic or amortized O(1).

/// A moment that a heap entry is ordered by.
internal protocol RpcTimed {
    /// The moment, in monotonic nanoseconds.
    var nanos: UInt64 { get }
}


/// A moment at which a call needs the tracker: its deadline, or the due time of its later resend.
internal struct RpcDue: RpcTimed {
    /// The moment, in monotonic nanoseconds.
    let nanos: UInt64
    /// The sequence number of the call.
    let seq: Int
    /// Whether the moment is the due time of a later resend (true) or the deadline of the call (false).
    let resend: Bool
}


/// A binary min-heap of due moments, earliest first. Ties come out in no fixed order.
///
/// It is written here because the package takes no new dependency. No benchmark has been run, so this
/// comment claims no speed gain over a library heap.
internal struct RpcMinHeap<Element: RpcTimed> {
    private var items: [Element] = []


    /// The earliest entry, or nil when the heap is empty.
    var earliest: Element? {
        return self.items.first
    }


    /// The number of entries, including the ones that have not been dropped from the front yet.
    var count: Int {
        return self.items.count
    }


    mutating func push(_ item: Element) {
        self.items.append(item)
        var index: Int = self.items.count - 1
        while index > 0 {
            let parent: Int = (index - 1) / 2
            guard self.items[index].nanos < self.items[parent].nanos else {
                break
            }
            self.items.swapAt(index, parent)
            index = parent
        }
    }


    /// Removes the earliest entry. Does nothing when the heap is empty.
    mutating func pop() {
        guard !self.items.isEmpty else {
            return
        }
        let last: Element = self.items.removeLast()
        guard !self.items.isEmpty else {
            return
        }
        self.items[0] = last
        self.siftDown(from: 0)
    }


    /// Removes every entry that the predicate rejects, then restores the heap order. The cost is linear in the entries
    /// it scans, so a caller that runs it when the entries outnumber the live ones twofold pays O(1) amortised per entry.
    mutating func keep(_ predicate: (Element) -> Bool) {
        self.items = self.items.filter(predicate)
        var index: Int = self.items.count / 2 - 1
        while index >= 0 {
            self.siftDown(from: index)
            index -= 1
        }
    }


    /// Moves the entry at `start` down until neither child is earlier.
    private mutating func siftDown(from start: Int) {
        var index: Int = start
        while true {
            let left: Int = 2 * index + 1
            let right: Int = left + 1
            var smallest: Int = index
            if left < self.items.count && self.items[left].nanos < self.items[smallest].nanos {
                smallest = left
            }
            if right < self.items.count && self.items[right].nanos < self.items[smallest].nanos {
                smallest = right
            }
            guard smallest != index else {
                break
            }
            self.items.swapAt(index, smallest)
            index = smallest
        }
    }
}


/// The tracker's heap of the due moments of its calls.
internal typealias RpcDueHeap = RpcMinHeap<RpcDue>


/// A due moment of the rpc pool's wait timer: the deadline or the resend time of a waiting call, or the end of an
/// endpoint's hold. The entry refers to its call or endpoint weakly, so it keeps neither alive. An entry stands only
/// while its call or endpoint still has that moment (RpcPool.swift); a stale one is dropped when it reaches the front.
internal struct RpcPoolDue: RpcTimed {
    /// The moment, in monotonic nanoseconds.
    let nanos: UInt64
    /// The call whose deadline or resend time this is. Nil for a hold.
    weak var call: RpcPoolCall?
    /// The endpoint whose hold ends at this moment. Nil for a call.
    weak var endpoint: RpcPoolEndpoint?
}


/// The identity of a due moment of a call: the call and the moment. A call stands at one moment at a time, so two
/// entries with the same identity are duplicates, and the compaction of the wait timer keeps one of them.
internal struct RpcPoolDueKey: Hashable {
    /// The identity of the call.
    let call: ObjectIdentifier
    /// The moment, in monotonic nanoseconds.
    let nanos: UInt64
}


/// The moment at which the reply route of a command is dropped.
internal struct RpcRouteExpiry {
    /// The command id of the route.
    let commandId: UInt32
    /// The moment, in monotonic nanoseconds.
    let nanos: UInt64
}


/// The route expiries in the order they were set. The client timeout is the same for every route, so
/// the moments come in non-decreasing order and the front is always the earliest.
internal struct RpcExpiryQueue {
    private var items: [RpcRouteExpiry] = []
    private var head: Int = 0


    /// The earliest entry, or nil when the queue is empty.
    var earliest: RpcRouteExpiry? {
        guard self.head < self.items.count else {
            return nil
        }
        return self.items[self.head]
    }


    mutating func push(_ item: RpcRouteExpiry) {
        self.items.append(item)
    }


    /// Removes the earliest entry. The consumed prefix is compacted once it is half of the storage.
    mutating func pop() {
        guard self.head < self.items.count else {
            return
        }
        self.head += 1
        if self.head >= 64 && self.head * 2 >= self.items.count {
            self.items.removeFirst(self.head)
            self.head = 0
        }
    }
}
