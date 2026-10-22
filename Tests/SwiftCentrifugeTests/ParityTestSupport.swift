import Foundation
@testable import SwiftCentrifuge

// Helpers of the tests of the parity features (instance, server time, identity). They are
// built on the public delegate and logger protocols, and on the seams of ManualScheduler.swift.

/// Records the events the parity tests check. The callbacks run on the client's queue; the lists
/// are guarded so that the test thread can read them.
final class RecordingClientDelegate: CentrifugeClientDelegate, @unchecked Sendable {
    /// Fulfilled by every `onConnected`.
    let connected: Expectation
    private let authEvents: LockedBox<[CentrifugeAuthEvent]> = LockedBox([])
    private let errors: LockedBox<[Error]> = LockedBox([])


    init(connected: Expectation) {
        self.connected = connected
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
        connected.fulfill()
    }


    func onAuth(_ client: CentrifugeClient, _ event: CentrifugeAuthEvent) {
        authEvents.update { (values: inout [CentrifugeAuthEvent]) in
            values.append(event)
        }
    }


    func onError(_ client: CentrifugeClient, _ event: CentrifugeErrorEvent) {
        errors.update { (values: inout [Error]) in
            values.append(event.error)
        }
    }
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
