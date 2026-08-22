import Testing
import HollerCore
import HollerCoreTestSupport
@testable import HollerPTT

@Suite("PushToTalkGatedControl leaving, releasing, and startup drops", .timeLimit(.minutes(1)))
struct PushToTalkGatedControlLeaveTests {
    let channel = kitchen

    @Test("a release whose stop command cannot be issued, or is refused, still frees the coordinator")
    func releaseFailuresFreeTheCoordinator() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        try await emitAndAwaitHandled(.beginTransmittingRequested(channel), on: service, gate: gate)
        await service.setStopFailures(1)
        await gate.release()  // throws inside the service
        #expect(await inner.recorded == ["press", "release"])
        try await emitAndAwaitHandled(.beginTransmittingRequested(channel), on: service, gate: gate)
        await gate.release()
        try await emitAndAwaitHandled(.stopTransmitFailed(channel), on: service, gate: gate)  // refused asynchronously
        #expect(await inner.recorded == ["press", "release", "press", "release"])
        withExtendedLifetime(gate) {}
    }

    @Test("stopAndAwaitLeave returns when the leave is confirmed (or refused to exhaustion), with a bound")
    func stopAndAwaitLeave() async throws {
        let harness = try await makeGate()
        let (gate, service, _) = (harness.gate, harness.service, harness.inner)
        await service.setAutoLeaveEvents(false)
        let stopping = Task { await gate.stopAndAwaitLeave(timeout: .seconds(30)) }
        try #require(await eventually { await service.count(.leave(channel)) == 1 })
        service.emit(.left(channel, reason: .developerRequest))  // confirmation
        await stopping.value  // returns promptly (not after 30 s)
        let bounded = Task { await gate.stopAndAwaitLeave(timeout: .milliseconds(50)) }  // no member: returns at once
        await bounded.value
        withExtendedLifetime(gate) {}
    }

    @Test("a refused leave followed by the restart's refused join reconciles to the surviving membership")
    func leaveRefusedThenJoinRefusedReconciles() async throws {
        let harness = try await makeGate()
        let (gate, service, _) = (harness.gate, harness.service, harness.inner)
        await service.setAutoLeaveEvents(false)
        await service.setAutoJoinEvents(false)
        await service.setHoldJoins(true)
        let restarting = Task { try await gate.start(channelName: "Kitchen") }  // leave (unanswered), join held
        try #require(await eventually { await service.pendingJoins == 1 })
        await service.setHoldJoins(false)
        await service.releaseJoins()
        try await restarting.value  // join issued, unanswered
        try await emitAndAwaitHandled(.leaveFailed(channel), on: service, gate: gate)  // old membership survives…
        #expect(await gate.isJoinedToSystemChannel == false)  // …decided when the join is answered
        try await emitAndAwaitHandled(.joinFailed(channel), on: service, gate: gate)
        #expect(await gate.isJoinedToSystemChannel)  // reconciled: the system still holds our membership
        withExtendedLifetime(gate) {}
    }

    @Test("a leave command that throws is retried like a refusal, and stopAndAwaitLeave waits for it")
    func throwingLeaveIsRetried() async throws {
        let harness = try await makeGate()
        let (gate, service, _) = (harness.gate, harness.service, harness.inner)
        await service.setLeaveFailures(2)  // the first two leave commands throw; the third is issued and confirmed
        await gate.stopAndAwaitLeave(timeout: .seconds(30))
        #expect(await service.count(.leave(channel)) == 3)
        withExtendedLifetime(gate) {}
    }

    @Test("a system drop that lands while start() is still suspended is rejoined once startup completes")
    func dropDuringStartupRejoins() async throws {
        let service = FakePushToTalkChannel()
        let inner = RecordingTalkControl()
        let gate = PushToTalkGatedControl(inner: inner, service: service, channel: channel)
        await service.setAutoJoinEvents(false)
        await service.setHoldJoins(true)
        let starting = Task { try await gate.start(channelName: "Kitchen") }
        try #require(await eventually { await service.pendingJoins == 1 })
        // answered while start() is suspended…
        try await emitAndAwaitHandled(.joined(channel), on: service, gate: gate)
        try await emitAndAwaitHandled(.left(channel, reason: .unknown), on: service, gate: gate)  // …and dropped again
        await service.setHoldJoins(false)
        await service.releaseJoins()
        try await starting.value
        #expect(await eventually { await service.count(.join(channel, "Kitchen")) == 2 })  // rejoined after startup
        try await emitAndAwaitHandled(.joined(channel), on: service, gate: gate)
        #expect(await gate.isJoinedToSystemChannel)
        withExtendedLifetime(gate) {}
    }

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

    @Test("a join that stop() retired but the system later accepts is left again; stopAndAwaitLeave waits for it")
    func staleAcceptedJoinIsLeft() async throws {
        let service = FakePushToTalkChannel()
        let inner = RecordingTalkControl()
        let gate = PushToTalkGatedControl(inner: inner, service: service, channel: channel)
        await service.setAutoJoinEvents(false)
        await service.setAutoLeaveEvents(false)
        try await gate.start(channelName: "Kitchen")  // join #1 unanswered
        // leave #1 issued (we might be a member)
        let stopping = Task { await gate.stopAndAwaitLeave(timeout: .seconds(30)) }
        try #require(await eventually { await service.count(.leave(channel)) == 1 })
        // leave #1 confirmed
        try await emitAndAwaitHandled(.left(channel, reason: .developerRequest), on: service, gate: gate)
        // join #1 accepted late → member again
        try await emitAndAwaitHandled(.joined(channel), on: service, gate: gate)
        try #require(await eventually { await service.count(.leave(channel)) == 2 })  // leave #2 issued
        #expect(await gate.isJoinedToSystemChannel == false)
        try await emitAndAwaitHandled(.left(channel, reason: .developerRequest), on: service, gate: gate)
        await stopping.value  // only now settled
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
}
