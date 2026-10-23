import Foundation

// One call of the rpc pool, from its admission to its settlement. A call waits in the line of its endpoint key
// until a connection has a free slot, then it holds that slot until the connection answers it. The line itself is
// an array in the pool (RpcPool.swift), bounded by `maxQueued`. The fields are read and written on the pool's queue.

/// One pool call. Its completion runs once, on the pool's queue.
internal final class RpcPoolCall {
    /// The endpoint key the call waits under. A call that the reroute hook moves takes the new key.
    internal var endpointKey: String

    internal let method: String

    internal let data: Data

    internal let options: CentrifugeRpcPoolCallOptions

    internal let completion: (Result<CentrifugeRpcResult, Error>) -> Void

    /// The monotonic moment the call's deadline passes. Set at admission.
    internal var deadline: UInt64 = 0

    /// The connection that carries the call, once it is placed.
    internal var connection: RpcPoolConnection? = nil

    /// The URL of the endpoint of the connection that carried the call last. A redirect checks its scheme against it.
    internal var endpointURL: String = ""

    /// Whether the call still holds a slot of `connection`: set at placement, cleared when the connection answers.
    internal var holdsSlot: Bool = false

    /// The handle of the call on its connection. Cancelling the pool call cancels it too, so the connection answers
    /// it at once and the slot is released without waiting for the connection's own timeout.
    internal var innerCall: CentrifugeRpcCall? = nil

    /// The resends the call has made, of any cause (a loss, a later refusal, a move). `retries` bounds it.
    internal var resends: Int = 0

    /// The later resends the call has made. The delay of the next later resend grows with it, and no other cause
    /// counts here.
    internal var laterResends: Int = 0

    /// The monotonic moment a later resend of the call is due. Set while the call waits in the resend wait list.
    internal var resendAt: UInt64 = 0

    /// The identity generation the call is bound to at admission. A pool with `tokenFrom` fails a waiting call whose
    /// generation the main client has left (identity changed). Zero for a pool without `tokenFrom`.
    internal var generation: UInt64 = 0

    /// Set when the completion has run. A settled call may still hold its slot until its connection answers.
    internal var isSettled: Bool = false

    /// Claims the completion: the first settlement runs it, and a later one does nothing.
    internal let settleOnce: CallOnce = CallOnce()


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
