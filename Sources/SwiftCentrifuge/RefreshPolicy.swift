import Foundation

// The retry policy of the timer refreshes: which server errors are retried, which keep the
// connection, the delay of a retry, and the rule for a token the server refused as expired.
// The functions are pure. The random source is the injected ClientRandom, so a test pins
// the delays exactly.

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


/// Whether a failed timer refresh is retried with a fresh token: a client error (code below 100), a
/// temporary error, and 109. Any other server error ends the connection, with the code.
internal func refreshRetries(code: UInt32, temporary: Bool) -> Bool {
    return code < 100 || temporary || code == refreshRefusedExpiredCode
}


/// Whether a failed timer refresh keeps the connection without a retry (103).
internal func refreshKeepsConnection(code: UInt32) -> Bool {
    return code == refreshRefusedIdentityCode
}


/// The delay of the retry after `step` consecutive failed timer refreshes, in seconds, as the Java SDK
/// computes it (AuthRefresh). The ceiling is max(20 s, min(tokenRetryCap, 20 s * 2^step)). The delay is
/// min(ceiling, 10 s + uniform[0, min(ceiling, 10 s * 2^step)]), with the draw taken from `random`.
/// Draw 0 gives 10 s; draw 1 gives min(ceiling, 10 s + 10 s * 2^step).
internal func refreshRetryDelay(step: Int, tokenRetryCap: TimeInterval, random: ClientRandom) -> TimeInterval {
    let scaledCeiling: TimeInterval = refreshRetryFirstCeilingSeconds * pow(2, Double(step))
    let ceilingSeconds: TimeInterval = max(refreshRetryFirstCeilingSeconds, min(tokenRetryCap, scaledCeiling))
    let ceiling: UInt64 = clientNanos(ceilingSeconds)
    let minimum: UInt64 = clientNanos(refreshRetryMinimumSeconds)
    let jitter: UInt64 = fullJitterNanos(base: minimum, attempt: step, cap: ceiling, random: random)
    let delay: UInt64 = min(ceiling, minimum + jitter)
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
