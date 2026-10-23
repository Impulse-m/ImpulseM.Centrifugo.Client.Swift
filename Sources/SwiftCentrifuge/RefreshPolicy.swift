import Foundation

// The retry policy of the timer refreshes: which server errors are retried, which keep the
// connection, the delay of a retry, and the rule for a token the server refused as expired.
// The functions are pure. The random source is the injected ClientRandom, so a test pins
// the delays exactly. The connection and the subscription refresh both decide with these.

/// The server code of a timer refresh refused as expired: the token the getter returned is refused.
internal let refreshRefusedExpiredCode: UInt32 = 109

/// The server code of a timer refresh that refuses the identity change of its token: the connection keeps
/// its identity and is not refreshed again; the server ends it at its expiry.
internal let refreshRefusedIdentityCode: UInt32 = 103

/// The shortest delay of a retry of a failed timer refresh, in seconds.
internal let refreshRetryMinimumSeconds: TimeInterval = 10

/// The ceiling of the first retry, in seconds. It doubles with each consecutive failure, up to the token
/// retry cap of the configuration.
internal let refreshRetryFirstCeilingSeconds: TimeInterval = 20


/// What a failed timer refresh does next. The connection and a subscription decide it the same way.
internal enum RefreshFailureAction {
    /// Reported, not retried: the connection keeps its identity and token until they expire (103).
    case keep
    /// Retried after the backoff with a fresh token. `refusedExpired` is set for 109, so the token the server
    /// refused can be remembered for stopOnRefusedToken.
    case retry(refusedExpired: Bool)
    /// The session ends with the server's code and message.
    case end(code: UInt32, message: String)
}


/// Whether a failed timer refresh is retried with a fresh token: a client error (code below 100), a
/// temporary error, and 109. Any other server error ends the connection, with the code.
internal func refreshRetries(code: UInt32, temporary: Bool) -> Bool {
    return code < 100 || temporary || code == refreshRefusedExpiredCode
}


/// Whether a failed timer refresh keeps the connection without a retry (103).
internal func refreshKeepsConnection(code: UInt32) -> Bool {
    return code == refreshRefusedIdentityCode
}


/// Decides what a failed timer refresh does next. An error that is not a server reply is retried.
internal func refreshFailureAction(_ error: Error) -> RefreshFailureAction {
    guard case CentrifugeError.replyError(let code, let message, let temporary) = error else {
        return .retry(refusedExpired: false)
    }
    if refreshKeepsConnection(code: code) {
        return .keep
    }
    if refreshRetries(code: code, temporary: temporary) {
        return .retry(refusedExpired: code == refreshRefusedExpiredCode)
    }
    return .end(code: code, message: message)
}


/// Runs the step of a failed timer refresh that `refreshFailureAction` picks. The connection and a subscription both
/// call it: the policy is the same, and only the side effects differ, so each passes its own closures.
internal func applyRefreshFailure(
    _ error: Error,
    keep: () -> Void,
    retry: (Bool) -> Void,
    end: (UInt32, String) -> Void
) {
    switch refreshFailureAction(error) {
    case .keep:
        keep()
    case .retry(let refusedExpired):
        retry(refusedExpired)
    case .end(let code, let message):
        end(code, message)
    }
}


/// The delay of the retry after `step` consecutive failed timer refreshes, in seconds, as the Java SDK
/// computes it (AuthRefresh). The ceiling is max(20 s, min(tokenRetryCap, 20 s * 2^step)). The delay is
/// min(ceiling, 10 s + uniform[0, min(ceiling, 10 s * 2^step)]), with the draw taken from `random`.
/// Draw 0 gives 10 s; draw 1 gives min(ceiling, 10 s + 10 s * 2^step).
internal func refreshRetryDelay(step: Int, tokenRetryCap: TimeInterval, random: ClientRandom) -> TimeInterval {
    let scaledCeiling: TimeInterval = refreshRetryFirstCeilingSeconds * pow(2, Double(step))
    let ceilingSeconds: TimeInterval = max(refreshRetryFirstCeilingSeconds, min(tokenRetryCap, scaledCeiling))
    let delay: UInt64 = boundedBackoffNanos(
        minimumNanos: clientNanos(refreshRetryMinimumSeconds),
        ceilingNanos: clientNanos(ceilingSeconds),
        attempt: step,
        random: random
    )
    return TimeInterval(delay) / 1e9
}


/// Whether a retry of a refused timer refresh must not send `token` again. That holds when the token is the
/// one the server refused as expired, and `stopOnRefusedToken` is set: the connection is left to expire,
/// and the next connect asks the getter for a token.
internal func refusedTokenIsNotResent(token: String, refused: String?, stopOnRefusedToken: Bool) -> Bool {
    guard stopOnRefusedToken, let refusedToken: String = refused else {
        return false
    }
    return token == refusedToken
}


internal extension CentrifugeClient {
    /// Whether a timer refresh token is the one the server refused as expired, which is not sent again.
    func connectionTokenIsRefused(_ token: String) -> Bool {
        return refusedTokenIsNotResent(token: token, refused: refreshState.refusedToken, stopOnRefusedToken: config.stopOnRefusedToken)
    }
}


internal extension CentrifugeSubscription {
    /// Whether a timer refresh token of the subscription is the one the server refused as expired, which is not
    /// sent again.
    func subscriptionTokenIsRefused(_ token: String) -> Bool {
        let stopOnRefusedToken: Bool = centrifuge?.config.stopOnRefusedToken ?? false
        return refusedTokenIsNotResent(token: token, refused: refreshRefusedToken, stopOnRefusedToken: stopOnRefusedToken)
    }

    /// Starts the refresh chain of the subscribed session after `delay`. One chain per subscribed session: a new step
    /// replaces the pending one, and the chain stops at its next step once the session it was started for is over
    /// (a resubscribe starts its own chain).
    func startSubscriptionRefresh(after delay: TimeInterval) {
        self.refreshTask?.cancel()
        let attempt: UInt64 = self.attempt
        let refreshTask: DispatchWorkItem = DispatchWorkItem { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.centrifuge?.syncQueue.async { [weak self] in
                guard let strongSelf = self, strongSelf.isCurrentSession(attempt) else { return }
                strongSelf.getSubscriptionToken(channel: strongSelf.channel, completion: { [weak self] result in
                    guard let strongSelf = self, strongSelf.isCurrentSession(attempt) else { return }
                    switch result {
                    case .success(let token):
                        if token == "" {
                            strongSelf.failUnauthorized(sendUnsubscribe: true)
                            return
                        }
                        // A token the server refused as expired is not sent again (stopOnRefusedToken).
                        if strongSelf.subscriptionTokenIsRefused(token) {
                            return
                        }
                        strongSelf.refreshWithToken(token: token, attempt: attempt)
                    case .failure(let error):
                        guard strongSelf.centrifuge != nil else { return }
                        if let centrifugeError = error as? CentrifugeError {
                            switch centrifugeError {
                            case .unauthorized:
                                strongSelf.failUnauthorized(sendUnsubscribe: true)
                                return
                            default:
                                break
                            }
                        }
                        strongSelf.scheduleSubscriptionRefreshRetry()
                        guard let strongSelf = self else { return }
                        strongSelf.delegate?.onError(
                            strongSelf,
                            CentrifugeSubscriptionErrorEvent(error: CentrifugeError.subscriptionTokenError(error: error))
                        )
                        return
                    }
                })
            }
        }

        self.centrifuge?.scheduleAfter(delay, refreshTask)
        self.refreshTask = refreshTask
    }

    /// Arms the retry of a failed subscription refresh after the delay of its failure count, and moves the count on.
    func scheduleSubscriptionRefreshRetry() {
        guard let client: CentrifugeClient = centrifuge else {
            return
        }
        let delay: TimeInterval = refreshRetryDelay(step: refreshFailures, tokenRetryCap: client.config.tokenRetryCap, random: client.random)
        refreshFailures += 1
        startSubscriptionRefresh(after: delay)
    }

    /// An accepted subscription refresh: the failure count and the refusal memory restart, and the refresh is armed
    /// again at the expiry the server reports.
    func subscriptionRefreshAccepted(expires: Bool, ttl: UInt32) {
        refreshFailures = 0
        refreshRefusedToken = nil
        if expires {
            startSubscriptionRefresh(after: Double(ttl))
        }
    }
}
