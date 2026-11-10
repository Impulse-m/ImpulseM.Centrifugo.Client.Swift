import Foundation
import Testing

/// In CI the proxy suites must run; a run that lost the variable fails here instead of skipping them unseen.
@Suite struct ProxyTestEnvironmentTests {
    @Test func proxySuitesRunInCI() {
        let continuousIntegration: String? = ProcessInfo.processInfo.environment["CI"]
        guard continuousIntegration == "true" else {
            return
        }
        #expect(proxyTestHost() != nil, "CENTRIFUGE_PROXY_TEST_HOST is not set in CI, so the proxy suites were skipped")
    }
}
