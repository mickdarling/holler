public import Foundation
public import HollerCore

/// SignalingTransport over a WebSocket to the relay. One instance, many connect/disconnect cycles
/// (the ConnectionSupervisor drives those). `connect()` returns (and `.connected` is emitted) only after the
/// handshake completed; a failed handshake throws and emits nothing. Never reconnects on its own.
public actor WebSocketSignalingTransport: SignalingTransport {
    private let url: URL
    private let connecting: any WebSocketConnecting
    private let codec = WireCodec()
    private var channel: (any WebSocketChannel)?
    private var pendingSocket: (any WebSocketChannel)?
    private var connectGeneration: UInt64 = 0
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
        connectGeneration &+= 1
        let generation = connectGeneration
        let socket = connecting.open(url)
        pendingSocket = socket
        socket.resume()
        do {
            try await socket.waitUntilOpen()
        } catch {
            socket.cancel()
            if generation == connectGeneration { pendingSocket = nil }
            throw TransportError.connectionFailed("\(error)")
        }
        // A disconnect() (or a newer connect()) while the handshake was in flight wins: do not install this socket.
        guard generation == connectGeneration else {
            socket.cancel()
            throw TransportError.connectionFailed("cancelled during handshake")
        }
        pendingSocket = nil
        channel = socket
        eventContinuation.yield(.connected)
        receiveTask = Task { [weak self] in await self?.receiveLoop(socket) }
    }

    public func disconnect() async {
        connectGeneration &+= 1
        pendingSocket?.cancel()
        pendingSocket = nil
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
