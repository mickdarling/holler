import Testing
import HollerCore
import HollerCoreTestSupport
@testable import HollerPTT

@Suite("PushToTalkGatedControl lifecycle overlap")
struct PushToTalkGatedControlLifecycleTests {
    let channel = kitchen

    @Test("a stop issued during a suspended start runs after it: joined, then left, nothing forwarded")
    func stopDuringStart() async throws {
        let service = FakePushToTalkChannel()
        let inner = FakeTalkControl()
        let gate = PushToTalkGatedControl(inner: inner, service: service, channel: channel)
        await service.setHoldJoins(true)
        let starting = Task { try await gate.start(channelName: "Kitchen") }
        await eventually { await service.pendingJoins == 1 }
        let stopping = Task { await gate.stop() }
        await Task.yield()
        await service.releaseJoins()
        try await starting.value
        await stopping.value
        let calls = await service.calls
        #expect(calls == [.prepare, .join(channel, "Kitchen"), .leave(channel)])
        var innerCalls = inner.calls.subscribe().makeAsyncIterator()
        service.emit(.beginTransmittingRequested(channel))
        inner.calls.send("marker")  // stopped: the begin callback is not forwarded
        #expect(await innerCalls.next() == "marker")
        await gate.press()  // stopped: button commands do not reach the service either
        #expect(await service.count(.begin(channel)) == 0)
        withExtendedLifetime(gate) {}
    }

    @Test("system callbacks that arrive while startup is still pending are not forwarded")
    func callbacksDuringStartupIgnored() async throws {
        let service = FakePushToTalkChannel()
        let inner = FakeTalkControl()
        let gate = PushToTalkGatedControl(inner: inner, service: service, channel: channel)
        await service.setHoldJoins(true)
        let starting = Task { try await gate.start(channelName: "Kitchen") }
        await eventually { await service.pendingJoins == 1 }
        var innerCalls = inner.calls.subscribe().makeAsyncIterator()
        service.emit(.beginTransmittingRequested(channel))  // delayed callback from a previous session
        inner.calls.send("marker")
        #expect(await innerCalls.next() == "marker")  // not forwarded: the gate is not running yet
        await service.releaseJoins()
        try await starting.value
        service.emit(.endTransmittingRequested(channel))
        #expect(await innerCalls.next() == "release")  // different event: the buffered begin was not replayed
        withExtendedLifetime(gate) {}
    }

    @Test("a stop issued during a suspended rejoin runs after it and leaves exactly once")
    func stopDuringRejoin() async throws {
        let harness = try await makeGate()
        let (gate, service, _) = (harness.gate, harness.service, harness.inner)
        await service.setHoldJoins(true)
        service.emit(.left(channel, reason: .unknown))
        await eventually { await service.pendingJoins == 1 }
        let stopping = Task { await gate.stop() }
        await Task.yield()
        #expect(await service.count(.leave(channel)) == 0)  // the stop is queued behind the rejoin
        await service.releaseJoins()
        await stopping.value
        let calls = await service.calls
        #expect(calls.suffix(2) == [.join(channel, "Kitchen"), .leave(channel)])
        #expect(await service.count(.leave(channel)) == 1)
        service.emit(.beginTransmittingRequested(channel))  // after stop nothing is forwarded
        await Task.yield()
        #expect(await service.count(.begin(channel)) == 0)
        withExtendedLifetime(gate) {}
    }

    @Test("a rejoin suspended across stop then start does not leave the new session's channel")
    func rejoinAcrossRestart() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        await service.setHoldJoins(true)
        service.emit(.left(channel, reason: .unknown))
        await eventually { await service.pendingJoins == 1 }  // rejoin holds the lifecycle lock, suspended in join
        let stopping = Task { await gate.stop() }
        let starting = Task { try await gate.start(channelName: "Kitchen") }
        await Task.yield()
        await service.releaseJoins()  // rejoin completes → stop runs (leave) → start runs (prepare + held join)
        await eventually { await service.pendingJoins == 1 }
        await service.releaseJoins()
        await stopping.value
        try await starting.value
        let calls = await service.calls
        #expect(calls.suffix(4) == [.join(channel, "Kitchen"), .leave(channel), .prepare, .join(channel, "Kitchen")])
        var innerCalls = inner.calls.subscribe().makeAsyncIterator()
        service.emit(.beginTransmittingRequested(channel))
        #expect(await innerCalls.next() == "press")  // the new session is live and joined
        withExtendedLifetime(gate) {}
    }

    @Test("a failed start leaves the gate stopped: late system callbacks are ignored until a start succeeds")
    func failedStartIsStopped() async throws {
        let service = FakePushToTalkChannel()
        let inner = FakeTalkControl()
        let gate = PushToTalkGatedControl(inner: inner, service: service, channel: channel)
        try await gate.start(channelName: "Kitchen")
        await gate.stop()
        await service.setPrepareFailures(1)
        await #expect(throws: FakePushToTalkChannel.Rejected.self) { try await gate.start(channelName: "Kitchen") }
        var innerCalls = inner.calls.subscribe().makeAsyncIterator()
        service.emit(.beginTransmittingRequested(channel))
        inner.calls.send("marker")
        #expect(await innerCalls.next() == "marker")  // the begin callback was not forwarded
        try await gate.start(channelName: "Kitchen")
        service.emit(.beginTransmittingRequested(channel))
        #expect(await innerCalls.next() == "press")
        withExtendedLifetime(gate) {}
    }

    @Test("a start issued while stop is suspended in release() waits for it and owns a fresh session")
    func startAfterSuspendedStop() async throws {
        let service = FakePushToTalkChannel()
        let inner = HoldingTalkControl()
        let gate = PushToTalkGatedControl(inner: inner, service: service, channel: channel)
        try await gate.start(channelName: "Kitchen")
        await inner.setHoldReleases(true)
        let stopping = Task { await gate.stop() }
        await eventually { await inner.pendingReleases == 1 }
        let starting = Task { try await gate.start(channelName: "Kitchen") }
        await Task.yield()
        #expect(await service.count(.prepare) == 1)  // the new start is queued behind the stop
        await inner.releaseAll()
        await stopping.value
        try await starting.value
        let calls = await service.calls
        #expect(calls == [.prepare, .join(channel, "Kitchen"), .leave(channel), .prepare, .join(channel, "Kitchen")])
        var baseCalls = inner.base.calls.subscribe().makeAsyncIterator()
        service.emit(.beginTransmittingRequested(channel))
        #expect(await baseCalls.next() == "press")  // the gate is running
        withExtendedLifetime(gate) {}
    }

    @Test("a failed start queued behind a stop leaves the gate stopped and the channel left")
    func failedStartAfterStop() async throws {
        let service = FakePushToTalkChannel()
        let inner = HoldingTalkControl()
        let gate = PushToTalkGatedControl(inner: inner, service: service, channel: channel)
        try await gate.start(channelName: "Kitchen")
        await inner.setHoldReleases(true)
        let stopping = Task { await gate.stop() }
        await eventually { await inner.pendingReleases == 1 }
        await service.setPrepareFailures(1)
        let starting = Task { try await gate.start(channelName: "Kitchen") }
        await Task.yield()
        await inner.releaseAll()
        await stopping.value
        await #expect(throws: FakePushToTalkChannel.Rejected.self) { try await starting.value }
        #expect(await service.count(.leave(channel)) == 1)  // from the stop; nothing joined afterwards
        var baseCalls = inner.base.calls.subscribe().makeAsyncIterator()
        service.emit(.beginTransmittingRequested(channel))
        inner.base.calls.send("marker")
        #expect(await baseCalls.next() == "marker")  // the gate is stopped
        withExtendedLifetime(gate) {}
    }
}
