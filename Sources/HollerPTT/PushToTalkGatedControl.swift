public import HollerCore

/// TalkControlling decorator: presses go to the system PushToTalk service first; the coordinator only starts
/// capturing once the system confirms transmission (required for background audio activation on iOS).
/// Also mirrors the remote speaker into the system UI and rejoins the system channel when the service drops it.
public actor PushToTalkGatedControl: TalkControlling {
    private let inner: any TalkControlling
    private let service: any PushToTalkChannelControlling
    private let channelID: ChannelID
    private var channelName = ""
    private var roster: [Participant] = []
    private var receivingFrom: ParticipantID?
    private var activeSpeaker: String?
    private var speakerUpdateInFlight = false
    private var speakerRefreshPending = false
    private var running = false
    /// start()/stop() run strictly one after another (FIFO): a start issued during a stop waits for the stop to finish,
    /// so a new session can never overtake the release/leave of the old one.
    private var lifecycleBusy = false
    private var lifecycleWaiters: [CheckedContinuation<Void, Never>] = []
    /// Bumped whenever the system channel membership ends (leave, stop): a speaker result from before is discarded.
    private var channelSession = 0
    /// All pumps live for the gate's lifetime: the adapter's event stream is single-consumer and created once (cancelling
    /// it would leave a restarted gate deaf), and the state/roster caches must stay current while stopped so a restart
    /// mirrors the real speaker. `running` gates the side effects, not the bookkeeping.
    private let pumps = TaskBag()

    public init(inner: any TalkControlling, service: any PushToTalkChannelControlling, channel: ChannelID) {
        self.inner = inner
        self.service = service
        self.channelID = channel
    }

    /// Join the system channel and start forwarding system events, talk states, and the roster.
    /// Runs after any stop() in progress; a failed start leaves the gate stopped.
    public func start(channelName: String) async throws {
        await acquireLifecycle()
        do {
            try await startLocked(channelName: channelName)
        } catch {
            releaseLifecycle()
            throw error
        }
        releaseLifecycle()
        await refreshActiveSpeaker()  // streams emit only future changes: a restart re-mirrors the current speaker
    }

    /// Startup proper (under the lifecycle lock): subscribe, prepare, join, then accept callbacks.
    private func startLocked(channelName: String) async throws {
        self.channelName = channelName
        if pumps.isEmpty {  // subscribe before the first startup await so nothing from that window is replayed later
            let events = service.events
            let states = inner.subscribeStates()
            let rosters = inner.subscribeRoster()
            pumps.add(Task { [weak self] in for await event in events { await self?.handle(event) } })
            pumps.add(Task { [weak self] in for await state in states { await self?.mirror(state) } })
            pumps.add(Task { [weak self] in for await roster in rosters { await self?.update(roster: roster) } })
        }
        do {
            try await service.prepare()
            try await service.join(Channel(id: channelID, name: channelName))
        } catch {
            activeSpeaker = nil
            throw error  // still stopped: callbacks that arrived during the failed startup were dropped, not queued
        }
        running = true  // only a successful startup accepts system callbacks and button commands
    }

    /// Stop forwarding, release the coordinator (the system end-transmitting callback will no longer be forwarded,
    /// so an in-progress transmission must not keep capture and the floor), and leave the system channel.
    /// Serialized with start() and rejoin(). start() may be called again afterwards; it waits for this.
    public func stop() async {
        await acquireLifecycle()
        defer { releaseLifecycle() }
        running = false
        channelSession += 1
        activeSpeaker = nil  // invalidated before suspending: leaving clears the system UI
        await inner.release()
        try? await service.leave(channelID)
    }

    private func acquireLifecycle() async {
        if !lifecycleBusy { lifecycleBusy = true; return }
        await withCheckedContinuation { lifecycleWaiters.append($0) }  // resumed only when ownership is handed over
    }

    /// Ownership passes directly to the first waiter (the flag never clears in between), so a later caller cannot
    /// slip in ahead of an earlier one.
    private func releaseLifecycle() {
        if lifecycleWaiters.isEmpty { lifecycleBusy = false } else { lifecycleWaiters.removeFirst().resume() }
    }

    public var currentRoster: [Participant] { roster }
    public func press() async { if running { try? await service.requestBeginTransmitting(channelID) } }
    public func release() async { if running { try? await service.stopTransmitting(channelID) } }
    public nonisolated func subscribeStates() -> AsyncStream<TalkMachine.State> { inner.subscribeStates() }
    public nonisolated func subscribeNotices() -> AsyncStream<TalkNotice> { inner.subscribeNotices() }
    public nonisolated func subscribeRoster() -> AsyncStream<[Participant]> { inner.subscribeRoster() }

    private func handle(_ event: PushToTalkEvent) async {
        guard running else { return }
        switch event {
        case let .beginTransmittingRequested(id) where id == channelID: await inner.press()
        case let .endTransmittingRequested(id) where id == channelID: await inner.release()
        case let .joined(id) where id == channelID: await refreshActiveSpeaker()  // a fresh channel shows nobody
        case let .left(id, reason) where id == channelID:
            channelSession += 1
            activeSpeaker = nil  // leaving cleared the system UI; an in-flight speaker result is now stale
            if reason.shouldRejoin { await rejoin() }
        default: break
        }
    }

    /// One rejoin per system leave event (no loop of our own: the service either keeps us or drops us again).
    /// Runs under the lifecycle lock so it cannot straddle a stop()/start(): a stop that was already waiting goes
    /// after the rejoin and leaves; a stop that came first makes the rejoin a no-op.
    private func rejoin() async {
        await acquireLifecycle()
        defer { releaseLifecycle() }
        guard running else { return }
        try? await service.join(Channel(id: channelID, name: channelName))
    }

    /// Remote speaker → system active participant; cleared when we leave `.receiving`.
    private func mirror(_ state: TalkMachine.State) async {
        if case let .receiving(speaker) = state { receivingFrom = speaker } else { receivingFrom = nil }
        await refreshActiveSpeaker()
    }

    /// The roster and state streams arrive on separate pumps: a roster that resolves the current speaker's name
    /// after `.receiving` was mirrored must re-mirror, or the system UI keeps showing the raw id.
    private func update(roster: [Participant]) async {
        self.roster = roster
        await refreshActiveSpeaker()
    }

    /// One system call in flight at a time, applied in order: a refresh requested during the await is coalesced and
    /// re-evaluated afterwards, so an older continuation can never overwrite a newer name (actor reentrancy).
    private func refreshActiveSpeaker() async {
        guard running else { return }
        if speakerUpdateInFlight { speakerRefreshPending = true; return }
        speakerUpdateInFlight = true
        defer { speakerUpdateInFlight = false }
        repeat {
            speakerRefreshPending = false
            let name = receivingFrom.map { speaker in roster.first { $0.id == speaker }?.displayName ?? speaker.rawValue }
            guard name != activeSpeaker else { continue }
            // Cache only after the service accepted the update, so a transient rejection is retried on the next emission.
            let session = channelSession
            let accepted = (try? await service.setActiveSpeaker(name, on: channelID)) != nil
            guard running, session == channelSession else { continue }  // stale result; drain any queued refresh
            if accepted { activeSpeaker = name }
        } while speakerRefreshPending && running
    }
}
