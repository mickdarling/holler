/// Interprets TalkMachine effects against the transport and audio adapters, and turns inbound
/// WireMessages into TalkMachine events. One per channel session.
public actor TalkCoordinator: TalkControlling {
    private let participant: Participant
    private let channel: ChannelID
    private var me: ParticipantID { participant.id }
    private let transport: any SignalingTransport
    private let capture: any AudioCapturing
    private let playback: any AudioPlaying
    private let machine = TalkMachine()
    private var state: TalkMachine.State = .idle
    private var roster: [Participant] = []
    private var captureTask: Task<Void, Never>?
    private var pumpTasks: [Task<Void, Never>] = []
    private let stateBroadcaster = Broadcaster<TalkMachine.State>()
    private let noticeBroadcaster = Broadcaster<TalkNotice>()
    private let rosterBroadcaster = Broadcaster<[Participant]>()

    public init(
        participant: Participant,
        channel: ChannelID,
        transport: any SignalingTransport,
        capture: any AudioCapturing,
        playback: any AudioPlaying
    ) {
        self.participant = participant
        self.channel = channel
        self.transport = transport
        self.capture = capture
        self.playback = playback
    }

    public var currentState: TalkMachine.State { state }
    public var currentRoster: [Participant] { roster }
    public nonisolated func subscribeStates() -> AsyncStream<TalkMachine.State> { stateBroadcaster.subscribe() }
    public nonisolated func subscribeNotices() -> AsyncStream<TalkNotice> { noticeBroadcaster.subscribe() }
    public nonisolated func subscribeRoster() -> AsyncStream<[Participant]> { rosterBroadcaster.subscribe() }

    /// Wire the coordinator to a supervisor's message and health streams.
    public func attach(messages: AsyncStream<WireMessage>, health: AsyncStream<HealthState>) {
        pumpTasks.append(Task { [weak self] in for await message in messages { await self?.receive(message) } })
        pumpTasks.append(Task { [weak self] in for await status in health { await self?.observe(health: status) } })
    }

    public func detach() {
        pumpTasks.forEach { $0.cancel() }
        pumpTasks.removeAll()
    }

    public func press() async { await handle(.pressed) }
    public func release() async { await handle(.released) }

    public func receive(_ message: WireMessage) async {
        switch message {
        case let .floorGranted(to) where to == me: await handle(.granted)
        case let .floorGranted(to): await handle(.remoteStarted(to))
        case let .floorDenied(to, heldBy) where to == me: await handle(.denied(heldBy: heldBy))
        case let .floorReleased(by) where by != me: await handle(.remoteStopped(by))
        case let .audio(from, frame): await play(frame, from: from)
        case let .welcome(participants): updateRoster(participants)
        case let .participantJoined(participant): updateRoster(roster.filter { $0.id != participant.id } + [participant])
        case let .participantLeft(id): updateRoster(roster.filter { $0.id != id })
        case let .ping(nonce): try? await transport.send(.pong(nonce: nonce))
        default: break
        }
    }

    private func observe(health: HealthState) async {
        switch health {
        case .online: try? await transport.send(.hello(participant: participant, channel: channel))
        case .connecting: break
        case .offline, .retrying, .stopped: await handle(.disconnected)
        }
    }

    public func handle(_ event: TalkMachine.Event) async {
        let (next, effects) = machine.reduce(state, event)
        if next != state {
            state = next
            stateBroadcaster.send(next)
        }
        for effect in effects { await perform(effect) }
    }

    private func perform(_ effect: TalkMachine.Effect) async {
        switch effect {
        case .sendFloorRequest: try? await transport.send(.floorRequest(from: me))
        case .sendFloorRelease: try? await transport.send(.floorReleased(by: me))
        case .startCapture: await startCapture()
        case .stopCapture: await stopCapture()
        case .startPlayback: break
        case .stopPlayback: await playback.stopAll()
        case let .notifyDenied(holder): noticeBroadcaster.send(.denied(heldBy: holder))
        }
    }

    private func startCapture() async {
        guard let frames = try? await capture.start() else {
            await handle(.released)
            return
        }
        captureTask = Task { [weak self] in
            for await frame in frames {
                guard let self, !Task.isCancelled else { return }
                try? await self.transport.send(.audio(from: self.me, frame: frame))
            }
        }
    }

    private func stopCapture() async {
        captureTask?.cancel()
        captureTask = nil
        await capture.stop()
    }

    private func play(_ frame: AudioFrame, from speaker: ParticipantID) async {
        guard case let .receiving(current) = state, current == speaker else { return }
        try? await playback.play(frame, from: speaker)
    }

    private func updateRoster(_ participants: [Participant]) {
        roster = participants.sorted { $0.displayName < $1.displayName }
        rosterBroadcaster.send(roster)
    }
}
