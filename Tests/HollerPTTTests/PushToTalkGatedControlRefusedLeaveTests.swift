import Testing
import HollerCore
import HollerCoreTestSupport
@testable import HollerPTT

/// A refused leave means the membership stands: the gate reconciles to it and never joins again on its account.
@Suite(.timeLimit(.minutes(1)))
struct PushToTalkGatedControlRefusedLeaveTests {
    let channel = kitchen

    @Test("a retired join accepted while our leave is in flight, then that leave refused: the membership is ours")
    func staleAcceptedThenLeaveRefused() async throws {
        let service = FakePushToTalkChannel()
        let inner = RecordingTalkControl()
        let gate = PushToTalkGatedControl(inner: inner, service: service, channel: channel)
        await service.setAutoJoinEvents(false)
        await service.setAutoLeaveEvents(false)
        try await gate.start(channelName: "Kitchen")  // join #1 unanswered
        await service.setHoldPrepares(true)
        let restarting = Task { try await gate.start(channelName: "Kitchen") }  // retires #1, issues leave #1
        try #require(await eventually { await service.pendingPrepares == 1 })
        try await emitAndAwaitHandled(.joined(channel), on: service, gate: gate)  // #1 accepted late: a member
        await service.setHoldPrepares(false)
        await service.releasePrepares()
        try await restarting.value  // join #2 issued, unanswered
        try await emitAndAwaitHandled(.leaveFailed(channel), on: service, gate: gate)  // leave #1 refused: still in
        #expect(await gate.membershipSurvived)
        try await emitAndAwaitHandled(.joinFailed(channel), on: service, gate: gate)  // #2 refused: that one blocked it
        #expect(await gate.isJoinedToSystemChannel)  // reconciled to the surviving membership
        #expect(await service.count(.join(channel, "Kitchen")) == 2)  // no third join
        withExtendedLifetime(gate) {}
    }

    @Test("a join refused while our leave was in flight, then that leave refused too: still a member, no rejoin")
    func joinRefusedThenLeaveRefused() async throws {
        let harness = try await makeGate()
        let (gate, service, _) = (harness.gate, harness.service, harness.inner)
        await service.setAutoLeaveEvents(false)
        await service.setJoinFailures(2)  // the held membership blocks replacement joins
        try await gate.start(channelName: "Kitchen")  // leave #1 unanswered; join #2 refused
        try await emitAndAwaitHandled(.leaveFailed(channel), on: service, gate: gate)  // leave #1 refused
        try await emitAndAwaitHandled(.joined(ChannelID("other")), on: service, gate: gate)  // drain
        #expect(await gate.isJoinedToSystemChannel)
        #expect(await service.count(.join(channel, "Kitchen")) == 2)
        withExtendedLifetime(gate) {}
    }

    @Test("a refused leave of a membership never confirmed proves nothing: the retired join's refusal decides")
    func refusedLeaveOfNeverJoinedMembership() async throws {
        for duringPrepare in [true, false] {
            let service = FakePushToTalkChannel()
            let inner = RecordingTalkControl()
            let gate = PushToTalkGatedControl(inner: inner, service: service, channel: channel)
            await service.setAutoJoinEvents(false)
            await service.setAutoLeaveEvents(false)
            try await gate.start(channelName: "Kitchen")  // join #1 unanswered
            await service.setHoldPrepares(duringPrepare)
            let restarting = Task { try await gate.start(channelName: "Kitchen") }  // retires #1, issues leave #1
            if duringPrepare {
                try #require(await eventually { await service.pendingPrepares == 1 })
            } else {
                try await restarting.value
            }
            try await emitAndAwaitHandled(.joinFailed(channel), on: service, gate: gate)  // #1 refused: never a member
            try await emitAndAwaitHandled(.leaveFailed(channel), on: service, gate: gate)  // leave #1 refused: so what
            #expect(await gate.isJoinedToSystemChannel == false, "duringPrepare=\(duringPrepare)")
            #expect(await gate.membershipSurvived == false, "duringPrepare=\(duringPrepare)")
            if duringPrepare {
                await service.setHoldPrepares(false)
                await service.releasePrepares()
                try await restarting.value
            }
            #expect(await service.count(.join(channel, "Kitchen")) == 2, "duringPrepare=\(duringPrepare)")  // #2 issued
            try await emitAndAwaitHandled(.joined(channel), on: service, gate: gate)  // #2 accepted
            #expect(await gate.isJoinedToSystemChannel, "duringPrepare=\(duringPrepare)")
            withExtendedLifetime(gate) {}
        }
    }

    @Test("our confirmed leave ends a membership a late-accepted retired join said survived")
    func ownLeaveEndsSurvivingMembership() async throws {
        let service = FakePushToTalkChannel()
        let inner = RecordingTalkControl()
        let gate = PushToTalkGatedControl(inner: inner, service: service, channel: channel)
        await service.setAutoJoinEvents(false)
        await service.setAutoLeaveEvents(false)
        try await gate.start(channelName: "Kitchen")  // join #1 unanswered
        try await gate.start(channelName: "Kitchen")  // leave #1 issued, join #2 issued
        try await emitAndAwaitHandled(.joined(channel), on: service, gate: gate)  // #1 accepted: a member, for now
        #expect(await gate.membershipSurvived)
        try await emitAndAwaitHandled(.left(channel, reason: .developerRequest), on: service, gate: gate)  // leave #1
        #expect(await gate.membershipSurvived == false)
        try await emitAndAwaitHandled(.joinFailed(channel), on: service, gate: gate)  // #2 refused
        #expect(await gate.isJoinedToSystemChannel == false)  // nothing to fall back on
        try await emitAndAwaitHandled(.beginTransmittingRequested(channel), on: service, gate: gate)
        #expect(await inner.recorded.contains("press") == false)  // not a member: no press
        withExtendedLifetime(gate) {}
    }

    @Test("our own confirmed leave tells the leaves queued behind it that nothing is live: no phantom membership")
    func ownLeaveInformsLeavesBehind() async throws {
        let service = FakePushToTalkChannel()
        let inner = RecordingTalkControl()
        let gate = PushToTalkGatedControl(inner: inner, service: service, channel: channel)
        await service.setAutoJoinEvents(false)
        await service.setAutoLeaveEvents(false)
        try await gate.start(channelName: "Kitchen")  // join #1
        await gate.stop()  // leave #1 behind join #1
        try await gate.start(channelName: "Kitchen")  // join #2
        try await emitAndAwaitHandled(.joined(channel), on: service, gate: gate)  // #1 accepted: M1 live
        await gate.stop()  // leave #2 behind join #2
        try await emitAndAwaitHandled(.left(channel, reason: .developerRequest), on: service, gate: gate)  // leave #1
        try await emitAndAwaitHandled(.joinFailed(channel), on: service, gate: gate)  // #2 refused: nothing live
        try await gate.start(channelName: "Kitchen")  // join #3
        try await emitAndAwaitHandled(.leaveFailed(channel), on: service, gate: gate)  // leave #2: nothing to leave
        #expect(await gate.membershipSurvived == false)
        try await emitAndAwaitHandled(.joinFailed(channel), on: service, gate: gate)  // #3 refused
        #expect(await gate.isJoinedToSystemChannel == false)  // no phantom membership
        try await emitAndAwaitHandled(.beginTransmittingRequested(channel), on: service, gate: gate)
        #expect(await inner.recorded.contains("press") == false)
        withExtendedLifetime(gate) {}
    }

    @Test("after the leave retries are exhausted the membership is still ours: the next start reconciles to it")
    func exhaustedLeavesKeepMembershipKnown() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        await service.setLeaveFailures(3)  // every attempt refused: the system keeps us in
        await service.setAutoJoinEvents(false)
        await gate.stop()
        #expect(await eventually { await service.count(.leave(channel)) == 3 })  // bounded, then gives up
        #expect(await gate.membershipSurvived)
        try await gate.start(channelName: "Kitchen")  // join #2
        try await emitAndAwaitHandled(.joinFailed(channel), on: service, gate: gate)  // refused: already in
        #expect(await gate.isJoinedToSystemChannel)  // reconciled to the membership the system kept
        try await emitAndAwaitHandled(.beginTransmittingRequested(channel), on: service, gate: gate)
        #expect(await inner.recorded.last == "press")
        await gate.stop()  // and the session end leaves it again
        #expect(await eventually { await service.count(.leave(channel)) == 4 })
        withExtendedLifetime(gate) {}
    }
}
