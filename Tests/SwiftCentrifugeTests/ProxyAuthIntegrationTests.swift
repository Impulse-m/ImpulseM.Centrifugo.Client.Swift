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
/// to 127.0.0.1 (ci.yml does both). Without the variable the suite is disabled and reported as
/// skipped, and `ProxyTestEnvironmentTests` fails a CI run without it.
@Suite(.serialized, .timeLimit(.minutes(2)), .enabled(if: proxyTestHost() != nil, "CENTRIFUGE_PROXY_TEST_HOST is not set"))
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

    /// `wss://` on 8443 behind the HTTPS keys: the CONNECT is where Apple asks for credentials.
    private static func secureDictionaryRoute() -> Route {
        return Route(
            endpointScheme: "wss",
            upstreamPort: 8443,
            tlsSkipVerify: true,
            configure: { configuration, proxyPort in
                configuration.connectionProxyDictionary = proxyDictionary(proxyPort: proxyPort)
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
                configuration.connectionProxyDictionary = proxyDictionary(proxyPort: proxyPort)
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

        // The provider runs on the client's queue, so the count is shared through a locked box.
        let providerCalls: LockedBox<Int> = LockedBox<Int>(0)
        let connected: Expectation = Expectation("connected through the proxy")
        let watcher: ProxyConnectWatcher = ProxyConnectWatcher(connected: connected)

        let configurationProvider: URLSessionConfigurationProvider = {
            let configuration: URLSessionConfiguration = URLSessionConfiguration.ephemeral
            route.configure(configuration, proxy.port)
            return configuration
        }
        let credentialsProvider: CentrifugeProxyCredentialsProvider = {
            providerCalls.update { (value: inout Int) -> Void in
                value += 1
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

        return Outcome(connected: connected.fulfillmentCount > 0, providerCalls: providerCalls.current, proxy: proxy)
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
        guard #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) else {
            return
        }
        let host: String = try #require(proxyTestHost())
        let outcome: Outcome = try await runCase(
            ProxyAuthIntegrationTests.proxyConfigurationRoute(), .right,
            host: host, timeout: 10, waitForConnect: true
        )
        expectConnectedThroughProxy(outcome, authority: "\(host):8000")
    }

    @Test func proxyConfigurationWrongPasswordNeverConnects() async throws {
        guard #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) else {
            return
        }
        let host: String = try #require(proxyTestHost())
        let outcome: Outcome = try await runCase(
            ProxyAuthIntegrationTests.proxyConfigurationRoute(), .wrongPassword,
            host: host, timeout: 5, waitForConnect: false
        )
        expectNotConnected(outcome)
    }

    @Test func proxyConfigurationNilProviderNeverConnects() async throws {
        guard #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) else {
            return
        }
        let host: String = try #require(proxyTestHost())
        let outcome: Outcome = try await runCase(
            ProxyAuthIntegrationTests.proxyConfigurationRoute(), .providerReturnsNil,
            host: host, timeout: 5, waitForConnect: false
        )
        expectNotConnected(outcome)
    }

    // MARK: Proxy dictionary, secure route (wss://, CONNECT through the HTTPS keys)

    @Test func secureDictionaryRightCredentialsConnect() async throws {
        let host: String = try #require(proxyTestHost())
        let outcome: Outcome = try await runCase(
            ProxyAuthIntegrationTests.secureDictionaryRoute(), .right,
            host: host, timeout: 10, waitForConnect: true
        )
        expectConnectedThroughProxy(outcome, authority: "\(host):8443")
    }

    @Test func secureDictionaryWrongPasswordNeverConnects() async throws {
        let host: String = try #require(proxyTestHost())
        let outcome: Outcome = try await runCase(
            ProxyAuthIntegrationTests.secureDictionaryRoute(), .wrongPassword,
            host: host, timeout: 5, waitForConnect: false
        )
        expectNotConnected(outcome)
    }

    @Test func secureDictionaryNilProviderNeverConnects() async throws {
        let host: String = try #require(proxyTestHost())
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
        let host: String = try #require(proxyTestHost())
        let outcome: Outcome = try await runCase(
            ProxyAuthIntegrationTests.plainDictionaryRoute(), .right,
            host: host, timeout: 5, waitForConnect: false
        )
        #expect(outcome.proxy.rejected >= 1, "rejections: \(outcome.proxy.rejections)")
        #expect(!outcome.connected || outcome.proxy.connects + outcome.proxy.forwards >= 1,
                "connected without an authenticated proxy request")
    }
}
