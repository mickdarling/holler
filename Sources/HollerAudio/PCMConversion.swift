@preconcurrency import AVFoundation
import Synchronization

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
    static func convert(
        _ input: AVAudioPCMBuffer, with converter: AVAudioConverter, to target: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = target.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        let consumed = Mutex(false)
        let status = converter.convert(to: output, error: nil) { _, outStatus in
            let alreadyConsumed = consumed.withLock { value -> Bool in
                defer { value = true }
                return value
            }
            outStatus.pointee = alreadyConsumed ? .noDataNow : .haveData
            return alreadyConsumed ? nil : input
        }
        return status == .error ? nil : output
    }
}
