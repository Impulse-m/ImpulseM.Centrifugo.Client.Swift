import Foundation
import Testing
@testable import SwiftCentrifuge

/// The server time of a client: the offset that each command reply with a time
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


    /// A push carries the same `time` field, but only a command reply sets the offset. The same
    /// time in a reply does set it, so the push case is not passing for want of a reply.
    @Test func serverTimeIsTakenOnlyFromReplies() async {
        serveRpcTimes()
        let connected: Expectation = Expectation("connected")
        let messageArrived: Expectation = Expectation("message push arrived")
        let delegate: RecordingClientDelegate = RecordingClientDelegate(connected: connected, messageArrived: messageArrived)
        let setup: ManualClientSetup = makeManualClient(endpoint: server.url, config: CentrifugeClientConfig(), delegate: delegate)
        setup.client.connect()
        await fulfillment(of: [connected], within: 5)

        var push: Centrifugal_Centrifuge_Protocol_Push = Centrifugal_Centrifuge_Protocol_Push()
        push.message = Centrifugal_Centrifuge_Protocol_Message()
        var pushReply: Centrifugal_Centrifuge_Protocol_Reply = Centrifugal_Centrifuge_Protocol_Reply()
        pushReply.time = setup.clock.wallMillis() + 500
        pushReply.push = push
        server.sendReply(pushReply)
        await fulfillment(of: [messageArrived], within: 5)
        #expect(setup.client.serverTimeMillis() == setup.clock.wallMillis(), "a push with a time does not set the offset")

        let serverTime: Int64 = setup.clock.wallMillis() + 500
        replyTime.set(serverTime)
        await runRpc(setup.client)
        #expect(setup.client.serverTimeMillis() == serverTime, "the same time in a command reply does")
        withExtendedLifetime(delegate) {}
    }


    /// A reply time more than 365 days from the local clock, and a time whose difference
    /// overflows, leave the offset as it was. Nothing traps.
    @Test func serverTimeIgnoresAnImplausibleReplyTime() async {
        serveRpcTimes()
        let connected: Expectation = Expectation("connected")
        let delegate: RecordingClientDelegate = RecordingClientDelegate(connected: connected)
        let setup: ManualClientSetup = makeManualClient(endpoint: server.url, config: CentrifugeClientConfig(), delegate: delegate)
        let serverTime: Int64 = setup.clock.wallMillis() + 500
        replyTime.set(serverTime)
        setup.client.connect()
        await fulfillment(of: [connected], within: 5)

        await runRpc(setup.client)
        #expect(setup.client.serverTimeMillis() == serverTime)

        let fourHundredDays: Int64 = 400 * 86_400_000
        let implausible: [Int64] = [Int64.max, Int64.min, setup.clock.wallMillis() + fourHundredDays]
        for time: Int64 in implausible {
            replyTime.set(time)
            await runRpc(setup.client)
            #expect(setup.client.serverTimeMillis() == serverTime, "a reply time of \(time) keeps the offset")
        }
        withExtendedLifetime(delegate) {}
    }


    /// A reply that arrives after its call timed out answers no pending command, so it does not
    /// set the offset. The next call's reply is ordered after it on the connection.
    @Test func lateReplyToATimedOutCallDoesNotSetTheOffset() async {
        serveRpcTimes()
        let silent: LockedBox<Bool> = LockedBox(true)
        let droppedId: LockedBox<UInt32> = LockedBox(0)
        let dropped: Expectation = Expectation("rpc reached the server")
        server.dropCommand = { (command: Centrifugal_Centrifuge_Protocol_Command) -> Bool in
            guard command.hasRpc, silent.current else {
                return false
            }
            droppedId.set(command.id)
            dropped.fulfill()
            return true
        }
        let connected: Expectation = Expectation("connected")
        let delegate: RecordingClientDelegate = RecordingClientDelegate(connected: connected)
        let setup: ManualClientSetup = makeManualClient(endpoint: server.url, config: CentrifugeClientConfig(), delegate: delegate)
        setup.client.connect()
        await fulfillment(of: [connected], within: 5)

        let expired: Expectation = Expectation("rpc timed out")
        setup.client.rpc(method: "method", data: Data()) { (result: Result<CentrifugeRpcResult, Error>) in
            expired.fulfill()
        }
        await fulfillment(of: [dropped], within: 5)
        await setup.scheduler.advance(by: setup.client.config.timeout)
        await fulfillment(of: [expired], within: 5)

        var late: Centrifugal_Centrifuge_Protocol_Reply = Centrifugal_Centrifuge_Protocol_Reply()
        late.id = droppedId.current
        late.time = setup.clock.wallMillis() + 500
        late.rpc = Centrifugal_Centrifuge_Protocol_RPCResult()
        server.sendReply(late)

        silent.set(false)
        replyTime.set(0)
        await runRpc(setup.client)
        #expect(setup.client.serverTimeMillis() == setup.clock.wallMillis(), "a late reply to an expired call does not set the offset")
        withExtendedLifetime(delegate) {}
    }
}
