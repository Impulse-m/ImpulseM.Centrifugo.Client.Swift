import Foundation
@testable import SwiftCentrifuge

// The server side of the tracked-call tests (parity spec F7 to F9, section 4.2). It composes the
// public hooks of FakeCentrifugoServer and leaves that file untouched: `dropCommand` records every
// command and decides which get no reply, and `onCommand` builds the reply of the rest. The reply id
// is set to the command id here, so a test never has to. Arrivals are awaited through
// `awaitArrivals`, never by sleeping.

typealias RpcCommand = Centrifugal_Centrifuge_Protocol_Command
typealias RpcReply = Centrifugal_Centrifuge_Protocol_Reply


/// The fake server of one test, with the arrival record and the reply rules.
final class FakeRpcServer: @unchecked Sendable {
    /// One waiter of `awaitArrivals`: fulfilled by every arrival that matches.
    private struct Waiter {
        let matches: (RpcCommand) -> Bool
        let expectation: Expectation
    }


    let server: FakeCentrifugoServer
    // Everything below is guarded by `lock`, so an arrival and a waiter cannot miss each other.
    private let lock: NSLock = NSLock()
    private var arrivals: [RpcCommand] = []
    private var waiters: [Waiter] = []
    private var dropRule: ((RpcCommand) -> Bool)? = nil
    private var answerRule: ((RpcCommand) -> RpcReply?)? = nil


    init() throws {
        self.server = FakeCentrifugoServer()
        try self.server.start()
        self.server.dropCommand = { [weak self] (command: RpcCommand) -> Bool in
            guard let owner: FakeRpcServer = self else {
                return false
            }
            return owner.arrived(command)
        }
        self.server.onCommand = { [weak self] (command: RpcCommand) -> RpcReply? in
            guard let owner: FakeRpcServer = self, let answer: (RpcCommand) -> RpcReply? = owner.currentAnswer() else {
                return nil
            }
            guard var reply: RpcReply = answer(command) else {
                return nil
            }
            reply.id = command.id
            return reply
        }
    }


    /// Commands for which the server never replies. Checked when a command arrives.
    func setDrop(_ rule: ((RpcCommand) -> Bool)?) {
        lock.lock()
        self.dropRule = rule
        lock.unlock()
    }


    /// The reply of each command the rules do not drop: nil lets the default (an empty reply) through.
    func setAnswer(_ rule: ((RpcCommand) -> RpcReply?)?) {
        lock.lock()
        self.answerRule = rule
        lock.unlock()
    }


    /// Every command received so far, in arrival order.
    func allCommands() -> [RpcCommand] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return self.arrivals
    }


    /// Suspends until `count` commands matching `matches` have arrived. Commands that arrived earlier
    /// count too.
    func awaitArrivals(_ description: String, count: Int = 1, _ matches: @escaping (RpcCommand) -> Bool) async {
        let expectation: Expectation = Expectation(description)
        expectation.expectedFulfillmentCount = count
        let alreadyArrived: Int = registerWaiter(Waiter(matches: matches, expectation: expectation))
        for _ in 0 ..< min(alreadyArrived, count) {
            expectation.fulfill()
        }
        await fulfillment(of: expectation, within: 5)
    }


    private func currentAnswer() -> ((RpcCommand) -> RpcReply?)? {
        lock.lock()
        defer {
            lock.unlock()
        }
        return self.answerRule
    }


    /// Adds a waiter and returns how many matching commands arrived before it. Kept synchronous so the
    /// lock is never taken from an async context, where NSLock is unavailable.
    private func registerWaiter(_ waiter: Waiter) -> Int {
        lock.lock()
        defer {
            lock.unlock()
        }
        let alreadyArrived: Int = self.arrivals.filter(waiter.matches).count
        self.waiters.append(waiter)
        return alreadyArrived
    }


    /// Records a command, wakes the waiters it matches, and tells whether it gets no reply.
    private func arrived(_ command: RpcCommand) -> Bool {
        var toFulfill: [Expectation] = []
        var drop: Bool = false
        lock.lock()
        self.arrivals.append(command)
        for waiter: Waiter in self.waiters where waiter.matches(command) {
            toFulfill.append(waiter.expectation)
        }
        drop = self.dropRule?(command) ?? false
        lock.unlock()
        for expectation: Expectation in toFulfill {
            expectation.fulfill()
        }
        return drop
    }
}


/// The client delegate of the tracked-call tests: counts the connects and the disconnects, and lets a
/// test wait until a count is reached.
final class RpcTestDelegate: CentrifugeClientDelegate, @unchecked Sendable {
    private enum Event: Hashable {
        case connected
        case connecting
    }


    private struct Waiter {
        let event: Event
        let target: Int
        let expectation: Expectation
    }


    private let lock: NSLock = NSLock()
    private var counts: [Event: Int] = [:]
    private var waiters: [Waiter] = []


    func onConnected(_ client: CentrifugeClient, _ event: CentrifugeConnectedEvent) {
        record(Event.connected)
    }


    func onConnecting(_ client: CentrifugeClient, _ event: CentrifugeConnectingEvent) {
        record(Event.connecting)
    }


    /// Suspends until `times` connects have been reported.
    func awaitConnected(times: Int) async {
        await awaitEvent(Event.connected, times: times)
    }


    /// Suspends until `times` events of the connecting state have been reported. `connect()` reports
    /// one of them too, so a test counts from `connectingEvents`.
    func awaitConnecting(times: Int) async {
        await awaitEvent(Event.connecting, times: times)
    }


    /// The events of the connecting state reported so far.
    var connectingEvents: Int {
        lock.lock()
        defer {
            lock.unlock()
        }
        return self.counts[Event.connecting] ?? 0
    }


    private func record(_ event: Event) {
        var ready: [Expectation] = []
        lock.lock()
        let total: Int = (self.counts[event] ?? 0) + 1
        self.counts[event] = total
        self.waiters = self.waiters.filter { (waiter: Waiter) -> Bool in
            if waiter.event == event && total >= waiter.target {
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


    private func awaitEvent(_ event: Event, times: Int) async {
        let expectation: Expectation = Expectation("delegate event")
        let satisfied: Bool = registerEventWaiter(event, times: times, expectation: expectation)
        if satisfied {
            return
        }
        await fulfillment(of: expectation, within: 5)
    }


    /// Adds a waiter unless the count is already reached, and tells whether it is. Synchronous for the
    /// same reason as `FakeRpcServer.registerWaiter`.
    private func registerEventWaiter(_ event: Event, times: Int, expectation: Expectation) -> Bool {
        lock.lock()
        defer {
            lock.unlock()
        }
        if (self.counts[event] ?? 0) >= times {
            return true
        }
        self.waiters.append(Waiter(event: event, target: times, expectation: expectation))
        return false
    }
}
