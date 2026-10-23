import Foundation
import Testing
@testable import SwiftCentrifuge

// The retry of a failed subscription token refresh, on the manual clock: the retry waits the timer refresh
// backoff of the subscription's own failure count, drawn from the injected random source. The refresh of the
// subscription and the refresh of the connection share one policy (RefreshPolicy.swift).


/// A reply of the fake server to a subscription refresh that fails with a temporary error.
private func temporaryErrorReply(to command: FakeCentrifugoServer.PCommand) -> FakeCentrifugoServer.PReply {
    var reply: FakeCentrifugoServer.PReply = FakeCentrifugoServer.PReply()
    reply.id = command.id
    reply.error.code = 100
    reply.error.message = "try later"
    reply.error.temporary = true
    return reply
}


/// A reply of the fake server to a subscription refresh that fails with `code`, not temporary.
private func refusedReply(to command: FakeCentrifugoServer.PCommand, code: UInt32) -> FakeCentrifugoServer.PReply {
    var reply: FakeCentrifugoServer.PReply = FakeCentrifugoServer.PReply()
    reply.id = command.id
    reply.error.code = code
    reply.error.message = "refused"
    return reply
}


/// A subscription config whose token getter gives `token` and then calls `afterCall`. The getter runs its completion
/// first, so the work the completion queued is ahead of anything `afterCall` signals.
private func refreshingConfig(token: String, afterCall: @escaping () -> Void = {}) -> CentrifugeSubscriptionConfig {
    var config: CentrifugeSubscriptionConfig = CentrifugeSubscriptionConfig()
    config.token = "initial"
    config.tokenGetter = { (_: CentrifugeSubscriptionTokenEvent, completion: @escaping (Result<String, Error>) -> Void) in
        completion(.success(token))
        afterCall()
    }
    return config
}


@Suite(.serialized, .timeLimit(.minutes(1)))
final class SubscriptionRefreshRetryTests: @unchecked Sendable {
    private let server: FakeCentrifugoServer


    init() throws {
        server = FakeCentrifugoServer()
        // The fake server never sends a ping, and these tests move the manual clock past the default ping window
        // (25 s ping plus the server ping delay). With ping set, the watchdog would close the connection on that clock
        // and no reply would arrive, so the suite arms no watchdog. Other suites keep the default connect result.
        // The earlier CI failure that prompted this was not reproduced locally, so this is the only claim made here.
        server.connectResult.ping = 0
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


    /// Connects a client on the manual clock, with `draw` as the random source's position in each range, and
    /// subscribes one channel with `config`. Returns once the subscription is subscribed: its refresh is armed at the
    /// 10 s the server gives.
    private func subscribe(
        draw: Double,
        config: CentrifugeSubscriptionConfig,
        clientDelegate: ClosureClientDelegate,
        subDelegate: ClosureSubscriptionDelegate
    ) async throws -> ManualClientSetup {
        let connected: Expectation = Expectation("connected")
        clientDelegate.onConn = {
            connected.fulfill()
        }
        let setup: ManualClientSetup = makeManualClient(
            endpoint: server.url,
            config: CentrifugeClientConfig(),
            delegate: clientDelegate,
            random: ManualRandom(draw: draw)
        )
        setup.client.connect()
        await fulfillment(of: connected, within: 5)
        let subscribed: Expectation = Expectation("subscribed")
        subDelegate.onSub = {
            subscribed.fulfill()
        }
        let subscription: CentrifugeSubscription = try setup.client.newSubscription(channel: "ch", delegate: subDelegate, config: config)
        subscription.subscribe()
        await fulfillment(of: subscribed, within: 5)
        return setup
    }


    /// The first failed subscription refresh is reported with the server's code, and its retry is armed with the
    /// first step of the backoff: 10 s with draw 0, from the injected random source.
    @Test func subscriptionRefreshRetryWaitsTheBackoffOfItsFirstFailure() async throws {
        let refused: Expectation = Expectation("refresh refused and reported")
        let clientDelegate: ClosureClientDelegate = ClosureClientDelegate()
        let subDelegate: ClosureSubscriptionDelegate = ClosureSubscriptionDelegate()
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
            return refusedReply(to: command, code: 109)
        }
        let setup: ManualClientSetup = try await subscribe(draw: 0, config: refreshingConfig(token: "refreshed-token"), clientDelegate: clientDelegate, subDelegate: subDelegate)
        // The subscribe result armed the refresh at its ttl; advancing the manual clock fires it.
        await setup.scheduler.advance(by: 10)
        await fulfillment(of: refused, within: 5)
        // The refusal is reported after its retry is armed, so the last non-late call is the retry: 10 s at draw 0.
        #expect(lastNonLateTimerDelay(setup.scheduler) == 10)
        withExtendedLifetime(clientDelegate) {}
    }


    /// Consecutive failures of the subscription refresh escalate the retry delay step by step, and stop at the
    /// token retry cap: 10 s to 20 s at step 0, up to 300 s, with draw 1 (the upper bound of each range).
    @Test func retryDelayEscalatesAndStopsAtTheCap() async throws {
        server.onCommand = { (command: FakeCentrifugoServer.PCommand) -> FakeCentrifugoServer.PReply? in
            guard command.hasSubRefresh else {
                return nil
            }
            return temporaryErrorReply(to: command)
        }
        let failures: EventCounter = EventCounter()
        let clientDelegate: ClosureClientDelegate = ClosureClientDelegate()
        let subDelegate: ClosureSubscriptionDelegate = ClosureSubscriptionDelegate()
        subDelegate.onErr = { (event: CentrifugeSubscriptionErrorEvent) in
            if case CentrifugeError.subscriptionRefreshError = event.error {
                failures.record()
            }
        }
        let setup: ManualClientSetup = try await subscribe(draw: 1, config: refreshingConfig(token: "refreshed-token"), clientDelegate: clientDelegate, subDelegate: subDelegate)
        // Round n fires the timer armed before it, then waits for the failure that arms the next retry.
        let expected: [TimeInterval] = [20, 30, 50, 90, 170, 300, 300]
        var delay: TimeInterval = 10
        for index: Int in 0 ..< expected.count {
            await setup.scheduler.advance(by: delay)
            await failures.awaitCount(times: index + 1)
            let armed: TimeInterval = lastNonLateTimerDelay(setup.scheduler) ?? 0
            #expect(armed == expected[index], "retry after failure \(index + 1)")
            delay = armed
        }
        withExtendedLifetime(clientDelegate) {}
    }


    /// A refusal with code 103 keeps the subscription's token: it is reported, and no retry is armed.
    @Test func subscriptionRefreshRefusedWith103IsReportedAndNotRetried() async throws {
        let reports: EventCounter = EventCounter()
        let clientDelegate: ClosureClientDelegate = ClosureClientDelegate()
        let subDelegate: ClosureSubscriptionDelegate = ClosureSubscriptionDelegate()
        subDelegate.onErr = { (event: CentrifugeSubscriptionErrorEvent) in
            if case CentrifugeError.subscriptionRefreshError = event.error {
                reports.record()
            }
        }
        server.onCommand = { (command: FakeCentrifugoServer.PCommand) -> FakeCentrifugoServer.PReply? in
            guard command.hasSubRefresh else {
                return nil
            }
            return refusedReply(to: command, code: 103)
        }
        let setup: ManualClientSetup = try await subscribe(draw: 0, config: refreshingConfig(token: "refreshed-token"), clientDelegate: clientDelegate, subDelegate: subDelegate)
        let armedBefore: Int = nonLateTimerCount(setup.scheduler)
        await setup.scheduler.advance(by: 10)
        await reports.awaitCount(times: 1)
        // A retry would have been armed before the report; none was.
        #expect(nonLateTimerCount(setup.scheduler) == armedBefore)
        withExtendedLifetime(clientDelegate) {}
    }


    /// A refusal with code 109 of a token the server already refused is not sent again: the retry fetches the same
    /// token, and nothing is sent or armed for it.
    @Test func subscriptionRefreshRefusedWith109WithTheSameTokenIsNotSentAgain() async throws {
        let reports: EventCounter = EventCounter()
        let fetches: EventCounter = EventCounter()
        let clientDelegate: ClosureClientDelegate = ClosureClientDelegate()
        let subDelegate: ClosureSubscriptionDelegate = ClosureSubscriptionDelegate()
        subDelegate.onErr = { (event: CentrifugeSubscriptionErrorEvent) in
            if case CentrifugeError.subscriptionRefreshError = event.error {
                reports.record()
            }
        }
        server.onCommand = { (command: FakeCentrifugoServer.PCommand) -> FakeCentrifugoServer.PReply? in
            // The sentinel of the test is a client refresh, which the server accepts.
            if command.hasRefresh && !command.hasSubRefresh {
                var accepted: FakeCentrifugoServer.PReply = FakeCentrifugoServer.PReply()
                accepted.id = command.id
                accepted.refresh = Centrifugal_Centrifuge_Protocol_RefreshResult()
                return accepted
            }
            guard command.hasSubRefresh else {
                return nil
            }
            return refusedReply(to: command, code: 109)
        }
        let config: CentrifugeSubscriptionConfig = refreshingConfig(token: "same-token", afterCall: {
            fetches.record()
        })
        let setup: ManualClientSetup = try await subscribe(draw: 0, config: config, clientDelegate: clientDelegate, subDelegate: subDelegate)
        let armedBeforeRefusal: Int = nonLateTimerCount(setup.scheduler)
        await setup.scheduler.advance(by: 10)
        await reports.awaitCount(times: 1)
        // The refusal armed the retry at 10 s, and the token is remembered as refused.
        #expect(lastNonLateTimerDelay(setup.scheduler) == 10)
        let armedAfterRefusal: Int = nonLateTimerCount(setup.scheduler)
        #expect(armedAfterRefusal == armedBeforeRefusal + 1)

        await setup.scheduler.advance(by: 10)
        // Two fetches in all: the first and the retry. The retry's token is the refused one, so it is not sent.
        await fetches.awaitCount(times: 2)
        await awaitSyncQueue(setup.client)
        #expect(nonLateTimerCount(setup.scheduler) == armedAfterRefusal)
        // A resend would be written on the connection in the retry's decision and would reach the fake server later.
        // A client refresh, answered by the server, orders after it: the connection is one ordered stream.
        let sentinel: Expectation = Expectation("sentinel refresh answered")
        setup.client.refresh(token: "sentinel-token") { (_: Result<CentrifugeRefreshResult, Error>) -> Void in
            sentinel.fulfill()
        }
        await fulfillment(of: [sentinel], within: 5)
        #expect(server.received().filter(\.hasSubRefresh).count == 1, "the refused token is not sent again")
        withExtendedLifetime(clientDelegate) {}
    }


    /// An accepted subscription refresh starts the failure count again: the failure after it waits the first step of
    /// the backoff (20 s with draw 1), not the second.
    @Test func subscriptionRetryCountRestartsAfterAnAcceptedRefresh() async throws {
        // The first and the third refresh fail with a temporary error; the second is accepted with a 10 s expiry.
        let answers: LockedBox<Int> = LockedBox(0)
        server.onCommand = { (command: FakeCentrifugoServer.PCommand) -> FakeCentrifugoServer.PReply? in
            guard command.hasSubRefresh else {
                return nil
            }
            var count: Int = 0
            answers.update { (value: inout Int) in
                value += 1
                count = value
            }
            if count == 2 {
                var reply: FakeCentrifugoServer.PReply = FakeCentrifugoServer.PReply()
                reply.id = command.id
                reply.subRefresh.expires = true
                reply.subRefresh.ttl = 10
                return reply
            }
            return temporaryErrorReply(to: command)
        }
        let failures: EventCounter = EventCounter()
        let clientDelegate: ClosureClientDelegate = ClosureClientDelegate()
        let subDelegate: ClosureSubscriptionDelegate = ClosureSubscriptionDelegate()
        subDelegate.onErr = { (event: CentrifugeSubscriptionErrorEvent) in
            if case CentrifugeError.subscriptionRefreshError = event.error {
                failures.record()
            }
        }
        let setup: ManualClientSetup = try await subscribe(draw: 1, config: refreshingConfig(token: "refreshed-token"), clientDelegate: clientDelegate, subDelegate: subDelegate)
        await setup.scheduler.advance(by: 10)
        await failures.awaitCount(times: 1)
        #expect(lastNonLateTimerDelay(setup.scheduler) == 20)

        // The accepted refresh arms the next refresh at its 10 s expiry. The observer signals that arm.
        let rearmed: EventCounter = EventCounter()
        setup.scheduler.observe { (call: ScheduledCall) in
            if !call.lateGrace && call.delay == 10 {
                rearmed.record()
            }
        }
        await setup.scheduler.advance(by: 20)
        await rearmed.awaitCount(times: 1)

        // The third refresh fails: its retry starts at the first step again, 20 s, not the second step, 30 s.
        await setup.scheduler.advance(by: 10)
        await failures.awaitCount(times: 2)
        #expect(lastNonLateTimerDelay(setup.scheduler) == 20)
        withExtendedLifetime(clientDelegate) {}
    }
}
