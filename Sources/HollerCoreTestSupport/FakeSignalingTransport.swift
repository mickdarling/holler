public import HollerCore

/// Scriptable transport: decide whether connect() succeeds, emit events on demand, record sends.
public actor FakeSignalingTransport: SignalingTransport {
    public enum Call: Equatable, Sendable { case connect, disconnect, send(WireMessage) }

    public private(set) var calls: [Call] = []
    public var connectResults: [Result<Void, TransportError>]
    public nonisolated let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation

    public init(connectResults: [Result<Void, TransportError>] = []) {
        self.connectResults = connectResults
        (events, continuation) = AsyncStream.makeStream(of: TransportEvent.self, bufferingPolicy: .unbounded)
    }

    public func connect() async throws {
        calls.append(.connect)
        guard !connectResults.isEmpty else { return }
        let result = connectResults.removeFirst()
        if case let .failure(error) = result { throw error }
    }

    public func disconnect() async { calls.append(.disconnect) }
    public func send(_ message: WireMessage) async throws { calls.append(.send(message)) }

    /// Push an event as if the socket produced it.
    public func emit(_ event: TransportEvent) { continuation.yield(event) }
    public var connectCount: Int { calls.filter { $0 == .connect }.count }
}
