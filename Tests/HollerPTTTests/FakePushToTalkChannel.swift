import HollerCore
import HollerPTT
import Synchronization

/// Scriptable PushToTalkChannelControlling: records calls, emits system events, and can hold join()/setActiveSpeaker()
/// open or reject them. Like the real adapter, join() is answered by `.joined` and leave() by `.left(.developerRequest)`
/// (unless disabled), and every command can be made to throw.
actor FakePushToTalkChannel: PushToTalkChannelControlling {
    enum Call: Equatable, Sendable {
        case prepare, join(ChannelID, String), leave(ChannelID), begin(ChannelID), stop(ChannelID)
        case speaker(String?, ChannelID)
    }
    struct Rejected: Error {}

    nonisolated let events: AsyncStream<PushToTalkEvent>
    /// Every event this fake has put on the stream (system answers included), so a test can wait for the gate to
    /// catch up with all of them rather than with "one more" (a system answer still queued would be miscounted).
    nonisolated let emitted = Atomic<Int>(0)
    nonisolated var emittedCount: Int { emitted.load(ordering: .sequentiallyConsistent) }
    private let continuation: AsyncStream<PushToTalkEvent>.Continuation
    private(set) var calls: [Call] = []
    private var autoJoinEvents = true
    private var autoLeaveEvents = true
    private var leaveFailures = 0, beginFailures = 0, stopFailures = 0, joinCommandFailures = 0
    private var holdJoins = false
    private var holdBegins = false
    private var beginWaiters: [CheckedContinuation<Void, Never>] = []
    private var joinWaiters: [CheckedContinuation<Void, Never>] = []
    private var prepareFailures = 0
    private var holdPrepares = false
    private var holdLeaves = false
    private var leaveWaiters: [CheckedContinuation<Void, Never>] = []
    private var prepareWaiters: [CheckedContinuation<Void, Never>] = []
    private var joinFailures = 0  // join() returns normally; the system then reports `.joinFailed`
    private var speakerFailures = 0
    private var holdSpeakerCalls = false
    private var speakerWaiters: [CheckedContinuation<Void, Never>] = []

    init() {
        (events, continuation) = AsyncStream.makeStream(of: PushToTalkEvent.self, bufferingPolicy: .unbounded)
    }

    func prepare() async throws {
        calls.append(.prepare)
        if holdPrepares { await withCheckedContinuation { prepareWaiters.append($0) } }
        if prepareFailures > 0 { prepareFailures -= 1; throw Rejected() }
    }
    func join(_ channel: Channel) async throws {
        calls.append(.join(channel.id, channel.name))
        if holdJoins { await withCheckedContinuation { joinWaiters.append($0) } }
        if joinCommandFailures > 0 { joinCommandFailures -= 1; throw Rejected() }  // the command cannot be issued
        if joinFailures > 0 { joinFailures -= 1; emit(.joinFailed(channel.id)); return }
        if autoJoinEvents { emit(.joined(channel.id)) }
    }
    func leave(_ channel: ChannelID) async throws {
        calls.append(.leave(channel))
        if holdLeaves { await withCheckedContinuation { leaveWaiters.append($0) } }
        if leaveFailures > 0 { leaveFailures -= 1; throw Rejected() }
        if autoLeaveEvents { emit(.left(channel, reason: .developerRequest)) }
    }
    func requestBeginTransmitting(_ channel: ChannelID) async throws {
        calls.append(.begin(channel))
        if holdBegins { await withCheckedContinuation { beginWaiters.append($0) } }
        if beginFailures > 0 { beginFailures -= 1; throw Rejected() }
    }
    func stopTransmitting(_ channel: ChannelID) async throws {
        calls.append(.stop(channel))
        if stopFailures > 0 { stopFailures -= 1; throw Rejected() }
    }
    func setActiveSpeaker(_ name: String?, on channel: ChannelID) async throws {
        calls.append(.speaker(name, channel))
        if holdSpeakerCalls { await withCheckedContinuation { speakerWaiters.append($0) } }
        if speakerFailures > 0 { speakerFailures -= 1; throw Rejected() }
    }

    /// Push an event as if the system delivered it.
    nonisolated func emit(_ event: PushToTalkEvent) {
        emitted.add(1, ordering: .sequentiallyConsistent)
        continuation.yield(event)
    }
    func setAutoJoinEvents(_ on: Bool) { autoJoinEvents = on }
    func setAutoLeaveEvents(_ on: Bool) { autoLeaveEvents = on }
    func setLeaveFailures(_ count: Int) { leaveFailures = count }
    func setBeginFailures(_ count: Int) { beginFailures = count }
    func setStopFailures(_ count: Int) { stopFailures = count }
    /// Later join() calls suspend until releaseJoins() (to script lifecycle calls overlapping in the gate).
    func setHoldJoins(_ hold: Bool) { holdJoins = hold }
    /// Later requestBeginTransmitting() calls suspend until releaseBegins() (a release can overtake the command).
    func setHoldBegins(_ hold: Bool) { holdBegins = hold }
    func releaseBegins() { let pending = beginWaiters; beginWaiters.removeAll(); pending.forEach { $0.resume() } }
    var pendingBegins: Int { beginWaiters.count }
    func releaseJoins() { let pending = joinWaiters; joinWaiters.removeAll(); pending.forEach { $0.resume() } }
    var pendingJoins: Int { joinWaiters.count }
    func setPrepareFailures(_ count: Int) { prepareFailures = count }
    func setHoldPrepares(_ hold: Bool) { holdPrepares = hold }
    func setHoldLeaves(_ hold: Bool) { holdLeaves = hold }
    func releaseLeaves() { let pending = leaveWaiters; leaveWaiters.removeAll(); pending.forEach { $0.resume() } }
    var pendingLeaveCalls: Int { leaveWaiters.count }
    func releasePrepares() { let pending = prepareWaiters; prepareWaiters.removeAll(); pending.forEach { $0.resume() } }
    var pendingPrepares: Int { prepareWaiters.count }
    func setJoinFailures(_ count: Int) { joinFailures = count }
    func setJoinCommandFailures(_ count: Int) { joinCommandFailures = count }
    func setSpeakerFailures(_ count: Int) { speakerFailures = count }
    func setHoldSpeakerCalls(_ hold: Bool) { holdSpeakerCalls = hold }
    func releaseSpeakerCalls() {
        let pending = speakerWaiters; speakerWaiters.removeAll(); pending.forEach { $0.resume() }
    }
    var pendingSpeakerCalls: Int { speakerWaiters.count }
    func count(_ call: Call) -> Int { calls.filter { $0 == call }.count }
    var speakerCalls: [Call] { calls.filter { if case .speaker = $0 { true } else { false } } }
}
