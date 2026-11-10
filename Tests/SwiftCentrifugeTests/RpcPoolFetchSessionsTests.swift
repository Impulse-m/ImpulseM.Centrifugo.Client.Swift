import Foundation
import Network
import Testing
@testable import SwiftCentrifuge

/// Unit tests of the session choice of the redirect fetches: a session is kept while the transport settings of its source
/// stay the same, and a new one is made when they change. No network: the sessions are made and never used.
@Suite(.timeLimit(.minutes(1)))
struct RpcPoolFetchSessionsTests {

    /// A URL protocol class that never handles a request. It only makes a protocol class list that differs from the empty one.
    private final class MarkerProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool {
            return false
        }


        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            return request
        }
    }


    /// An ephemeral configuration whose HTTPS proxy is the given host.
    private func makeConfiguration(proxyHost: String) -> URLSessionConfiguration {
        let configuration: URLSessionConfiguration = URLSessionConfiguration.ephemeral
        let proxy: [AnyHashable: Any] = ["HTTPSProxy": proxyHost]
        configuration.connectionProxyDictionary = proxy
        return configuration
    }


    /// Sessions for a source. The `make` closure counts its calls in `makes`, and makes a session that is never used.
    private func makeSessions(
        source: RpcPoolRedirectSource,
        makes: LockedBox<Int>
    ) -> RpcPoolFetchSessions {
        return RpcPoolFetchSessions(
            source: source,
            make: { (configuration: URLSessionConfiguration) -> URLSession in
                makes.update { (count: inout Int) -> Void in
                    count += 1
                }
                return URLSession(configuration: configuration)
            }
        )
    }


    @Test func aSourceReadOnceKeepsOneSession() {
        let asks: LockedBox<Int> = LockedBox<Int>(0)
        let makes: LockedBox<Int> = LockedBox<Int>(0)
        let source: RpcPoolRedirectSource = RpcPoolRedirectSource(
            configuration: { () -> URLSessionConfiguration in
                asks.update { (count: inout Int) -> Void in
                    count += 1
                }
                return self.makeConfiguration(proxyHost: "proxy.example")
            },
            perFetch: false
        )
        let sessions: RpcPoolFetchSessions = makeSessions(source: source, makes: makes)
        let first: URLSession = sessions.current()
        let second: URLSession = sessions.current()
        let third: URLSession = sessions.current()
        #expect(first === second)
        #expect(second === third)
        #expect(makes.current == 1)
        #expect(asks.current == 1)
        sessions.close()
    }


    @Test func aProviderWithTheSameSettingsKeepsItsSession() {
        let asks: LockedBox<Int> = LockedBox<Int>(0)
        let makes: LockedBox<Int> = LockedBox<Int>(0)
        let source: RpcPoolRedirectSource = RpcPoolRedirectSource(
            configuration: { () -> URLSessionConfiguration in
                asks.update { (count: inout Int) -> Void in
                    count += 1
                }
                return self.makeConfiguration(proxyHost: "proxy.example")
            },
            perFetch: true
        )
        let sessions: RpcPoolFetchSessions = makeSessions(source: source, makes: makes)
        let first: URLSession = sessions.current()
        let second: URLSession = sessions.current()
        let third: URLSession = sessions.current()
        #expect(first === second)
        #expect(second === third)
        #expect(makes.current == 1)
        #expect(asks.current == 3)
        sessions.close()
    }


    @Test func aChangeOfTheProxyMakesANewSession() {
        let host: LockedBox<String> = LockedBox<String>("proxy-a.example")
        let makes: LockedBox<Int> = LockedBox<Int>(0)
        let source: RpcPoolRedirectSource = RpcPoolRedirectSource(
            configuration: { () -> URLSessionConfiguration in
                return self.makeConfiguration(proxyHost: host.current)
            },
            perFetch: true
        )
        let sessions: RpcPoolFetchSessions = makeSessions(source: source, makes: makes)
        let first: URLSession = sessions.current()
        host.set("proxy-b.example")
        let second: URLSession = sessions.current()
        #expect(first !== second)
        #expect(makes.current == 2)
        let third: URLSession = sessions.current()
        #expect(third === second)
        #expect(makes.current == 2)
        sessions.close()
    }


    @Test func closeEndsTheSessionAndTheNextFetchGetsANewOne() {
        let makes: LockedBox<Int> = LockedBox<Int>(0)
        let source: RpcPoolRedirectSource = RpcPoolRedirectSource(
            configuration: { () -> URLSessionConfiguration in
                return self.makeConfiguration(proxyHost: "proxy.example")
            },
            perFetch: false
        )
        let sessions: RpcPoolFetchSessions = makeSessions(source: source, makes: makes)
        let first: URLSession = sessions.current()
        sessions.close()
        let second: URLSession = sessions.current()
        #expect(first !== second)
        #expect(makes.current == 2)
        sessions.close()
    }


    @Test func aSourceWithProxyConfigurationsGetsASessionForEachFetch() {
        guard #available(
            macOS 14.0,
            iOS 17.0,
            watchOS 10.0,
            tvOS 17.0,
            *
        ) else {
            return
        }
        let endpoint: NWEndpoint = NWEndpoint.hostPort(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: 3128)!
        )
        let proxy: ProxyConfiguration = ProxyConfiguration(httpCONNECTProxy: endpoint)
        let configuration: URLSessionConfiguration = URLSessionConfiguration.ephemeral
        configuration.proxyConfigurations = [proxy]
        let makes: LockedBox<Int> = LockedBox<Int>(0)
        let source: RpcPoolRedirectSource = RpcPoolRedirectSource(
            configuration: { () -> URLSessionConfiguration in
                return configuration
            },
            perFetch: true
        )
        let sessions: RpcPoolFetchSessions = makeSessions(source: source, makes: makes)
        let first: URLSession = sessions.current()
        let second: URLSession = sessions.current()
        #expect(first !== second)
        #expect(makes.current == 2)
        sessions.close()
    }


    @Test func sameRedirectTransportComparesTheCopiedSettings() {
        let left: URLSessionConfiguration = self.makeConfiguration(proxyHost: "proxy.example")
        let sameHost: URLSessionConfiguration = self.makeConfiguration(proxyHost: "proxy.example")
        #expect(sameRedirectTransport(left, sameHost))

        let otherHost: URLSessionConfiguration = self.makeConfiguration(proxyHost: "other.example")
        #expect(!sameRedirectTransport(left, otherHost))

        let noProxy: URLSessionConfiguration = URLSessionConfiguration.ephemeral
        #expect(!sameRedirectTransport(left, noProxy))
        #expect(sameRedirectTransport(URLSessionConfiguration.ephemeral, URLSessionConfiguration.ephemeral))

        let requestLeft: URLSessionConfiguration = URLSessionConfiguration.ephemeral
        let requestRight: URLSessionConfiguration = URLSessionConfiguration.ephemeral
        requestRight.timeoutIntervalForRequest = requestLeft.timeoutIntervalForRequest + 1
        #expect(!sameRedirectTransport(requestLeft, requestRight))

        let resourceLeft: URLSessionConfiguration = URLSessionConfiguration.ephemeral
        let resourceRight: URLSessionConfiguration = URLSessionConfiguration.ephemeral
        resourceRight.timeoutIntervalForResource = resourceLeft.timeoutIntervalForResource + 1
        #expect(!sameRedirectTransport(resourceLeft, resourceRight))

        let connectivityLeft: URLSessionConfiguration = URLSessionConfiguration.ephemeral
        let connectivityRight: URLSessionConfiguration = URLSessionConfiguration.ephemeral
        connectivityRight.waitsForConnectivity = !connectivityLeft.waitsForConnectivity
        #expect(!sameRedirectTransport(connectivityLeft, connectivityRight))

        let classesLeft: URLSessionConfiguration = URLSessionConfiguration.ephemeral
        let classesRight: URLSessionConfiguration = URLSessionConfiguration.ephemeral
        let emptyClasses: [AnyClass] = []
        classesLeft.protocolClasses = emptyClasses
        let oneClass: [AnyClass] = [MarkerProtocol.self]
        classesRight.protocolClasses = oneClass
        #expect(!sameRedirectTransport(classesLeft, classesRight))
    }
}
