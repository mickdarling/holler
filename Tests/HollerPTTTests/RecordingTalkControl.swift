import HollerCore
import HollerCoreTestSupport

/// TalkControlling that records press/release in order (for negative assertions) and can hold release() open
/// (to script lifecycle calls overlapping in the gate). Streams come from an embedded FakeTalkControl.
actor RecordingTalkControl: TalkControlling {
    let base = FakeTalkControl()
    private(set) var recorded: [String] = []
    private var holdReleases = false, holdPresses = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var pressWaiters: [CheckedContinuation<Void, Never>] = []

    func setHoldReleases(_ hold: Bool) { holdReleases = hold }
    func setHoldPresses(_ hold: Bool) { holdPresses = hold }
    func releasePresses() {
        let pending = pressWaiters
        pressWaiters.removeAll()
        pending.forEach { $0.resume() }
    }
    var pendingPresses: Int { pressWaiters.count }
    func releaseAll() {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
    var pendingReleases: Int { waiters.count }

    func press() async {
        if holdPresses { await withCheckedContinuation { pressWaiters.append($0) } }
        recorded.append("press")
        await base.press()
    }
    func release() async {
        if holdReleases { await withCheckedContinuation { waiters.append($0) } }
        recorded.append("release")
        await base.release()
    }
    nonisolated func subscribeStates() -> AsyncStream<TalkMachine.State> { base.subscribeStates() }
    nonisolated func subscribeNotices() -> AsyncStream<TalkNotice> { base.subscribeNotices() }
    nonisolated func subscribeRoster() -> AsyncStream<[Participant]> { base.subscribeRoster() }
    /// Push a talk state / roster as the coordinator would.
    nonisolated func sendState(_ state: TalkMachine.State) { base.states.send(state) }
    nonisolated func sendRoster(_ roster: [Participant]) { base.roster.send(roster) }
}
