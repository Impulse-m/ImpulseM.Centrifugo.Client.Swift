import Foundation

// The state of the token exchange of a client, its refusal run, and the configuration rules of the exchange.
// The state is touched only on syncQueue. A refusal run is the period from the first refusal of a refresh token
// until an accepted exchange or the end of the session: it has a horizon (the grace) and one retry.

/// The access token of the connection and the monotonic moment it expires.
internal struct TokenExchangeExpiry {
    internal let token: String
    internal let deadlineNanos: UInt64
}


/// A bootstrap: the anonymous connect reply, held until the access token is obtained and sent in a refresh command.
internal struct TokenExchangeBootstrap {
    // The connection the bootstrap runs on. The bootstrap ends with it.
    internal let transportId: UInt64
    // The connect result of the anonymous reply. The connect resumes with it, merged with the refresh result.
    internal let pending: Centrifugal_Centrifuge_Protocol_ConnectResult
    // The retry of a failed step, nil when none is armed.
    internal var retryTimer: DispatchWorkItem? = nil
    // The deadline of the exchange in flight, nil when none is armed.
    internal var exchangeTimer: DispatchWorkItem? = nil
    // Set when the access token was put on the client for the refresh command. It is cleared again when the bootstrap
    // ends without the command being accepted.
    internal var tokenSet: Bool = false
    // The subscribe pushes that arrived during the bootstrap, by channel. The connect resumes with them merged in.
    internal var heldSubscribes: [String: Centrifugal_Centrifuge_Protocol_Subscribe] = [:]
    // The channels whose unsubscribe push arrived during the bootstrap. The connect resumes without them.
    internal var heldUnsubscribes: Set<String> = []
}


/// The token exchange state of a client. Its fields are the state of one connection at a time, and of the
/// refusal run that survives a reconnect.
internal struct TokenExchangeState {
    // Set at the start of each connect attempt: the next connect reply may be taken over by a bootstrap.
    internal var anonymousConnect: Bool = false
    // Set at the start of each connect attempt: the connect carried a token.
    internal var connectSentToken: Bool = false
    // The bootstrap of the connection in progress, nil when there is none.
    internal var bootstrap: TokenExchangeBootstrap? = nil
    // The number of failed bootstrap steps, which escalates the backoff across reconnects. It restarts when a bootstrap
    // completes, and when the session ends or the application disconnects.
    internal var bootstrapAttempt: Int = 0
    // The grace the latest accepted exchange published, nil when it published none.
    internal var publishedGraceSeconds: Int? = nil
    // The horizon of the refusal run, a monotonic moment. Nil when no run is open.
    internal var horizonNanos: UInt64? = nil
    // The presentations of an unchanged refresh token that the open run has retried.
    internal var refusals: Int = 0
    // The expiry of the connection token, from the replies that carried it.
    internal var expiry: TokenExchangeExpiry? = nil
}


/// The configuration error of a token exchange, or nil when there is none: a token getter next to it, or an empty
/// refusal type (which would match an error without an application type).
internal func tokenExchangeConfigurationError(_ config: CentrifugeClientConfig) -> CentrifugeError? {
    guard let exchange: CentrifugeTokenExchange = config.tokenExchange else {
        return nil
    }
    if config.tokenGetter != nil {
        return CentrifugeError.configurationError(message: "tokenExchange and tokenGetter are exclusive")
    }
    if exchange.refusalTypes.contains("") {
        return CentrifugeError.configurationError(message: "refusalTypes holds an empty entry")
    }
    return nil
}


/// The grace in whole seconds for a grace of the application. A negative or non-finite value is ignored, and the
/// default is used. A value above the longest grace is cut to it.
internal func normalizedGraceSeconds(_ seconds: TimeInterval) -> Int {
    guard seconds.isFinite, seconds >= 0 else {
        return Int(tokenExchangeDefaultGraceSeconds)
    }
    return Int(min(seconds, tokenExchangeMaxGraceSeconds))
}


/// Whether an error is the application's `CentrifugeError.unauthorized`: a refusal of the refresh token, or a session
/// that the application ended.
internal func isTokenExchangeUnauthorized(_ error: Error) -> Bool {
    guard let centrifugeError: CentrifugeError = error as? CentrifugeError else {
        return false
    }
    if case .unauthorized = centrifugeError {
        return true
    }
    return false
}


internal extension CentrifugeClient {
    /// The grace in use, in seconds: the one the latest accepted exchange published, else the option's.
    func tokenExchangeGraceSeconds() -> Int {
        if let published: Int = tokenExchangeState.publishedGraceSeconds {
            return published
        }
        guard let exchange: CentrifugeTokenExchange = config.tokenExchange else {
            return Int(tokenExchangeDefaultGraceSeconds)
        }
        return normalizedGraceSeconds(exchange.grace)
    }

    /// Opens the refusal run at its first refusal. The horizon is the grace from now. An open run keeps its horizon.
    func openRefusalRun() {
        guard tokenExchangeState.horizonNanos == nil else {
            return
        }
        let graceNanos: UInt64 = UInt64(tokenExchangeGraceSeconds()) * 1_000_000_000
        tokenExchangeState.horizonNanos = clock.monotonicNanos() + graceNanos
    }

    /// Whether the horizon of the open run has passed. With no open run there is no horizon left.
    func refusalHorizonPassed() -> Bool {
        guard let horizon: UInt64 = tokenExchangeState.horizonNanos else {
            return true
        }
        return clock.monotonicNanos() >= horizon
    }

    /// The nanoseconds from now to the horizon of the open run, zero when no run is open or the horizon passed.
    func refusalHorizonRemainingNanos() -> UInt64 {
        guard let horizon: UInt64 = tokenExchangeState.horizonNanos else {
            return 0
        }
        let now: UInt64 = clock.monotonicNanos()
        return horizon > now ? horizon - now : 0
    }

    /// Ends the refusal run: the horizon is dropped and the refused presentations start again at zero.
    func closeRefusalRun() {
        tokenExchangeState.horizonNanos = nil
        tokenExchangeState.refusals = 0
    }

    /// An accepted exchange ends the refusal run. Its grace is kept for the next run when it publishes one. A result
    /// without one falls back to the option's grace, and a negative one keeps the grace in use.
    func tokenExchangeAccepted(grace: Int?) {
        closeRefusalRun()
        guard let published: Int = grace else {
            tokenExchangeState.publishedGraceSeconds = nil
            return
        }
        guard published >= 0 else {
            return
        }
        tokenExchangeState.publishedGraceSeconds = min(published, Int(tokenExchangeMaxGraceSeconds))
    }

    /// Records when the connection token expires, from a reply that carried it. A reply without expiry, or without a
    /// token, clears the record. Only a client with a token exchange records it.
    func observeTokenExpiry(expires: Bool, ttl: UInt32) {
        guard config.tokenExchange != nil else {
            return
        }
        guard expires, let current: String = self.token, !current.isEmpty else {
            tokenExchangeState.expiry = nil
            return
        }
        let deadline: UInt64 = clock.monotonicNanos() + UInt64(ttl) * 1_000_000_000
        tokenExchangeState.expiry = TokenExchangeExpiry(token: current, deadlineNanos: deadline)
    }

    /// Whether the connection token is the one the expiry record holds, and that record has passed.
    func tokenExchangeTokenExpired() -> Bool {
        guard let expiry: TokenExchangeExpiry = tokenExchangeState.expiry, let current: String = self.token else {
            return false
        }
        return expiry.token == current && clock.monotonicNanos() >= expiry.deadlineNanos
    }
}
