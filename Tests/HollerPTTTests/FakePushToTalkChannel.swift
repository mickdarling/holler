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
    struct Rejected: Error {}
    private var holdJoins = false
    private var speakerFailures = 0
    private var prepareFailures = 0
    private var holdSpeakerCalls = false
    private var speakerWaiters: [CheckedContinuation<Void, Never>] = []
    private var joinWaiters: [CheckedContinuation<Void, Never>] = []

    init() {
        (events, continuation) = AsyncStream.makeStream(of: PushToTalkEvent.self, bufferingPolicy: .unbounded)
    }

    func prepare() async throws {
        calls.append(.prepare)
        if prepareFailures > 0 { prepareFailures -= 1; throw Rejected() }
    }
    func join(_ channel: Channel) async throws {
        calls.append(.join(channel.id, channel.name))
        guard holdJoins else { return }
        await withCheckedContinuation { joinWaiters.append($0) }
    }
    func leave(_ channel: ChannelID) async throws { calls.append(.leave(channel)) }
    func requestBeginTransmitting(_ channel: ChannelID) async throws { calls.append(.begin(channel)) }
    func stopTransmitting(_ channel: ChannelID) async throws { calls.append(.stop(channel)) }
    func setActiveSpeaker(_ name: String?, on channel: ChannelID) async throws {
        calls.append(.speaker(name, channel))
        if holdSpeakerCalls { await withCheckedContinuation { speakerWaiters.append($0) } }
        if speakerFailures > 0 { speakerFailures -= 1; throw Rejected() }
    }

    /// Push an event as if the system delivered it.
    nonisolated func emit(_ event: PushToTalkEvent) { continuation.yield(event) }
    /// Later join() calls suspend until releaseJoins() (to script a stop() during an in-flight rejoin).
    func setHoldJoins(_ hold: Bool) { holdJoins = hold }
    /// The next `count` prepare() calls are recorded and then rejected.
    func setPrepareFailures(_ count: Int) { prepareFailures = count }
    /// The next `count` setActiveSpeaker calls are recorded and then rejected.
    func setSpeakerFailures(_ count: Int) { speakerFailures = count }
    func releaseJoins() {
        let pending = joinWaiters
        joinWaiters.removeAll()
        pending.forEach { $0.resume() }
    }
    var pendingJoins: Int { joinWaiters.count }
    /// setActiveSpeaker calls suspend until releaseSpeakerCalls() (to script overlapping speaker updates).
    func setHoldSpeakerCalls(_ hold: Bool) { holdSpeakerCalls = hold }
    func releaseSpeakerCalls() {
        let pending = speakerWaiters
        speakerWaiters.removeAll()
        pending.forEach { $0.resume() }
    }
    var pendingSpeakerCalls: Int { speakerWaiters.count }
    func count(_ call: Call) -> Int { calls.filter { $0 == call }.count }
}
