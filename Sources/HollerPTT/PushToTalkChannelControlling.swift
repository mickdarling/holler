public import HollerCore

/// What the gate needs from the system push-to-talk service. `PushToTalkChannelAdapter` (iOS) is the real one;
/// tests use a fake, so the gate and its tests compile on every platform (ADR-0005).
public protocol PushToTalkChannelControlling: Sendable {
    /// System callbacks, in the order the service delivered them.
    var events: AsyncStream<PushToTalkEvent> { get }
    func prepare() async throws
    func join(_ channel: Channel) async throws
    func leave(_ channel: ChannelID) async throws
    func requestBeginTransmitting(_ channel: ChannelID) async throws
    func stopTransmitting(_ channel: ChannelID) async throws
    func setActiveSpeaker(_ name: String?, on channel: ChannelID) async throws
}
