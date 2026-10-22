import Foundation
import Testing
@testable import SwiftCentrifuge

// Helpers of the tests of the parity features (instance, server time, identity). They are
// built on the public delegate and logger protocols, and on the seams of ManualScheduler.swift.
//
// A test file that calls `fulfillment` or `Issue.record` must import Testing, even when it uses
// nothing else from it: their source location defaults to `#_sourceLocation`, a Testing macro, and
// the Swift 6.1.2 compiler crashes on that default in a file that does not import it.

/// Counts the events of one kind and lets a test wait until a count is reached. Guarded by a lock, so
/// the count can be read and waited on from any thread.
final class EventCounter: @unchecked Sendable {
    /// One waiter of `awaitCount`: fulfilled once the count reaches `target`.
    private struct Waiter {
        let target: Int
        let expectation: Expectation
    }


    private let lock: NSLock = NSLock()
    private var count: Int = 0
    private var waiters: [Waiter] = []


    /// The events counted so far.
    var total: Int {
        lock.lock()
        defer {
            lock.unlock()
        }
        return self.count
    }


    /// Counts one event and fulfils the waiters that it reaches.
    func record() {
        var ready: [Expectation] = []
        lock.lock()
        self.count += 1
        let reached: Int = self.count
        self.waiters = self.waiters.filter { (waiter: Waiter) -> Bool in
            if reached >= waiter.target {
                ready.append(waiter.expectation)
                return false
            }
            return true
        }
        lock.unlock()
        for expectation: Expectation in ready {
            expectation.fulfill()
        }
    }


    /// Suspends until `times` events have been counted.
    func awaitCount(times: Int) async {
        let expectation: Expectation = Expectation("counted events")
        if registerWaiter(target: times, expectation: expectation) {
            return
        }
        await fulfillment(of: expectation, within: 5)
    }


    /// Adds a waiter unless the count is already reached, and tells whether it is. Synchronous, so the
    /// lock is never taken from an async context.
    private func registerWaiter(target: Int, expectation: Expectation) -> Bool {
        lock.lock()
        defer {
            lock.unlock()
        }
        if self.count >= target {
            return true
        }
        self.waiters.append(Waiter(target: target, expectation: expectation))
        return false
    }
}


/// Records the events the parity tests check. The callbacks run on the client's queue; the lists
/// are guarded so that the test thread can read them.
final class RecordingClientDelegate: CentrifugeClientDelegate, @unchecked Sendable {
    /// Fulfilled by every `onConnected`.
    let connected: Expectation
    private let authEvents: LockedBox<[CentrifugeAuthEvent]> = LockedBox([])
    private let errors: LockedBox<[Error]> = LockedBox([])
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
    }


    func onAuth(_ client: CentrifugeClient, _ event: CentrifugeAuthEvent) {
        authEvents.update { (values: inout [CentrifugeAuthEvent]) in
            values.append(event)
        }
    }


    func onMessage(_ client: CentrifugeClient, _ event: CentrifugeMessageEvent) {
        messageArrived?.fulfill()
    }


    func onError(_ client: CentrifugeClient, _ event: CentrifugeErrorEvent) {
        errors.update { (values: inout [Error]) in
            values.append(event.error)
        }
    }
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
