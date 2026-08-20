@preconcurrency public import AVFoundation
public import HollerCore

/// Microphone capture via AVAudioEngine: taps the input node, converts to the channel format, emits frames.
public actor AVAudioEngineCapture: AudioCapturing {
    private let engine = AVAudioEngine()
    private let codec: any AudioFrameCodec
    private let format: AudioFormatSpec
    private var emitter: FrameEmitter?

    public init(codec: any AudioFrameCodec, format: AudioFormatSpec = .voiceDefault) {
        self.codec = codec
        self.format = format
    }

    public func start() async throws -> AsyncStream<AudioFrame> {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: format.sampleRate,
            channels: AVAudioChannelCount(format.channels), interleaved: true
        ) else { throw AudioEngineError.formatUnavailable }
        guard let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw AudioEngineError.converterUnavailable
        }
        let (stream, continuation) = AsyncStream.makeStream(of: AudioFrame.self, bufferingPolicy: .bufferingNewest(64))
        let emitter = FrameEmitter(codec: codec, continuation: continuation, startedAt: .now)
        self.emitter = emitter
        input.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { buffer, _ in
            guard let converted = PCMConversion.convert(buffer, with: converter, to: target) else { return }
            emitter.emit(PCMConversion.samples(from: converted))
        }
        engine.prepare()
        try engine.start()
        return stream
    }

    public func stop() async {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        emitter?.finish()
        emitter = nil
    }
}
