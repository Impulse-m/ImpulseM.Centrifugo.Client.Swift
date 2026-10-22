import Foundation
import Testing

// The values a test has seen, in order, and the waiters that let a test wait until enough matching
// values have arrived. The event counter of the parity tests and the fake rpc server are built on it.
//
// A file that calls `fulfillment` must import Testing (see ParityTestSupport.swift).

/// The values recorded so far, with the waiters of `awaitArrivals`. Guarded by one lock, so an arrival
/// and a waiter cannot miss each other.
final class ArrivalLog<Element>: @unchecked Sendable {
    /// One waiter: fulfilled once for each recorded value that matches it.
    private struct Waiter {
        let matches: (Element) -> Bool
        let expectation: Expectation
    }


    private let lock: NSLock = NSLock()
    private var values: [Element] = []
    private var waiters: [Waiter] = []


    /// Every recorded value, in order.
    var all: [Element] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return self.values
    }


    /// The number of recorded values.
    var total: Int {
        lock.lock()
        defer {
            lock.unlock()
        }
        return self.values.count
    }


    /// Records a value and fulfils the waiters that match it.
    func record(_ value: Element) {
        var toFulfill: [Expectation] = []
        lock.lock()
        self.values.append(value)
        for waiter: Waiter in self.waiters where waiter.matches(value) {
            toFulfill.append(waiter.expectation)
        }
        lock.unlock()
        for expectation: Expectation in toFulfill {
            expectation.fulfill()
        }
    }


    /// Suspends until `count` recorded values match `matches`. Values recorded earlier count too.
    func awaitArrivals(_ description: String, count: Int, _ matches: @escaping (Element) -> Bool) async {
        let expectation: Expectation = Expectation(description)
        expectation.expectedFulfillmentCount = count
        let alreadyArrived: Int = registerWaiter(Waiter(matches: matches, expectation: expectation))
        for _ in 0 ..< min(alreadyArrived, count) {
            expectation.fulfill()
        }
        await fulfillment(of: expectation, within: 5)
    }


    /// Adds a waiter and returns how many recorded values match it already. Synchronous, so the lock is
    /// never taken from an async context.
    private func registerWaiter(_ waiter: Waiter) -> Int {
        lock.lock()
        defer {
            lock.unlock()
        }
        let alreadyArrived: Int = self.values.filter(waiter.matches).count
        self.waiters.append(waiter)
        return alreadyArrived
    }
}
