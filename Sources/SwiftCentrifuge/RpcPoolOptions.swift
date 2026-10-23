import Foundation

// The options, the call options and the stats of the rpc pool, and the checks that refuse an option that
// cannot work. The pool itself is in RpcPool.swift.

/// The longest span a pool timer can run, in seconds: the largest millisecond count of a 32-bit timer.
internal let maxPoolTimerSeconds: TimeInterval = 2147483.647

/// The most redirect fetches a pool may run at once.
internal let maxRedirectsInflightCeiling: Int = 16


/// Options of an `CentrifugeRpcPool`. The connections of the pool are plain clients of the endpoint URLs,
/// built with these connection settings. Calls are plain requests: no instance, no message id.
public struct CentrifugeRpcPoolOptions {
    /// The endpoint URLs of an endpoint key. An empty list means the key has no endpoint: the call fails with
    /// `configurationError`, and the next call asks again. A key is resolved once, and its URLs are kept until
    /// `close`. Keys which resolve to one URL share its connections.
    public var endpoints: (String) -> [String]

    /// Headers of each connection, as `CentrifugeClientConfig.headers`.
    public var headers: [String: String]

    /// Client name of each connection, as `CentrifugeClientConfig.name`.
    public var name: String

    /// Client version of each connection, as `CentrifugeClientConfig.version`.
    public var version: String

    /// Call deadline and reply timeout of each connection, in seconds. A call's deadline is at most this long
    /// after its admission. Must be above 0.
    public var timeout: TimeInterval

    /// Minimum delay before a connection ended for good is opened again, in seconds (the hold of an endpoint).
    public var minReconnectDelay: TimeInterval

    /// Maximum of that hold, in seconds.
    public var maxReconnectDelay: TimeInterval

    /// Maximum allowed time between pings from the server of each connection, in seconds.
    public var maxServerPingDelay: TimeInterval

    /// Name of the header that carries a call's `affinity`. Nil means calls have no affinity.
    public var affinityHeader: String?

    /// Connections opened per endpoint URL at most. Default 2.
    public var maxConnectionsPerEndpoint: Int

    /// Calls in flight per connection at most. Default 1.
    public var maxInflightPerConnection: Int

    /// Fresh calls waiting for a connection at most, over all keys. Beyond it a call fails with
    /// `replyError(code: 16)`, unless it can open a connection. Default 64; 0 is valid.
    public var maxQueued: Int

    /// Seconds a connection without calls stays open. 0 keeps it open until `close`. Default 60.
    public var idleTimeout: TimeInterval

    /// Resends of one call at most, counted over all causes together: a call lost with its connection, a server
    /// refusal with the later signal, and a move by `reroute`. Default 3; 0 is valid and sends no resend.
    public var retries: Int

    /// Maps a server error reply to an endpoint key. A reply that maps to a key moves the call to that key, at the
    /// front of its line, while `retries` and the call's deadline allow. Nil, or a nil result, means no move. The
    /// hook runs on server error replies only, and only when a resend is possible (a resend left and the deadline
    /// still ahead). It never runs on a lost call or a timeout.
    public var reroute: ((CentrifugeReplyError) -> String?)?

    /// Maps the outcome of a call that reached a connection to the bytes the pool fetches, or nil for no redirect. The
    /// hook sees a reply, a server error and a connection loss. It does not see a timeout, a cancel or a close.
    public var redirect: ((CentrifugeReplyOutcome) -> CentrifugeRedirect?)?

    /// Redirect fetches in flight at most, over the pool, from 1 to 16. A fetch that finds no free slot waits for one in
    /// arrival order, and counts in `queued`. Default 4.
    public var maxRedirectsInflight: Int

    /// Body bytes a redirect fetch accepts at most, unless its redirect gives its own. Default 16 MiB.
    public var maxRedirectBytes: Int

    /// The session whose transport settings (proxy, TLS, timeouts) the redirect fetches keep. The pool uses its own
    /// delegate, and never the headers, cookies, stored credentials or cache of the session. Nil means an ephemeral
    /// session.
    public var urlSession: URLSession?

    /// Whether the connections take their token from the main client: the client's confirmed token is lent to each
    /// connection, and a connection refused its token asks the client to renew it once. Exclusive with `token` and
    /// `tokenGetter`. Default false.
    public var tokenFrom: Bool

    /// The token of each connection, for a pool without `tokenFrom`. Empty means no token. Exclusive with `tokenFrom`.
    public var token: String

    /// The token getter of each connection, for a pool without `tokenFrom`. Exclusive with `tokenFrom`.
    public var tokenGetter: CentrifugeConnectionTokenGetter?

    /// With `tokenFrom`, closes the idle connections of a session the main client ended, as the client ends it, instead of
    /// at the idle timeout. Default true.
    public var closeEndedSession: Bool


    public init(
        endpoints: @escaping (String) -> [String],
        headers: [String: String] = [:],
        name: String = "swift",
        version: String = "",
        timeout: TimeInterval = 5.0,
        minReconnectDelay: TimeInterval = 0.5,
        maxReconnectDelay: TimeInterval = 20.0,
        maxServerPingDelay: TimeInterval = 10.0,
        affinityHeader: String? = nil,
        maxConnectionsPerEndpoint: Int = 2,
        maxInflightPerConnection: Int = 1,
        maxQueued: Int = 64,
        idleTimeout: TimeInterval = 60.0,
        retries: Int = 3,
        reroute: ((CentrifugeReplyError) -> String?)? = nil,
        redirect: ((CentrifugeReplyOutcome) -> CentrifugeRedirect?)? = nil,
        maxRedirectsInflight: Int = 4,
        maxRedirectBytes: Int = 16 * 1024 * 1024,
        urlSession: URLSession? = nil,
        tokenFrom: Bool = false,
        token: String = "",
        tokenGetter: CentrifugeConnectionTokenGetter? = nil,
        closeEndedSession: Bool = true
    ) {
        self.endpoints = endpoints
        self.headers = headers
        self.name = name
        self.version = version
        self.timeout = timeout
        self.minReconnectDelay = minReconnectDelay
        self.maxReconnectDelay = maxReconnectDelay
        self.maxServerPingDelay = maxServerPingDelay
        self.affinityHeader = affinityHeader
        self.maxConnectionsPerEndpoint = maxConnectionsPerEndpoint
        self.maxInflightPerConnection = maxInflightPerConnection
        self.maxQueued = maxQueued
        self.idleTimeout = idleTimeout
        self.retries = retries
        self.reroute = reroute
        self.redirect = redirect
        self.maxRedirectsInflight = maxRedirectsInflight
        self.maxRedirectBytes = maxRedirectBytes
        self.urlSession = urlSession
        self.tokenFrom = tokenFrom
        self.token = token
        self.tokenGetter = tokenGetter
        self.closeEndedSession = closeEndedSession
    }
}


/// Options of one pool call.
public struct CentrifugeRpcPoolCallOptions {
    /// Headers sent with the call. A header named as the pool's `affinityHeader` is refused.
    public var headers: [String: String]

    /// Deadline of the call in seconds. Nil means the pool's `timeout`. An explicit value must be above 0 and
    /// no more than the pool's `timeout`, otherwise the call fails with `configurationError`.
    public var timeout: TimeInterval?

    /// Affinity hint, sent in the pool's `affinityHeader`. Needs that option.
    public var affinity: String?


    public init(
        headers: [String: String] = [:],
        timeout: TimeInterval? = nil,
        affinity: String? = nil
    ) {
        self.headers = headers
        self.timeout = timeout
        self.affinity = affinity
    }
}


/// The state of a pool, for the application's own pacing. A snapshot: it may lag a call that is in progress.
public struct CentrifugeRpcPoolStats: Equatable {
    /// Connections open or connecting.
    public let connections: Int

    /// Calls holding a slot of a connection.
    public let inflight: Int

    /// Calls waiting for a connection, and redirect fetches waiting for a slot.
    public let queued: Int

    /// Redirect fetches holding a slot.
    public let redirects: Int


    public init(
        connections: Int,
        inflight: Int,
        queued: Int,
        redirects: Int = 0
    ) {
        self.connections = connections
        self.inflight = inflight
        self.queued = queued
        self.redirects = redirects
    }
}


/// The configuration error of a pool's options, or nil when they can work.
internal func poolConfigurationError(_ options: CentrifugeRpcPoolOptions) -> CentrifugeError? {
    if let name: String = options.affinityHeader, name.isEmpty {
        return CentrifugeError.configurationError(message: "affinityHeader must be a header name")
    }
    if options.maxConnectionsPerEndpoint < 1 {
        return CentrifugeError.configurationError(message: "maxConnectionsPerEndpoint must be at least 1")
    }
    if options.maxInflightPerConnection < 1 {
        return CentrifugeError.configurationError(message: "maxInflightPerConnection must be at least 1")
    }
    if options.maxQueued < 0 {
        return CentrifugeError.configurationError(message: "maxQueued must be at least 0")
    }
    if options.retries < 0 {
        return CentrifugeError.configurationError(message: "retries must be at least 0")
    }
    if !isPoolTimerSpan(options.idleTimeout, allowZero: true) {
        return CentrifugeError.configurationError(message: "idleTimeout must be 0 or a span of at most 2147483.647 seconds")
    }
    if !isValidRpcTimeout(options.timeout, limit: maxPoolTimerSeconds) {
        return CentrifugeError.configurationError(message: "timeout must be a positive span of at most 2147483.647 seconds")
    }
    if !isPoolTimerSpan(options.minReconnectDelay, allowZero: true) || !isPoolTimerSpan(options.maxReconnectDelay, allowZero: true) {
        return CentrifugeError.configurationError(message: "reconnect delays must be spans of at most 2147483.647 seconds")
    }
    if options.maxRedirectsInflight < 1 || options.maxRedirectsInflight > maxRedirectsInflightCeiling {
        return CentrifugeError.configurationError(message: "maxRedirectsInflight must be from 1 to 16")
    }
    if options.maxRedirectBytes < 0 {
        return CentrifugeError.configurationError(message: "maxRedirectBytes must be at least 0")
    }
    if options.tokenFrom && (!options.token.isEmpty || options.tokenGetter != nil) {
        return CentrifugeError.configurationError(message: "tokenFrom is exclusive with token and tokenGetter")
    }
    return nil
}


/// The configuration error of one call's options, or nil when they can be used. Checked at admission, after the
/// pool's own states (closed, ended, disconnected) have been checked.
internal func poolCallConfigurationError(
    _ options: CentrifugeRpcPoolCallOptions,
    affinityHeader: String?,
    poolTimeout: TimeInterval
) -> CentrifugeError? {
    if options.affinity != nil && affinityHeader == nil {
        return CentrifugeError.configurationError(message: "affinity needs the affinityHeader option")
    }
    if let name: String = affinityHeader, options.headers[name] != nil {
        return CentrifugeError.configurationError(message: "the affinity header is set by the affinity option, not by headers")
    }
    let timeout: TimeInterval = options.timeout ?? poolTimeout
    if !isValidRpcTimeout(timeout, limit: poolTimeout) {
        return CentrifugeError.configurationError(message: "timeout must be a positive number of seconds, at most the pool timeout")
    }
    return nil
}


/// Whether a call timeout in seconds can be used: finite, above zero, and no more than `limit`. The one rule of the
/// pool's options, of a call's options and of a tracked call's options.
internal func isValidRpcTimeout(_ seconds: TimeInterval, limit: TimeInterval) -> Bool {
    return seconds.isFinite && seconds > 0 && seconds <= limit
}


/// Whether a span in seconds fits a pool timer: finite, not negative, at most `maxPoolTimerSeconds`, and above zero
/// unless `allowZero`.
private func isPoolTimerSpan(_ seconds: TimeInterval, allowZero: Bool) -> Bool {
    if !seconds.isFinite || seconds < 0 {
        return false
    }
    if seconds == 0 {
        return allowZero
    }
    return seconds <= maxPoolTimerSeconds
}
