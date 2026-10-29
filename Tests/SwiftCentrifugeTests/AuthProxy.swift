import Foundation
import Network

/// An in-process HTTP proxy that asks for Basic credentials, for the integration test of the native
/// transport's proxy support.
///
/// A request without the right `Proxy-Authorization` gets 407, and the connection stays open for the
/// retry. A `CONNECT` with the right credentials becomes a tunnel. An absolute-form request
/// (`GET http://host:port/path`) with the right credentials is forwarded with its request line
/// rewritten to origin-form. Every upstream is 127.0.0.1 on `upstreamPort`, whatever host the client
/// asked for, so the server is reachable through the proxy and directly alike.
///
/// Every connection is handled on one serial queue. Only the counters and the recorded lists are
/// guarded by the lock, because the test reads them from another thread.
final class AuthProxy: @unchecked Sendable {
    /// One client connection, its upstream connection, and the bytes read from the client that are
    /// not handled yet. Only touched on the proxy's queue.
    private final class Exchange: @unchecked Sendable {
        let client: NWConnection
        var upstream: NWConnection?
        var upstreamReady: Bool = false
        var buffer: Data = Data()

        init(client: NWConnection) {
            self.client = client
        }
    }

    private static let headEnd: Data = Data("\r\n\r\n".utf8)

    /// What the proxy does once the upstream connection is up.
    private enum Takeover {
        case tunnel
        case forward(head: Data)
    }

    private let user: String
    private let password: String
    private let upstreamPort: UInt16
    private let queue: DispatchQueue = DispatchQueue(label: "auth.proxy")
    private let lock: NSLock = NSLock()
    private var listener: NWListener?
    private var exchanges: [Exchange] = []
    private var rejectedCount: Int = 0
    private var connectCount: Int = 0
    private var forwardCount: Int = 0
    private var recordedAuthorities: [String] = []
    private var recordedForms: [String] = []
    private var recordedRejections: [String] = []

    init(user: String, password: String, upstreamPort: UInt16) {
        self.user = user
        self.password = password
        self.upstreamPort = upstreamPort
    }

    var port: UInt16 {
        return listener?.port?.rawValue ?? 0
    }

    /// Requests answered with 407 so far.
    var rejected: Int {
        return locked { rejectedCount }
    }

    /// Authenticated CONNECT requests so far.
    var connects: Int {
        return locked { connectCount }
    }

    /// Authenticated absolute-form requests so far.
    var forwards: Int {
        return locked { forwardCount }
    }

    /// The authority (`host:port`) of every authenticated request, in order.
    var authorities: [String] {
        return locked { recordedAuthorities }
    }

    /// The form of every authenticated request, `CONNECT` or `absolute`, in order.
    var forms: [String] {
        return locked { recordedForms }
    }

    /// The request line and the header names of every request answered with 407, in order.
    var rejections: [String] {
        return locked { recordedRejections }
    }

    func start() throws {
        let listener: NWListener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] client in
            self?.accept(client)
        }
        let ready: DispatchSemaphore = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                ready.signal()
            }
        }
        self.listener = listener
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
    }

    func stop() {
        listener?.cancel()
        let all: [Exchange] = locked { exchanges }
        for exchange in all {
            exchange.client.cancel()
            exchange.upstream?.cancel()
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func accept(_ client: NWConnection) {
        let exchange: Exchange = Exchange(client: client)
        locked { exchanges.append(exchange) }
        client.start(queue: queue)
        readMore(exchange)
    }

    /// Reads from the client until the exchange is taken over (tunnel or forward) or closed.
    private func readMore(_ exchange: Exchange) {
        exchange.client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                exchange.buffer.append(data)
            }
            if self.handleBufferedHeads(exchange) {
                return
            }
            if isComplete || error != nil {
                exchange.client.cancel()
                return
            }
            self.readMore(exchange)
        }
    }

    /// Handles every complete request head in the buffer. Returns true when reading must stop:
    /// the exchange was taken over or closed.
    private func handleBufferedHeads(_ exchange: Exchange) -> Bool {
        while let range = exchange.buffer.range(of: AuthProxy.headEnd) {
            let head: Data = exchange.buffer.subdata(in: 0..<range.lowerBound)
            exchange.buffer = exchange.buffer.subdata(in: range.upperBound..<exchange.buffer.count)
            if !handleHead(exchange, head: head) {
                return true
            }
        }
        return false
    }

    /// Returns true when the connection stays open for the next request (a 407 was sent), and false
    /// when the exchange was taken over or closed.
    private func handleHead(_ exchange: Exchange, head: Data) -> Bool {
        let text: String = String(decoding: head, as: UTF8.self)
        let lines: [String] = text.components(separatedBy: "\r\n")
        let requestParts: [Substring] = lines[0].split(separator: " ")
        guard requestParts.count == 3 else {
            send(exchange.client, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            exchange.client.cancel()
            return false
        }
        let method: String = String(requestParts[0])
        let target: String = String(requestParts[1])
        let version: String = String(requestParts[2])

        let headers: [String: String] = parseHeaders(lines)
        let expected: String = "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
        if headers["proxy-authorization"] != expected {
            let names: String = headers.keys.sorted().joined(separator: ",")
            locked {
                rejectedCount += 1
                recordedRejections.append("\(lines[0]) [\(names)]")
            }
            send(exchange.client, "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"test\"\r\nContent-Length: 0\r\n\r\n")
            return true
        }

        if method == "CONNECT" {
            locked {
                connectCount += 1
                recordedAuthorities.append(target)
                recordedForms.append("CONNECT")
            }
            openUpstream(exchange, takeover: .tunnel)
            return false
        }

        if target.hasPrefix("http://"), let components = URLComponents(string: target), let host = components.host {
            let port: Int = components.port ?? 80
            var origin: String = components.path.isEmpty ? "/" : components.path
            if let query = components.percentEncodedQuery {
                origin += "?" + query
            }
            locked {
                forwardCount += 1
                recordedAuthorities.append("\(host):\(port)")
                recordedForms.append("absolute")
            }
            // The rewritten request goes upstream without the proxy's credentials.
            var rewritten: [String] = ["\(method) \(origin) \(version)"]
            for line in lines.dropFirst() where !line.lowercased().hasPrefix("proxy-authorization:") {
                rewritten.append(line)
            }
            let rewrittenHead: Data = Data((rewritten.joined(separator: "\r\n") + "\r\n\r\n").utf8)
            openUpstream(exchange, takeover: .forward(head: rewrittenHead))
            return false
        }

        send(exchange.client, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        exchange.client.cancel()
        return false
    }

    private func parseHeaders(_ lines: [String]) -> [String: String] {
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else {
                continue
            }
            let name: String = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value: String = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return headers
    }

    /// Connects to the local server, then takes the exchange over: a tunnel answers the client with
    /// 200, a forward sends the rewritten head upstream. Either way the bytes already read from the
    /// client go upstream first, and then both directions are piped.
    private func openUpstream(_ exchange: Exchange, takeover: Takeover) {
        let upstream: NWConnection = NWConnection(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: upstreamPort)!, using: .tcp)
        exchange.upstream = upstream
        upstream.stateUpdateHandler = { state in
            switch state {
                case .ready:
                    guard !exchange.upstreamReady else {
                        return
                    }
                    exchange.upstreamReady = true
                    self.finishTakeover(exchange, upstream: upstream, takeover: takeover)

                case .failed, .cancelled:
                    exchange.client.cancel()

                default:
                    break
            }
        }
        upstream.start(queue: queue)
    }

    private func finishTakeover(_ exchange: Exchange, upstream: NWConnection, takeover: Takeover) {
        switch takeover {
            case .tunnel:
                send(exchange.client, "HTTP/1.1 200 Connection Established\r\n\r\n")

            case .forward(let head):
                upstream.send(content: head, completion: .contentProcessed { _ in })
        }
        if !exchange.buffer.isEmpty {
            upstream.send(content: exchange.buffer, completion: .contentProcessed { _ in })
            exchange.buffer = Data()
        }
        pipeBothWays(exchange.client, upstream)
    }

    private func pipeBothWays(_ client: NWConnection, _ upstream: NWConnection) {
        pipe(from: client, to: upstream)
        pipe(from: upstream, to: client)
    }

    private func pipe(from: NWConnection, to: NWConnection) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                to.send(content: data, completion: .contentProcessed { _ in })
            }
            if isComplete || error != nil {
                to.cancel()
                from.cancel()
                return
            }
            self.pipe(from: from, to: to)
        }
    }

    private func send(_ connection: NWConnection, _ text: String) {
        connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
    }
}
