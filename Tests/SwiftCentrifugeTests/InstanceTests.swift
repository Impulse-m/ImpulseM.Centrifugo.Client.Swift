import Foundation
import Testing
@testable import SwiftCentrifuge

/// The instance of a client: its validation at `create`, what `init` does with
/// an invalid one, the connect request and the debug log. Driven by FakeCentrifugoServer.
@Suite(.serialized, .timeLimit(.minutes(1)))
final class InstanceTests: @unchecked Sendable {
    /// 22 characters, all in the allowed set.
    private let validInstance: String = "Xk3pQ9vL2mR7tYw4Zb8Nc6"
    private let server: FakeCentrifugoServer


    init() throws {
        server = FakeCentrifugoServer()
        try server.start()
    }


    deinit {
        server.stop()
    }


    /// The connect request the client sent, or nil when it sent none.
    private func connectRequest() -> Centrifugal_Centrifuge_Protocol_ConnectRequest? {
        let command: Centrifugal_Centrifuge_Protocol_Command? = server.received().first { (command: Centrifugal_Centrifuge_Protocol_Command) -> Bool in
            return command.hasConnect
        }
        return command?.connect
    }


    @Test func invalidInstanceIsRefusedAtCreate() {
        let invalidInstances: [String] = [
            "",
            "short",
            String(repeating: "a", count: 65),
            "Xk3pQ9vL2mR7tYw4Zb8Nc!",
            "Xk3pQ9vL2mR7tYw4Zb8Nc\u{e9}"
        ]
        for invalid: String in invalidInstances {
            var config: CentrifugeClientConfig = CentrifugeClientConfig()
            config.instance = invalid
            do {
                _ = try CentrifugeClient.create(endpoint: server.url, config: config)
                Issue.record("create accepted the instance \(invalid.count) characters long")
            } catch CentrifugeError.configurationError(let message) {
                #expect(invalid.isEmpty || !message.contains(invalid), "the error text does not contain the instance")
            } catch {
                Issue.record("create threw \(error) instead of configurationError")
            }
        }
    }


    @Test func validInstanceIsAcceptedAtCreate() throws {
        var config: CentrifugeClientConfig = CentrifugeClientConfig()
        config.instance = validInstance
        let client: CentrifugeClient = try CentrifugeClient.create(endpoint: server.url, config: config)
        #expect(client.configError == nil)
    }


    @Test func instanceLengthBoundsAreInclusive() {
        #expect(instanceConfigurationError(String(repeating: "a", count: 21)) != nil)
        #expect(instanceConfigurationError(String(repeating: "a", count: 22)) == nil)
        #expect(instanceConfigurationError(String(repeating: "a", count: 64)) == nil)
        #expect(instanceConfigurationError(String(repeating: "a", count: 65)) != nil)
        #expect(instanceConfigurationError(nil) == nil, "an absent instance is valid")
    }


    /// `init` returns a client for an invalid instance. It reports the error through `onError`
    /// at connect() and fails every rpc() with it at once.
    @Test func invalidInstanceIsReportedByInitAtConnectAndFailsRpc() async {
        var config: CentrifugeClientConfig = CentrifugeClientConfig()
        config.instance = "short"
        let delegate: RecordingClientDelegate = RecordingClientDelegate(connected: Expectation("never connected"))
        let setup: ManualClientSetup = makeManualClient(endpoint: server.url, config: config, delegate: delegate)
        let failed: Expectation = Expectation("rpc failed with the configuration error")
        setup.client.connect()
        setup.client.rpc(method: "method", data: Data()) { (result: Result<CentrifugeRpcResult, Error>) in
            if case .failure(let error) = result, case CentrifugeError.configurationError = error {
                failed.fulfill()
            }
        }
        await fulfillment(of: [failed], within: 5)
        #expect(delegate.reportedErrors.count == 1, "connect() reports the error once")
        #expect(server.received().isEmpty, "nothing is sent for an invalid configuration")
        withExtendedLifetime(delegate) {}
    }


    /// The debug log shows the redacted instance and never the instance itself.
    @Test func instanceIsNotWrittenToTheDebugLog() async {
        let logger: CapturingLogger = CapturingLogger()
        var config: CentrifugeClientConfig = CentrifugeClientConfig()
        config.instance = validInstance
        config.logger = logger
        let connected: Expectation = Expectation("connected")
        let delegate: RecordingClientDelegate = RecordingClientDelegate(connected: connected)
        let setup: ManualClientSetup = makeManualClient(endpoint: server.url, config: config, delegate: delegate)
        setup.client.connect()
        await fulfillment(of: [connected], within: 5)

        let lines: [String] = logger.all
        let leaked: [String] = lines.filter { (line: String) -> Bool in
            return line.contains(validInstance)
        }
        #expect(lines.contains("connect instance=<redacted>"), "the connect line is redacted")
        #expect(leaked.isEmpty, "no log line contains the instance")
        withExtendedLifetime(delegate) {}
    }


    /// The connect request carries the instance and the RPC options flag (bit 32).
    @Test func connectRequestCarriesTheInstanceAndTheRpcOptionsFlag() async {
        var config: CentrifugeClientConfig = CentrifugeClientConfig()
        config.instance = validInstance
        let connected: Expectation = Expectation("connected")
        let delegate: RecordingClientDelegate = RecordingClientDelegate(connected: connected)
        let setup: ManualClientSetup = makeManualClient(endpoint: server.url, config: config, delegate: delegate)
        setup.client.connect()
        await fulfillment(of: [connected], within: 5)

        let request: Centrifugal_Centrifuge_Protocol_ConnectRequest? = connectRequest()
        #expect(request?.instance == validInstance)
        #expect(request?.flag == Int64(1) << 32, "the connect request advertises bit 32")
        withExtendedLifetime(delegate) {}
    }


    /// Without an instance the connect request carries no instance.
    @Test func connectRequestHasNoInstanceWhenUnset() async {
        let connected: Expectation = Expectation("connected")
        let delegate: RecordingClientDelegate = RecordingClientDelegate(connected: connected)
        let setup: ManualClientSetup = makeManualClient(endpoint: server.url, config: CentrifugeClientConfig(), delegate: delegate)
        setup.client.connect()
        await fulfillment(of: [connected], within: 5)

        #expect(connectRequest()?.instance == "")
        withExtendedLifetime(delegate) {}
    }
}
