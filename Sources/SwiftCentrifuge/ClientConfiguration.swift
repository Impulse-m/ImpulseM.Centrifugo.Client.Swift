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
