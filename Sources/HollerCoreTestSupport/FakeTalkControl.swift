public import HollerCore

/// Scriptable TalkControlling for view-model tests: records presses/releases and lets tests push states.
public final class FakeTalkControl: TalkControlling, Sendable {
    public let states = Broadcaster<TalkMachine.State>()
    public let notices = Broadcaster<TalkNotice>()
    public let roster = Broadcaster<[Participant]>()
    public let calls = Broadcaster<String>()

    public init() {}
    public func press() async { calls.send("press") }
    public func release() async { calls.send("release") }
    public func subscribeStates() -> AsyncStream<TalkMachine.State> { states.subscribe() }
    public func subscribeNotices() -> AsyncStream<TalkNotice> { notices.subscribe() }
    public func subscribeRoster() -> AsyncStream<[Participant]> { roster.subscribe() }
}
