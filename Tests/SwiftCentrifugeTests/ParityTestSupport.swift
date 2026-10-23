import Foundation
import Testing
@testable import SwiftCentrifuge

// Helpers of the tests of the parity features (instance, server time, identity). They are
// built on the public delegate and logger protocols, and on the seams of ManualScheduler.swift.
//
// A test file that calls `fulfillment` or `Issue.record` must import Testing, even when it uses
// nothing else from it: their source location defaults to `#_sourceLocation`, a Testing macro, and
// the Swift 6.1.2 compiler crashes on that default in a file that does not import it.

/// Counts the events of one kind and lets a test wait until a count is reached. The count can be read
/// and waited on from any thread (see ArrivalLog.swift).
final class EventCounter: @unchecked Sendable {
    private let events: ArrivalLog<Void> = ArrivalLog()


    /// The events counted so far.
    var total: Int {
        return events.total
    }


    /// Counts one event and fulfils the waiters that it reaches.
    func record() {
        events.record(())
    }


    /// Suspends until `times` events have been counted.
    func awaitCount(times: Int) async {
        await events.awaitArrivals("counted events", count: times) { (_: Void) -> Bool in
            return true
        }
    }
}


extension EventCounter {
    /// Suspends until the client has handled the `count`-th push, which the delegate counts in
    /// onMessage. That callback runs after the push's frame was decoded, so it is the sync point before a
    /// test moves the clock past the push (the timers of the client see the push first).
    func awaitPushArrival(count: Int) async {
        await awaitCount(times: count)
    }
}


/// Records the events the parity tests check. The callbacks run on the client's queue; the lists
/// are guarded so that the test thread can read them.
final class RecordingClientDelegate: CentrifugeClientDelegate, @unchecked Sendable {
    /// Fulfilled by every `onConnected`.
    let connected: Expectation
    /// Counts every `onMessage`, so a test can wait for the pushes it sends.
    let messages: EventCounter = EventCounter()
    private let authEvents: LockedBox<[CentrifugeAuthEvent]> = LockedBox([])
    private let errors: LockedBox<[Error]> = LockedBox([])
    private let connectingCodes: LockedBox<[UInt32]> = LockedBox([])
    private let connectedCounter: EventCounter = EventCounter()
    private let connectingCounter: EventCounter = EventCounter()
    /// Fulfilled by every `onMessage`, when one was given.
    private let messageArrived: Expectation?


    init(connected: Expectation, messageArrived: Expectation? = nil) {
        self.connected = connected
        self.messageArrived = messageArrived
    }


    /// Suspends until `times` connects have been reported.
    func awaitConnected(times: Int) async {
        await connectedCounter.awaitCount(times: times)
    }


    /// Suspends until `times` connecting events have been reported. `connect()` reports one of them
    /// too, so a test counts from `connectingEvents`.
    func awaitConnecting(times: Int) async {
        await connectingCounter.awaitCount(times: times)
    }


    /// The connecting events reported so far.
    var connectingEvents: Int {
        return connectingCounter.total
    }


    /// The codes of the connecting events so far, in order.
    var connectingCodesSoFar: [UInt32] {
        return connectingCodes.current
    }


    /// Every identity event so far, in order.
    var authEventsSoFar: [CentrifugeAuthEvent] {
        return authEvents.current
    }


    /// The users of the identity events so far, in order.
    var authUsers: [String] {
        return authEvents.current.map { (event: CentrifugeAuthEvent) -> String in
            return event.user
        }
    }


    /// Every error reported through `onError` so far, in order.
    var reportedErrors: [Error] {
        return errors.current
    }


    func onConnected(_ client: CentrifugeClient, _ event: CentrifugeConnectedEvent) {
        connectedCounter.record()
        connected.fulfill()
    }


    func onConnecting(_ client: CentrifugeClient, _ event: CentrifugeConnectingEvent) {
        connectingCounter.record()
        connectingCodes.update { (values: inout [UInt32]) in
            values.append(event.code)
        }
    }


    func onAuth(_ client: CentrifugeClient, _ event: CentrifugeAuthEvent) {
        authEvents.update { (values: inout [CentrifugeAuthEvent]) in
            values.append(event)
        }
    }


    func onMessage(_ client: CentrifugeClient, _ event: CentrifugeMessageEvent) {
        messages.record()
        messageArrived?.fulfill()
    }


    func onError(_ client: CentrifugeClient, _ event: CentrifugeErrorEvent) {
        errors.update { (values: inout [Error]) in
            values.append(event.error)
        }
    }
}


/// Client delegate whose callbacks call the closures the test sets. The callbacks run on the client's queue.
final class ClosureClientDelegate: CentrifugeClientDelegate, @unchecked Sendable {
    var onConn: (() -> Void)?
    var onErr: ((CentrifugeErrorEvent) -> Void)?
    var onDisc: ((CentrifugeDisconnectedEvent) -> Void)?
    var onAuthEvent: ((CentrifugeAuthEvent) -> Void)?


    func onConnected(_ client: CentrifugeClient, _ event: CentrifugeConnectedEvent) {
        onConn?()
    }


    func onError(_ client: CentrifugeClient, _ event: CentrifugeErrorEvent) {
        onErr?(event)
    }


    func onDisconnected(_ client: CentrifugeClient, _ event: CentrifugeDisconnectedEvent) {
        onDisc?(event)
    }


    func onAuth(_ client: CentrifugeClient, _ event: CentrifugeAuthEvent) {
        onAuthEvent?(event)
    }
}


/// Subscription delegate whose callbacks call the closures the test sets. The callbacks run on the client's queue.
final class ClosureSubscriptionDelegate: CentrifugeSubscriptionDelegate, @unchecked Sendable {
    var onSub: (() -> Void)?
    var onErr: ((CentrifugeSubscriptionErrorEvent) -> Void)?


    func onSubscribed(_ subscription: CentrifugeSubscription, _ event: CentrifugeSubscribedEvent) {
        onSub?()
    }


    func onUnsubscribed(_ subscription: CentrifugeSubscription, _ event: CentrifugeUnsubscribedEvent) {
    }


    func onError(_ subscription: CentrifugeSubscription, _ event: CentrifugeSubscriptionErrorEvent) {
        onErr?(event)
    }
}


/// Returns once every block enqueued on the client's queue before this call has run.
func awaitSyncQueue(_ client: CentrifugeClient) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        client.syncQueue.async {
            continuation.resume()
        }
    }
}


/// The number of timers armed on the manual clock so far that are not command timeouts.
func nonLateTimerCount(_ scheduler: ManualScheduler) -> Int {
    return scheduler.scheduledCalls.filter { (call: ScheduledCall) -> Bool in
        return !call.lateGrace
    }.count
}


/// The delay of the last timer armed on the manual clock that is not a command timeout.
func lastNonLateTimerDelay(_ scheduler: ManualScheduler) -> TimeInterval? {
    return scheduler.scheduledCalls.last(where: { (call: ScheduledCall) -> Bool in
        return !call.lateGrace
    })?.delay
}


/// A client together with the clock and the scheduler it was built with.
struct ManualClientSetup {
    let client: CentrifugeClient
    let clock: ManualClock
    let scheduler: ManualScheduler
}


/// Builds a client on a ManualClock and a ManualScheduler. The client's own factory makes the
/// scheduler, so it runs on the client's queue; the factory runs inside the initializer. `onFactory`
/// receives the clock the factory was given, which is the clock of the client.
func makeManualClient(
    endpoint: String,
    config: CentrifugeClientConfig,
    delegate: CentrifugeClientDelegate? = nil,
    random: ClientRandom? = nil,
    onFactory: ((ClientClock) -> Void)? = nil
) -> ManualClientSetup {
    let clock: ManualClock = ManualClock()
    let holder: LockedBox<ManualScheduler?> = LockedBox(nil)
    let client: CentrifugeClient = CentrifugeClient(
        endpoint: endpoint,
        config: config,
        delegate: delegate,
        clock: clock,
        schedulerFactory: { (queue: DispatchQueue, factoryClock: ClientClock) -> ClientScheduler in
            onFactory?(factoryClock)
            let manual: ManualScheduler = ManualScheduler(
                queue: queue,
                clock: clock
            )
            holder.set(manual)
            return manual
        },
        random: random ?? SystemClientRandom()
    )
    // The factory runs inside the client's initializer, so the holder is always filled by now.
    let scheduler: ManualScheduler = holder.current!
    return ManualClientSetup(client: client, clock: clock, scheduler: scheduler)
}


/// Keeps every line of the debug log, whatever its level.
final class CapturingLogger: CentrifugeLogger, @unchecked Sendable {
    private let messages: LockedBox<[String]> = LockedBox([])


    /// Every message so far, in order.
    var all: [String] {
        return messages.current
    }


    func log(
        level: CentrifugeLoggerLevel,
        message: @autoclosure () -> String,
        file: StaticString,
        function: StaticString,
        line: UInt
    ) {
        let text: String = message()
        messages.update { (values: inout [String]) in
            values.append(text)
        }
    }
}
