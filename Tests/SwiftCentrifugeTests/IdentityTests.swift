import Foundation
import Testing
@testable import SwiftCentrifuge

/// The identity of a connection (parity spec F5): the `onAuth` event of each connect, and of each
/// refresh that changes the user or the auth class. The refreshes are the timer refreshes, driven by
/// the test clock, so no real time passes.
@Suite(.serialized, .timeLimit(.minutes(1)))
final class IdentityTests: @unchecked Sendable {
    private let server: FakeCentrifugoServer


    init() throws {
        server = FakeCentrifugoServer()
        try server.start()
    }


    deinit {
        server.stop()
    }


    /// Returns once every block enqueued on the client's queue before this call has run.
    private func awaitSyncQueue(_ client: CentrifugeClient) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            client.syncQueue.async {
                continuation.resume()
            }
        }
    }


    /// Answers every refresh with the user in `users`, a ttl of 10 s and expiry set, so the
    /// connection refreshes again 10 s after each refresh.
    private func serveRefreshes(users: LockedBox<String>) {
        server.onCommand = { (command: Centrifugal_Centrifuge_Protocol_Command) -> Centrifugal_Centrifuge_Protocol_Reply? in
            guard command.hasRefresh else {
                return nil
            }
            var result: Centrifugal_Centrifuge_Protocol_RefreshResult = Centrifugal_Centrifuge_Protocol_RefreshResult()
            result.expires = true
            result.ttl = 10
            result.user = users.current
            var reply: Centrifugal_Centrifuge_Protocol_Reply = Centrifugal_Centrifuge_Protocol_Reply()
            reply.id = command.id
            reply.refresh = result
            return reply
        }
    }


    /// Advances the test clock to the next timer refresh, with the server answering `user`. Returns
    /// once the refresh has been processed: the next refresh is armed only after the identity check.
    private func runRefresh(
        _ setup: ManualClientSetup,
        user: String,
        users: LockedBox<String>,
        rescheduled: LockedBox<Expectation?>
    ) async {
        users.set(user)
        let armed: Expectation = Expectation("next refresh armed")
        rescheduled.set(armed)
        await setup.scheduler.advance(by: 10)
        await fulfillment(of: [armed], within: 5)
        rescheduled.set(nil)
    }


    @Test func authEventFiresOnConnectAndWhenTheIdentityChanges() async {
        let users: LockedBox<String> = LockedBox("alice")
        serveRefreshes(users: users)
        server.connectResult.user = "alice"
        server.connectResult.expires = true
        server.connectResult.ttl = 10

        var config: CentrifugeClientConfig = CentrifugeClientConfig()
        config.tokenGetter = { (event: CentrifugeConnectionTokenEvent, completion: @escaping (Result<String, Error>) -> Void) in
            completion(.success("token"))
        }
        let connected: Expectation = Expectation("connected")
        let delegate: RecordingClientDelegate = RecordingClientDelegate(connected: connected)
        let setup: ManualClientSetup = makeManualClient(endpoint: server.url, config: config, delegate: delegate)
        setup.client.connect()
        await fulfillment(of: [connected], within: 5)
        // onAuth follows onConnected on the same queue block; wait for that block to finish.
        await awaitSyncQueue(setup.client)
        #expect(delegate.authUsers == ["alice"], "one event at connect")

        let rescheduled: LockedBox<Expectation?> = LockedBox(nil)
        setup.scheduler.observe { (call: ScheduledCall) in
            if !call.lateGrace {
                rescheduled.current?.fulfill()
            }
        }

        await runRefresh(setup, user: "alice", users: users, rescheduled: rescheduled)
        #expect(delegate.authEventsSoFar.count == 1, "a refresh with the same identity reports nothing")

        await runRefresh(setup, user: "bob", users: users, rescheduled: rescheduled)
        #expect(delegate.authUsers == ["alice", "bob"], "a changed identity is reported")

        await runRefresh(setup, user: "bob", users: users, rescheduled: rescheduled)
        #expect(delegate.authEventsSoFar.count == 2, "the same changed identity is not reported again")
        withExtendedLifetime(delegate) {}
    }
}
