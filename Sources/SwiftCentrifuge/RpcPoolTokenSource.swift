import Foundation

// The token of the connections of a pool with `tokenFrom`: the main client's confirmed token, lent to each connection.
// The source runs on the main client's queue, which is the pool's queue, and is touched there only. It answers a
// connection's token request at once from the confirmed token, or leaves it waiting for an event of the main client:
// while the main client connects, and while a renewal runs. A connection that was refused its token starts one renewal
// of the main client per confirmed token. When no renewal can replace a refused token, the token is spent until the
// next confirmation of the main client. The source runs no timer of its own.

/// A pool that the token source tells of the events of its main client.
internal protocol RpcPoolMainListener: AnyObject {
    /// Called on the main client's queue after an event of the main client that may place, fail or retire the pool's calls
    /// and connections.
    func onMainEvent()
}


/// A weak reference to a pool the source tells of the events of its main client.
private final class RpcPoolListenerRef {
    weak var listener: RpcPoolMainListener?


    init(_ listener: RpcPoolMainListener) {
        self.listener = listener
    }
}


/// A token request of a connection, waiting for the main client.
private final class RpcPoolTokenWaiter {
    let owner: RpcPoolConnectionToken

    let refused: String

    let completion: (Result<String, Error>) -> Void


    init(
        owner: RpcPoolConnectionToken,
        refused: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        self.owner = owner
        self.refused = refused
        self.completion = completion
    }
}


/// The token state of one connection of a pool with `tokenFrom`: the token the connection presented last, and the
/// identity generation of that token. Its getter is the token getter of the connection's client.
internal final class RpcPoolConnectionToken {
    /// The token the connection presented last. Empty before its first token.
    internal private(set) var presented: String = ""

    /// The identity generation of the connection. It is set once, by the first token lent to the connection, and never
    /// moves on: a connection whose generation is not the current one is retired at its next token request. Until the
    /// first token it holds the generation the source had when the connection was made.
    internal private(set) var generation: UInt64

    /// Whether a token was lent to the connection, which fixes its generation.
    internal private(set) var stamped: Bool = false

    private let source: RpcPoolTokenSource


    internal init(source: RpcPoolTokenSource) {
        self.source = source
        self.generation = source.generation
    }


    /// The token getter of the connection's client. It runs on the connection's queue, asks the source on the main
    /// client's queue, and completes on whichever queue the source answers from: the client takes the answer on its own.
    internal func getter() -> CentrifugeConnectionTokenGetter {
        let source: RpcPoolTokenSource = self.source
        return { (event: CentrifugeConnectionTokenEvent, completion: @escaping (Result<String, Error>) -> Void) -> Void in
            source.queue.async {
                source.request(owner: self, completion: completion)
            }
        }
    }


    /// Records the token the connection was lent. The first token fixes the generation of the connection; later tokens
    /// never move it.
    internal func lend(_ token: String, generation: UInt64) {
        self.presented = token
        if !stamped {
            stamped = true
            self.generation = generation
        }
    }
}


/// The token source of one main client: its confirmed token, its identity generation, and the token requests of its
/// pools' connections that wait for the main client.
internal final class RpcPoolTokenSource {
    /// The queue of the source: the main client's, which the pools run on.
    internal let queue: DispatchQueue

    /// The main client. Weak: the client holds its source.
    private weak var main: CentrifugeClient?

    /// The token the main client confirmed last: its token at its last connect or accepted refresh. Nil before the first.
    private var confirmed: String? = nil

    /// The confirmed token that no renewal can replace before the next confirmation. Nil when none.
    private var spentToken: String? = nil

    /// The confirmed token a renewal was started for. One renewal runs per confirmed token.
    private var renewedFor: String? = nil

    /// Whether an identity was recorded, and the identity recorded at the last confirmation.
    private var recorded: Bool = false

    private var user: String = ""

    private var authClass: String = ""

    /// Moves on when the identity changes and when a session ends.
    private var generationCount: UInt64 = 0

    /// Set by a session end, cleared by the next connect confirmation.
    private var ended: Bool = false

    /// The token requests waiting for the main client, one per connection.
    private var waiting: [ObjectIdentifier: RpcPoolTokenWaiter] = [:]

    /// The pools told of the events of the main client.
    private var listeners: [RpcPoolListenerRef] = []


    internal init(main: CentrifugeClient) {
        self.main = main
        self.queue = main.syncQueue
    }


    /// The source of a main client. The first pool that takes its token from the client makes it, and the client keeps it.
    /// A client that is already connected when the source is made is seeded on the queue, before the pool's first call.
    /// Runs on the main client's queue only: it reads and stores `main.poolTokenSource`, which the client reads there.
    internal static func forClient(_ main: CentrifugeClient) -> RpcPoolTokenSource {
        if let existing: RpcPoolTokenSource = main.poolTokenSource {
            return existing
        }
        let made: RpcPoolTokenSource = RpcPoolTokenSource(main: main)
        main.poolTokenSource = made
        made.queue.async { [weak made] () -> Void in
            made?.seedIfConnected()
        }
        return made
    }


    /// The identity generation: it moves on when the identity of the main client changes and when its session ends.
    internal var generation: UInt64 {
        return generationCount
    }


    /// Whether the confirmed token is spent: the fleet refused it, and no renewal can replace it before the next
    /// confirmation.
    internal var isSpent: Bool {
        guard let token: String = spentToken else {
            return false
        }
        return token == confirmed
    }


    /// Tells a pool the events of the main client from now on.
    internal func addListener(_ listener: RpcPoolMainListener) {
        listeners.append(RpcPoolListenerRef(listener))
    }


    /// Answers the token request of a connection, on the queue. `owner` is the connection's token state, and the token it
    /// presented last is the one it refused. A request that this one replaces is answered unauthorized.
    internal func request(owner: RpcPoolConnectionToken, completion: @escaping (Result<String, Error>) -> Void) {
        let key: ObjectIdentifier = ObjectIdentifier(owner)
        if let replaced: RpcPoolTokenWaiter = waiting[key] {
            waiting[key] = nil
            replaced.completion(.failure(CentrifugeError.unauthorized))
        }
        if owner.stamped && owner.generation != generationCount {
            // A connection of an ended generation is retired: its token request is refused.
            completion(.failure(CentrifugeError.unauthorized))
            return
        }
        let waiter: RpcPoolTokenWaiter = RpcPoolTokenWaiter(owner: owner, refused: owner.presented, completion: completion)
        waiting[key] = waiter
        step(key)
    }


    /// Takes the confirmation of a main client that is connected when its source is made. Runs on the queue.
    internal func seedIfConnected() {
        guard let main: CentrifugeClient = self.main, main.state == .connected else {
            return
        }
        connectConfirmed()
    }


    /// Whether the identity a connection of the pool confirmed is the identity of the current generation.
    internal func confirmsIdentity(user: String, authClass: String) -> Bool {
        return user == self.user && authClass == self.authClass
    }


    /// Marks a token unusable: a connection confirmed another identity with it. The token is spent until the main client's
    /// next confirmation, so no connection is lent it again.
    internal func markUnusable(_ token: String) {
        if token.isEmpty {
            return
        }
        spend(token)
    }


    /// The main client confirmed its connect: its token is the confirmed one, and a renewal, a spent mark and a session end
    /// are cleared. The requests waiting for a token are answered.
    internal func connectConfirmed() {
        guard let main: CentrifugeClient = self.main else {
            return
        }
        ended = false
        renewedFor = nil
        spentToken = nil
        confirmed = main.token ?? ""
        observeIdentity(main)
        settleAll()
        notify()
    }


    /// The main client accepted a refresh: its token is the confirmed one. A renewal that gave back the token it was started
    /// for spends that token. The requests waiting for a token are answered again.
    internal func refreshAccepted() {
        guard let main: CentrifugeClient = self.main, main.state == .connected else {
            return
        }
        confirmed = main.token ?? ""
        spentToken = nil
        observeIdentity(main)
        if confirmed == renewedFor {
            spentToken = confirmed
        }
        settleAll()
        notify()
    }


    /// The state of the main client changed. A disconnect ends the requests that wait for it, and a session end moves the
    /// generation on once.
    internal func mainStateChanged() {
        guard let main: CentrifugeClient = self.main else {
            return
        }
        if main.state == .disconnected {
            if main.sessionEnded && !ended {
                ended = true
                generationCount += 1
            }
            settleAll()
        }
        notify()
    }


    /// Records the identity of the main client. The first identity is recorded as it is; a changed one moves the generation on.
    private func observeIdentity(_ main: CentrifugeClient) {
        let identityUser: String = main.identity.user
        let identityAuthClass: String = main.identity.authClass
        if !recorded {
            recorded = true
            user = identityUser
            authClass = identityAuthClass
            return
        }
        if identityUser != user || identityAuthClass != authClass {
            user = identityUser
            authClass = identityAuthClass
            generationCount += 1
        }
    }


    /// Answers the waiting request of a connection when the main client can answer it now. Otherwise the request waits for
    /// the next event of the main client.
    private func step(_ key: ObjectIdentifier) {
        guard let waiter: RpcPoolTokenWaiter = waiting[key] else {
            return
        }
        guard let main: CentrifugeClient = self.main, main.state != .disconnected else {
            finish(key, .failure(CentrifugeError.unauthorized))
            return
        }
        guard main.state == .connected, let token: String = confirmed else {
            return
        }
        if token == spentToken {
            finish(key, .failure(CentrifugeError.unauthorized))
            return
        }
        if token.isEmpty || token != waiter.refused {
            deliver(key, token)
            return
        }
        // The token was refused: the main client renews it, once per confirmed token.
        if !canRenew(main) {
            spend(token)
            return
        }
        if renewedFor != token {
            renewedFor = token
            startRenewal(main)
        }
    }


    /// Whether the main client can renew its token: it has a token getter or a token exchange.
    private func canRenew(_ main: CentrifugeClient) -> Bool {
        return main.config.tokenGetter != nil || main.config.tokenExchange != nil
    }


    /// Asks the main client for a new token. Its answer reaches the source through the refresh hooks of the client, so only a
    /// failure is read here.
    private func startRenewal(_ main: CentrifugeClient) {
        let token: String = confirmed ?? ""
        main.refresh(token: nil) { [weak self] (result: Result<CentrifugeRefreshResult, Error>) -> Void in
            guard let owner: RpcPoolTokenSource = self else {
                return
            }
            owner.renewalFinished(token: token, result: result)
        }
    }


    /// A renewal of the main client ended. An accepted one was handled by `refreshAccepted`. A server refusal that the
    /// renewal cannot repair (a non-temporary error, 103, or 109, which gives back the refused token again), or a renewal
    /// that cannot run, spends the token that was renewed. Any other failure leaves the requests waiting for the next
    /// event of the main client.
    private func renewalFinished(token: String, result: Result<CentrifugeRefreshResult, Error>) {
        guard case .failure(let error) = result else {
            return
        }
        var spends: Bool = false
        if let known: CentrifugeError = error as? CentrifugeError {
            switch known {
            case .replyError(let code, _, let temporary):
                spends = !temporary || code == 103 || code == 109
            case .configurationError:
                spends = true
            default:
                spends = false
            }
        }
        if spends && confirmed == token && spentToken != token {
            spend(token)
        }
    }


    /// Delivers a token to a waiting request. A connection stamped with an older generation than the current one is retired
    /// instead: the token is of another generation than the one the connection belongs to.
    private func deliver(_ key: ObjectIdentifier, _ token: String) {
        guard let waiter: RpcPoolTokenWaiter = waiting[key] else {
            return
        }
        waiting[key] = nil
        if waiter.owner.stamped && waiter.owner.generation != generationCount {
            waiter.completion(.failure(CentrifugeError.unauthorized))
            return
        }
        waiter.owner.lend(token, generation: generationCount)
        waiter.completion(.success(token))
    }


    /// Ends a waiting request with a failure.
    private func finish(_ key: ObjectIdentifier, _ result: Result<String, Error>) {
        guard let waiter: RpcPoolTokenWaiter = waiting[key] else {
            return
        }
        waiting[key] = nil
        waiter.completion(result)
    }


    /// The confirmed token is spent: the requests waiting for a token are answered now, and the pools hear of it.
    private func spend(_ token: String) {
        spentToken = token
        settleAll()
        notify()
    }


    /// Answers every waiting request again, after an event of the main client. The requests are walked over a copy, and a
    /// request that is answered during the walk is not evaluated again.
    private func settleAll() {
        for (key, waiter) in Array(waiting) {
            if waiting[key] === waiter {
                step(key)
            }
        }
    }


    /// Tells the pools of the main client an event. The listeners that were released are dropped first.
    private func notify() {
        listeners.removeAll { (ref: RpcPoolListenerRef) -> Bool in
            return ref.listener == nil
        }
        let current: [RpcPoolListenerRef] = listeners
        for ref: RpcPoolListenerRef in current {
            ref.listener?.onMainEvent()
        }
    }
}
