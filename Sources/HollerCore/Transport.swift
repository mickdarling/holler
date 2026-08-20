/// What a signaling/media connection reports back to the domain.
public enum TransportEvent: Sendable, Equatable {
    case connected
    case disconnected(reason: String)
    case message(WireMessage)
}

/// A single connection to the relay. One instance = one socket lifetime; the supervisor reconnects by calling
/// `connect()` again. Implemented by an adapter (URLSessionWebSocketTask).
public protocol SignalingTransport: Sendable {
    var events: AsyncStream<TransportEvent> { get }
    func connect() async throws
    func disconnect() async
    func send(_ message: WireMessage) async throws
}

public enum TransportError: Error, Equatable, Sendable {
    case notConnected
    case encodingFailed(String)
    case decodingFailed(String)
    case connectionFailed(String)
}
