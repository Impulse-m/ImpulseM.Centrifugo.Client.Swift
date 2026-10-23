import Foundation
import Testing
@testable import SwiftCentrifuge

// The ping watchdog (table T6): one timer per connection, which re-arms itself from the replies the
// client has decoded. The time is the ManualClock of ManualScheduler.swift and moves only when a test
// advances it. Every push the test depends on is awaited before the advance, so no test sleeps.
//
// The connection of these tests has a ping of 5 s and a server ping delay of 5 s: the window is 10 s.

/// A connected client on the manual clock, with the delegate that records its events.
private struct WatchdogConnection {
    let setup: ManualClientSetup
    let delegate: WatchdogDelegate
}


/// Counts the messages (pushes) and the connecting events, with their codes, of one client.
private final class WatchdogDelegate: CentrifugeClientDelegate, @unchecked Sendable {
    let connected: Expectation = Expectation("connected")
    let pushes: EventCounter = EventCounter()
    private let connectingCodes: LockedBox<[UInt32]> = LockedBox([])


    /// The codes of the connecting events so far, in order.
    var codes: [UInt32] {
        return connectingCodes.current
    }


    func onConnected(_ client: CentrifugeClient, _ event: CentrifugeConnectedEvent) {
        connected.fulfill()
    }


    func onConnecting(_ client: CentrifugeClient, _ event: CentrifugeConnectingEvent) {
        connectingCodes.update { (values: inout [UInt32]) in
            values.append(event.code)
        }
    }


    func onMessage(_ client: CentrifugeClient, _ event: CentrifugeMessageEvent) {
        pushes.record()
    }
}


@Suite(.serialized, .timeLimit(.minutes(1)))
final class PingWatchdogTests: @unchecked Sendable {
    private let fake: FakeRpcServer


    init() throws {
        fake = try FakeRpcServer()
    }


    deinit {
        fake.server.stop()
    }


    // MARK: helpers

    private func connectResult(pong: Bool) -> FakeCentrifugoServer.PConnectResult {
        var result: FakeCentrifugoServer.PConnectResult = FakeCentrifugoServer.PConnectResult()
        result.client = "fake-client"
        result.version = "0.0.0"
        result.ping = 5
        result.pong = pong
        return result
    }


    private func watchdogConfig() -> CentrifugeClientConfig {
        var config: CentrifugeClientConfig = CentrifugeClientConfig()
        config.maxServerPingDelay = 5
        return config
    }


    private func messagePush() -> FakeCentrifugoServer.PPush {
        var push: FakeCentrifugoServer.PPush = FakeCentrifugoServer.PPush()
        push.message = Centrifugal_Centrifuge_Protocol_Message()
        return push
    }


    /// A pong is the empty command the client writes for a server ping: it has no command id.
    private func isPong(_ command: RpcCommand) -> Bool {
        return command.id == 0 && !command.hasConnect
    }


    /// Connects a client on the manual clock. Returns once the connect is reported and the connect
    /// reply has armed the watchdog: the queue is drained, so the arming is in place.
    private func connectedClient(pong: Bool) async -> WatchdogConnection {
        fake.server.connectResult = connectResult(pong: pong)
        let delegate: WatchdogDelegate = WatchdogDelegate()
        let setup: ManualClientSetup = makeManualClient(
            endpoint: fake.server.url,
            config: watchdogConfig(),
            delegate: delegate
        )
        setup.client.connect()
        await fulfillment(of: delegate.connected, within: 5)
        await awaitSyncQueue(setup.client)
        return WatchdogConnection(setup: setup, delegate: delegate)
    }


    // MARK: tests

    /// A push 90% into the window moves the close to one full window after the push.
    @Test func pingWatchdogRestartsOnAnyReply() async {
        let connection: WatchdogConnection = await connectedClient(pong: false)
        let setup: ManualClientSetup = connection.setup
        let delegate: WatchdogDelegate = connection.delegate
        // The connect reply armed the watchdog at t0, due at t0 + 10 s.
        await setup.scheduler.advance(by: 9)
        fake.server.sendPush(messagePush())
        await awaitPushArrival(delegate.pushes, count: 1)
        // The timer fires at t0 + 10 s. The push was 1 s ago, so the timer re-arms for 9 s: due at t0 + 19 s.
        await setup.scheduler.advance(by: 1)
        #expect(setup.client.state == .connected)
        await setup.scheduler.advance(by: 8.5)
        #expect(setup.client.state == .connected)
        #expect(!delegate.codes.contains(connectingCodeNoPing))
        // At t0 + 19 s the connection has been silent for one full window after the push.
        await setup.scheduler.advance(by: 0.5)
        #expect(delegate.codes.contains(connectingCodeNoPing))
        withExtendedLifetime(delegate) {}
    }


    /// A server ping is a reply too. The close comes exactly one window after the last reply.
    @Test func silenceAfterAnyReplyClosesWithinOneWindow() async {
        let connection: WatchdogConnection = await connectedClient(pong: true)
        let setup: ManualClientSetup = connection.setup
        let delegate: WatchdogDelegate = connection.delegate
        await setup.scheduler.advance(by: 4)
        // The server ping is the last reply, at t0 + 4 s. The pong it gets back is the sync point.
        fake.server.sendReply(FakeCentrifugoServer.PReply())
        await fake.awaitArrivals("pong", { (command: RpcCommand) -> Bool in
            return self.isPong(command)
        })
        // The timer fires at t0 + 10 s, 6 s after the ping, and re-arms for 4 s: due at t0 + 14 s.
        await setup.scheduler.advance(by: 6)
        #expect(setup.client.state == .connected)
        await setup.scheduler.advance(by: 3.5)
        #expect(setup.client.state == .connected)
        // One window after the ping, at t0 + 14 s, the connection closes with no ping.
        await setup.scheduler.advance(by: 0.5)
        #expect(delegate.codes.contains(connectingCodeNoPing))
        withExtendedLifetime(delegate) {}
    }


    /// A server ping still gets its pong: one empty command, sent back once.
    @Test func serverPingStillGetsItsPong() async {
        let connection: WatchdogConnection = await connectedClient(pong: true)
        let setup: ManualClientSetup = connection.setup
        let delegate: WatchdogDelegate = connection.delegate
        fake.server.sendReply(FakeCentrifugoServer.PReply())
        await fake.awaitArrivals("pong", { (command: RpcCommand) -> Bool in
            return self.isPong(command)
        })
        let pongs: [RpcCommand] = fake.allCommands().filter { (command: RpcCommand) -> Bool in
            return self.isPong(command)
        }
        #expect(pongs.count == 1)
        #expect(setup.client.state == .connected)
        withExtendedLifetime(delegate) {}
    }


    /// A thousand reply batches arm no timer: the watchdog's one timer is the only one, armed at connect.
    @Test func replyBatchesCreateNoTimer() async {
        let connection: WatchdogConnection = await connectedClient(pong: false)
        let setup: ManualClientSetup = connection.setup
        let delegate: WatchdogDelegate = connection.delegate
        let armedAtConnect: Int = setup.scheduler.scheduledCalls.count
        for _ in 0 ..< 1000 {
            fake.server.sendPush(messagePush())
        }
        await awaitPushArrival(delegate.pushes, count: 1000)
        #expect(setup.scheduler.scheduledCalls.count == armedAtConnect)
        withExtendedLifetime(delegate) {}
    }
}
