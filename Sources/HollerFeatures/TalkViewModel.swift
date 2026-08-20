public import Foundation
public import HollerCore
public import Observation

/// UI state for one channel. Observes the talk layer and health; forwards press/release. Main-actor by design.
@MainActor
@Observable
public final class TalkViewModel {
    public private(set) var talkState: TalkMachine.State = .idle
    public private(set) var health: HealthState = .offline
    public private(set) var roster: [Participant] = []
    public private(set) var lastNotice: TalkNotice?
    public let channelName: String

    private let control: any TalkControlling
    private let bag = TaskBag()

    public init(channelName: String, control: any TalkControlling, health: AsyncStream<HealthState>) {
        self.channelName = channelName
        self.control = control
        // Subscribe synchronously so nothing sent right after init is missed.
        let states = control.subscribeStates()
        let notices = control.subscribeNotices()
        let roster = control.subscribeRoster()
        bag.add(Task { [weak self] in for await state in states { self?.talkState = state } })
        bag.add(Task { [weak self] in for await notice in notices { self?.lastNotice = notice } })
        bag.add(Task { [weak self] in for await members in roster { self?.roster = members } })
        bag.add(Task { [weak self] in for await status in health { self?.health = status } })
    }

    public var isTransmitting: Bool { talkState == .transmitting }
    public var speakerID: ParticipantID? {
        if case let .receiving(from) = talkState { return from }
        return nil
    }
    public var speakerName: String? {
        guard let speakerID else { return nil }
        return roster.first { $0.id == speakerID }?.displayName ?? speakerID.rawValue
    }
    public var canTalk: Bool { health == .online && talkState == .idle }

    public func pressed() { Task { await control.press() } }
    public func released() { Task { await control.release() } }
    public func clearNotice() { lastNotice = nil }
}
