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
    /// Bumped by every start()/stop(): a lifecycle call that was suspended across a newer one must not apply its
    /// post-await effects (an old stop must not leave a newer session's channel).
    private var lifecycle = 0
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
    /// A stop() that lands while this is suspended wins: no pumps are started and a completed join is undone.
    public func start(channelName: String) async throws {
        self.channelName = channelName
        lifecycle += 1
        let generation = lifecycle
        running = true
        do {
            try await service.prepare()
            guard generation == lifecycle else { return }
            try await service.join(Channel(id: channelID, name: channelName))
        } catch {
            if generation == lifecycle {  // a failed start is a stopped gate: finish any stop this start superseded
                running = false
                activeSpeaker = nil
                try? await service.leave(channelID)
            }
            throw error
        }
        guard generation == lifecycle else { if !running { try? await service.leave(channelID) }; return }
        if pumps.isEmpty {
            let events = service.events
            let states = inner.subscribeStates()
            let rosters = inner.subscribeRoster()
            pumps.add(Task { [weak self] in for await event in events { await self?.handle(event) } })
            pumps.add(Task { [weak self] in for await state in states { await self?.mirror(state) } })
            pumps.add(Task { [weak self] in for await roster in rosters { await self?.update(roster: roster) } })
        }
        await refreshActiveSpeaker()  // streams emit only future changes: a restart re-mirrors the current speaker
    }

    /// Stop forwarding, release the coordinator (the system end-transmitting callback will no longer be forwarded,
    /// so an in-progress transmission must not keep capture and the floor), and leave the system channel.
    /// A join in flight when stop() ran is undone (see start()/rejoin()). start() may be called again afterwards.
    public func stop() async {
        lifecycle += 1
        let generation = lifecycle
        running = false
        channelSession += 1
        await inner.release()
        guard generation == lifecycle else { return }  // a newer start() owns the channel now
        activeSpeaker = nil  // leaving the channel clears the system UI
        try? await service.leave(channelID)
    }

    public var currentRoster: [Participant] { roster }
    public func press() async { try? await service.requestBeginTransmitting(channelID) }
    public func release() async { try? await service.stopTransmitting(channelID) }
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
    private func rejoin() async {
        try? await service.join(Channel(id: channelID, name: channelName))
        if !running { try? await service.leave(channelID) }  // stop() ran while the join was suspended
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
