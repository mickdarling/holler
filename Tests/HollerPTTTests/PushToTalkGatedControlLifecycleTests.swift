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
        withExtendedLifetime(gate) {}
    }

    @Test("stop leaves the channel and undoes a rejoin that was in flight")
    func stopDuringRejoin() async throws {
        let harness = try await makeGate()
        let (gate, service) = (harness.gate, harness.service)
        await service.setHoldJoins(true)
        service.emit(.left(channel, reason: .unknown))
        await eventually { await service.pendingJoins == 1 }
        await gate.stop()
        #expect(await service.count(.leave(channel)) == 1)
        await service.releaseJoins()
        await eventually { await service.count(.leave(channel)) == 2 }
        let calls = await service.calls
        #expect(calls.suffix(3) == [.join(channel, "Kitchen"), .leave(channel), .leave(channel)])
        service.emit(.beginTransmittingRequested(channel))  // after stop nothing is forwarded
        await Task.yield()
        #expect(await service.count(.begin(channel)) == 0)
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
