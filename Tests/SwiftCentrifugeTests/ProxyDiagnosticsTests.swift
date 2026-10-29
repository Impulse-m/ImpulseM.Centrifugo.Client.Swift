import Foundation
import Network
import Testing
@testable import SwiftCentrifuge

/// Prints what URLSession does with an HTTP proxy that asks for Basic credentials, for several ways of
/// configuring the proxy and its credentials. It asserts nothing.
@Suite(.serialized, .timeLimit(.minutes(3)))
struct ProxyDiagnosticsTests {

    private final class Recorder: NSObject, URLSessionWebSocketDelegate, URLSessionDataDelegate, @unchecked Sendable {
        let user: String
        let password: String
        private let lock: NSLock = NSLock()
        private var lines: [String] = []
        private var finished: Bool = false

        init(user: String, password: String) {
            self.user = user
            self.password = password
        }

        var all: [String] {
            lock.lock()
            defer { lock.unlock() }
            return lines
        }

        var isFinished: Bool {
            lock.lock()
            defer { lock.unlock() }
            return finished
        }

        func note(_ line: String, finish: Bool = false) {
            lock.lock()
            lines.append(line)
            if finish {
                finished = true
            }
            lock.unlock()
        }

        private func describe(_ challenge: URLAuthenticationChallenge) -> String {
            let space: URLProtectionSpace = challenge.protectionSpace
            return "method=\(space.authenticationMethod) isProxy=\(space.isProxy()) proxyType=\(space.proxyType ?? "nil") "
                + "host=\(space.host):\(space.port) failures=\(challenge.previousFailureCount)"
        }

        private func answer(
            _ challenge: URLAuthenticationChallenge,
            _ completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            if challenge.protectionSpace.isProxy() && challenge.previousFailureCount == 0 {
                completionHandler(.useCredential, URLCredential(user: user, password: password, persistence: .none))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }

        func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            note("session-level challenge: \(describe(challenge))")
            answer(challenge, completionHandler)
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            note("task-level challenge: \(describe(challenge))")
            answer(challenge, completionHandler)
        }

        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
            note("didOpen protocol=\(`protocol` ?? "nil")", finish: true)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let status: String = (task.response as? HTTPURLResponse).map { String($0.statusCode) } ?? "nil"
            note("didComplete status=\(status) error=\(String(describing: error))", finish: true)
        }
    }

    private enum TaskKind {
        case data
        case webSocketFromURL
        case webSocketFromRequest
    }

    private static func proxyHost() -> String? {
        let value: String? = ProcessInfo.processInfo.environment["CENTRIFUGE_PROXY_TEST_HOST"]
        return value?.isEmpty == false ? value : nil
    }

    private static func proxyDictionary(port: UInt16) -> [AnyHashable: Any] {
        return [
            kCFNetworkProxiesHTTPEnable as String: 1,
            kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPPort as String: Int(port),
            "HTTPSEnable": 1,
            "HTTPSProxy": "127.0.0.1",
            "HTTPSPort": Int(port),
        ]
    }

    private func run(
        _ name: String,
        host: String,
        kind: TaskKind,
        configure: (URLSessionConfiguration, UInt16, String, String) -> Void
    ) async throws {
        let user: String = "user-" + UUID().uuidString.prefix(8)
        let password: String = "pw-" + UUID().uuidString
        let proxy: AuthProxy = AuthProxy(user: user, password: password, upstreamPort: 8000)
        try proxy.start()
        defer { proxy.stop() }

        let configuration: URLSessionConfiguration = URLSessionConfiguration.ephemeral
        configure(configuration, proxy.port, user, password)
        let recorder: Recorder = Recorder(user: user, password: password)
        let session: URLSession = URLSession(configuration: configuration, delegate: recorder, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let task: URLSessionTask
        switch kind {
            case .data:
                task = session.dataTask(with: URL(string: "http://\(host):8000/connection/websocket")!)

            case .webSocketFromURL:
                task = session.webSocketTask(
                    with: URL(string: "ws://\(host):8000/connection/websocket")!,
                    protocols: ["centrifuge-protobuf"]
                )

            case .webSocketFromRequest:
                var request: URLRequest = URLRequest(url: URL(string: "ws://\(host):8000/connection/websocket")!)
                request.setValue("centrifuge-protobuf", forHTTPHeaderField: "Sec-WebSocket-Protocol")
                task = session.webSocketTask(with: request)
        }
        task.resume()

        var waited: Int = 0
        while !recorder.isFinished && waited < 60 {
            try await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }
        task.cancel()

        print("PROXYDIAG [\(name)] finished=\(recorder.isFinished) after \(waited * 100) ms")
        for line in recorder.all {
            print("PROXYDIAG [\(name)] client: \(line)")
        }
        print("PROXYDIAG [\(name)] proxy: rejected=\(proxy.rejected) connects=\(proxy.connects) forwards=\(proxy.forwards) forms=\(proxy.forms) authorities=\(proxy.authorities)")
        for line in proxy.rejections {
            print("PROXYDIAG [\(name)] proxy 407 for: \(line)")
        }
    }

    @Test func diagnoseProxyAuthentication() async throws {
        guard let host = ProxyDiagnosticsTests.proxyHost() else { return }

        try await run("data, dictionary", host: host, kind: .data) { configuration, port, _, _ in
            configuration.connectionProxyDictionary = ProxyDiagnosticsTests.proxyDictionary(port: port)
        }

        try await run("websocket from URL, dictionary", host: host, kind: .webSocketFromURL) { configuration, port, _, _ in
            configuration.connectionProxyDictionary = ProxyDiagnosticsTests.proxyDictionary(port: port)
        }

        try await run("websocket from request, dictionary", host: host, kind: .webSocketFromRequest) { configuration, port, _, _ in
            configuration.connectionProxyDictionary = ProxyDiagnosticsTests.proxyDictionary(port: port)
        }

        try await run("websocket from URL, dictionary with user and password", host: host, kind: .webSocketFromURL) { configuration, port, user, password in
            var dictionary: [AnyHashable: Any] = ProxyDiagnosticsTests.proxyDictionary(port: port)
            dictionary[kCFProxyUsernameKey as String] = user
            dictionary[kCFProxyPasswordKey as String] = password
            configuration.connectionProxyDictionary = dictionary
        }

        try await run("websocket from request, dictionary with user and password", host: host, kind: .webSocketFromRequest) { configuration, port, user, password in
            var dictionary: [AnyHashable: Any] = ProxyDiagnosticsTests.proxyDictionary(port: port)
            dictionary[kCFProxyUsernameKey as String] = user
            dictionary[kCFProxyPasswordKey as String] = password
            configuration.connectionProxyDictionary = dictionary
        }

        if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
            try await run("websocket from URL, proxy configuration with credential", host: host, kind: .webSocketFromURL) { configuration, port, user, password in
                var proxyConfiguration: ProxyConfiguration = ProxyConfiguration(
                    httpCONNECTProxy: NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
                )
                proxyConfiguration.applyCredential(username: user, password: password)
                configuration.proxyConfigurations = [proxyConfiguration]
            }

            try await run("websocket from URL, proxy configuration without credential", host: host, kind: .webSocketFromURL) { configuration, port, _, _ in
                let proxyConfiguration: ProxyConfiguration = ProxyConfiguration(
                    httpCONNECTProxy: NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
                )
                configuration.proxyConfigurations = [proxyConfiguration]
            }
        }
    }
}
