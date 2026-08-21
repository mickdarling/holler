import Testing
import HollerCore
import HollerCoreTestSupport
@testable import HollerPTT

@Suite("PushToTalkGatedControl lifecycle overlap")
struct PushToTalkGatedControlLifecycleTests {
    let channel = kitchen

    @Test("stop during a suspended start wins: the join is undone and nothing is forwarded")
    func stopDuringStart() async throws {
        let service = FakePushToTalkChannel()
        let inner = FakeTalkControl()
        let gate = PushToTalkGatedControl(inner: inner, service: service, channel: channel)
        await service.setHoldJoins(true)
        let starting = Task { try await gate.start(channelName: "Kitchen") }
        await eventually { await service.pendingJoins == 1 }
        await gate.stop()
        await service.releaseJoins()
        try await starting.value
        let calls = await service.calls
        #expect(calls == [.prepare, .join(channel, "Kitchen"), .leave(channel), .leave(channel)])
        var innerCalls = inner.calls.subscribe().makeAsyncIterator()
        service.emit(.beginTransmittingRequested(channel))
        inner.calls.send("marker")  // pumps were never started, so the marker is the first thing we see
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

    @Test("a stop suspended in release() does not leave the channel a newer start joined")
    func staleStopDoesNotLeaveNewSession() async throws {
        let service = FakePushToTalkChannel()
        let inner = HoldingTalkControl()
        let gate = PushToTalkGatedControl(inner: inner, service: service, channel: channel)
        try await gate.start(channelName: "Kitchen")
        await inner.setHoldReleases(true)
        let stopping = Task { await gate.stop() }
        await eventually { await inner.pendingReleases == 1 }
        try await gate.start(channelName: "Kitchen")  // newer lifecycle: prepare + join again
        await inner.releaseAll()
        await stopping.value
        let calls = await service.calls
        #expect(calls == [.prepare, .join(channel, "Kitchen"), .prepare, .join(channel, "Kitchen")])  // no leave
        var baseCalls = inner.base.calls.subscribe().makeAsyncIterator()
        service.emit(.beginTransmittingRequested(channel))
        #expect(await baseCalls.next() == "press")  // the gate is running
        withExtendedLifetime(gate) {}
    }

    @Test("a failed replacement start still leaves the channel the superseded stop was about to leave")
    func failedReplacementStartLeaves() async throws {
        let service = FakePushToTalkChannel()
        let inner = HoldingTalkControl()
        let gate = PushToTalkGatedControl(inner: inner, service: service, channel: channel)
        try await gate.start(channelName: "Kitchen")
        await inner.setHoldReleases(true)
        let stopping = Task { await gate.stop() }
        await eventually { await inner.pendingReleases == 1 }
        await service.setPrepareFailures(1)
        await #expect(throws: FakePushToTalkChannel.Rejected.self) { try await gate.start(channelName: "Kitchen") }
        await inner.releaseAll()
        await stopping.value
        #expect(await service.count(.leave(channel)) == 1)  // exactly one leave: from the failed start
        var baseCalls = inner.base.calls.subscribe().makeAsyncIterator()
        service.emit(.beginTransmittingRequested(channel))
        inner.base.calls.send("marker")
        #expect(await baseCalls.next() == "marker")  // the gate is stopped
        withExtendedLifetime(gate) {}
    }
}
