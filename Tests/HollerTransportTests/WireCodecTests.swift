import Foundation
import Testing
import HollerCore
@testable import HollerTransport

@Suite("WireCodec")
struct WireCodecTests {
    let codec = WireCodec()

    @Test("encodes to the documented JSON and decodes back")
    func roundTrip() throws {
        let message = WireMessage.floorGranted(to: ParticipantID("p1"))
        let text = try codec.encode(message)
        #expect(text == #"{"floorGranted":{"to":"p1"}}"#)
        #expect(try codec.decode(text) == message)
    }

    @Test("rejects malformed input with a decoding error")
    func malformed() {
        #expect(throws: TransportError.self) { try codec.decode("{nope") }
    }
}
