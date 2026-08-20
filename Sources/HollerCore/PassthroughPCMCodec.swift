public import Foundation

/// Little-endian 16-bit PCM "codec": no compression, always works. The baseline every platform can decode.
public struct PassthroughPCMCodec: AudioFrameCodec {
    public let kind: AudioCodecKind = .pcm16
    public init() {}

    public func encode(_ samples: [Int16]) throws -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let value = UInt16(bitPattern: sample).littleEndian
            data.append(UInt8(truncatingIfNeeded: value))
            data.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        return data
    }

    public func decode(_ payload: Data) throws -> [Int16] {
        guard payload.count.isMultiple(of: 2) else {
            throw AudioCodecError.malformedPayload(byteCount: payload.count)
        }
        var samples: [Int16] = []
        samples.reserveCapacity(payload.count / 2)
        var iterator = payload.makeIterator()
        while let low = iterator.next(), let high = iterator.next() {
            let bits = UInt16(low) | (UInt16(high) << 8)
            samples.append(Int16(bitPattern: bits))
        }
        return samples
    }
}
