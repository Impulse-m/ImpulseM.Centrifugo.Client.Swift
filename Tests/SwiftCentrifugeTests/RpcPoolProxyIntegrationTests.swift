import Foundation
import Testing
@testable import SwiftCentrifuge

/// Integration tests for the transport of an RPC pool through a proxy that asks for Basic credentials (`AuthProxy`),
/// against the real Centrifugo: plain on localhost:8000 and TLS on localhost:8443 (ci.yml starts both).
///
/// The pool's connections take the main client's transport, so the main client is configured with the proxy and
/// its credentials, and the pool is created from it. The main client always connects first, over `wss://` with the
/// right credentials, so that the pool admits its calls. Only then does the provider switch to the case's answer,
/// and the proxy's counts are read after that: what the proxy sees later comes from the pool's connections.
///
/// The client uses a host name that is not a loopback address, because Apple's networking may skip a proxy for
/// localhost. The name resolves to the local Centrifugo, so a pool connection that bypassed the proxy would reach
/// the server; the "no server reply" checks rely on that.
///
/// The suite needs `CENTRIFUGE_PROXY_TEST_HOST` set to that host name, and `/etc/hosts` mapping it to 127.0.0.1
/// (ci.yml does both). Without the variable every test returns early.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct RpcPoolProxyIntegrationTests {

    /// How the credentials provider answers the proxy's challenge once the main client is connected.
    private enum CredentialMode {
        case right
        case wrongPassword
        case providerReturnsNil
    }

    private struct Outcome {
        /// Whether the server answered the call: a success or a reply error, not a transport or timeout failure.
        let serverReplied: Bool
        /// The proxy's authenticated requests before and after the pool call.
        let authenticatedBefore: Int
        let authenticatedAfter: Int
        /// The proxy's 407 answers before and after the pool call.
        let rejectedBefore: Int
        let rejectedAfter: Int
        let proxy: AuthProxy
    }

    /// Counts how many times the credentials provider was called, from the client's queue.
    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() {
            lock.lock(); defer { lock.unlock() }
            count += 1
        }

        var value: Int {
            lock.lock(); defer { lock.unlock() }
            return count
        }
    }

    /// Keeps the result of a pool call, which settles on the pool's queue.
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Result<CentrifugeRpcResult, Error>?

        func set(_ result: Result<CentrifugeRpcResult, Error>) {
            lock.lock(); defer { lock.unlock() }
            stored = result
        }

        var value: Result<CentrifugeRpcResult, Error>? {
            lock.lock(); defer { lock.unlock() }
            return stored
        }
    }

    private final class ConnectWatcher: CentrifugeClientDelegate, @unchecked Sendable {
        let connected: Expectation

        init(connected: Expectation) {
            self.connected = connected
        }

        func onConnected(_ client: CentrifugeClient, _ event: CentrifugeConnectedEvent) {
            connected.fulfill()
        }
    }

    private static func proxyHost() -> String? {
        let value: String? = ProcessInfo.processInfo.environment["CENTRIFUGE_PROXY_TEST_HOST"]
        return value?.isEmpty == false ? value : nil
    }

    /// The HTTP and HTTPS keys of `connectionProxyDictionary`, both pointing at the proxy.
    private static func dictionaryConfiguration(proxyPort: UInt16) -> URLSessionConfiguration {
        let configuration: URLSessionConfiguration = URLSessionConfiguration.ephemeral
        let proxyDictionary: [AnyHashable: Any] = [
            kCFNetworkProxiesHTTPEnable as String: 1,
            kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPPort as String: Int(proxyPort),
            "HTTPSEnable": 1,
            "HTTPSProxy": "127.0.0.1",
            "HTTPSPort": Int(proxyPort),
        ]
        configuration.connectionProxyDictionary = proxyDictionary
        return configuration
    }

    /// Whether a pool call's result is an answer of the server.
    private func isServerReply(_ result: Result<CentrifugeRpcResult, Error>?) -> Bool {
        guard let result: Result<CentrifugeRpcResult, Error> = result else {
            return false
        }
        switch result {
            case .success:
                return true

            case .failure(let error):
                guard let centrifugeError: CentrifugeError = error as? CentrifugeError else {
                    return false
                }
                switch centrifugeError {
                    case .replyError, .replyErrorDetails:
                        return true

                    default:
                        return false
                }
        }
    }

    /// Starts a proxy, a main client on `wss://host:8443` configured with the proxy, and a pool of that main client
    /// whose endpoint is `poolScheme`://`host`:`poolPort`. Once the main client is connected, the provider answers as
    /// `mode` says. Makes one pool call, and returns what the server and the proxy saw.
    private func runPoolCase(
        poolScheme: String,
        poolPort: UInt16,
        mode: CredentialMode,
        host: String
    ) async throws -> Outcome {
        let user: String = "user-" + UUID().uuidString.prefix(8)
        let password: String = "pw-" + UUID().uuidString

        // Every tunnel ends at the TLS server, which the main client and the secure pool route use.
        let proxy: AuthProxy = AuthProxy(user: user, password: password, upstreamPort: 8443)
        try proxy.start()
        defer { proxy.stop() }

        let providerCalls: CallCounter = CallCounter()
        let mainConnected: Expectation = Expectation("main connected through the proxy")
        let watcher: ConnectWatcher = ConnectWatcher(connected: mainConnected)
        let proxyPort: UInt16 = proxy.port
        let config: CentrifugeClientConfig = CentrifugeClientConfig(
            tlsSkipVerify: true,
            useNativeWebSocket: true,
            urlSessionConfigurationProvider: { () -> URLSessionConfiguration in
                return RpcPoolProxyIntegrationTests.dictionaryConfiguration(proxyPort: proxyPort)
            },
            proxyCredentialsProvider: { () -> CentrifugeProxyCredentials? in
                providerCalls.increment()
                guard mainConnected.fulfillmentCount > 0 else {
                    return CentrifugeProxyCredentials(user: user, password: password)
                }
                switch mode {
                    case .right:
                        return CentrifugeProxyCredentials(user: user, password: password)

                    case .wrongPassword:
                        return CentrifugeProxyCredentials(user: user, password: "wrong-" + password)

                    case .providerReturnsNil:
                        return nil
                }
            }
        )
        let mainEndpoint: String = "wss://\(host):8443/connection/websocket"
        let main: CentrifugeClient = CentrifugeClient(endpoint: mainEndpoint, config: config, delegate: watcher)
        main.connect()
        defer { main.disconnect() }
        await fulfillment(of: mainConnected, within: 10)

        let poolEndpoint: String = "\(poolScheme)://\(host):\(poolPort)/connection/websocket"
        let options: CentrifugeRpcPoolOptions = CentrifugeRpcPoolOptions(
            endpoints: { (_: String) -> [String] in
                return [poolEndpoint]
            },
            timeout: 10
        )
        let pool: CentrifugeRpcPool = try CentrifugeRpcPool.create(main: main, options: options)
        defer { pool.close(completion: {}) }

        let before: Int = proxy.connects + proxy.forwards
        let rejectedBefore: Int = proxy.rejected
        let box: ResultBox = ResultBox()
        let done: Expectation = Expectation("pool call settled")
        pool.rpc(
            endpointKey: "proxy-test",
            method: "test.method",
            data: Data("{}".utf8),
            options: CentrifugeRpcPoolCallOptions()
        ) { (result: Result<CentrifugeRpcResult, Error>) -> Void in
            box.set(result)
            done.fulfill()
        }
        await fulfillment(of: done, within: 20)

        print("RpcPoolProxyIntegrationTests: proxy saw authorities \(proxy.authorities), forms \(proxy.forms)")
        return Outcome(
            serverReplied: isServerReply(box.value),
            authenticatedBefore: before,
            authenticatedAfter: proxy.connects + proxy.forwards,
            rejectedBefore: rejectedBefore,
            rejectedAfter: proxy.rejected,
            proxy: proxy
        )
    }

    // MARK: Secure route (wss://, CONNECT through the HTTPS keys, pool connections on the main client's transport)

    @Test func secureRightCredentialsReachServerThroughPool() async throws {
        guard let host = RpcPoolProxyIntegrationTests.proxyHost() else { return }
        let outcome: Outcome = try await runPoolCase(poolScheme: "wss", poolPort: 8443, mode: .right, host: host)
        #expect(outcome.serverReplied, "the pool call got no answer of the server; rejections: \(outcome.proxy.rejections)")
        #expect(outcome.authenticatedAfter > outcome.authenticatedBefore,
                "no authenticated request by a pool connection; rejections: \(outcome.proxy.rejections)")
        #expect(outcome.rejectedAfter > outcome.rejectedBefore, "the pool's connection was never asked for credentials")
        #expect(outcome.proxy.authorities.contains("\(host):8443"), "authorities: \(outcome.proxy.authorities)")
    }

    @Test func secureWrongPasswordPoolCallFailsWithoutDirectFallback() async throws {
        guard let host = RpcPoolProxyIntegrationTests.proxyHost() else { return }
        let outcome: Outcome = try await runPoolCase(poolScheme: "wss", poolPort: 8443, mode: .wrongPassword, host: host)
        // The host resolves directly, so a direct pool connection would be answered by the server.
        #expect(!outcome.serverReplied, "the server answered a pool call without the right credentials")
        #expect(outcome.authenticatedAfter == outcome.authenticatedBefore, "a pool connection was authenticated")
        #expect(outcome.rejectedAfter > outcome.rejectedBefore, "no pool connection reached the proxy")
    }

    @Test func secureNilProviderPoolCallFailsWithoutDirectFallback() async throws {
        guard let host = RpcPoolProxyIntegrationTests.proxyHost() else { return }
        let outcome: Outcome = try await runPoolCase(poolScheme: "wss", poolPort: 8443, mode: .providerReturnsNil, host: host)
        #expect(!outcome.serverReplied, "the server answered a pool call without credentials")
        #expect(outcome.authenticatedAfter == outcome.authenticatedBefore, "a pool connection was authenticated")
        #expect(outcome.rejectedAfter > outcome.rejectedBefore, "no pool connection reached the proxy")
    }

    // MARK: Platform limitation

    @Test func plainWebSocketPoolNeverGoesDirect() async throws {
        // The proxy's 407 to an absolute-form request gets no challenge from Apple's networking, so the pool's
        // plain connections fail at the proxy. They fail closed: no server reply unless the proxy saw an
        // authenticated request.
        guard let host = RpcPoolProxyIntegrationTests.proxyHost() else { return }
        // The plain server on 8000 answers a direct connection; the proxy never forwards there.
        let outcome: Outcome = try await runPoolCase(poolScheme: "ws", poolPort: 8000, mode: .right, host: host)
        #expect(outcome.rejectedAfter > outcome.rejectedBefore, "no pool connection reached the proxy")
        #expect(!outcome.serverReplied, "the server answered a plain pool call that went around the proxy")
    }
}
