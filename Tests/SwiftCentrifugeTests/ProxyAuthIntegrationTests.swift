import Foundation
import Testing
@testable import SwiftCentrifuge

/// Integration tests for the native WebSocket transport through an HTTP proxy that asks for Basic
/// credentials (`AuthProxy`), against the real Centrifugo on localhost:8000.
///
/// The client uses a host name that is not a loopback address. Apple's networking may skip a proxy
/// for `localhost` and `127.0.0.1`, which would look like a proxy that is ignored. The host name
/// resolves to the local Centrifugo, so a client that bypassed the proxy would connect. The
/// "no direct fallback" checks rely on that.
///
/// The suite needs `CENTRIFUGE_PROXY_TEST_HOST` set to that host name, and `/etc/hosts` mapping it
/// to 127.0.0.1 (ci.yml does both). Without the variable every test returns early.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct ProxyAuthIntegrationTests {

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

    private func makeClient(
        host: String,
        proxyPort: UInt16,
        credentialsProvider: CentrifugeProxyCredentialsProvider?,
        watcher: ConnectWatcher
    ) -> CentrifugeClient {
        let configurationProvider: URLSessionConfigurationProvider = {
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

        let config: CentrifugeClientConfig = CentrifugeClientConfig(
            useNativeWebSocket: true,
            urlSessionConfigurationProvider: configurationProvider,
            proxyCredentialsProvider: credentialsProvider
        )
        return CentrifugeClient(
            endpoint: "ws://\(host):8000/connection/websocket",
            config: config,
            delegate: watcher
        )
    }

    @Test func rightCredentialsReachConnectedThroughProxy() async throws {
        guard let host = ProxyAuthIntegrationTests.proxyHost() else { return }
        let user: String = "user-" + UUID().uuidString.prefix(8)
        let password: String = "pw-" + UUID().uuidString

        let proxy = AuthProxy(user: user, password: password, upstreamPort: 8000)
        try proxy.start()
        defer { proxy.stop() }

        let providerCalls: CallCounter = CallCounter()
        let connected: Expectation = Expectation("connected through the proxy")
        let watcher: ConnectWatcher = ConnectWatcher(connected: connected)
        let client: CentrifugeClient = makeClient(
            host: host,
            proxyPort: proxy.port,
            credentialsProvider: {
                providerCalls.increment()
                return CentrifugeProxyCredentials(user: user, password: password)
            },
            watcher: watcher
        )
        client.connect()
        defer { client.disconnect() }

        await fulfillment(of: connected, within: 10)

        print("ProxyAuthIntegrationTests: proxy saw forms \(proxy.forms), authorities \(proxy.authorities)")
        #expect(proxy.connects + proxy.forwards >= 1)
        #expect(proxy.rejected >= 1)
        #expect(proxy.authorities.contains("\(host):8000"))
        #expect(providerCalls.value >= 1)
    }

    @Test func wrongPasswordDoesNotConnectAndNeverFallsBackToDirect() async throws {
        guard let host = ProxyAuthIntegrationTests.proxyHost() else { return }
        let user: String = "user-" + UUID().uuidString.prefix(8)
        let password: String = "pw-" + UUID().uuidString

        let proxy = AuthProxy(user: user, password: password, upstreamPort: 8000)
        try proxy.start()
        defer { proxy.stop() }

        let connected: Expectation = Expectation("connected with a wrong password")
        connected.isInverted = true
        let watcher: ConnectWatcher = ConnectWatcher(connected: connected)
        let client: CentrifugeClient = makeClient(
            host: host,
            proxyPort: proxy.port,
            credentialsProvider: {
                CentrifugeProxyCredentials(user: user, password: "wrong-" + password)
            },
            watcher: watcher
        )
        client.connect()
        defer { client.disconnect() }

        await fulfillment(of: connected, within: 5)

        #expect(proxy.connects + proxy.forwards == 0)
        #expect(proxy.rejected >= 1)
    }

    @Test func providerReturningNilDoesNotConnectAndNeverFallsBackToDirect() async throws {
        guard let host = ProxyAuthIntegrationTests.proxyHost() else { return }
        let user: String = "user-" + UUID().uuidString.prefix(8)
        let password: String = "pw-" + UUID().uuidString

        let proxy = AuthProxy(user: user, password: password, upstreamPort: 8000)
        try proxy.start()
        defer { proxy.stop() }

        let connected: Expectation = Expectation("connected with no credentials")
        connected.isInverted = true
        let watcher: ConnectWatcher = ConnectWatcher(connected: connected)
        let client: CentrifugeClient = makeClient(
            host: host,
            proxyPort: proxy.port,
            credentialsProvider: { nil },
            watcher: watcher
        )
        client.connect()
        defer { client.disconnect() }

        await fulfillment(of: connected, within: 5)

        #expect(proxy.connects + proxy.forwards == 0)
        #expect(proxy.rejected >= 1)
    }
}
