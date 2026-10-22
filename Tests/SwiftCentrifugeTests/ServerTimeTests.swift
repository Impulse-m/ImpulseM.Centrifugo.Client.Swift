import Foundation
import Testing
@testable import SwiftCentrifuge

/// The server time of a client (parity spec F4): the offset that each command reply with a time
/// sets, read through `serverTimeMillis()`. The clock is the test clock, so every value is exact.
@Suite(.serialized, .timeLimit(.minutes(1)))
final class ServerTimeTests: @unchecked Sendable {
    private let server: FakeCentrifugoServer
    /// The `time` of the next rpc reply; 0 makes the reply carry no time.
    private let replyTime: LockedBox<Int64> = LockedBox(0)


    init() throws {
        server = FakeCentrifugoServer()
        try server.start()
    }


    deinit {
        server.stop()
    }


    /// Answers every rpc with a reply that carries the time in `replyTime`. The box is captured,
    /// not the test, so the server does not keep the test alive.
    private func serveRpcTimes() {
        let times: LockedBox<Int64> = replyTime
        server.onCommand = { (command: Centrifugal_Centrifuge_Protocol_Command) -> Centrifugal_Centrifuge_Protocol_Reply? in
            guard command.hasRpc else {
                return nil
            }
            var reply: Centrifugal_Centrifuge_Protocol_Reply = Centrifugal_Centrifuge_Protocol_Reply()
            reply.id = command.id
            reply.time = times.current
            reply.rpc = Centrifugal_Centrifuge_Protocol_RPCResult()
            return reply
        }
    }


    /// Makes one rpc call and returns once its completion has run. The offset of its reply is
    /// set before the completion runs.
    private func runRpc(_ client: CentrifugeClient) async {
        let done: Expectation = Expectation("rpc completed")
        client.rpc(method: "method", data: Data()) { (result: Result<CentrifugeRpcResult, Error>) in
            done.fulfill()
        }
        await fulfillment(of: [done], within: 5)
    }


    @Test func serverTimeIsLocalTimeBeforeAnyReplyCarriesIt() {
        let setup: ManualClientSetup = makeManualClient(endpoint: server.url, config: CentrifugeClientConfig())
        #expect(setup.client.serverTimeMillis() == setup.clock.wallMillis())

        setup.clock.advance(by: 2.5)
        #expect(setup.client.serverTimeMillis() == setup.clock.wallMillis(), "the local clock moves on")
    }


    @Test func serverTimeFollowsReplyTime() async {
        serveRpcTimes()
        let connected: Expectation = Expectation("connected")
        let delegate: RecordingClientDelegate = RecordingClientDelegate(connected: connected)
        let setup: ManualClientSetup = makeManualClient(endpoint: server.url, config: CentrifugeClientConfig(), delegate: delegate)
        let serverTime: Int64 = setup.clock.wallMillis() + 500
        replyTime.set(serverTime)
        setup.client.connect()
        await fulfillment(of: [connected], within: 5)

        await runRpc(setup.client)
        #expect(setup.client.serverTimeMillis() == serverTime, "the offset is the reply time minus the local time")

        setup.clock.advance(by: 1)
        #expect(setup.client.serverTimeMillis() == serverTime + 1000, "the server time moves with the local clock")
        withExtendedLifetime(delegate) {}
    }


    @Test func replyWithoutServerTimeKeepsLastOffset() async {
        serveRpcTimes()
        let connected: Expectation = Expectation("connected")
        let delegate: RecordingClientDelegate = RecordingClientDelegate(connected: connected)
        let setup: ManualClientSetup = makeManualClient(endpoint: server.url, config: CentrifugeClientConfig(), delegate: delegate)
        let serverTime: Int64 = setup.clock.wallMillis() + 500
        replyTime.set(serverTime)
        setup.client.connect()
        await fulfillment(of: [connected], within: 5)

        await runRpc(setup.client)
        replyTime.set(0)
        await runRpc(setup.client)
        #expect(setup.client.serverTimeMillis() == serverTime, "a reply without a time keeps the offset")

        setup.clock.advance(by: 1)
        #expect(setup.client.serverTimeMillis() == serverTime + 1000)
        withExtendedLifetime(delegate) {}
    }
}
