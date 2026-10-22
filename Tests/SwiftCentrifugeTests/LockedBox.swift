import Foundation

/// A value that the test doubles of the new tests share between threads, guarded by a lock.
/// The older test files keep their own private copies; they stay as they are upstream.
final class LockedBox<T>: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var value: T


    init(_ value: T) {
        self.value = value
    }


    var current: T {
        lock.lock()
        defer {
            lock.unlock()
        }
        return value
    }


    func set(_ newValue: T) {
        lock.lock()
        value = newValue
        lock.unlock()
    }


    func update(_ body: (inout T) -> Void) {
        lock.lock()
        defer {
            lock.unlock()
        }
        body(&value)
    }
}
