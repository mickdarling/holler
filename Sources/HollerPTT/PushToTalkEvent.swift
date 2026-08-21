public import Foundation
public import HollerCore

/// Why the system removed the app from a channel (mirrors PTChannelLeaveReason without importing PushToTalk).
public enum PushToTalkLeaveReason: Sendable, Equatable {
    case unknown
    case userRequest
    case developerRequest
    /// A managed-device restriction took effect; the system would refuse a rejoin.
    case systemPolicy

    /// The app rejoins automatically only when the system dropped it for no stated reason.
    public var shouldRejoin: Bool {
        switch self {
        case .userRequest, .developerRequest, .systemPolicy: false
        case .unknown: true
        }
    }
}

/// What the system PushToTalk service tells the app. Platform-neutral so Features/App code can consume it.
public enum PushToTalkEvent: Sendable, Equatable {
    case joined(ChannelID)
    case left(ChannelID, reason: PushToTalkLeaveReason)
    case beginTransmittingRequested(ChannelID)
    case endTransmittingRequested(ChannelID)
    case audioSessionActivated
    case audioSessionDeactivated
    case pushTokenUpdated(Data)
    case incomingSpeaker(ChannelID, speaker: ParticipantID, displayName: String)
}
