public import Foundation

/// Supported on-the-wire audio encodings. `pcm16` is the verified fallback; `opus` is preferred once verified on device.
public enum AudioCodecKind: String, Sendable, Codable, CaseIterable {
    case pcm16
    case opus
}

/// Describes the stream format negotiated for a channel.
public struct AudioFormatSpec: Sendable, Equatable, Codable {
    public let sampleRate: Double
    public let channels: Int
    public let codec: AudioCodecKind
    public init(sampleRate: Double, channels: Int, codec: AudioCodecKind) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.codec = codec
    }
    /// 16 kHz mono PCM: small, intelligible, and decodable everywhere.
    public static let voiceDefault = AudioFormatSpec(sampleRate: 16_000, channels: 1, codec: .pcm16)
}

/// One encoded chunk of audio. `sequence` lets receivers detect loss and reorder.
public struct AudioFrame: Sendable, Equatable, Codable {
    public let sequence: UInt32
    public let timestampMilliseconds: UInt64
    public let payload: Data
    public init(sequence: UInt32, timestampMilliseconds: UInt64, payload: Data) {
        self.sequence = sequence
        self.timestampMilliseconds = timestampMilliseconds
        self.payload = payload
    }
}

/// Captures microphone audio as encoded frames. Implemented by an adapter (AVAudioEngine).
public protocol AudioCapturing: Sendable {
    func start() async throws -> AsyncStream<AudioFrame>
    func stop() async
}

/// Plays received frames, attributed to the speaker. Implemented by an adapter.
public protocol AudioPlaying: Sendable {
    func play(_ frame: AudioFrame, from participant: ParticipantID) async throws
    func stopAll() async
}

/// Encodes/decodes PCM samples for the wire. Kept behind a protocol so Opus can replace PCM without touching callers.
public protocol AudioFrameCodec: Sendable {
    var kind: AudioCodecKind { get }
    func encode(_ samples: [Int16]) throws -> Data
    func decode(_ payload: Data) throws -> [Int16]
}

public enum AudioCodecError: Error, Equatable, Sendable {
    case malformedPayload(byteCount: Int)
}
