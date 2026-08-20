/// Something the UI can tell the user about a talk attempt.
public enum TalkNotice: Sendable, Equatable {
    case denied(heldBy: ParticipantID)
}

/// What the UI needs from the talk layer. TalkCoordinator is the real one; tests use a fake.
public protocol TalkControlling: Sendable {
    func press() async
    func release() async
    func subscribeStates() -> AsyncStream<TalkMachine.State>
    func subscribeNotices() -> AsyncStream<TalkNotice>
    func subscribeRoster() -> AsyncStream<[Participant]>
}
