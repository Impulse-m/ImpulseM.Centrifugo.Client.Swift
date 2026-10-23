import Foundation

// The configuration checks of a client, shared by `create` and `init`. Each check of one feature lives with that feature
// (the instance in Instance.swift, the token exchange in TokenExchangeRefusal.swift); this file only combines them.

/// The configuration error of a client, or nil when the client can work: the instance (see
/// `instanceConfigurationError`), `maxPendingRpc` at least 1, and the token exchange (see
/// `tokenExchangeConfigurationError`).
internal func clientConfigurationError(_ config: CentrifugeClientConfig) -> CentrifugeError? {
    if let error: CentrifugeError = instanceConfigurationError(config.instance) {
        return error
    }
    if config.maxPendingRpc < 1 {
        return CentrifugeError.configurationError(message: "maxPendingRpc must be at least 1")
    }
    if let error: CentrifugeError = tokenExchangeConfigurationError(config) {
        return error
    }
    return nil
}


public extension CentrifugeClient {
    /// Creates a client, and refuses a configuration that cannot work. Unlike `init`, which
    /// still returns a client for such a configuration (and reports it through `onError` at
    /// `connect()`), this throws it at once.
    ///
    /// - Throws: `CentrifugeError.configurationError` when `config.instance` is not valid, or
    ///   `config.maxPendingRpc` is below 1.
    static func create(
        endpoint: String,
        config: CentrifugeClientConfig,
        delegate: CentrifugeClientDelegate? = nil
    ) throws -> CentrifugeClient {
        if let error: CentrifugeError = clientConfigurationError(config) {
            throw error
        }
        return CentrifugeClient(endpoint: endpoint, config: config, delegate: delegate)
    }
}
