import Testing
@testable import SwiftCentrifuge

/// The command id counter (CommandId.swift). Pure: the wrap is reached by seeding it.
@Suite(.timeLimit(.minutes(1)))
final class CommandIdCounterTests: @unchecked Sendable {

    @Test func firstIdIsOne() {
        var counter: CommandIdCounter = CommandIdCounter()
        #expect(counter.next() == 1)
        #expect(counter.next() == 2)
    }

    /// Past UInt32.max the counter wraps without trapping, and it skips 0: the server
    /// sends pushes and pings with id 0.
    @Test func commandIdWrapsWithoutTrapping() {
        var counter: CommandIdCounter = CommandIdCounter(last: UInt32.max - 1)
        #expect(counter.next() == UInt32.max)
        let wrapped: UInt32 = counter.next()
        #expect(wrapped == 1, "0 is skipped")
        #expect(wrapped != 0)
    }
}
