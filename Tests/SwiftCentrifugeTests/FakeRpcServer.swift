import Foundation
import Testing
@testable import SwiftCentrifuge

// The server side of the tracked-call tests. It composes the
// public hooks of FakeCentrifugoServer and leaves that file untouched: `dropCommand` records every
// command and decides which get no reply, and `onCommand` builds the reply of the rest. The reply id
// is set to the command id here, so a test never has to. Arrivals are awaited through
// `awaitArrivals`, never by sleeping.

typealias RpcCommand = Centrifugal_Centrifuge_Protocol_Command
typealias RpcReply = Centrifugal_Centrifuge_Protocol_Reply


/// The fake server of one test, with the arrival record and the reply rules.
final class FakeRpcServer: @unchecked Sendable {
    let server: FakeCentrifugoServer
    // The arrival record is its own log (ArrivalLog.swift). The rules below are guarded by `lock`.
    private let arrivals: ArrivalLog<RpcCommand> = ArrivalLog()
    private let lock: NSLock = NSLock()
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
        return arrivals.all
    }


    /// Suspends until `count` commands matching `matches` have arrived. Commands that arrived earlier
    /// count too.
    func awaitArrivals(_ description: String, count: Int = 1, _ matches: @escaping (RpcCommand) -> Bool) async {
        await arrivals.awaitArrivals(description, count: count, matches)
    }


    private func currentAnswer() -> ((RpcCommand) -> RpcReply?)? {
        lock.lock()
        defer {
            lock.unlock()
        }
        return self.answerRule
    }


    /// Tells whether a command gets no reply, then records it and wakes the waiters it matches. The drop
    /// decision comes first: a waiter resumes only after the rule has run, so a test may change the rule
    /// once `awaitArrivals` returns without racing the decision for the command that woke it.
    private func arrived(_ command: RpcCommand) -> Bool {
        lock.lock()
        let rule: ((RpcCommand) -> Bool)? = self.dropRule
        lock.unlock()
        let dropped: Bool = rule?(command) ?? false
        arrivals.record(command)
        return dropped
    }
}
