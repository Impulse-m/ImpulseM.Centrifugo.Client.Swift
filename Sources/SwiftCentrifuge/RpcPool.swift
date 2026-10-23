import Foundation

// The rpc pool: several connections per endpoint URL, a window of calls on each connection, and a bounded line of
// waiting calls per endpoint key. The pool runs on the main client's queue, which is also where its completions run.
// Its state is touched on that queue only; the stats snapshot is the one value read from other threads.
//
// Timers come from the main client's scheduler: one idle timer per connection, and one deadline timer for the
// waiting calls, which also wakes at the end of an endpoint's hold (after a connection ended for good). A call in
// flight carries its own deadline on its connection. This slice has no token source, no resend, no redirect: a call fails with the answer of its
// connection, and a call on a connection that is lost fails with that connection's error.

/// A pool of connections for plain rpc calls: several connections per endpoint, a window of calls on each, and a
/// bounded wait queue. The calls are plain requests, so their methods must be safe to run more than once.
public final class CentrifugeRpcPool {
    /// The client whose queue, clock, scheduler and random source the pool shares, and whose session state (ended,
    /// disconnected) decides the refusal of a call.
    private let main: CentrifugeClient

    /// The queue of the pool: the main client's. Its state is touched on it only, and it runs the completions.
    internal let queue: DispatchQueue

    private let options: CentrifugeRpcPoolOptions

    /// The configuration error of the options, or nil. A pool with one fails every call with it.
    private let configError: CentrifugeError?

    /// The settings of each connection, from the pool's options.
    private let connectionConfig: CentrifugeClientConfig

    /// Guards `statsSnapshot`, which the queue writes and any thread reads.
    private let statsLock: NSLock = NSLock()

    private var statsSnapshot: CentrifugeRpcPoolStats = CentrifugeRpcPoolStats(connections: 0, inflight: 0, queued: 0)

    private var endpointsByURL: [String: RpcPoolEndpoint] = [:]

    /// The endpoints of the keys resolved so far. A key whose resolution came back empty is not kept.
    private var endpointsByKey: [String: [RpcPoolEndpoint]] = [:]

    /// The waiting calls of each key, in admission order.
    private var lines: [String: [RpcPoolCall]] = [:]

    /// Every call that is not settled yet, so that `close` settles them all.
    private var unsettled: [ObjectIdentifier: RpcPoolCall] = [:]

    /// The one timer of the waiting calls' deadlines.
    private var waitTimer: ClientDeadlineTimer = ClientDeadlineTimer()

    private var closed: Bool = false


    /// Creates a pool. Options that cannot work are not refused here: the pool then fails every call with the
    /// `configurationError`. `create` refuses them.
    public init(main: CentrifugeClient, options: CentrifugeRpcPoolOptions) {
        self.main = main
        self.queue = main.syncQueue
        self.options = options
        self.configError = poolConfigurationError(options)
        self.connectionConfig = CentrifugeClientConfig(
            timeout: options.timeout,
            headers: options.headers,
            minReconnectDelay: options.minReconnectDelay,
            maxReconnectDelay: options.maxReconnectDelay,
            maxServerPingDelay: options.maxServerPingDelay,
            name: options.name,
            version: options.version
        )
    }


    /// Creates a pool, and refuses options that cannot work.
    /// - Throws: `CentrifugeError.configurationError` for an option that cannot work.
    public static func create(main: CentrifugeClient, options: CentrifugeRpcPoolOptions) throws -> CentrifugeRpcPool {
        if let error: CentrifugeError = poolConfigurationError(options) {
            throw error
        }
        return CentrifugeRpcPool(main: main, options: options)
    }


    /// Runs a call on a connection of its endpoint key. The call takes a free slot of a live connection, or waits in
    /// the line of its key while a connection opens or a slot frees. The handle cancels the call: a call that still
    /// waits fails at once, and a call in flight is ignored when its connection answers.
    ///
    /// Failures: `clientRejected(code: 4)` after `close`, `unauthorized` and `clientDisconnected` while the main client
    /// is ended or disconnected, `configurationError` for an option that cannot work, `replyError(code: 16)` when the
    /// line is full, `timeout` at the deadline, `replyError(code: 17)` for a cancel, and `connectionClosed` for a call
    /// in flight that the pool closes.
    @discardableResult
    public func rpc(
        endpointKey: String,
        method: String,
        data: Data,
        options: CentrifugeRpcPoolCallOptions,
        completion: @escaping (Result<CentrifugeRpcResult, Error>) -> Void
    ) -> CentrifugeRpcCall {
        let call: RpcPoolCall = RpcPoolCall(
            endpointKey: endpointKey,
            method: method,
            data: data,
            options: options,
            completion: completion
        )
        self.queue.async { [weak self] in
            self?.admit(call)
        }
        let queue: DispatchQueue = self.queue
        return CentrifugeRpcCall(onCancel: { [weak self] () -> Void in
            queue.async {
                self?.cancel(call)
            }
        })
    }


    /// The state of the pool. Safe to call from any thread, and from a callback of the pool.
    public func stats() -> CentrifugeRpcPoolStats {
        self.statsLock.lock()
        defer {
            self.statsLock.unlock()
        }
        return self.statsSnapshot
    }


    /// Closes every connection. The completion runs on the pool's queue once the pool is closed. Calls still waiting
    /// fail with `replyError(code: 17)`, calls in flight with `connectionClosed`, and later calls with
    /// `clientRejected(code: 4)`.
    public func close(completion: @escaping () -> Void) {
        self.queue.async { [weak self] in
            self?.closeOnQueue()
            completion()
        }
    }


    // MARK: - Admission and placement

    /// The admission checks, in order: configuration, closed, the main client's session, the options of the call,
    /// then placement (a live slot, else the line under `maxQueued`).
    private func admit(_ call: RpcPoolCall) {
        if let error: CentrifugeError = configError {
            settle(call, .failure(error))
            return
        }
        if closed {
            settle(call, .failure(CentrifugeError.clientRejected(code: 4, message: "rpc pool is closed")))
            return
        }
        if main.state == .disconnected {
            let error: CentrifugeError = main.sessionEnded ? CentrifugeError.unauthorized : CentrifugeError.clientDisconnected
            settle(call, .failure(error))
            return
        }
        if let error: CentrifugeError = poolCallConfigurationError(
            call.options,
            affinityHeader: options.affinityHeader,
            poolTimeout: options.timeout
        ) {
            settle(call, .failure(error))
            return
        }
        let endpoints: [RpcPoolEndpoint] = endpointsOf(call.endpointKey)
        if endpoints.isEmpty {
            settle(call, .failure(CentrifugeError.configurationError(message: "the endpoint key has no endpoint")))
            return
        }
        let timeout: TimeInterval = call.options.timeout ?? options.timeout
        call.deadline = main.clock.monotonicNanos() + clientNanos(timeout)
        unsettled[ObjectIdentifier(call)] = call
        let line: [RpcPoolCall] = lines[call.endpointKey] ?? []
        if line.isEmpty, let conn: RpcPoolConnection = liveConnection(endpoints) {
            place(call, on: conn)
            publishStats()
            return
        }
        // A call that may open a connection is admitted at any bound: the connection it opens serves it.
        if opener(endpoints) == nil && queuedCount() >= options.maxQueued {
            settle(call, .failure(CentrifugeError.replyError(code: rpcCodeLimitExceeded, message: "limit exceeded", temporary: false)))
            return
        }
        lines[call.endpointKey, default: []].append(call)
        drain(call.endpointKey)
        publishStats()
    }


    /// The endpoints of an endpoint key. A key is resolved once and kept; an empty resolution is not kept, so the next
    /// call resolves again.
    private func endpointsOf(_ key: String) -> [RpcPoolEndpoint] {
        if let known: [RpcPoolEndpoint] = endpointsByKey[key] {
            return known
        }
        let urls: [String] = options.endpoints(key)
        var found: [RpcPoolEndpoint] = []
        for url: String in urls {
            found.append(endpointFor(url))
        }
        if !found.isEmpty {
            endpointsByKey[key] = found
        }
        return found
    }


    /// The endpoint of a URL, made on first use. Connections belong to it, whichever key resolved to it.
    private func endpointFor(_ url: String) -> RpcPoolEndpoint {
        if let known: RpcPoolEndpoint = endpointsByURL[url] {
            return known
        }
        let endpoint: RpcPoolEndpoint = RpcPoolEndpoint(url: url)
        endpointsByURL[url] = endpoint
        return endpoint
    }


    /// The live connection with a free slot and the fewest calls, over the endpoints in order. Nil when there is none.
    private func liveConnection(_ endpoints: [RpcPoolEndpoint]) -> RpcPoolConnection? {
        var best: RpcPoolConnection? = nil
        for endpoint: RpcPoolEndpoint in endpoints {
            for conn: RpcPoolConnection in endpoint.connections {
                if !conn.isConnected || conn.inFlight >= options.maxInflightPerConnection {
                    continue
                }
                guard let current: RpcPoolConnection = best else {
                    best = conn
                    continue
                }
                if conn.inFlight < current.inFlight {
                    best = conn
                }
            }
        }
        return best
    }


    /// The first endpoint that may open a connection now: not held, below `maxConnectionsPerEndpoint`, and with no
    /// connection connecting. Nil when none may.
    private func opener(_ endpoints: [RpcPoolEndpoint]) -> RpcPoolEndpoint? {
        let now: UInt64 = main.clock.monotonicNanos()
        for endpoint: RpcPoolEndpoint in endpoints {
            if let until: UInt64 = endpoint.holdUntil, now < until {
                continue
            }
            if endpoint.connections.count >= options.maxConnectionsPerEndpoint {
                continue
            }
            let connecting: Bool = endpoint.connections.contains { (conn: RpcPoolConnection) -> Bool in
                return !conn.isConnected
            }
            if connecting {
                continue
            }
            return endpoint
        }
        return nil
    }


    /// Places the calls of a key line, head first, while the head can be placed. When the head cannot be placed and an
    /// endpoint may open a connection, one is opened and the line waits for it.
    private func drain(_ key: String) {
        if closed {
            return
        }
        let endpoints: [RpcPoolEndpoint] = endpointsByKey[key] ?? []
        while let head: RpcPoolCall = lines[key]?.first {
            let now: UInt64 = main.clock.monotonicNanos()
            if head.deadline <= now {
                removeHead(key)
                settle(head, .failure(CentrifugeError.timeout))
                continue
            }
            guard let conn: RpcPoolConnection = liveConnection(endpoints) else {
                if let endpoint: RpcPoolEndpoint = opener(endpoints) {
                    openConnection(endpoint)
                }
                break
            }
            removeHead(key)
            place(head, on: conn)
        }
        if lines[key]?.isEmpty == true {
            lines[key] = nil
        }
        updateWaitTimer()
    }


    /// Drains every key line. Used when a connection or a hold changes.
    private func drainAll() {
        for key: String in Array(lines.keys) {
            drain(key)
        }
    }


    private func removeHead(_ key: String) {
        lines[key]?.removeFirst()
    }


    /// Removes a waiting call from its line. Returns false when the call is not in a line.
    private func removeFromLine(_ call: RpcPoolCall) -> Bool {
        guard var line: [RpcPoolCall] = lines[call.endpointKey] else {
            return false
        }
        guard let index: Int = line.firstIndex(where: { (candidate: RpcPoolCall) -> Bool in
            return candidate === call
        }) else {
            return false
        }
        line.remove(at: index)
        if line.isEmpty {
            lines[call.endpointKey] = nil
        } else {
            lines[call.endpointKey] = line
        }
        return true
    }


    /// Sends a call on a connection. The call holds the connection's slot until the connection answers it.
    private func place(_ call: RpcPoolCall, on conn: RpcPoolConnection) {
        let now: UInt64 = main.clock.monotonicNanos()
        var span: UInt64 = 0
        if call.deadline > now {
            span = call.deadline - now
        }
        // The rest of the deadline is the timeout of the call on the connection, which never exceeds the pool's.
        let timeout: TimeInterval = min(clientSeconds(nanos: span), options.timeout)
        if timeout <= 0 {
            settle(call, .failure(CentrifugeError.timeout))
            return
        }
        var headers: [String: String] = call.options.headers
        if let name: String = options.affinityHeader, let affinity: String = call.options.affinity {
            headers[name] = affinity
        }
        call.connection = conn
        call.holdsSlot = true
        conn.inFlight += 1
        let queue: DispatchQueue = self.queue
        conn.client.rpc(
            method: call.method,
            data: call.data,
            options: CentrifugeRpcOptions(headers: headers, timeout: timeout)
        ) { (result: Result<CentrifugeRpcResult, Error>) -> Void in
            queue.async { [weak self] in
                self?.innerDone(call, result)
            }
        }
    }


    /// The answer of a connection to a call the pool placed. The slot is released first, so the settlement and the
    /// lines see the connection free.
    private func innerDone(_ call: RpcPoolCall, _ result: Result<CentrifugeRpcResult, Error>) {
        releaseSlot(call)
        settle(call, result)
        drainAll()
        publishStats()
    }


    /// Releases the slot a call holds on its connection. The connection's idle clock starts again when it has no call.
    private func releaseSlot(_ call: RpcPoolCall) {
        guard call.holdsSlot, let conn: RpcPoolConnection = call.connection else {
            return
        }
        call.holdsSlot = false
        conn.inFlight -= 1
        conn.lastUse = main.clock.monotonicNanos()
        if conn.inFlight == 0 {
            armIdle(conn)
        }
    }


    /// Runs the completion of a call, once. The call is taken out of the unsettled set first.
    private func settle(_ call: RpcPoolCall, _ result: Result<CentrifugeRpcResult, Error>) {
        if call.settled {
            return
        }
        call.settled = true
        unsettled[ObjectIdentifier(call)] = nil
        publishStats()
        call.completion(result)
    }


    /// Cancels a call. A waiting call leaves its line and fails at once. A call in flight fails at once too, and its
    /// connection still answers it, which releases its slot without a second completion.
    private func cancel(_ call: RpcPoolCall) {
        if call.settled {
            return
        }
        let cancelled: CentrifugeError = CentrifugeError.replyError(code: rpcCodeCancelled, message: "cancelled", temporary: false)
        if removeFromLine(call) {
            settle(call, .failure(cancelled))
            drain(call.endpointKey)
        } else {
            settle(call, .failure(cancelled))
        }
        publishStats()
    }


    // MARK: - Connections

    /// Opens a connection to an endpoint. It connects on its own queue, and its events come back through the queue.
    private func openConnection(_ endpoint: RpcPoolEndpoint) {
        let conn: RpcPoolConnection = RpcPoolConnection(
            endpoint: endpoint,
            config: connectionConfig,
            pool: self,
            now: main.clock.monotonicNanos()
        )
        endpoint.holdUntil = nil
        endpoint.connections.append(conn)
        conn.client.connect()
        armIdle(conn)
        publishStats()
    }


    /// The connection of an endpoint confirmed its connect: it takes calls now.
    internal func connectionConnected(_ conn: RpcPoolConnection) {
        if closed || conn.closed {
            return
        }
        conn.linkState = .connected
        conn.endpoint.failures = 0
        drainAll()
        publishStats()
    }


    /// The connection of an endpoint is connecting again (its first connect, or a reconnect of its client). It takes
    /// no calls until it connects.
    internal func connectionConnecting(_ conn: RpcPoolConnection) {
        if closed || conn.closed {
            return
        }
        conn.linkState = .connecting
        publishStats()
    }


    /// The connection of an endpoint ended for good. It leaves its endpoint, and the endpoint is held for a backoff.
    internal func connectionDisconnected(_ conn: RpcPoolConnection) {
        if closed || conn.closed {
            return
        }
        conn.closed = true
        conn.idleItem?.cancel()
        conn.idleItem = nil
        conn.endpoint.connections.removeAll { (candidate: RpcPoolConnection) -> Bool in
            return candidate === conn
        }
        conn.endpoint.failures += 1
        holdEndpoint(conn.endpoint)
        publishStats()
    }


    /// Holds an endpoint for a backoff, after a connection of it ended for good: no connection opens until the hold
    /// ends. The backoff is the connection settings' reconnect span, with full jitter from the main client's random
    /// source. No timer is armed for it: the pool's deadline timer wakes at the end of the hold (updateWaitTimer).
    private func holdEndpoint(_ endpoint: RpcPoolEndpoint) {
        let delay: UInt64 = boundedBackoffNanos(
            minimumNanos: clientNanos(options.minReconnectDelay),
            ceilingNanos: clientNanos(options.maxReconnectDelay),
            attempt: endpoint.failures - 1,
            random: main.random
        )
        endpoint.holdUntil = main.clock.monotonicNanos() + delay
        updateWaitTimer()
    }


    /// Arms the idle timer of a connection, when it has none and the idle timeout is set. The timer runs at the end of
    /// the idle span counted from the connection's last use, and checks again when it fires.
    private func armIdle(_ conn: RpcPoolConnection) {
        if closed || conn.closed || conn.idleItem != nil || options.idleTimeout <= 0 {
            return
        }
        let now: UInt64 = main.clock.monotonicNanos()
        let due: UInt64 = conn.lastUse + clientNanos(options.idleTimeout)
        var span: UInt64 = 0
        if due > now {
            span = due - now
        }
        let item: DispatchWorkItem = DispatchWorkItem { [weak self, weak conn] () -> Void in
            guard let owner: CentrifugeRpcPool = self, let connection: RpcPoolConnection = conn else {
                return
            }
            connection.idleItem = nil
            owner.idleDue(connection)
        }
        conn.idleItem = item
        main.scheduleAfter(clientSeconds(nanos: span), item)
    }


    /// The idle timer of a connection ran. A connection with a call in flight is left alone: the release of that call
    /// arms the timer again. A connection used since the timer was armed is armed for the rest of its span.
    private func idleDue(_ conn: RpcPoolConnection) {
        if closed || conn.closed || conn.inFlight > 0 {
            return
        }
        let now: UInt64 = main.clock.monotonicNanos()
        let due: UInt64 = conn.lastUse + clientNanos(options.idleTimeout)
        if now < due {
            armIdle(conn)
            return
        }
        closeConnection(conn)
        publishStats()
    }


    /// Closes one connection the pool chose to close (idle). It leaves its endpoint at once.
    private func closeConnection(_ conn: RpcPoolConnection) {
        conn.closed = true
        conn.idleItem?.cancel()
        conn.idleItem = nil
        conn.endpoint.connections.removeAll { (candidate: RpcPoolConnection) -> Bool in
            return candidate === conn
        }
        conn.client.disconnect()
    }


    // MARK: - Timers, stats and close

    /// Keeps the deadline timer at the earliest moment that wakes the pool: the deadline of a waiting call, or the end
    /// of a hold while a call waits. Only moments still ahead count, so the timer never re-arms for a past moment.
    private func updateWaitTimer() {
        let now: UInt64 = main.clock.monotonicNanos()
        var earliest: UInt64? = nil
        for line: [RpcPoolCall] in lines.values {
            for call: RpcPoolCall in line {
                earliest = earlierNanos(earliest, call.deadline)
            }
        }
        if !lines.isEmpty {
            for endpoint: RpcPoolEndpoint in endpointsByURL.values {
                if let until: UInt64 = endpoint.holdUntil, until > now {
                    earliest = earlierNanos(earliest, until)
                }
            }
        }
        waitTimer.rearm(at: earliest, on: main, lateGrace: true) { [weak self] () -> Void in
            self?.waitTimerFired()
        }
    }


    /// The deadline timer ran: the waiting calls whose deadline passed fail with `timeout`, and the lines move on.
    private func waitTimerFired() {
        waitTimer.forget()
        if closed {
            return
        }
        let now: UInt64 = main.clock.monotonicNanos()
        var expired: [RpcPoolCall] = []
        for key: String in Array(lines.keys) {
            var kept: [RpcPoolCall] = []
            for call: RpcPoolCall in lines[key] ?? [] {
                if call.deadline <= now {
                    expired.append(call)
                } else {
                    kept.append(call)
                }
            }
            if kept.isEmpty {
                lines[key] = nil
            } else {
                lines[key] = kept
            }
        }
        for call: RpcPoolCall in expired {
            settle(call, .failure(CentrifugeError.timeout))
        }
        drainAll()
        updateWaitTimer()
    }


    private func queuedCount() -> Int {
        var total: Int = 0
        for line: [RpcPoolCall] in lines.values {
            total += line.count
        }
        return total
    }


    /// Writes the stats snapshot. Called on the queue after each change of the pool's state.
    private func publishStats() {
        var connections: Int = 0
        var inflight: Int = 0
        for endpoint: RpcPoolEndpoint in endpointsByURL.values {
            for conn: RpcPoolConnection in endpoint.connections {
                connections += 1
                inflight += conn.inFlight
            }
        }
        let snapshot: CentrifugeRpcPoolStats = CentrifugeRpcPoolStats(
            connections: connections,
            inflight: inflight,
            queued: queuedCount()
        )
        self.statsLock.lock()
        self.statsSnapshot = snapshot
        self.statsLock.unlock()
    }


    /// The close of the pool, on its queue. Every timer is cancelled, every connection is closed, and every call that
    /// is not settled fails: a waiting call with `cancelled`, a call in flight with `connectionClosed`.
    private func closeOnQueue() {
        if closed {
            return
        }
        closed = true
        waitTimer.cancel()
        for endpoint: RpcPoolEndpoint in endpointsByURL.values {
            endpoint.holdUntil = nil
            for conn: RpcPoolConnection in endpoint.connections {
                conn.closed = true
                conn.idleItem?.cancel()
                conn.idleItem = nil
                conn.client.disconnect()
            }
            endpoint.connections = []
        }
        endpointsByURL = [:]
        endpointsByKey = [:]
        lines = [:]
        for call: RpcPoolCall in Array(unsettled.values) {
            if call.connection == nil {
                settle(call, .failure(CentrifugeError.replyError(code: rpcCodeCancelled, message: "cancelled", temporary: false)))
            } else {
                settle(call, .failure(CentrifugeError.connectionClosed))
            }
        }
        publishStats()
    }
}
