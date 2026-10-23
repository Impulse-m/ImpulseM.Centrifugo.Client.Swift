import Foundation

// The token exchange: the client obtains and renews its connection token from a refresh token the
// application stores. The application supplies `load`, `store` and `exchange` (CentrifugeTokenExchange).
// The flow is in TokenExchangeFlow.swift, its refusal run and state in TokenExchangeRefusal.swift.

/// The grace the client uses when the exchange does not set one: how long the issuer keeps accepting the
/// refresh token an exchange consumed, in seconds.
internal let tokenExchangeDefaultGraceSeconds: Double = 30

/// The longest grace the client uses, in seconds. A longer grace from the application or the issuer is cut to it.
internal let tokenExchangeMaxGraceSeconds: Double = 300

/// How many times an unchanged refresh token is presented again inside one refusal run.
internal let tokenExchangeRefusalRetries: Int = 1

/// The text of the error that reports the retry of a refused refresh token. It names no token.
internal let tokenExchangeRefusedRetryMessage: String = "refresh token refused, retrying within the grace"


/// The refresh token the application stores. An empty token means that none is stored.
public struct CentrifugeStoredTokens: Equatable {
    /// The refresh token.
    public let refreshToken: String


    public init(refreshToken: String) {
        self.refreshToken = refreshToken
    }
}


/// What an exchange returns: the access token, which becomes the connection token, and the rotated refresh
/// token when the issuer rotated it.
public struct CentrifugeTokenExchangeResult {
    /// The access token.
    public let token: String
    /// The rotated refresh token, or nil when it did not change or when there is nothing to store.
    public let refreshToken: String?
    /// The grace the issuer publishes, in seconds, or nil when it publishes none. A negative value is ignored, and the
    /// grace in use is kept. A value above 300 is cut to 300.
    public let grace: Int?


    public init(token: String, refreshToken: String? = nil, grace: Int? = nil) {
        self.token = token
        self.refreshToken = refreshToken
        self.grace = grace
    }
}


/// The application's side of the token exchange. Set it as `CentrifugeClientConfig.tokenExchange`.
///
/// Every callback may complete on any thread, and each must complete exactly once. The client holds no refresh
/// token of its own: it calls `load` before each exchange.
///
/// - `load`: reads the stored refresh token. Nil or an empty token means none is stored. Fail with
///   `CentrifugeError.unauthorized` when the application's session is over: the client ends the session.
/// - `store`: persists a rotated refresh token. Called before the access token of the rotation is used. A failure
///   is reported through `onError`, and the exchange goes on.
/// - `exchange`: exchanges the refresh token for an access token. Use `event.rpc` to call the server over the
///   connection. Fail with `CentrifugeError.unauthorized` when the issuer refused the refresh token. An rpc
///   error whose application type is one of `refusalTypes` is passed on as that refusal. Any other failure is
///   reported and retried with backoff.
public protocol CentrifugeTokenExchange: AnyObject {
    /// Reads the stored refresh token.
    func load(completion: @escaping (Result<CentrifugeStoredTokens?, Error>) -> Void)

    /// Persists a rotated refresh token.
    func store(_ tokens: CentrifugeStoredTokens, completion: @escaping (Error?) -> Void)

    /// Exchanges the refresh token of `event` for an access token.
    func exchange(_ event: CentrifugeTokenExchangeEvent, completion: @escaping (Result<CentrifugeTokenExchangeResult, Error>) -> Void)

    /// Application error types (`CentrifugeReplyError.appType`) that mean the issuer refused the refresh token. The
    /// match is exact, and the error code is never consulted. Default: empty. An empty entry is a configuration error.
    var refusalTypes: Set<String> { get }

    /// How long the issuer keeps accepting the refresh token an exchange consumed, in seconds. A refused token is
    /// presented again within this grace, and the session ends at its end. Default 30. Negative or non-finite values
    /// use the default, and values above 300 are cut to 300.
    var grace: TimeInterval { get }

    /// Renews the access token from 0.6 of its ttl instead of 0.7, so that the renewals of many clients spread out.
    /// Default false: the renewal is due at a random moment from 0.7 to 0.9 of the ttl.
    var earlyRenewal: Bool { get }
}


public extension CentrifugeTokenExchange {
    var refusalTypes: Set<String> {
        return []
    }


    var grace: TimeInterval {
        return tokenExchangeDefaultGraceSeconds
    }


    var earlyRenewal: Bool {
        return false
    }
}


/// What an exchange gets: the refresh token to exchange, and `rpc`, a plain call on the connection the exchange
/// runs over. The client creates one for each exchange.
public final class CentrifugeTokenExchangeEvent {
    /// The refresh token to exchange, as `load` returned it.
    public let refreshToken: String

    // The client and the connection of the exchange. A call after the client is gone, or on another connection, fails.
    private weak var client: CentrifugeClient?
    private let transportId: UInt64
    private let refusalTypes: Set<String>


    internal init(
        client: CentrifugeClient,
        transportId: UInt64,
        refreshToken: String,
        refusalTypes: Set<String>
    ) {
        self.client = client
        self.transportId = transportId
        self.refreshToken = refreshToken
        self.refusalTypes = refusalTypes
    }


    /// Calls a server rpc over the connection of the exchange. A server error whose application type is one of
    /// the exchange's refusal types completes with `CentrifugeError.unauthorized`. The completion runs on the
    /// client's queue.
    public func rpc(method: String, data: Data, completion: @escaping (Result<CentrifugeRpcResult, Error>) -> Void) {
        guard let owner: CentrifugeClient = client else {
            completion(.failure(CentrifugeError.connectionClosed))
            return
        }
        owner.sendTokenExchangeRpc(transportId: transportId, method: method, data: data, refusalTypes: refusalTypes, completion: completion)
    }
}


/// An error of the token exchange that the application did not return itself: an exchange that returned no access
/// token, a store that failed, or the retry of a refused token. Its text never holds a token.
internal struct TokenExchangeFailure: Error, CustomStringConvertible {
    internal let message: String
    internal let underlying: Error?


    /// The message, and the cause of a store or load failure when the application gave one.
    internal var description: String {
        guard let cause: Error = underlying else {
            return message
        }
        return "\(message): \(cause)"
    }
}
