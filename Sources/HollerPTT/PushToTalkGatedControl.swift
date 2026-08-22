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
    /// A speaker the system was told about through a push while the coordinator is still idle (no relay yet): shown
    /// until the coordinator reports a real state, then the coordinator is authoritative.
    var pushedSpeaker: String?
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
    /// A system drop arrived while start() was still suspended in its join: rejoin once startup completes.
    var rejoinAfterStart = false
    /// The user/system ended a membership this session held: no rejoin until the next start(), and a retired join
    /// accepted afterwards is left again (bounded retries, never adopted).
    var terminalLeave = false
    var starting = false
    /// endSession() is between retiring the session and issuing its leave (it awaits the coordinator first).
    var endingSession = false
    /// Leaves we issued whose confirmation or refusal is outstanding, in issue order (the system answers in that order).
    var pendingLeaveQueue: [PendingLeave] = []
    var pendingLeaves: Int { pendingLeaveQueue.count }
    /// How many times the current leave (session end, or a terminal cleanup leave) has been asked of the system: a refused
    /// leave is retried, bounded.
    var leaveAttempts = 0
    static let maxLeaveAttempts = 3
    var nextLeaveID = 0
    /// A join was refused while our own leave was still in flight: retry once the leave is confirmed.
    var rejoinAfterLeave = false
    /// Our leave was refused while a restart's join was still unanswered: if that join is refused too, we are still a
    /// member of the old channel and the gate reconciles to joined.
    var membershipSurvived = false
    var leaveWaiters: [CheckedContinuation<Void, Never>] = []
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
    /// restarts the session (release, leave, join again). A failed start leaves the gate stopped. If the user or the
    /// system ends a membership this session holds, that is final: the gate stays running but not joined and does not
    /// rejoin; the next start() joins again.
    public func start(channelName: String) async throws {
        await acquireLifecycle()
        defer { releaseLifecycle() }
        self.channelName = channelName
        if pumps.isEmpty { startPumps() }  // before the first startup await: nothing from that window is replayed later
        if running { await endSession() }
        starting = true
        defer { starting = false }
        do {
            try await service.prepare()
            terminalLeave = false  // a terminal leave during prepare() ended a membership this start() replaces
            // Already a member (the old membership survived a refused leave, or a retired join was accepted late, while
            // prepare() was suspended): that membership is the session's; a second join for the same channel is not
            // issued, so `joined` never coexists with an outstanding join.
            if !joined { try await issueJoin() }
        } catch {
            // The gate stays stopped (`starting` cleared first: a refused cleanup leave is retried, never reconciled to
            // joined); a membership that survived a refused leave is ended now. No rejoin latch can be armed here.
            starting = false
            terminalLeave = false
            if joined || membershipSurvived {
                joined = false
                membershipSurvived = false
                leaveAttempts = 0
                await issueLeave()
            }
            throw error
        }
        running = true
        if rejoinAfterStart {  // dropped during startup and not re-established since: join again
            rejoinAfterStart = false
            if !joined && joinsOutstanding == 0 && !terminalLeave { try? await issueJoin() }
        }
        refreshContinuation.yield()
    }

    /// Release the coordinator (an in-progress transmission must not keep capture and the floor) and leave the system
    /// channel. Serialized with start()/rejoin(); start() may be called again afterwards.
    public func stop() async {
        await acquireLifecycle()
        defer { releaseLifecycle() }
        await endSession()
    }

    func endSession() async {
        endingSession = true
        defer { endingSession = false }
        running = false
        // Whether a membership is live is carried in actor state across the coordinator release below: a `.left`
        // handled meanwhile clears it, a retired join accepted meanwhile sets it. Decided only after the await.
        membershipSurvived = joined || membershipSurvived
        joined = false
        staleJoins += joinsOutstanding  // answers to this session's joins must not re-arm the stopped gate
        joinsOutstanding = 0
        rejoinAfterLeave = false
        rejoinAfterAnswer = false
        rejoinAfterStart = false
        terminalLeave = false
        systemTransmitting = false
        stopRequested = false
        channelSession += 1
        activeSpeaker = nil  // invalidated before suspending; leaving clears the system UI
        pushedSpeaker = nil
        speakerEpoch += 1
        await inner.release()
        let live = membershipSurvived
        membershipSurvived = false
        guard live || staleJoins > 0 else { return }  // a retired join still unanswered may yet create a membership
        leaveAttempts = 0
        endingSession = false  // the leave is being issued now: a retired join answered from here on is on its own
        await issueLeave(liveMembership: live)
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
}
