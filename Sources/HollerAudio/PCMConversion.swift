@preconcurrency public import AVFoundation

/// Small, pure helpers between AVAudioPCMBuffer and [Int16]. Kept separate so they are easy to test and reason about.
enum PCMConversion {
    /// Int16 mono samples from an interleaved Int16 buffer (channel 0 only).
    static func samples(from buffer: AVAudioPCMBuffer) -> [Int16] {
        guard let channelData = buffer.int16ChannelData else { return [] }
        let count = Int(buffer.frameLength)
        return Array(UnsafeBufferPointer(start: channelData[0], count: count))
    }

    /// A mono Int16 buffer in `format` containing `samples`.
    static func buffer(from samples: [Int16], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channelData = buffer.int16ChannelData else { return nil }
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channelData[0].update(from: base, count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }

    /// Resample/convert one input buffer into `target` format.
    static func convert(_ input: AVAudioPCMBuffer, with converter: AVAudioConverter, to target: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = target.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var consumed = false
        let status = converter.convert(to: output, error: nil) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return input
        }
        return status == .error ? nil : output
    }
}
