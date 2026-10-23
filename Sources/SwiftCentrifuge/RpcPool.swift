import Foundation

// The rpc pool: several connections per endpoint URL, a window of calls on each connection, and a bounded line of
// waiting calls per endpoint key. The pool runs on the main client's queue, which is also where its completions run.
// Its state is touched on that queue only; the stats snapshot is the one value read from other threads.
//
// Timers come from the main client's scheduler: one idle timer per connection, and one deadline timer for the
// waiting calls. The deadline timer also wakes at the end of an endpoint's hold (after a connection ended for good)
// and at the end of a later resend's delay. A call in flight carries its own deadline on its connection. A call
// lost with its connection, refused with the later signal or moved by the reroute hook is resent while `retries`
// and its deadline allow. A call that the redirect hook moves to bytes at a URL is settled by a fetch of those bytes
// (RpcPoolRedirect.swift). The pool does not send tokens yet.

/// A pool of connections for plain rpc calls: several connections per endpoint, a window of calls on each, and a
/// bounded wait queue. The calls are plain requests, so their methods must be safe to run more than once.
public final class CentrifugeRpcPool: RpcPoolMainListener {
    /// The queue of the pool: the main client's. Its state is touched on it only, and it runs the completions.
    internal let queue: DispatchQueue

    /// The client whose queue, clock, scheduler and random source the pool shares, and whose session state (ended,
    /// disconnected) decides the refusal of a call.
    private let main: CentrifugeClient

    private let options: CentrifugeRpcPoolOptions

    /// The configuration error of the options, or nil. A pool with one fails every call with it.
    private let configError: CentrifugeError?

    /// The settings of each connection, from the pool's options.
    private let connectionConfig: CentrifugeClientConfig

    /// The redirect fetches of the pool: their slots, their line and their session.
    private let fetches: RpcPoolFetches

    /// The token source of the main client, with a pool that takes its token from it (`tokenFrom`). Nil otherwise. Set on
    /// the main client's queue, a moment after the pool is made, before any call of the pool is admitted.
    private var tokenSource: RpcPoolTokenSource? = nil

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

    /// The calls whose later resend waits for its delay. They join their line when the delay ends. They are not
    /// counted toward `maxQueued` (queuedCount). A plain array on purpose: the scans over them stay short.
    private var resendWaits: [RpcPoolCall] = []

    /// The one timer of the waiting calls' deadlines, the ends of the holds and the ends of the later resend delays.
    private var waitTimer: ClientDeadlineTimer = ClientDeadlineTimer()

    private var closed: Bool = false


    /// Creates a pool. Options that cannot work are not refused here: the pool then fails every call with the
    /// `configurationError`. `create` refuses them.
    public init(main: CentrifugeClient, options: CentrifugeRpcPoolOptions) {
        self.main = main
        self.queue = main.syncQueue
        self.options = options
        self.fetches = RpcPoolFetches(
            queue: main.syncQueue,
            limit: options.maxRedirectsInflight,
            configuration: redirectSessionConfiguration(options.urlSession)
        )
        self.configError = poolConfigurationError(options)
        var settings: CentrifugeClientConfig = CentrifugeClientConfig(
            timeout: options.timeout,
            headers: options.headers,
            minReconnectDelay: options.minReconnectDelay,
            maxReconnectDelay: options.maxReconnectDelay,
            maxServerPingDelay: options.maxServerPingDelay,
            name: options.name,
            version: options.version
        )
        settings.token = options.token
        settings.tokenGetter = options.tokenGetter
        self.connectionConfig = settings
        if options.tokenFrom {
            // The source is made, stored on the main client and told of this pool on the main client's queue: the client
            // reads the stored source there, so no thread other than the queue touches it.
            main.syncQueue.async { [weak self] () -> Void in
                let source: RpcPoolTokenSource = RpcPoolTokenSource.forClient(main)
                guard let pool: CentrifugeRpcPool = self else {
                    return
                }
                pool.tokenSource = source
                source.addListener(pool)
            }
        }
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
    /// line is full, `timeout` at the deadline, `replyError(code: 17)` for a cancel, `replyError(code: 18)` for a
    /// redirect that did not complete, and `connectionClosed` for a call in flight that the pool closes.
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
        // The admission holds the pool until it runs: a pool released right after this call still settles it.
        self.queue.async {
            self.admit(call)
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
        if closed {
            settle(call, .failure(CentrifugeError.clientRejected(code: 4, message: "rpc pool is closed")))
            return
        }
        if let error: CentrifugeError = configError {
            settle(call, .failure(error))
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
        if let source: RpcPoolTokenSource = tokenSource {
            // The call is bound to the identity generation of the main client now, and refused when no connection can
            // take it while the client's token is spent.
            call.generation = source.generation
            if source.isSpent && !hasLiveConnection(endpoints) {
                settle(call, .failure(CentrifugeError.clientRejected(code: 3, message: "token refused")))
                return
            }
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


    /// Whether a connected connection of the current generation exists, whatever its load (as Java's hasLive). A spent
    /// token refuses a call only when no such connection can serve it later; a busy connection frees its slot.
    private func hasLiveConnection(_ endpoints: [RpcPoolEndpoint]) -> Bool {
        let current: UInt64 = currentGeneration()
        for endpoint: RpcPoolEndpoint in endpoints {
            for conn: RpcPoolConnection in endpoint.connections where conn.isConnected && conn.generation == current {
                return true
            }
        }
        return false
    }


    /// The live connection with a free slot and the fewest calls, over the endpoints in order. Nil when there is none.
    private func liveConnection(_ endpoints: [RpcPoolEndpoint]) -> RpcPoolConnection? {
        var best: RpcPoolConnection? = nil
        let current: UInt64 = currentGeneration()
        for endpoint: RpcPoolEndpoint in endpoints {
            for conn: RpcPoolConnection in endpoint.connections {
                if !conn.isConnected || conn.inFlight >= options.maxInflightPerConnection || conn.generation != current {
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
        retireStaleIdle(endpoints)
        while let head: RpcPoolCall = lines[key]?.first {
            let now: UInt64 = main.clock.monotonicNanos()
            if head.deadline <= now {
                removeHead(key)
                settle(head, .failure(CentrifugeError.timeout))
                continue
            }
            if let failure: CentrifugeError = waitingFailure(head, endpoints) {
                removeHead(key)
                settle(head, .failure(failure))
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


    /// The error a waiting call fails with at once, or nil while it may wait. Only a pool with `tokenFrom` has one: the
    /// main client's end or disconnect, a call bound to an identity the client has left, and a spent token that no
    /// connection of the identity can take.
    private func waitingFailure(_ call: RpcPoolCall, _ endpoints: [RpcPoolEndpoint]) -> CentrifugeError? {
        guard let source: RpcPoolTokenSource = tokenSource else {
            return nil
        }
        if main.state == .disconnected {
            if main.sessionEnded {
                return CentrifugeError.unauthorized
            }
            return CentrifugeError.clientDisconnected
        }
        if call.generation != source.generation {
            return CentrifugeError.clientRejected(code: 3, message: "identity changed")
        }
        if source.isSpent && !hasLiveConnection(endpoints) {
            return CentrifugeError.clientRejected(code: 3, message: "token refused")
        }
        return nil
    }


    /// The identity generation of the token source, or zero for a pool without `tokenFrom`.
    private func currentGeneration() -> UInt64 {
        guard let source: RpcPoolTokenSource = tokenSource else {
            return 0
        }
        return source.generation
    }


    /// Closes the idle connections of the endpoints that carry an older identity generation. They retire at this event
    /// only, when a call of their endpoint waits: the pool does not walk its connections for it.
    private func retireStaleIdle(_ endpoints: [RpcPoolEndpoint]) {
        let current: UInt64 = currentGeneration()
        for endpoint: RpcPoolEndpoint in endpoints {
            for conn: RpcPoolConnection in Array(endpoint.connections) {
                if conn.inFlight == 0 && conn.lostCalls.isEmpty && conn.generation != current {
                    closeConnection(conn)
                }
            }
        }
    }


    /// Whether the idle connections close as their session ends: a pool with `tokenFrom`, the option set, and a main client
    /// whose session the server ended.
    private func endedSessionClosesIdle() -> Bool {
        return tokenSource != nil && options.closeEndedSession && main.sessionEnded && main.state == .disconnected
    }


    /// Closes the idle connections of an ended session now (`closeEndedSession`).
    private func closeEndedIdle() {
        if !endedSessionClosesIdle() {
            return
        }
        for endpoint: RpcPoolEndpoint in Array(endpointsByURL.values) {
            for conn: RpcPoolConnection in Array(endpoint.connections) {
                if conn.inFlight == 0 && conn.lostCalls.isEmpty {
                    closeConnection(conn)
                }
            }
        }
    }


    /// The main client changed state or identity, or ended its session: the idle connections of an ended session close,
    /// and the waiting calls are placed or failed. Called on the queue by the token source.
    internal func onMainEvent() {
        if closed {
            return
        }
        closeEndedIdle()
        drainAll()
        publishStats()
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
        call.endpointURL = conn.endpoint.url
        call.holdsSlot = true
        conn.inFlight += 1
        let queue: DispatchQueue = self.queue
        let handle: CentrifugeRpcCall = conn.client.rpc(
            method: call.method,
            data: call.data,
            options: CentrifugeRpcOptions(headers: headers, timeout: timeout)
        ) { (result: Result<CentrifugeRpcResult, Error>) -> Void in
            // The answer reaches the pool even when it was released, so that the call's completion runs once.
            queue.async {
                self.innerDone(call, result)
            }
        }
        call.innerCall = handle
    }


    /// The answer of a connection to a call the pool placed. The slot is released first, so the settlement and the
    /// lines see the connection free.
    private func innerDone(_ call: RpcPoolCall, _ result: Result<CentrifugeRpcResult, Error>) {
        releaseSlot(call)
        switch result {
        case .success:
            settleAnswered(call, result)
        case .failure(let error):
            answerFailed(call, error)
        }
        drainAll()
        publishStats()
    }


    /// Decides a failed answer. A call lost with its connection waits for the connection's next event, which tells
    /// the outcome. A server error may move or resend the call. Anything else settles at once.
    private func answerFailed(_ call: RpcPoolCall, _ error: Error) {
        if call.isSettled {
            return
        }
        if isConnectionLost(error), let conn: RpcPoolConnection = call.connection, !closed, !conn.closed {
            conn.lostCalls.append(call)
            return
        }
        if let reply: CentrifugeReplyError = serverReply(of: error) {
            serverErrorAnswered(call, reply: reply, error: error)
            return
        }
        settleAnswered(call, .failure(error))
    }


    /// A server error reply. Either resend needs a resend left and a deadline still ahead, and only then does the
    /// reroute hook see the reply. A move wins over the later signal. Otherwise the error settles unchanged.
    private func serverErrorAnswered(_ call: RpcPoolCall, reply: CentrifugeReplyError, error: Error) {
        let now: UInt64 = main.clock.monotonicNanos()
        if call.resends >= options.retries || call.deadline <= now {
            settleAnswered(call, .failure(error))
            return
        }
        if let key: String = options.reroute?(reply) {
            move(call, to: key)
            return
        }
        if reply.metadata[rpcRetryMetadataKey] == rpcRetryValueLater {
            waitForLaterResend(call, now: now)
            return
        }
        settleAnswered(call, .failure(error))
    }


    /// The server error of a failed answer, as the reroute hook sees it, or nil when the error is not a server reply.
    /// Only codes from 100 up are server errors: the codes below are the client's own (unsupported headers, limit,
    /// cancel), as the JS and Java SDKs also read them.
    private func serverReply(of error: Error) -> CentrifugeReplyError? {
        guard let known: CentrifugeError = error as? CentrifugeError else {
            return nil
        }
        switch known {
        case .replyError(let code, let message, let temporary):
            if code < rpcServerErrorFloor {
                return nil
            }
            return CentrifugeReplyError(
                code: code,
                message: message,
                temporary: temporary,
                appCode: 0,
                appType: "",
                metadata: [:]
            )
        case .replyErrorDetails(let details):
            return details
        default:
            return nil
        }
    }


    /// Whether a failed answer is a connection lost before its reply.
    private func isConnectionLost(_ error: Error) -> Bool {
        guard let known: CentrifugeError = error as? CentrifugeError else {
            return false
        }
        if case .connectionClosed = known {
            return true
        }
        return false
    }


    /// Moves a call to another endpoint key. It joins the front of that key's line, so it goes before the calls that
    /// wait there. A key that resolves to no endpoint fails the call, as an admission does.
    private func move(_ call: RpcPoolCall, to key: String) {
        call.resends += 1
        call.connection = nil
        call.endpointKey = key
        if endpointsOf(key).isEmpty {
            settle(call, .failure(CentrifugeError.configurationError(message: "the endpoint key has no endpoint")))
            return
        }
        lines[key, default: []].insert(call, at: 0)
    }


    /// Resends a call lost with its connection at the back of its line, while `retries` and its deadline allow.
    /// Otherwise the call settles with the loss.
    private func resendLost(_ call: RpcPoolCall) {
        if call.isSettled {
            return
        }
        let now: UInt64 = main.clock.monotonicNanos()
        if call.resends >= options.retries || call.deadline <= now {
            settleAnswered(call, .failure(CentrifugeError.connectionClosed))
            return
        }
        call.resends += 1
        call.connection = nil
        lines[call.endpointKey, default: []].append(call)
    }


    /// Waits the delay of a later resend, at the back of the line once it ends. The delay is uniform over
    /// `0 ... min(250 ms * 2^n, remaining deadline)`, drawn from the main client's random source, where n is the
    /// number of later resends the call has made so far. The caller has checked that the deadline is still ahead.
    private func waitForLaterResend(_ call: RpcPoolCall, now: UInt64) {
        let remaining: UInt64 = call.deadline - now
        let delay: UInt64 = laterResendDelayNanos(attempt: call.laterResends, remaining: remaining, random: main.random)
        call.laterResends += 1
        call.resends += 1
        call.connection = nil
        call.resendAt = now + delay
        resendWaits.append(call)
        updateWaitTimer()
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
            if endedSessionClosesIdle() && conn.lostCalls.isEmpty {
                closeConnection(conn)
            } else {
                armIdle(conn)
            }
        }
    }


    /// Runs the completion of a call, once. The call is taken out of the unsettled set first.
    private func settle(_ call: RpcPoolCall, _ result: Result<CentrifugeRpcResult, Error>) {
        guard call.settleOnce.claim() else {
            return
        }
        call.isSettled = true
        unsettled[ObjectIdentifier(call)] = nil
        publishStats()
        call.completion(result)
    }


    /// Cancels a call. A waiting call leaves its line and fails at once. A call in flight fails at once too, and its
    /// connection call is cancelled, so the connection answers it now and releases the slot without a second completion.
    private func cancel(_ call: RpcPoolCall) {
        if removeFromLine(call) || removeFromResendWaits(call) {
            settle(call, .failure(cancelledCallError()))
            drain(call.endpointKey)
        } else {
            _ = fetches.cancel(call)
            settle(call, .failure(cancelledCallError()))
            call.innerCall?.cancel()
            updateWaitTimer()
        }
        publishStats()
    }


    /// Removes a call from the resend wait list. Returns false when the call is not waiting there.
    private func removeFromResendWaits(_ call: RpcPoolCall) -> Bool {
        let before: Int = resendWaits.count
        resendWaits.removeAll { (candidate: RpcPoolCall) -> Bool in
            return candidate === call
        }
        return resendWaits.count != before
    }


    // MARK: - Connections

    /// Opens a connection to an endpoint. It connects on its own queue, and its events come back through the queue.
    private func openConnection(_ endpoint: RpcPoolEndpoint) {
        let conn: RpcPoolConnection = RpcPoolConnection(
            endpoint: endpoint,
            config: connectionConfig,
            pool: self,
            now: main.clock.monotonicNanos(),
            tokenSource: tokenSource
        )
        endpoint.holdUntil = nil
        endpoint.connections.append(conn)
        conn.client.connect()
        armIdle(conn)
        publishStats()
    }


    /// The connection of an endpoint confirmed its connect: it takes calls now.
    internal func connectionConnected(_ conn: RpcPoolConnection, user: String, authClass: String) {
        if closed || conn.closed {
            return
        }
        if conn.generation != currentGeneration() {
            // The identity moved on while it connected: the connection retires at this event.
            closeConnection(conn)
            drainAll()
            publishStats()
            return
        }
        if let source: RpcPoolTokenSource = tokenSource, !source.confirmsIdentity(user: user, authClass: authClass) {
            // The server confirmed another identity than the one of the generation: the token is unusable, and the
            // connection retires. The source's notice then places the waiting calls again.
            closeConnection(conn)
            source.markUnusable(conn.presentedToken)
            drainAll()
            publishStats()
            return
        }
        conn.linkState = .connected
        conn.endpoint.failures = 0
        drainAll()
        publishStats()
    }


    /// The connection of an endpoint is connecting again (its first connect, or a reconnect of its client). It takes
    /// no calls until it connects. The calls it lost are resent now: the client reconnects by itself.
    internal func connectionConnecting(_ conn: RpcPoolConnection) {
        if closed || conn.closed {
            return
        }
        conn.linkState = .connecting
        let lost: [RpcPoolCall] = conn.lostCalls
        conn.lostCalls = []
        for call: RpcPoolCall in lost {
            resendLost(call)
        }
        drainAll()
        publishStats()
    }


    /// The connection of an endpoint ended for good. It leaves its endpoint. A close for message size holds nothing
    /// back. Any other end holds the endpoint for a backoff. The calls it lost settle with `connectionClosed` on a
    /// message-size close or an unauthorized close, and are resent on any other end while `retries` allow.
    internal func connectionDisconnected(_ conn: RpcPoolConnection, code: UInt32) {
        if closed || conn.closed {
            return
        }
        conn.closed = true
        conn.idleTimer.cancel()
        conn.endpoint.connections.removeAll { (candidate: RpcPoolConnection) -> Bool in
            return candidate === conn
        }
        let lost: [RpcPoolCall] = conn.lostCalls
        conn.lostCalls = []
        let repeatsLoss: Bool = code == disconnectCodeMessageSizeLimit || code == disconnectedCodeUnauthorized
        // A connection of an identity the client has left, refused its token, retires silently: it counts no failure and
        // holds no endpoint, so a call of the new identity opens at once (as Java does).
        let retiredSilently: Bool = code == disconnectedCodeUnauthorized && conn.generation != currentGeneration()
        if code != disconnectCodeMessageSizeLimit && !retiredSilently {
            conn.endpoint.failures += 1
            holdEndpoint(conn.endpoint)
        }
        for call: RpcPoolCall in lost {
            if repeatsLoss {
                settleAnswered(call, .failure(CentrifugeError.connectionClosed))
            } else {
                resendLost(call)
            }
        }
        drainAll()
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
        if closed || conn.closed || conn.idleTimer.isArmed || options.idleTimeout <= 0 {
            return
        }
        let due: UInt64 = conn.lastUse + clientNanos(options.idleTimeout)
        conn.idleTimer.rearm(at: due, on: main, lateGrace: false) { [weak self, weak conn] () -> Void in
            guard let owner: CentrifugeRpcPool = self, let connection: RpcPoolConnection = conn else {
                return
            }
            connection.idleTimer.forget()
            owner.idleDue(connection)
        }
    }


    /// The idle timer of a connection ran. A connection with a call in flight is left alone: the release of that call
    /// arms the timer again. A connection used since the timer was armed is armed for the rest of its span.
    private func idleDue(_ conn: RpcPoolConnection) {
        if closed || conn.closed || conn.inFlight > 0 {
            return
        }
        let now: UInt64 = main.clock.monotonicNanos()
        // A call lost with the connection waits for the connection's next event, which comes at once: the idle span
        // starts again until then.
        if !conn.lostCalls.isEmpty {
            conn.lastUse = now
            armIdle(conn)
            return
        }
        // A connection still connecting is not closed under the calls that wait for it: its idle span starts again.
        if conn.linkState != .connected && callsWait(for: conn.endpoint) {
            conn.lastUse = now
            armIdle(conn)
            return
        }
        let due: UInt64 = conn.lastUse + clientNanos(options.idleTimeout)
        if now < due {
            armIdle(conn)
            return
        }
        closeConnection(conn)
        publishStats()
    }


    /// Whether a waiting call is in the line of a key that resolves to the endpoint.
    private func callsWait(for endpoint: RpcPoolEndpoint) -> Bool {
        for key: String in Array(lines.keys) {
            guard let line: [RpcPoolCall] = lines[key], !line.isEmpty else {
                continue
            }
            guard let endpoints: [RpcPoolEndpoint] = endpointsByKey[key] else {
                continue
            }
            if endpoints.contains(where: { (candidate: RpcPoolEndpoint) -> Bool in
                return candidate === endpoint
            }) {
                return true
            }
        }
        for call: RpcPoolCall in resendWaits {
            guard let endpoints: [RpcPoolEndpoint] = endpointsByKey[call.endpointKey] else {
                continue
            }
            if endpoints.contains(where: { (candidate: RpcPoolEndpoint) -> Bool in
                return candidate === endpoint
            }) {
                return true
            }
        }
        return false
    }


    /// Closes one connection the pool chose to close (idle). It leaves its endpoint at once.
    private func closeConnection(_ conn: RpcPoolConnection) {
        conn.closed = true
        conn.idleTimer.cancel()
        conn.endpoint.connections.removeAll { (candidate: RpcPoolConnection) -> Bool in
            return candidate === conn
        }
        conn.client.disconnect()
    }


    // MARK: - Redirects

    /// Settles a call that reached a connection, after the redirect hook has seen its outcome. A hook that returns a
    /// redirect starts its fetch instead. A timeout and a cancel are the pool's own outcomes, so they settle at once.
    private func settleAnswered(_ call: RpcPoolCall, _ result: Result<CentrifugeRpcResult, Error>) {
        guard let hook: (CentrifugeReplyOutcome) -> CentrifugeRedirect? = options.redirect, !closed, !call.isSettled else {
            settle(call, result)
            return
        }
        let outcome: CentrifugeReplyOutcome
        switch result {
        case .success(let reply):
            outcome = .reply(reply)
        case .failure(let error):
            if isPoolLocal(error) {
                settle(call, result)
                return
            }
            outcome = .error(error)
        }
        guard let redirect: CentrifugeRedirect = hook(outcome) else {
            settle(call, result)
            return
        }
        startFetch(call, redirect)
    }


    /// Whether an error is one the pool settles itself: a deadline or a cancel.
    private func isPoolLocal(_ error: Error) -> Bool {
        guard let known: CentrifugeError = error as? CentrifugeError else {
            return false
        }
        switch known {
        case .timeout:
            return true
        case .replyError(let code, _, _):
            return code == rpcCodeCancelled
        default:
            return false
        }
    }


    /// Starts the fetch of a redirect for a call. The URL is checked first, with no request for a refused one. A fetch
    /// that finds no free slot waits for one in the line, which counts in `queued` under `maxQueued`.
    private func startFetch(_ call: RpcPoolCall, _ redirect: CentrifugeRedirect) {
        let maxBytes: Int = redirect.maxBytes ?? options.maxRedirectBytes
        guard let url: URL = allowedRedirectURL(redirect.url, endpoint: call.endpointURL) else {
            settle(call, .failure(CentrifugeError.replyError(code: rpcCodeRedirectFailed, message: "redirect URL is not allowed for the endpoint", temporary: false)))
            return
        }
        if maxBytes < 0 {
            settle(call, .failure(CentrifugeError.configurationError(message: "maxBytes must be an integer of at least 0")))
            return
        }
        if fetches.isFull && queuedCount() >= options.maxQueued {
            settle(call, .failure(CentrifugeError.replyError(code: rpcCodeLimitExceeded, message: "limit exceeded", temporary: false)))
            return
        }
        let fetch: RpcPoolFetch = RpcPoolFetch(
            call: call,
            url: url,
            headers: redirect.headers,
            maxBytes: maxBytes
        ) { [weak self] (result: Result<CentrifugeRpcResult, Error>) -> Void in
            self?.fetchSettled(call, result)
        }
        fetches.request(fetch)
        publishStats()
        updateWaitTimer()
    }


    /// A redirect fetch ended: the call settles with its bytes or with its failure.
    private func fetchSettled(_ call: RpcPoolCall, _ result: Result<CentrifugeRpcResult, Error>) {
        settle(call, result)
        publishStats()
        updateWaitTimer()
    }


    // MARK: - Timers, stats and close

    /// Keeps the deadline timer at the earliest moment that wakes the pool: the deadline of a waiting call, the end of
    /// a hold while a call waits, or the end of a later resend's delay. A moment already past is kept too: the timer
    /// then runs at once and moves the due calls on, so no due call is left waiting for another event.
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
        for call: RpcPoolCall in resendWaits {
            earliest = earlierNanos(earliest, call.resendAt)
        }
        for call: RpcPoolCall in fetches.calls {
            earliest = earlierNanos(earliest, call.deadline)
        }
        // The timer holds the pool strongly while a call waits, so a pool the app released still settles its waiting
        // calls at their deadlines. The timer is cancelled when nothing waits, which ends the reference.
        waitTimer.rearm(at: earliest, on: main, lateGrace: true) { () -> Void in
            self.waitTimerFired()
        }
    }


    /// The deadline timer ran: the waiting calls whose deadline passed fail with `timeout`, the later resends whose
    /// delay ended join the back of their lines, and the lines move on.
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
        var stillWaiting: [RpcPoolCall] = []
        var due: [RpcPoolCall] = []
        for call: RpcPoolCall in resendWaits {
            if call.resendAt <= now {
                due.append(call)
            } else {
                stillWaiting.append(call)
            }
        }
        resendWaits = stillWaiting
        // A resend whose delay ends at or after the deadline is not sent: its call times out.
        for call: RpcPoolCall in due {
            if call.deadline <= now {
                expired.append(call)
            } else {
                lines[call.endpointKey, default: []].append(call)
            }
        }
        expired.append(contentsOf: fetches.expire(now: now))
        for call: RpcPoolCall in expired {
            settle(call, .failure(CentrifugeError.timeout))
        }
        drainAll()
        updateWaitTimer()
    }


    /// The calls that wait for a slot in a line, and the redirect fetches that wait for a slot. A later resend
    /// that waits for its delay is not counted: `maxQueued` bounds fresh calls only (spec C 2.3), so a resend is
    /// never refused by it.
    private func queuedCount() -> Int {
        var total: Int = fetches.waitingCount
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
            queued: queuedCount(),
            redirects: fetches.runningCount
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
                // The lost calls of the connection are settled below with the rest; the connection keeps no reference.
                conn.lostCalls = []
                conn.idleTimer.cancel()
                conn.client.disconnect()
            }
            endpoint.connections = []
        }
        endpointsByURL = [:]
        endpointsByKey = [:]
        lines = [:]
        resendWaits = []
        fetches.close()
        for call: RpcPoolCall in Array(unsettled.values) {
            if call.connection == nil {
                settle(call, .failure(cancelledCallError()))
            } else {
                settle(call, .failure(CentrifugeError.connectionClosed))
            }
        }
        publishStats()
    }
}
