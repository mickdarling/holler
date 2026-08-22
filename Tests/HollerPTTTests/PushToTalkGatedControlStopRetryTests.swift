import Testing
import HollerCore
import HollerCoreTestSupport
@testable import HollerPTT

/// The gate asks the system to stop a transmission the coordinator no longer backs; a refusal is asked again (bounded)
/// and a refusal answering an earlier transmission's stop is ignored.
@Suite(.timeLimit(.minutes(1)))
struct PushToTalkGatedControlStopRetryTests {
    let channel = kitchen

    @Test("a refused system stop is asked again (bounded) when the coordinator is already idle")
    func refusedSystemStopIsRetried() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        try await emitAndAwaitHandled(.beginTransmittingRequested(channel), on: service, gate: gate)  // pressed
        inner.base.notices.send(.denied(heldBy: becca.id))  // the coordinator went idle and then said why
        try #require(await eventually { await service.count(.stop(channel)) == 1 })
        try await emitAndAwaitHandled(.stopTransmitFailed(channel), on: service, gate: gate)  // refused → ask again
        #expect(await eventually { await service.count(.stop(channel)) == 2 })
        try await emitAndAwaitHandled(.stopTransmitFailed(channel), on: service, gate: gate)
        try await emitAndAwaitHandled(.stopTransmitFailed(channel), on: service, gate: gate)
        try await emitAndAwaitHandled(.joined(ChannelID("other")), on: service, gate: gate)  // drain
        #expect(await service.count(.stop(channel)) == 3)  // bounded
        try await emitAndAwaitHandled(.endTransmittingRequested(channel), on: service, gate: gate)
        #expect(await inner.recorded.last == "release")
        withExtendedLifetime(gate) {}
    }

    @Test("a stop refusal answering an earlier transmission's stop does not touch the current transmission")
    func staleStopRefusalIgnored() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        try await emitAndAwaitHandled(.beginTransmittingRequested(channel), on: service, gate: gate)  // #1 pressed
        inner.base.notices.send(.denied(heldBy: becca.id))  // coordinator idle: stop #1 asked
        try #require(await eventually { await service.count(.stop(channel)) == 1 })
        try await emitAndAwaitHandled(.endTransmittingRequested(channel), on: service, gate: gate)  // #1 over
        try await emitAndAwaitHandled(.beginTransmittingRequested(channel), on: service, gate: gate)  // #2 pressed
        try await emitAndAwaitHandled(.stopTransmitFailed(channel), on: service, gate: gate)  // late answer to stop #1
        #expect(await service.count(.stop(channel)) == 1)  // #2 is not stopped…
        #expect(await inner.recorded.last == "press")  // …nor released
        withExtendedLifetime(gate) {}
    }
}
