import Foundation
import Testing
@testable import SwiftCentrifuge

/// Unit tests for how `NativeWebSocket` starts its `URLSessionWebSocketTask`.
///
/// The task is started from the request's URL, not from the request, because a request-started
/// task may not honour the session's proxy settings. The subprotocol is passed to the task, and the
/// request's headers are moved to the session. These tests look at what the task is created from,
/// through the `makeTask` seam, and the task itself points at a port nothing listens on.
@Suite(.timeLimit(.minutes(1)))
struct NativeWebSocketTaskTests {

    @Test func taskIsStartedFromURLWithProtocolAndAppHeaders() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else {
            return
        }
        let endpoint: URL = URL(string: "ws://127.0.0.1:1/connection/websocket")!
        var request: URLRequest = URLRequest(url: endpoint)
        request.setValue("app-value", forHTTPHeaderField: "X-App-Header")

        let queue = DispatchQueue(label: "test")
        let ws = NativeWebSocket(
            request: request,
            urlSessionConfigurationProvider: nil,
            tlsSkipVerify: false,
            tlsChallengeHandler: nil,
            proxyCredentialsProvider: nil,
            queue: queue,
            log: EmptyLogger.instance
        )

        var createdFromURL: URL?
        var createdWithProtocols: [String]?
        var sessionHeaders: [AnyHashable: Any]?
        ws.makeTask = { session, url, protocols in
            createdFromURL = url
            createdWithProtocols = protocols
            sessionHeaders = session.configuration.httpAdditionalHeaders
            return session.webSocketTask(with: URL(string: "ws://127.0.0.1:1/")!)
        }

        queue.sync { ws.connect() }
        queue.sync { ws.close() }

        #expect(createdFromURL == endpoint)
        #expect(createdWithProtocols == ["centrifuge-protobuf"])
        #expect(sessionHeaders?["X-App-Header"] as? String == "app-value")
        #expect(sessionHeaders?["Sec-WebSocket-Protocol"] == nil)
    }

    /// Guards the application's configuration: the request's headers belong to the session the socket makes, so the
    /// configuration that the provider returned must come back with no header of the request.
    @Test func theProvidersConfigurationIsLeftUnchanged() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else {
            return
        }
        let shared: URLSessionConfiguration = URLSessionConfiguration.ephemeral
        let endpoint: URL = URL(string: "ws://127.0.0.1:1/connection/websocket")!
        var request: URLRequest = URLRequest(url: endpoint)
        request.setValue("app-value", forHTTPHeaderField: "X-App-Header")

        let queue: DispatchQueue = DispatchQueue(label: "test")
        let provider: URLSessionConfigurationProvider = { () -> URLSessionConfiguration in
            return shared
        }
        let ws: NativeWebSocket = NativeWebSocket(
            request: request,
            urlSessionConfigurationProvider: provider,
            tlsSkipVerify: false,
            tlsChallengeHandler: nil,
            proxyCredentialsProvider: nil,
            queue: queue,
            log: EmptyLogger.instance
        )

        // The task factory runs on the socket's queue, so the headers it records are shared through a locked box.
        let recorded: LockedBox<[AnyHashable: Any]?> = LockedBox<[AnyHashable: Any]?>(nil)
        ws.makeTask = { session, url, protocols in
            recorded.set(session.configuration.httpAdditionalHeaders)
            return session.webSocketTask(with: URL(string: "ws://127.0.0.1:1/")!)
        }

        queue.sync { ws.connect() }
        queue.sync { ws.close() }

        #expect(recorded.current?["X-App-Header"] as? String == "app-value")
        #expect(shared.httpAdditionalHeaders == nil)
    }

    /// Guards the precedence of headers: a request header replaces the same header of the provider's session, and the
    /// session's other headers stay.
    @Test func requestHeadersWinOverTheProvidersSessionHeaders() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else {
            return
        }
        let shared: URLSessionConfiguration = URLSessionConfiguration.ephemeral
        shared.httpAdditionalHeaders = ["X-App-Header": "from-session", "X-Session-Header": "session-value"]
        let endpoint: URL = URL(string: "ws://127.0.0.1:1/connection/websocket")!
        var request: URLRequest = URLRequest(url: endpoint)
        request.setValue("app-value", forHTTPHeaderField: "X-App-Header")

        let queue: DispatchQueue = DispatchQueue(label: "test")
        let provider: URLSessionConfigurationProvider = { () -> URLSessionConfiguration in
            return shared
        }
        let ws: NativeWebSocket = NativeWebSocket(
            request: request,
            urlSessionConfigurationProvider: provider,
            tlsSkipVerify: false,
            tlsChallengeHandler: nil,
            proxyCredentialsProvider: nil,
            queue: queue,
            log: EmptyLogger.instance
        )

        // The task factory runs on the socket's queue, so the headers it records are shared through a locked box.
        let recorded: LockedBox<[AnyHashable: Any]?> = LockedBox<[AnyHashable: Any]?>(nil)
        ws.makeTask = { session, url, protocols in
            recorded.set(session.configuration.httpAdditionalHeaders)
            return session.webSocketTask(with: URL(string: "ws://127.0.0.1:1/")!)
        }

        queue.sync { ws.connect() }
        queue.sync { ws.close() }

        #expect(recorded.current?["X-App-Header"] as? String == "app-value")
        #expect(recorded.current?["X-Session-Header"] as? String == "session-value")
    }

    /// Guards the subprotocol: the task takes it as its own, so a request header of that name never reaches the session.
    @Test func aSubprotocolHeaderOfTheRequestIsLeftOut() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else {
            return
        }
        let endpoint: URL = URL(string: "ws://127.0.0.1:1/connection/websocket")!
        var request: URLRequest = URLRequest(url: endpoint)
        request.setValue("other-protocol", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        request.setValue("app-value", forHTTPHeaderField: "X-App-Header")

        let queue: DispatchQueue = DispatchQueue(label: "test")
        let ws: NativeWebSocket = NativeWebSocket(
            request: request,
            urlSessionConfigurationProvider: nil,
            tlsSkipVerify: false,
            tlsChallengeHandler: nil,
            proxyCredentialsProvider: nil,
            queue: queue,
            log: EmptyLogger.instance
        )

        // The task factory runs on the socket's queue, so what it records is shared through locked boxes.
        let recordedProtocols: LockedBox<[String]?> = LockedBox<[String]?>(nil)
        let recordedHeaders: LockedBox<[AnyHashable: Any]?> = LockedBox<[AnyHashable: Any]?>(nil)
        ws.makeTask = { session, url, protocols in
            recordedProtocols.set(protocols)
            recordedHeaders.set(session.configuration.httpAdditionalHeaders)
            return session.webSocketTask(with: URL(string: "ws://127.0.0.1:1/")!)
        }

        queue.sync { ws.connect() }
        queue.sync { ws.close() }

        #expect(recordedProtocols.current == ["centrifuge-protobuf"])
        #expect(recordedHeaders.current?["X-App-Header"] as? String == "app-value")
        let headers: [AnyHashable: Any] = recordedHeaders.current ?? [:]
        let hasProtocolHeader: Bool = headers.keys.contains { (key: AnyHashable) -> Bool in
            return String(describing: key.base).lowercased() == "sec-websocket-protocol"
        }
        #expect(!hasProtocolHeader, "the session carries a Sec-WebSocket-Protocol header")
    }
}
