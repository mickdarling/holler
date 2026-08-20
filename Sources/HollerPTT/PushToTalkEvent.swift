public import Foundation
public import HollerCore

/// What the system PushToTalk service tells the app. Platform-neutral so Features/App code can consume it.
public enum PushToTalkEvent: Sendable, Equatable {
    case joined(ChannelID)
    case left(ChannelID, reason: String)
    case beginTransmittingRequested(ChannelID)
    case endTransmittingRequested(ChannelID)
    case audioSessionActivated
    case audioSessionDeactivated
    case pushTokenUpdated(Data)
    case incomingSpeaker(ChannelID, speaker: ParticipantID, displayName: String)
}
