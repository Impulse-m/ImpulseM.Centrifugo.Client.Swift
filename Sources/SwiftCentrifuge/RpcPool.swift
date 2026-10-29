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

    /// The settings of each connection: the pool's options, and the transport of the main client (see `init`).
    internal let connectionConfig: CentrifugeClientConfig

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

    /// The waiting calls of each key, in admission order. An entry whose call no longer waits in the line is stale: it
    /// stays until it reaches the front, or until the stale entries outnumber the live ones (compactLines).
    private var lines: [String: [RpcPoolCall]] = [:]

    /// The calls that wait in a line, live. Counted toward `maxQueued` with the fetches that wait (queuedCount).
    private var lineCount: Int = 0

    /// The keys with calls in a line, and how many calls each has there. A key is in its endpoints' `lineKeys` while it counts.
    private var keyLineCounts: [String: Int] = [:]

    /// The stale entries of the lines: calls settled while they waited, still in an array.
    private var staleLineEntries: Int = 0

    /// The calls that wait for the timer: in a line, in a redirect fetch, or in a later resend's delay.
    private var timedWaits: Int = 0

    /// The attached connections of the endpoints, and the calls in flight on them. The stats snapshot reads them, so they
    /// are kept as the connections attach and detach and the slots are taken and released, and the snapshot costs no scan.
    private var connectionCount: Int = 0

    private var inflightCount: Int = 0

    /// Every call that is not settled yet, so that `close` settles them all.
    private var unsettled: [ObjectIdentifier: RpcPoolCall] = [:]

    /// The one timer of the waiting calls' deadlines, the ends of the holds and the ends of the later resend delays.
    private var waitTimer: ClientDeadlineTimer = ClientDeadlineTimer()

    /// The due moments of the waiting calls: the deadlines of the calls in a line or a redirect fetch, and the resend times
    /// of the calls in the resend waits. The timer takes the due ones (waitTimerFired), so no event or fire scans them.
    private var callDues: RpcMinHeap<RpcPoolDue> = RpcMinHeap()

    /// The ends of the endpoint holds. The timer takes the earliest that still holds (earliestHold).
    private var holdDues: RpcMinHeap<RpcPoolDue> = RpcMinHeap()

    private var closed: Bool = false


    /// Creates a pool. Options that cannot work are not refused here: the pool then fails every call with the
    /// `configurationError`. `create` refuses them.
    public init(main: CentrifugeClient, options: CentrifugeRpcPoolOptions) {
        self.main = main
        self.queue = main.syncQueue
        self.options = options
        let mainConfig: CentrifugeClientConfig = main.config
        self.fetches = RpcPoolFetches(
            queue: main.syncQueue,
            limit: options.maxRedirectsInflight,
            source: redirectSource(
                urlSession: options.urlSession,
                mainProvider: mainConfig.urlSessionConfigurationProvider
            ),
            proxyCredentialsProvider: mainConfig.proxyCredentialsProvider
        )
        self.configError = poolConfigurationError(options)
            ?? poolTransportError(useNativeWebSocket: mainConfig.useNativeWebSocket, nativeAvailable: nativeWebSocketIsAvailable)
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
        // The transport of the main client, so that the pool's connections use its proxy, TLS and credentials. The
        // providers are closures: each connection asks them itself, when it makes its session and at each challenge.
        settings.useNativeWebSocket = mainConfig.useNativeWebSocket
        settings.urlSessionConfigurationProvider = mainConfig.urlSessionConfigurationProvider
        settings.proxyCredentialsProvider = mainConfig.proxyCredentialsProvider
        settings.tlsSkipVerify = mainConfig.tlsSkipVerify
        settings.tlsChallengeHandler = mainConfig.tlsChallengeHandler
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
        if let error: CentrifugeError = poolTransportError(
            useNativeWebSocket: main.config.useNativeWebSocket,
            nativeAvailable: nativeWebSocketIsAvailable
        ) {
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


    /// The entries of the wait timer's due moments, standing or not. The tests read it on the pool's queue to bound them.
    internal var dueEntryCount: Int {
        return callDues.count
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
        // The line counts its live calls only: a settled call that still has an entry in the line does not block a placement.
        let lineIsEmpty: Bool = (keyLineCounts[call.endpointKey] ?? 0) == 0
        if lineIsEmpty, let conn: RpcPoolConnection = liveConnection(endpoints) {
            place(call, on: conn)
            publishStats()
            return
        }
        // A call that may open a connection is admitted at any bound: the connection it opens serves it.
        if opener(endpoints) == nil && queuedCount() >= options.maxQueued {
            settle(call, .failure(CentrifugeError.replyError(code: rpcCodeLimitExceeded, message: "limit exceeded", temporary: false)))
            return
        }
        joinLine(call, atFront: false)
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
            if head.wait != .line {
                // A call settled while it waited: its entry is dropped here, as the stale entry it became.
                removeHead(key)
                staleLineEntries -= 1
                continue
            }
            let now: UInt64 = main.clock.monotonicNanos()
            if head.deadline <= now {
                removeHead(key)
                setWait(head, .idle)
                settle(head, .failure(CentrifugeError.timeout))
                continue
            }
            if let failure: CentrifugeError = waitingFailure(head, endpoints) {
                removeHead(key)
                setWait(head, .idle)
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


    /// Drains every key line. Used by the events that may change any endpoint: the main client's state or identity.
    /// A connection event drains only the keys of its endpoint (drainEndpoint).
    private func drainAll() {
        for key: String in Array(lines.keys) {
            drain(key)
        }
    }


    /// Drains the keys with waiting calls that resolve to an endpoint. Only a state of that endpoint's connections or
    /// holds can change their outcome, so the other keys are left as they are.
    private func drainEndpoint(_ endpoint: RpcPoolEndpoint) {
        for key: String in Array(endpoint.lineKeys) {
            drain(key)
        }
    }


    /// Drops the front entry of a key's line. The caller then sets the call's wait, which takes it out of the counts.
    private func removeHead(_ key: String) {
        lines[key]?.removeFirst()
    }


    /// Sends a call on a connection. The call holds the connection's slot until the connection answers it.
    private func place(_ call: RpcPoolCall, on conn: RpcPoolConnection) {
        setWait(call, .idle)
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
        if conn.attached {
            inflightCount += 1
        }
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
        let endpoint: RpcPoolEndpoint? = call.connection?.endpoint
        releaseSlot(call)
        switch result {
        case .success:
            settleAnswered(call, result)
        case .failure(let error):
            answerFailed(call, error)
        }
        // The freed slot drains the keys of its endpoint. A call that moved or resent joins the line of its new key.
        if let freed: RpcPoolEndpoint = endpoint {
            drainEndpoint(freed)
        }
        drain(call.endpointKey)
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
        joinLine(call, atFront: true)
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
        joinLine(call, atFront: false)
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
        setWait(call, .resendWait)
        updateWaitTimer()
    }


    /// Releases the slot a call holds on its connection. The connection's idle clock starts again when it has no call.
    private func releaseSlot(_ call: RpcPoolCall) {
        guard call.holdsSlot, let conn: RpcPoolConnection = call.connection else {
            return
        }
        call.holdsSlot = false
        conn.inFlight -= 1
        if conn.attached {
            inflightCount -= 1
        }
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
        if call.wait == .line {
            // Its entry stays in the line until the front reaches it, so the line's stale count goes up.
            staleLineEntries += 1
        }
        setWait(call, .idle)
        call.isSettled = true
        unsettled[ObjectIdentifier(call)] = nil
        compactLinesIfNeeded()
        publishStats()
        call.completion(result)
    }


    /// Cancels a call. A waiting call leaves its line and fails at once. A call in flight fails at once too, and its
    /// connection call is cancelled, so the connection answers it now and releases the slot without a second completion.
    private func cancel(_ call: RpcPoolCall) {
        if call.wait == .line || call.wait == .resendWait {
            // The call leaves its line or its resend wait lazily: its entry is dropped when it reaches the front.
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
        attachConnection(conn)
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
            drainEndpoint(conn.endpoint)
            publishStats()
            return
        }
        if let source: RpcPoolTokenSource = tokenSource, !source.confirmsIdentity(user: user, authClass: authClass) {
            // The server confirmed another identity than the one of the generation: the token is unusable, and the
            // connection retires. The source's notice then places the waiting calls again.
            closeConnection(conn)
            source.markUnusable(conn.presentedToken)
            drainEndpoint(conn.endpoint)
            publishStats()
            return
        }
        conn.linkState = .connected
        conn.endpoint.failures = 0
        drainEndpoint(conn.endpoint)
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
        drainEndpoint(conn.endpoint)
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
        detachConnection(conn)
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
        drainEndpoint(conn.endpoint)
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
        let until: UInt64 = main.clock.monotonicNanos() + delay
        endpoint.holdUntil = until
        holdDues.push(RpcPoolDue(nanos: until, call: nil, endpoint: endpoint))
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
        if conn.linkState != .connected && conn.endpoint.queuedWaits > 0 {
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


    /// Closes one connection the pool chose to close (idle). It leaves its endpoint at once.
    private func closeConnection(_ conn: RpcPoolConnection) {
        conn.closed = true
        conn.idleTimer.cancel()
        detachConnection(conn)
        conn.client.disconnect()
    }


    /// Adds a connection to its endpoint, and counts it in the stats totals.
    private func attachConnection(_ conn: RpcPoolConnection) {
        conn.endpoint.connections.append(conn)
        conn.attached = true
        connectionCount += 1
        inflightCount += conn.inFlight
    }


    /// Removes a connection from its endpoint, and takes it and its calls in flight out of the stats totals. A connection
    /// that is not attached is left as it is, so a second removal changes no count.
    private func detachConnection(_ conn: RpcPoolConnection) {
        guard conn.attached else {
            return
        }
        conn.attached = false
        conn.endpoint.connections.removeAll { (candidate: RpcPoolConnection) -> Bool in
            return candidate === conn
        }
        connectionCount -= 1
        inflightCount -= conn.inFlight
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
        setWait(call, .fetch)
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
    /// then runs at once and moves the due calls on, so no due call is left waiting for another event. The earliest
    /// moment is read from the heaps, so an event costs no scan of the calls, the lines, the holds or the fetches.
    private func updateWaitTimer() {
        let now: UInt64 = main.clock.monotonicNanos()
        var earliest: UInt64? = earliestCallDue()
        // The holds are pruned on every call, and they wake the timer only while a call waits in a line.
        let hold: UInt64? = earliestHold(now: now)
        if lineCount > 0, let until: UInt64 = hold {
            earliest = earlierNanos(earliest, until)
        }
        // The timer holds the pool strongly while a call waits, so a pool the app released still settles its waiting
        // calls at their deadlines. The timer is cancelled when nothing waits, which ends the reference.
        waitTimer.rearm(at: earliest, on: main, lateGrace: true) { () -> Void in
            self.waitTimerFired()
        }
    }


    /// Adds a call to the line of its key, at the back or at the front, and puts its deadline on the timer.
    private func joinLine(_ call: RpcPoolCall, atFront: Bool) {
        setWait(call, .line)
        if atFront {
            lines[call.endpointKey, default: []].insert(call, at: 0)
        } else {
            lines[call.endpointKey, default: []].append(call)
        }
    }


    /// Sets where a call waits, and puts the moment that the wait is due at on the timer: the deadline in a line or a
    /// redirect fetch, the resend time in the resend waits, and nothing otherwise. The counts of the old wait are
    /// taken out and those of the new one are added, so every count stays the number of calls in that wait.
    private func setWait(_ call: RpcPoolCall, _ wait: RpcPoolWait) {
        countOut(call)
        call.wait = wait
        countIn(call)
        switch wait {
        case .line, .fetch:
            callDues.push(RpcPoolDue(nanos: call.deadline, call: call, endpoint: nil))
        case .resendWait:
            callDues.push(RpcPoolDue(nanos: call.resendAt, call: call, endpoint: nil))
        case .idle:
            return
        }
        compactCallDuesIfNeeded()
    }


    /// Takes a call out of the counts of the wait it is in. A call in a line keeps its entry in the line's array: the
    /// caller that removes the entry at the front, or the compaction, drops it.
    private func countOut(_ call: RpcPoolCall) {
        switch call.wait {
        case .idle:
            return
        case .line:
            lineCount -= 1
            timedWaits -= 1
            adjustEndpoints(call.endpointKey, by: -1)
            dropKeyLine(call.endpointKey)
        case .resendWait:
            timedWaits -= 1
            adjustEndpoints(call.endpointKey, by: -1)
        case .fetch:
            timedWaits -= 1
        }
    }


    /// Adds a call to the counts of the wait it is in.
    private func countIn(_ call: RpcPoolCall) {
        switch call.wait {
        case .idle:
            return
        case .line:
            lineCount += 1
            timedWaits += 1
            adjustEndpoints(call.endpointKey, by: 1)
            addKeyLine(call.endpointKey)
        case .resendWait:
            timedWaits += 1
            adjustEndpoints(call.endpointKey, by: 1)
        case .fetch:
            timedWaits += 1
        }
    }


    /// Adds `delta` to the queued waits of the endpoints that a key resolves to.
    private func adjustEndpoints(_ key: String, by delta: Int) {
        guard let endpoints: [RpcPoolEndpoint] = endpointsByKey[key] else {
            return
        }
        for endpoint: RpcPoolEndpoint in endpoints {
            endpoint.queuedWaits += delta
        }
    }


    /// Counts one more call in the line of a key. The first one puts the key on its endpoints.
    private func addKeyLine(_ key: String) {
        let count: Int = (keyLineCounts[key] ?? 0) + 1
        keyLineCounts[key] = count
        if count == 1, let endpoints: [RpcPoolEndpoint] = endpointsByKey[key] {
            for endpoint: RpcPoolEndpoint in endpoints {
                endpoint.lineKeys.insert(key)
            }
        }
    }


    /// Counts one call less in the line of a key. The last one takes the key off its endpoints.
    private func dropKeyLine(_ key: String) {
        let count: Int = (keyLineCounts[key] ?? 1) - 1
        if count > 0 {
            keyLineCounts[key] = count
            return
        }
        keyLineCounts[key] = nil
        if let endpoints: [RpcPoolEndpoint] = endpointsByKey[key] {
            for endpoint: RpcPoolEndpoint in endpoints {
                endpoint.lineKeys.remove(key)
            }
        }
    }


    /// Drops the stale entries of the lines once they outnumber the live calls twofold. The cost is linear in the
    /// entries, and it runs after at least as many settlements as entries it drops, so it is amortised O(1) per settlement.
    private func compactLinesIfNeeded() {
        if closed || staleLineEntries <= 2 * lineCount {
            return
        }
        var kept: [String: [RpcPoolCall]] = [:]
        for entry: (key: String, value: [RpcPoolCall]) in lines {
            let live: [RpcPoolCall] = entry.value.filter { (candidate: RpcPoolCall) -> Bool in
                return candidate.wait == .line
            }
            if !live.isEmpty {
                kept[entry.key] = live
            }
        }
        lines = kept
        staleLineEntries = 0
    }


    /// Drops the entries of the due moments that no longer stand once they outnumber the timed waits twofold, so the
    /// heap holds about one entry per waiting call. A call that returns to a line or a fetch with the same deadline
    /// leaves its earlier entry standing, so only the first entry of each call and moment is kept. The kept entries
    /// are at most the timed waits, so the cost is linear in the heap, and amortised O(1) per entry added.
    private func compactCallDuesIfNeeded() {
        if closed || callDues.count <= 2 * timedWaits {
            return
        }
        var kept: Set<RpcPoolDueKey> = []
        callDues.keep { (due: RpcPoolDue) -> Bool in
            guard let call: RpcPoolCall = due.call, self.isStandingCallDue(due) else {
                return false
            }
            return kept.insert(RpcPoolDueKey(call: ObjectIdentifier(call), nanos: due.nanos)).inserted
        }
    }


    /// The earliest moment of the calls that stands, or nil when none does. The entries that do not stand are dropped
    /// from the front: the front of a heap is its earliest entry, so the first one that stands is the answer.
    private func earliestCallDue() -> UInt64? {
        while let due: RpcPoolDue = callDues.earliest, !isStandingCallDue(due) {
            callDues.pop()
        }
        return callDues.earliest?.nanos
    }


    /// The earliest end of a hold, or nil when none is. A superseded entry is dropped from the front on every call. An
    /// ended hold is dropped too while no call waits; while one waits, it stays at the front, so the timer runs at once
    /// and waitTimerFired drains the keys of its endpoint.
    private func earliestHold(now: UInt64) -> UInt64? {
        while let due: RpcPoolDue = holdDues.earliest {
            if !isCurrentHold(due) {
                holdDues.pop()
            } else if lineCount == 0 && due.nanos <= now {
                holdDues.pop()
            } else {
                break
            }
        }
        return holdDues.earliest?.nanos
    }


    /// Whether the entry of a call stands: the call is unsettled, and it waits in the state that set the entry.
    private func isStandingCallDue(_ due: RpcPoolDue) -> Bool {
        guard let call: RpcPoolCall = due.call, !call.isSettled else {
            return false
        }
        switch call.wait {
        case .line, .fetch:
            return due.nanos == call.deadline
        case .resendWait:
            return due.nanos == call.resendAt
        case .idle:
            return false
        }
    }


    /// Whether the entry of a hold is the current one: its endpoint still holds until that moment. An entry of an earlier
    /// hold of the endpoint is superseded.
    private func isCurrentHold(_ due: RpcPoolDue) -> Bool {
        guard let endpoint: RpcPoolEndpoint = due.endpoint, let until: UInt64 = endpoint.holdUntil else {
            return false
        }
        return until == due.nanos
    }


    /// The deadline timer ran: the waiting calls whose deadline passed fail with `timeout`, the later resends whose
    /// delay ended join the back of their lines, and the lines move on.
    private func waitTimerFired() {
        waitTimer.forget()
        if closed {
            return
        }
        let now: UInt64 = main.clock.monotonicNanos()
        // The due moments of the calls, earliest first. Only the entries that are due are taken from the heap.
        var expired: [RpcPoolCall] = []
        var resumed: [RpcPoolCall] = []
        while let due: RpcPoolDue = callDues.earliest, due.nanos <= now {
            callDues.pop()
            guard let call: RpcPoolCall = due.call, isStandingCallDue(due) else {
                continue
            }
            // A resend whose delay ends at or after the deadline is not sent: its call times out.
            if call.wait == .resendWait && call.deadline > now {
                resumed.append(call)
            } else {
                expired.append(call)
            }
        }
        // The holds that ended: their keys are drained below, so a call that waits on the endpoint opens its connection.
        var endedEndpoints: [RpcPoolEndpoint] = []
        while let hold: RpcPoolDue = holdDues.earliest, hold.nanos <= now {
            holdDues.pop()
            if isCurrentHold(hold), let endpoint: RpcPoolEndpoint = hold.endpoint {
                endedEndpoints.append(endpoint)
            }
        }
        var keys: [String] = []
        for call: RpcPoolCall in resumed where call.wait == .resendWait {
            joinLine(call, atFront: false)
            keys.append(call.endpointKey)
        }
        for call: RpcPoolCall in expired {
            keys.append(call.endpointKey)
            if call.wait == .fetch {
                _ = fetches.cancel(call)
            }
            settle(call, .failure(CentrifugeError.timeout))
        }
        for endpoint: RpcPoolEndpoint in endedEndpoints {
            keys.append(contentsOf: endpoint.lineKeys)
        }
        for key: String in keys {
            drain(key)
        }
        updateWaitTimer()
    }


    /// The calls that wait for a slot in a line, and the redirect fetches that wait for a slot. A later resend
    /// that waits for its delay is not counted: `maxQueued` bounds fresh calls only (spec C 2.3), so a resend is
    /// never refused by it. Both counts are kept as calls join and leave, so the sum is O(1).
    private func queuedCount() -> Int {
        return fetches.waitingCount + lineCount
    }


    /// Writes the stats snapshot. Called on the queue after each change of the pool's state. The totals are kept as the
    /// state changes, so the snapshot costs no scan of the endpoints or the connections.
    private func publishStats() {
        let snapshot: CentrifugeRpcPoolStats = CentrifugeRpcPoolStats(
            connections: connectionCount,
            inflight: inflightCount,
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
                conn.attached = false
                // The lost calls of the connection are settled below with the rest; the connection keeps no reference.
                conn.lostCalls = []
                conn.idleTimer.cancel()
                conn.client.disconnect()
            }
            endpoint.connections = []
        }
        connectionCount = 0
        inflightCount = 0
        fetches.close()
        // The calls settle while the keys and the counts are kept, so each one leaves its wait as it settles.
        for call: RpcPoolCall in Array(unsettled.values) {
            if call.connection == nil {
                settle(call, .failure(cancelledCallError()))
            } else {
                settle(call, .failure(CentrifugeError.connectionClosed))
            }
        }
        endpointsByURL = [:]
        endpointsByKey = [:]
        lines = [:]
        keyLineCounts = [:]
        lineCount = 0
        staleLineEntries = 0
        timedWaits = 0
        callDues = RpcMinHeap()
        holdDues = RpcMinHeap()
        publishStats()
    }
}
