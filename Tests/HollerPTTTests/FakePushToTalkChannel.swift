import HollerCore
import HollerPTT

/// Scriptable PushToTalkChannelControlling: records calls, lets tests emit system events, can hold join() open.
actor FakePushToTalkChannel: PushToTalkChannelControlling {
    enum Call: Equatable, Sendable {
        case prepare, join(ChannelID, String), leave(ChannelID), begin(ChannelID), stop(ChannelID)
        case speaker(String?, ChannelID)
    }

    nonisolated let events: AsyncStream<PushToTalkEvent>
    private let continuation: AsyncStream<PushToTalkEvent>.Continuation
    private(set) var calls: [Call] = []
    private var holdJoins = false
    private var joinWaiters: [CheckedContinuation<Void, Never>] = []

    init() {
        (events, continuation) = AsyncStream.makeStream(of: PushToTalkEvent.self, bufferingPolicy: .unbounded)
    }

    func prepare() async throws { calls.append(.prepare) }
    func join(_ channel: Channel) async throws {
        calls.append(.join(channel.id, channel.name))
        guard holdJoins else { return }
        await withCheckedContinuation { joinWaiters.append($0) }
    }
    func leave(_ channel: ChannelID) async throws { calls.append(.leave(channel)) }
    func requestBeginTransmitting(_ channel: ChannelID) async throws { calls.append(.begin(channel)) }
    func stopTransmitting(_ channel: ChannelID) async throws { calls.append(.stop(channel)) }
    func setActiveSpeaker(_ name: String?, on channel: ChannelID) async throws { calls.append(.speaker(name, channel)) }

    /// Push an event as if the system delivered it.
    nonisolated func emit(_ event: PushToTalkEvent) { continuation.yield(event) }
    /// Later join() calls suspend until releaseJoins() (to script a stop() during an in-flight rejoin).
    func setHoldJoins(_ hold: Bool) { holdJoins = hold }
    func releaseJoins() {
        let pending = joinWaiters
        joinWaiters.removeAll()
        pending.forEach { $0.resume() }
    }
    var pendingJoins: Int { joinWaiters.count }
    func count(_ call: Call) -> Int { calls.filter { $0 == call }.count }
}
