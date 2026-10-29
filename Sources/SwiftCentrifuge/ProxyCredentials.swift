import Foundation

/// The Basic credentials the native WebSocket transport sends to an HTTP proxy that asks for them.
public struct CentrifugeProxyCredentials {
    public let user: String
    public let password: String

    public init(user: String, password: String) {
        self.user = user
        self.password = password
    }
}

/// A provider of the credentials for a proxy that asks for HTTP Basic authentication. See
/// `CentrifugeClientConfig.proxyCredentialsProvider`.
public typealias CentrifugeProxyCredentialsProvider = () -> CentrifugeProxyCredentials?
