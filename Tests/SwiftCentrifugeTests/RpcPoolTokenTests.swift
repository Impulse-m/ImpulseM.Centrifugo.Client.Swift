import Foundation
import Testing
@testable import SwiftCentrifuge

// The rpc pool with `tokenFrom`: the connections are lent the main client's token, the identity moves on the calls
// that wait, a refused token spends the source, and an ended session closes the idle connections. The pool's
// connections go to the in-process fake server; the main client's timers run on its ManualScheduler, so no test sleeps.

/// The outcome of one pool call, filled on the pool's queue and awaited by the test.
private final class TokenPoolOutcome: @unchecked Sendable {
    let done: Expectation
    private let value: LockedBox<Result<CentrifugeRpcResult, Error>?> = LockedBox(nil)


    init(_ description: String) {
        self.done = Expectation(description)
    }


    var error: CentrifugeError? {
        guard case .failure(let error)? = value.current else {
            return nil
        }
        return error as? CentrifugeError
    }


    func record(_ result: Result<CentrifugeRpcResult, Error>) {
        value.set(result)
        done.fulfill()
    }
}


/// A short name for the outcome of a call, so a test checks the kind and the code.
private func kindOf(_ error: CentrifugeError?) -> String {
    guard let value: CentrifugeError = error else {
        return "none"
    }
    switch value {
    case .unauthorized:
        return "unauthorized"
    case .clientDisconnected:
        return "clientDisconnected"
    case .clientRejected(let code, let message):
        return "clientRejected \(code) \(message)"
    case .replyError(let code, _, _):
        return "replyError \(code)"
    default:
        return "other"
    }
}


/// Whether a command is a connect with the given token.
private func connectWithToken(_ token: String) -> (RpcCommand) -> Bool {
    return { (command: RpcCommand) -> Bool in
        return command.hasConnect && command.connect.token == token
    }
}


/// A main client with the delegate it keeps weakly (the test holds both) and the scheduler it runs its timers on.
private struct TokenMain {
    let client: CentrifugeClient
    let delegate: CentrifugeClientDelegate
    let scheduler: ManualScheduler
}


@Suite(.serialized, .timeLimit(.minutes(1)))
final class RpcPoolTokenTests: @unchecked Sendable {
    private let fake: FakeRpcServer


    init() throws {
        fake = try FakeRpcServer()
    }


    deinit {
        fake.server.stop()
    }


    // MARK: helpers

    private func poolOptions(
        tokenFrom: Bool,
        closeEndedSession: Bool = true,
        maxConnectionsPerEndpoint: Int = 2,
        idleTimeout: TimeInterval = 60,
        timeout: TimeInterval = 5
    ) -> CentrifugeRpcPoolOptions {
        let url: String = fake.server.url
        return CentrifugeRpcPoolOptions(
            endpoints: { (_: String) -> [String] in
                return [url]
            },
            timeout: timeout,
            maxConnectionsPerEndpoint: maxConnectionsPerEndpoint,
            idleTimeout: idleTimeout,
            tokenFrom: tokenFrom,
            closeEndedSession: closeEndedSession
        )
    }


    /// A main client on the manual clock, connected to the server at `server`, returned once its connect is reported.
    private func connectedMain(server: String, config: CentrifugeClientConfig) async -> TokenMain {
        let delegate: RecordingClientDelegate = RecordingClientDelegate(connected: Expectation("connected"))
        let setup: ManualClientSetup = makeManualClient(endpoint: server, config: config, delegate: delegate)
        setup.client.connect()
        await delegate.awaitConnected(times: 1)
        return TokenMain(client: setup.client, delegate: delegate, scheduler: setup.scheduler)
    }


    /// Runs an ended session with one idle connection of a pool with `tokenFrom`, and returns the connections the pool holds
    /// once the session has ended. The main client runs on a server of its own, so that its session can end without the
    /// pool's connection: its token getter gives a token at the first connect and answers unauthorized at the next one.
    private func connectionsAfterEndedSession(closeEndedSession: Bool) async throws -> Int {
        let mainServer: FakeCentrifugoServer = FakeCentrifugoServer()
        try mainServer.start()
        defer {
            mainServer.stop()
        }
        let calls: LockedBox<Int> = LockedBox(0)
        var config: CentrifugeClientConfig = CentrifugeClientConfig()
        config.tokenGetter = { (_: CentrifugeConnectionTokenEvent, completion: @escaping (Result<String, Error>) -> Void) -> Void in
            let count: Int = calls.current + 1
            calls.set(count)
            if count == 1 {
                completion(.success("t-main"))
            } else {
                completion(.failure(CentrifugeError.unauthorized))
            }
        }
        let connected: Expectation = Expectation("main connected")
        let ended: Expectation = Expectation("session ended")
        let delegate: ClosureClientDelegate = ClosureClientDelegate()
        delegate.onConn = { () -> Void in
            connected.fulfill()
        }
        delegate.onDisc = { (_: CentrifugeDisconnectedEvent) -> Void in
            ended.fulfill()
        }
        let setup: ManualClientSetup = makeManualClient(endpoint: mainServer.url, config: config, delegate: delegate)
        setup.client.connect()
        await fulfillment(of: connected, within: 5)

        // idleTimeout 0 keeps the connection open, so only the session end can close it.
        let pool: CentrifugeRpcPool = CentrifugeRpcPool(
            main: setup.client,
            options: poolOptions(tokenFrom: true, closeEndedSession: closeEndedSession, idleTimeout: 0)
        )
        let outcome: TokenPoolOutcome = TokenPoolOutcome("call on the pool connection")
        pool.rpc(endpointKey: "", method: "m", data: Data(), options: CentrifugeRpcPoolCallOptions()) { (result: Result<CentrifugeRpcResult, Error>) -> Void in
            outcome.record(result)
        }
        await fulfillment(of: outcome.done, within: 5)
        #expect(kindOf(outcome.error) == "none")
        #expect(pool.stats().connections == 1)

        // The main client reconnects after the server's invalidation, asks its getter, and the session ends.
        mainServer.disconnect(3014, "state invalidated")
        await setup.scheduler.advance(by: 30)
        await fulfillment(of: ended, within: 5)
        await awaitSyncQueue(setup.client)
        let remaining: Int = pool.stats().connections
        withExtendedLifetime(delegate) {}
        withExtendedLifetime(pool) {}
        return remaining
    }


    // MARK: tests

    @Test func tokenFromIsExclusiveWithTokenAndTokenGetter() async throws {
        let main: CentrifugeClient = makeManualClient(endpoint: fake.server.url, config: CentrifugeClientConfig()).client

        var withToken: CentrifugeRpcPoolOptions = poolOptions(tokenFrom: true)
        withToken.token = "t-own"
        var refusedToken: Bool = false
        do {
            _ = try CentrifugeRpcPool.create(main: main, options: withToken)
        } catch {
            refusedToken = true
        }
        #expect(refusedToken)

        var withGetter: CentrifugeRpcPoolOptions = poolOptions(tokenFrom: true)
        withGetter.tokenGetter = { (_: CentrifugeConnectionTokenEvent, completion: @escaping (Result<String, Error>) -> Void) -> Void in
            completion(.success("t-own"))
        }
        var refusedGetter: Bool = false
        do {
            _ = try CentrifugeRpcPool.create(main: main, options: withGetter)
        } catch {
            refusedGetter = true
        }
        #expect(refusedGetter)
    }


    @Test func tokenFromLendsTheMainTokenToItsConnections() async throws {
        var config: CentrifugeClientConfig = CentrifugeClientConfig()
        config.token = "t-main"
        let main: TokenMain = await connectedMain(server: fake.server.url, config: config)
        let pool: CentrifugeRpcPool = CentrifugeRpcPool(main: main.client, options: poolOptions(tokenFrom: true))
        let outcome: TokenPoolOutcome = TokenPoolOutcome("call on a lent connection")
        pool.rpc(endpointKey: "", method: "m", data: Data(), options: CentrifugeRpcPoolCallOptions()) { (result: Result<CentrifugeRpcResult, Error>) -> Void in
            outcome.record(result)
        }
        await fulfillment(of: outcome.done, within: 5)
        #expect(kindOf(outcome.error) == "none")

        // The main client and the pool's connection both presented the main client's confirmed token.
        await fake.awaitArrivals("connects with the main token", count: 2, connectWithToken("t-main"))
        #expect(fake.allCommands().filter(connectWithToken("t-main")).count == 2)
        withExtendedLifetime(main.delegate) {}
    }


    @Test func poolClosesIdleConnectionsOfAnEndedSession() async throws {
        let remaining: Int = try await connectionsAfterEndedSession(closeEndedSession: true)
        #expect(remaining == 0)
    }


    @Test func poolKeepsIdleConnectionsOfAnEndedSessionWhenCloseEndedSessionIsOff() async throws {
        let remaining: Int = try await connectionsAfterEndedSession(closeEndedSession: false)
        #expect(remaining == 1)
    }


    @Test func identityChangeFailsTheCallsThatWait() async throws {
        fake.setDrop { (command: RpcCommand) -> Bool in
            return command.hasRpc
        }
        var config: CentrifugeClientConfig = CentrifugeClientConfig()
        config.token = "t-main"
        let main: TokenMain = await connectedMain(server: fake.server.url, config: config)
        let pool: CentrifugeRpcPool = CentrifugeRpcPool(
            main: main.client,
            options: poolOptions(tokenFrom: true, maxConnectionsPerEndpoint: 1)
        )
        // The first call holds the one connection, and the server never answers it.
        let first: TokenPoolOutcome = TokenPoolOutcome("first call")
        let firstCall: CentrifugeRpcCall = pool.rpc(endpointKey: "", method: "m", data: Data(), options: CentrifugeRpcPoolCallOptions()) { (result: Result<CentrifugeRpcResult, Error>) -> Void in
            first.record(result)
        }
        await fake.awaitArrivals("first rpc") { (command: RpcCommand) -> Bool in
            return command.hasRpc
        }
        // The second call waits for the connection, bound to the identity it was made under.
        let second: TokenPoolOutcome = TokenPoolOutcome("second call")
        pool.rpc(endpointKey: "", method: "m", data: Data(), options: CentrifugeRpcPoolCallOptions()) { (result: Result<CentrifugeRpcResult, Error>) -> Void in
            second.record(result)
        }

        // A refresh moves the identity on: the server confirms another user.
        fake.setAnswer { (command: RpcCommand) -> RpcReply? in
            guard command.hasRefresh else {
                return nil
            }
            var refreshed: Centrifugal_Centrifuge_Protocol_RefreshResult = Centrifugal_Centrifuge_Protocol_RefreshResult()
            refreshed.user = "u2"
            var reply: RpcReply = RpcReply()
            reply.refresh = refreshed
            return reply
        }
        let refreshDone: Expectation = Expectation("refresh done")
        main.client.refresh(token: "t-second") { (_: Result<CentrifugeRefreshResult, Error>) -> Void in
            refreshDone.fulfill()
        }
        await fulfillment(of: refreshDone, within: 5)
        await fulfillment(of: second.done, within: 5)
        #expect(kindOf(second.error) == "clientRejected 3 identity changed")

        firstCall.cancel()
        await fulfillment(of: first.done, within: 5)
        #expect(kindOf(first.error) == "replyError 17")
        withExtendedLifetime(main.delegate) {}
    }


    @Test func refusedTokenWithNoRenewalFailsTheCallsWithTokenRefused() async throws {
        var config: CentrifugeClientConfig = CentrifugeClientConfig()
        config.token = "t-main"
        let main: TokenMain = await connectedMain(server: fake.server.url, config: config)

        // From now on the server refuses every connect: the pool's connection presents the main token and gets 109. The
        // main client has no token getter and no token exchange, so no renewal can replace the token.
        fake.setAnswer { (command: RpcCommand) -> RpcReply? in
            guard command.hasConnect else {
                return nil
            }
            return rpcErrorReply(code: 109, message: "token expired", temporary: false)
        }
        let pool: CentrifugeRpcPool = CentrifugeRpcPool(main: main.client, options: poolOptions(tokenFrom: true))
        let outcome: TokenPoolOutcome = TokenPoolOutcome("call with a refused token")
        pool.rpc(endpointKey: "", method: "m", data: Data(), options: CentrifugeRpcPoolCallOptions()) { (result: Result<CentrifugeRpcResult, Error>) -> Void in
            outcome.record(result)
        }
        await fake.awaitArrivals("pool connect", count: 2, connectWithToken("t-main"))
        await fulfillment(of: outcome.done, within: 10)
        #expect(kindOf(outcome.error) == "clientRejected 3 token refused")
        withExtendedLifetime(main.delegate) {}
    }
}
