import HollerCore
import HollerCoreTestSupport

/// TalkControlling whose release() can be held open, to script lifecycle calls overlapping in the gate.
actor HoldingTalkControl: TalkControlling {
    let base = FakeTalkControl()
    private var holdReleases = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func setHoldReleases(_ hold: Bool) { holdReleases = hold }
    func releaseAll() {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
    var pendingReleases: Int { waiters.count }

    func press() async { await base.press() }
    func release() async {
        if holdReleases { await withCheckedContinuation { waiters.append($0) } }
        await base.release()
    }
    nonisolated func subscribeStates() -> AsyncStream<TalkMachine.State> { base.subscribeStates() }
    nonisolated func subscribeNotices() -> AsyncStream<TalkNotice> { base.subscribeNotices() }
    nonisolated func subscribeRoster() -> AsyncStream<[Participant]> { base.subscribeRoster() }
}
