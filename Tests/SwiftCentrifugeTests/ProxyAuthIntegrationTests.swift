import Foundation
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

    private struct Outcome {
        let connected: Bool
        let providerCalls: Int
        let proxy: AuthProxy
    }

    /// Starts a proxy and a client on `route`, and runs them for `timeout` seconds. With
    /// `waitForConnect`, it returns as soon as the client connects, or after `timeout`.
    private func runCase(
        _ route: ProxyRoute,
        _ mode: ProxyCredentialMode,
        host: String,
        timeout: TimeInterval,
        waitForConnect: Bool
    ) async throws -> Outcome {
        let user: String = "user-" + UUID().uuidString.prefix(8)
        let password: String = "pw-" + UUID().uuidString

        let proxy: AuthProxy = AuthProxy(user: user, password: password, upstreamPort: route.serverPort)
        try proxy.start()
        defer { proxy.stop() }

        // The provider runs on the client's queue, so the count is shared through a locked box.
        let providerCalls: LockedBox<Int> = LockedBox<Int>(0)
        let connected: Expectation = Expectation("connected through the proxy")
        let watcher: ProxyConnectWatcher = ProxyConnectWatcher(connected: connected)

        let configurationProvider: URLSessionConfigurationProvider = { () -> URLSessionConfiguration in
            return route.configuration(proxy.port)
        }
        let credentialsProvider: CentrifugeProxyCredentialsProvider = {
            providerCalls.update { (value: inout Int) -> Void in
                value += 1
            }
            return proxyCredentials(mode: mode, user: user, password: password)
        }
        let config: CentrifugeClientConfig = CentrifugeClientConfig(
            tlsSkipVerify: route.tlsSkipVerify,
            useNativeWebSocket: true,
            urlSessionConfigurationProvider: configurationProvider,
            proxyCredentialsProvider: credentialsProvider
        )
        let client: CentrifugeClient = CentrifugeClient(
            endpoint: "\(route.scheme)://\(host):\(route.serverPort)/connection/websocket",
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
            proxyConfigurationsProxyRoute(), .right,
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
            proxyConfigurationsProxyRoute(), .wrongPassword,
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
            proxyConfigurationsProxyRoute(), .providerReturnsNil,
            host: host, timeout: 5, waitForConnect: false
        )
        expectNotConnected(outcome)
    }

    // MARK: Proxy dictionary, secure route (wss://, CONNECT through the HTTPS keys)

    @Test func secureDictionaryRightCredentialsConnect() async throws {
        let host: String = try #require(proxyTestHost())
        let outcome: Outcome = try await runCase(
            secureDictionaryProxyRoute(), .right,
            host: host, timeout: 10, waitForConnect: true
        )
        expectConnectedThroughProxy(outcome, authority: "\(host):8443")
    }

    @Test func secureDictionaryWrongPasswordNeverConnects() async throws {
        let host: String = try #require(proxyTestHost())
        let outcome: Outcome = try await runCase(
            secureDictionaryProxyRoute(), .wrongPassword,
            host: host, timeout: 5, waitForConnect: false
        )
        expectNotConnected(outcome)
    }

    @Test func secureDictionaryNilProviderNeverConnects() async throws {
        let host: String = try #require(proxyTestHost())
        let outcome: Outcome = try await runCase(
            secureDictionaryProxyRoute(), .providerReturnsNil,
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
            plainDictionaryProxyRoute(), .right,
            host: host, timeout: 5, waitForConnect: false
        )
        #expect(outcome.proxy.rejected >= 1, "rejections: \(outcome.proxy.rejections)")
        #expect(!outcome.connected || outcome.proxy.connects + outcome.proxy.forwards >= 1,
                "connected without an authenticated proxy request")
    }
}
