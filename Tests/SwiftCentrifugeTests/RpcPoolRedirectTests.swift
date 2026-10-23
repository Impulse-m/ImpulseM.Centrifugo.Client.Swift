import Foundation
import Testing
@testable import SwiftCentrifuge

// The redirect of a pool call: the fetch of the bytes that the hook names, its checks and its limits, its line under
// maxQueued, its deadline, its cancel and its close. The fetches run on a URLProtocol stub that the test answers, so
// no request reaches the network. The connections go to the in-process fake server, and the deadline timer runs on the
// main client's ManualScheduler, so no test sleeps.

/// What the stub answers one request with.
private enum StubAnswer {
    /// Answers now: the status, the headers, the body, and the URL the response reports (nil: the request's own).
    case respond(status: Int, headers: [String: String], body: Data, url: URL?)

    /// Keeps the request open until the test releases it.
    case hold
}


/// The requests the stub has seen, the rule that answers them, and the requests it holds. Guarded by its lock.
private final class StubBook: @unchecked Sendable {
    private let lock: NSLock = NSLock()

    private var rule: ((URLRequest) -> StubAnswer)? = nil

    private var arrival: ((URLRequest) -> Void)? = nil

    private var requests: [URLRequest] = []

    private var held: [RedirectStubProtocol] = []

    /// The body of the release, once the test has released the held requests. A request that is held after it is
    /// answered with this body, so that a fetch which arrives late is not held forever.
    private var released: Data? = nil


    /// Forgets the rule, the requests, the held requests and the release.
    func reset() {
        lock.lock()
        rule = nil
        arrival = nil
        requests = []
        held = []
        released = nil
        lock.unlock()
    }


    func setRule(_ newRule: ((URLRequest) -> StubAnswer)?) {
        lock.lock()
        rule = newRule
        lock.unlock()
    }


    /// Calls `observer` for every request that arrives, after it is recorded.
    func setArrival(_ observer: ((URLRequest) -> Void)?) {
        lock.lock()
        arrival = observer
        lock.unlock()
    }


    /// Records a request, and decides its answer by the rule. A request the rule holds is registered as held, unless
    /// the release has come already. Runs on the URL loading thread.
    func handle(_ owner: RedirectStubProtocol, _ request: URLRequest) -> StubAnswer {
        lock.lock()
        requests.append(request)
        let current: ((URLRequest) -> StubAnswer)? = rule
        let observer: ((URLRequest) -> Void)? = arrival
        lock.unlock()
        observer?(request)
        var answer: StubAnswer = .respond(status: 404, headers: [:], body: Data(), url: nil)
        if let decide: (URLRequest) -> StubAnswer = current {
            answer = decide(request)
        }
        guard case .hold = answer else {
            return answer
        }
        lock.lock()
        defer {
            lock.unlock()
        }
        if let body: Data = released {
            return .respond(status: 200, headers: [:], body: body, url: nil)
        }
        held.append(owner)
        return .hold
    }


    func forget(_ owner: RedirectStubProtocol) {
        lock.lock()
        held.removeAll { (candidate: RedirectStubProtocol) -> Bool in
            return candidate === owner
        }
        lock.unlock()
    }


    /// Releases the held requests: they are taken out, and the release is kept for the requests held later.
    func release(_ body: Data) -> [RedirectStubProtocol] {
        lock.lock()
        released = body
        let taken: [RedirectStubProtocol] = held
        held = []
        lock.unlock()
        return taken
    }


    /// Every request seen so far, in arrival order.
    func seen() -> [URLRequest] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return requests
    }
}


/// The URLProtocol of the redirect fetches in these tests. It answers each request with the book's rule.
private final class RedirectStubProtocol: URLProtocol {
    static let book: StubBook = StubBook()


    override class func canInit(with request: URLRequest) -> Bool {
        return request.url?.host == "redirect.stub"
    }


    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }


    override func startLoading() {
        switch RedirectStubProtocol.book.handle(self, request) {
        case .hold:
            // Registered as held by the book: it is answered by the test's release.
            break
        case .respond(let status, let headers, let body, let url):
            deliver(status: status, headers: headers, body: body, url: url)
        }
    }


    override func stopLoading() {
        RedirectStubProtocol.book.forget(self)
    }


    /// Sends a response, its body, and the end of the load.
    func deliver(status: Int, headers: [String: String], body: Data, url: URL?) {
        let own: URL? = request.url
        guard let served: URL = url ?? own else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        guard let response: HTTPURLResponse = HTTPURLResponse(url: served, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty {
            client?.urlProtocol(self, didLoad: body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }


    /// Answers every held request with a 200 response of the body, and any request held later the same way.
    static func releaseHeld(_ body: Data) {
        for owner: RedirectStubProtocol in book.release(body) {
            owner.deliver(status: 200, headers: [:], body: body, url: nil)
        }
    }
}


/// The outcome of one pool call, filled on the pool's queue and awaited by the test.
private final class RedirectOutcome: @unchecked Sendable {
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


    var data: Data? {
        guard case .success(let result)? = value.current else {
            return nil
        }
        return result.data
    }


    func record(_ result: Result<CentrifugeRpcResult, Error>) {
        value.set(result)
        done.fulfill()
    }
}


/// A main client, the delegate it keeps weakly (the test holds both), and the scheduler it runs its timers on.
private struct RedirectMainHarness {
    let client: CentrifugeClient
    let delegate: CentrifugeClientDelegate
    let scheduler: ManualScheduler
}


/// Two calls whose replies carry redirects. The first fetch is held by the stub, and the second call is the one that
/// waits for its slot (or fails at once when the line has no room).
private struct HeldRedirects {
    let main: RedirectMainHarness
    let pool: CentrifugeRpcPool
    let firstCall: CentrifugeRpcCall
    let secondCall: CentrifugeRpcCall
    let first: RedirectOutcome
    let second: RedirectOutcome
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
    case .connectionClosed:
        return "connectionClosed"
    case .timeout:
        return "timeout"
    case .clientRejected(let code, let message):
        return "clientRejected \(code) \(message)"
    case .configurationError:
        return "configurationError"
    case .replyError(let code, _, _):
        return "replyError \(code)"
    case .replyErrorDetails(let details):
        return "replyErrorDetails \(details.code)"
    default:
        return "other"
    }
}


/// The reply of a successful rpc call with the given data.
private func resultReply(_ text: String) -> RpcReply {
    var result: Centrifugal_Centrifuge_Protocol_RPCResult = Centrifugal_Centrifuge_Protocol_RPCResult()
    result.data = Data(text.utf8)
    var reply: RpcReply = RpcReply()
    reply.rpc = result
    return reply
}


/// The fake server's answer: an rpc command gets the data "plain", and the other commands the default answer.
private func plainAnswer(_ command: RpcCommand) -> RpcReply? {
    if command.hasRpc {
        return resultReply("plain")
    }
    return nil
}


/// The stub's rule for the held fetch: "/first" is held, and every other path answers 200 with "second".
private func holdFirstAnswerOthers(_ request: URLRequest) -> StubAnswer {
    if request.url?.path == "/first" {
        return .hold
    }
    return .respond(status: 200, headers: [:], body: Data("second".utf8), url: nil)
}


/// The requests of the redirect host, from the stub's record.
private func fetchesOf(_ requests: [URLRequest]) -> [URLRequest] {
    return requests.filter { (request: URLRequest) -> Bool in
        return request.url?.host == "redirect.stub"
    }
}


/// A redirect hook that names one URL for every outcome.
private func redirectHook(to url: String) -> (CentrifugeReplyOutcome) -> CentrifugeRedirect? {
    return { (_: CentrifugeReplyOutcome) -> CentrifugeRedirect? in
        return CentrifugeRedirect(url: url)
    }
}


/// Options of a pool whose connections go to the fake server, and whose redirect fetches run on the stub.
private func redirectOptions(
    fakeURL: String,
    maxRedirectsInflight: Int = 4,
    maxQueued: Int = 64,
    additionalHeaders: [AnyHashable: Any]? = nil,
    redirect: ((CentrifugeReplyOutcome) -> CentrifugeRedirect?)?
) -> CentrifugeRpcPoolOptions {
    let configuration: URLSessionConfiguration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RedirectStubProtocol.self]
    configuration.httpAdditionalHeaders = additionalHeaders
    return CentrifugeRpcPoolOptions(
        endpoints: { (_: String) -> [String] in
            return [fakeURL]
        },
        maxQueued: maxQueued,
        redirect: redirect,
        maxRedirectsInflight: maxRedirectsInflight,
        urlSession: URLSession(configuration: configuration)
    )
}


@Suite(.serialized, .timeLimit(.minutes(1)))
final class RpcPoolRedirectTests: @unchecked Sendable {
    private let fake: FakeRpcServer


    init() throws {
        fake = try FakeRpcServer()
        RedirectStubProtocol.book.reset()
    }


    deinit {
        fake.server.stop()
    }


    // MARK: helpers

    /// A main client on the manual clock and scheduler, connected to the fake server.
    private func connectedMain() async -> RedirectMainHarness {
        let delegate: RecordingClientDelegate = RecordingClientDelegate(connected: Expectation("connected"))
        let setup: ManualClientSetup = makeManualClient(
            endpoint: fake.server.url,
            config: CentrifugeClientConfig(),
            delegate: delegate
        )
        setup.client.connect()
        await delegate.awaitConnected(times: 1)
        return RedirectMainHarness(client: setup.client, delegate: delegate, scheduler: setup.scheduler)
    }


    /// Starts one pool call, and returns its handle.
    @discardableResult
    private func startCall(
        _ pool: CentrifugeRpcPool,
        _ outcome: RedirectOutcome,
        method: String = "m",
        timeout: TimeInterval? = nil
    ) -> CentrifugeRpcCall {
        return pool.rpc(
            endpointKey: "",
            method: method,
            data: Data(),
            options: CentrifugeRpcPoolCallOptions(timeout: timeout)
        ) { (result: Result<CentrifugeRpcResult, Error>) -> Void in
            outcome.record(result)
        }
    }


    /// Starts two calls whose replies carry the redirects to "/first" and "/second". Returns once both hooks have run
    /// and the pool has handled the second call: it waits for a slot, or it has failed at once.
    private func startHeldRedirects(maxQueued: Int, maxRedirectsInflight: Int) async -> HeldRedirects {
        let main: RedirectMainHarness = await connectedMain()
        let counter: LockedBox<Int> = LockedBox(0)
        let firstHook: Expectation = Expectation("first redirect hooked")
        let secondHook: Expectation = Expectation("second redirect hooked")
        let hook: (CentrifugeReplyOutcome) -> CentrifugeRedirect? = { (_: CentrifugeReplyOutcome) -> CentrifugeRedirect? in
            let number: Int = counter.current + 1
            counter.set(number)
            if number == 1 {
                firstHook.fulfill()
                return CentrifugeRedirect(url: "https://redirect.stub/first")
            }
            secondHook.fulfill()
            return CentrifugeRedirect(url: "https://redirect.stub/second")
        }
        let pool: CentrifugeRpcPool = CentrifugeRpcPool(
            main: main.client,
            options: redirectOptions(
                fakeURL: fake.server.url,
                maxRedirectsInflight: maxRedirectsInflight,
                maxQueued: maxQueued,
                redirect: hook
            )
        )
        let first: RedirectOutcome = RedirectOutcome("first call")
        let second: RedirectOutcome = RedirectOutcome("second call")
        // The stub has seen the first fetch once it is held, so a release or a close after this point meets it.
        let heldFirst: Expectation = Expectation("first fetch held by the stub")
        RedirectStubProtocol.book.setArrival { (request: URLRequest) -> Void in
            if request.url?.path == "/first" {
                heldFirst.fulfill()
            }
        }
        let firstCall: CentrifugeRpcCall = startCall(pool, first)
        await fulfillment(of: firstHook, within: 5)
        await awaitSyncQueue(main.client)
        let secondCall: CentrifugeRpcCall = startCall(pool, second)
        await fulfillment(of: secondHook, within: 5)
        await awaitSyncQueue(main.client)
        await fulfillment(of: heldFirst, within: 5)
        return HeldRedirects(
            main: main,
            pool: pool,
            firstCall: firstCall,
            secondCall: secondCall,
            first: first,
            second: second
        )
    }


    // MARK: fetch

    @Test func redirectFetchCarriesNoApplicationCredentials() async throws {
        fake.setAnswer(plainAnswer)
        RedirectStubProtocol.book.setRule { (_: URLRequest) -> StubAnswer in
            return .respond(status: 200, headers: [:], body: Data("bytes".utf8), url: nil)
        }
        let main: RedirectMainHarness = await connectedMain()
        let pool: CentrifugeRpcPool = CentrifugeRpcPool(
            main: main.client,
            options: redirectOptions(fakeURL: fake.server.url, redirect: { (_: CentrifugeReplyOutcome) -> CentrifugeRedirect? in
                return CentrifugeRedirect(url: "https://redirect.stub/chunk", headers: ["X-Chunk": "1"])
            })
        )
        let outcome: RedirectOutcome = RedirectOutcome("redirected call")
        startCall(pool, outcome)
        await fulfillment(of: outcome.done, within: 5)
        #expect(outcome.data == Data("bytes".utf8))

        let fetched: [URLRequest] = fetchesOf(RedirectStubProtocol.book.seen())
        #expect(fetched.count == 1)
        #expect(fetched.first?.value(forHTTPHeaderField: "X-Chunk") == "1")
        #expect(fetched.first?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(fetched.first?.value(forHTTPHeaderField: "Cookie") == nil)
        withExtendedLifetime(pool) {}
        withExtendedLifetime(main.delegate) {}
    }


    @Test func redirectFetchIgnoresTheApplicationSessionHeaders() async throws {
        fake.setAnswer(plainAnswer)
        RedirectStubProtocol.book.setRule { (_: URLRequest) -> StubAnswer in
            return .respond(status: 200, headers: [:], body: Data("bytes".utf8), url: nil)
        }
        let main: RedirectMainHarness = await connectedMain()
        let pool: CentrifugeRpcPool = CentrifugeRpcPool(
            main: main.client,
            options: redirectOptions(
                fakeURL: fake.server.url,
                additionalHeaders: ["Authorization": "Bearer application-secret"],
                redirect: redirectHook(to: "https://redirect.stub/secret")
            )
        )
        let outcome: RedirectOutcome = RedirectOutcome("session headers")
        startCall(pool, outcome)
        await fulfillment(of: outcome.done, within: 5)
        #expect(outcome.data == Data("bytes".utf8))

        let fetched: [URLRequest] = fetchesOf(RedirectStubProtocol.book.seen())
        #expect(fetched.count == 1)
        #expect(fetched.first?.value(forHTTPHeaderField: "Authorization") == nil)
        withExtendedLifetime(pool) {}
        withExtendedLifetime(main.delegate) {}
    }


    @Test func redirect3xxFailsTheFetch() async throws {
        fake.setAnswer(plainAnswer)
        RedirectStubProtocol.book.setRule { (_: URLRequest) -> StubAnswer in
            return .respond(status: 302, headers: ["Location": "https://redirect.stub/other"], body: Data(), url: nil)
        }
        let main: RedirectMainHarness = await connectedMain()
        let pool: CentrifugeRpcPool = CentrifugeRpcPool(
            main: main.client,
            options: redirectOptions(fakeURL: fake.server.url, redirect: redirectHook(to: "https://redirect.stub/start"))
        )
        let outcome: RedirectOutcome = RedirectOutcome("refused redirect")
        startCall(pool, outcome)
        await fulfillment(of: outcome.done, within: 5)
        #expect(kindOf(outcome.error) == "replyError 18")
        // The target of the 3xx answer is never requested: one request in all.
        #expect(fetchesOf(RedirectStubProtocol.book.seen()).count == 1)
        withExtendedLifetime(pool) {}
        withExtendedLifetime(main.delegate) {}
    }


    @Test func runtimeFollowedHopIsRefusedBeforeTheBody() async throws {
        fake.setAnswer(plainAnswer)
        RedirectStubProtocol.book.setRule { (_: URLRequest) -> StubAnswer in
            return .respond(status: 200, headers: [:], body: Data("bytes".utf8), url: URL(string: "https://other.stub/x"))
        }
        let main: RedirectMainHarness = await connectedMain()
        let pool: CentrifugeRpcPool = CentrifugeRpcPool(
            main: main.client,
            options: redirectOptions(fakeURL: fake.server.url, redirect: redirectHook(to: "https://redirect.stub/start"))
        )
        let outcome: RedirectOutcome = RedirectOutcome("followed hop")
        startCall(pool, outcome)
        await fulfillment(of: outcome.done, within: 5)
        #expect(kindOf(outcome.error) == "replyError 18")
        withExtendedLifetime(pool) {}
        withExtendedLifetime(main.delegate) {}
    }


    @Test func redirectDeclaredLengthOverTheLimitFailsBeforeTheBody() async throws {
        fake.setAnswer(plainAnswer)
        RedirectStubProtocol.book.setRule { (_: URLRequest) -> StubAnswer in
            return .respond(status: 200, headers: ["Content-Length": "100"], body: Data("ab".utf8), url: nil)
        }
        let main: RedirectMainHarness = await connectedMain()
        let pool: CentrifugeRpcPool = CentrifugeRpcPool(
            main: main.client,
            options: redirectOptions(fakeURL: fake.server.url, redirect: { (_: CentrifugeReplyOutcome) -> CentrifugeRedirect? in
                return CentrifugeRedirect(url: "https://redirect.stub/big", maxBytes: 4)
            })
        )
        let outcome: RedirectOutcome = RedirectOutcome("declared length")
        startCall(pool, outcome)
        await fulfillment(of: outcome.done, within: 5)
        #expect(kindOf(outcome.error) == "replyError 18")
        withExtendedLifetime(pool) {}
        withExtendedLifetime(main.delegate) {}
    }


    @Test func redirectBodyPastTheLimitFails() async throws {
        fake.setAnswer(plainAnswer)
        RedirectStubProtocol.book.setRule { (_: URLRequest) -> StubAnswer in
            return .respond(status: 200, headers: [:], body: Data("0123456789".utf8), url: nil)
        }
        let main: RedirectMainHarness = await connectedMain()
        let pool: CentrifugeRpcPool = CentrifugeRpcPool(
            main: main.client,
            options: redirectOptions(fakeURL: fake.server.url, redirect: { (_: CentrifugeReplyOutcome) -> CentrifugeRedirect? in
                return CentrifugeRedirect(url: "https://redirect.stub/big", maxBytes: 4)
            })
        )
        let outcome: RedirectOutcome = RedirectOutcome("body over the limit")
        startCall(pool, outcome)
        await fulfillment(of: outcome.done, within: 5)
        #expect(kindOf(outcome.error) == "replyError 18")
        withExtendedLifetime(pool) {}
        withExtendedLifetime(main.delegate) {}
    }


    @Test func httpRedirectIsRefusedFromASecureEndpoint() async throws {
        #expect(allowedRedirectURL("http://cdn.example/x", endpoint: "wss://a.example/connection") == nil)
        #expect(allowedRedirectURL("http://cdn.example/x", endpoint: "https://a.example/") == nil)
        #expect(allowedRedirectURL("https://cdn.example/x", endpoint: "wss://a.example/") != nil)
        #expect(allowedRedirectURL("http://cdn.example/x", endpoint: "ws://a.example/") != nil)
        #expect(allowedRedirectURL("ftp://cdn.example/x", endpoint: "ws://a.example/") == nil)
    }


    @Test func poolLimitsRedirectsAndFailsLoudlyOnBadEndpoint() async throws {
        fake.setAnswer(plainAnswer)
        RedirectStubProtocol.book.setRule { (_: URLRequest) -> StubAnswer in
            return .respond(status: 200, headers: [:], body: Data("bytes".utf8), url: nil)
        }
        let main: RedirectMainHarness = await connectedMain()

        // A URL of another scheme is refused before any request is made.
        let badScheme: CentrifugeRpcPool = CentrifugeRpcPool(
            main: main.client,
            options: redirectOptions(fakeURL: fake.server.url, redirect: redirectHook(to: "ftp://redirect.stub/x"))
        )
        let refused: RedirectOutcome = RedirectOutcome("scheme refused")
        startCall(badScheme, refused)
        await fulfillment(of: refused.done, within: 5)
        #expect(kindOf(refused.error) == "replyError 18")
        #expect(fetchesOf(RedirectStubProtocol.book.seen()).isEmpty)

        // A negative body limit is a configuration error, and no request is made.
        let negativeLimit: CentrifugeRpcPool = CentrifugeRpcPool(
            main: main.client,
            options: redirectOptions(fakeURL: fake.server.url, redirect: { (_: CentrifugeReplyOutcome) -> CentrifugeRedirect? in
                return CentrifugeRedirect(url: "https://redirect.stub/x", maxBytes: -1)
            })
        )
        let negative: RedirectOutcome = RedirectOutcome("negative limit")
        startCall(negativeLimit, negative)
        await fulfillment(of: negative.done, within: 5)
        #expect(kindOf(negative.error) == "configurationError")
        #expect(fetchesOf(RedirectStubProtocol.book.seen()).isEmpty)
        withExtendedLifetime(badScheme) {}
        withExtendedLifetime(negativeLimit) {}
        withExtendedLifetime(main.delegate) {}
    }


    // MARK: hook

    @Test func redirectHookSeesEveryOutcomeAndNilSettlesUnchanged() async throws {
        fake.setAnswer { (command: RpcCommand) -> RpcReply? in
            if command.hasRpc {
                if command.rpc.method == "fail" {
                    return rpcErrorReply(code: 107, message: "refused")
                }
                return resultReply("plain")
            }
            return nil
        }
        let main: RedirectMainHarness = await connectedMain()
        let seen: LockedBox<[String]> = LockedBox([])
        let hook: (CentrifugeReplyOutcome) -> CentrifugeRedirect? = { (outcome: CentrifugeReplyOutcome) -> CentrifugeRedirect? in
            var label: String = ""
            switch outcome {
            case .reply(let result):
                label = "reply " + String(decoding: result.data, as: UTF8.self)
            case .error(let error):
                label = "error " + kindOf(error as? CentrifugeError)
            }
            seen.update { (values: inout [String]) -> Void in
                values.append(label)
            }
            return nil
        }
        let pool: CentrifugeRpcPool = CentrifugeRpcPool(
            main: main.client,
            options: redirectOptions(fakeURL: fake.server.url, redirect: hook)
        )
        let answered: RedirectOutcome = RedirectOutcome("reply")
        startCall(pool, answered, method: "ok")
        await fulfillment(of: answered.done, within: 5)
        let failed: RedirectOutcome = RedirectOutcome("error")
        startCall(pool, failed, method: "fail")
        await fulfillment(of: failed.done, within: 5)

        #expect(answered.data == Data("plain".utf8))
        #expect(kindOf(failed.error) == "replyError 107")
        #expect(seen.current == ["reply plain", "error replyError 107"])
        #expect(fetchesOf(RedirectStubProtocol.book.seen()).isEmpty)
        withExtendedLifetime(pool) {}
        withExtendedLifetime(main.delegate) {}
    }


    // MARK: waiting line, close, cancel and deadline

    @Test func redirectWaiterIsRefusedAtMaxQueuedZero() async throws {
        fake.setAnswer(plainAnswer)
        RedirectStubProtocol.book.setRule { (request: URLRequest) -> StubAnswer in
            return holdFirstAnswerOthers(request)
        }
        let held: HeldRedirects = await startHeldRedirects(maxQueued: 0, maxRedirectsInflight: 1)
        await fulfillment(of: held.second.done, within: 5)
        #expect(kindOf(held.second.error) == "replyError 16")
        #expect(held.pool.stats().redirects == 1)

        RedirectStubProtocol.releaseHeld(Data("first".utf8))
        await fulfillment(of: held.first.done, within: 5)
        #expect(held.first.data == Data("first".utf8))
        withExtendedLifetime(held.pool) {}
        withExtendedLifetime(held.main.delegate) {}
    }


    @Test func redirectWaiterCountsInQueuedAndStartsWhenTheFirstEnds() async throws {
        fake.setAnswer(plainAnswer)
        RedirectStubProtocol.book.setRule { (request: URLRequest) -> StubAnswer in
            return holdFirstAnswerOthers(request)
        }
        let held: HeldRedirects = await startHeldRedirects(maxQueued: 1, maxRedirectsInflight: 1)
        #expect(held.pool.stats().queued == 1)
        #expect(held.pool.stats().redirects == 1)

        RedirectStubProtocol.releaseHeld(Data("first".utf8))
        await fulfillment(of: [held.first.done, held.second.done], within: 5)
        #expect(held.first.data == Data("first".utf8))
        #expect(held.second.data == Data("second".utf8))
        #expect(held.pool.stats().queued == 0)
        #expect(held.pool.stats().redirects == 0)
        withExtendedLifetime(held.pool) {}
        withExtendedLifetime(held.main.delegate) {}
    }


    @Test func poolCloseSettlesAWaitingFetchWithTheClosedError() async throws {
        fake.setAnswer(plainAnswer)
        RedirectStubProtocol.book.setRule { (request: URLRequest) -> StubAnswer in
            return holdFirstAnswerOthers(request)
        }
        let held: HeldRedirects = await startHeldRedirects(maxQueued: 64, maxRedirectsInflight: 1)
        let closed: Expectation = Expectation("pool closed")
        held.pool.close {
            closed.fulfill()
        }
        await fulfillment(of: [closed, held.first.done, held.second.done], within: 5)
        #expect(kindOf(held.first.error) == "connectionClosed")
        #expect(kindOf(held.second.error) == "connectionClosed")
        // The waiting fetch was never requested.
        let paths: [String] = fetchesOf(RedirectStubProtocol.book.seen()).map { (request: URLRequest) -> String in
            return request.url?.path ?? ""
        }
        #expect(paths == ["/first"])
        withExtendedLifetime(held.main.delegate) {}
    }


    @Test func cancelOfAWaitingFetchSettlesCancelled() async throws {
        fake.setAnswer(plainAnswer)
        RedirectStubProtocol.book.setRule { (request: URLRequest) -> StubAnswer in
            return holdFirstAnswerOthers(request)
        }
        let held: HeldRedirects = await startHeldRedirects(maxQueued: 64, maxRedirectsInflight: 1)
        held.secondCall.cancel()
        await fulfillment(of: held.second.done, within: 5)
        #expect(kindOf(held.second.error) == "replyError 17")
        #expect(held.pool.stats().queued == 0)
        #expect(held.pool.stats().redirects == 1)

        RedirectStubProtocol.releaseHeld(Data("first".utf8))
        await fulfillment(of: held.first.done, within: 5)
        #expect(held.first.data == Data("first".utf8))
        withExtendedLifetime(held.pool) {}
        withExtendedLifetime(held.firstCall) {}
        withExtendedLifetime(held.main.delegate) {}
    }


    @Test func theDeadlineCoversTheRedirectFetch() async throws {
        fake.setAnswer(plainAnswer)
        RedirectStubProtocol.book.setRule { (_: URLRequest) -> StubAnswer in
            return .hold
        }
        let main: RedirectMainHarness = await connectedMain()
        let hookSeen: Expectation = Expectation("redirect hooked")
        let hook: (CentrifugeReplyOutcome) -> CentrifugeRedirect? = { (_: CentrifugeReplyOutcome) -> CentrifugeRedirect? in
            hookSeen.fulfill()
            return CentrifugeRedirect(url: "https://redirect.stub/slow")
        }
        let pool: CentrifugeRpcPool = CentrifugeRpcPool(
            main: main.client,
            options: redirectOptions(fakeURL: fake.server.url, redirect: hook)
        )
        let outcome: RedirectOutcome = RedirectOutcome("slow fetch")
        startCall(pool, outcome, timeout: 1)
        await fulfillment(of: hookSeen, within: 5)
        // The fetch is in progress and its deadline timer is armed: the deadline passes on the manual clock.
        await awaitSyncQueue(main.client)
        await main.scheduler.advance(by: 1)
        await fulfillment(of: outcome.done, within: 5)
        #expect(kindOf(outcome.error) == "timeout")
        #expect(pool.stats().redirects == 0)
        withExtendedLifetime(pool) {}
        withExtendedLifetime(main.delegate) {}
    }
}
