import Foundation

// The routing of a reply to a tracked rpc call. The client calls `routeTrackedReply` for each reply
// whose command id has no callback in `opCallbacks`; the tracker decides whether it owns the id.
// A reply that answers a pending command sets the server time; a late one does not.

internal extension CentrifugeClient {
    /// Hands a reply to the tracker when the tracker wrote the command it answers. A reply to a
    /// command the tracker does not own is ignored, as before the tracked calls.
    func routeTrackedReply(_ reply: Centrifugal_Centrifuge_Protocol_Reply) {
        guard self.rpcTracker.owns(commandId: reply.id) else {
            return
        }
        if self.rpcTracker.awaitsReply(commandId: reply.id) {
            self.serverTimeFrom(reply: reply)
        }
        self.rpcTracker.handleReply(reply)
    }

    /// Gives a command the next command id and writes it on the connection. The tracker routes the
    /// reply by that id. Throws when the command cannot be encoded: nothing is written then.
    func writeTrackedCommand(_ command: inout Centrifugal_Centrifuge_Protocol_Command) throws -> UInt32 {
        command.id = self.nextCommandId()
        try self.sendCommandAsync(command: command)
        return command.id
    }
}
