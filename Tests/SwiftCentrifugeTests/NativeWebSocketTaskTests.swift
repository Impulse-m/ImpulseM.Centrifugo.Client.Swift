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
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
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
}
