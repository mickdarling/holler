import Testing
import HollerCore
import HollerCoreTestSupport
@testable import HollerPTT

/// A release that arrives before the system confirms the begin must still end the transmission: the coordinator is
/// never pressed for a finger that is already up.
@Suite(.timeLimit(.minutes(1)))
struct PushToTalkGatedControlQuickTapTests {
    let channel = kitchen

    @Test("release before the begin callback, stop command refused: the begin is stopped, the coordinator not pressed")
    func releaseBeforeBeginWithRefusedStopCommand() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        await gate.press()  // begin requested; the system has not answered
        await service.setStopFailures(1)
        await gate.release()  // the stop cannot even be issued
        try await emitAndAwaitHandled(.beginTransmittingRequested(channel), on: service, gate: gate)  // begin lands
        #expect(await inner.recorded.contains("press") == false)  // the coordinator never captures
        #expect(await eventually { await service.count(.stop(channel)) == 2 })  // the system is asked to stop
        try await emitAndAwaitHandled(.endTransmittingRequested(channel), on: service, gate: gate)
        #expect(await gate.isSystemTransmitting == false)
        withExtendedLifetime(gate) {}
    }

    @Test("release before the begin callback, stop refused by the system before the begin: same outcome")
    func releaseBeforeBeginWithStopRefusedBeforeBegin() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        await gate.press()
        await gate.release()  // stop #1 issued
        try await emitAndAwaitHandled(.stopTransmitFailed(channel), on: service, gate: gate)  // refused before begin
        try await emitAndAwaitHandled(.beginTransmittingRequested(channel), on: service, gate: gate)
        #expect(await inner.recorded.contains("press") == false)
        #expect(await eventually { await service.count(.stop(channel)) == 2 })
        withExtendedLifetime(gate) {}
    }

    @Test("a new press before the begin callback supersedes the earlier release: the begin is pressed")
    func pressAgainBeforeBeginSupersedesRelease() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        await gate.press()
        await service.setStopFailures(1)
        await gate.release()  // remembered
        await gate.press()  // pressed again before the system answered
        try await emitAndAwaitHandled(.beginTransmittingRequested(channel), on: service, gate: gate)
        #expect(await inner.recorded.last == "press")  // the coordinator captures for the live press
        #expect(await service.count(.stop(channel)) == 1)  // no stop for the superseded release
        withExtendedLifetime(gate) {}
    }

    @Test("a new press while the begin is unanswered issues no second begin request")
    func pressAgainBeforeBeginIssuesOneBegin() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        await gate.press()
        await gate.release()  // stop issued; the begin is still unanswered
        await gate.press()
        #expect(await service.count(.begin(channel)) == 1)  // the outstanding begin answers this press too
        try await emitAndAwaitHandled(.beginTransmittingRequested(channel), on: service, gate: gate)
        #expect(await inner.recorded.last == "press")
        withExtendedLifetime(gate) {}
    }

    @Test("a failed begin clears a pending release: the next press is ordinary")
    func beginFailedClearsPendingRelease() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        await gate.press()
        await service.setStopFailures(1)
        await gate.release()
        try await emitAndAwaitHandled(.beginTransmitFailed(channel), on: service, gate: gate)  // nothing will start
        await gate.press()
        try await emitAndAwaitHandled(.beginTransmittingRequested(channel), on: service, gate: gate)
        #expect(await inner.recorded.last == "press")
        withExtendedLifetime(gate) {}
    }
}
