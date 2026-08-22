import Testing
import HollerCore
import HollerCoreTestSupport
@testable import HollerPTT

@Suite("PushToTalkGatedControl lifecycle overlap", .timeLimit(.minutes(1)))
struct PushToTalkGatedControlLifecycleTests {
    let channel = kitchen

    /// A gate whose start() is suspended inside the fake's held join().
    struct SuspendedStart {
        let gate: PushToTalkGatedControl
        let service: FakePushToTalkChannel
        let inner: RecordingTalkControl
        let starting: Task<Void, any Error>
    }

    func suspendedStart() async throws -> SuspendedStart {
        let service = FakePushToTalkChannel()
        let inner = RecordingTalkControl()
        let gate = PushToTalkGatedControl(inner: inner, service: service, channel: channel)
        await service.setHoldJoins(true)
        let starting = Task { try await gate.start(channelName: "Kitchen") }
        try #require(await eventually { await service.pendingJoins == 1 })
        return SuspendedStart(gate: gate, service: service, inner: inner, starting: starting)
    }

    @Test("callbacks that arrive while startup is pending are dropped, not queued")
    func callbacksDuringStartupIgnored() async throws {
        let sus = try await suspendedStart()
        let (gate, service, inner, starting) = (sus.gate, sus.service, sus.inner, sus.starting)
        try await emitAndAwaitHandled(.beginTransmittingRequested(channel), on: service, gate: gate)  // stale callback
        #expect(await inner.recorded.isEmpty)
        await service.setHoldJoins(false)
        await service.releaseJoins()
        try await starting.value
        try #require(await eventually { await gate.isJoinedToSystemChannel })
        try await emitAndAwaitHandled(.endTransmittingRequested(channel), on: service, gate: gate)
        #expect(await inner.recorded == ["release"])  // a different event: the buffered begin was not replayed
        withExtendedLifetime(gate) {}
    }

    @Test("a .left delivered during startup is honoured: the gate rejoins instead of staying deaf")
    func leftDuringStartupRejoins() async throws {
        let sus = try await suspendedStart()
        let (gate, service, starting) = (sus.gate, sus.service, sus.starting)
        await service.setHoldJoins(false)
        await service.releaseJoins()
        try await starting.value
        try #require(await eventually { await gate.isJoinedToSystemChannel })
        try await emitAndAwaitHandled(.left(channel, reason: .unknown), on: service, gate: gate)
        #expect(await eventually { await service.count(.join(channel, "Kitchen")) == 2 })
        try #require(await eventually { await gate.isJoinedToSystemChannel })
        withExtendedLifetime(gate) {}
    }

    @Test("a stop issued during a suspended start runs after it: joined, then left, nothing forwarded")
    func stopDuringStart() async throws {
        let sus = try await suspendedStart()
        let (gate, service, inner, starting) = (sus.gate, sus.service, sus.inner, sus.starting)
        let stopping = Task { await gate.stop() }
        try #require(await eventually { await gate.pendingLifecycleWaiters == 1 })
        await service.setHoldJoins(false)
        await service.releaseJoins()
        try await starting.value
        await stopping.value
        #expect(await service.calls == [.prepare, .join(channel, "Kitchen"), .leave(channel)])
        try await emitAndAwaitHandled(.beginTransmittingRequested(channel), on: service, gate: gate)
        #expect(await inner.recorded == ["release"])  // stop's release only; the begin was not forwarded
        await gate.press()
        #expect(await service.count(.begin(channel)) == 0)
        withExtendedLifetime(gate) {}
    }

    @Test("a stop issued during a suspended rejoin runs after it and leaves exactly once")
    func stopDuringRejoin() async throws {
        let harness = try await makeGate()
        let (gate, service, _) = (harness.gate, harness.service, harness.inner)
        await service.setHoldJoins(true)
        service.emit(.left(channel, reason: .unknown))
        try #require(await eventually { await service.pendingJoins == 1 })  // rejoin holds the lock, suspended in join
        let stopping = Task { await gate.stop() }
        try #require(await eventually { await gate.pendingLifecycleWaiters == 1 })
        await service.setHoldJoins(false)
        await service.releaseJoins()
        await stopping.value
        #expect(await service.calls.suffix(2) == [.join(channel, "Kitchen"), .leave(channel)])
        #expect(await service.count(.leave(channel)) == 1)
        withExtendedLifetime(gate) {}
    }

    @Test("a rejoin suspended across stop then start does not leave the new session's channel")
    func rejoinAcrossRestart() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        await service.setHoldJoins(true)
        service.emit(.left(channel, reason: .unknown))
        try #require(await eventually { await service.pendingJoins == 1 })
        let stopping = Task { await gate.stop() }
        try #require(await eventually { await gate.pendingLifecycleWaiters == 1 })  // queued in this order…
        let starting = Task { try await gate.start(channelName: "Kitchen") }
        try #require(await eventually { await gate.pendingLifecycleWaiters == 2 })  // …deterministically
        await service.setHoldJoins(false)
        await service.releaseJoins()  // rejoin completes → stop (leave) → start (prepare + join)
        await stopping.value
        try await starting.value
        let expectedTail: [FakePushToTalkChannel.Call] = [
            .join(channel, "Kitchen"), .leave(channel), .prepare, .join(channel, "Kitchen")
        ]
        #expect(await service.calls.suffix(4) == expectedTail)
        try #require(await eventually { await gate.isJoinedToSystemChannel })
        try await emitAndAwaitHandled(.beginTransmittingRequested(channel), on: service, gate: gate)
        #expect(await inner.recorded == ["release", "press"])  // the new session is live and joined
        withExtendedLifetime(gate) {}
    }

    @Test("a start issued while stop is suspended in release() waits for it and owns a fresh session")
    func startAfterSuspendedStop() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        await inner.setHoldReleases(true)
        let stopping = Task { await gate.stop() }
        try #require(await eventually { await inner.pendingReleases == 1 })
        let starting = Task { try await gate.start(channelName: "Kitchen") }
        try #require(await eventually { await gate.pendingLifecycleWaiters == 1 })  // queued behind the stop
        #expect(await service.count(.prepare) == 1)
        await inner.releaseAll()
        await stopping.value
        try await starting.value
        let expected: [FakePushToTalkChannel.Call] = [
            .prepare, .join(channel, "Kitchen"), .leave(channel), .prepare, .join(channel, "Kitchen")
        ]
        #expect(await service.calls == expected)
        try #require(await eventually { await gate.isJoinedToSystemChannel })
        withExtendedLifetime(gate) {}
    }

    @Test("a failed start queued behind a stop leaves the gate stopped and the channel left")
    func failedStartAfterStop() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        await inner.setHoldReleases(true)
        let stopping = Task { await gate.stop() }
        try #require(await eventually { await inner.pendingReleases == 1 })
        await service.setPrepareFailures(1)
        let starting = Task { try await gate.start(channelName: "Kitchen") }
        try #require(await eventually { await gate.pendingLifecycleWaiters == 1 })
        await inner.releaseAll()
        await stopping.value
        await #expect(throws: FakePushToTalkChannel.Rejected.self) { try await starting.value }
        #expect(await service.count(.leave(channel)) == 1)
        #expect(await gate.isJoinedToSystemChannel == false)
        try await emitAndAwaitHandled(.beginTransmittingRequested(channel), on: service, gate: gate)
        #expect(await inner.recorded == ["release"])
        withExtendedLifetime(gate) {}
    }
}
