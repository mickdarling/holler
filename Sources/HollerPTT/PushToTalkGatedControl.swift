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
    private var running = false
    private var pumps: [Task<Void, Never>] = []

    public init(inner: any TalkControlling, service: any PushToTalkChannelControlling, channel: ChannelID) {
        self.inner = inner
        self.service = service
        self.channelID = channel
    }

    /// Join the system channel and start forwarding system events, talk states, and the roster.
    /// A stop() that lands while this is suspended wins: no pumps are started and a completed join is undone.
    public func start(channelName: String) async throws {
        self.channelName = channelName
        running = true
        try await service.prepare()
        guard running else { return }
        try await service.join(Channel(id: channelID, name: channelName))
        guard running else { try? await service.leave(channelID); return }
        let events = service.events
        let states = inner.subscribeStates()
        let rosters = inner.subscribeRoster()
        pumps = [
            Task { [weak self] in for await event in events { await self?.handle(event) } },
            Task { [weak self] in for await state in states { await self?.mirror(state) } },
            Task { [weak self] in for await roster in rosters { await self?.update(roster: roster) } }
        ]
    }

    /// Stop forwarding and leave the system channel. A rejoin in flight when stop() ran is undone (see rejoin()).
    public func stop() async {
        running = false
        pumps.forEach { $0.cancel() }
        pumps.removeAll()
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
        case .beginTransmittingRequested: await inner.press()
        case .endTransmittingRequested: await inner.release()
        case let .left(id, reason) where id == channelID && reason.shouldRejoin: await rejoin()
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

    private func refreshActiveSpeaker() async {
        guard running else { return }
        let name = receivingFrom.map { speaker in roster.first { $0.id == speaker }?.displayName ?? speaker.rawValue }
        guard name != activeSpeaker else { return }
        activeSpeaker = name
        try? await service.setActiveSpeaker(name, on: channelID)
    }
}
