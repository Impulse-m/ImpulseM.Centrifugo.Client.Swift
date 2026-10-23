import Foundation

// One call of the rpc pool, from its admission to its settlement. A call waits in the line of its endpoint key
// until a connection has a free slot, then it holds that slot until the connection answers it. The line itself is
// an array in the pool (RpcPool.swift), bounded by `maxQueued`. The fields are read and written on the pool's queue.

/// One pool call. Its completion runs once, on the pool's queue.
internal final class RpcPoolCall {
    /// The endpoint key the call was made with.
    internal let endpointKey: String

    internal let method: String

    internal let data: Data

    internal let options: CentrifugeRpcPoolCallOptions

    internal let completion: (Result<CentrifugeRpcResult, Error>) -> Void

    /// The monotonic moment the call's deadline passes. Set at admission.
    internal var deadline: UInt64 = 0

    /// The connection that carries the call, once it is placed.
    internal var connection: RpcPoolConnection? = nil

    /// Whether the call still holds a slot of `connection`: set at placement, cleared when the connection answers.
    internal var holdsSlot: Bool = false

    /// Whether the completion has run (or is running). A settled call may still hold its slot until its answer.
    internal var settled: Bool = false


    internal init(
        endpointKey: String,
        method: String,
        data: Data,
        options: CentrifugeRpcPoolCallOptions,
        completion: @escaping (Result<CentrifugeRpcResult, Error>) -> Void
    ) {
        self.endpointKey = endpointKey
        self.method = method
        self.data = data
        self.options = options
        self.completion = completion
    }
}
