import Foundation

// The token exchange flow of a client with `CentrifugeClientConfig.tokenExchange`. Each connect attempt starts
// anonymously, or with the token it kept. An anonymous reply starts a bootstrap: the stored refresh token is
// exchanged for an access token with a plain rpc over the same connection, the access token is sent in a refresh
// command, and the connect resumes with the reply merged with the refresh result. The timer refresh renews the
// access token the same way (renewTokenExchangeToken).
//
// Everything here runs on syncQueue. The application's load, store and exchange complete on any thread, and each
// completion hops back to syncQueue before it touches the state. A callback of a stale attempt (its connection
// is gone, or it timed out) changes no run and ends no session: its refresh token rotation is still stored, as long
// as the client is alive. The exchange completions hold the client strongly, so a client released while an exchange
// is in flight still stores the rotation: the issuer has consumed the old refresh token, and a lost rotation would end
// the session at the next launch. The completion is called once by the application, so the reference ends with it.

/// The bounds of the retry of a failed bootstrap step, in seconds. The delay is the Java formula of the backoff:
/// min(maximum, minimum + uniform[0, min(maximum, minimum * 2^step)]).
internal let tokenBootstrapMinimumSeconds: TimeInterval = 5
internal let tokenBootstrapMaximumSeconds: TimeInterval = 60

/// The renewal window of the access token, as fractions of its ttl: [0.7, 0.9), or [0.6, 0.9) with earlyRenewal.
internal let tokenRenewalStartShare: Double = 0.7
internal let tokenRenewalEarlyStartShare: Double = 0.6
internal let tokenRenewalEndShare: Double = 0.9

/// The outcome of storing a rotated refresh token.
internal enum TokenStoreOutcome {
    /// The rotation was stored, or nothing had to be stored, or the failure was reported.
    case done
    /// The application's session is over: its load in the store step said so.
    case sessionEnded
}


internal extension CentrifugeClient {
    /// Starts a connect attempt of a client with a token exchange (startAttempt hook). The token is cleared when the
    /// server asked for a fresh one, or when the record of its expiry has passed, so that the connect goes out
    /// anonymously. The caller opens the transport.
    func beginTokenExchangeAttempt() {
        assertIsOnQueue(syncQueue)
        if refreshRequired || tokenExchangeTokenExpired() {
            self.token = ""
            self.refreshRequired = false
            tokenExchangeState.expiry = nil
        }
        tokenExchangeState.anonymousConnect = true
        tokenExchangeState.connectSentToken = !(self.token ?? "").isEmpty
    }

    /// Called with a connect reply before the client connects (handleConnectResult hook). A user in the reply
    /// means the server accepted the connect, so the connect goes on. An anonymous reply starts a bootstrap, and the
    /// connect resumes when it completes. Returns true when a bootstrap took the reply over.
    func tokenExchangeInterceptsConnect(_ result: Centrifugal_Centrifuge_Protocol_ConnectResult) -> Bool {
        guard tokenExchangeState.anonymousConnect else {
            return false
        }
        tokenExchangeState.anonymousConnect = false
        let sentToken: Bool = tokenExchangeState.connectSentToken
        tokenExchangeState.connectSentToken = false
        if !result.user.isEmpty {
            // A user reply to a connect that sent a token accepts the token. Without one, the identity is the server's own.
            if sentToken {
                closeRefusalRun()
            }
            observeTokenExpiry(expires: result.expires, ttl: result.ttl)
            return false
        }
        // The anonymous reply refuses the token the connect sent, so none is kept.
        self.token = ""
        tokenExchangeState.expiry = nil
        // The server pings while the bootstrap holds the connection, and each ping is answered (handlePing). The
        // watchdog itself is armed by the connect that resumes.
        if result.ping > 0 {
            self.pingInterval = result.ping
            self.sendPong = result.pong
        }
        tokenExchangeState.bootstrap = TokenExchangeBootstrap(transportId: self.transportId, pending: result)
        startBootstrapStep()
        return true
    }

    /// Holds a subscribe or an unsubscribe push that arrives while the bootstrap runs (handlePush hook). The connect
    /// resumes with the held subscriptions merged in, so no event is delivered for them before the connect. Returns
    /// true when the push was held.
    func holdTokenExchangePush(_ push: Centrifugal_Centrifuge_Protocol_Push) -> Bool {
        guard tokenExchangeState.bootstrap != nil else {
            return false
        }
        if push.hasSubscribe {
            tokenExchangeState.bootstrap?.heldSubscribes[push.channel] = push.subscribe
            tokenExchangeState.bootstrap?.heldUnsubscribes.remove(push.channel)
            return true
        }
        if push.hasUnsubscribe {
            tokenExchangeState.bootstrap?.heldSubscribes.removeValue(forKey: push.channel)
            tokenExchangeState.bootstrap?.heldUnsubscribes.insert(push.channel)
            return true
        }
        return false
    }

    /// Called when the connection is lost (processDisconnect hook). The bootstrap of the connection ends with it, and
    /// its backoff goes on. A disconnect the application asked for, or a terminal one, ends the session: the backoff
    /// restarts and the refusal run closes. The expiry record is kept.
    func tokenExchangeTransportLost(code: UInt32, terminal: Bool) {
        guard config.tokenExchange != nil else {
            return
        }
        abandonBootstrap()
        tokenExchangeState.anonymousConnect = false
        tokenExchangeState.connectSentToken = false
        if code == disconnectedCodeDisconnectCalled || terminal {
            tokenExchangeState.bootstrapAttempt = 0
            closeRefusalRun()
        }
    }

    /// The delay of the timer refresh of an expiry the server reported, in seconds. With a token exchange it is a random
    /// moment in the renewal window of the ttl, drawn from the injected random source. Without one, it is the ttl.
    func connectionRenewalDelay(ttl: UInt32) -> TimeInterval {
        guard let exchange: CentrifugeTokenExchange = config.tokenExchange else {
            return TimeInterval(ttl)
        }
        let windowStart: Double = exchange.earlyRenewal ? tokenRenewalEarlyStartShare : tokenRenewalStartShare
        let share: Double = windowStart + (tokenRenewalEndShare - windowStart) * uniformFraction(random)
        return TimeInterval(ttl) * share
    }

    /// The connection token of a renewal (getConnectionToken hook): the access token is exchanged over the connected
    /// connection. It serves the timer refresh and refresh() without a token. The completion runs on syncQueue, with
    /// the access token or the error. A timer fetch that a refresh() call superseded is dropped by its caller.
    func renewTokenExchangeToken(completion: @escaping (Result<String, Error>) -> Void) {
        self.syncQueue.async { [weak self] in
            guard let strongSelf: CentrifugeClient = self else {
                return
            }
            let transportId: UInt64 = strongSelf.transportId
            strongSelf.loadStoredRefreshToken(completion: { [weak self] (stored: Result<String?, Error>) in
                guard let owner: CentrifugeClient = self else {
                    return
                }
                switch stored {
                case .failure(let error):
                    if isTokenExchangeUnauthorized(error) {
                        owner.closeRefusalRun()
                    }
                    completion(.failure(error))
                case .success(let presented):
                    guard let refreshToken: String = presented else {
                        owner.closeRefusalRun()
                        completion(.failure(CentrifugeError.unauthorized))
                        return
                    }
                    owner.runRenewalExchange(transportId: transportId, refreshToken: refreshToken, completion: completion)
                }
            })
        }
    }
}


internal extension CentrifugeClient {
    /// Reads the stored refresh token. The completion runs on syncQueue, with nil for none or an empty one. The
    /// completion is not called when the client is gone.
    func loadStoredRefreshToken(completion: @escaping (Result<String?, Error>) -> Void) {
        guard let exchange: CentrifugeTokenExchange = config.tokenExchange else {
            return
        }
        let once: CallOnce = CallOnce()
        exchange.load(completion: { [weak self] (result: Result<CentrifugeStoredTokens?, Error>) in
            guard once.claim(), let strongSelf: CentrifugeClient = self else {
                return
            }
            strongSelf.syncQueue.async {
                switch result {
                case .success(let stored):
                    completion(.success(storedRefreshTokenOf(stored)))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        })
    }

    /// Whether the bootstrap of `transportId` is still the one of the connection that is connecting.
    func isCurrentBootstrap(_ transportId: UInt64) -> Bool {
        guard let bootstrap: TokenExchangeBootstrap = tokenExchangeState.bootstrap else {
            return false
        }
        return bootstrap.transportId == transportId && self.transportId == transportId && state == .connecting
    }

    /// One step of the bootstrap: reads the stored refresh token and exchanges it. Without a token the connect goes on
    /// anonymously, unless a refusal run is open: then the session ends.
    func startBootstrapStep() {
        guard let transportId: UInt64 = tokenExchangeState.bootstrap?.transportId else {
            return
        }
        loadStoredRefreshToken(completion: { [weak self] (stored: Result<String?, Error>) in
            guard let strongSelf: CentrifugeClient = self, strongSelf.isCurrentBootstrap(transportId) else {
                return
            }
            switch stored {
            case .failure(let error):
                if isTokenExchangeUnauthorized(error) {
                    strongSelf.endBootstrapSession()
                } else {
                    strongSelf.failBootstrap(error)
                }
            case .success(let presented):
                guard let refreshToken: String = presented else {
                    if strongSelf.tokenExchangeState.horizonNanos != nil {
                        // The token was removed during a refusal run: the session ends.
                        strongSelf.endBootstrapSession()
                        return
                    }
                    strongSelf.finishBootstrap(refresh: nil)
                    return
                }
                strongSelf.runBootstrapExchange(refreshToken: refreshToken)
            }
        })
    }

    /// Runs one exchange of the bootstrap. The client timeout is its deadline: an exchange that comes after it changes no
    /// run, and its rotation is stored.
    func runBootstrapExchange(refreshToken: String) {
        guard let transportId: UInt64 = tokenExchangeState.bootstrap?.transportId, let exchange: CentrifugeTokenExchange = config.tokenExchange else {
            return
        }
        let once: CallOnce = CallOnce()
        let deadline: DispatchWorkItem = DispatchWorkItem { [weak self] in
            guard once.claim(), let strongSelf: CentrifugeClient = self else {
                return
            }
            guard strongSelf.isCurrentBootstrap(transportId) else {
                return
            }
            strongSelf.abandonBootstrapAndClose(TokenExchangeFailure(message: "token exchange timed out", underlying: nil))
        }
        tokenExchangeState.bootstrap?.exchangeTimer = deadline
        scheduleTimeout(after: config.timeout, deadline)
        let event: CentrifugeTokenExchangeEvent = CentrifugeTokenExchangeEvent(
            client: self,
            transportId: transportId,
            refreshToken: refreshToken,
            refusalTypes: exchange.refusalTypes
        )
        // The completion holds the client strongly: a client released during the exchange would drop the rotated refresh
        // token after the issuer consumed the old one. The application calls the completion once, so no cycle persists.
        exchange.exchange(event, completion: { [self] (result: Result<CentrifugeTokenExchangeResult, Error>) in
            self.syncQueue.async {
                guard once.claim() else {
                    self.storeAbandonedRotation(result, used: refreshToken)
                    return
                }
                deadline.cancel()
                self.onBootstrapExchanged(transportId: transportId, refreshToken: refreshToken, result: result)
            }
        })
    }

    /// The outcome of a bootstrap exchange: an accepted one ends the refusal run, and a refusal opens it. The rotation is
    /// stored before the access token is used. A refusal presents the stored token again, see reloadAfterRefusal.
    func onBootstrapExchanged(transportId: UInt64, refreshToken: String, result: Result<CentrifugeTokenExchangeResult, Error>) {
        guard isCurrentBootstrap(transportId) else {
            storeAbandonedRotation(result, used: refreshToken)
            return
        }
        switch result {
        case .success(let exchanged):
            if !exchanged.token.isEmpty {
                tokenExchangeAccepted(grace: exchanged.grace)
            }
        case .failure(let error):
            if isTokenExchangeUnauthorized(error) {
                openRefusalRun()
            }
        }
        storeRotation(rotatedRefreshTokenOf(result), used: refreshToken, completion: { [weak self] (outcome: TokenStoreOutcome) in
            guard let strongSelf: CentrifugeClient = self, strongSelf.isCurrentBootstrap(transportId) else {
                return
            }
            if outcome == .sessionEnded {
                strongSelf.endBootstrapSession()
                return
            }
            switch result {
            case .failure(let error):
                if isTokenExchangeUnauthorized(error) {
                    strongSelf.reloadAfterRefusal(transportId: transportId, refreshToken: refreshToken)
                } else {
                    strongSelf.failBootstrap(error)
                }
            case .success(let exchanged):
                if exchanged.token.isEmpty {
                    strongSelf.failBootstrap(TokenExchangeFailure(message: "token exchange returned no access token", underlying: nil))
                } else {
                    strongSelf.refreshBootstrap(transportId: transportId, accessToken: exchanged.token)
                }
            }
        })
    }

    /// The issuer refused the refresh token. The stored token is read again: a changed one is presented at once, an empty
    /// one ends the session. The same one is presented once more, at a random moment inside the remaining grace. A second
    /// refusal of the unchanged value, or a refusal at the horizon, ends the session.
    func reloadAfterRefusal(transportId: UInt64, refreshToken: String) {
        loadStoredRefreshToken(completion: { [weak self] (again: Result<String?, Error>) in
            guard let strongSelf: CentrifugeClient = self, strongSelf.isCurrentBootstrap(transportId) else {
                return
            }
            switch again {
            case .failure(let error):
                if isTokenExchangeUnauthorized(error) {
                    strongSelf.endBootstrapSession()
                } else {
                    strongSelf.failBootstrap(error)
                }
            case .success(let presented):
                guard let token: String = presented else {
                    strongSelf.endBootstrapSession()
                    return
                }
                if token != refreshToken {
                    strongSelf.runBootstrapExchange(refreshToken: token)
                    return
                }
                if strongSelf.refusalHorizonPassed() || strongSelf.tokenExchangeState.refusals >= tokenExchangeRefusalRetries {
                    strongSelf.endBootstrapSession()
                    return
                }
                strongSelf.reportTokenError(TokenExchangeFailure(message: tokenExchangeRefusedRetryMessage, underlying: nil))
                let delay: UInt64 = strongSelf.random.uniform(0 ... strongSelf.refusalHorizonRemainingNanos())
                strongSelf.tokenExchangeState.refusals += 1
                strongSelf.scheduleBootstrapRetry(transportId: transportId, delayNanos: delay)
            }
        })
    }

    /// Sends the access token in a refresh command over the bootstrap's connection. The token is kept on the client
    /// for the command, and cleared again when the server refuses it.
    func refreshBootstrap(transportId: UInt64, accessToken: String) {
        self.token = accessToken
        tokenExchangeState.bootstrap?.tokenSet = true
        sendRefreshCommand(token: accessToken, completion: { [weak self] (result: Centrifugal_Centrifuge_Protocol_RefreshResult?, error: Error?) in
            guard let strongSelf: CentrifugeClient = self, strongSelf.isCurrentBootstrap(transportId) else {
                return
            }
            if let refreshError: Error = error {
                strongSelf.onBootstrapRefreshFailed(transportId: transportId, error: refreshError)
                return
            }
            strongSelf.finishBootstrap(refresh: result)
        })
    }

    /// The refresh command of a bootstrap failed. A retryable server error retries the bootstrap after the backoff. Any
    /// other server error disconnects with its code. A lost reply closes the connection after the backoff, so the
    /// reconnect bootstraps again on a connection that carries no identity.
    func onBootstrapRefreshFailed(transportId: UInt64, error: Error) {
        self.token = ""
        guard let centrifugeError: CentrifugeError = error as? CentrifugeError, case .replyError(let code, let message, let temporary) = centrifugeError else {
            abandonBootstrapAndClose(error)
            return
        }
        if refreshRetries(code: code, temporary: temporary) {
            delegate?.onError(self, CentrifugeErrorEvent(error: CentrifugeError.refreshError(error: error)))
            scheduleBootstrapRetry(transportId: transportId, delayNanos: nextBootstrapBackoffNanos())
            return
        }
        tokenExchangeState.bootstrapAttempt = 0
        processDisconnect(code: code, reason: message, reconnect: false)
    }

    /// The bootstrap completed: the connect resumes with the held reply, merged with the refresh result when there is one.
    func finishBootstrap(refresh: Centrifugal_Centrifuge_Protocol_RefreshResult?) {
        guard let bootstrap: TokenExchangeBootstrap = tokenExchangeState.bootstrap else {
            return
        }
        cancelBootstrapTimers()
        tokenExchangeState.bootstrap = nil
        tokenExchangeState.bootstrapAttempt = 0
        var connect: Centrifugal_Centrifuge_Protocol_ConnectResult = bootstrap.pending
        if let refreshed: Centrifugal_Centrifuge_Protocol_RefreshResult = refresh {
            connect.expires = refreshed.expires
            connect.ttl = refreshed.ttl
            connect.user = refreshed.user
            connect.authClass = refreshed.authClass
        }
        for (channel, subscribe) in bootstrap.heldSubscribes {
            connect.subs[channel] = tokenExchangeSubscribeResult(subscribe)
        }
        for channel in bootstrap.heldUnsubscribes {
            connect.subs.removeValue(forKey: channel)
        }
        observeTokenExpiry(expires: connect.expires, ttl: connect.ttl)
        resumeConnect(connect)
    }

    /// A step failed in a way that is retried: the error is reported, and the step runs again after the backoff.
    func failBootstrap(_ error: Error) {
        reportTokenError(error)
        guard let transportId: UInt64 = tokenExchangeState.bootstrap?.transportId else {
            return
        }
        scheduleBootstrapRetry(transportId: transportId, delayNanos: nextBootstrapBackoffNanos())
    }

    /// Ends the session at the server's word of the application: the refusal run closes, the backoff restarts, and the
    /// client disconnects for good with code 1.
    func endBootstrapSession() {
        tokenExchangeState.bootstrapAttempt = 0
        closeRefusalRun()
        processDisconnect(code: disconnectedCodeUnauthorized, reason: "unauthorized", reconnect: false)
    }

    /// Arms the retry of the bootstrap step after `delayNanos`. The retry runs a new step, if the connection still is the same.
    func scheduleBootstrapRetry(transportId: UInt64, delayNanos: UInt64) {
        let retry: DispatchWorkItem = DispatchWorkItem { [weak self] in
            guard let strongSelf: CentrifugeClient = self, strongSelf.isCurrentBootstrap(transportId) else {
                return
            }
            strongSelf.tokenExchangeState.bootstrap?.retryTimer = nil
            strongSelf.startBootstrapStep()
        }
        tokenExchangeState.bootstrap?.retryTimer?.cancel()
        tokenExchangeState.bootstrap?.retryTimer = retry
        scheduleAfter(clientSeconds(nanos: delayNanos), retry)
    }

    /// The delay of the next failed bootstrap step, in nanoseconds. The step count moves on, so the steps escalate across
    /// reconnects.
    func nextBootstrapBackoffNanos() -> UInt64 {
        let step: Int = tokenExchangeState.bootstrapAttempt
        tokenExchangeState.bootstrapAttempt += 1
        return boundedBackoffNanos(
            minimumNanos: clientNanos(tokenBootstrapMinimumSeconds),
            ceilingNanos: clientNanos(tokenBootstrapMaximumSeconds),
            attempt: step,
            random: random
        )
    }

    /// Ends a bootstrap whose exchange stalled, or whose refresh outcome is unknown. The error is reported, and the
    /// connection is closed after the backoff, so the reconnect bootstraps again.
    func abandonBootstrapAndClose(_ error: Error) {
        guard let transportId: UInt64 = tokenExchangeState.bootstrap?.transportId else {
            return
        }
        abandonBootstrap()
        reportTokenError(error)
        let closer: DispatchWorkItem = DispatchWorkItem { [weak self] in
            guard let strongSelf: CentrifugeClient = self, strongSelf.transportId == transportId, strongSelf.state == .connecting else {
                return
            }
            strongSelf.processDisconnect(code: connectingCodeTransportClosed, reason: "transport closed", reconnect: true)
        }
        scheduleAfter(clientSeconds(nanos: nextBootstrapBackoffNanos()), closer)
    }

    /// Gives up the bootstrap: its timers stop, its access token is cleared, and nothing of it runs again. The backoff is kept.
    func abandonBootstrap() {
        guard let bootstrap: TokenExchangeBootstrap = tokenExchangeState.bootstrap else {
            return
        }
        cancelBootstrapTimers()
        if bootstrap.tokenSet {
            self.token = ""
        }
        tokenExchangeState.bootstrap = nil
    }

    /// Cancels the timers of the bootstrap in progress.
    func cancelBootstrapTimers() {
        tokenExchangeState.bootstrap?.retryTimer?.cancel()
        tokenExchangeState.bootstrap?.exchangeTimer?.cancel()
    }

    /// Reports an error of the token exchange through `onError`.
    func reportTokenError(_ error: Error) {
        delegate?.onError(self, CentrifugeErrorEvent(error: CentrifugeError.tokenError(error: error)))
    }

    /// Hands a rotated refresh token to the application, before the access token of its result is used. The
    /// rotation is stored only while the application still holds the refresh token the exchange used
    /// (compare-and-store), so a newer token, or a logout that cleared the storage, is never overwritten. A
    /// failed read or store is reported, and the exchange goes on.
    func storeRotation(_ rotated: String?, used refreshToken: String, completion: @escaping (TokenStoreOutcome) -> Void = { _ in }) {
        guard let newToken: String = rotated, !newToken.isEmpty, newToken != refreshToken, let exchange: CentrifugeTokenExchange = config.tokenExchange else {
            completion(.done)
            return
        }
        loadStoredRefreshToken(completion: { [weak self] (current: Result<String?, Error>) in
            guard let strongSelf: CentrifugeClient = self else {
                return
            }
            switch current {
            case .failure(let error):
                if isTokenExchangeUnauthorized(error) {
                    completion(.sessionEnded)
                } else {
                    strongSelf.reportTokenError(TokenExchangeFailure(message: "token store failed to read the stored token", underlying: error))
                    completion(.done)
                }
            case .success(let stored):
                guard let held: String = stored, held == refreshToken else {
                    completion(.done)
                    return
                }
                exchange.store(CentrifugeStoredTokens(refreshToken: newToken), completion: { [weak self] (storeError: Error?) in
                    guard let owner: CentrifugeClient = self else {
                        return
                    }
                    owner.syncQueue.async {
                        if let failure: Error = storeError {
                            owner.reportTokenError(TokenExchangeFailure(message: "token store failed", underlying: failure))
                        }
                        completion(.done)
                    }
                })
            }
        })
    }

    /// The rotation of a stale exchange: stored by the rule of storeRotation, and its access token is not used. A
    /// session end of the read is dropped with the outcome.
    func storeAbandonedRotation(_ result: Result<CentrifugeTokenExchangeResult, Error>, used refreshToken: String) {
        storeRotation(rotatedRefreshTokenOf(result), used: refreshToken)
    }

    /// The renewal exchange of a renewal. The client timeout is its deadline: an exchange that comes after it
    /// changes no run, and its rotation is stored.
    func runRenewalExchange(transportId: UInt64, refreshToken: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard let exchange: CentrifugeTokenExchange = config.tokenExchange else {
            return
        }
        let once: CallOnce = CallOnce()
        let deadline: DispatchWorkItem = DispatchWorkItem {
            guard once.claim() else {
                return
            }
            completion(.failure(CentrifugeError.timeout))
        }
        scheduleTimeout(after: config.timeout, deadline)
        let event: CentrifugeTokenExchangeEvent = CentrifugeTokenExchangeEvent(
            client: self,
            transportId: transportId,
            refreshToken: refreshToken,
            refusalTypes: exchange.refusalTypes
        )
        // Strong, as in runBootstrapExchange: the rotation of a released client is still stored.
        exchange.exchange(event, completion: { [self] (result: Result<CentrifugeTokenExchangeResult, Error>) in
            self.syncQueue.async {
                guard once.claim() else {
                    self.storeAbandonedRotation(result, used: refreshToken)
                    return
                }
                deadline.cancel()
                self.onRenewalExchanged(transportId: transportId, refreshToken: refreshToken, result: result, completion: completion)
            }
        })
    }

    /// The outcome of a renewal exchange. A result on a lost connection is stale: it changes no run, and its rotation
    /// is stored. A refresh() call admitted meanwhile does not make it stale: a timer fetch that it superseded is
    /// dropped by its caller, and an explicit fetch is the first call and goes on.
    func onRenewalExchanged(
        transportId: UInt64,
        refreshToken: String,
        result: Result<CentrifugeTokenExchangeResult, Error>,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard self.transportId == transportId, self.state == .connected else {
            storeAbandonedRotation(result, used: refreshToken)
            completion(.failure(CentrifugeError.connectionClosed))
            return
        }
        switch result {
        case .success(let exchanged):
            if !exchanged.token.isEmpty {
                tokenExchangeAccepted(grace: exchanged.grace)
            }
        case .failure(let error):
            if isTokenExchangeUnauthorized(error) {
                openRefusalRun()
            }
        }
        storeRotation(rotatedRefreshTokenOf(result), used: refreshToken, completion: { [weak self] (outcome: TokenStoreOutcome) in
            guard let strongSelf: CentrifugeClient = self else {
                return
            }
            if outcome == .sessionEnded {
                strongSelf.closeRefusalRun()
                completion(.failure(CentrifugeError.unauthorized))
                return
            }
            switch result {
            case .failure(let error):
                if isTokenExchangeUnauthorized(error) {
                    strongSelf.reloadRenewalAfterRefusal(transportId: transportId, refreshToken: refreshToken, completion: completion)
                } else {
                    completion(.failure(error))
                }
            case .success(let exchanged):
                if exchanged.token.isEmpty {
                    completion(.failure(TokenExchangeFailure(message: "token exchange returned no access token", underlying: nil)))
                } else {
                    completion(.success(exchanged.token))
                }
            }
        })
    }

    /// The renewal was refused: the stored token is read again, as in reloadAfterRefusal. Within the grace, the fetch
    /// fails once with the retry message, and the timer refresh fetches again.
    func reloadRenewalAfterRefusal(transportId: UInt64, refreshToken: String, completion: @escaping (Result<String, Error>) -> Void) {
        loadStoredRefreshToken(completion: { [weak self] (again: Result<String?, Error>) in
            guard let strongSelf: CentrifugeClient = self else {
                return
            }
            switch again {
            case .failure(let error):
                if isTokenExchangeUnauthorized(error) {
                    strongSelf.closeRefusalRun()
                }
                completion(.failure(error))
            case .success(let presented):
                guard let token: String = presented else {
                    strongSelf.closeRefusalRun()
                    completion(.failure(CentrifugeError.unauthorized))
                    return
                }
                if token != refreshToken {
                    strongSelf.runRenewalExchange(transportId: transportId, refreshToken: token, completion: completion)
                    return
                }
                if strongSelf.refusalHorizonPassed() || strongSelf.tokenExchangeState.refusals >= tokenExchangeRefusalRetries {
                    strongSelf.closeRefusalRun()
                    completion(.failure(CentrifugeError.unauthorized))
                    return
                }
                strongSelf.tokenExchangeState.refusals += 1
                completion(.failure(TokenExchangeFailure(message: tokenExchangeRefusedRetryMessage, underlying: nil)))
            }
        })
    }

    /// Sends a plain rpc over the connection of an exchange and completes with its result. A call on another
    /// connection, or on a connection that is gone, fails with connectionClosed. A server error whose application
    /// type is a refusal type completes with unauthorized, the refusal of the refresh token.
    func sendTokenExchangeRpc(
        transportId: UInt64,
        method: String,
        data: Data,
        refusalTypes: Set<String>,
        completion: @escaping (Result<CentrifugeRpcResult, Error>) -> Void
    ) {
        self.syncQueue.async { [weak self] in
            guard let strongSelf: CentrifugeClient = self, strongSelf.transportId == transportId, strongSelf.state != .disconnected else {
                completion(.failure(CentrifugeError.connectionClosed))
                return
            }
            let command: Centrifugal_Centrifuge_Protocol_Command = makeRpcCommand(id: strongSelf.nextCommandId(), method: method, data: data)
            strongSelf.sendCommand(command: command, completion: { (reply: Centrifugal_Centrifuge_Protocol_Reply?, error: Error?) in
                if let failure: Error = error {
                    completion(.failure(failure))
                    return
                }
                guard let answer: Centrifugal_Centrifuge_Protocol_Reply = reply else {
                    completion(.failure(CentrifugeError.connectionClosed))
                    return
                }
                if answer.hasError {
                    if refusalTypes.contains(answer.error.appType) {
                        completion(.failure(CentrifugeError.unauthorized))
                        return
                    }
                    completion(.failure(rpcErrorValue(answer.error)))
                    return
                }
                completion(.success(CentrifugeRpcResult(data: answer.rpc.data, cached: answer.rpc.cached)))
            })
        }
    }
}


/// The refresh token of a stored value, or nil when there is none.
private func storedRefreshTokenOf(_ stored: CentrifugeStoredTokens?) -> String? {
    guard let tokens: CentrifugeStoredTokens = stored, !tokens.refreshToken.isEmpty else {
        return nil
    }
    return tokens.refreshToken
}


/// The rotated refresh token of a successful exchange, or nil.
private func rotatedRefreshTokenOf(_ result: Result<CentrifugeTokenExchangeResult, Error>) -> String? {
    guard case .success(let exchanged) = result else {
        return nil
    }
    return exchanged.refreshToken
}


/// The subscribe result of a subscribe push held by the bootstrap, as the connect result carries it. The push has no
/// publications and no recovery, so neither is copied.
private func tokenExchangeSubscribeResult(_ subscribe: Centrifugal_Centrifuge_Protocol_Subscribe) -> Centrifugal_Centrifuge_Protocol_SubscribeResult {
    var result: Centrifugal_Centrifuge_Protocol_SubscribeResult = Centrifugal_Centrifuge_Protocol_SubscribeResult()
    result.recoverable = subscribe.recoverable
    result.positioned = subscribe.positioned
    result.offset = subscribe.offset
    result.epoch = subscribe.epoch
    result.data = subscribe.data
    return result
}
