import Foundation

// The public types of a tracked rpc call: the options, the handle that cancels the
// call, and the error payload of a server error that carries application fields. The call logic is
// in RpcTracker.swift.

/// The command of a plain rpc request with a command id. The token exchange and the tracker build their rpc
/// commands here, so the shape is written once.
internal func makeRpcCommand(id: UInt32, method: String, data: Data) -> Centrifugal_Centrifuge_Protocol_Command {
    var request: Centrifugal_Centrifuge_Protocol_RPCRequest = Centrifugal_Centrifuge_Protocol_RPCRequest()
    request.method = method
    request.data = data
    var command: Centrifugal_Centrifuge_Protocol_Command = Centrifugal_Centrifuge_Protocol_Command()
    command.id = id
    command.rpc = request
    return command
}


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
    private let onCancel: () -> Void


    internal init(slot: RpcCallSlot) {
        self.onCancel = {
            slot.cancel()
        }
    }


    /// A handle whose cancel runs `onCancel`. The rpc pool uses it for its own calls (RpcPool.swift).
    internal init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }


    /// Cancels the call. Safe to call from any thread and from a delegate callback.
    public func cancel() {
        self.onCancel()
    }
}


public extension CentrifugeClient {
    /**
     Send RPC command with options. The returned handle cancels the call.
     - parameter method: String
     - parameter data: Data
     - parameter options: Headers and the deadline of the call
     - parameter completion: Completion block
     */
    @discardableResult
    func rpc(
        method: String,
        data: Data,
        options: CentrifugeRpcOptions,
        completion: @escaping (Result<CentrifugeRpcResult, Error>)->()
    ) -> CentrifugeRpcCall {
        let slot: RpcCallSlot = RpcCallSlot(queue: self.syncQueue, tracker: self.rpcTracker)
        self.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.rpcTracker.admit(method: method, data: data, options: options, completion: completion, slot: slot)
        }
        return CentrifugeRpcCall(slot: slot)
    }
}


/// Links a call handle to its tracked call. `call` is set and read on the client's queue only. It is
/// weak: the tracker keeps a call until it settles, so a settled call and its completion are released
/// even while the handle is held.
internal final class RpcCallSlot: @unchecked Sendable {
    internal weak var call: TrackedRpc?
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


