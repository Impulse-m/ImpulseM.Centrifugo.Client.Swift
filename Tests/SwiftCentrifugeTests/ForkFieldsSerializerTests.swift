import Foundation
import SwiftProtobuf
import Testing
@testable import SwiftCentrifuge

/// Round-trip tests for the protocol fields added by the fork (`ConnectRequest.dict`
/// and `profile`, `ConnectResult.flag` and `dict`, the `Dictionary` message), and
/// for an upstream-shaped frame that carries none of them. The fork fields are
/// generated but no SDK sends `dict` or `profile` on connect yet, so these tests
/// pin the wire shape of the generated API.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ForkFieldsSerializerTests {

    private typealias PCommand = Centrifugal_Centrifuge_Protocol_Command
    private typealias PReply = Centrifugal_Centrifuge_Protocol_Reply
    private typealias PConnectRequest = Centrifugal_Centrifuge_Protocol_ConnectRequest
    private typealias PConnectResult = Centrifugal_Centrifuge_Protocol_ConnectResult
    private typealias PDictionary = Centrifugal_Centrifuge_Protocol_Dictionary


    @Test func forkFieldsRoundTrip() throws {
        var request: PConnectRequest = PConnectRequest()
        request.dict = "dict-id"
        request.profile = "profile-a"
        var command: PCommand = PCommand()
        command.id = 1
        command.connect = request

        let decodedCommand: PCommand = try PCommand(serializedBytes: command.serializedData())

        #expect(decodedCommand.connect.dict == "dict-id")
        #expect(decodedCommand.connect.profile == "profile-a")

        var dictionary: PDictionary = PDictionary()
        dictionary.id = "dict-id"
        dictionary.data = Data([0x01, 0x02, 0x03])
        var result: PConnectResult = PConnectResult()
        result.flag = 1
        result.dict = dictionary
        var reply: PReply = PReply()
        reply.id = 1
        reply.connect = result

        let decodedReply: PReply = try PReply(serializedBytes: reply.serializedData())

        #expect(decodedReply.connect.flag == 1)
        #expect(decodedReply.connect.hasDict)
        #expect(decodedReply.connect.dict.id == "dict-id")
        #expect(decodedReply.connect.dict.data == Data([0x01, 0x02, 0x03]))

        var storedDictionary: PDictionary = PDictionary()
        storedDictionary.id = "dict-id"
        storedDictionary.dataB64 = "AQID"
        let decodedDictionary: PDictionary = try PDictionary(serializedBytes: storedDictionary.serializedData())

        #expect(decodedDictionary.id == "dict-id")
        #expect(decodedDictionary.dataB64 == "AQID")
        #expect(decodedDictionary.data.isEmpty)
    }


    @Test func connectRequestFlagRoundTrip() throws {
        // Field 7 is upstream: tag (7 << 3) | varint = 0x38, followed by the value.
        var small: PConnectRequest = PConnectRequest()
        small.flag = 1
        #expect(try small.serializedData() == Data([0x38, 0x01]))

        // Bit 32 (the tracked-call capability) needs the full 64-bit value.
        var wide: PConnectRequest = PConnectRequest()
        wide.flag = Int64(1) << 32
        let decoded: PConnectRequest = try PConnectRequest(serializedBytes: wide.serializedData())

        #expect(decoded.flag == Int64(1) << 32)
    }


    @Test func upstreamShapedFrameIsAccepted() throws {
        // A length-delimited reply encoded with the upstream 0.11.0 schema (protoc 34.0,
        // `--encode=centrifugal.centrifuge.protocol.Reply`) from
        // Reply { id: 1, connect { client: "client-id", version: "6.8.2", ping: 25, pong: true } }.
        // It carries no fork fields, as a server without them sends it. Being a literal,
        // it pins the upstream field numbers; a round trip through the generated codec
        // would not.
        let frame: Data = Data([
            0x1a,
            0x08, 0x01,
            0x2a, 0x16,
            0x0a, 0x09, 0x63, 0x6c, 0x69, 0x65, 0x6e, 0x74, 0x2d, 0x69, 0x64,
            0x12, 0x05, 0x36, 0x2e, 0x38, 0x2e, 0x32,
            0x38, 0x19,
            0x40, 0x01,
        ])

        let replies: [PReply] = try CentrifugeSerializer.deserializeCommands(data: frame)

        #expect(replies.count == 1)
        #expect(replies[0].id == 1)
        #expect(replies[0].connect.client == "client-id")
        #expect(replies[0].connect.version == "6.8.2")
        #expect(replies[0].connect.ping == 25)
        #expect(replies[0].connect.pong)
        #expect(replies[0].connect.flag == 0)
        #expect(!replies[0].connect.hasDict)
        #expect(replies[0].connect.user.isEmpty)
        #expect(replies[0].connect.authClass.isEmpty)
    }
}
