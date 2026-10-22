import Foundation

// The retry signal of a tracked rpc call. The server sets a metadata
// key on its own errors, so a backend cannot set it: a call whose error carries it was not
// executed. `new_msg_id` asks for a resend with a new msg_id, `later` for a resend with the same one.

/// The metadata key of the retry signal.
internal let rpcRetryMetadataKey: String = "x-centrifugo-retry"

/// The value that asks for a resend with a new msg_id.
internal let rpcRetryValueNewMsgID: String = "new_msg_id"

/// The value that asks for a resend later, with the same msg_id.
internal let rpcRetryValueLater: String = "later"

/// Most resends of one call that asked for a new msg_id. A third refusal surfaces the error.
internal let maxNewIdResends: Int = 2

/// Most resends of one call that asked for a later attempt. A fourth refusal surfaces the error.
internal let maxLaterResends: Int = 3

/// Base of the later-resend delay in nanoseconds: 250 ms, doubled for each later resend so far.
internal let laterResendBaseNanos: UInt64 = 250_000_000

/// A call with headers on a connection that did not confirm the RPC options, so the headers cannot be
/// carried. Client-local: the server never sends it, but it travels as a `replyError` code, as the
/// contract documents.
internal let rpcCodeUnsupported: UInt32 = 15

/// A call refused by the client's bound on tracked calls, or a resend beyond its limit.
internal let rpcCodeLimitExceeded: UInt32 = 16

/// A call the client cancelled, before or after it was sent.
internal let rpcCodeCancelled: UInt32 = 17


/// The two resend signals of the server.
internal enum RpcRetrySignal: Equatable {
    case newMsgID
    case later
}


/// The retry signal of an error reply, read from its raw metadata. A missing key, and any other
/// value, is no signal.
internal func retrySignal(of error: Centrifugal_Centrifuge_Protocol_Error) -> RpcRetrySignal? {
    guard let value: String = error.metadata[rpcRetryMetadataKey] else {
        return nil
    }
    switch value {
    case rpcRetryValueNewMsgID:
        return RpcRetrySignal.newMsgID
    case rpcRetryValueLater:
        return RpcRetrySignal.later
    default:
        return nil
    }
}
