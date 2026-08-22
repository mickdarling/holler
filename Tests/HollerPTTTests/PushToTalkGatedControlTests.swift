import Testing
import Foundation
import HollerCore
import HollerCoreTestSupport
@testable import HollerPTT

@Suite("PushToTalkGatedControl", .timeLimit(.minutes(1)))
struct PushToTalkGatedControlTests {
    let channel = kitchen

    @Test("start prepares and joins; press/release go to the system service, not the coordinator")
    func startAndPresses() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        await gate.press()
        await gate.release()
        #expect(await service.calls == [.prepare, .join(channel, "Kitchen"), .begin(channel), .stop(channel)])
        #expect(await inner.recorded.isEmpty)  // the coordinator only hears about it once the system confirms
        try await emitAndAwaitHandled(.beginTransmittingRequested(channel), on: service, gate: gate)
        #expect(await inner.recorded == ["press"])
        withExtendedLifetime(gate) {}
    }

    @Test("system transmit callbacks drive the coordinator, in order")
    func systemCallbacksReachInner() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        try await emitAndAwaitHandled(.beginTransmittingRequested(channel), on: service, gate: gate)
        try await emitAndAwaitHandled(.endTransmittingRequested(channel), on: service, gate: gate)
        #expect(await inner.recorded == ["press", "release"])
        withExtendedLifetime(gate) {}
    }

    @Test("rejoins after a system drop (.unknown) only; every such drop rejoins again")
    func rejoinPolicy() async throws {
        let harness = try await makeGate()
        let (gate, service, _) = (harness.gate, harness.service, harness.inner)
        for reason in [PushToTalkLeaveReason.userRequest, .developerRequest, .systemPolicy] {
            try await emitAndAwaitHandled(.left(channel, reason: reason), on: service, gate: gate)
        }
        try await emitAndAwaitHandled(.left(ChannelID("other"), reason: .unknown), on: service, gate: gate)
        #expect(await service.count(.join(channel, "Kitchen")) == 1)  // none of those rejoin
        try await emitAndAwaitHandled(.left(channel, reason: .unknown), on: service, gate: gate)
        try #require(await eventually { await gate.isJoinedToSystemChannel })  // rejoined (fake confirms with .joined)
        try await emitAndAwaitHandled(.left(channel, reason: .unknown), on: service, gate: gate)
        #expect(await eventually { await service.count(.join(channel, "Kitchen")) == 3 })  // a second drop rejoins too
        withExtendedLifetime(gate) {}
    }

    @Test("callbacks for other channels are ignored (transmit, joined, left)")
    func otherChannelCallbacksIgnored() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        let other = ChannelID("other")
        try await emitAndAwaitHandled(.beginTransmittingRequested(other), on: service, gate: gate)
        try await emitAndAwaitHandled(.endTransmittingRequested(other), on: service, gate: gate)
        try await emitAndAwaitHandled(.left(other, reason: .unknown), on: service, gate: gate)
        try await emitAndAwaitHandled(.joined(other), on: service, gate: gate)
        #expect(await inner.recorded.isEmpty)
        #expect(await service.count(.join(channel, "Kitchen")) == 1)
        #expect(await gate.isJoinedToSystemChannel)
        withExtendedLifetime(gate) {}
    }

    @Test("until the system confirms the join, callbacks are not forwarded and button commands are not sent")
    func nothingBeforeJoinedConfirmation() async throws {
        let service = FakePushToTalkChannel()
        let inner = RecordingTalkControl()
        let gate = PushToTalkGatedControl(inner: inner, service: service, channel: channel)
        await service.setAutoJoinEvents(false)
        try await gate.start(channelName: "Kitchen")
        try await emitAndAwaitHandled(.beginTransmittingRequested(channel), on: service, gate: gate)
        await gate.press()
        #expect(await inner.recorded.isEmpty)
        #expect(await service.count(.begin(channel)) == 0)
        try await emitAndAwaitHandled(.joined(channel), on: service, gate: gate)  // now the system confirms
        try await emitAndAwaitHandled(.beginTransmittingRequested(channel), on: service, gate: gate)
        #expect(await inner.recorded == ["press"])
        withExtendedLifetime(gate) {}
    }

    @Test("a join the system refuses leaves the gate unjoined: button commands are not sent")
    func joinFailedIsNotJoined() async throws {
        let service = FakePushToTalkChannel()
        let inner = RecordingTalkControl()
        let gate = PushToTalkGatedControl(inner: inner, service: service, channel: channel)
        await service.setJoinFailures(1)
        try await gate.start(channelName: "Kitchen")
        // drain past the joinFailed
        try await emitAndAwaitHandled(.joined(ChannelID("other")), on: service, gate: gate)
        #expect(await gate.isJoinedToSystemChannel == false)
        await gate.press()
        #expect(await service.count(.begin(channel)) == 0)
        withExtendedLifetime(gate) {}
    }

    @Test("when the coordinator drops the floor on its own, the system transmission is stopped")
    func coordinatorDropsFloorStopsSystemTransmission() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        // system transmits
        try await emitAndAwaitHandled(.beginTransmittingRequested(channel), on: service, gate: gate)
        try await sendStateAndAwait(.requesting, on: inner, gate: gate)
        // relay denied: coordinator idle, system still transmits
        try await sendStateAndAwait(.idle, on: inner, gate: gate)
        #expect(await service.count(.stop(channel)) == 1)
        try await sendStateAndAwait(.receiving(from: becca.id), on: inner, gate: gate)  // asked once; not again
        #expect(await service.count(.stop(channel)) == 1)
        try await emitAndAwaitHandled(.endTransmittingRequested(channel), on: service, gate: gate)
        try await sendStateAndAwait(.idle, on: inner, gate: gate)  // no system transmission any more: nothing to stop
        #expect(await service.count(.stop(channel)) == 1)
        withExtendedLifetime(gate) {}
    }

    @Test("a refused begin or stop request releases the coordinator (it must not wait for a callback that won't come)")
    func transmitFailuresReleaseTheCoordinator() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        await gate.press()
        try await emitAndAwaitHandled(.beginTransmitFailed(channel), on: service, gate: gate)
        #expect(await inner.recorded == ["release"])
        try await emitAndAwaitHandled(.stopTransmitFailed(channel), on: service, gate: gate)
        #expect(await inner.recorded == ["release", "release"])
        withExtendedLifetime(gate) {}
    }

    @Test("a press always goes through the system; if the coordinator then denies the floor, the system is stopped")
    func pressDeniedByCoordinatorStopsSystem() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        try await sendStateAndAwait(.receiving(from: becca.id), on: inner, gate: gate)
        inner.sendState(.idle)  // the gate's cache may lag the coordinator: it must not branch on it
        await gate.press()
        #expect(await service.count(.begin(channel)) == 1)
        #expect(await inner.recorded.isEmpty)
        // system transmits
        try await emitAndAwaitHandled(.beginTransmittingRequested(channel), on: service, gate: gate)
        #expect(await inner.recorded == ["press"])
        inner.base.notices.send(.denied(heldBy: becca.id))  // the coordinator was receiving after all
        #expect(await eventually { await service.count(.stop(channel)) == 1 })
        withExtendedLifetime(gate) {}
    }

    @Test("events the gate does not use (audio session, push token) leave its state untouched")
    func unusedEventsIgnored() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        try await emitAndAwaitHandled(.audioSessionActivated, on: service, gate: gate)
        try await emitAndAwaitHandled(.pushTokenUpdated(Data([1, 2])), on: service, gate: gate)
        try await emitAndAwaitHandled(.audioSessionDeactivated, on: service, gate: gate)
        #expect(await gate.isJoinedToSystemChannel)
        #expect(await inner.recorded.isEmpty)
        withExtendedLifetime(gate) {}
    }
}
