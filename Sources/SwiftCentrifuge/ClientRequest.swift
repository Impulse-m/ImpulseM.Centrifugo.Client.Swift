import Foundation

// The setup that both client initializers share (see Client.swift): the request of the endpoint and the
// log line of the transport choice. The check of the configuration is in Instance.swift.

internal extension CentrifugeClient {
    /// The request of the endpoint, with the configured headers.
    static func makeRequest(endpoint: String, config: CentrifugeClientConfig) -> URLRequest {
        var request: URLRequest = URLRequest(url: URL(string: endpoint)!)
        for (key, value) in config.headers {
            request.addValue(value, forHTTPHeaderField: key)
        }
        return request
    }


    /// Logs the transport the client uses, and the setting that has no effect on it.
    static func logTransportChoice(config: CentrifugeClientConfig, log: CentrifugeLogger) {
        if #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *), config.useNativeWebSocket {
            log.info("Using NativeWebSocket")
        } else {
            // Either useNativeWebSocket is off, or the OS is too old for
            // URLSessionWebSocketTask (iOS < 13.0 and equivalents).
            log.info("Using StarscreamWebSocket")
            if config.tlsChallengeHandler != nil {
                log.warning("tlsChallengeHandler is set but has no effect on the Starscream transport")
            }
        }
    }
}
