import Foundation
import Testing
@testable import SwiftCentrifuge

/// Unit tests for the transport of an RPC pool: its connections take the main client's transport, its redirect fetches
/// take the transport settings of `urlSession` or of the main client's provider, and the fetches answer the proxy with the
/// main client's credentials. No network: the pool is only made, and its parts are called directly.
@Suite(.timeLimit(.minutes(1)))
struct RpcPoolTransportTests {

    private final class DummySender: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
    }

    private func makeProxyChallenge() -> URLAuthenticationChallenge {
        let space: URLProtectionSpace = URLProtectionSpace(
            proxyHost: "127.0.0.1", port: 3128, type: NSURLProtectionSpaceHTTPProxy,
            realm: "test", authenticationMethod: NSURLAuthenticationMethodHTTPBasic
        )
        return URLAuthenticationChallenge(
            protectionSpace: space, proposedCredential: nil,
            previousFailureCount: 0, failureResponse: nil, error: nil, sender: DummySender()
        )
    }

    private func makeOptions(urlSession: URLSession? = nil) -> CentrifugeRpcPoolOptions {
        return CentrifugeRpcPoolOptions(
            endpoints: { (_: String) -> [String] in
                return ["ws://127.0.0.1:1/connection/websocket"]
            },
            urlSession: urlSession
        )
    }

    /// The proxy dictionary of a configuration, read as a string for one key.
    private func proxyHost(_ configuration: URLSessionConfiguration) -> String? {
        let dictionary: [AnyHashable: Any]? = configuration.connectionProxyDictionary
        let value: Any? = dictionary?["HTTPSProxy"]
        return value as? String
    }

    @Test func poolConnectionsTakeTheMainTransport() {
        let marker: URLSessionConfiguration = URLSessionConfiguration.ephemeral
        marker.timeoutIntervalForRequest = 123
        var handlerCalls: Int = 0
        let main: CentrifugeClient = CentrifugeClient(
            endpoint: "ws://127.0.0.1:1/connection/websocket",
            config: CentrifugeClientConfig(
                tlsSkipVerify: true,
                useNativeWebSocket: true,
                urlSessionConfigurationProvider: { () -> URLSessionConfiguration in
                    return marker
                },
                tlsChallengeHandler: { (_: URLAuthenticationChallenge, completion: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) -> Void in
                    handlerCalls += 1
                    completion(.cancelAuthenticationChallenge, nil)
                },
                proxyCredentialsProvider: { () -> CentrifugeProxyCredentials? in
                    return CentrifugeProxyCredentials(user: "pool-user", password: "pool-pass")
                }
            )
        )
        let pool: CentrifugeRpcPool = CentrifugeRpcPool(main: main, options: makeOptions())

        let settings: CentrifugeClientConfig = pool.connectionConfig
        #expect(settings.useNativeWebSocket)
        #expect(settings.tlsSkipVerify)
        #expect(settings.urlSessionConfigurationProvider?().timeoutIntervalForRequest == 123)
        #expect(settings.proxyCredentialsProvider?()?.user == "pool-user")
        #expect(settings.proxyCredentialsProvider?()?.password == "pool-pass")

        var disposition: URLSession.AuthChallengeDisposition?
        settings.tlsChallengeHandler?(makeProxyChallenge()) { (value: URLSession.AuthChallengeDisposition, _: URLCredential?) -> Void in
            disposition = value
        }
        #expect(disposition == .cancelAuthenticationChallenge)
        #expect(handlerCalls == 1)
    }

    @Test func poolWithDefaultMainKeepsStarscreamAndNoProviders() {
        let main: CentrifugeClient = CentrifugeClient(
            endpoint: "ws://127.0.0.1:1/connection/websocket",
            config: CentrifugeClientConfig()
        )
        let pool: CentrifugeRpcPool = CentrifugeRpcPool(main: main, options: makeOptions())

        let settings: CentrifugeClientConfig = pool.connectionConfig
        #expect(!settings.useNativeWebSocket)
        #expect(!settings.tlsSkipVerify)
        #expect(settings.urlSessionConfigurationProvider == nil)
        #expect(settings.proxyCredentialsProvider == nil)
        #expect(settings.tlsChallengeHandler == nil)
    }

    private func isConfigurationError(_ error: CentrifugeError?) -> Bool {
        guard let error: CentrifugeError = error else {
            return false
        }
        if case .configurationError = error {
            return true
        }
        return false
    }

    @Test func nativeTransportNeedsAvailableWebSocketTask() {
        let refused: CentrifugeError? = poolTransportError(useNativeWebSocket: true, nativeAvailable: false)
        #expect(isConfigurationError(refused))
        #expect(poolTransportError(useNativeWebSocket: true, nativeAvailable: true) == nil)
        #expect(poolTransportError(useNativeWebSocket: false, nativeAvailable: false) == nil)
    }

    @Test func redirectTakesTheGivenSessionsProxy() {
        let given: URLSessionConfiguration = URLSessionConfiguration.ephemeral
        given.connectionProxyDictionary = ["HTTPSProxy": "10.0.0.1"]
        let source: RpcPoolRedirectSource = redirectSource(
            urlSession: URLSession(configuration: given),
            mainProvider: { () -> URLSessionConfiguration in
                let other: URLSessionConfiguration = URLSessionConfiguration.ephemeral
                other.connectionProxyDictionary = ["HTTPSProxy": "10.9.9.9"]
                return other
            }
        )
        #expect(!source.perFetch)
        #expect(proxyHost(source.configuration()) == "10.0.0.1")
    }

    @Test func redirectAsksMainProviderForEachFetch() {
        var proxyNumber: Int = 0
        let source: RpcPoolRedirectSource = redirectSource(
            urlSession: nil,
            mainProvider: { () -> URLSessionConfiguration in
                proxyNumber += 1
                let configuration: URLSessionConfiguration = URLSessionConfiguration.ephemeral
                configuration.connectionProxyDictionary = ["HTTPSProxy": "proxy-\(proxyNumber)"]
                configuration.httpAdditionalHeaders = ["Authorization": "app-secret"]
                configuration.urlCredentialStorage = URLCredentialStorage.shared
                return configuration
            }
        )
        #expect(source.perFetch)

        let first: URLSessionConfiguration = source.configuration()
        let second: URLSessionConfiguration = source.configuration()
        #expect(proxyHost(first) == "proxy-1")
        #expect(proxyHost(second) == "proxy-2")
        // Headers and stored credentials of the provider's session are never copied.
        #expect(first.httpAdditionalHeaders == nil)
        #expect(first.urlCredentialStorage == nil)
    }

    @Test func redirectWithNothingGivenIsEphemeralWithoutProxy() {
        let source: RpcPoolRedirectSource = redirectSource(urlSession: nil, mainProvider: nil)
        #expect(!source.perFetch)
        let configuration: URLSessionConfiguration = source.configuration()
        #expect(configuration.connectionProxyDictionary == nil)
        #expect(configuration.httpAdditionalHeaders == nil)
    }

    @Test func fetchDelegateAnswersProxyWithMainCredentials() {
        let delegate: RpcPoolFetchDelegate = RpcPoolFetchDelegate(proxyCredentialsProvider: { () -> CentrifugeProxyCredentials? in
            return CentrifugeProxyCredentials(user: "main-user", password: "main-pass")
        })
        let task: URLSessionTask = URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:1/")!)

        var disposition: URLSession.AuthChallengeDisposition?
        var credential: URLCredential?
        delegate.urlSession(URLSession.shared, task: task, didReceive: makeProxyChallenge()) {
            (value: URLSession.AuthChallengeDisposition, received: URLCredential?) -> Void in
            disposition = value
            credential = received
        }
        #expect(disposition == .useCredential)
        #expect(credential?.user == "main-user")
        #expect(credential?.password == "main-pass")
    }

    @Test func fetchDelegateCancelsProxyChallengeWithoutCredentials() {
        let delegate: RpcPoolFetchDelegate = RpcPoolFetchDelegate(proxyCredentialsProvider: { () -> CentrifugeProxyCredentials? in
            return nil
        })
        let task: URLSessionTask = URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:1/")!)

        var disposition: URLSession.AuthChallengeDisposition?
        delegate.urlSession(URLSession.shared, task: task, didReceive: makeProxyChallenge()) {
            (value: URLSession.AuthChallengeDisposition, _: URLCredential?) -> Void in
            disposition = value
        }
        #expect(disposition == .cancelAuthenticationChallenge)
    }
}
