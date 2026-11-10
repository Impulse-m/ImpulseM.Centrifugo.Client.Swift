import Foundation
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

/// In CI the proxy suites must run; a run that lost the variable fails here instead of skipping them unseen.
@Suite struct ProxyTestEnvironmentTests {
    @Test func proxySuitesRunInCI() {
        let continuousIntegration: String? = ProcessInfo.processInfo.environment["CI"]
        guard continuousIntegration == "true" else {
            return
        }
        #expect(proxyTestHost() != nil, "CENTRIFUGE_PROXY_TEST_HOST is not set in CI, so the proxy suites were skipped")
    }
}
