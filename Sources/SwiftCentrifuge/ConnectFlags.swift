import Foundation

/// Connect flags the client advertises in `ConnectRequest.flag`. The server answers with the
/// flags it enabled, in `ConnectResult.flag`, using the same bits.
internal enum ConnectFlags {
    /// The server runs the RPC registry, so its calls can be tracked. The client advertises it, and
    /// the tracker reads the server's answer to decide whether a call is tracked.
    internal static let rpcOptions: Int64 = Int64(1) << 32
}
