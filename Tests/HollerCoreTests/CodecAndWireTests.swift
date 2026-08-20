import Foundation
import Testing
@testable import HollerCore

@Suite("PassthroughPCMCodec")
struct PassthroughPCMCodecTests {
    let codec = PassthroughPCMCodec()

    @Test("round-trips samples", arguments: [[Int16]](arrayLiteral: [], [0], [1, -1, 32767, -32768], [12_345, -2]))
    func roundTrip(samples: [Int16]) throws {
        let encoded = try codec.encode(samples)
        #expect(encoded.count == samples.count * 2)
        #expect(try codec.decode(encoded) == samples)
    }

    @Test("encodes little-endian")
    func littleEndian() throws {
        #expect(try codec.encode([0x0102]) == Data([0x02, 0x01]))
    }

    @Test("rejects odd byte counts")
    func oddBytes() {
        #expect(throws: AudioCodecError.malformedPayload(byteCount: 3)) { try codec.decode(Data([1, 2, 3])) }
    }
}

@Suite("WireMessage JSON")
struct WireMessageTests {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    let alice = Participant(id: ParticipantID("alice"), displayName: "Alice")

    @Test("every case round-trips through JSON", arguments: [
        WireMessage.hello(participant: Participant(id: ParticipantID("a"), displayName: "A"),
                          channel: ChannelID("kitchen")),
        .welcome(participants: [Participant(id: ParticipantID("a"), displayName: "A")]),
        .participantJoined(participant: Participant(id: ParticipantID("b"), displayName: "B")),
        .participantLeft(id: ParticipantID("b")),
        .floorRequest(from: ParticipantID("a")), .floorGranted(to: ParticipantID("a")),
        .floorDenied(to: ParticipantID("a"), heldBy: ParticipantID("b")), .floorReleased(by: ParticipantID("a")),
        .audio(from: ParticipantID("a"),
               frame: AudioFrame(sequence: 7, timestampMilliseconds: 99, payload: Data([1, 2]))),
        .ping(nonce: 42), .pong(nonce: 42)
    ])
    func roundTrip(message: WireMessage) throws {
        let data = try encoder.encode(message)
        #expect(try decoder.decode(WireMessage.self, from: data) == message)
    }

    @Test("hello encodes with the documented shape the relay expects")
    func helloShape() throws {
        let data = try encoder.encode(WireMessage.hello(participant: alice, channel: ChannelID("kitchen")))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hello = try #require(object["hello"] as? [String: Any])
        #expect(hello["channel"] as? String == "kitchen")
        #expect((hello["participant"] as? [String: Any])?["displayName"] as? String == "Alice")
    }

    @Test("labeled keys are stable for the relay")
    func labeledKeys() throws {
        let data = try encoder.encode(WireMessage.floorDenied(to: alice.id, heldBy: ParticipantID("bob")))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let denied = try #require(object["floorDenied"] as? [String: Any])
        #expect(denied["to"] as? String == "alice")
        #expect(denied["heldBy"] as? String == "bob")
    }
}
