import Testing
import HollerCore
import HollerCoreTestSupport
@testable import HollerPTT

/// stop()/start() release the coordinator before deciding about the leave; what the system reports during that
/// await (a retired join accepted, the membership ended) must shape the decision.
@Suite(.timeLimit(.minutes(1)))
struct PushToTalkGatedControlReleaseWindowTests {
    let channel = kitchen

    @Test("a retired join accepted while stop() is releasing the coordinator makes its leave a real one: retried")
    func staleAcceptedDuringReleaseThenLeaveRefused() async throws {
        let service = FakePushToTalkChannel()
        let inner = RecordingTalkControl()
        let gate = PushToTalkGatedControl(inner: inner, service: service, channel: channel)
        await service.setAutoJoinEvents(false)
        await service.setAutoLeaveEvents(false)
        try await gate.start(channelName: "Kitchen")  // join #1 unanswered
        await inner.setHoldReleases(true)
        let stopping = Task { await gate.stop() }  // retires #1; parks in inner.release()
        try #require(await eventually { await inner.pendingReleases == 1 })
        try await emitAndAwaitHandled(.joined(channel), on: service, gate: gate)  // #1 accepted: a real membership
        await inner.setHoldReleases(false)
        await inner.releaseAll()
        await stopping.value  // leave #1 issued for a confirmed membership
        try await emitAndAwaitHandled(.leaveFailed(channel), on: service, gate: gate)  // refused: still in → retry
        #expect(await eventually { await service.count(.leave(channel)) == 2 })
        withExtendedLifetime(gate) {}
    }

    @Test("a retired join accepted while stop() releases the coordinator is left even if nothing was pending before")
    func staleAcceptedDuringReleaseWithNothingPendingIsLeft() async throws {
        let service = FakePushToTalkChannel()
        let inner = RecordingTalkControl()
        let gate = PushToTalkGatedControl(inner: inner, service: service, channel: channel)
        await service.setAutoJoinEvents(false)
        await service.setAutoLeaveEvents(false)
        try await gate.start(channelName: "Kitchen")  // join #1 unanswered
        await service.setLeaveFailures(1)
        await gate.stop()  // leave #1's command throws: nothing pending, join #1 retired and unanswered
        await inner.setHoldReleases(true)
        let stopping = Task { await gate.stop() }  // parks in inner.release(); nothing looked like a membership
        try #require(await eventually { await inner.pendingReleases == 1 })
        try await emitAndAwaitHandled(.joined(channel), on: service, gate: gate)  // #1 accepted meanwhile: real
        await inner.setHoldReleases(false)
        await inner.releaseAll()
        await stopping.value
        #expect(await eventually { await service.count(.leave(channel)) == 2 })  // that membership is left
        withExtendedLifetime(gate) {}
    }

    @Test("a membership ended while stop() releases the coordinator is not left: nothing survived")
    func membershipEndedDuringReleaseIsNotLeft() async throws {
        for reason in [PushToTalkLeaveReason.unknown, .userRequest] {
            let harness = try await makeGate()
            let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
            await service.setAutoLeaveEvents(false)
            await inner.setHoldReleases(true)
            let stopping = Task { await gate.stop() }  // parks in inner.release()
            try #require(await eventually { await inner.pendingReleases == 1 })
            try await emitAndAwaitHandled(.left(channel, reason: reason), on: service, gate: gate)  // over meanwhile
            await inner.setHoldReleases(false)
            await inner.releaseAll()
            await stopping.value
            #expect(await service.count(.leave(channel)) == 0, "reason=\(reason)")  // no phantom leave
            #expect(await gate.membershipSurvived == false, "reason=\(reason)")
            await gate.stopAndAwaitLeave()  // settles at once
            withExtendedLifetime(gate) {}
        }
    }

    @Test("a membership adopted from a refused earlier leave is ended by our own later leave: joined clears, rejoin")
    func adoptedMembershipEndedByOurQueuedLeave() async throws {
        let harness = try await makeGate()
        let (gate, service, _) = (harness.gate, harness.service, harness.inner)
        await service.setAutoJoinEvents(false)
        await service.setAutoLeaveEvents(false)
        await gate.stop()  // leave #1 for the confirmed membership
        try await gate.start(channelName: "Kitchen")  // join #2
        await gate.stop()  // leave #2 behind join #2
        await service.setHoldPrepares(true)
        let starting = Task { try await gate.start(channelName: "Kitchen") }  // parks in prepare()
        try #require(await eventually { await service.pendingPrepares == 1 })
        try await emitAndAwaitHandled(.leaveFailed(channel), on: service, gate: gate)  // leave #1 refused: still in
        try #require(await gate.isJoinedToSystemChannel)  // adopted while starting
        await service.setHoldPrepares(false)
        await service.releasePrepares()
        try await starting.value  // already a member: no third join
        try await emitAndAwaitHandled(.joined(channel), on: service, gate: gate)  // #2 (retired) accepted
        try await emitAndAwaitHandled(.left(channel, reason: .developerRequest), on: service, gate: gate)  // leave #2
        #expect(await gate.isJoinedToSystemChannel == false)  // our own leave ended that membership
        #expect(await eventually { await service.count(.join(channel, "Kitchen")) == 3 })  // and the session rejoins
        withExtendedLifetime(gate) {}
    }

    @Test("a leave whose command fails is judged by its entry as the answers during the call left it")
    func unissuableLeaveUsesItsOwnUpdatedEntry() async throws {
        let service = FakePushToTalkChannel()
        let inner = RecordingTalkControl()
        let gate = PushToTalkGatedControl(inner: inner, service: service, channel: channel)
        await service.setAutoJoinEvents(false)
        await service.setAutoLeaveEvents(false)
        try await gate.start(channelName: "Kitchen")  // join #1 unanswered
        await service.setHoldLeaves(true)
        await service.setLeaveFailures(1)  // leave #1's command will throw once released
        let stopping = Task { await gate.stop() }  // leave #1 behind join #1, parked inside service.leave
        try #require(await eventually { await service.pendingLeaveCalls == 1 })
        try await emitAndAwaitHandled(.joined(channel), on: service, gate: gate)  // #1 accepted meanwhile: a member
        await service.setHoldLeaves(false)
        await service.releaseLeaves()  // the command throws: never sent, but its entry now says "live membership"
        await stopping.value
        #expect(await eventually { await service.count(.leave(channel)) == 2 })  // retried, not discarded
        withExtendedLifetime(gate) {}
    }

    @Test("a join issued while a retry leave's command is in flight counts as ahead of it")
    func joinOvertakingInFlightLeaveCountsAsAhead() async throws {
        let harness = try await makeGate()
        let (gate, service, _) = (harness.gate, harness.service, harness.inner)
        await service.setAutoLeaveEvents(false)
        await gate.stop()  // leave #1 for the confirmed membership
        await service.setHoldLeaves(true)
        service.emit(.leaveFailed(channel))  // refused → the retry leave #2 (issued on the event pump) parks in leave()
        try #require(await eventually { await service.pendingLeaveCalls == 1 })
        try await gate.start(channelName: "Kitchen")  // join #2 reaches the system first; its acceptance is queued
        await service.setHoldLeaves(false)
        await service.releaseLeaves()  // leave #2 now reaches the system, behind join #2: it ends that membership
        try await emitAndAwaitHandled(.left(channel, reason: .developerRequest), on: service, gate: gate)  // leave #2
        #expect(await eventually { await service.count(.join(channel, "Kitchen")) == 3 })  // ended → rejoined
        withExtendedLifetime(gate) {}
    }

    @Test("an older leave's confirmation landing while stop() releases the coordinator keeps the live membership")
    func olderLeaveConfirmationDuringReleaseKeepsLiveMembership() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        await service.setAutoLeaveEvents(false)
        await gate.stop()  // leave #1 for M1, unanswered
        try await gate.start(channelName: "Kitchen")  // join #2 accepted: M2 live
        try #require(await eventually { await gate.isJoinedToSystemChannel })
        await inner.setHoldReleases(true)
        let stopping = Task { await gate.stop() }  // parks in inner.release(); M2's liveness is carried in state
        try #require(await eventually { await inner.pendingReleases == 1 })
        try await emitAndAwaitHandled(.left(channel, reason: .developerRequest), on: service, gate: gate)  // leave #1
        await inner.setHoldReleases(false)
        await inner.releaseAll()
        await stopping.value
        #expect(await eventually { await service.count(.leave(channel)) == 2 })  // M2 is left
        withExtendedLifetime(gate) {}
    }
}
