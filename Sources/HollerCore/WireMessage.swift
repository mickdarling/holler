/// The relay protocol. Encoded as JSON via Codable; the relay (relay/) mirrors this shape exactly.
/// Every associated value is labeled so the JSON keys are stable and readable (docs/wire-protocol.md).
public enum WireMessage: Sendable, Equatable, Codable {
    /// Client -> relay on connect.
    case hello(participant: Participant, channel: ChannelID)
    /// Relay -> client after hello; current roster (excluding the recipient).
    case welcome(participants: [Participant])
    case participantJoined(participant: Participant)
    case participantLeft(id: ParticipantID)
    /// Floor control: exactly one speaker at a time per channel.
    case floorRequest(from: ParticipantID)
    case floorGranted(to: ParticipantID)
    case floorDenied(to: ParticipantID, heldBy: ParticipantID)
    case floorReleased(by: ParticipantID)
    /// Audio from the current floor holder.
    case audio(from: ParticipantID, frame: AudioFrame)
    /// Liveness. Either side may ping; the other answers with the same nonce.
    case ping(nonce: UInt64)
    case pong(nonce: UInt64)
}
