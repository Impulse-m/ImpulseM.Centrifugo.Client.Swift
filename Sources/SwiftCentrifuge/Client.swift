//
//  Client.swift
//  SwiftCentrifuge
//
//  Created by Alexander Emelin on 03/01/2019.
//  Copyright © 2019 Alexander Emelin. All rights reserved.
//

import Foundation
import SwiftProtobuf

public enum CentrifugeError: Error {
    case unauthorized
    case timeout
    case duplicateSub
    case clientDisconnected
    case subscriptionUnsubscribed
    case transportError(error: Error)
    case tokenError(error: Error)
    case connectError(error: Error)
    case refreshError(error: Error)
    case subscriptionSubscribeError(error: Error)
    case subscriptionTokenError(error: Error)
    case subscriptionGetStateError(error: Error)
    case subscriptionRefreshError(error: Error)
    case replyError(code: UInt32, message: String, temporary: Bool)
    /// A server error reply to an rpc call that carries an application code, type or metadata (see
    /// `CentrifugeReplyError`). Other server replies (connect, subscribe, refresh) stay `replyError`.
    case replyErrorDetails(CentrifugeReplyError)
    /// The connection was lost while the call was on it, and the call cannot be resent on the next one.
    case connectionClosed
    /// Code 10. A call settles with it when its transmit throws, which is an encode failure of its request.
    /// No protobuf request of the client fails to encode today, and the transport gives no write error signal,
    /// so in practice no call gets it. It stays for the shape of the API.
    case transportWriteError(error: Error)
    /// The client refused the call itself, with a text that is not a server reply. Reserved for the
    /// rpc pool, and never a server reply code.
    case clientRejected(code: UInt32, message: String)
    case configurationError(message: String)
}

/// Retrieves a connection token dynamically, called whenever the client needs one (initial
/// connect, or a refresh). Call the completion handler exactly once, with `.success(token)` or
/// `.failure(error)` — a failure is handled properly (see `CentrifugeError.tokenError`;
/// `CentrifugeError.unauthorized` specifically ends the connection attempt rather than
/// retrying).
/// - Warning: Call the completion handler exactly once, on every code path. There is no
/// timeout: if it's never called, the connection attempt hangs indefinitely, with no error,
/// no disconnect event, and no other diagnostic. If your token-fetching logic depends on
/// something that might stall (a slow network call, etc.), guard it with your own timeout
/// and call `completion(.failure(...))` on expiry.
public typealias CentrifugeConnectionTokenGetter = (_ event: CentrifugeConnectionTokenEvent, _ completion: @escaping (Result<String, Error>) -> Void) -> Void


/// Configuration structure for Centrifuge client.
public struct CentrifugeClientConfig {

    /// Initializes the configuration with the provided parameters.
    /// - Parameters:
    ///   - timeout: Timeout for server responses and for opening the connection (the WebSocket handshake), in seconds
    ///   - headers: Custom headers to include in requests
    ///   - tlsSkipVerify: Flag to skip TLS certificate verification
    ///   - minReconnectDelay: Minimum delay before attempting reconnection, in seconds
    ///   - maxReconnectDelay: Maximum delay between reconnection attempts, in seconds
    ///   - maxServerPingDelay: Maximum allowed time between pings from the server, in seconds
    ///   - name: Custom client name for identification
    ///   - version: Client version for tracking
    ///   - token: Authentication token for connecting to the server
    ///   - data: Custom binary data associated with the client
    ///   - debug: Enables detailed logging for debugging purposes
    ///   - useNativeWebSocket: Enables the use of native `URLSessionWebSocketTask` for WebSocket connections instead of Starscream v3. 
    ///   If you need custom configuration for URLSessionWebSocketTask then use urlSessionConfigurationProvider option to configure desired behaviour.
    ///   - urlSessionConfigurationProvider: Optional allows setting custom options for `URLSessionWebSocketTask` used by the native WebSocket,
    ///   - tokenGetter: Callback for retrieving authentication tokens dynamically
    ///   - logger: Logger instance for debugging and diagnostics
    ///   - tlsChallengeHandler: Optional handler receiving every challenge the native WebSocket transport's `URLSession` gets at the session level (server-trust, client-certificate/mTLS, and also NTLM/Negotiate for an authenticating proxy), e.g. to trust a private CA, pin a certificate, or present a client identity. Takes precedence over `tlsSkipVerify` when both are set
    ///   - proxyCredentialsProvider: Optional provider of the Basic credentials for an HTTP proxy that asks for them. Applies only to the native transport. Called at each proxy challenge, so it returns the current credentials. Nil fails the connection attempt
    ///   - instance: Optional id of this client, 22 to 64 characters of A-Z, a-z, 0-9, `_` or `-`. Sent in the connect request and never logged. See `CentrifugeClient.create`
    public init(
        timeout: Double = 5.0,
        headers: [String : String] = .init(),
        tlsSkipVerify: Bool = false,
        minReconnectDelay: Double = 0.5,
        maxReconnectDelay: Double = 20.0,
        maxServerPingDelay: Double = 10.0,
        name: String = "swift",
        version: String = "",
        token: String = "",
        data: Data? = nil,
        debug: Bool = false,
        useNativeWebSocket: Bool = false,
        urlSessionConfigurationProvider: URLSessionConfigurationProvider? = nil,
        tokenGetter: CentrifugeConnectionTokenGetter? = nil,
        logger: CentrifugeLogger? = nil,
        tlsChallengeHandler: CentrifugeTLSChallengeHandler? = nil,
        proxyCredentialsProvider: CentrifugeProxyCredentialsProvider? = nil,
        instance: String? = nil,
        maxPendingRpc: Int = 32,
        stopOnRefusedToken: Bool = true,
        tokenRetryCap: TimeInterval = 300,
        tokenExchange: CentrifugeTokenExchange? = nil
    ) {
        self.timeout = timeout
        self.headers = headers
        self.tlsSkipVerify = tlsSkipVerify
        self.minReconnectDelay = minReconnectDelay
        self.maxReconnectDelay = maxReconnectDelay
        self.maxServerPingDelay = maxServerPingDelay
        self.name = name
        self.version = version
        self.token = token
        self.data = data
        self.debug = debug
        self.useNativeWebSocket = useNativeWebSocket
        self.urlSessionConfigurationProvider = urlSessionConfigurationProvider

        self.tokenGetter = tokenGetter
        self.logger = logger
        self.tlsChallengeHandler = tlsChallengeHandler
        self.proxyCredentialsProvider = proxyCredentialsProvider
        self.instance = instance
        self.maxPendingRpc = maxPendingRpc
        self.stopOnRefusedToken = stopOnRefusedToken
        self.tokenRetryCap = tokenRetryCap
        self.tokenExchange = tokenExchange
    }

    /// Timeout for server responses and for opening the connection (the WebSocket
    /// handshake), in seconds.
    public var timeout: Double

    /// Custom headers to include in requests.
    public var headers: [String : String]

    /// Flag to skip TLS certificate verification. Applies to both transports. On the native
    /// transport (`useNativeWebSocket == true`) this is only used as a fallback when
    /// `tlsChallengeHandler` is not set; if both are set, `tlsChallengeHandler` takes precedence.
    public var tlsSkipVerify: Bool

    /// Minimum delay before attempting reconnection, in seconds.
    public var minReconnectDelay: Double

    /// Maximum delay between reconnection attempts, in seconds.
    public var maxReconnectDelay: Double

    /// Maximum allowed time between pings from the server, in seconds.
    public var maxServerPingDelay: Double

    /// Custom client name for identification.
    public var name: String

    /// Client version for tracking.
    public var version: String

    /// Authentication token for connecting to the server.
    public var token: String

    /// Callback for retrieving authentication tokens dynamically. See
    /// `CentrifugeConnectionTokenGetter` for its call-exactly-once contract and the lack of
    /// any built-in timeout.
    public var tokenGetter: CentrifugeConnectionTokenGetter?

    /// Custom binary data associated with the client.
    public var data: Data?

    /// Enables detailed logging for debugging purposes.
    public var debug: Bool

    /// Logger instance for debugging and diagnostics.
    public var logger: CentrifugeLogger?

    /// Indicates whether the native WebSocket transport is being used.
    public var useNativeWebSocket: Bool

    /// Applied when `useNativeWebSocket == true` and will uses a native `URLSessionWebSocketTask`   for establishing WebSocket connections.
    /// - Parameters:
    ///   - urlSessionConfigurationProvider: An optional closure that provides a custom `URLSessionConfiguration`.
    ///   If not provided, `URLSessionConfiguration.default` will be used.
    /// - Note: This option is available on iOS 13.0 and later. It provides a modern WebSocket implementation.
    public var urlSessionConfigurationProvider: URLSessionConfigurationProvider?

    /// Applied when `useNativeWebSocket == true`. Lets the app answer every challenge the
    /// underlying `URLSession` receives at the session level — server-trust (e.g. to trust a
    /// private CA or pin a certificate), client-certificate (mTLS), and also NTLM/Negotiate
    /// (e.g. for an authenticating proxy). This is an unfiltered forward, same as Kingfisher's
    /// equivalent `AuthenticationChallengeResponsible.downloader(_:didReceive:)` — a handler
    /// only interested in TLS trust decisions should check
    /// `challenge.protectionSpace.authenticationMethod` itself. Takes precedence over
    /// `tlsSkipVerify` (which only ever applies to server-trust). If neither is set, the
    /// system default handling is used (full certificate verification).
    /// - Note: Only takes effect where the native transport itself is available (iOS 13.0 and
    /// later, see `useNativeWebSocket`); ignored on older OS versions, where the Starscream
    /// transport is used instead. Starscream has no equivalent to this handler — its only TLS
    /// option is `tlsSkipVerify`, which disables verification entirely rather than allowing
    /// custom trust logic or client certificates.
    /// - Note: Called on the client's own private internal serial queue (the same one used
    /// for all of its other WebSocket delegate callbacks and internal processing), not the
    /// main thread. Don't block it — the completion handler is `@escaping`, so kick off any
    /// slow work (e.g. a network call) elsewhere and call it once that resolves, rather than
    /// blocking this queue waiting for it.
    /// - Warning: Call the completion handler exactly once, on every code path, including
    /// error paths — e.g. `completionHandler(.cancelAuthenticationChallenge, nil)` to fail the
    /// connection deliberately. If it's not called within `timeout`, the connection attempt
    /// fails with a transport timeout error and the client retries, so a handler that may
    /// stall (a network call to check a pin set, etc.) should still call the completion
    /// handler on every path.
    public var tlsChallengeHandler: CentrifugeTLSChallengeHandler?

    /// Applied when `useNativeWebSocket == true`. Gives the Basic credentials for a proxy that asks for them.
    /// Apple's networking asks only on a CONNECT: for a `wss://` endpoint behind the HTTPS keys of the
    /// session's `connectionProxyDictionary`, and for any endpoint behind `URLSessionConfiguration.proxyConfigurations`
    /// (iOS 17 / macOS 14). For a `ws://` endpoint behind the HTTP keys the proxy's 407 gets no challenge, so the
    /// connection fails. The provider is called at each challenge, so it returns the current credentials.
    /// Nil, or a provider that returns nil, fails the connection attempt. Starscream ignores this setting.
    /// The RPC pool's connections and redirect fetches use it too, through the same provider.
    /// - Note: Called on an internal queue of the SDK (the client's queue, or the pool's fetch queue for redirects),
    /// never on the main thread. It must be fast and must not block.
    public var proxyCredentialsProvider: CentrifugeProxyCredentialsProvider?

    /// Id of this client on the server, 22 to 64 characters of A-Z, a-z, 0-9, `_` or `-`. It is
    /// sent in the connect request when set, and it is never written to the debug log. An invalid
    /// value is refused by `CentrifugeClient.create`, and reported through `onError` at `connect()`
    /// by `init`.
    public var instance: String?

    /// Most calls of a client with an instance that may be in flight at once: waiting, sent, or
    /// waiting for a resend. A call beyond it fails at once with `replyError(code: 16)`. Must be at
    /// least 1. A client without an instance has no bound.
    public var maxPendingRpc: Int

    /// Whether a timer refresh whose fresh token is the one the server refused as expired (code 109) does not
    /// send that token again. The connection is then left to expire, and the next connect asks the token getter.
    /// Default true. Set it to false to resend the same token on each retry.
    public var stopOnRefusedToken: Bool

    /// The longest delay between two retries of a failed timer refresh, in seconds. The retry delay grows from
    /// 10 to 20 seconds and doubles with each consecutive failure, up to this cap. Default 300.
    public var tokenRetryCap: TimeInterval

    /// Obtains and renews the connection token from a refresh token the application stores, over the
    /// connection itself. Exclusive with `tokenGetter`: `CentrifugeClient.create` throws for both. See
    /// `CentrifugeTokenExchange`. Default nil.
    public var tokenExchange: CentrifugeTokenExchange?

}

/// A typealias for a provider that returns a custom `URLSessionConfiguration`.
public typealias URLSessionConfigurationProvider = (() -> URLSessionConfiguration)

/// Handles every challenge the native WebSocket transport's underlying `URLSession` receives
/// at the session level — server-trust, client-certificate (mTLS), and also NTLM/Negotiate
/// (e.g. for an authenticating proxy) — for example, to trust a private CA, pin a certificate,
/// or present a client identity. This is an unfiltered forward of
/// `URLSessionDelegate.urlSession(_:didReceive:completionHandler:)`, the same shape as
/// Kingfisher's equivalent `AuthenticationChallengeResponsible.downloader(_:didReceive:)`: a
/// handler only interested in TLS trust decisions should check
/// `challenge.protectionSpace.authenticationMethod` itself before deciding, typically
/// deferring anything else with `completionHandler(.performDefaultHandling, nil)`. Call the
/// completion handler exactly once. HTTP Basic/Digest challenges never reach this handler —
/// those are task-level only, and this transport doesn't implement that delegate method. If
/// not set, the system default handling is used.
/// - Note: Only applies when `useNativeWebSocket == true`. Starscream has no equivalent to
/// this handler — its only TLS option is `tlsSkipVerify`, which disables verification
/// entirely rather than allowing custom trust logic or client certificates.
/// - Note: Called on the client's own private internal serial queue (the same one used for
/// all of its other WebSocket delegate callbacks and internal processing), not the main
/// thread. Don't block it — the completion handler is `@escaping`, so kick off any slow
/// work (e.g. a network call) elsewhere and call it once that resolves.
/// - Warning: Call the completion handler exactly once, on every code path, including error
/// paths — e.g. `completionHandler(.cancelAuthenticationChallenge, nil)` to fail the
/// connection deliberately. If it's not called within `timeout`, the connection attempt fails
/// with a transport timeout error and the client retries, so a handler that may stall (a
/// network call to check a pin set, etc.) should still call the completion handler on every
/// path.
public typealias CentrifugeTLSChallengeHandler = (
    _ challenge: URLAuthenticationChallenge,
    _ completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
) -> Void

public enum CentrifugeClientState: Sendable {
    case disconnected
    case connecting
    case connected
}

public class CentrifugeClient: @unchecked Sendable {
    public weak var delegate: CentrifugeClientDelegate?
    
    //MARK -
    fileprivate(set) var url: String
    fileprivate(set) var syncQueue: DispatchQueue
    fileprivate(set) var config: CentrifugeClientConfig
    internal let scheduler: ClientScheduler
    internal let clock: ClientClock
    internal let random: ClientRandom
    // Set when the configuration cannot be used (see Instance.swift): connect() reports it and
    // rpc() fails with it. Nil for a usable configuration.
    internal let configError: CentrifugeError?
    internal let serverTimeOffset: ServerTimeOffset = ServerTimeOffset()
    internal var identity: ConnectionIdentity = ConnectionIdentity()
    // The rpc calls: tracked and plain (RpcTracker.swift). Bound to this client at the end of
    // each initializer.
    internal let rpcTracker: RpcTracker = RpcTracker()
    // The explicit refresh calls and the marks of the timer refreshes (Refresh.swift).
    internal let refreshState: RefreshState = RefreshState()
    // The token exchange of the client, when one is configured (TokenExchangeRefusal.swift).
    internal var tokenExchangeState: TokenExchangeState = TokenExchangeState()

    //MARK -
    fileprivate(set) var internalState: CentrifugeClientState = .disconnected
    fileprivate var request: URLRequest
    // The transport of the current connection attempt, nil when there is none. Every
    // attempt gets a new transport object; transportId identifies it, and callbacks of a
    // transport that is no longer current are ignored.
    fileprivate var conn: WebSocketInterface?
    internal var transportId: UInt64 = 0
    fileprivate var openTimeoutTask: DispatchWorkItem?
    fileprivate var client: String?
    internal var token: String?
    fileprivate var data: Data?
    fileprivate var commandIds: CommandIdCounter = CommandIdCounter()
    fileprivate var commandIdLock: NSLock = NSLock()
    fileprivate var opCallbacks: [UInt32: ((CentrifugeResolveData) -> ())] = [:]
    fileprivate var connectCallbacks: [String: ((Error?) -> ())] = [:]
    fileprivate let subscriptionsLock = NSLock()
    fileprivate var subscriptions = [CentrifugeSubscription]()
    // Channel compaction: numeric channel ID → subscription, used to route pushes
    // that carry an ID instead of the string channel name. IDs are scoped to a
    // server session — the registry is dropped on disconnect and each subscription
    // re-registers from its subscribe reply. Touched only on syncQueue.
    fileprivate var subscriptionsById = [Int64: CentrifugeSubscription]()
    fileprivate var serverSubs = [String: ServerSubscription]()
    fileprivate var reconnectAttempts = 0
    fileprivate var disconnectOpts: CentrifugeDisconnectOptions?
    internal var refreshTask: DispatchWorkItem?
    internal var refreshRequired: Bool = false
    // Set by every disconnect: true when it is the unauthorized one, which ends the session. The rpc pool
    // reads it while the client is disconnected (RpcPool.swift).
    internal var sessionEnded: Bool = false
    // The token source of the rpc pools that take their token from this client (RpcPoolTokenSource.swift). The first
    // such pool makes it. The connect, refresh and disconnect points below tell it of the client's events.
    internal var poolTokenSource: RpcPoolTokenSource? = nil
    // The ping watchdog (Client+PingWatchdog.swift) reads and arms these three.
    internal var pingTimer: DispatchWorkItem?
    internal var pingInterval: UInt32 = 0
    internal var sendPong: Bool = false
    // The ping watchdog: the clock time of the last decoded batch that carried a reply.
    internal var lastReplyNanos: UInt64 = 0
    // The publish debounce windows of the subscriptions and their one timer (PublishDebounce.swift).
    internal var publishDebounce: PublishDebounceState = PublishDebounceState()
    fileprivate var reconnectTask: DispatchWorkItem?
    fileprivate var log: CentrifugeLogger

    static let barrierQueue = DispatchQueue(label: "com.centrifugal.centrifuge-swift.barrier<\(UUID().uuidString)>", attributes: .concurrent)
    
    public private(set) var state: CentrifugeClientState {
        get {
            return CentrifugeClient.barrierQueue.sync { internalState }
        }
        set (newState) {
            CentrifugeClient.barrierQueue.async(flags: .barrier) { self.internalState = newState }
        }
    }
    
    /// Initialize client.
    ///
    /// - Parameters:
    ///   - url: protobuf URL endpoint of Centrifugo/Centrifuge.
    ///   - config: config object.
    ///   - delegate: delegate protocol implementation to react on client events.
    public init(endpoint: String, config: CentrifugeClientConfig, delegate: CentrifugeClientDelegate? = nil) {
        let clock: ClientClock = SystemClientClock()
        let setup: ClientSetup = CentrifugeClient.makeSetup(endpoint: endpoint, config: config, clock: clock) { queue, queueClock in
            return DispatchClientScheduler(queue: queue, clock: queueClock)
        }
        self.url = endpoint
        self.config = config
        self.delegate = delegate
        self.log = setup.log
        self.token = config.token
        if config.data != nil {
            self.data = config.data
        }
        self.syncQueue = setup.syncQueue
        self.clock = clock
        self.random = SystemClientRandom()
        self.scheduler = setup.scheduler
        self.configError = setup.configError
        self.request = setup.request
        self.rpcTracker.bind(client: self)
    }

    /// Initialize client with the clock and scheduler seams (see Scheduler.swift). The public
    /// initializer above passes the production values; tests reach this one through
    /// `@testable import`. Both are designated (a subclass calls the public one with `super.init`),
    /// so the shared setup lives in `makeSetup`, not in a convenience initializer.
    internal init(
        endpoint: String,
        config: CentrifugeClientConfig,
        delegate: CentrifugeClientDelegate?,
        clock: ClientClock,
        schedulerFactory: ClientSchedulerFactory,
        random: ClientRandom
    ) {
        let setup: ClientSetup = CentrifugeClient.makeSetup(endpoint: endpoint, config: config, clock: clock, schedulerFactory: schedulerFactory)
        self.url = endpoint
        self.config = config
        self.delegate = delegate
        self.log = setup.log
        self.token = config.token
        if config.data != nil {
            self.data = config.data
        }
        self.syncQueue = setup.syncQueue
        self.clock = clock
        self.random = random
        self.scheduler = setup.scheduler
        self.configError = setup.configError
        self.request = setup.request
        self.rpcTracker.bind(client: self)
    }

    /// The values that both initializers take from one setup function.
    private typealias ClientSetup = (
        syncQueue: DispatchQueue,
        scheduler: ClientScheduler,
        configError: CentrifugeError?,
        request: URLRequest,
        log: CentrifugeLogger
    )

    /// The setup both initializers share: the queue and its scheduler, the configuration error, the request and the
    /// log. Only the random source differs between the initializers, and each sets it itself.
    private static func makeSetup(
        endpoint: String,
        config: CentrifugeClientConfig,
        clock: ClientClock,
        schedulerFactory: ClientSchedulerFactory
    ) -> ClientSetup {
        let log: CentrifugeLogger = config.logger ?? EmptyLogger.instance
        let queueID: String = UUID().uuidString
        let syncQueue: DispatchQueue = DispatchQueue(label: "com.centrifugal.centrifuge-swift.sync<\(queueID)>")
        let scheduler: ClientScheduler = schedulerFactory(syncQueue, clock)
        let request: URLRequest = CentrifugeClient.makeRequest(endpoint: endpoint, config: config)
        CentrifugeClient.logTransportChoice(config: config, log: log)
        return (
            syncQueue: syncQueue,
            scheduler: scheduler,
            configError: clientConfigurationError(config),
            request: request,
            log: log
        )
    }
    
    /**
     Connect to server.
     */
    public func connect() {
        self.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            guard strongSelf.state != .connecting else { return }
            guard strongSelf.state != .connected else { return }
            if let error: CentrifugeError = strongSelf.configError {
                strongSelf.delegate?.onError(strongSelf, CentrifugeErrorEvent(error: error))
                return
            }
            strongSelf.log.debug("start connecting")
            strongSelf.state = .connecting
            strongSelf.delegate?.onConnecting(strongSelf, CentrifugeConnectingEvent(code: connectingCodeConnectCalled, reason: "connect called"))
            strongSelf.reconnectAttempts = 0
            strongSelf.startAttempt()
        }
    }
    
    /**
     Disconnect from server.
     */
    public func disconnect() {
        self.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.processDisconnect(code: disconnectedCodeDisconnectCalled, reason: "disconnect called", reconnect: false)
        }
    }
    
    /**
     Clears the reconnect state, resetting attempts and delays.
     Schedules a reconnect immediately if one was pending.
     */
    public func resetReconnectState() {
        self.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.reconnectAttempts = 0

            guard strongSelf.reconnectTask != nil else { return }
            strongSelf.scheduleReconnect(immediately: true)
        }
    }

    /**
     setToken allows updating connection token.
     - parameter token: String
     */
    public func setToken(token: String) {
        self.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.token = token;
            if strongSelf.config.tokenGetter == nil {
                // The token expired and the app set a new one: without a token getter
                // there is no other way to get it, so the next attempt uses it. With a
                // getter, the next attempt still fetches a new token (the one set
                // meanwhile may be the expired one), as in centrifuge-js.
                strongSelf.refreshRequired = false
            }
        }
    }

    /**
     Create subscription object to specific channel with delegate
     - parameter channel: String
     - parameter delegate: CentrifugeSubscriptionDelegate
     - returns: CentrifugeSubscription
     */
    public func newSubscription(channel: String, delegate: CentrifugeSubscriptionDelegate, config: CentrifugeSubscriptionConfig? = nil) throws -> CentrifugeSubscription {
        defer { subscriptionsLock.unlock() }
        subscriptionsLock.lock()
        guard !self.subscriptions.contains(where: { $0.channel == channel }) else { throw CentrifugeError.duplicateSub }
        if let config, config.delta != nil, config.tagsFilter != nil {
            throw CentrifugeError.configurationError(message: "cannot use delta and tags filter together")
        }
        let sub = CentrifugeSubscription(
            centrifuge: self,
            channel: channel,
            config: config ?? CentrifugeSubscriptionConfig(),
            delegate: delegate,
            log: log
        )
        self.subscriptions.append(sub)
        return sub
    }
    
    /**
     Try to get Subscription from internal client registry. Can return nil if Subscription
     does not exist yet.
     - parameter channel: String
     - returns: CentrifugeSubscription?
     */
    public func getSubscription(channel: String) -> CentrifugeSubscription? {
        defer { subscriptionsLock.unlock() }
        subscriptionsLock.lock()
        return self.subscriptions.first(where: { $0.channel == channel })
    }
    
    /**
     * Say Client that Subscription should be removed from the internal registry. Subscription will be
     * automatically unsubscribed before removing. A removed subscription can't subscribe again (its
     * subscribe() reports a configurationError through onError): create a new one for the channel.
     * Removing a subscription that was already removed does nothing, also when a newer subscription of
     * the same channel exists.
     - parameter sub: CentrifugeSubscription
     */
    public func removeSubscription(_ sub: CentrifugeSubscription) {
        subscriptionsLock.lock()
        // Only this subscription: one removed before must not remove a newer
        // subscription of the same channel.
        let found = self.subscriptions.contains(where: { $0 === sub })
        self.subscriptions.removeAll(where: { $0 === sub })
        subscriptionsLock.unlock()
        guard found else { return }
        // Unsubscribe with the lock released: processUnsubscribe leads to
        // onUnsubscribed, and a handler that touches the registry would deadlock
        // on this non-recursive lock. The unsubscribe itself is queued on
        // syncQueue either way, so the observable ordering is unchanged.
        sub.markRemoved()
        sub.processUnsubscribe(sendUnsubscribe: true, code: unsubscribedCodeUnsubscribeCalled, reason: "unsubscribe called")
    }
    
    /**
     * Get a map with all client-side subscriptions in client's internal registry.
     */
    public func getSubscriptions() -> [String: CentrifugeSubscription] {
        defer { subscriptionsLock.unlock() }
        subscriptionsLock.lock()
        var subs = [String : CentrifugeSubscription]()
        self.subscriptions.forEach { sub in
            subs[sub.channel] = sub
        }
        return subs
    }
    
    /**
     Send raw asynchronous (without waiting for a response) message to server.
     - parameter data: Data
     - parameter completion: Completion block
     */
    public func send(data: Data, completion: @escaping (Error?)->()) {
        self.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.waitForConnect(completion: { [weak self] error in
                guard let strongSelf = self else { return }
                if let err = error {
                    completion(err)
                    return
                }
                strongSelf.sendSend(data: data, completion: completion)
            })
        }
    }
    
    /**
     Publish message Data to channel.
     - parameter channel: String channel name
     - parameter data: Data message data
     - parameter completion: Completion block
     */
    public func publish(channel: String, data: Data, completion: @escaping (Result<CentrifugePublishResult, Error>)->()) {
        self.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.waitForConnect(completion: { [weak self] error in
                guard let strongSelf = self else { return }
                if let err = error {
                    completion(.failure(err))
                    return
                }
                strongSelf.sendPublish(channel: channel, data: data, completion: { _, error in
                    guard self != nil else { return }
                    if let err = error {
                        completion(.failure(err))
                        return
                    }
                    completion(.success(CentrifugePublishResult()))
                })
            })
        }
    }
    
    /**
     Send RPC  command.
     - parameter method: String
     - parameter data: Data
     - parameter completion: Completion block
     */
    public func rpc(method: String, data: Data, completion: @escaping (Result<CentrifugeRpcResult, Error>)->()) {
        self.rpc(method: method, data: data, options: CentrifugeRpcOptions(), completion: completion)
    }
    
    public func presence(channel: String, completion: @escaping (Result<CentrifugePresenceResult, Error>)->()) {
        self.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.waitForConnect(completion: { [weak self] error in
                guard let strongSelf = self else { return }
                if let err = error {
                    completion(.failure(err))
                    return
                }
                strongSelf.sendPresence(channel: channel, completion: completion)
            })
        }
    }
    
    public func presenceStats(channel: String, completion: @escaping (Result<CentrifugePresenceStatsResult, Error>)->()) {
        self.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.waitForConnect(completion: { [weak self] error in
                guard let strongSelf = self else { return }
                if let err = error {
                    completion(.failure(err))
                    return
                }
                strongSelf.sendPresenceStats(channel: channel, completion: completion)
            })
        }
    }
    
    public func history(channel: String, limit: Int32 = 0, since: CentrifugeStreamPosition? = nil, reverse: Bool = false, completion: @escaping (Result<CentrifugeHistoryResult, Error>)->()) {
        self.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.waitForConnect(completion: { [weak self] error in
                guard let strongSelf = self else { return }
                if let err = error {
                    completion(.failure(err))
                    return
                }
                strongSelf.sendHistory(channel: channel, limit: limit, since: since, reverse: reverse, completion: completion)
            })
        }
    }
}

internal extension CentrifugeClient {
    
    func refreshWithToken(token: String, transportId: UInt64) {
        self.syncQueue.async { [weak self] in
            guard let strongSelf = self, strongSelf.isCurrentConnection(transportId) else { return }
            strongSelf.token = token
            strongSelf.sendRefreshCommand(token: token, completion: { [weak self] result, error in
                guard let strongSelf = self, strongSelf.isCurrentConnection(transportId) else { return }
                if let err = error {
                    // The retry is armed (or the connection ends) before the callout: delegate callbacks
                    // run inline and may re-enter the client.
                    defer {
                        strongSelf.delegate?.onError(
                            strongSelf,
                            CentrifugeErrorEvent(error: CentrifugeError.refreshError(error: err))
                        )
                    }
                    applyRefreshFailure(err, keep: {
                        return
                    }, retry: { (refusedExpired: Bool) -> Void in
                        if refusedExpired {
                            strongSelf.refreshState.refusedToken = token
                        }
                        strongSelf.scheduleTimerRefreshRetry()
                    }, end: { (code: UInt32, message: String) -> Void in
                        strongSelf.processDisconnect(code: code, reason: message, reconnect: false)
                    })
                    return
                }
                if let res = result {
                    strongSelf.acceptRefreshReply(res)
                }
            })
        }
    }
    
    /// Runs `item` on syncQueue after `delay`, with the late-timer grace of timeouts.
    func scheduleTimeout(after delay: TimeInterval, _ item: DispatchWorkItem) {
        self.scheduler.schedule(after: delay, lateGrace: true, item)
    }

    /// Whether the client is still connected over the transport with this id.
    func isCurrentConnection(_ transportId: UInt64) -> Bool {
        return self.transportId == transportId && self.state == .connected
    }

    func getBackoffDelay(step: Int, minDelay: Double, maxDelay: Double) -> Double {
        // Full jitter technique, details:
        // https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/
        // Example delays for steps 0 ... 9, minDelay: 0.5, maxDelay: 20.0
        // 0:       0.5116465680544957
        // 1:       0.9243348276211367
        // 2:       2.178205903666517
        // 3:       2.3306662375223826
        // 4:       6.011917228522875
        // 5:       4.514918385024222
        // 6:       18.60093247413233
        // 7:       19.42679889496607
        // 8:       10.569444750143937
        // 9:       16.69024085860802
        var currentStep = step;
        if (currentStep > 31) { currentStep = 31 }
        return min(maxDelay, minDelay + Double.random(in: 0 ... min(maxDelay, minDelay * pow(2, Double(currentStep)))));
    }
    
    func sendSubRefresh(token: String, channel: String, completion: @escaping (Centrifugal_Centrifuge_Protocol_SubRefreshResult?, Error?)->()) {
        var req = Centrifugal_Centrifuge_Protocol_SubRefreshRequest()
        req.token = token
        req.channel = channel
        
        var command = Centrifugal_Centrifuge_Protocol_Command()
        command.id = self.nextCommandId()
        command.subRefresh = req
        self.sendCommand(command: command, completion: { [weak self] reply, error in
            guard self != nil else { return }
            if let err = error {
                completion(nil, err)
                return
            }
            if let rep = reply {
                if rep.hasError {
                    completion(nil, CentrifugeError.replyError(code: rep.error.code, message: rep.error.message, temporary: rep.error.temporary))
                    return
                }
                completion(rep.subRefresh, nil)
            }
        })
    }
        
    func getConnectionToken(completion: @escaping (Result<String, Error>)->()) {
        // With a token exchange the token is renewed over the connection (TokenExchangeFlow.swift).
        if config.tokenExchange != nil {
            renewTokenExchangeToken(completion: completion)
            return
        }
        self.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            let once = CallOnce()
            strongSelf.config.tokenGetter?(CentrifugeConnectionTokenEvent()) { [weak self] result in
                guard once.claim(), let strongSelf = self else { return }
                strongSelf.syncQueue.async { [weak self] in
                    guard self != nil else { return }
                    completion(result)
                }
            }
        }
    }
    
    func getClient() -> String? {
        return self.client;
    }
    
    func unsubscribe(sub: CentrifugeSubscription) {
        let channel = sub.channel
        if self.state == .connected {
            let transportId = self.transportId
            self.sendUnsubscribe(channel: channel, completion: { [weak self] _, error in
                // Only for the connection it was sent on: when that connection is
                // gone (the teardown fails pending commands), so is the subscription
                // on the server.
                guard let strongSelf = self, strongSelf.transportId == transportId else { return }
                if let _ = error {
                    strongSelf.reconnect(
                        code: connectingCodeUnsubscribeError, reason: "unsubscribe error")
                    return
                }
            })
        }
    }
    
    func resubscribe() {
        // Snapshot under the lock, then call out with it released. Resubscribing
        // can reach a delegate callback, and delegate callbacks run inline on the
        // caller's thread - if one of them touches the subscription registry
        // (getSubscription, newSubscription, ...) it would try to take this
        // non-recursive lock again and deadlock. See snapshotSubscriptions().
        for sub in snapshotSubscriptions() {
            sub.resubscribeIfNecessary()
        }
    }

    /// Copy of the subscription registry, taken under `subscriptionsLock` and
    /// returned with the lock released.
    ///
    /// `subscriptionsLock` is a non-recursive `NSLock` and delegate callbacks are
    /// invoked inline (that is what gives the transport its backpressure), so any
    /// callout made while holding it can be re-entered by user code and deadlock.
    /// Every iteration over `subscriptions` that can reach user code must go
    /// through this snapshot.
    private func snapshotSubscriptions() -> [CentrifugeSubscription] {
        subscriptionsLock.lock()
        defer { subscriptionsLock.unlock() }
        return self.subscriptions
    }
    
    func subscribe(channel: String, token: String, delta: String?, tagsFilter: CentrifugeFilterNode?, data: Data?, recover: Bool, streamPosition: StreamPosition, positioned: Bool, recoverable: Bool, joinLeave: Bool, flag: Int64, completion: @escaping (Centrifugal_Centrifuge_Protocol_SubscribeResult?, Error?)->()) {
        self.sendSubscribe(channel: channel, token: token, delta: delta, tagsFilter: tagsFilter, data: data, recover: recover, streamPosition: streamPosition, positioned: positioned, recoverable: recoverable, joinLeave: joinLeave, flag: flag, completion: completion)
    }
    
    func reconnect(code: UInt32, reason: String) {
        self.processDisconnect(code: code, reason: reason, reconnect: true)
    }

    /// Disconnects for good on a stream the client can't process.
    func failBadProtocol(reason: String) {
        self.processDisconnect(code: disconnectCodeBadProtocol, reason: reason, reconnect: false)
    }

    // Update the channel compaction registry for a subscription: remove the old
    // numeric ID mapping (only if it still points to this subscription) and
    // register the new one. Either ID may be 0 meaning "no mapping". Called on
    // syncQueue (subscribe reply / unsubscribe).
    func updateSubscriptionPushId(sub: CentrifugeSubscription, oldId: Int64, newId: Int64) {
        if oldId > 0 && self.subscriptionsById[oldId] === sub {
            self.subscriptionsById.removeValue(forKey: oldId)
        }
        if newId > 0 {
            self.subscriptionsById[newId] = sub
        }
    }

    /// The next command id. The counter is shared by every command of the client, under its lock.
    func nextCommandId() -> UInt32 {
        self.commandIdLock.lock()
        let cid = self.commandIds.next()
        self.commandIdLock.unlock()
        return cid
    }

    /// Writes one command without waiting for its reply. Throws when the command cannot be encoded.
    func sendCommandAsync(command: Centrifugal_Centrifuge_Protocol_Command) throws {
        let commands: [Centrifugal_Centrifuge_Protocol_Command] = [command]
        let data = try CentrifugeSerializer.serializeCommands(commands: commands)
        self.conn?.write(data: data)
    }

    /// Writes one command and calls back with its reply. Internal for the token exchange flow (TokenExchangeFlow.swift),
    /// which writes its rpc command with it. Upstream's sendCommand is fileprivate, so the moved body lives here.
    func sendCommand(command: Centrifugal_Centrifuge_Protocol_Command, completion: @escaping (Centrifugal_Centrifuge_Protocol_Reply?, Error?)->()) {
        let strongSelf = self
        let commands: [Centrifugal_Centrifuge_Protocol_Command] = [command]
        do {
            let data = try CentrifugeSerializer.serializeCommands(commands: commands)
            strongSelf.conn?.write(data: data)
            strongSelf.waitForReply(id: command.id, completion: completion)
        } catch {
            completion(nil, error)
            return
        }
    }
}

fileprivate extension CentrifugeClient {
    func makeTransport() -> WebSocketInterface {
        if #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *), config.useNativeWebSocket {
            return NativeWebSocket(
                request: request,
                urlSessionConfigurationProvider: config.urlSessionConfigurationProvider,
                tlsSkipVerify: config.tlsSkipVerify,
                tlsChallengeHandler: config.tlsChallengeHandler,
                proxyCredentialsProvider: config.proxyCredentialsProvider,
                queue: syncQueue,
                log: log
            )
        }
        return StarscreamWebSocket(request: request, tlsSkipVerify: self.config.tlsSkipVerify, queue: syncQueue, log: log)
    }

    /// Starts a connection attempt: gets a connection token when one is needed, then
    /// opens a transport. The token comes first, as in centrifuge-js: no connection is
    /// open while the token getter runs. Centrifugo closes a connection that sends no
    /// connect command for a while, so with the transport opened first, a getter slower
    /// than that failed every attempt, its token discarded with the attempt.
    func startAttempt() {
        assertIsOnQueue(syncQueue)
        // Ends a previous attempt: its continuations, e.g. a token getter's, check the id.
        closeTransport()
        // Continuations below act only for the attempt they were started for: after a
        // disconnect() + connect() or a reconnect they belong to an attempt that is
        // over, even though the client is connecting again.
        let attempt = self.transportId

        if config.tokenExchange != nil {
            // The token exchange connects first, without a token when none is kept (TokenExchangeFlow.swift).
            beginTokenExchangeAttempt()
            openTransport()
            return
        }

        if refreshRequired && config.tokenGetter == nil {
            // The token expired and there is no getter to get a new one.
            delegate?.onError(self, CentrifugeErrorEvent(error: CentrifugeError.configurationError(
                message: "token expired but no tokenGetter set in the configuration")))
            failUnauthorized()
            return
        }

        guard config.tokenGetter != nil && (refreshRequired || token == "") else {
            openTransport()
            return
        }
        getConnectionToken(completion: { [weak self] result in
            guard let strongSelf = self, strongSelf.transportId == attempt, strongSelf.state == .connecting else { return }
            switch result {
                case .success(let token):
                    strongSelf.token = token
                    strongSelf.refreshRequired = false
                    strongSelf.openTransport()
                case .failure(let error):
                    if let centrifugeError = error as? CentrifugeError {
                        switch centrifugeError {
                        case .unauthorized:
                            strongSelf.failUnauthorized();
                            return
                        default:
                            break
                        }
                    }
                    strongSelf.delegate?.onError(
                        strongSelf,
                        CentrifugeErrorEvent(error: CentrifugeError.tokenError(error: error))
                    )
                    strongSelf.processDisconnect(code: connectingCodeTransportClosed, reason: "transport closed", reconnect: true)
            }
        })
    }

    /// Opens a new transport for the attempt in progress. Opening it is limited by
    /// `config.timeout`, like the commands sent over it.
    func openTransport() {
        assertIsOnQueue(syncQueue)
        closeTransport()

        let ws = makeTransport()
        let id = self.transportId
        ws.onConnect = { [weak self] in
            guard let strongSelf = self, strongSelf.transportId == id else { return }
            strongSelf.log.trace("WebSocket connected")
            strongSelf.openTimeoutTask?.cancel()
            strongSelf.openTimeoutTask = nil
            strongSelf.onTransportOpen()
        }
        ws.onDisconnect = { [weak self] disconnect, error in
            guard let strongSelf = self, strongSelf.transportId == id else { return }
            strongSelf.log.trace("WebSocket disconnected")
            assertIsOnQueue(strongSelf.syncQueue)
            strongSelf.closeTransport()

            if strongSelf.state == .disconnected {
                return
            }

            if strongSelf.state == .connecting, let error = error {
                strongSelf.delegate?.onError(
                    strongSelf,
                    CentrifugeErrorEvent(error: CentrifugeError.transportError(error: error))
                )
            }

            strongSelf.processDisconnect(code: disconnect.code, reason: disconnect.reason, reconnect: disconnect.reconnect)
        }
        ws.onData = { [weak self] data in
            guard let strongSelf = self, strongSelf.transportId == id else { return }
            strongSelf.onData(data: data)
        }
        self.conn = ws

        let openTimeoutTask = DispatchWorkItem { [weak self] in
            guard let strongSelf = self, strongSelf.transportId == id else { return }
            strongSelf.log.debug("transport open timeout")
            strongSelf.closeTransport()
            guard strongSelf.state == .connecting else { return }
            strongSelf.delegate?.onError(
                strongSelf,
                CentrifugeErrorEvent(error: CentrifugeError.transportError(error: CentrifugeError.timeout))
            )
            strongSelf.processDisconnect(code: connectingCodeTransportClosed, reason: "transport closed", reconnect: true)
        }
        self.openTimeoutTask = openTimeoutTask
        self.scheduleTimeout(after: self.config.timeout, openTimeoutTask)

        ws.connect()
    }

    /// Closes the current transport, if any. Nothing it delivers after this point
    /// (frames already read, its close callback) reaches the client.
    func closeTransport() {
        assertIsOnQueue(syncQueue)
        self.transportId &+= 1
        self.openTimeoutTask?.cancel()
        self.openTimeoutTask = nil
        guard let conn = self.conn else { return }
        self.conn = nil
        conn.close()
    }

    func onTransportOpen() {
        assertIsOnQueue(syncQueue)
        guard self.state == .connecting else { return }
        // The token was obtained before the transport was opened (see startAttempt).
        sendConnect(transportId: self.transportId)
    }

    func sendConnect(transportId: UInt64) {
        let token = self.token
        sendConnect(completion: { [weak self] res, error in
            guard let strongSelf = self, strongSelf.transportId == transportId, strongSelf.state == .connecting else { return }
            strongSelf.handleConnectResult(res: res, error: error, token: token)
        })
    }
    
    /// - Parameter token: the token the connect command carried.
    func handleConnectResult(res: Centrifugal_Centrifuge_Protocol_ConnectResult?, error: Error?, token: String?) {
        // A token exchange may take an anonymous reply over; the connect resumes when its bootstrap completes.
        if error == nil, let anonymous: Centrifugal_Centrifuge_Protocol_ConnectResult = res, tokenExchangeInterceptsConnect(anonymous) {
            return
        }
        if let err = error {
            defer {
                self.delegate?.onError(
                    self,
                    CentrifugeErrorEvent(error: CentrifugeError.connectError(error: err))
                )
            }
            switch err {
            case CentrifugeError.replyError(let code, let message, let temporary):
                if code == 109 { // Token expired.
                    // The next attempt gets a new token, unless the app set a new one
                    // meanwhile (see setToken).
                    if token == self.token {
                        self.refreshRequired = true
                    }
                    self.processDisconnect(code: connectingCodeTransportClosed, reason: "transport closed", reconnect: true)
                    return
                } else if temporary {
                    self.processDisconnect(code: connectingCodeTransportClosed, reason: "transport closed", reconnect: true)
                    return
                } else {
                    self.processDisconnect(code: code, reason: message, reconnect: false)
                    return
                }
            default:
                self.processDisconnect(code: connectingCodeTransportClosed, reason: "transport closed", reconnect: true)
                return
            }
        }
        
        if let result = res {
            self.state = .connected
            // Queued calls go out here, before the delegate's onConnected. A call that this settles
            // (headers on a connection without the RPC options) completes before that event.
            self.rpcTracker.onConnected(capable: (result.flag & ConnectFlags.rpcOptions) != 0)
            self.refreshConnected()
            self.reconnectAttempts = 0
            self.client = result.client
            self.identity.applyConnect(user: result.user, authClass: result.authClass)
            self.delegate?.onConnected(self, CentrifugeConnectedEvent(client: result.client, data: result.data))
            self.delegate?.onAuth(self, CentrifugeAuthEvent(user: self.identity.user, authClass: self.identity.authClass))
            self.poolTokenSource?.connectConfirmed()
            for cb in self.connectCallbacks.values {
                cb(nil)
            }
            self.connectCallbacks.removeAll(keepingCapacity: false)
            
            // Process server-side subscriptions.
            for (channel, subResult) in result.subs {
                self.serverSubs[channel] = ServerSubscription(recoverable: subResult.recoverable, offset: subResult.offset, epoch: subResult.epoch)
                let event = CentrifugeServerSubscribedEvent(channel: channel, wasRecovering: subResult.wasRecovering, recovered: subResult.recovered, positioned: subResult.positioned, recoverable: subResult.recoverable, streamPosition: subResult.positioned || subResult.recoverable ? StreamPosition(offset: subResult.offset, epoch: subResult.epoch) : nil, data: subResult.data)
                self.delegate?.onSubscribed(self, event)
                subResult.publications.forEach{ pub in
                    var info: CentrifugeClientInfo? = nil;
                    if pub.hasInfo {
                        info = CentrifugeClientInfo(client: pub.info.client, user: pub.info.user, connInfo: pub.info.connInfo, chanInfo: pub.info.chanInfo)
                    }
                    let pubEvent = CentrifugeServerPublicationEvent(channel: channel, data: pub.data, offset: pub.offset, tags: pub.tags, info: info)
                    self.delegate?.onPublication(self, pubEvent)
                    if self.serverSubs[channel]?.recoverable == true && pub.offset > 0 {
                        self.serverSubs[channel]?.offset = pub.offset
                    }
                }
            }
            // Server-side subscriptions we knew about but which are not part of the
            // connect result anymore are gone: emit unsubscribed and drop them. Must
            // run after (and outside) the loop above, otherwise subscriptions are not
            // cleaned up at all when the connect result carries no subs.
            for (channel, _) in self.serverSubs {
                if result.subs[channel] == nil {
                    self.delegate?.onUnsubscribed(self, CentrifugeServerUnsubscribedEvent(channel: channel))
                    self.serverSubs.removeValue(forKey: channel)
                }
            }
            // Resubscribe to client-side subscriptions.
            self.resubscribe()
            
            // Start reacting on pings from a server.
            if result.ping > 0 {
                self.pingInterval = result.ping
                self.sendPong = result.pong
                self.startWaitPing()
            }
            
            // Periodically refresh connection token.
            if result.expires {
                self.startConnectionRefresh(after: self.connectionRenewalDelay(ttl: result.ttl))
            }
        }
    }
    
    func onData(data: Data) {
        assertIsOnQueue(syncQueue)
        handleData(data: data)
    }
    
    
    private func waitForReply(id: UInt32, completion: @escaping (Centrifugal_Centrifuge_Protocol_Reply?, Error?)->()) {
        let timeoutTask = DispatchWorkItem { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.opCallbacks[id] = nil
            completion(nil, CentrifugeError.timeout)
        }
        self.scheduleTimeout(after: self.config.timeout, timeoutTask)
        
        self.opCallbacks[id] = { [weak self] rep in
            guard let strongSelf = self else { return }
            timeoutTask.cancel()
            
            strongSelf.opCallbacks[id] = nil
            
            if let err = rep.error {
                completion(nil, err)
            } else {
                completion(rep.reply, nil)
            }
        }
    }
    
    private func waitForConnect(completion: @escaping (Error?)->()) {
        if self.state == .disconnected {
            completion(CentrifugeError.clientDisconnected)
            return
        }
        if self.state == .connected {
            completion(nil)
            return
        }
        
        // OK, let's wait.
        
        let uid = UUID().uuidString
        
        let timeoutTask = DispatchWorkItem { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.connectCallbacks[uid] = nil
            completion(CentrifugeError.timeout)
        }
        self.scheduleTimeout(after: self.config.timeout, timeoutTask)
        
        self.connectCallbacks[uid] = { error in
            timeoutTask.cancel()
            completion(error)
        }
    }
    
    private func scheduleReconnect(immediately: Bool = false) {
        assertIsOnQueue(syncQueue)

        guard self.state == .connecting else { return }

        let delay = immediately ? 0.0 : self.getBackoffDelay(
            step: self.reconnectAttempts,
            minDelay: self.config.minReconnectDelay,
            maxDelay: self.config.maxReconnectDelay
        )
        self.reconnectAttempts += 1
        self.reconnectTask?.cancel()
        self.reconnectTask = DispatchWorkItem { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.reconnectTask = nil
            guard strongSelf.state == .connecting else { return }
            strongSelf.log.debug("start reconnecting")
            strongSelf.startAttempt()
        }
        self.log.debug("schedule reconnect in \(delay) seconds")
        self.scheduleAfter(delay, self.reconnectTask!)
    }
    
    // The client-side subscription a push is for: only a subscribed one. A push for
    // a subscription that is subscribing or unsubscribed belongs to a subscribe
    // session that is over (or not established yet) and must not be applied - it
    // would deliver events the app no longer expects and move the stream position.
    // nil means the push goes to a server-side subscription of the channel, if any.
    // Pushes with a numeric channel ID (channel compaction) are only ever for
    // client-side subscriptions.
    private func subscribedSub(channel: String, id: Int64) -> CentrifugeSubscription? {
        if id > 0 {
            guard let sub = self.subscriptionForPushId(id), sub.state == .subscribed else { return nil }
            return sub
        }
        subscriptionsLock.lock()
        defer { subscriptionsLock.unlock() }
        return self.subscriptions.first(where: { $0.channel == channel && $0.state == .subscribed })
    }

    private func handlePub(channel: String, pub: Centrifugal_Centrifuge_Protocol_Publication, id: Int64 = 0) {
        if let sub = self.subscribedSub(channel: channel, id: id) {
            sub.handlePublication(pub: pub)
            return
        }
        guard id == 0, self.serverSubs[channel] != nil else { return }
        var info: CentrifugeClientInfo? = nil;
        if pub.hasInfo {
            info = CentrifugeClientInfo(client: pub.info.client, user: pub.info.user, connInfo: pub.info.connInfo, chanInfo: pub.info.chanInfo)
        }
        let event = CentrifugeServerPublicationEvent(channel: channel, data: pub.data, offset: pub.offset, tags: pub.tags, info: info)
        self.delegate?.onPublication(self, event)
        if self.serverSubs[channel]?.recoverable == true && pub.offset > 0 {
            self.serverSubs[channel]?.offset = pub.offset
        }
    }
    
    private func handleJoin(channel: String, join: Centrifugal_Centrifuge_Protocol_Join, id: Int64 = 0) {
        if let sub = self.subscribedSub(channel: channel, id: id) {
            sub.delegate?.onJoin(sub, CentrifugeJoinEvent(client: join.info.client, user: join.info.user, connInfo: join.info.connInfo, chanInfo: join.info.chanInfo))
            return
        }
        guard id == 0, self.serverSubs[channel] != nil else { return }
        let event = CentrifugeServerJoinEvent(channel: channel, client: join.info.client, user: join.info.user, connInfo: join.info.connInfo, chanInfo: join.info.chanInfo)
        self.delegate?.onJoin(self, event)
    }

    private func handleLeave(channel: String, leave: Centrifugal_Centrifuge_Protocol_Leave, id: Int64 = 0) {
        if let sub = self.subscribedSub(channel: channel, id: id) {
            sub.delegate?.onLeave(sub, CentrifugeLeaveEvent(client: leave.info.client, user: leave.info.user, connInfo: leave.info.connInfo, chanInfo: leave.info.chanInfo))
            return
        }
        guard id == 0, self.serverSubs[channel] != nil else { return }
        let event = CentrifugeServerLeaveEvent(channel: channel, client: leave.info.client, user: leave.info.user, connInfo: leave.info.connInfo, chanInfo: leave.info.chanInfo)
        self.delegate?.onLeave(self, event)
    }
    
    private func handleUnsubscribe(channel: String, unsubscribe: Centrifugal_Centrifuge_Protocol_Unsubscribe) {
        guard let sub = self.subscribedSub(channel: channel, id: 0) else {
            if let _ = self.serverSubs[channel] {
                let event = CentrifugeServerUnsubscribedEvent(channel: channel)
                self.delegate?.onUnsubscribed(self, event)
                self.serverSubs.removeValue(forKey: channel)
            }
            return
        }
        
        if (unsubscribe.code < 2500) {
            sub.processUnsubscribe(sendUnsubscribe: false, code: unsubscribe.code, reason: unsubscribe.reason)
        } else {
            if unsubscribe.code == unsubscribedStateInvalidated {
                // State invalidated: drop the subscription token and cached state
                // so the resubscribe below obtains a fresh token and re-syncs.
                sub.invalidateState()
            }
            sub.moveToSubscribingUponDisconnect(code: unsubscribe.code, reason: unsubscribe.reason)
            sub.resubscribeIfNecessary()
        }
    }
    
    private func handleSubscribe(channel: String, sub: Centrifugal_Centrifuge_Protocol_Subscribe) {
        self.serverSubs[channel] = ServerSubscription(recoverable: sub.recoverable, offset: sub.offset, epoch: sub.epoch)
        let event = CentrifugeServerSubscribedEvent(channel: channel, wasRecovering: false, recovered: false, positioned: sub.positioned, recoverable: sub.recoverable, streamPosition: sub.positioned || sub.recoverable ? StreamPosition(offset: sub.offset, epoch: sub.epoch): nil, data: sub.data)
        self.delegate?.onSubscribed(self, event)
    }
    
    private func handleMessage(message: Centrifugal_Centrifuge_Protocol_Message) {
        self.delegate?.onMessage(self, CentrifugeMessageEvent(data: message.data))
    }
    
    private func handleDisconnect(disconnect: Centrifugal_Centrifuge_Protocol_Disconnect) {
        let code = disconnect.code
        let reconnect = code < 3500 || code >= 5000 || (code >= 4000 && code < 4500)
        self.processDisconnect(code: code, reason: disconnect.reason, reconnect: reconnect)
    }
    
    private func handlePing() {
        // A bootstrap holds the connection in the connecting state, and the server pings it too.
        guard self.state == .connected || self.tokenExchangeState.bootstrap != nil else { return }
        if self.sendPong {
            try? self.sendCommandAsync(command: Centrifugal_Centrifuge_Protocol_Command())
        }
    }
    
    // Resolve a client-side subscription for a push by numeric channel ID when
    // channel compaction is in use (the push then has no channel name).
    private func subscriptionForPushId(_ id: Int64) -> CentrifugeSubscription? {
        return self.subscriptionsById[id]
    }

    private func handlePush(push: Centrifugal_Centrifuge_Protocol_Push) {
        if self.holdTokenExchangePush(push) { return }
        let channel = push.channel
        // Channel compaction: pub/join/leave pushes may carry a numeric channel ID
        // instead of the channel name. Other push types always carry the channel.
        let id = push.id
        if push.hasPub {
            let pub = push.pub
            self.handlePub(channel: channel, pub: pub, id: id)
        } else if push.hasJoin {
            let join = push.join
            self.handleJoin(channel: channel, join: join, id: id)
        } else if push.hasLeave {
            let leave = push.leave
            self.handleLeave(channel: channel, leave: leave, id: id)
        } else if push.hasUnsubscribe {
            let unsubscribe = push.unsubscribe
            self.handleUnsubscribe(channel: channel, unsubscribe: unsubscribe)
        } else if push.hasSubscribe {
            let sub = push.subscribe
            self.handleSubscribe(channel: channel, sub: sub)
        } else if push.hasMessage {
            let message = push.message
            self.handleMessage(message: message)
        } else if push.hasDisconnect {
            let disconnect = push.disconnect
            self.handleDisconnect(disconnect: disconnect)
        }
    }
    
    private func handleData(data: Data) {
        do {
            let replies = try CentrifugeSerializer.deserializeCommands(data: data)
            if !replies.isEmpty {
                self.lastReplyNanos = self.clock.monotonicNanos()
            }
            let transportId = self.transportId
            for reply in replies {
                // A message earlier in this frame ended the connection (a disconnect
                // push, an error reply): the rest of the frame belongs to it too.
                guard self.transportId == transportId else { break }
                if reply.id > 0 {
                    // Only a reply that answers a pending command sets the server time.
                    if let callback: ((CentrifugeResolveData) -> ()) = self.opCallbacks[reply.id] {
                        self.serverTimeFrom(reply: reply)
                        callback(CentrifugeResolveData(error: nil, reply: reply))
                    } else {
                        self.routeTrackedReply(reply)
                    }
                } else {
                    if !reply.hasPush {
                        self.handlePing()
                    } else {
                        self.handlePush(push: reply.push)
                    }
                }
            }
        } catch {
            self.log.error("error deserializeCommands: \(error)")
        }
    }
}


// Called from other files: processDisconnect and failUnauthorized (Refresh.swift, TokenExchangeFlow.swift and the ping
// watchdog in Client+PingWatchdog.swift), so this extension is internal.
internal extension CentrifugeClient {
    private func stopReconnect() {
        self.reconnectTask?.cancel()
        self.reconnectTask = nil
    }

    /// The server ended the session as unauthorized: the connection is disconnected for good.
    func failUnauthorized() -> Void {
        self.processDisconnect(code: disconnectedCodeUnauthorized, reason: "unauthorized", reconnect: false)
    }

    // Caller must synchronize access.
    func processDisconnect(code: UInt32, reason: String, reconnect: Bool) {
        assertIsOnQueue(syncQueue)
        if self.state == .disconnected {
            return
        }
        
        let previousState = self.state
        self.sessionEnded = code == disconnectedCodeUnauthorized

        // Close the transport before anything else, so that events emitted below
        // never see it, and frames it already read are not delivered.
        self.closeTransport()
        self.tokenExchangeTransportLost(code: code, terminal: !reconnect)

        if reconnect {
            self.state = .connecting
        } else {
            self.state = .disconnected
        }
        let needEvent = previousState != self.state
        
        self.rpcTracker.onTransportLost(terminal: !reconnect)
        self.resetPublishDebounce()
        self.client = nil

        // Channel compaction IDs are scoped to a server session — drop the routing
        // registry; each resubscribe re-registers a fresh ID. The per-subscription
        // pushId is left as-is: the next subscribe reply re-registers it regardless
        // of whether the server reuses the same ID.
        self.subscriptionsById.removeAll()

        if code == disconnectedStateInvalidated {
            // State invalidated (delivered as a WebSocket close code or a Disconnect
            // push — both funnel here): drop the connection token so the next connect
            // fetches a fresh one via the token getter, and invalidate every
            // subscription's cached state before they move to subscribing below.
            // Without a getter there is no new token to get: keep the token the client
            // has (or none) and reconnect with it - the server rejects it if it's no
            // longer valid.
            if self.config.tokenGetter != nil {
                self.token = ""
                self.refreshRequired = true
            }
            for sub in snapshotSubscriptions() {
                sub.invalidateState()
            }
            // Server-side subscriptions carry their own cached recovery position,
            // separate from the client-side subscriptions above — reset it to the
            // same unrecoverable sentinel so the next connect can't recover from
            // now-invalidated state.
            for channel in self.serverSubs.keys {
                self.serverSubs[channel]?.offset = 0
                self.serverSubs[channel]?.epoch = "_"
            }
        }

        // Detach the pending callbacks before resolving them. A callback can
        // re-enter processDisconnect synchronously (a failed unsubscribe
        // reconnects), and that nested call must not find - and resolve a second
        // time - the callbacks this loop has not reached yet.
        let opCallbacks = self.opCallbacks
        self.opCallbacks.removeAll()
        for resolveFunc in opCallbacks.values {
            resolveFunc(CentrifugeResolveData(error: CentrifugeError.clientDisconnected, reply: nil))
        }

        // Calls waiting for a connection keep waiting (within their timeout) across
        // a reconnect; only a disconnect ends the wait, as in centrifuge-js.
        if !reconnect {
            let connectCallbacks = self.connectCallbacks
            self.connectCallbacks.removeAll()
            for resolveFunc in connectCallbacks.values {
                resolveFunc(CentrifugeError.clientDisconnected)
            }
        }
        
        // Explicit refresh calls waiting for the connection: a disconnect for good fails them.
        self.refreshDisconnected(terminal: !reconnect)
        self.stopReconnect()
        self.stopWaitPing()
        self.stopConnectionRefresh()
        
        // Snapshot first: moveToSubscribingUponDisconnect emits onSubscribing, and
        // a handler that calls getSubscription() would deadlock on this lock.
        for sub in snapshotSubscriptions() {
            sub.moveToSubscribingUponDisconnect(code: subscribingCodeTransportClosed, reason: "transport closed")
        }
        
        if previousState == .connected  {
            for (channel, _) in self.serverSubs {
                let event = CentrifugeServerSubscribingEvent(channel: channel)
                self.delegate?.onSubscribing(self, event)
            }
        }
        
        if needEvent {
            if self.state == .disconnected {
                self.delegate?.onDisconnected(
                    self,
                    CentrifugeDisconnectedEvent(code: code, reason: reason)
                )
            } else {
                self.delegate?.onConnecting(
                    self,
                    CentrifugeConnectingEvent(code: code, reason: reason)
                )
            }
        }

        self.poolTokenSource?.mainStateChanged()
        if self.state == .connecting {
            self.scheduleReconnect()
        }
    }
    
    private func sendConnect(completion: @escaping (Centrifugal_Centrifuge_Protocol_ConnectResult?, Error?)->()) {
        var req = Centrifugal_Centrifuge_Protocol_ConnectRequest()
        if self.token != nil {
            req.token = self.token!
        }
        if self.data != nil {
            req.data = self.data!
        }
        req.name = self.config.name
        req.version = self.config.version
        req.flag = ConnectFlags.rpcOptions
        if let instance: String = self.config.instance {
            req.instance = instance
            self.log.debug("connect instance=\(instanceRedaction)")
        }
        if !self.serverSubs.isEmpty {
            var subs = [String: Centrifugal_Centrifuge_Protocol_SubscribeRequest]()
            for (channel, serverSub) in self.serverSubs {
                var subRequest = Centrifugal_Centrifuge_Protocol_SubscribeRequest();
                subRequest.recover = serverSub.recoverable
                subRequest.offset = serverSub.offset
                subRequest.epoch = serverSub.epoch
                subs[channel] = subRequest
            }
            req.subs = subs
        }
        
        var command = Centrifugal_Centrifuge_Protocol_Command()
        command.id = self.nextCommandId()
        command.connect = req
        self.sendCommand(command: command, completion: { [weak self] reply, error in
            guard self != nil else { return }
            if let err = error {
                completion(nil, err)
                return
            }
            if let rep = reply {
                if rep.hasError {
                    completion(nil, CentrifugeError.replyError(code: rep.error.code, message: rep.error.message, temporary: rep.error.temporary))
                    return
                }
                completion(rep.connect, nil)
            }
        })
    }
    
}


// The token exchange flow (TokenExchangeFlow.swift) resumes a connect through this: handleConnectResult is in a fileprivate
// extension, and a member of one cannot be made internal.
internal extension CentrifugeClient {
    func resumeConnect(_ result: Centrifugal_Centrifuge_Protocol_ConnectResult) {
        self.handleConnectResult(res: result, error: nil, token: nil)
    }
}


// The refresh command is sent from Refresh.swift, so it is internal (the extension is not fileprivate).
internal extension CentrifugeClient {
    func sendRefresh(token: String, completion: @escaping (Centrifugal_Centrifuge_Protocol_RefreshResult?, Error?)->()) {
        var req = Centrifugal_Centrifuge_Protocol_RefreshRequest()
        req.token = token
        
        var command = Centrifugal_Centrifuge_Protocol_Command()
        command.id = self.nextCommandId()
        command.refresh = req
        self.sendCommand(command: command, completion: { [weak self] reply, error in
            guard self != nil else { return }
            if let err = error {
                completion(nil, err)
                return
            }
            if let rep = reply {
                if rep.hasError {
                    completion(nil, CentrifugeError.replyError(code: rep.error.code, message: rep.error.message, temporary: rep.error.temporary))
                    return
                }
                completion(rep.refresh, nil)
            }
        })
    }
}


fileprivate extension CentrifugeClient {
    private func sendUnsubscribe(channel: String, completion: @escaping (Centrifugal_Centrifuge_Protocol_UnsubscribeResult?, Error?)->()) {
        var req = Centrifugal_Centrifuge_Protocol_UnsubscribeRequest()
        req.channel = channel
        
        var command = Centrifugal_Centrifuge_Protocol_Command()
        command.id = self.nextCommandId()
        command.unsubscribe = req
        self.sendCommand(command: command, completion: { [weak self] reply, error in
            guard self != nil else { return }
            if let err = error {
                completion(nil, err)
                return
            }
            if let rep = reply {
                if rep.hasError {
                    completion(nil, CentrifugeError.replyError(code: rep.error.code, message: rep.error.message, temporary: rep.error.temporary))
                    return
                }
                completion(rep.unsubscribe, nil)
            }
        })
    }
    
    private func sendSubscribe(channel: String, token: String, delta: String?, tagsFilter: CentrifugeFilterNode?, data: Data?, recover: Bool, streamPosition: StreamPosition, positioned: Bool, recoverable: Bool, joinLeave: Bool, flag: Int64, completion: @escaping (Centrifugal_Centrifuge_Protocol_SubscribeResult?, Error?)->()) {
        var req = Centrifugal_Centrifuge_Protocol_SubscribeRequest()
        req.channel = channel
        if recover {
            req.recover = true
            req.epoch = streamPosition.epoch
            req.offset = streamPosition.offset
        }
        req.positioned = positioned
        req.recoverable = recoverable
        req.joinLeave = joinLeave
        req.flag = flag
        if let delta {
            req.delta = delta
        }
        if let tagsFilter {
            req.tf = tagsFilter.node
        }
        if data != nil {
            req.data = data!
        }
        if token != "" {
            req.token = token
        }
        var command = Centrifugal_Centrifuge_Protocol_Command()
        command.id = self.nextCommandId()
        command.subscribe = req
        self.sendCommand(command: command, completion: { [weak self] reply, error in
            guard self != nil else { return }
            if let err = error {
                completion(nil, err)
                return
            }
            if let rep = reply {
                if rep.hasError {
                    completion(nil, CentrifugeError.replyError(code: rep.error.code, message: rep.error.message, temporary: rep.error.temporary))
                    return
                }
                completion(rep.subscribe, nil)
            }
        })
    }
    
    private func sendPublish(channel: String, data: Data, completion: @escaping (Centrifugal_Centrifuge_Protocol_PublishResult?, Error?)->()) {
        var req = Centrifugal_Centrifuge_Protocol_PublishRequest()
        req.channel = channel
        req.data = data
        
        var command = Centrifugal_Centrifuge_Protocol_Command()
        command.id = self.nextCommandId()
        command.publish = req
        self.sendCommand(command: command, completion: { [weak self] reply, error in
            guard self != nil else { return }
            if let err = error {
                completion(nil, err)
                return
            }
            if let rep = reply {
                if rep.hasError {
                    completion(nil, CentrifugeError.replyError(code: rep.error.code, message: rep.error.message, temporary: rep.error.temporary))
                    return
                }
                completion(rep.publish, nil)
            }
        })
    }
    
    private func sendHistory(channel: String, limit: Int32 = 0, since: CentrifugeStreamPosition?, reverse: Bool = false, completion: @escaping (Result<CentrifugeHistoryResult, Error>)->()) {
        var req = Centrifugal_Centrifuge_Protocol_HistoryRequest()
        req.channel = channel
        req.limit = limit
        req.reverse = reverse
        if since != nil {
            var sp = Centrifugal_Centrifuge_Protocol_StreamPosition()
            sp.offset = since!.offset
            sp.epoch = since!.epoch
            req.since = sp
        }
        var command = Centrifugal_Centrifuge_Protocol_Command()
        command.id = self.nextCommandId()
        command.history = req
        self.sendCommand(command: command, completion: { [weak self] reply, error in
            guard self != nil else { return }
            if let err = error {
                completion(.failure(err))
                return
            }
            if let rep = reply {
                if rep.hasError {
                    completion(.failure(CentrifugeError.replyError(code: rep.error.code, message: rep.error.message, temporary: rep.error.temporary)))
                    return
                }
                let result = rep.history
                var pubs = [CentrifugePublication]()
                for pub in result.publications {
                    var clientInfo: CentrifugeClientInfo?
                    if pub.hasInfo {
                        clientInfo = CentrifugeClientInfo(client: pub.info.client, user: pub.info.user, connInfo: pub.info.connInfo, chanInfo: pub.info.chanInfo)
                    }
                    pubs.append(CentrifugePublication(offset: pub.offset, data: pub.data, clientInfo: clientInfo))
                }
                completion(.success(CentrifugeHistoryResult(publications: pubs, offset: result.offset, epoch: result.epoch)))
            }
        })
    }
    
    private func sendPresence(channel: String, completion: @escaping (Result<CentrifugePresenceResult, Error>)->()) {
        var req = Centrifugal_Centrifuge_Protocol_PresenceRequest()
        req.channel = channel
        
        var command = Centrifugal_Centrifuge_Protocol_Command()
        command.id = self.nextCommandId()
        command.presence = req
        
        self.sendCommand(command: command, completion: { [weak self] reply, error in
            guard self != nil else { return }
            if let err = error {
                completion(.failure(err))
                return
            }
            if let rep = reply {
                if rep.hasError {
                    completion(.failure(CentrifugeError.replyError(code: rep.error.code, message: rep.error.message, temporary: rep.error.temporary)))
                    return
                }
                let result = rep.presence
                var presence = [String: CentrifugeClientInfo]()
                for (client, info) in result.presence {
                    presence[client] = CentrifugeClientInfo(client: info.client, user: info.user, connInfo: info.connInfo, chanInfo: info.chanInfo)
                }
                completion(.success(CentrifugePresenceResult(presence: presence)))
            }
        })
    }
    
    private func sendPresenceStats(channel: String, completion: @escaping (Result<CentrifugePresenceStatsResult, Error>)->()) {
        var req = Centrifugal_Centrifuge_Protocol_PresenceStatsRequest()
        req.channel = channel
        
        var command = Centrifugal_Centrifuge_Protocol_Command()
        command.id = self.nextCommandId()
        command.presenceStats = req
        
        self.sendCommand(command: command, completion: { [weak self] reply, error in
            guard self != nil else { return }
            if let err = error {
                completion(.failure(err))
                return
            }
            if let rep = reply {
                if rep.hasError {
                    completion(.failure(CentrifugeError.replyError(code: rep.error.code, message: rep.error.message, temporary: rep.error.temporary)))
                    return
                }
                let result = rep.presenceStats
                let stats = CentrifugePresenceStatsResult(numClients: result.numClients, numUsers: result.numUsers)
                completion(.success(stats))
            }
        })
    }
    
    private func sendSend(data: Data, completion: @escaping (Error?)->()) {
        var req = Centrifugal_Centrifuge_Protocol_SendRequest()
        req.data = data
        do {
            var command = Centrifugal_Centrifuge_Protocol_Command()
            command.send = req
            try self.sendCommandAsync(command: command)
            completion(nil)
        } catch {
            completion(error)
        }
    }
}
