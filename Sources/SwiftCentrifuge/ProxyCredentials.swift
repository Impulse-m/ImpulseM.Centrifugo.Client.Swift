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

/// The answer to a task-level challenge of a native transport's session: the proxy's HTTP Basic
/// challenge gets the provider's credentials, and every other challenge gets default handling.
/// Shared by the WebSocket connections and the redirect fetches of the RPC pool.
internal func proxyChallengeAnswer(
    _ challenge: URLAuthenticationChallenge,
    provider: CentrifugeProxyCredentialsProvider?
) -> (disposition: URLSession.AuthChallengeDisposition, credential: URLCredential?) {
    guard challenge.protectionSpace.isProxy(),
          challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPBasic else {
        return (.performDefaultHandling, nil)
    }

    // The proxy rejected the credentials we sent. Fail instead of asking again.
    guard challenge.previousFailureCount == 0 else {
        return (.cancelAuthenticationChallenge, nil)
    }

    guard let provider: CentrifugeProxyCredentialsProvider = provider,
          let proxyCredentials: CentrifugeProxyCredentials = provider() else {
        return (.cancelAuthenticationChallenge, nil)
    }

    // Persistence .none, not .forSession: a stored credential would be proposed again after
    // the proxy's password changes, fail with previousFailureCount 1 and be cancelled on every
    // later attempt. It also keeps the password out of the shared credential storage.
    let credential: URLCredential = URLCredential(
        user: proxyCredentials.user,
        password: proxyCredentials.password,
        persistence: .none
    )
    return (.useCredential, credential)
}
