import Foundation
import Testing
@testable import SwiftCentrifuge

/// Unit tests for the Basic credentials of an HTTP proxy on the native WebSocket transport
/// (`CentrifugeClientConfig.proxyCredentialsProvider`).
///
/// A proxy's Basic challenge is task-level, so it reaches
/// `urlSession(_:task:didReceive:completionHandler:)`. These tests call that method with a synthetic
/// challenge. The session-level method is checked too, to show the TLS handling is unchanged.
@Suite(.timeLimit(.minutes(1)))
struct NativeWebSocketProxyAuthTests {

    private final class DummySender: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
    }

    /// A thread-safe counter, for how many times the provider was called.
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

    private func makeProxyChallenge(
        authMethod: String = NSURLAuthenticationMethodHTTPBasic,
        previousFailureCount: Int = 0
    ) -> URLAuthenticationChallenge {
        let space = URLProtectionSpace(
            proxyHost: "127.0.0.1", port: 3128, type: NSURLProtectionSpaceHTTPProxy,
            realm: "test", authenticationMethod: authMethod
        )
        return URLAuthenticationChallenge(
            protectionSpace: space, proposedCredential: nil,
            previousFailureCount: previousFailureCount, failureResponse: nil, error: nil, sender: DummySender()
        )
    }

    private func makeServerChallenge(authMethod: String) -> URLAuthenticationChallenge {
        let space = URLProtectionSpace(
            host: "example.com", port: 443, protocol: "https",
            realm: nil, authenticationMethod: authMethod
        )
        return URLAuthenticationChallenge(
            protectionSpace: space, proposedCredential: nil,
            previousFailureCount: 0, failureResponse: nil, error: nil, sender: DummySender()
        )
    }

    @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
    private func makeSocket(
        tlsChallengeHandler: CentrifugeTLSChallengeHandler? = nil,
        proxyCredentialsProvider: CentrifugeProxyCredentialsProvider?,
        queue: DispatchQueue
    ) -> NativeWebSocket {
        return NativeWebSocket(
            request: URLRequest(url: URL(string: "wss://example.com/connection/websocket")!),
            urlSessionConfigurationProvider: nil,
            tlsSkipVerify: false,
            tlsChallengeHandler: tlsChallengeHandler,
            proxyCredentialsProvider: proxyCredentialsProvider,
            queue: queue,
            log: EmptyLogger.instance
        )
    }

    /// Calls the task-level delegate method on the socket's queue and returns the answer.
    @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
    private func answerTaskChallenge(
        _ ws: NativeWebSocket,
        _ queue: DispatchQueue,
        _ challenge: URLAuthenticationChallenge
    ) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let task: URLSessionTask = URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:1/")!)
        var answer: (URLSession.AuthChallengeDisposition, URLCredential?)?
        queue.sync {
            ws.urlSession(URLSession.shared, task: task, didReceive: challenge) { disposition, credential in
                answer = (disposition, credential)
            }
        }
        guard let answer = answer else {
            Issue.record("the completion handler was not called")
            return (.performDefaultHandling, nil)
        }
        return answer
    }

    /// Calls the session-level delegate method on the socket's queue and returns the answer.
    @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
    private func answerSessionChallenge(
        _ ws: NativeWebSocket,
        _ queue: DispatchQueue,
        _ challenge: URLAuthenticationChallenge
    ) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        var answer: (URLSession.AuthChallengeDisposition, URLCredential?)?
        queue.sync {
            ws.urlSession(URLSession.shared, didReceive: challenge) { disposition, credential in
                answer = (disposition, credential)
            }
        }
        guard let answer = answer else {
            Issue.record("the completion handler was not called")
            return (.performDefaultHandling, nil)
        }
        return answer
    }

    @Test func proxyBasicChallengeIsAnsweredWithProviderCredentials() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        let queue = DispatchQueue(label: "test")
        let ws = makeSocket(proxyCredentialsProvider: {
            CentrifugeProxyCredentials(user: "alice", password: "s3cret")
        }, queue: queue)

        let (disposition, credential) = answerTaskChallenge(ws, queue, makeProxyChallenge())

        #expect(disposition == .useCredential)
        #expect(credential?.user == "alice")
        #expect(credential?.password == "s3cret")
        #expect(credential?.persistence == URLCredential.Persistence.none)
    }

    @Test func providerIsCalledAtChallengeTime() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        let queue = DispatchQueue(label: "test")
        var currentUser = "first"
        let ws = makeSocket(proxyCredentialsProvider: {
            CentrifugeProxyCredentials(user: currentUser, password: "pw")
        }, queue: queue)

        let (_, firstCredential) = answerTaskChallenge(ws, queue, makeProxyChallenge())
        currentUser = "second"
        let (_, secondCredential) = answerTaskChallenge(ws, queue, makeProxyChallenge())

        #expect(firstCredential?.user == "first")
        #expect(secondCredential?.user == "second")
    }

    @Test func providerReturningNilCancelsWithoutCredential() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        let queue = DispatchQueue(label: "test")
        let ws = makeSocket(proxyCredentialsProvider: { nil }, queue: queue)

        let (disposition, credential) = answerTaskChallenge(ws, queue, makeProxyChallenge())

        #expect(disposition == .cancelAuthenticationChallenge)
        #expect(credential == nil)
    }

    @Test func noProviderCancelsWithoutCredential() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        let queue = DispatchQueue(label: "test")
        let ws = makeSocket(proxyCredentialsProvider: nil, queue: queue)

        let (disposition, credential) = answerTaskChallenge(ws, queue, makeProxyChallenge())

        #expect(disposition == .cancelAuthenticationChallenge)
        #expect(credential == nil)
    }

    @Test func repeatedRejectionCancelsWithoutCallingProvider() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        let queue = DispatchQueue(label: "test")
        let calls = CallCounter()
        let ws = makeSocket(proxyCredentialsProvider: {
            calls.increment()
            return CentrifugeProxyCredentials(user: "alice", password: "wrong")
        }, queue: queue)

        let (disposition, credential) = answerTaskChallenge(ws, queue, makeProxyChallenge(previousFailureCount: 1))

        #expect(disposition == .cancelAuthenticationChallenge)
        #expect(credential == nil)
        #expect(calls.value == 0)
    }

    @Test func nonProxyBasicChallengePerformsDefaultHandlingWithoutCallingProvider() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        let queue = DispatchQueue(label: "test")
        let calls = CallCounter()
        let ws = makeSocket(proxyCredentialsProvider: {
            calls.increment()
            return CentrifugeProxyCredentials(user: "alice", password: "s3cret")
        }, queue: queue)

        let challenge = makeServerChallenge(authMethod: NSURLAuthenticationMethodHTTPBasic)
        let (disposition, credential) = answerTaskChallenge(ws, queue, challenge)

        #expect(disposition == .performDefaultHandling)
        #expect(credential == nil)
        #expect(calls.value == 0)
    }

    @Test func serverTrustChallengeKeepsSessionLevelHandlingWithProviderSet() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        // A provider does not change the session-level path: with nothing else set, a server-trust
        // challenge still gets default handling, and the provider is not asked.
        let queue = DispatchQueue(label: "test")
        let calls = CallCounter()
        let ws = makeSocket(proxyCredentialsProvider: {
            calls.increment()
            return CentrifugeProxyCredentials(user: "alice", password: "s3cret")
        }, queue: queue)

        let (disposition, credential) = answerSessionChallenge(
            ws, queue, makeServerChallenge(authMethod: NSURLAuthenticationMethodServerTrust)
        )

        #expect(disposition == .performDefaultHandling)
        #expect(credential == nil)
        #expect(calls.value == 0)
    }

    @Test func serverTrustChallengeStillReachesTLSChallengeHandler() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        // tlsChallengeHandler keeps receiving the session-level challenges, with a provider set too.
        let queue = DispatchQueue(label: "test")
        let calls = CallCounter()
        var receivedAuthMethod: String?
        let ws = makeSocket(tlsChallengeHandler: { challenge, completion in
            receivedAuthMethod = challenge.protectionSpace.authenticationMethod
            completion(.cancelAuthenticationChallenge, nil)
        }, proxyCredentialsProvider: {
            calls.increment()
            return CentrifugeProxyCredentials(user: "alice", password: "s3cret")
        }, queue: queue)

        let (disposition, _) = answerSessionChallenge(
            ws, queue, makeServerChallenge(authMethod: NSURLAuthenticationMethodServerTrust)
        )

        #expect(disposition == .cancelAuthenticationChallenge)
        #expect(receivedAuthMethod == NSURLAuthenticationMethodServerTrust)
        #expect(calls.value == 0)
    }
}
