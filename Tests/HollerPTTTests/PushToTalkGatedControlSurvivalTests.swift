import Testing
import HollerCore
import HollerCoreTestSupport
@testable import HollerPTT

/// A membership that the system says is still ours (a refused leave, a retired join accepted late) is held: a leave
/// of it ends it for good, the user ending it is final for the session, and one adopted during a restart's prepare()
/// becomes that session's membership (no second join).
@Suite(.timeLimit(.minutes(1)))
struct PushToTalkGatedControlSurvivalTests {
    let channel = kitchen

    @Test("any leave ends a membership that survived a refused leave: a later refused join does not re-adopt it")
    func leaveEndsSurvivingMembership() async throws {
        for reason in [PushToTalkLeaveReason.unknown, .developerRequest] {
            let harness = try await makeGate()
            let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
            await service.setAutoLeaveEvents(false)
            await service.setAutoJoinEvents(false)
            await service.setHoldJoins(true)
            let restarting = Task { try await gate.start(channelName: "Kitchen") }  // leave unanswered; join #2 held
            try #require(await eventually { await service.pendingJoins == 1 })
            try await emitAndAwaitHandled(.leaveFailed(channel), on: service, gate: gate)  // membership survives…
            try await emitAndAwaitHandled(.left(channel, reason: reason), on: service, gate: gate)  // …then ends
            await service.setHoldJoins(false)
            await service.releaseJoins()
            try await restarting.value
            try await emitAndAwaitHandled(.joinFailed(channel), on: service, gate: gate)  // join #2 refused
            #expect(await gate.isJoinedToSystemChannel == false, "reason=\(reason)")  // nothing to fall back on
            try await emitAndAwaitHandled(.beginTransmittingRequested(channel), on: service, gate: gate)
            #expect(await inner.recorded == ["release"], "reason=\(reason)")  // not a member: no press
            withExtendedLifetime(gate) {}
        }
    }

    @Test("a leave before our own leave is refused: nothing survived, a refused join does not re-adopt it")
    func leaveBeforeRefusedLeaveLeavesNothingToSurvive() async throws {
        for reason in [PushToTalkLeaveReason.unknown, .userRequest] {
            let harness = try await makeGate()
            let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
            await service.setAutoLeaveEvents(false)
            await service.setAutoJoinEvents(false)
            try await gate.start(channelName: "Kitchen")  // leave #1 and join #2 both outstanding
            try await emitAndAwaitHandled(.left(channel, reason: reason), on: service, gate: gate)  // ended anyway
            try await emitAndAwaitHandled(.leaveFailed(channel), on: service, gate: gate)  // leave #1: nothing to leave
            #expect(await gate.membershipSurvived == false, "reason=\(reason)")
            try await emitAndAwaitHandled(.joinFailed(channel), on: service, gate: gate)  // join #2 refused
            #expect(await gate.isJoinedToSystemChannel == false, "reason=\(reason)")
            try await emitAndAwaitHandled(.beginTransmittingRequested(channel), on: service, gate: gate)
            #expect(await inner.recorded == ["release"], "reason=\(reason)")
            withExtendedLifetime(gate) {}
        }
    }

    @Test("a user leave of the old membership surviving through a late-accepted join leaves the new request standing")
    func userLeaveOfSurvivingMembershipKeepsStandingJoin() async throws {
        let service = FakePushToTalkChannel()
        let inner = RecordingTalkControl()
        let gate = PushToTalkGatedControl(inner: inner, service: service, channel: channel)
        await service.setAutoJoinEvents(false)
        await service.setAutoLeaveEvents(false)
        try await gate.start(channelName: "Kitchen")  // join #1 unanswered
        await gate.stop()  // join #1 retired; leave #1 unanswered
        try await gate.start(channelName: "Kitchen")  // join #2 unanswered
        try await emitAndAwaitHandled(.joined(channel), on: service, gate: gate)  // #1 accepted late: we are a member
        #expect(await gate.membershipSurvived)
        try await emitAndAwaitHandled(.left(channel, reason: .userRequest), on: service, gate: gate)  // user leaves it
        #expect(await gate.terminalLeave == false)  // join #2 is the session's standing request: not affected
        #expect(await gate.membershipSurvived == false)
        try await emitAndAwaitHandled(.leaveFailed(channel), on: service, gate: gate)  // leave #1: nothing to leave
        try await emitAndAwaitHandled(.joined(channel), on: service, gate: gate)  // #2 accepted
        #expect(await gate.isJoinedToSystemChannel)
        #expect(await service.count(.join(channel, "Kitchen")) == 2)
        withExtendedLifetime(gate) {}
    }

    @Test("a terminal leave during prepare() of a membership adopted meanwhile does not outlive the new session")
    func terminalLeaveOfAdoptedMembershipDuringPrepare() async throws {
        let harness = try await makeGate()
        let (gate, service, _) = (harness.gate, harness.service, harness.inner)
        await service.setAutoLeaveEvents(false)
        await service.setHoldPrepares(true)
        let restarting = Task { try await gate.start(channelName: "Kitchen") }  // old leave issued; prepare held
        try #require(await eventually { await service.pendingPrepares == 1 })
        try await emitAndAwaitHandled(.leaveFailed(channel), on: service, gate: gate)  // old membership survived…
        try #require(await gate.isJoinedToSystemChannel)
        try await emitAndAwaitHandled(.left(channel, reason: .userRequest), on: service, gate: gate)  // …user ends it
        await service.setHoldPrepares(false)
        await service.releasePrepares()
        try await restarting.value
        try #require(await eventually { await gate.isJoinedToSystemChannel })  // the new session joins
        #expect(await gate.terminalLeave == false)
        try await emitAndAwaitHandled(.left(channel, reason: .unknown), on: service, gate: gate)  // and still rejoins
        #expect(await eventually { await service.count(.join(channel, "Kitchen")) == 3 })
        withExtendedLifetime(gate) {}
    }

    @Test("a user leave of the adopted old membership during the startup join does not veto the new session")
    func terminalLeaveOfAdoptedMembershipDuringStartupJoin() async throws {
        let harness = try await makeGate()
        let (gate, service, _) = (harness.gate, harness.service, harness.inner)
        await service.setAutoLeaveEvents(false)
        await service.setAutoJoinEvents(false)
        await service.setHoldJoins(true)
        let restarting = Task { try await gate.start(channelName: "Kitchen") }  // leave issued; join #2 held
        try #require(await eventually { await service.pendingJoins == 1 })
        try await emitAndAwaitHandled(.leaveFailed(channel), on: service, gate: gate)  // old membership survived…
        try await emitAndAwaitHandled(.left(channel, reason: .userRequest), on: service, gate: gate)  // …user ends it
        await service.setHoldJoins(false)
        await service.releaseJoins()
        try await restarting.value
        #expect(await gate.terminalLeave == false)
        #expect(await gate.staleJoins == 0)  // the startup join is current, not retired
        try await emitAndAwaitHandled(.joined(channel), on: service, gate: gate)  // join #2 accepted
        #expect(await gate.isJoinedToSystemChannel)
        #expect(await service.count(.leave(channel)) == 1)  // the new membership is kept
        withExtendedLifetime(gate) {}
    }

    @Test("a membership adopted during prepare() is the session's: no second join, and the user ending it is final")
    func adoptedMembershipDuringPrepareIsTheSessions() async throws {
        let harness = try await makeGate()
        let (gate, service, _) = (harness.gate, harness.service, harness.inner)
        await service.setAutoLeaveEvents(false)
        await service.setHoldPrepares(true)
        let restarting = Task { try await gate.start(channelName: "Kitchen") }  // leave #1 issued; prepare held
        try #require(await eventually { await service.pendingPrepares == 1 })
        try await emitAndAwaitHandled(.leaveFailed(channel), on: service, gate: gate)  // old membership survived…
        try #require(await gate.isJoinedToSystemChannel)  // …and is adopted while starting
        await service.setHoldPrepares(false)
        await service.releasePrepares()
        try await restarting.value
        #expect(await service.count(.join(channel, "Kitchen")) == 1)  // no redundant join for a channel we are in
        #expect(await gate.joinsOutstanding == 0)
        #expect(await gate.terminalLeave == false)
        try await emitAndAwaitHandled(.left(channel, reason: .userRequest), on: service, gate: gate)  // user ends it
        try await emitAndAwaitHandled(.left(channel, reason: .unknown), on: service, gate: gate)  // stray drop
        try await emitAndAwaitHandled(.joined(ChannelID("other")), on: service, gate: gate)  // drain
        #expect(await gate.terminalLeave)
        #expect(await service.count(.join(channel, "Kitchen")) == 1)  // final: no rejoin
        withExtendedLifetime(gate) {}
    }

    @Test("a retired join accepted while our own leave is still in flight is not the new session's membership")
    func staleJoinAcceptedWhileOwnLeaveInFlight() async throws {
        let service = FakePushToTalkChannel()
        let inner = RecordingTalkControl()
        let gate = PushToTalkGatedControl(inner: inner, service: service, channel: channel)
        await service.setAutoJoinEvents(false)
        await service.setAutoLeaveEvents(false)
        try await gate.start(channelName: "Kitchen")  // join #1 unanswered
        await service.setHoldPrepares(true)
        let restarting = Task { try await gate.start(channelName: "Kitchen") }  // retires join #1, issues leave #1
        try #require(await eventually { await service.pendingPrepares == 1 })  // leave #1 was issued before it
        try await emitAndAwaitHandled(.joined(channel), on: service, gate: gate)  // join #1 accepted, late
        #expect(await gate.isJoinedToSystemChannel == false)  // leave #1 (issued after it) ends that membership
        await service.setHoldPrepares(false)
        await service.releasePrepares()
        try await restarting.value  // join #2 issued
        try await emitAndAwaitHandled(.left(channel, reason: .developerRequest), on: service, gate: gate)  // leave #1
        #expect(await gate.isJoinedToSystemChannel == false)
        await service.setAutoJoinEvents(true)
        try await emitAndAwaitHandled(.joined(channel), on: service, gate: gate)  // join #2 accepted
        try #require(await eventually { await gate.isJoinedToSystemChannel })
        #expect(await service.count(.join(channel, "Kitchen")) == 2)
        withExtendedLifetime(gate) {}
    }
}
