public import Foundation
public import HollerCore

/// SignalingTransport over a WebSocket to the relay. One instance, many connect/disconnect cycles
/// (the ConnectionSupervisor drives those). Emits TransportEvents; never reconnects on its own.
public actor WebSocketSignalingTransport: SignalingTransport {
    private let url: URL
    private let connecting: any WebSocketConnecting
    private let codec = WireCodec()
    private var channel: (any WebSocketChannel)?
    private var receiveTask: Task<Void, Never>?
    private let eventContinuation: AsyncStream<TransportEvent>.Continuation
    public nonisolated let events: AsyncStream<TransportEvent>

    public init(url: URL, connecting: any WebSocketConnecting = URLSessionWebSocketConnecting()) {
        self.url = url
        self.connecting = connecting
        (events, eventContinuation) = AsyncStream.makeStream(of: TransportEvent.self, bufferingPolicy: .unbounded)
    }

    public func connect() async throws {
        await disconnect()
        let socket = connecting.open(url)
        socket.resume()
        channel = socket
        eventContinuation.yield(.connected)
        receiveTask = Task { [weak self] in await self?.receiveLoop(socket) }
    }

    public func disconnect() async {
        receiveTask?.cancel()
        receiveTask = nil
        channel?.cancel()
        channel = nil
    }

    public func send(_ message: WireMessage) async throws {
        guard let channel else { throw TransportError.notConnected }
        let text = try codec.encode(message)
        do {
            try await channel.send(text: text)
        } catch {
            throw TransportError.connectionFailed("\(error)")
        }
    }

    private func receiveLoop(_ socket: any WebSocketChannel) async {
        while !Task.isCancelled {
            do {
                let text = try await socket.receiveText()
                if let message = try? codec.decode(text) {
                    eventContinuation.yield(.message(message))
                }
            } catch {
                guard !Task.isCancelled else { return }
                channel = nil
                eventContinuation.yield(.disconnected(reason: "\(error)"))
                return
            }
        }
    }
}
