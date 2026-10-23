import Foundation

// One connection of the rpc pool: a plain client of an endpoint URL, with the calls it carries. The client's
// events come on the client's own queue; they are handed to the pool's queue, where the pool's state is kept.

/// A connection of the pool. It is the delegate of its client, and the pool holds it in its endpoint.
internal final class RpcPoolConnection: CentrifugeClientDelegate {
    /// Whether the connection has confirmed its connect and takes calls, or is connecting (the first connect or a
    /// reconnect of its client). A reconnecting connection takes no calls.
    internal enum LinkState {
        case connecting
        case connected
    }


    /// The endpoint the connection belongs to.
    internal let endpoint: RpcPoolEndpoint

    /// The client of the connection. The pool connects and closes it.
    internal let client: CentrifugeClient

    /// The pool that owns the connection. Weak: the pool holds its connections through their endpoints.
    internal weak var pool: CentrifugeRpcPool?

    internal var linkState: LinkState = .connecting

    /// Calls of the pool placed on this connection and not yet answered.
    internal var inFlight: Int = 0

    /// The monotonic moment the connection was opened, or its last call was answered. The idle clock runs from it.
    internal var lastUse: UInt64

    /// The idle timer of the connection, pending while one is armed. The pool arms at most one per connection.
    internal var idleTimer: ClientDeadlineTimer = ClientDeadlineTimer()

    /// Calls that the connection lost before an answer. Their outcome waits for the connection's next event: that
    /// event tells a loss that repeats (message size, unauthorized) from one that may be resent.
    internal var lostCalls: [RpcPoolCall] = []

    /// Set when the pool closes the connection or drops it. Its client's later events are then ignored.
    internal var closed: Bool = false

    /// Whether the connection is in its endpoint's list, and counted in the pool's stats totals (RpcPool.swift).
    internal var attached: Bool = false

    internal var isConnected: Bool {
        return self.linkState == .connected
    }


    /// The identity generation of the connection's token. Zero without a token source.
    internal var generation: UInt64 {
        guard let box: RpcPoolConnectionToken = self.tokenBox else {
            return 0
        }
        return box.generation
    }


    /// The token the connection presented last, empty without a token source.
    internal var presentedToken: String {
        guard let box: RpcPoolConnectionToken = self.tokenBox else {
            return ""
        }
        return box.presented
    }


    /// The token state of the connection, with a pool that takes its token from the main client (nil otherwise).
    private let tokenBox: RpcPoolConnectionToken?


    internal init(
        endpoint: RpcPoolEndpoint,
        config: CentrifugeClientConfig,
        pool: CentrifugeRpcPool,
        now: UInt64,
        tokenSource: RpcPoolTokenSource?
    ) {
        var settings: CentrifugeClientConfig = config
        var box: RpcPoolConnectionToken? = nil
        if let source: RpcPoolTokenSource = tokenSource {
            let made: RpcPoolConnectionToken = RpcPoolConnectionToken(source: source)
            settings.tokenGetter = made.getter()
            box = made
        }
        self.endpoint = endpoint
        self.tokenBox = box
        self.client = CentrifugeClient(endpoint: endpoint.url, config: settings)
        self.pool = pool
        self.lastUse = now
        self.client.delegate = self
    }


    /// The identity the server confirmed is read here, on the client's queue, and handed to the pool with the event.
    internal func onConnected(_ client: CentrifugeClient, _ event: CentrifugeConnectedEvent) {
        let user: String = client.identity.user
        let authClass: String = client.identity.authClass
        self.forward { (owner: CentrifugeRpcPool, connection: RpcPoolConnection) -> Void in
            owner.connectionConnected(connection, user: user, authClass: authClass)
        }
    }


    /// The client connects again by itself after a lost transport: the connection takes no calls until it connects.
    internal func onConnecting(_ client: CentrifugeClient, _ event: CentrifugeConnectingEvent) {
        self.forward { (owner: CentrifugeRpcPool, connection: RpcPoolConnection) -> Void in
            owner.connectionConnecting(connection)
        }
    }


    /// The client ended for good: the connection leaves its endpoint, with the code that ended it.
    internal func onDisconnected(_ client: CentrifugeClient, _ event: CentrifugeDisconnectedEvent) {
        let code: UInt32 = event.code
        self.forward { (owner: CentrifugeRpcPool, connection: RpcPoolConnection) -> Void in
            owner.connectionDisconnected(connection, code: code)
        }
    }


    /// Runs `work` on the pool's queue, with the pool and this connection. Nothing runs when the pool is gone.
    private func forward(_ work: @escaping (CentrifugeRpcPool, RpcPoolConnection) -> Void) {
        guard let owner: CentrifugeRpcPool = self.pool else {
            return
        }
        owner.queue.async { [weak self] in
            guard let connection: RpcPoolConnection = self else {
                return
            }
            work(owner, connection)
        }
    }
}
