#if os(iOS)
public import Foundation
public import HollerCore
public import PushToTalk
public import AVFoundation
import Synchronization

/// Adapter over PTChannelManager. Delegate callbacks are forwarded as PushToTalkEvents; commands are async methods
/// (the manager's join/leave/transmit calls are synchronous and report outcomes through the delegate).
/// Verified constraints (apple-platform-facts 2026-08-20): iOS 16+ only; audio session must not mix with others;
/// keep service status .ready.
@MainActor
public final class PushToTalkChannelAdapter: NSObject, PTChannelManagerDelegate, PTChannelRestorationDelegate,
    PushToTalkChannelControlling {
    public nonisolated let events: AsyncStream<PushToTalkEvent>
    private nonisolated let continuation: AsyncStream<PushToTalkEvent>.Continuation
    private var manager: PTChannelManager?
    private var channelUUIDs: [ChannelID: UUID] = [:]
    private nonisolated let channelIDs = Mutex<[UUID: ChannelID]>([:])

    public override init() {
        (events, continuation) = AsyncStream.makeStream(of: PushToTalkEvent.self, bufferingPolicy: .unbounded)
        super.init()
    }

    public func prepare() async throws {
        manager = try await PTChannelManager.channelManager(delegate: self, restorationDelegate: self)
    }

    public func join(_ channel: Channel) async throws {
        let uuid = channelUUIDs[channel.id] ?? UUID()
        channelUUIDs[channel.id] = uuid
        channelIDs.withLock { $0[uuid] = channel.id }
        let descriptor = PTChannelDescriptor(name: channel.name, image: nil)
        manager?.requestJoinChannel(channelUUID: uuid, descriptor: descriptor)
    }

    public func leave(_ channel: ChannelID) async throws {
        guard let uuid = channelUUIDs[channel] else { return }
        manager?.leaveChannel(channelUUID: uuid)
    }

    public func requestBeginTransmitting(_ channel: ChannelID) async throws {
        guard let uuid = channelUUIDs[channel] else { return }
        manager?.requestBeginTransmitting(channelUUID: uuid)
    }

    public func stopTransmitting(_ channel: ChannelID) async throws {
        guard let uuid = channelUUIDs[channel] else { return }
        manager?.stopTransmitting(channelUUID: uuid)
    }

    public func setActiveSpeaker(_ name: String?, on channel: ChannelID) async throws {
        guard let uuid = channelUUIDs[channel] else { return }
        let participant = name.map { PTParticipant(name: $0, image: nil) }
        try await manager?.setActiveRemoteParticipant(participant, channelUUID: uuid)
    }

    // MARK: PTChannelManagerDelegate (nonisolated; forward to the stream)

    public nonisolated func channelManager(
        _ channelManager: PTChannelManager, didJoinChannel channelUUID: UUID,
        reason: PTChannelJoinReason
    ) {
        continuation.yield(.joined(channelID(for: channelUUID)))
    }

    public nonisolated func channelManager(
        _ channelManager: PTChannelManager, didLeaveChannel channelUUID: UUID,
        reason: PTChannelLeaveReason
    ) {
        continuation.yield(.left(channelID(for: channelUUID), reason: Self.leaveReason(reason)))
    }

    public nonisolated func channelManager(
        _ channelManager: PTChannelManager, channelUUID: UUID,
        didBeginTransmittingFrom source: PTChannelTransmitRequestSource
    ) {
        continuation.yield(.beginTransmittingRequested(channelID(for: channelUUID)))
    }

    public nonisolated func channelManager(
        _ channelManager: PTChannelManager, channelUUID: UUID,
        didEndTransmittingFrom source: PTChannelTransmitRequestSource
    ) {
        continuation.yield(.endTransmittingRequested(channelID(for: channelUUID)))
    }

    public nonisolated func channelManager(
        _ channelManager: PTChannelManager, receivedEphemeralPushToken pushToken: Data
    ) {
        continuation.yield(.pushTokenUpdated(pushToken))
    }

    public nonisolated func incomingPushResult(
        channelManager: PTChannelManager, channelUUID: UUID, pushPayload: [String: Any]
    ) -> PTPushResult {
        guard let speaker = pushPayload["speaker"] as? String else { return .leaveChannel }
        let name = pushPayload["speakerName"] as? String ?? speaker
        let event = PushToTalkEvent.incomingSpeaker(
            channelID(for: channelUUID), speaker: ParticipantID(speaker), displayName: name
        )
        continuation.yield(event)
        return .activeRemoteParticipant(PTParticipant(name: name, image: nil))
    }

    public nonisolated func channelManager(
        _ channelManager: PTChannelManager, didActivate audioSession: AVAudioSession
    ) {
        continuation.yield(.audioSessionActivated)
    }

    public nonisolated func channelManager(
        _ channelManager: PTChannelManager, didDeactivate audioSession: AVAudioSession
    ) {
        continuation.yield(.audioSessionDeactivated)
    }

    private nonisolated static func leaveReason(_ reason: PTChannelLeaveReason) -> PushToTalkLeaveReason {
        switch reason {
        case .unknown: .unknown
        case .userRequest: .userRequest
        case .developerRequest: .developerRequest
        case .systemPolicy: .systemPolicy
        @unknown default: .unknown
        }
    }

    private nonisolated func channelID(for uuid: UUID) -> ChannelID {
        channelIDs.withLock { $0[uuid] } ?? ChannelID(uuid.uuidString)
    }

    // MARK: PTChannelRestorationDelegate

    public nonisolated func channelDescriptor(restoredChannelUUID channelUUID: UUID) -> PTChannelDescriptor {
        PTChannelDescriptor(name: "Holler", image: nil)
    }
}
#endif
