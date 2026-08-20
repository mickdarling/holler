public import Foundation
public import HollerCore

/// JSON encoding of WireMessage for the socket. Pure; tested without a network.
public struct WireCodec: Sendable {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    public init() {}

    public func encode(_ message: WireMessage) throws(TransportError) -> String {
        do {
            let data = try encoder.encode(message)
            guard let text = String(data: data, encoding: .utf8) else {
                throw TransportError.encodingFailed("non-utf8 output")
            }
            return text
        } catch let error as TransportError {
            throw error
        } catch {
            throw TransportError.encodingFailed("\(error)")
        }
    }

    public func decode(_ text: String) throws(TransportError) -> WireMessage {
        do {
            return try decoder.decode(WireMessage.self, from: Data(text.utf8))
        } catch {
            throw TransportError.decodingFailed("\(error)")
        }
    }
}
