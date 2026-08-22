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

/// Thrown by a PushToTalkChannelControlling when a command cannot even be issued.
public enum PushToTalkServiceError: Error, Equatable {
    case notPrepared   // prepare() has not succeeded
    case unknownChannel  // the channel was never joined through this service
}

/// What the system PushToTalk service tells the app. Platform-neutral so Features/App code can consume it.
public enum PushToTalkEvent: Sendable, Equatable {
    case joined(ChannelID)
    /// The system refused the join (not in the foreground, channel limit, call active, …); we are not a member.
    case joinFailed(ChannelID)
    case left(ChannelID, reason: PushToTalkLeaveReason)
    /// Our leave was refused; membership is unchanged.
    case leaveFailed(ChannelID)
    case beginTransmittingRequested(ChannelID)
    case endTransmittingRequested(ChannelID)
    /// requestBeginTransmitting was refused; the system is not transmitting for us.
    case beginTransmitFailed(ChannelID)
    /// stopTransmitting was refused (typically: there was no transmission to stop).
    case stopTransmitFailed(ChannelID)
    case audioSessionActivated
    case audioSessionDeactivated
    case pushTokenUpdated(Data)
    case incomingSpeaker(ChannelID, speaker: ParticipantID, displayName: String)
}
