import Testing
import HollerCore
import HollerCoreTestSupport
@testable import HollerPTT

@Suite("PushToTalkGatedControl membership bookkeeping (stale confirmations, refused commands)", .timeLimit(.minutes(1)))
struct PushToTalkGatedControlMembershipTests {
    let channel = kitchen

    @Test("a stale .joinFailed (undrained) across stop/start does not wedge the next session")
    func staleJoinFailedAcrossRestart() async throws {
        let service = FakePushToTalkChannel()
        let inner = RecordingTalkControl()
        let gate = PushToTalkGatedControl(inner: inner, service: service, channel: channel)
        await service.setJoinFailures(1)
        try await gate.start(channelName: "Kitchen")  // .joinFailed queued, not yet handled
        await gate.stop()
        try await gate.start(channelName: "Kitchen")  // .joined queued behind the stale .joinFailed
        try #require(await eventually { await gate.isJoinedToSystemChannel })
        withExtendedLifetime(gate) {}
    }

    @Test("a transmit failure delivered after stop() does not touch the coordinator")
    func transmitFailureAfterStopIgnored() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        await gate.stop()
        try await emitAndAwaitHandled(.beginTransmitFailed(channel), on: service, gate: gate)
        #expect(await inner.recorded == ["release"])  // stop's release only
        withExtendedLifetime(gate) {}
    }

    @Test("our own leave confirmation arriving after the next .joined does not end the new membership")
    func ownLeaveConfirmationAfterRejoinIgnored() async throws {
        let harness = try await makeGate()
        let (gate, service, _) = (harness.gate, harness.service, harness.inner)
        await service.setAutoLeaveEvents(false)  // hold the confirmation back…
        await gate.stop()
        try await gate.start(channelName: "Kitchen")
        try #require(await eventually { await gate.isJoinedToSystemChannel })
        // …deliver late
        try await emitAndAwaitHandled(.left(channel, reason: .developerRequest), on: service, gate: gate)
        #expect(await gate.isJoinedToSystemChannel)
        try await emitAndAwaitHandled(.joined(ChannelID("other")), on: service, gate: gate)  // drain
        #expect(await service.count(.join(channel, "Kitchen")) == 2)  // the replacement membership is kept: no rejoin
        withExtendedLifetime(gate) {}
    }

    @Test("a join refused while our leave was in flight is retried once the leave confirms")
    func joinRefusedDuringLeaveRetries() async throws {
        let harness = try await makeGate()
        let (gate, service, _) = (harness.gate, harness.service, harness.inner)
        await service.setAutoLeaveEvents(false)
        await service.setJoinFailures(1)  // the restart's join is refused (channel still held by the leaving session)
        try await gate.start(channelName: "Kitchen")
        try await emitAndAwaitHandled(.joined(ChannelID("other")), on: service, gate: gate)  // drain the joinFailed
        #expect(await gate.isJoinedToSystemChannel == false)
        // leave confirmed
        try await emitAndAwaitHandled(.left(channel, reason: .developerRequest), on: service, gate: gate)
        try #require(await eventually { await gate.isJoinedToSystemChannel })  // retried and confirmed
        #expect(await service.count(.join(channel, "Kitchen")) == 3)
        withExtendedLifetime(gate) {}
    }

    @Test("commands the service refuses leave the gate consistent (leave in stop, stop in mirror)")
    func serviceErrorsAreTolerated() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        try await emitAndAwaitHandled(.beginTransmittingRequested(channel), on: service, gate: gate)
        await service.setStopFailures(1)
        try await sendStateAndAwait(.idle, on: inner, gate: gate)  // mirror's stopTransmitting throws…
        #expect(await service.count(.stop(channel)) == 1)
        try await sendStateAndAwait(.receiving(from: becca.id), on: inner, gate: gate)  // …so the latch re-arms and retries
        #expect(await service.count(.stop(channel)) == 2)
        await service.setLeaveFailures(1)
        await gate.stop()  // leave throws: still a stopped gate
        #expect(await gate.isJoinedToSystemChannel == false)
        try await emitAndAwaitHandled(.beginTransmittingRequested(channel), on: service, gate: gate)
        #expect(await inner.recorded == ["press", "release"])  // nothing forwarded after stop
        try await gate.start(channelName: "Kitchen")
        try #require(await eventually { await gate.isJoinedToSystemChannel })
        withExtendedLifetime(gate) {}
    }

    @Test("a press the service refuses to issue leaves the gate consistent; the next press goes through")
    func beginRequestRefusedByService() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        await service.setBeginFailures(1)
        await gate.press()  // throws inside the service; swallowed
        await gate.press()
        #expect(await service.count(.begin(channel)) == 2)
        #expect(await inner.recorded.isEmpty)  // nothing reaches the coordinator without a system confirmation
        withExtendedLifetime(gate) {}
    }

    @Test("a leave the system refuses after stop() is retried (bounded); a refusal during a restart reconciles")
    func refusedLeaveRetriedOrReconciled() async throws {
        let harness = try await makeGate()
        let (gate, service, _) = (harness.gate, harness.service, harness.inner)
        await service.setAutoLeaveEvents(false)
        await gate.stop()  // leave #1 issued, unanswered
        try await emitAndAwaitHandled(.leaveFailed(channel), on: service, gate: gate)
        #expect(await eventually { await service.count(.leave(channel)) == 2 })  // retried
        try await emitAndAwaitHandled(.leaveFailed(channel), on: service, gate: gate)
        #expect(await eventually { await service.count(.leave(channel)) == 3 })
        try await emitAndAwaitHandled(.leaveFailed(channel), on: service, gate: gate)
        #expect(await service.count(.leave(channel)) == 3)  // bounded: no fourth attempt
        // restart path: the leave of the old session is refused after the new session joined → still a member
        await service.setAutoLeaveEvents(true)
        try await gate.start(channelName: "Kitchen")
        try #require(await eventually { await gate.isJoinedToSystemChannel })
        await service.setAutoLeaveEvents(false)
        try await gate.start(channelName: "Kitchen")  // restart: leave (unanswered) + join (answered by .joined)
        try #require(await eventually { await gate.isJoinedToSystemChannel })
        try await emitAndAwaitHandled(.leaveFailed(channel), on: service, gate: gate)  // old leave refused, late
        #expect(await gate.isJoinedToSystemChannel)  // unchanged: the membership is ours
        withExtendedLifetime(gate) {}
    }
}
