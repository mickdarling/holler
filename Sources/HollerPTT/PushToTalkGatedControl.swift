public import HollerCore

/// TalkControlling decorator: presses go to the system PushToTalk service first; the coordinator only starts
/// capturing once the system confirms transmission (required for background audio activation on iOS).
/// Also mirrors the remote speaker into the system UI and rejoins the system channel when the service drops it.
///
/// Model: start()/stop()/rejoin() are serialized FIFO. Transmit callbacks are forwarded only while the system has
/// confirmed membership (`.joined` … `.left`/`.joinFailed`), so nothing buffered from an earlier membership can drive
/// the coordinator later; our own leave confirmations (`.left(.developerRequest)`) are accounted for so one arriving
/// after the next `.joined` does not end the new membership. Speaker mirroring runs on one worker (newest request
/// wins) and never overlaps a system transmission, which the framework rejects. When the coordinator drops the floor
/// on its own (denied, disconnected) while the system still transmits, the gate tells the system to stop.
public actor PushToTalkGatedControl: TalkControlling {
    let inner: any TalkControlling
    let service: any PushToTalkChannelControlling
    let channelID: ChannelID
    var channelName = ""
    var roster: [Participant] = []
    var receivingFrom: ParticipantID?
    var activeSpeaker: String?
    /// Bumped whenever `activeSpeaker` is written outside the refresh worker (join, leave, stop, pushed speaker), so the
    /// worker can tell that the system's view changed while its call was in flight (value equality is not enough).
    var speakerEpoch = 0
    var running = false
    var joined = false
    /// Joins we issued that the system has not answered yet. The system answers each requestJoinChannel once, in order,
    /// so only the answer that brings this to zero is the current membership's; earlier answers are stale and ignored.
    /// Not reset by endSession(): the answers are still coming.
    var joinsOutstanding = 0
    /// Joins issued by a session that has since ended: their answers are still coming and must be swallowed.
    var staleJoins = 0
    /// A system drop arrived while a rejoin was unanswered: rejoin again once that answer lands.
    var rejoinAfterAnswer = false
    /// Leaves we issued whose `.left(.developerRequest)` confirmation is still outstanding.
    var pendingLeaves = 0
    /// A join was refused while our own leave was still in flight: retry once the leave is confirmed.
    var rejoinAfterLeave = false
    var systemTransmitting = false
    /// The membership (channelSession) a system transmission belongs to: end/failed callbacks from an earlier one are stale.
    var transmitSession = 0
    var stopRequested = false
    var channelSession = 0
    private var lifecycleBusy = false
    private var lifecycleWaiters: [CheckedContinuation<Void, Never>] = []
    let refreshContinuation: AsyncStream<Void>.Continuation
    private let refreshRequests: AsyncStream<Void>
    /// Lifetime pumps: the adapter's event stream is single-consumer and created once; the caches must stay current
    /// while stopped so a restart mirrors the real speaker.
    private let pumps = TaskBag()
    // Test hooks (internal).
    var handledEventCount = 0
    var handledStateCount = 0
    var refreshCount = 0
    var pendingLifecycleWaiters: Int { lifecycleWaiters.count }
    var isJoinedToSystemChannel: Bool { joined }
    var isSystemTransmitting: Bool { systemTransmitting }

    public init(inner: any TalkControlling, service: any PushToTalkChannelControlling, channel: ChannelID) {
        self.inner = inner
        self.service = service
        self.channelID = channel
        (refreshRequests, refreshContinuation) = AsyncStream.makeStream(of: Void.self,
                                                                         bufferingPolicy: .bufferingNewest(1))
    }

    /// Join the system channel; callbacks are accepted once `.joined` confirms. Calling this on a running gate
    /// restarts the session (release, leave, join again). A failed start leaves the gate stopped.
    public func start(channelName: String) async throws {
        await acquireLifecycle()
        defer { releaseLifecycle() }
        self.channelName = channelName
        if pumps.isEmpty { startPumps() }  // before the first startup await: nothing from that window is replayed later
        if running { await endSession() }
        try await service.prepare()
        try await issueJoin()
        running = true
        refreshContinuation.yield()
    }

    /// Release the coordinator (an in-progress transmission must not keep capture and the floor) and leave the system
    /// channel. Serialized with start()/rejoin(); start() may be called again afterwards.
    public func stop() async {
        await acquireLifecycle()
        defer { releaseLifecycle() }
        await endSession()
    }

    func issueJoin() async throws {
        joinsOutstanding += 1
        do {
            try await service.join(Channel(id: channelID, name: channelName))
        } catch {
            joinsOutstanding -= 1
            throw error
        }
    }

    func endSession() async {
        let wasMember = joined || joinsOutstanding > 0
        running = false
        joined = false
        staleJoins += joinsOutstanding  // answers to this session's joins must not re-arm the stopped gate
        joinsOutstanding = 0
        rejoinAfterLeave = false
        rejoinAfterAnswer = false
        systemTransmitting = false
        stopRequested = false
        channelSession += 1
        activeSpeaker = nil  // invalidated before suspending; leaving clears the system UI
        speakerEpoch += 1
        await inner.release()
        guard wasMember else { return }
        pendingLeaves += 1  // before the call: its confirmation can be handled before the call returns
        if (try? await service.leave(channelID)) == nil { pendingLeaves -= 1 }  // could not be issued: none will come
    }

    private func startPumps() {
        let events = service.events, states = inner.subscribeStates(), rosters = inner.subscribeRoster()
        let notices = inner.subscribeNotices(), refreshes = refreshRequests
        pumps.add(Task { [weak self] in for await event in events { await self?.handle(event) } })
        pumps.add(Task { [weak self] in for await state in states { await self?.mirror(state) } })
        pumps.add(Task { [weak self] in for await roster in rosters { await self?.update(roster: roster) } })
        pumps.add(Task { [weak self] in for await notice in notices { await self?.handle(notice: notice) } })
        pumps.add(Task { [weak self] in for await _ in refreshes { await self?.refreshActiveSpeaker() } })
    }

    func acquireLifecycle() async {
        if !lifecycleBusy { lifecycleBusy = true; return }
        await withCheckedContinuation { lifecycleWaiters.append($0) }  // resumed only when ownership is handed over
    }

    /// Ownership passes directly to the first waiter (the flag never clears in between): strict FIFO.
    func releaseLifecycle() {
        if lifecycleWaiters.isEmpty { lifecycleBusy = false } else { lifecycleWaiters.removeFirst().resume() }
    }

    public var currentRoster: [Participant] { roster }
    /// Always through the system: the coordinator's state is only observed asynchronously here, so it cannot be used
    /// to pre-empt the request. If the coordinator then denies the floor, its notice makes the gate stop the system.
    public func press() async { if joined { try? await service.requestBeginTransmitting(channelID) } }
    public func release() async { if joined { try? await service.stopTransmitting(channelID) } }
    public nonisolated func subscribeStates() -> AsyncStream<TalkMachine.State> { inner.subscribeStates() }
    public nonisolated func subscribeNotices() -> AsyncStream<TalkNotice> { inner.subscribeNotices() }
    public nonisolated func subscribeRoster() -> AsyncStream<[Participant]> { inner.subscribeRoster() }
}
