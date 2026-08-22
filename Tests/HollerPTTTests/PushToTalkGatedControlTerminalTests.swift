import Testing
import HollerCore
import HollerCoreTestSupport
@testable import HollerPTT

/// A terminal leave (the user or the system ended a membership the session holds) is final for the session: no latch,
/// late answer, or later event may join again before the next start(). A leave while not joined concerns a membership
/// already retired and must not touch the new session.
@Suite(.timeLimit(.minutes(1)))
struct PushToTalkGatedControlTerminalTests {
    let channel = kitchen

    @Test("a user leave of the retired membership while our leave is in flight does not cancel the new session's retry")
    func lateUserLeaveKeepsRetryAfterRefusedJoin() async throws {
        let harness = try await makeGate()
        let (gate, service, _) = (harness.gate, harness.service, harness.inner)
        await service.setAutoLeaveEvents(false)
        await service.setAutoJoinEvents(false)
        await service.setHoldJoins(true)
        let restarting = Task { try await gate.start(channelName: "Kitchen") }  // leave issued; join #2 held
        try #require(await eventually { await service.pendingJoins == 1 })
        try await emitAndAwaitHandled(.joinFailed(channel), on: service, gate: gate)  // refused; our leave in flight
        try await emitAndAwaitHandled(.left(channel, reason: .userRequest), on: service, gate: gate)  // old one, late
        await service.setHoldJoins(false)
        await service.releaseJoins()
        try await restarting.value
        #expect(await gate.terminalLeave == false)
        await service.setAutoJoinEvents(true)
        try await emitAndAwaitHandled(.left(channel, reason: .developerRequest), on: service, gate: gate)  // ours
        try #require(await eventually { await gate.isJoinedToSystemChannel })  // retried once our leave confirmed
        #expect(await service.count(.join(channel, "Kitchen")) == 3)
        withExtendedLifetime(gate) {}
    }

    @Test("a failed start whose cleanup leave is refused retries it and leaves the gate stopped, not joined")
    func failedStartWithRefusedCleanupLeave() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        await service.setAutoLeaveEvents(false)
        await service.setHoldJoins(true)
        await service.setJoinCommandFailures(1)  // the replacement join throws once released
        let restarting = Task { try await gate.start(channelName: "Kitchen") }
        try #require(await eventually { await service.pendingJoins == 1 })
        try await emitAndAwaitHandled(.leaveFailed(channel), on: service, gate: gate)  // old membership survived
        await service.setLeaveFailures(1)  // the cleanup leave cannot be issued the first time
        await service.setHoldJoins(false)
        await service.releaseJoins()
        await #expect(throws: FakePushToTalkChannel.Rejected.self) { try await restarting.value }
        #expect(await eventually { await service.count(.leave(channel)) == 3 })  // refused, then retried
        #expect(await gate.isJoinedToSystemChannel == false)
        try await emitAndAwaitHandled(.beginTransmittingRequested(channel), on: service, gate: gate)
        #expect(await inner.recorded == ["release"])  // a stopped gate never presses the coordinator
        withExtendedLifetime(gate) {}
    }

    @Test("a startup join whose command throws after a late user leave leaves the counters settled")
    func throwingStartupJoinKeepsCountersSettled() async throws {
        let harness = try await makeGate()
        let (gate, service, _) = (harness.gate, harness.service, harness.inner)
        await service.setAutoJoinEvents(false)
        await service.setHoldJoins(true)
        await service.setJoinCommandFailures(1)
        let restarting = Task { try await gate.start(channelName: "Kitchen") }
        try #require(await eventually { await service.pendingJoins == 1 })
        try await emitAndAwaitHandled(.left(channel, reason: .userRequest), on: service, gate: gate)  // old one, late
        await service.setHoldJoins(false)
        await service.releaseJoins()  // the join's command now throws: it was never sent
        await #expect(throws: FakePushToTalkChannel.Rejected.self) { try await restarting.value }
        #expect(await gate.joinsOutstanding == 0)
        #expect(await gate.staleJoins == 0)
        #expect(await gate.terminalLeave == false)
        await gate.stopAndAwaitLeave()  // returns at once: nothing is in flight
        withExtendedLifetime(gate) {}
    }

    @Test("an unsolicited .developerRequest leave is not final: the next system drop rejoins")
    func unsolicitedDeveloperLeaveIsRecoverable() async throws {
        let harness = try await makeGate()
        let (gate, service, _) = (harness.gate, harness.service, harness.inner)
        try await emitAndAwaitHandled(.left(channel, reason: .developerRequest), on: service, gate: gate)  // not ours
        try await emitAndAwaitHandled(.joined(ChannelID("other")), on: service, gate: gate)  // drain
        #expect(await service.count(.join(channel, "Kitchen")) == 1)  // no immediate rejoin
        #expect(await gate.terminalLeave == false)
        try await emitAndAwaitHandled(.left(channel, reason: .unknown), on: service, gate: gate)  // system drop
        #expect(await eventually { await service.count(.join(channel, "Kitchen")) == 2 })  // recovered
        withExtendedLifetime(gate) {}
    }

    @Test("a terminal leave still releasing the coordinator when a restart runs does not latch onto the new session")
    func terminalLeaveStraddlingRestartDoesNotVetoIt() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        try await emitAndAwaitHandled(.beginTransmittingRequested(channel), on: service, gate: gate)  // transmitting
        await inner.setHoldReleases(true)
        service.emit(.left(channel, reason: .userRequest))  // the handler parks in inner.release()
        try #require(await eventually { await inner.pendingReleases == 1 })
        let restarting = Task { try await gate.start(channelName: "Kitchen") }  // endSession parks there too
        try #require(await eventually { await inner.pendingReleases == 2 })
        await inner.setHoldReleases(false)
        await inner.releaseAll()
        try await restarting.value
        try #require(await eventually { await gate.isJoinedToSystemChannel })
        try await emitAndAwaitHandled(.joined(ChannelID("other")), on: service, gate: gate)  // drain the old handler
        #expect(await gate.terminalLeave == false)
        try await emitAndAwaitHandled(.left(channel, reason: .unknown), on: service, gate: gate)  // still rejoins
        #expect(await eventually { await service.count(.join(channel, "Kitchen")) == 3 })
        withExtendedLifetime(gate) {}
    }
}
