import Foundation

/// Connect flags the client advertises in `ConnectRequest.flag`. The server answers with the
/// flags it enabled, in `ConnectResult.flag`, using the same bits.
internal enum ConnectFlags {
    /// The server runs the RPC registry (tracked calls, parity spec F7). The client advertises
    /// it from the slice that adds the instance; it reads the server's answer in the slice that
    /// adds tracked calls.
    internal static let rpcOptions: Int64 = Int64(1) << 32
}
