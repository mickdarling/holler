import Testing
import HollerCore
import HollerCoreTestSupport
@testable import HollerPTT

/// Leaves are answered in issue order; each carries the membership it was issued for and whether that membership was
/// ever confirmed. A session end that ends no membership must not retire an earlier leave still outstanding.
@Suite(.timeLimit(.minutes(1)))
struct PushToTalkGatedControlLeaveQueueTests {
    let channel = kitchen

    @Test("stop() while the old membership survived a refused leave issues a real leave: refused again → retried")
    func stopWhileMembershipSurvivedThenLeaveRefused() async throws {
        let harness = try await makeGate()
        let (gate, service, _) = (harness.gate, harness.service, harness.inner)
        await service.setAutoLeaveEvents(false)
        await service.setAutoJoinEvents(false)
        try await gate.start(channelName: "Kitchen")  // leave #1 unanswered, join #2 unanswered
        try await emitAndAwaitHandled(.leaveFailed(channel), on: service, gate: gate)  // membership survived
        #expect(await gate.membershipSurvived)
        await gate.stop()  // leave #2 for the surviving membership (confirmed by the refusal)
        try await emitAndAwaitHandled(.joinFailed(channel), on: service, gate: gate)  // retired #2 refused
        try await emitAndAwaitHandled(.leaveFailed(channel), on: service, gate: gate)  // leave #2 refused → retry
        #expect(await eventually { await service.count(.leave(channel)) == 3 })
        withExtendedLifetime(gate) {}
    }

    @Test("a second stop() that ends no membership does not retire the first stop's outstanding leave")
    func secondStopKeepsOutstandingLeave() async throws {
        let harness = try await makeGate()
        let (gate, service, _) = (harness.gate, harness.service, harness.inner)
        await service.setAutoLeaveEvents(false)
        await gate.stop()  // leave #1
        await gate.stop()  // nothing to leave
        try await emitAndAwaitHandled(.leaveFailed(channel), on: service, gate: gate)  // leave #1 refused → retry
        #expect(await eventually { await service.count(.leave(channel)) == 2 })
        withExtendedLifetime(gate) {}
    }

    @Test("a restart that ends no membership keeps the earlier leave's refusal meaningful: still a member")
    func restartKeepsEarlierLeaveRefusal() async throws {
        let harness = try await makeGate()
        let (gate, service, _) = (harness.gate, harness.service, harness.inner)
        await service.setAutoLeaveEvents(false)
        await service.setAutoJoinEvents(false)
        try await gate.start(channelName: "Kitchen")  // leave #1 unanswered, join #2
        try await emitAndAwaitHandled(.joinFailed(channel), on: service, gate: gate)  // #2 refused
        try await gate.start(channelName: "Kitchen")  // ends no membership; join #3
        try await emitAndAwaitHandled(.leaveFailed(channel), on: service, gate: gate)  // leave #1 refused: still in
        #expect(await gate.membershipSurvived)
        try await emitAndAwaitHandled(.joinFailed(channel), on: service, gate: gate)  // #3 refused
        #expect(await gate.isJoinedToSystemChannel)  // reconciled to the membership the system kept
        withExtendedLifetime(gate) {}
    }

    @Test("a stop() ending a later, unconfirmed session does not retire the first stop's leave: refused → retried")
    func laterSessionEndKeepsEarlierLeave() async throws {
        let harness = try await makeGate()
        let (gate, service, _) = (harness.gate, harness.service, harness.inner)
        await service.setAutoLeaveEvents(false)
        await service.setAutoJoinEvents(false)
        await gate.stop()  // leave #1 for the confirmed membership
        try await gate.start(channelName: "Kitchen")  // join #2 unanswered
        await gate.stop()  // leave #2 for join #2's maybe-membership
        try await emitAndAwaitHandled(.leaveFailed(channel), on: service, gate: gate)  // leave #1 refused: still in
        #expect(await eventually { await service.count(.leave(channel)) == 3 })  // retried
        withExtendedLifetime(gate) {}
    }

    @Test("a membership ended by the user invalidates only the leaves issued for it; a later real one is still left")
    func userLeaveInvalidatesOnlyEarlierLeaves() async throws {
        let service = FakePushToTalkChannel()
        let inner = RecordingTalkControl()
        let gate = PushToTalkGatedControl(inner: inner, service: service, channel: channel)
        await service.setAutoJoinEvents(false)
        await service.setAutoLeaveEvents(false)
        try await gate.start(channelName: "Kitchen")  // join #1 unanswered
        await gate.stop()  // leave #1, behind join #1
        try await gate.start(channelName: "Kitchen")  // join #2 unanswered
        await gate.stop()  // leave #2, behind join #2
        try await emitAndAwaitHandled(.joined(channel), on: service, gate: gate)  // #1 accepted: leave #1 is real
        try await emitAndAwaitHandled(.left(channel, reason: .userRequest), on: service, gate: gate)  // user ends it
        try await emitAndAwaitHandled(.left(channel, reason: .developerRequest), on: service, gate: gate)  // leave #1
        try await emitAndAwaitHandled(.joined(channel), on: service, gate: gate)  // #2 accepted: leave #2 is real
        try await emitAndAwaitHandled(.leaveFailed(channel), on: service, gate: gate)  // leave #2 refused: still in
        #expect(await eventually { await service.count(.leave(channel)) == 3 })  // retried, not discarded
        #expect(await gate.isJoinedToSystemChannel == false)
        withExtendedLifetime(gate) {}
    }

    @Test("a leave queued behind an unanswered join ends the membership that join creates, not the one ending now")
    func leaveBehindJoinSurvivesEarlierMembershipEnd() async throws {
        let service = FakePushToTalkChannel()
        let inner = RecordingTalkControl()
        let gate = PushToTalkGatedControl(inner: inner, service: service, channel: channel)
        await service.setAutoJoinEvents(false)
        await service.setAutoLeaveEvents(false)
        try await gate.start(channelName: "Kitchen")  // join #1 unanswered
        await gate.stop()  // leave #1, behind join #1
        try await gate.start(channelName: "Kitchen")  // join #2 unanswered
        try await emitAndAwaitHandled(.joined(channel), on: service, gate: gate)  // #1 accepted: M1 live (survived)
        #expect(await gate.membershipSurvived)
        await gate.stop()  // leave #2, behind join #2, for a live membership
        try await emitAndAwaitHandled(.left(channel, reason: .unknown), on: service, gate: gate)  // M1 ends
        try await emitAndAwaitHandled(.leaveFailed(channel), on: service, gate: gate)  // leave #1: nothing to leave
        try await emitAndAwaitHandled(.joined(channel), on: service, gate: gate)  // #2 accepted: M2 live
        try await emitAndAwaitHandled(.leaveFailed(channel), on: service, gate: gate)  // leave #2 refused: still in M2
        #expect(await eventually { await service.count(.leave(channel)) == 3 })  // retried: M2 is ours to end
        withExtendedLifetime(gate) {}
    }
}
