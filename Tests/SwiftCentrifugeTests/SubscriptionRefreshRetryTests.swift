import Foundation
import Testing
@testable import SwiftCentrifuge

// The retry of a failed subscription token refresh, on the manual clock: the retry waits the timer refresh
// backoff of the subscription's own failure count, drawn from the injected random source.

/// Client delegate of these tests: reports the connect.
private final class SubRetryClientDelegate: CentrifugeClientDelegate, @unchecked Sendable {
    var onConn: (() -> Void)?


    func onConnected(_ client: CentrifugeClient, _ event: CentrifugeConnectedEvent) {
        onConn?()
    }
}


/// Subscription delegate of these tests: each callback calls the closure the test set.
private final class SubRetrySubDelegate: CentrifugeSubscriptionDelegate, @unchecked Sendable {
    var onSub: (() -> Void)?
    var onErr: ((CentrifugeSubscriptionErrorEvent) -> Void)?


    func onSubscribed(_ s: CentrifugeSubscription, _ e: CentrifugeSubscribedEvent) {
        onSub?()
    }


    func onUnsubscribed(_ s: CentrifugeSubscription, _ e: CentrifugeUnsubscribedEvent) {
    }


    func onError(_ s: CentrifugeSubscription, _ e: CentrifugeSubscriptionErrorEvent) {
        onErr?(e)
    }
}


@Suite(.serialized, .timeLimit(.minutes(1)))
final class SubscriptionRefreshRetryTests: @unchecked Sendable {
    private let server: FakeCentrifugoServer


    init() throws {
        server = FakeCentrifugoServer()
        // The subscription token expires after 10 seconds, so the refresh is armed on the manual clock.
        server.onSubscribe = { _, _ in
            var result: FakeCentrifugoServer.PSubscribeResult = FakeCentrifugoServer.PSubscribeResult()
            result.expires = true
            result.ttl = 10
            return result
        }
        try server.start()
    }


    deinit {
        server.stop()
    }


    /// The first failed subscription refresh is reported with the server's code, and its retry is armed with the
    /// first step of the backoff: 10 s with draw 0, from the injected random source.
    @Test func subscriptionRefreshRetryWaitsTheBackoffOfItsFirstFailure() async throws {
        let connected: Expectation = Expectation("connected")
        let subscribed: Expectation = Expectation("subscribed")
        let refused: Expectation = Expectation("refresh refused and reported")
        let clientDelegate: SubRetryClientDelegate = SubRetryClientDelegate()
        clientDelegate.onConn = {
            connected.fulfill()
        }
        let subDelegate: SubRetrySubDelegate = SubRetrySubDelegate()
        subDelegate.onSub = {
            subscribed.fulfill()
        }
        subDelegate.onErr = { (event: CentrifugeSubscriptionErrorEvent) in
            if case CentrifugeError.subscriptionRefreshError(let err) = event.error,
               case CentrifugeError.replyError(let code, _, _) = err, code == 109 {
                refused.fulfill()
            }
        }
        server.onCommand = { (command: FakeCentrifugoServer.PCommand) -> FakeCentrifugoServer.PReply? in
            guard command.hasSubRefresh else {
                return nil
            }
            var reply: FakeCentrifugoServer.PReply = FakeCentrifugoServer.PReply()
            reply.id = command.id
            reply.error.code = 109
            reply.error.message = "token expired"
            return reply
        }
        let setup: ManualClientSetup = makeManualClient(
            endpoint: server.url,
            config: CentrifugeClientConfig(),
            delegate: clientDelegate,
            random: ManualRandom(draw: 0)
        )
        setup.client.connect()
        await fulfillment(of: connected, within: 5)
        var config: CentrifugeSubscriptionConfig = CentrifugeSubscriptionConfig()
        config.token = "initial"
        config.tokenGetter = { (_: CentrifugeSubscriptionTokenEvent, completion: @escaping (Result<String, Error>) -> Void) in
            completion(.success("refreshed-token"))
        }
        let subscription: CentrifugeSubscription = try setup.client.newSubscription(channel: "ch", delegate: subDelegate, config: config)
        subscription.subscribe()
        await fulfillment(of: subscribed, within: 5)
        // The subscribe result armed the refresh at its ttl; advancing the manual clock fires it.
        await setup.scheduler.advance(by: 10)
        await fulfillment(of: refused, within: 5)
        // The refusal is reported after its retry is armed, so the last non-late call is the retry: 10 s at draw 0.
        let delays: [TimeInterval] = setup.scheduler.scheduledCalls.filter { (call: ScheduledCall) -> Bool in
            return !call.lateGrace
        }.map { (call: ScheduledCall) -> TimeInterval in
            return call.delay
        }
        #expect(delays.last == 10)
        withExtendedLifetime(clientDelegate) {}
    }
}
