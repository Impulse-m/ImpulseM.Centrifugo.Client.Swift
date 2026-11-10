import Foundation
import Network
import Testing
@testable import SwiftCentrifuge

/// The host name the proxy suites connect to. It is not a loopback address, because Apple's networking may skip a
/// proxy for localhost. The name resolves to the local Centrifugo, so a client that went around the proxy would still
/// connect. CI sets the variable and maps the name to 127.0.0.1 in /etc/hosts.
func proxyTestHost() -> String? {
    let value: String? = ProcessInfo.processInfo.environment["CENTRIFUGE_PROXY_TEST_HOST"]
    return value?.isEmpty == false ? value : nil
}

/// The HTTP and HTTPS keys of `connectionProxyDictionary`, both pointing at the proxy on 127.0.0.1.
func proxyDictionary(proxyPort: UInt16) -> [AnyHashable: Any] {
    let dictionary: [AnyHashable: Any] = [
        kCFNetworkProxiesHTTPEnable as String: 1,
        kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
        kCFNetworkProxiesHTTPPort as String: Int(proxyPort),
        "HTTPSEnable": 1,
        "HTTPSProxy": "127.0.0.1",
        "HTTPSPort": Int(proxyPort),
    ]
    return dictionary
}

/// Fulfills an expectation once the client is connected.
final class ProxyConnectWatcher: CentrifugeClientDelegate, @unchecked Sendable {
    let connected: Expectation

    init(connected: Expectation) {
        self.connected = connected
    }

    func onConnected(_ client: CentrifugeClient, _ event: CentrifugeConnectedEvent) {
        connected.fulfill()
    }
}

/// A challenge sender that ignores every answer, for challenges that the tests only inspect or hand to the code under test.
final class ChallengeSenderStub: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}

    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}

    func cancel(_ challenge: URLAuthenticationChallenge) {}
}

/// A proxy challenge on port 3128 of 127.0.0.1, with the given scheme and previous failure count.
func makeProxyChallenge(
    authMethod: String = NSURLAuthenticationMethodHTTPBasic,
    previousFailureCount: Int = 0
) -> URLAuthenticationChallenge {
    let space: URLProtectionSpace = URLProtectionSpace(
        proxyHost: "127.0.0.1",
        port: 3128,
        type: NSURLProtectionSpaceHTTPProxy,
        realm: "test",
        authenticationMethod: authMethod
    )
    return URLAuthenticationChallenge(
        protectionSpace: space,
        proposedCredential: nil,
        previousFailureCount: previousFailureCount,
        failureResponse: nil,
        error: nil,
        sender: ChallengeSenderStub()
    )
}

/// How a credentials provider of the proxy tests answers the proxy's challenge.
enum ProxyCredentialMode {
    case right
    case wrongPassword
    case providerReturnsNil
}

/// The credentials that a provider of the proxy tests returns for `mode`: the right ones, the right user with a wrong
/// password, or none.
func proxyCredentials(mode: ProxyCredentialMode, user: String, password: String) -> CentrifugeProxyCredentials? {
    switch mode {
        case .right:
            return CentrifugeProxyCredentials(user: user, password: password)

        case .wrongPassword:
            return CentrifugeProxyCredentials(user: user, password: "wrong-" + password)

        case .providerReturnsNil:
            return nil
    }
}

/// One way to route a client through the test proxy.
struct ProxyRoute {
    /// The scheme of the endpoint, `ws` or `wss`.
    let scheme: String
    /// The port of the server. The test proxy sends every request there.
    let serverPort: UInt16
    let tlsSkipVerify: Bool
    /// The session configuration of the client, given the proxy's port.
    let configuration: (UInt16) -> URLSessionConfiguration
}

/// `wss://` on 8443 behind the HTTPS keys: the CONNECT is where Apple asks for credentials.
func secureDictionaryProxyRoute() -> ProxyRoute {
    return ProxyRoute(
        scheme: "wss",
        serverPort: 8443,
        tlsSkipVerify: true,
        configuration: { (proxyPort: UInt16) -> URLSessionConfiguration in
            let configuration: URLSessionConfiguration = URLSessionConfiguration.ephemeral
            configuration.connectionProxyDictionary = proxyDictionary(proxyPort: proxyPort)
            return configuration
        }
    )
}

/// `ws://` on 8000 behind the HTTP and HTTPS keys: the platform never asks for credentials.
func plainDictionaryProxyRoute() -> ProxyRoute {
    return ProxyRoute(
        scheme: "ws",
        serverPort: 8000,
        tlsSkipVerify: false,
        configuration: { (proxyPort: UInt16) -> URLSessionConfiguration in
            let configuration: URLSessionConfiguration = URLSessionConfiguration.ephemeral
            configuration.connectionProxyDictionary = proxyDictionary(proxyPort: proxyPort)
            return configuration
        }
    )
}

/// `ws://` on 8000 behind `proxyConfigurations` (iOS 17 / macOS 14): a CONNECT, with credentials asked.
@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
func proxyConfigurationsProxyRoute() -> ProxyRoute {
    return ProxyRoute(
        scheme: "ws",
        serverPort: 8000,
        tlsSkipVerify: false,
        configuration: { (proxyPort: UInt16) -> URLSessionConfiguration in
            let configuration: URLSessionConfiguration = URLSessionConfiguration.ephemeral
            let proxyEndpoint: NWEndpoint = NWEndpoint.hostPort(
                host: "127.0.0.1",
                port: NWEndpoint.Port(rawValue: proxyPort)!
            )
            configuration.proxyConfigurations = [ProxyConfiguration(httpCONNECTProxy: proxyEndpoint)]
            return configuration
        }
    )
}
