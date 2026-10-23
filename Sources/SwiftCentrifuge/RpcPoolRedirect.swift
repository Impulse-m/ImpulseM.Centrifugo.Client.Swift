import Foundation

// The redirect of a pool call: the outcome the hook sees, the URL check, and the fetch of the bytes. A fetch follows
// no hop, sends only the redirect headers, carries no cookies or credentials, and reads its body under a limit as the
// bytes arrive. The fetches of one pool share `maxRedirectsInflight` slots; a fetch that waits for a slot counts in
// `queued`. The pool's logic is in RpcPool.swift.

/// The outcome of a pool call that reached a connection, as the redirect hook sees it. A timeout, a cancel and a close
/// are the pool's own outcomes: the hook does not see them.
public enum CentrifugeReplyOutcome {
    /// The server answered the call.
    case reply(CentrifugeRpcResult)

    /// The call failed on its connection: a server error reply, or a connection that lost it.
    case error(Error)
}


/// Bytes that the pool fetches from a URL instead of taking them from the reply. The redirect hook returns it.
public struct CentrifugeRedirect {
    /// The absolute URL of the bytes. It must be `https:`, or `http:` when the endpoint is not secure (`wss:` and
    /// `https:` endpoints are secure). Any other URL fails the call with `replyError(code: 18)`, with no request.
    public var url: String

    /// Headers of the fetch. They are the only headers it sends: no cookies and no credentials.
    public var headers: [String: String]

    /// Body bytes accepted at most. Nil means the pool's `maxRedirectBytes`. A negative value fails the call with
    /// `configurationError`.
    public var maxBytes: Int?


    public init(
        url: String,
        headers: [String: String] = [:],
        maxBytes: Int? = nil
    ) {
        self.url = url
        self.headers = headers
        self.maxBytes = maxBytes
    }
}


/// The code of a redirect that did not complete: the fetch failed, or its status, its URL or its body was refused.
internal let rpcCodeRedirectFailed: UInt32 = 18

/// The most a body buffer is reserved for before its bytes arrive, so that a declared length does not allocate up front.
private let redirectInitialBufferBytes: Int = 1024 * 1024


/// Why a redirect fetch failed. The message is fixed per step.
internal struct RpcPoolRedirectFailure: Error {
    internal let message: String
}


/// Whether an endpoint is secure: `wss:` or `https:`. An insecure endpoint may redirect to `http:`.
internal func isSecureEndpoint(_ endpoint: String) -> Bool {
    let lowered: String = endpoint.lowercased()
    return lowered.hasPrefix("wss:") || lowered.hasPrefix("https:")
}


/// The URL of a redirect when the endpoint of the call allows fetching it, or nil. A secure endpoint takes `https:`
/// only; an insecure one takes `https:` and `http:`.
internal func allowedRedirectURL(_ target: String, endpoint: String) -> URL? {
    guard let url: URL = URL(string: target), url.host != nil, let scheme: String = url.scheme?.lowercased() else {
        return nil
    }
    if scheme == "https" {
        return url
    }
    if scheme == "http" && !isSecureEndpoint(endpoint) {
        return url
    }
    return nil
}


/// The absolute string of a URL without its fragment: the form in which a request and its response are compared.
internal func urlWithoutFragment(_ url: URL) -> String {
    guard var parts: URLComponents = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        return url.absoluteString
    }
    parts.fragment = nil
    return parts.string ?? url.absoluteString
}


/// The configuration of a pool's redirect session. It is a fresh ephemeral configuration: the application's session
/// contributes only its transport settings (proxy, TLS, timeouts, URL protocol classes, waiting for connectivity).
/// Its headers, cookies, stored credentials and cache are never copied, so an application header such as
/// `Authorization` never reaches the host that a redirect names.
internal func redirectSessionConfiguration(_ session: URLSession?) -> URLSessionConfiguration {
    let configuration: URLSessionConfiguration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    guard let given: URLSession = session else {
        return configuration
    }
    let source: URLSessionConfiguration = given.configuration
    configuration.connectionProxyDictionary = source.connectionProxyDictionary
    if #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) {
        configuration.tlsMinimumSupportedProtocolVersion = source.tlsMinimumSupportedProtocolVersion
        configuration.tlsMaximumSupportedProtocolVersion = source.tlsMaximumSupportedProtocolVersion
    } else {
        // Older systems only have the deprecated SSLProtocol properties. Their use warns, and does not fail the build.
        configuration.tlsMinimumSupportedProtocol = source.tlsMinimumSupportedProtocol
        configuration.tlsMaximumSupportedProtocol = source.tlsMaximumSupportedProtocol
    }
    configuration.timeoutIntervalForRequest = source.timeoutIntervalForRequest
    configuration.timeoutIntervalForResource = source.timeoutIntervalForResource
    configuration.protocolClasses = source.protocolClasses
    configuration.waitsForConnectivity = source.waitsForConnectivity
    return configuration
}


/// The state of one redirect fetch while its body arrives. The session's delegate queue uses it, and its outcome
/// leaves once, through `finish`.
internal final class RpcPoolFetchBody {
    /// The URL of the request without its fragment: the response must report the same URL.
    internal let requested: String

    /// The body bytes accepted at most.
    internal let maxBytes: Int

    private let finish: (Result<Data, RpcPoolRedirectFailure>) -> Void

    private var buffer: Data = Data()

    private var failure: RpcPoolRedirectFailure? = nil


    internal init(
        requested: String,
        maxBytes: Int,
        finish: @escaping (Result<Data, RpcPoolRedirectFailure>) -> Void
    ) {
        self.requested = requested
        self.maxBytes = maxBytes
        self.finish = finish
    }


    /// Checks the response before its body is read. Returns false when the fetch must stop: a status other than 2xx
    /// (a redirect included), a response that reports another URL than the request, or a declared length over the limit.
    internal func accept(_ response: URLResponse) -> Bool {
        guard let http: HTTPURLResponse = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            fail("redirect fetch status")
            return false
        }
        if let served: URL = response.url, urlWithoutFragment(served) != requested {
            fail("redirect followed by the runtime")
            return false
        }
        if response.expectedContentLength > Int64(maxBytes) {
            fail("redirect body over the limit")
            return false
        }
        if response.expectedContentLength > 0 {
            let reserve: Int = min(Int(response.expectedContentLength), redirectInitialBufferBytes)
            buffer.reserveCapacity(reserve)
        }
        return true
    }


    /// Adds the bytes of a chunk. Returns false when the body passes the limit, and the fetch must stop.
    internal func append(_ chunk: Data) -> Bool {
        if failure != nil {
            return false
        }
        if buffer.count + chunk.count > maxBytes {
            fail("redirect body over the limit")
            return false
        }
        buffer.append(chunk)
        return true
    }


    /// The session ended the fetch. The first failure that was recorded wins over the session's own error.
    internal func end(_ error: Error?) {
        if let recorded: RpcPoolRedirectFailure = failure {
            finish(.failure(recorded))
            return
        }
        if error != nil {
            finish(.failure(RpcPoolRedirectFailure(message: "redirect fetch failed")))
            return
        }
        finish(.success(buffer))
    }


    private func fail(_ message: String) {
        if failure == nil {
            failure = RpcPoolRedirectFailure(message: message)
        }
    }
}


/// The session delegate of the redirect fetches of a pool. It refuses every redirect, so that a 3xx answer is the
/// response, which fails the fetch. It routes the data of each task to the body of that fetch.
internal final class RpcPoolFetchDelegate: NSObject, URLSessionDataDelegate {
    private let lock: NSLock = NSLock()

    private var bodies: [Int: RpcPoolFetchBody] = [:]


    /// Registers the body of a task. Called before the task starts.
    internal func register(_ identifier: Int, _ body: RpcPoolFetchBody) {
        lock.lock()
        bodies[identifier] = body
        lock.unlock()
    }


    internal func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }


    internal func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let body: RpcPoolFetchBody = bodyOf(dataTask) else {
            completionHandler(.cancel)
            return
        }
        completionHandler(body.accept(response) ? .allow : .cancel)
    }


    internal func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        guard let body: RpcPoolFetchBody = bodyOf(dataTask) else {
            return
        }
        if !body.append(data) {
            dataTask.cancel()
        }
    }


    internal func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let body: RpcPoolFetchBody = takeBody(task) else {
            return
        }
        body.end(error)
    }


    private func bodyOf(_ task: URLSessionTask) -> RpcPoolFetchBody? {
        lock.lock()
        defer {
            lock.unlock()
        }
        return bodies[task.taskIdentifier]
    }


    private func takeBody(_ task: URLSessionTask) -> RpcPoolFetchBody? {
        lock.lock()
        defer {
            lock.unlock()
        }
        let body: RpcPoolFetchBody? = bodies[task.taskIdentifier]
        bodies[task.taskIdentifier] = nil
        return body
    }
}


/// One redirect fetch of a pool call: its URL, its headers, the bound of its body, and the settlement of the call.
internal final class RpcPoolFetch {
    internal let call: RpcPoolCall

    internal let url: URL

    internal let headers: [String: String]

    internal let maxBytes: Int

    /// Settles the call with the outcome of the fetch. The pool passes a closure that runs on its queue.
    internal let onDone: (Result<CentrifugeRpcResult, Error>) -> Void

    /// The data task of the fetch, once it starts.
    internal var task: URLSessionDataTask? = nil


    internal init(
        call: RpcPoolCall,
        url: URL,
        headers: [String: String],
        maxBytes: Int,
        onDone: @escaping (Result<CentrifugeRpcResult, Error>) -> Void
    ) {
        self.call = call
        self.url = url
        self.headers = headers
        self.maxBytes = maxBytes
        self.onDone = onDone
    }


    /// The request of the fetch: a GET with the redirect headers only.
    internal func makeRequest() -> URLRequest {
        var request: URLRequest = URLRequest(url: url)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        for header: (key: String, value: String) in headers {
            request.setValue(header.value, forHTTPHeaderField: header.key)
        }
        return request
    }
}


/// The redirect fetches of one pool: the slots they hold, the line of fetches that wait for one, and the session that
/// runs them. The pool calls it on its queue; the session reports back to that queue.
internal final class RpcPoolFetches {
    private let queue: DispatchQueue

    private let limit: Int

    private let configuration: URLSessionConfiguration

    private let delegate: RpcPoolFetchDelegate = RpcPoolFetchDelegate()

    private var session: URLSession? = nil

    /// The fetches that hold a slot.
    private var running: [RpcPoolFetch] = []

    /// The fetches that wait for a slot, in arrival order.
    private var waiting: [RpcPoolFetch] = []


    internal init(
        queue: DispatchQueue,
        limit: Int,
        configuration: URLSessionConfiguration
    ) {
        self.queue = queue
        self.limit = limit
        self.configuration = configuration
    }


    deinit {
        session?.finishTasksAndInvalidate()
    }


    /// The fetches that hold a slot.
    internal var runningCount: Int {
        return running.count
    }


    /// The fetches that wait for a slot.
    internal var waitingCount: Int {
        return waiting.count
    }


    /// Whether every slot is held, so that a fetch asked now would wait for one.
    internal var isFull: Bool {
        return running.count >= limit
    }


    /// The calls of the fetches that run or wait, for the pool's deadline timer.
    internal var calls: [RpcPoolCall] {
        var all: [RpcPoolCall] = []
        for fetch: RpcPoolFetch in running {
            all.append(fetch.call)
        }
        for fetch: RpcPoolFetch in waiting {
            all.append(fetch.call)
        }
        return all
    }


    /// Adds a fetch to the line, and starts the fetches that a free slot takes.
    internal func request(_ fetch: RpcPoolFetch) {
        waiting.append(fetch)
        startWaiting()
    }


    /// Removes the fetch of a call, cancelling it when it runs. Returns false when the call has no fetch.
    internal func cancel(_ call: RpcPoolCall) -> Bool {
        if take(call) == nil {
            return false
        }
        startWaiting()
        return true
    }


    /// Ends the fetches whose call deadline passed, cancelling those that run, and starts the waiting fetches that a
    /// slot now takes. Returns the calls that expired.
    internal func expire(now: UInt64) -> [RpcPoolCall] {
        var expired: [RpcPoolCall] = []
        var keptRunning: [RpcPoolFetch] = []
        for fetch: RpcPoolFetch in running {
            if fetch.call.deadline <= now {
                fetch.task?.cancel()
                expired.append(fetch.call)
            } else {
                keptRunning.append(fetch)
            }
        }
        running = keptRunning
        var keptWaiting: [RpcPoolFetch] = []
        for fetch: RpcPoolFetch in waiting {
            if fetch.call.deadline <= now {
                expired.append(fetch.call)
            } else {
                keptWaiting.append(fetch)
            }
        }
        waiting = keptWaiting
        startWaiting()
        return expired
    }


    /// Cancels every fetch and ends the session. The pool settles the calls.
    internal func close() {
        for fetch: RpcPoolFetch in running {
            fetch.task?.cancel()
        }
        running = []
        waiting = []
        session?.invalidateAndCancel()
        session = nil
    }


    /// Removes the fetch of a call from either line. Returns it, or nil when the call has no fetch.
    private func take(_ call: RpcPoolCall) -> RpcPoolFetch? {
        if let index: Int = waiting.firstIndex(where: { (candidate: RpcPoolFetch) -> Bool in
            return candidate.call === call
        }) {
            return waiting.remove(at: index)
        }
        if let index: Int = running.firstIndex(where: { (candidate: RpcPoolFetch) -> Bool in
            return candidate.call === call
        }) {
            let fetch: RpcPoolFetch = running.remove(at: index)
            fetch.task?.cancel()
            return fetch
        }
        return nil
    }


    /// Starts the waiting fetches, in arrival order, while a slot is free.
    private func startWaiting() {
        while running.count < limit && !waiting.isEmpty {
            let fetch: RpcPoolFetch = waiting.removeFirst()
            start(fetch)
        }
    }


    /// Starts one fetch: its task, registered before it resumes, holds a slot until the session reports its end.
    private func start(_ fetch: RpcPoolFetch) {
        let queue: DispatchQueue = self.queue
        let body: RpcPoolFetchBody = RpcPoolFetchBody(
            requested: urlWithoutFragment(fetch.url),
            maxBytes: fetch.maxBytes
        ) { [weak self] (outcome: Result<Data, RpcPoolRedirectFailure>) -> Void in
            queue.async {
                self?.completed(fetch, outcome)
            }
        }
        let target: URLSession = currentSession()
        let task: URLSessionDataTask = target.dataTask(with: fetch.makeRequest())
        fetch.task = task
        running.append(fetch)
        delegate.register(task.taskIdentifier, body)
        task.resume()
    }


    /// The session reported the end of a fetch. A fetch that was taken out already (cancelled, expired, closed) is
    /// ignored. The call settles with the bytes, or with `replyError(code: 18)`.
    private func completed(_ fetch: RpcPoolFetch, _ outcome: Result<Data, RpcPoolRedirectFailure>) {
        guard let index: Int = running.firstIndex(where: { (candidate: RpcPoolFetch) -> Bool in
            return candidate === fetch
        }) else {
            return
        }
        running.remove(at: index)
        startWaiting()
        switch outcome {
        case .success(let data):
            fetch.onDone(.success(CentrifugeRpcResult(data: data)))
        case .failure(let failure):
            fetch.onDone(.failure(CentrifugeError.replyError(code: rpcCodeRedirectFailed, message: failure.message, temporary: false)))
        }
    }


    /// The session of the fetches, made on the first fetch. Its callbacks run on one serial queue of their own.
    private func currentSession() -> URLSession {
        if let existing: URLSession = session {
            return existing
        }
        let operations: OperationQueue = OperationQueue()
        operations.maxConcurrentOperationCount = 1
        let created: URLSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: operations)
        session = created
        return created
    }
}
