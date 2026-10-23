import Foundation

// The rpc calls of a client. Every rpc call goes through the tracker. A call of a client with an
// instance, written on a connection that confirmed the RPC options (flag bit 32), is tracked: it
// carries a msg_id, its replies are acked, a lost call is resent with `retransmit` on the next
// connection, it can be cancelled, and it counts against `maxPendingRpc`. Any other call is plain: no
// msg_id, and a call on a lost connection fails.
//
// The tracker runs on the client's queue only. Its one timer serves the earliest of the call
// deadlines, the later-resend times and the expiries of the reply routes. The due moments are kept
// in heaps and queues (RpcDeadlines.swift), so no timer event scans the calls or the routes. A
// connection event (a loss or a connect) scans the calls and the routes once each, in
// onTransportLost and onConnected.
//
// Replies are routed through the tracker's own table of routes, not through the client's opCallbacks.
// A route holds the call, the msg_id and the expiry of a late reply, which an opCallbacks entry cannot
// hold, and the table is cleared with the connection (onTransportLost). The client asks `owns` and
// `awaitsReply` before it hands a reply over, so the two tables agree on which replies are the tracker's.

/// The phase of one call.
internal enum TrackedRpcPhase {
    /// Not on the wire: waiting for a connection. A call with `everSent` was written on a lost
    /// connection and waits to be resent.
    case queued
    /// Written, waiting for its reply.
    case sent
    /// Refused with a `later` signal, waiting for its resend time.
    case resendWait
    /// Completed: its completion has run.
    case settled
}


/// One rpc call from admission to its completion.
internal final class TrackedRpc {
    internal let seq: Int
    internal let method: String
    internal let data: Data
    internal let headers: [String: String]
    internal let completion: (Result<CentrifugeRpcResult, Error>) -> Void
    /// The deadline of the call across its attempts, in monotonic nanoseconds.
    internal let deadline: UInt64
    /// Whether the call counts against `maxPendingRpc` (the client has an instance).
    internal let counted: Bool
    internal var phase: TrackedRpcPhase = .queued
    /// The msg_id of a tracked call; 0 for a plain call.
    internal var msgID: UInt64 = 0
    /// The command id of the write in flight; 0 when none.
    internal var commandId: UInt32 = 0
    /// Whether the call was written at least once.
    internal var everSent: Bool = false
    /// Whether the next write is a resend of a call that was written before.
    internal var retransmit: Bool = false
    internal var newIdResends: Int = 0
    internal var laterResends: Int = 0
    /// When a `resendWait` call is due, in monotonic nanoseconds.
    internal var resendAt: UInt64 = 0


    internal init(
        seq: Int,
        method: String,
        data: Data,
        headers: [String: String],
        completion: @escaping (Result<CentrifugeRpcResult, Error>) -> Void,
        deadline: UInt64,
        counted: Bool
    ) {
        self.seq = seq
        self.method = method
        self.data = data
        self.headers = headers
        self.completion = completion
        self.deadline = deadline
        self.counted = counted
    }
}


/// The reply route of one command, keyed by command id. A route is active while its call waits for
/// the reply. After the call settled early (its deadline, a cancel), the route stays for the late
/// reply until `expiry`, so the reply can still be acked. A cancel command's route expires without
/// a reply: its callbacks are dropped and the cancel is not sent again.
private struct Route {
    var call: TrackedRpc?
    let msgID: UInt64
    let isCancel: Bool
    /// Nil while the call is active, whose deadline bounds it; otherwise the nanoseconds at which
    /// the route is dropped.
    var expiry: UInt64?
}


internal final class RpcTracker {
    // Set by `bind` in the client's initializer, before any call can arrive. Weak, because the client
    // owns the tracker. Nil once the client is released: every entry point and timer then does nothing.
    private weak var client: CentrifugeClient?
    private var connected: Bool = false
    private var capable: Bool = false
    private var generator: MsgIdGenerator? = nil
    private var lastSeq: Int = 0
    private var calls: [Int: TrackedRpc] = [:]
    private var routes: [UInt32: Route] = [:]
    // The due moments of the calls (deadlines and later resends), and the route expiries in order.
    // An entry is live only while its call and its state still match; see isLive and isCurrent.
    private var dues: RpcDueHeap = RpcDueHeap()
    private var expiries: RpcExpiryQueue = RpcExpiryQueue()
    private var pendingAcks: [UInt64] = []
    private var pendingCancels: [UInt64] = []
    private var inFlight: Int = 0
    private var timer: ClientDeadlineTimer = ClientDeadlineTimer()


    internal init() {
    }


    /// The tracker is released with its client. Its pending timer item is cancelled, so nothing stays
    /// scheduled for a dead client. The item's closure holds the tracker weakly, so a pending item
    /// never keeps the tracker alive.
    deinit {
        self.timer.cancel()
    }


    /// Connects the tracker to its client. The client calls it at the end of each initializer.
    internal func bind(client: CentrifugeClient) {
        self.client = client
    }


    /// Whether a reply with this command id belongs to the tracker.
    internal func owns(commandId: UInt32) -> Bool {
        return self.routes[commandId] != nil
    }


    /// Whether a reply with this command id answers a command still waiting for its reply: a call
    /// that has not settled, or a cancel. A late reply to a call that settled early does not.
    internal func awaitsReply(commandId: UInt32) -> Bool {
        guard let route: Route = self.routes[commandId] else {
            return false
        }
        return route.call != nil || route.isCancel
    }


    /// Admits a call. The completion runs once, on the client's queue. `slot` receives the call, so
    /// the handle can cancel it.
    internal func admit(
        method: String,
        data: Data,
        options: CentrifugeRpcOptions,
        completion: @escaping (Result<CentrifugeRpcResult, Error>) -> Void,
        slot: RpcCallSlot
    ) {
        guard let client: CentrifugeClient = self.client else {
            return
        }
        if let configError: CentrifugeError = client.configError {
            completion(.failure(configError))
            return
        }
        let limit: TimeInterval = client.config.timeout
        if let explicit: TimeInterval = options.timeout, !isValidRpcTimeout(explicit, limit: limit) {
            completion(.failure(CentrifugeError.configurationError(message: "rpc timeout must be above 0 and no more than the client timeout")))
            return
        }
        if client.state == .disconnected {
            completion(.failure(CentrifugeError.clientDisconnected))
            return
        }
        let counted: Bool = client.config.instance != nil
        if counted {
            if self.inFlight >= client.config.maxPendingRpc {
                completion(.failure(CentrifugeError.replyError(code: rpcCodeLimitExceeded, message: "limit exceeded", temporary: false)))
                return
            }
            self.inFlight += 1
        }
        let timeout: TimeInterval = options.timeout ?? limit
        let deadline: UInt64 = client.clock.monotonicNanos() + clientNanos(timeout)
        self.lastSeq += 1
        let call: TrackedRpc = TrackedRpc(
            seq: self.lastSeq,
            method: method,
            data: data,
            headers: options.headers,
            completion: completion,
            deadline: deadline,
            counted: counted
        )
        slot.call = call
        self.calls[call.seq] = call
        self.dues.push(RpcDue(nanos: deadline, seq: call.seq, resend: false))
        if self.connected && !client.refreshBusy {
            self.writeCall(call)
        }
        self.armTimer()
    }


    /// Cancels a call on the client's queue. A call not on the wire fails at once; a sent call gets
    /// a cancel command for the server, and keeps its route for the late reply.
    internal func cancelCall(_ call: TrackedRpc?) {
        guard self.client != nil else {
            return
        }
        guard let target: TrackedRpc = call else {
            return
        }
        self.finishLocally(target, error: cancelledCallError())
        self.armTimer()
    }


    /// The client's connection is confirmed: flushes the pending cancels and the waiting calls. The calls wait
    /// while a refresh() call or a refresh command is in flight (contract 4.3); onRefreshIdle writes them then.
    /// `capable` is whether the server confirmed the RPC options.
    internal func onConnected(capable: Bool) {
        guard let client: CentrifugeClient = self.client else {
            return
        }
        self.connected = true
        self.capable = capable
        if capable {
            let cancels: [UInt64] = self.pendingCancels
            self.pendingCancels = []
            for msgID: UInt64 in cancels {
                self.sendCancel(msgID)
            }
        }
        if !client.refreshBusy {
            for call: TrackedRpc in self.queuedInWriteOrder() {
                self.writeCall(call)
            }
        }
        self.armTimer()
    }


    /// The refresh state went idle: a refresh() call and every refresh command are settled. The calls that waited
    /// for it are written now, when the connection is confirmed.
    internal func onRefreshIdle() {
        guard let client: CentrifugeClient = self.client, self.connected, !client.refreshBusy else {
            return
        }
        for call: TrackedRpc in self.queuedInWriteOrder() {
            self.writeCall(call)
        }
        self.armTimer()
    }


    /// The transport is gone. Sent calls wait for the next connection (a plain call fails). A
    /// terminal disconnect fails every waiting call and drops the acks; the pending cancels stay.
    internal func onTransportLost(terminal: Bool) {
        guard self.client != nil else {
            return
        }
        self.connected = false
        self.capable = false
        let lost: [Route] = Array(self.routes.values)
        self.routes.removeAll()
        self.expiries = RpcExpiryQueue()
        let cancels: [UInt64] = lost.filter { (route: Route) -> Bool in
            return route.isCancel
        }.map { (route: Route) -> UInt64 in
            return route.msgID
        }.sorted()
        for msgID: UInt64 in cancels {
            self.addPendingCancel(msgID)
        }
        for call: TrackedRpc in self.sortedCalls() where call.phase == .sent || call.phase == .resendWait {
            if call.msgID == 0 {
                self.settle(call, .failure(CentrifugeError.connectionClosed))
                continue
            }
            call.phase = .queued
            call.commandId = 0
            call.retransmit = true
        }
        if terminal {
            for call: TrackedRpc in self.sortedCalls() where call.phase == .queued {
                if !call.everSent {
                    self.settle(call, .failure(CentrifugeError.clientDisconnected))
                    continue
                }
                if call.msgID != 0 {
                    self.addPendingCancel(call.msgID)
                }
                self.settle(call, .failure(CentrifugeError.connectionClosed))
            }
            self.pendingAcks = []
        }
        self.armTimer()
    }


    /// Takes a reply of a command the tracker wrote. The client calls it only for ids `owns` reports.
    internal func handleReply(_ reply: Centrifugal_Centrifuge_Protocol_Reply) {
        guard self.client != nil else {
            return
        }
        guard let route: Route = self.routes.removeValue(forKey: reply.id) else {
            return
        }
        if route.isCancel {
            return
        }
        guard let call: TrackedRpc = route.call else {
            // A late reply to a call that settled early: its msg_id is acked, so the server can
            // drop its record.
            if route.msgID != 0 {
                self.pendingAcks.append(route.msgID)
            }
            self.armTimer()
            return
        }
        if reply.hasError && call.msgID != 0, let signal: RpcRetrySignal = retrySignal(of: reply.error) {
            // A refused call is not settled and not acked: the server did not run it, and an ack
            // would let the server forget a msg_id that is still to be resent.
            self.handleRetry(call, signal: signal, error: reply.error)
            self.armTimer()
            return
        }
        if call.msgID != 0 {
            self.pendingAcks.append(call.msgID)
        }
        if reply.hasError {
            self.settle(call, .failure(rpcErrorValue(reply.error)))
        } else {
            self.settle(call, .success(CentrifugeRpcResult(data: reply.rpc.data, cached: reply.rpc.cached)))
        }
        self.armTimer()
    }


    /// Writes a queued call on the connected transport: a tracked call with its msg_id, or a plain
    /// call. A call that the connection cannot carry fails here.
    private func writeCall(_ call: TrackedRpc) {
        guard let client: CentrifugeClient = self.client else {
            return
        }
        guard call.phase == .queued else {
            return
        }
        let tracked: Bool = self.capable && client.config.instance != nil
        if !tracked {
            if !self.capable && call.everSent {
                // Written on a lost connection, which cannot resend it.
                if call.msgID != 0 {
                    self.addPendingCancel(call.msgID)
                }
                self.settle(call, .failure(CentrifugeError.connectionClosed))
                return
            }
            if !self.capable && !call.headers.isEmpty {
                self.settle(call, .failure(CentrifugeError.replyError(code: rpcCodeUnsupported, message: "unsupported", temporary: false)))
                return
            }
        }
        if tracked && call.msgID == 0 {
            do {
                call.msgID = try self.nextMsgID(client: client)
            } catch {
                self.settle(call, .failure(error))
                return
            }
        }
        var request: Centrifugal_Centrifuge_Protocol_RPCRequest = Centrifugal_Centrifuge_Protocol_RPCRequest()
        request.method = call.method
        request.data = call.data
        request.headers = call.headers
        if tracked {
            request.msgID = call.msgID
            request.retransmit = call.retransmit
        }
        do {
            let id: UInt32 = try self.transmit(client: client, request: request, call: call, msgID: call.msgID, isCancel: false)
            call.commandId = id
            call.phase = .sent
            call.everSent = true
        } catch {
            self.settle(call, .failure(CentrifugeError.transportWriteError(error: error)))
        }
    }


    /// Writes one rpc or cancel command with the pending acks, and routes its reply. Throws when the
    /// command cannot be encoded; then nothing is written and the acks stay pending.
    private func transmit(
        client: CentrifugeClient,
        request: Centrifugal_Centrifuge_Protocol_RPCRequest,
        call: TrackedRpc?,
        msgID: UInt64,
        isCancel: Bool
    ) throws -> UInt32 {
        var rpc: Centrifugal_Centrifuge_Protocol_RPCRequest = request
        rpc.ack = self.pendingAcks
        var command: Centrifugal_Centrifuge_Protocol_Command = Centrifugal_Centrifuge_Protocol_Command()
        command.rpc = rpc
        let id: UInt32 = try client.writeTrackedCommand(&command)
        self.pendingAcks = []
        var expiry: UInt64? = nil
        if isCancel {
            let dropAt: UInt64 = client.clock.monotonicNanos() + clientNanos(client.config.timeout)
            expiry = dropAt
            self.expiries.push(RpcRouteExpiry(commandId: id, nanos: dropAt))
        }
        self.routes[id] = Route(call: call, msgID: msgID, isCancel: isCancel, expiry: expiry)
        return id
    }


    /// Sends a cancel command for a msg_id now, or keeps it for the next capable connection.
    private func sendCancel(_ msgID: UInt64) {
        guard let client: CentrifugeClient = self.client else {
            return
        }
        guard self.connected && self.capable else {
            self.addPendingCancel(msgID)
            return
        }
        var request: Centrifugal_Centrifuge_Protocol_RPCRequest = Centrifugal_Centrifuge_Protocol_RPCRequest()
        request.cancel = msgID
        do {
            _ = try self.transmit(client: client, request: request, call: nil, msgID: msgID, isCancel: true)
        } catch {
            // The error is dropped on purpose: the cancel is kept, and the next capable connection sends
            // it. A protobuf cancel request cannot fail to encode, so the kept cancel is the only outcome.
            self.addPendingCancel(msgID)
        }
    }


    /// Keeps a cancel for the next capable connection. When the bound is full, the oldest goes.
    private func addPendingCancel(_ msgID: UInt64) {
        guard let client: CentrifugeClient = self.client else {
            return
        }
        self.pendingCancels.append(msgID)
        let limit: Int = client.config.maxPendingRpc
        if self.pendingCancels.count > limit {
            self.pendingCancels.removeFirst(self.pendingCancels.count - limit)
        }
    }


    /// Handles a refusal of a tracked call: a new msg_id at once, or a resend later with the same one.
    /// Past the deadline, and once the resends of the signal are used up, the server error is surfaced
    /// unchanged: no attempt could run inside the call, and the server did not run it.
    private func handleRetry(_ call: TrackedRpc, signal: RpcRetrySignal, error: Centrifugal_Centrifuge_Protocol_Error) {
        guard let client: CentrifugeClient = self.client else {
            return
        }
        let now: UInt64 = client.clock.monotonicNanos()
        guard call.deadline > now else {
            self.surfaceRefusal(call, error: error)
            return
        }
        switch signal {
        case .newMsgID:
            guard call.newIdResends < maxNewIdResends else {
                self.surfaceRefusal(call, error: error)
                return
            }
            call.newIdResends += 1
            self.generator?.resync(serverTimeMillis: client.serverTimeMillis())
            call.msgID = 0
            call.retransmit = false
            call.phase = .queued
            self.writeCall(call)
        case .later:
            guard call.laterResends < maxLaterResends else {
                self.surfaceRefusal(call, error: error)
                return
            }
            // The range of the draw is capped at the remaining deadline, not the drawn value, so the
            // resend is never due after it. The draw is uniform over the capped range.
            let remaining: UInt64 = call.deadline - now
            let delay: UInt64 = laterResendDelayNanos(attempt: call.laterResends, remaining: remaining, random: client.random)
            call.laterResends += 1
            call.phase = .resendWait
            call.commandId = 0
            call.resendAt = now + delay
            call.retransmit = true
            self.dues.push(RpcDue(nanos: call.resendAt, seq: call.seq, resend: true))
        }
    }


    /// Settles a refused call with the server error, unchanged. The refusal is answered, so its msg_id is
    /// acked, as for any other error reply.
    private func surfaceRefusal(_ call: TrackedRpc, error: Centrifugal_Centrifuge_Protocol_Error) {
        if call.msgID != 0 {
            self.pendingAcks.append(call.msgID)
        }
        self.settle(call, .failure(rpcErrorValue(error)))
    }


    /// Settles a call from this side: its deadline or its cancel. A sent call keeps its route for the
    /// late reply and gets a cancel for the server. A call that was written and lost keeps its
    /// cancel as pending.
    private func finishLocally(_ call: TrackedRpc, error: CentrifugeError) {
        switch call.phase {
        case .queued:
            if call.everSent && call.msgID != 0 {
                self.addPendingCancel(call.msgID)
            }
        case .sent:
            self.retainRoute(call)
            if call.msgID != 0 {
                self.sendCancel(call.msgID)
            }
        case .resendWait:
            if call.msgID != 0 {
                self.sendCancel(call.msgID)
            }
        case .settled:
            return
        }
        self.settle(call, .failure(error))
    }


    /// Keeps the route of a sent call for its late reply, for one call timeout.
    private func retainRoute(_ call: TrackedRpc) {
        guard let client: CentrifugeClient = self.client else {
            return
        }
        guard call.commandId != 0, var route: Route = self.routes[call.commandId] else {
            return
        }
        let dropAt: UInt64 = client.clock.monotonicNanos() + clientNanos(client.config.timeout)
        route.call = nil
        route.expiry = dropAt
        self.routes[call.commandId] = route
        self.expiries.push(RpcRouteExpiry(commandId: call.commandId, nanos: dropAt))
    }


    /// Completes a call once. The bound is released here.
    private func settle(_ call: TrackedRpc, _ result: Result<CentrifugeRpcResult, Error>) {
        guard call.phase != .settled else {
            return
        }
        call.phase = .settled
        self.calls.removeValue(forKey: call.seq)
        if call.counted {
            self.inFlight -= 1
        }
        call.completion(result)
    }


    /// The msg_id of the next tracked write. The generator starts at the server time of its first use.
    private func nextMsgID(client: CentrifugeClient) throws -> UInt64 {
        var generator: MsgIdGenerator = self.generator ?? MsgIdGenerator(now: client.serverTimeMillis(), random: client.random)
        defer {
            self.generator = generator
        }
        return try generator.next(serverTimeMillis: client.serverTimeMillis())
    }


    /// The waiting calls in the order they go out: resends by msg_id first, then the calls that were
    /// never written, in call order.
    private func queuedInWriteOrder() -> [TrackedRpc] {
        let queued: [TrackedRpc] = self.sortedCalls().filter { (call: TrackedRpc) -> Bool in
            return call.phase == .queued
        }
        let resends: [TrackedRpc] = queued.filter { (call: TrackedRpc) -> Bool in
            return call.retransmit
        }.sorted { (first: TrackedRpc, second: TrackedRpc) -> Bool in
            return first.msgID < second.msgID
        }
        let firsts: [TrackedRpc] = queued.filter { (call: TrackedRpc) -> Bool in
            return !call.retransmit
        }
        return resends + firsts
    }


    private func sortedCalls() -> [TrackedRpc] {
        return self.calls.values.sorted { (first: TrackedRpc, second: TrackedRpc) -> Bool in
            return first.seq < second.seq
        }
    }


    /// Whether a due entry still stands: its call is waiting, and for a resend, still in the wait
    /// that set the entry. A deadline entry stands while its call waits.
    private func isLive(_ due: RpcDue) -> Bool {
        guard let call: TrackedRpc = self.calls[due.seq] else {
            return false
        }
        if !due.resend {
            return true
        }
        return call.phase == .resendWait && call.resendAt == due.nanos
    }


    /// Whether a route expiry still stands: its route exists and has the same expiry.
    private func isCurrent(_ expiry: RpcRouteExpiry) -> Bool {
        return self.routes[expiry.commandId]?.expiry == expiry.nanos
    }


    /// Drops the entries at the front of both queues that no longer stand, so the fronts are the
    /// earliest live moments.
    private func dropStaleFronts() {
        while let due: RpcDue = self.dues.earliest, !self.isLive(due) {
            self.dues.pop()
        }
        while let expiry: RpcRouteExpiry = self.expiries.earliest, !self.isCurrent(expiry) {
            self.expiries.pop()
        }
    }


    /// The earliest moment the timer must run, or nil when nothing needs it.
    private func nextWakeNanos() -> UInt64? {
        self.dropStaleFronts()
        var earliest: UInt64? = nil
        if let due: RpcDue = self.dues.earliest {
            earliest = due.nanos
        }
        if let expiry: RpcRouteExpiry = self.expiries.earliest {
            earliest = earlierNanos(earliest, expiry.nanos)
        }
        return earliest
    }


    /// Keeps the one timer at the earliest moment. It is re-armed only when that moment changes.
    private func armTimer() {
        guard let client: CentrifugeClient = self.client else {
            return
        }
        let next: UInt64? = self.nextWakeNanos()
        self.timer.rearm(at: next, on: client, lateGrace: true) { [weak self] in
            self?.onTimer()
        }
    }


    /// Runs what is due: the call deadlines, the later resends and the route expiries, in time order.
    /// A timer that finds the client gone does nothing and does not re-arm.
    private func onTimer() {
        self.timer.forget()
        guard let client: CentrifugeClient = self.client else {
            return
        }
        let now: UInt64 = client.clock.monotonicNanos()
        while let due: RpcDue = self.dues.earliest, due.nanos <= now {
            self.dues.pop()
            guard let call: TrackedRpc = self.calls[due.seq], self.isLive(due) else {
                continue
            }
            if call.deadline <= now {
                self.finishLocally(call, error: CentrifugeError.timeout)
            } else if due.resend && self.connected {
                call.phase = .queued
                self.writeCall(call)
            }
        }
        while let expiry: RpcRouteExpiry = self.expiries.earliest, expiry.nanos <= now {
            self.expiries.pop()
            if self.isCurrent(expiry) {
                self.routes.removeValue(forKey: expiry.commandId)
            }
        }
        self.armTimer()
    }
}
