import Foundation

// An endpoint of the rpc pool: one URL, and the connections that belong to it. Keys which resolve to the same URL
// share the endpoint. The pool's logic is in RpcPool.swift; this file holds the endpoint's state only.

/// One endpoint URL of the pool, with its connections and its hold after a connection ended for good.
internal final class RpcPoolEndpoint {
    /// The URL the connections of the endpoint open.
    internal let url: String

    /// The connections of the endpoint: open or connecting. A connection that is closed is removed from here.
    internal var connections: [RpcPoolConnection] = []

    /// The monotonic moment the hold ends, set after a connection of the endpoint ended for good: until then no
    /// connection opens. Nil when the endpoint was never held. The pool's deadline timer wakes at the end of it.
    internal var holdUntil: UInt64? = nil

    /// Connections of the endpoint that ended for good without a connect in between. Sets the length of the hold.
    internal var failures: Int = 0


    internal init(url: String) {
        self.url = url
    }
}
