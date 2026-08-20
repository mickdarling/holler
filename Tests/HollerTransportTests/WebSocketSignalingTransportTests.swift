import Foundation
import Testing
import HollerCore
@testable import HollerTransport

/// Scripted socket: hands out inbound texts, records outbound, fails on demand.
actor ScriptedSocket: WebSocketChannel {
    private var inbound: [String]
    private(set) var outbound: [String] = []
    private(set) var resumed = false
    private(set) var cancelled = false
    private let failAfterDrain: Bool

    init(inbound: [String] = [], failAfterDrain: Bool = true) {
        self.inbound = inbound
        self.failAfterDrain = failAfterDrain
    }

    nonisolated func resume() { Task { await self.markResumed() } }
    nonisolated func cancel() { Task { await self.markCancelled() } }
    private func markResumed() { resumed = true }
    private func markCancelled() { cancelled = true }

    func send(text: String) async throws { outbound.append(text) }

    func receiveText() async throws -> String {
        if !inbound.isEmpty { return inbound.removeFirst() }
        if failAfterDrain { throw URLError(.networkConnectionLost) }
        try await Task.sleep(for: .seconds(60))
        throw URLError(.timedOut)
    }
}

struct ScriptedConnecting: WebSocketConnecting {
    let socket: ScriptedSocket
    func open(_ url: URL) -> any WebSocketChannel { socket }
}

@Suite("WebSocketSignalingTransport")
struct WebSocketSignalingTransportTests {
    let url = URL(string: "wss://example.invalid/v0/channels/kitchen/ws")!

    @Test("connect emits connected, decodes inbound frames, then reports the drop")
    func lifecycle() async throws {
        let socket = ScriptedSocket(inbound: [#"{"ping":{"nonce":1}}"#, "garbage"])
        let transport = WebSocketSignalingTransport(url: url, connecting: ScriptedConnecting(socket: socket))
        var events = transport.events.makeAsyncIterator()
        try await transport.connect()
        #expect(await events.next() == .connected)
        #expect(await events.next() == .message(.ping(nonce: 1)))
        guard case .disconnected = await events.next() else { Issue.record("expected disconnected"); return }
    }

    @Test("send encodes through the codec; send before connect fails")
    func send() async throws {
        let socket = ScriptedSocket(failAfterDrain: false)
        let transport = WebSocketSignalingTransport(url: url, connecting: ScriptedConnecting(socket: socket))
        await #expect(throws: TransportError.notConnected) { try await transport.send(.ping(nonce: 2)) }
        try await transport.connect()
        try await transport.send(.ping(nonce: 2))
        #expect(await socket.outbound == [#"{"ping":{"nonce":2}}"#])
        await transport.disconnect()
    }
}
