public import HollerCore
import Foundation

/// Capture fake: yields scripted frames once started, records stop.
public actor FakeAudioCapturing: AudioCapturing {
    public private(set) var startCount = 0
    public private(set) var stopCount = 0
    private let frames: [AudioFrame]

    public init(frames: [AudioFrame] = []) { self.frames = frames }

    public func start() async throws -> AsyncStream<AudioFrame> {
        startCount += 1
        let scripted = frames
        return AsyncStream { continuation in
            scripted.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }

    public func stop() async { stopCount += 1 }
}

/// Playback fake: records every frame and who it came from.
public actor FakeAudioPlaying: AudioPlaying {
    public private(set) var played: [(ParticipantID, AudioFrame)] = []
    public private(set) var stopAllCount = 0
    public init() {}
    public func play(_ frame: AudioFrame, from participant: ParticipantID) async throws {
        played.append((participant, frame))
    }
    public func stopAll() async { stopAllCount += 1 }
}
