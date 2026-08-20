public import HollerCore

/// Records requested sleeps and returns immediately (or suspends until released) so supervisors are testable.
public actor FakeSleeper: Sleeper {
    public private(set) var requested: [Duration] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let holdUntilReleased: Bool

    public init(holdUntilReleased: Bool = false) {
        self.holdUntilReleased = holdUntilReleased
    }

    public func sleep(for duration: Duration) async throws {
        requested.append(duration)
        guard holdUntilReleased else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Wake every pending sleeper (fires the retry timers).
    public func releaseAll() {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    public var pendingCount: Int { waiters.count }
}
