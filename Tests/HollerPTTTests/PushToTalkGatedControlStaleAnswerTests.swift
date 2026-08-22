import Testing
import HollerCore
import HollerCoreTestSupport
@testable import HollerPTT

@Suite("PushToTalkGatedControl stale answers and overtaking callbacks", .timeLimit(.minutes(1)))
struct PushToTalkGatedControlStaleAnswerTests {
    let channel = kitchen

    @Test("a join answer that lands after stop() does not re-arm the stopped gate")
    func joinAnswerAfterStopIgnored() async throws {
        let service = FakePushToTalkChannel()
        let inner = RecordingTalkControl()
        let gate = PushToTalkGatedControl(inner: inner, service: service, channel: channel)
        await service.setAutoJoinEvents(false)
        try await gate.start(channelName: "Kitchen")  // join unanswered
        await gate.stop()
        try await emitAndAwaitHandled(.joined(channel), on: service, gate: gate)  // late answer
        #expect(await gate.isJoinedToSystemChannel == false)
        try await emitAndAwaitHandled(.beginTransmittingRequested(channel), on: service, gate: gate)
        #expect(await inner.recorded == ["release"])  // nothing forwarded after stop
        #expect(await gate.isSystemTransmitting == false)
        try await gate.start(channelName: "Kitchen")
        try await emitAndAwaitHandled(.joined(channel), on: service, gate: gate)  // the new session's answer
        try #require(await eventually { await gate.isJoinedToSystemChannel })
        withExtendedLifetime(gate) {}
    }

    @Test("a system drop while a rejoin is still unanswered rejoins again after that answer")
    func secondDropWhileRejoinPendingRetries() async throws {
        let harness = try await makeGate()
        let (gate, service, _) = (harness.gate, harness.service, harness.inner)
        await service.setAutoJoinEvents(false)
        // rejoin #1 unanswered
        try await emitAndAwaitHandled(.left(channel, reason: .unknown), on: service, gate: gate)
        try await emitAndAwaitHandled(.left(channel, reason: .unknown), on: service, gate: gate)  // dropped again
        #expect(await service.count(.join(channel, "Kitchen")) == 2)
        try await emitAndAwaitHandled(.joinFailed(channel), on: service, gate: gate)  // answer to rejoin #1
        #expect(await eventually { await service.count(.join(channel, "Kitchen")) == 3 })  // rejoin #2 issued
        await service.setAutoJoinEvents(true)
        try await emitAndAwaitHandled(.joined(channel), on: service, gate: gate)
        try #require(await eventually { await gate.isJoinedToSystemChannel })
        withExtendedLifetime(gate) {}
    }

    @Test("a press in flight when stop() runs is undone so the coordinator cannot keep a floor request")
    func pressOvertakingStopIsUndone() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        await inner.setHoldPresses(true)
        service.emit(.beginTransmittingRequested(channel))
        try #require(await eventually { await inner.pendingPresses == 1 })  // the pump is inside inner.press()
        await gate.stop()
        await inner.releasePresses()
        #expect(await eventually { await inner.recorded == ["release", "press", "release"] })  // press undone
        withExtendedLifetime(gate) {}
    }

    @Test("join answers are matched to join requests: a late answer to an earlier join is ignored (both orders)")
    func joinAnswersCorrelated() async throws {
        for staleFirst in [true, false] {
            let service = FakePushToTalkChannel()
            let inner = RecordingTalkControl()
            let gate = PushToTalkGatedControl(inner: inner, service: service, channel: channel)
            await service.setAutoJoinEvents(false)
            try await gate.start(channelName: "Kitchen")  // join #1, unanswered
            try await gate.start(channelName: "Kitchen")  // restart: join #2
            let first: PushToTalkEvent = staleFirst ? .joinFailed(channel) : .joined(channel)
            let second: PushToTalkEvent = staleFirst ? .joined(channel) : .joinFailed(channel)
            try await emitAndAwaitHandled(first, on: service, gate: gate)   // answer to #1 (stale)
            try await emitAndAwaitHandled(second, on: service, gate: gate)  // answer to #2 (current)
            #expect(await gate.isJoinedToSystemChannel == staleFirst, "staleFirst=\(staleFirst)")
            withExtendedLifetime(gate) {}
        }
    }

    @Test("a system drop during a transmission releases the coordinator")
    func leftMidTransmissionReleases() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        try await emitAndAwaitHandled(.beginTransmittingRequested(channel), on: service, gate: gate)
        await service.setAutoJoinEvents(false)  // keep the rejoin unconfirmed
        try await emitAndAwaitHandled(.left(channel, reason: .unknown), on: service, gate: gate)
        #expect(await inner.recorded == ["press", "release"])
        #expect(await gate.isSystemTransmitting == false)
        withExtendedLifetime(gate) {}
    }

    @Test("an end-transmitting callback from an earlier membership is ignored after the rejoin")
    func staleEndCallbackAfterRejoinIgnored() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        try await emitAndAwaitHandled(.beginTransmittingRequested(channel), on: service, gate: gate)
        try await emitAndAwaitHandled(.left(channel, reason: .unknown), on: service, gate: gate)  // releases; rejoins
        try #require(await eventually { await gate.isJoinedToSystemChannel })
        // stale (old session)
        try await emitAndAwaitHandled(.endTransmittingRequested(channel), on: service, gate: gate)
        #expect(await inner.recorded == ["press", "release"])  // no second release
        // new transmission
        try await emitAndAwaitHandled(.beginTransmittingRequested(channel), on: service, gate: gate)
        #expect(await gate.isSystemTransmitting)
        try await emitAndAwaitHandled(.endTransmittingRequested(channel), on: service, gate: gate)  // current: honoured
        #expect(await inner.recorded == ["press", "release", "press", "release"])
        #expect(await gate.isSystemTransmitting == false)
        withExtendedLifetime(gate) {}
    }

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
}
