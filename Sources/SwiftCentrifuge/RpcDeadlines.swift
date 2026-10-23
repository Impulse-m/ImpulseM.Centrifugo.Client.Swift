import Foundation

// The timer queues of the rpc tracker. Each one answers "what is due first" without a scan of the
// calls or the routes. Entries are never removed from the middle: an entry whose call or route has
// gone is dropped when it reaches the front, so every operation stays logarithmic or amortized O(1).

/// A moment at which a call needs the tracker: its deadline, or the due time of its later resend.
internal struct RpcDue {
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
internal struct RpcDueHeap {
    private var items: [RpcDue] = []


    /// The earliest entry, or nil when the heap is empty.
    var earliest: RpcDue? {
        return self.items.first
    }


    mutating func push(_ item: RpcDue) {
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
        let last: RpcDue = self.items.removeLast()
        guard !self.items.isEmpty else {
            return
        }
        self.items[0] = last
        var index: Int = 0
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
