public import HollerCore
import Synchronization

/// Turns PCM sample chunks into sequenced, timestamped AudioFrames. Sendable so the audio tap can call it directly.
public final class FrameEmitter: Sendable {
    private let codec: any AudioFrameCodec
    private let continuation: AsyncStream<AudioFrame>.Continuation
    private let startedAt: ContinuousClock.Instant
    private let sequence = Mutex<UInt32>(0)

    public init(codec: any AudioFrameCodec, continuation: AsyncStream<AudioFrame>.Continuation, startedAt: ContinuousClock.Instant) {
        self.codec = codec
        self.continuation = continuation
        self.startedAt = startedAt
    }

    public func emit(_ samples: [Int16]) {
        guard let payload = try? codec.encode(samples) else { return }
        let next = sequence.withLock { value -> UInt32 in
            defer { value &+= 1 }
            return value
        }
        continuation.yield(AudioFrame(sequence: next, timestampMilliseconds: elapsedMilliseconds(), payload: payload))
    }

    public func finish() { continuation.finish() }

    private func elapsedMilliseconds() -> UInt64 {
        let elapsed = ContinuousClock.now - startedAt
        let seconds = UInt64(max(elapsed.components.seconds, 0))
        let millis = UInt64(max(elapsed.components.attoseconds, 0) / 1_000_000_000_000_000)
        return seconds * 1_000 + millis
    }
}
