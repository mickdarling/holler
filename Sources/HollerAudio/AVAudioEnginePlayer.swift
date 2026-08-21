import AVFoundation
public import HollerCore

/// Plays decoded frames through an AVAudioPlayerNode. One player per session; frames are scheduled in order.
public actor AVAudioEnginePlayer: AudioPlaying {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let codec: any AudioFrameCodec
    private let format: AudioFormatSpec
    private var isRunning = false

    public init(codec: any AudioFrameCodec, format: AudioFormatSpec = .voiceDefault) {
        self.codec = codec
        self.format = format
    }

    public func play(_ frame: AudioFrame, from participant: ParticipantID) async throws {
        let target = try targetFormat()
        if !isRunning { try startEngine(with: target) }
        let samples = try codec.decode(frame.payload)
        guard let buffer = PCMConversion.buffer(from: samples, format: target) else {
            throw AudioEngineError.bufferAllocationFailed
        }
        enqueue(buffer)
        if !player.isPlaying { player.play() }
    }

    /// Synchronous so frames are queued in call order before `play` returns. (The async `scheduleBuffer`
    /// variant resumes only after playout, which would serialize frames; a detached Task would not preserve order.)
    private func enqueue(_ buffer: AVAudioPCMBuffer) {
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    public func stopAll() async {
        player.stop()
        engine.stop()
        isRunning = false
    }

    private func targetFormat() throws -> AVAudioFormat {
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: format.sampleRate,
            channels: AVAudioChannelCount(format.channels), interleaved: true
        ) else { throw AudioEngineError.formatUnavailable }
        return target
    }

    private func startEngine(with target: AVAudioFormat) throws {
        if player.engine == nil { engine.attach(player) }
        engine.connect(player, to: engine.mainMixerNode, format: target)
        engine.prepare()
        try engine.start()
        isRunning = true
    }
}
