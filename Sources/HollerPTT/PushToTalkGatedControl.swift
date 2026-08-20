#if os(iOS)
public import HollerCore

/// TalkControlling decorator for iOS: presses go to the system PushToTalk service first; the coordinator only
/// starts capturing once the system confirms transmission (required for background audio activation).
public actor PushToTalkGatedControl: TalkControlling {
    private let inner: any TalkControlling
    private let adapter: PushToTalkChannelAdapter
    private let channel: ChannelID
    private var pumpTask: Task<Void, Never>?

    public init(inner: any TalkControlling, adapter: PushToTalkChannelAdapter, channel: ChannelID) {
        self.inner = inner
        self.adapter = adapter
        self.channel = channel
    }

    /// Join the system channel and start forwarding system events to the coordinator.
    public func start(channelName: String) async throws {
        try await adapter.prepare()
        try await adapter.join(Channel(id: channel, name: channelName))
        let events = adapter.events
        pumpTask = Task { [weak self] in
            for await event in events { await self?.handle(event) }
        }
    }

    public func press() async { try? await adapter.requestBeginTransmitting(channel) }
    public func release() async { try? await adapter.stopTransmitting(channel) }
    public nonisolated func subscribeStates() -> AsyncStream<TalkMachine.State> { inner.subscribeStates() }
    public nonisolated func subscribeNotices() -> AsyncStream<TalkNotice> { inner.subscribeNotices() }
    public nonisolated func subscribeRoster() -> AsyncStream<[Participant]> { inner.subscribeRoster() }

    private func handle(_ event: PushToTalkEvent) async {
        switch event {
        case .beginTransmittingRequested: await inner.press()
        case .endTransmittingRequested: await inner.release()
        default: break
        }
    }
}
#endif
