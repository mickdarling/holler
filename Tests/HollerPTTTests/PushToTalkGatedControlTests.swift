import Testing
import HollerCore
import HollerCoreTestSupport
@testable import HollerPTT

@Suite("PushToTalkGatedControl")
struct PushToTalkGatedControlTests {
    let channel = kitchen

    @Test("start prepares and joins; press/release go to the system service, not the coordinator")
    func startAndPresses() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        var innerCalls = inner.calls.subscribe().makeAsyncIterator()
        await gate.press()
        await gate.release()
        let calls = await service.calls
        #expect(calls == [.prepare, .join(channel, "Kitchen"), .begin(channel), .stop(channel)])
        service.emit(.beginTransmittingRequested(channel))
        #expect(await innerCalls.next() == "press")  // the coordinator only hears about it after the system did
        withExtendedLifetime(gate) {}
    }

    @Test("system transmit callbacks drive the coordinator")
    func systemCallbacksReachInner() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        var innerCalls = inner.calls.subscribe().makeAsyncIterator()
        service.emit(.beginTransmittingRequested(channel))
        #expect(await innerCalls.next() == "press")
        service.emit(.endTransmittingRequested(channel))
        #expect(await innerCalls.next() == "release")
        withExtendedLifetime(gate) {}
    }

    @Test("rejoins after the system drops the channel, not after the user leaves")
    func rejoinPolicy() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        var innerCalls = inner.calls.subscribe().makeAsyncIterator()
        service.emit(.left(channel, reason: .unknown))
        service.emit(.left(ChannelID("other"), reason: .unknown))
        service.emit(.left(channel, reason: .userRequest))
        service.emit(.left(channel, reason: .developerRequest))
        service.emit(.left(channel, reason: .systemPolicy))
        service.emit(.beginTransmittingRequested(channel))  // marker: all earlier events were processed once seen
        #expect(await innerCalls.next() == "press")
        #expect(await service.count(.join(channel, "Kitchen")) == 2)
        withExtendedLifetime(gate) {}
    }

    @Test("stop releases the coordinator, leaves, and the gate can be started again")
    func stopReleasesAndRestarts() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        var innerCalls = inner.calls.subscribe().makeAsyncIterator()
        await gate.stop()
        #expect(await innerCalls.next() == "release")  // an in-progress transmission must not outlive the gate
        #expect(await service.calls.last == .leave(channel))
        try await gate.start(channelName: "Kitchen")
        service.emit(.beginTransmittingRequested(channel))
        #expect(await innerCalls.next() == "press")  // system events still reach the coordinator after a restart
        #expect(await service.count(.prepare) == 2)
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
}
