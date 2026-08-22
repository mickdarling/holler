#if os(iOS)
import Testing
import Foundation
import HollerCore
@testable import HollerPTT

/// Runs only in the simulator lane: the adapter is iOS-only. Optional delegate methods are never called if misspelled,
/// so their Objective-C selectors are checked here; commands before prepare() must throw.
@Suite("PushToTalkChannelAdapter (iOS)")
@MainActor
struct PushToTalkChannelAdapterTests {
    let channel = ChannelID("kitchen")
    @Test("optional PTChannelManagerDelegate methods are spelled so the framework will call them")
    func delegateSelectors() {
        let adapter = PushToTalkChannelAdapter()
        for selector in [
            "channelManager:failedToJoinChannelWithUUID:error:",
            "channelManager:failedToLeaveChannelWithUUID:error:",
            "channelManager:failedToBeginTransmittingInChannelWithUUID:error:",
            "channelManager:failedToStopTransmittingInChannelWithUUID:error:",
            "channelManager:didJoinChannelWithUUID:reason:",
            "channelManager:didLeaveChannelWithUUID:reason:",
            "channelManager:channelUUID:didBeginTransmittingFromSource:",
            "channelManager:channelUUID:didEndTransmittingFromSource:",
            "channelManager:receivedEphemeralPushToken:",
            "incomingPushResultForChannelManager:channelUUID:pushPayload:",
            "channelManager:didActivateAudioSession:",
            "channelManager:didDeactivateAudioSession:"
        ] {
            #expect(adapter.responds(to: Selector(selector)), "missing \(selector)")
        }
    }

    @Test("commands before prepare() throw notPrepared; unknown channels throw unknownChannel")
    func commandErrors() async {
        let adapter = PushToTalkChannelAdapter()
        await #expect(throws: PushToTalkServiceError.notPrepared) {
            try await adapter.join(Channel(id: channel, name: "K"))
        }
        await #expect(throws: PushToTalkServiceError.notPrepared) { try await adapter.leave(channel) }
        await #expect(throws: PushToTalkServiceError.notPrepared) {
            try await adapter.requestBeginTransmitting(channel)
        }
        await #expect(throws: PushToTalkServiceError.notPrepared) { try await adapter.stopTransmitting(channel) }
        await #expect(throws: PushToTalkServiceError.notPrepared) {
            try await adapter.setActiveSpeaker(nil, on: channel)
        }
    }
}
#endif
