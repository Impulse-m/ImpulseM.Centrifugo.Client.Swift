import Foundation
#if canImport(Network)
import Network
#endif

// The session of a pool's redirect fetches: where its transport settings come from, which of them the redirect session
// takes, and when the session is kept or replaced. The fetches themselves are in RpcPoolRedirect.swift.


/// Where the redirect fetches of a pool take their transport settings: the configuration, and whether it is asked again
/// for each fetch (`perFetch`), so that the session follows the settings a provider returns now.
internal struct RpcPoolRedirectSource {
    internal let configuration: () -> URLSessionConfiguration

    internal let perFetch: Bool
}


/// The source of the redirect fetches. The pool's `urlSession` wins when it is set, and it is read once. Otherwise the
/// main client's `urlSessionConfigurationProvider` is asked for each fetch, and the session is kept while its settings
/// stay the same (RpcPoolFetchSessions). Otherwise the fetches use an ephemeral session.
internal func redirectSource(
    urlSession: URLSession?,
    mainProvider: URLSessionConfigurationProvider?
) -> RpcPoolRedirectSource {
    if let given: URLSession = urlSession {
        let fixed: URLSessionConfiguration = redirectSessionConfiguration(given.configuration)
        return RpcPoolRedirectSource(configuration: { () -> URLSessionConfiguration in
            return fixed
        }, perFetch: false)
    }
    if let provider: URLSessionConfigurationProvider = mainProvider {
        return RpcPoolRedirectSource(configuration: { () -> URLSessionConfiguration in
            return redirectSessionConfiguration(provider())
        }, perFetch: true)
    }
    return RpcPoolRedirectSource(configuration: { () -> URLSessionConfiguration in
        return redirectSessionConfiguration(nil)
    }, perFetch: false)
}


/// The configuration of a pool's redirect session. It is a fresh ephemeral configuration: the given configuration
/// contributes only its transport settings (the proxy dictionary and the proxy configurations, the TLS protocol versions,
/// timeouts, URL protocol classes, waiting for connectivity).
/// Its headers, cookies, stored credentials and cache are never copied, so an application header such as
/// `Authorization` never reaches the host that a redirect names. The comparison in `sameRedirectTransport` covers the
/// same settings: a change here goes with a change there.
internal func redirectSessionConfiguration(_ source: URLSessionConfiguration?) -> URLSessionConfiguration {
    let configuration: URLSessionConfiguration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    guard let source: URLSessionConfiguration = source else {
        return configuration
    }
    configuration.connectionProxyDictionary = source.connectionProxyDictionary
    #if canImport(Network)
    if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
        configuration.proxyConfigurations = source.proxyConfigurations
    }
    #endif
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


/// Whether two configurations of a redirect session give a fetch the same transport: the settings that
/// `redirectSessionConfiguration` copies, and nothing else. A session is kept only while this holds. Proxy
/// configurations cannot be compared, so a configuration that has any matches nothing, and its session serves one fetch.
internal func sameRedirectTransport(_ left: URLSessionConfiguration, _ right: URLSessionConfiguration) -> Bool {
    if !sameProxyDictionary(left.connectionProxyDictionary, right.connectionProxyDictionary) {
        return false
    }
    #if canImport(Network)
    if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
        if !left.proxyConfigurations.isEmpty || !right.proxyConfigurations.isEmpty {
            return false
        }
    }
    #endif
    if #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) {
        if left.tlsMinimumSupportedProtocolVersion != right.tlsMinimumSupportedProtocolVersion {
            return false
        }
        if left.tlsMaximumSupportedProtocolVersion != right.tlsMaximumSupportedProtocolVersion {
            return false
        }
    } else {
        if left.tlsMinimumSupportedProtocol != right.tlsMinimumSupportedProtocol {
            return false
        }
        if left.tlsMaximumSupportedProtocol != right.tlsMaximumSupportedProtocol {
            return false
        }
    }
    if left.timeoutIntervalForRequest != right.timeoutIntervalForRequest {
        return false
    }
    if left.timeoutIntervalForResource != right.timeoutIntervalForResource {
        return false
    }
    if left.waitsForConnectivity != right.waitsForConnectivity {
        return false
    }
    return sameClasses(left.protocolClasses, right.protocolClasses)
}


/// Whether two proxy dictionaries are the same: both absent, or equal key by key.
private func sameProxyDictionary(_ left: [AnyHashable: Any]?, _ right: [AnyHashable: Any]?) -> Bool {
    guard let leftValues: [AnyHashable: Any] = left, let rightValues: [AnyHashable: Any] = right else {
        return left == nil && right == nil
    }
    return NSDictionary(dictionary: leftValues).isEqual(to: rightValues)
}


/// Whether two lists of URL protocol classes are the same classes in the same order.
private func sameClasses(_ left: [AnyClass]?, _ right: [AnyClass]?) -> Bool {
    guard let leftClasses: [AnyClass] = left, let rightClasses: [AnyClass] = right else {
        return left == nil && right == nil
    }
    let leftIdentifiers: [ObjectIdentifier] = leftClasses.map { (item: AnyClass) -> ObjectIdentifier in
        return ObjectIdentifier(item)
    }
    let rightIdentifiers: [ObjectIdentifier] = rightClasses.map { (item: AnyClass) -> ObjectIdentifier in
        return ObjectIdentifier(item)
    }
    return leftIdentifiers == rightIdentifiers
}


/// The session that a pool's redirect fetches run on. A source that is asked for each fetch keeps its session while the
/// transport settings it returns stay the same, so the fetches share connections. When the settings change, the next
/// fetch gets a new session, and the fetches in flight end on the old one, which ends with its last task. The pool calls
/// it on its queue.
internal final class RpcPoolFetchSessions {
    private let source: RpcPoolRedirectSource

    /// Makes a session from a configuration. The owner gives the delegate and the queue of the session.
    private let make: (URLSessionConfiguration) -> URLSession

    private var session: URLSession? = nil

    /// The configuration that `session` was made from, which the next answer of the source is compared with.
    private var settings: URLSessionConfiguration? = nil


    internal init(
        source: RpcPoolRedirectSource,
        make: @escaping (URLSessionConfiguration) -> URLSession
    ) {
        self.source = source
        self.make = make
    }


    /// The session for a fetch that starts now.
    internal func current() -> URLSession {
        if let existing: URLSession = session, !source.perFetch {
            return existing
        }
        // The source is asked at every fetch, which costs one configuration object and no scan: a fetch is a network
        // request, and this is how a change of the proxy reaches the next fetch without any timer or notification.
        let asked: URLSessionConfiguration = source.configuration()
        if let existing: URLSession = session, let made: URLSessionConfiguration = settings, sameRedirectTransport(made, asked) {
            return existing
        }
        // The fetches in flight keep the old session until they end. It takes no new task.
        session?.finishTasksAndInvalidate()
        let created: URLSession = make(asked)
        session = created
        settings = asked
        return created
    }


    /// Ends the session at once, with the tasks it still runs.
    internal func close() {
        session?.invalidateAndCancel()
        session = nil
        settings = nil
    }


    /// Ends the session once its tasks are done.
    internal func finish() {
        session?.finishTasksAndInvalidate()
        session = nil
        settings = nil
    }
}
