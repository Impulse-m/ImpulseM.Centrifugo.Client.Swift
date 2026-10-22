import Foundation

// The public types of a tracked rpc call (parity spec F7): the options, the handle that cancels the
// call, and the error payload of a server error that carries application fields. The call logic is
// in RpcTracker.swift.

/// Options of one `rpc` call.
public struct CentrifugeRpcOptions {
    /// Headers sent with the call. A connection that does not confirm the RPC options cannot carry
    /// them, and the call then fails with `replyError(code: 15)` without being sent.
    public var headers: [String: String]

    /// Deadline of the call across its attempts. Nil means `CentrifugeClientConfig.timeout`. An
    /// explicit value must be above 0 and no more than that timeout, otherwise the call fails with
    /// `configurationError`.
    public var timeout: TimeInterval?


    public init(
        headers: [String: String] = [:],
        timeout: TimeInterval? = nil
    ) {
        self.headers = headers
        self.timeout = timeout
    }
}


/// A server error reply that carries an application code, type or metadata. An error without them
/// arrives as `CentrifugeError.replyError` instead.
public struct CentrifugeReplyError: Equatable {
    public let code: UInt32
    public let message: String
    public let temporary: Bool
    public let appCode: Int32
    public let appType: String
    public let metadata: [String: String]


    public init(
        code: UInt32,
        message: String,
        temporary: Bool,
        appCode: Int32,
        appType: String,
        metadata: [String: String]
    ) {
        self.code = code
        self.message = message
        self.temporary = temporary
        self.appCode = appCode
        self.appType = appType
        self.metadata = metadata
    }
}


/// The handle of one `rpc` call. `cancel()` stops the call: a call that is not on the wire fails at
/// once, and a sent call also gets a cancel command for the server. Calling it after the call
/// completed does nothing.
public final class CentrifugeRpcCall: @unchecked Sendable {
    private let slot: RpcCallSlot


    internal init(slot: RpcCallSlot) {
        self.slot = slot
    }


    /// Cancels the call. Safe to call from any thread and from a delegate callback.
    public func cancel() {
        self.slot.cancel()
    }
}


/// Links a call handle to its tracked call. `call` is set and read on the client's queue only.
internal final class RpcCallSlot: @unchecked Sendable {
    internal var call: TrackedRpc?
    private let queue: DispatchQueue
    private weak var tracker: RpcTracker?


    internal init(queue: DispatchQueue, tracker: RpcTracker) {
        self.queue = queue
        self.tracker = tracker
    }


    /// Cancels the call on the client's queue. The handle does not have to stay alive for the
    /// cancel to run.
    internal func cancel() {
        self.queue.async {
            self.tracker?.cancelCall(self.call)
        }
    }
}
