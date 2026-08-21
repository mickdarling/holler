public import Foundation

/// The slice of URLSession the transport needs, so tests can substitute a fake socket.
public protocol WebSocketConnecting: Sendable {
    func open(_ url: URL) -> any WebSocketChannel
}

/// One live socket.
public protocol WebSocketChannel: Sendable {
    func resume()
    /// Resolves once the WebSocket handshake has completed and the peer answers a protocol-level ping;
    /// throws if the connection cannot be established.
    func waitUntilOpen() async throws
    func send(text: String) async throws
    func receiveText() async throws -> String
    func cancel()
}

/// Real implementation over URLSessionWebSocketTask.
public struct URLSessionWebSocketConnecting: WebSocketConnecting {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    public func open(_ url: URL) -> any WebSocketChannel {
        URLSessionWebSocketChannel(task: session.webSocketTask(with: url))
    }
}

struct URLSessionWebSocketChannel: WebSocketChannel {
    let task: URLSessionWebSocketTask

    func resume() { task.resume() }

    func waitUntilOpen() async throws {
        // URLSessionWebSocketTask exposes no open signal without a session delegate; a ping completes only after
        // the handshake succeeded and the server answered, which is exactly the "connected" we want to report.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            task.sendPing { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    func send(text: String) async throws {
        try await task.send(.string(text))
    }

    func receiveText() async throws -> String {
        switch try await task.receive() {
        case let .string(text): return text
        case let .data(data):
            guard let text = String(data: data, encoding: .utf8) else { throw URLError(.cannotDecodeRawData) }
            return text
        @unknown default: throw URLError(.badServerResponse)
        }
    }

    func cancel() { task.cancel(with: .normalClosure, reason: nil) }
}
