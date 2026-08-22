import Testing
import HollerCore
import HollerCoreTestSupport
@testable import HollerPTT

@Suite("PushToTalkGatedControl restarts, terminal leaves, and surviving memberships", .timeLimit(.minutes(1)))
struct PushToTalkGatedControlRestartTests {
    let channel = kitchen

    @Test("a leave refused during the restart window (before the replacement join returns) still reconciles")
    func leaveRefusedInRestartWindowReconciles() async throws {
        let harness = try await makeGate()
        let (gate, service, _) = (harness.gate, harness.service, harness.inner)
        await service.setAutoLeaveEvents(false)
        await service.setAutoJoinEvents(false)
        await service.setHoldJoins(true)
        let restarting = Task { try await gate.start(channelName: "Kitchen") }  // leave issued; join held
        try #require(await eventually { await service.pendingJoins == 1 })
        try await emitAndAwaitHandled(.leaveFailed(channel), on: service, gate: gate)  // in the window: not running yet
        #expect(await service.count(.leave(channel)) == 1)  // not retried to exhaustion: a replacement join is pending
        await service.setHoldJoins(false)
        await service.releaseJoins()
        try await restarting.value
        try await emitAndAwaitHandled(.joinFailed(channel), on: service, gate: gate)  // old membership blocked the join
        #expect(await gate.isJoinedToSystemChannel)  // reconciled to the surviving membership
        withExtendedLifetime(gate) {}
    }

    @Test("a retired join accepted while endSession() is still releasing the coordinator does not add a second leave")
    func staleJoinDuringEndSessionLeavesOnce() async throws {
        let service = FakePushToTalkChannel()
        let inner = RecordingTalkControl()
        let gate = PushToTalkGatedControl(inner: inner, service: service, channel: channel)
        await service.setAutoJoinEvents(false)
        try await gate.start(channelName: "Kitchen")  // join unanswered
        await inner.setHoldReleases(true)
        let stopping = Task { await gate.stop() }  // retires the join, then suspends in inner.release()
        try #require(await eventually { await inner.pendingReleases == 1 })
        try await emitAndAwaitHandled(.joined(channel), on: service, gate: gate)  // the retired join is accepted now
        #expect(await service.count(.leave(channel)) == 0)  // endSession will issue the leave itself
        await inner.releaseAll()
        await stopping.value
        #expect(await service.count(.leave(channel)) == 1)
        withExtendedLifetime(gate) {}
    }

    @Test("a terminal leave retires an unanswered rejoin; a late acceptance of it is left again")
    func terminalLeaveRetiresPendingRejoin() async throws {
        let harness = try await makeGate()
        let (gate, service, _) = (harness.gate, harness.service, harness.inner)
        await service.setAutoJoinEvents(false)
        try await emitAndAwaitHandled(.left(channel, reason: .unknown), on: service, gate: gate)  // rejoin, unanswered
        try await emitAndAwaitHandled(.left(channel, reason: .userRequest), on: service, gate: gate)  // user left
        try await emitAndAwaitHandled(.joined(channel), on: service, gate: gate)  // the rejoin is accepted late
        #expect(await gate.isJoinedToSystemChannel == false)  // not adopted…
        #expect(await eventually { await service.count(.leave(channel)) == 1 })  // …left again
        withExtendedLifetime(gate) {}
    }

    @Test("a restart whose startup throws after the old leave was refused still ends the surviving membership")
    func failedRestartLeavesSurvivingMembership() async throws {
        let harness = try await makeGate()
        let (gate, service, _) = (harness.gate, harness.service, harness.inner)
        await service.setAutoLeaveEvents(false)
        await service.setHoldJoins(true)
        await service.setJoinCommandFailures(1)  // the replacement join will throw once released
        let restarting = Task { try await gate.start(channelName: "Kitchen") }  // leave #1 issued; join held
        try #require(await eventually { await service.pendingJoins == 1 })
        try await emitAndAwaitHandled(.leaveFailed(channel), on: service, gate: gate)  // old membership survived
        await service.setHoldJoins(false)
        await service.releaseJoins()
        await #expect(throws: FakePushToTalkChannel.Rejected.self) { try await restarting.value }
        #expect(await gate.isJoinedToSystemChannel == false)
        #expect(await eventually { await service.count(.leave(channel)) == 2 })  // the surviving membership is left
        withExtendedLifetime(gate) {}
    }

    @Test("a drop during startup that the pending join itself repairs does not trigger a duplicate join")
    func dropThenJoinedDuringStartupNoDuplicate() async throws {
        let service = FakePushToTalkChannel()
        let inner = RecordingTalkControl()
        let gate = PushToTalkGatedControl(inner: inner, service: service, channel: channel)
        await service.setAutoJoinEvents(false)
        await service.setHoldJoins(true)
        let starting = Task { try await gate.start(channelName: "Kitchen") }
        try #require(await eventually { await service.pendingJoins == 1 })
        try await emitAndAwaitHandled(.left(channel, reason: .unknown), on: service, gate: gate)  // drop…
        try await emitAndAwaitHandled(.joined(channel), on: service, gate: gate)  // …then the pending join is accepted
        await service.setHoldJoins(false)
        await service.releaseJoins()
        try await starting.value
        #expect(await gate.isJoinedToSystemChannel)
        try await emitAndAwaitHandled(.joined(ChannelID("other")), on: service, gate: gate)  // drain
        #expect(await service.count(.join(channel, "Kitchen")) == 1)  // no duplicate join
        withExtendedLifetime(gate) {}
    }

    @Test("a terminal leave during a restart's startup is honored: the startup join is retired and not adopted")
    func terminalLeaveDuringStartup() async throws {
        let harness = try await makeGate()
        let (gate, service, _) = (harness.gate, harness.service, harness.inner)
        await service.setAutoJoinEvents(false)
        await service.setHoldJoins(true)
        let restarting = Task { try await gate.start(channelName: "Kitchen") }  // old leave confirmed; join held
        try #require(await eventually { await service.pendingJoins == 1 })
        try await emitAndAwaitHandled(.left(channel, reason: .userRequest), on: service, gate: gate)  // user left
        await service.setHoldJoins(false)
        await service.releaseJoins()
        try await restarting.value
        try await emitAndAwaitHandled(.joined(channel), on: service, gate: gate)  // the retired startup join accepted
        #expect(await gate.isJoinedToSystemChannel == false)
        #expect(await eventually { await service.count(.leave(channel)) == 2 })  // left again, not adopted
        withExtendedLifetime(gate) {}
    }
}
