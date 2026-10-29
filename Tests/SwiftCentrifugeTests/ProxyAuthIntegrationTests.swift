import Foundation
import Network
import Testing
@testable import SwiftCentrifuge

/// Integration tests for the native WebSocket transport through a proxy that asks for Basic
/// credentials (`AuthProxy`), against the real Centrifugo: plain on localhost:8000 and TLS on
/// localhost:8443 (ci.yml starts both).
///
/// Apple's networking asks the proxy for credentials on a CONNECT. That is the route of a `wss://`
/// endpoint behind the HTTPS keys of `connectionProxyDictionary`, and of any endpoint behind
/// `URLSessionConfiguration.proxyConfigurations` (iOS 17 / macOS 14). A `ws://` endpoint behind the
/// HTTP keys sends an absolute-form request that is never answered with credentials, so it fails
/// closed. The last test pins that down.
///
/// The client uses a host name that is not a loopback address, because Apple's networking may skip
/// a proxy for localhost. The name resolves to the local Centrifugo, so a client that bypassed the
/// proxy would connect; the "not connected" checks rely on that.
///
/// The suite needs `CENTRIFUGE_PROXY_TEST_HOST` set to that host name, and `/etc/hosts` mapping it
/// to 127.0.0.1 (ci.yml does both). Without the variable every test returns early.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct ProxyAuthIntegrationTests {

    /// How the credentials provider answers the proxy's challenge.
    private enum CredentialMode {
        case right
        case wrongPassword
        case providerReturnsNil
    }

    /// One way to route the client through the proxy.
    private struct Route {
        let endpointScheme: String
        let upstreamPort: UInt16
        let tlsSkipVerify: Bool
        /// Sets the proxy on the session configuration, given the proxy's port.
        let configure: (URLSessionConfiguration, UInt16) -> Void
    }

    private struct Outcome {
        let connected: Bool
        let providerCalls: Int
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
    private static func dictionaryConfigure(_ configuration: URLSessionConfiguration, _ proxyPort: UInt16) {
        let proxyDictionary: [AnyHashable: Any] = [
            kCFNetworkProxiesHTTPEnable as String: 1,
            kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPPort as String: Int(proxyPort),
            "HTTPSEnable": 1,
            "HTTPSProxy": "127.0.0.1",
            "HTTPSPort": Int(proxyPort),
        ]
        configuration.connectionProxyDictionary = proxyDictionary
    }

    /// `wss://` on 8443 behind the HTTPS keys: the CONNECT is where Apple asks for credentials.
    private static func secureDictionaryRoute() -> Route {
        return Route(
            endpointScheme: "wss",
            upstreamPort: 8443,
            tlsSkipVerify: true,
            configure: { configuration, proxyPort in
                dictionaryConfigure(configuration, proxyPort)
            }
        )
    }

    /// `ws://` on 8000 behind the HTTP and HTTPS keys: the platform never asks for credentials.
    private static func plainDictionaryRoute() -> Route {
        return Route(
            endpointScheme: "ws",
            upstreamPort: 8000,
            tlsSkipVerify: false,
            configure: { configuration, proxyPort in
                dictionaryConfigure(configuration, proxyPort)
            }
        )
    }

    /// `ws://` on 8000 behind `proxyConfigurations` (iOS 17 / macOS 14): a CONNECT, with credentials asked.
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    private static func proxyConfigurationRoute() -> Route {
        return Route(
            endpointScheme: "ws",
            upstreamPort: 8000,
            tlsSkipVerify: false,
            configure: { configuration, proxyPort in
                let proxyEndpoint: NWEndpoint = NWEndpoint.hostPort(
                    host: "127.0.0.1", port: NWEndpoint.Port(rawValue: proxyPort)!)
                configuration.proxyConfigurations = [ProxyConfiguration(httpCONNECTProxy: proxyEndpoint)]
            }
        )
    }

    /// Starts a proxy and a client on `route`, and runs them for `timeout` seconds. With
    /// `waitForConnect`, it returns as soon as the client connects, or after `timeout`.
    private func runCase(
        _ route: Route,
        _ mode: CredentialMode,
        host: String,
        timeout: TimeInterval,
        waitForConnect: Bool
    ) async throws -> Outcome {
        let user: String = "user-" + UUID().uuidString.prefix(8)
        let password: String = "pw-" + UUID().uuidString

        let proxy: AuthProxy = AuthProxy(user: user, password: password, upstreamPort: route.upstreamPort)
        try proxy.start()
        defer { proxy.stop() }

        let providerCalls: CallCounter = CallCounter()
        let connected: Expectation = Expectation("connected through the proxy")
        let watcher: ConnectWatcher = ConnectWatcher(connected: connected)

        let configurationProvider: URLSessionConfigurationProvider = {
            let configuration: URLSessionConfiguration = URLSessionConfiguration.ephemeral
            route.configure(configuration, proxy.port)
            return configuration
        }
        let credentialsProvider: CentrifugeProxyCredentialsProvider = {
            providerCalls.increment()
            switch mode {
                case .right:
                    return CentrifugeProxyCredentials(user: user, password: password)

                case .wrongPassword:
                    return CentrifugeProxyCredentials(user: user, password: "wrong-" + password)

                case .providerReturnsNil:
                    return nil
            }
        }
        let config: CentrifugeClientConfig = CentrifugeClientConfig(
            tlsSkipVerify: route.tlsSkipVerify,
            useNativeWebSocket: true,
            urlSessionConfigurationProvider: configurationProvider,
            proxyCredentialsProvider: credentialsProvider
        )
        let client: CentrifugeClient = CentrifugeClient(
            endpoint: "\(route.endpointScheme)://\(host):\(route.upstreamPort)/connection/websocket",
            config: config,
            delegate: watcher
        )
        client.connect()
        defer { client.disconnect() }

        if waitForConnect {
            await fulfillment(of: connected, within: timeout)
        } else {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        }

        print("ProxyAuthIntegrationTests: proxy saw authorities \(proxy.authorities), forms \(proxy.forms)")
        return Outcome(connected: connected.fulfillmentCount > 0, providerCalls: providerCalls.value, proxy: proxy)
    }

    /// The checks of a client that must connect through the proxy with the right credentials.
    private func expectConnectedThroughProxy(_ outcome: Outcome, authority: String) {
        #expect(outcome.connected, "not connected; rejections: \(outcome.proxy.rejections)")
        #expect(outcome.proxy.connects + outcome.proxy.forwards >= 1)
        #expect(outcome.proxy.rejected >= 1, "rejections: \(outcome.proxy.rejections)")
        #expect(outcome.proxy.authorities.contains(authority), "authorities: \(outcome.proxy.authorities)")
        #expect(outcome.providerCalls >= 1)
    }

    /// The checks of a client that must not connect, and must not get around the proxy.
    private func expectNotConnected(_ outcome: Outcome) {
        #expect(!outcome.connected, "connected without the right credentials")
        #expect(outcome.proxy.connects + outcome.proxy.forwards == 0)
        #expect(outcome.proxy.rejected >= 1, "rejections: \(outcome.proxy.rejections)")
    }

    // MARK: Proxy configuration route (ws://, CONNECT, iOS 17 / macOS 14)

    @Test func proxyConfigurationRightCredentialsConnect() async throws {
        guard #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) else { return }
        guard let host = ProxyAuthIntegrationTests.proxyHost() else { return }
        let outcome: Outcome = try await runCase(
            ProxyAuthIntegrationTests.proxyConfigurationRoute(), .right,
            host: host, timeout: 10, waitForConnect: true
        )
        expectConnectedThroughProxy(outcome, authority: "\(host):8000")
    }

    @Test func proxyConfigurationWrongPasswordNeverConnects() async throws {
        guard #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) else { return }
        guard let host = ProxyAuthIntegrationTests.proxyHost() else { return }
        let outcome: Outcome = try await runCase(
            ProxyAuthIntegrationTests.proxyConfigurationRoute(), .wrongPassword,
            host: host, timeout: 5, waitForConnect: false
        )
        expectNotConnected(outcome)
    }

    @Test func proxyConfigurationNilProviderNeverConnects() async throws {
        guard #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) else { return }
        guard let host = ProxyAuthIntegrationTests.proxyHost() else { return }
        let outcome: Outcome = try await runCase(
            ProxyAuthIntegrationTests.proxyConfigurationRoute(), .providerReturnsNil,
            host: host, timeout: 5, waitForConnect: false
        )
        expectNotConnected(outcome)
    }

    // MARK: Proxy dictionary, secure route (wss://, CONNECT through the HTTPS keys)

    @Test func secureDictionaryRightCredentialsConnect() async throws {
        guard let host = ProxyAuthIntegrationTests.proxyHost() else { return }
        let outcome: Outcome = try await runCase(
            ProxyAuthIntegrationTests.secureDictionaryRoute(), .right,
            host: host, timeout: 10, waitForConnect: true
        )
        expectConnectedThroughProxy(outcome, authority: "\(host):8443")
    }

    @Test func secureDictionaryWrongPasswordNeverConnects() async throws {
        guard let host = ProxyAuthIntegrationTests.proxyHost() else { return }
        let outcome: Outcome = try await runCase(
            ProxyAuthIntegrationTests.secureDictionaryRoute(), .wrongPassword,
            host: host, timeout: 5, waitForConnect: false
        )
        expectNotConnected(outcome)
    }

    @Test func secureDictionaryNilProviderNeverConnects() async throws {
        guard let host = ProxyAuthIntegrationTests.proxyHost() else { return }
        let outcome: Outcome = try await runCase(
            ProxyAuthIntegrationTests.secureDictionaryRoute(), .providerReturnsNil,
            host: host, timeout: 5, waitForConnect: false
        )
        expectNotConnected(outcome)
    }

    // MARK: Platform limitation

    @Test func plainWebSocketThroughProxyDictionaryNeverGoesDirect() async throws {
        // Apple does not answer a 407 to an absolute-form proxy request, so the task fails at the
        // proxy. This route fails closed instead of leaking: the client may not connect except
        // through an authenticated request, and the proxy must have refused it.
        guard let host = ProxyAuthIntegrationTests.proxyHost() else { return }
        let outcome: Outcome = try await runCase(
            ProxyAuthIntegrationTests.plainDictionaryRoute(), .right,
            host: host, timeout: 5, waitForConnect: false
        )
        #expect(outcome.proxy.rejected >= 1, "rejections: \(outcome.proxy.rejections)")
        #expect(!outcome.connected || outcome.proxy.connects + outcome.proxy.forwards >= 1,
                "connected without an authenticated proxy request")
    }
}
