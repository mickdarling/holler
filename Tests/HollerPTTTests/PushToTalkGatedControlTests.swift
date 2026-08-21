import Testing
import HollerCore
import HollerCoreTestSupport
@testable import HollerPTT

@Suite("PushToTalkGatedControl")
struct PushToTalkGatedControlTests {
    let channel = ChannelID("kitchen")
    let becca = Participant(id: ParticipantID("b"), displayName: "Becca")

    /// Keep the harness (and so the gate) alive for the whole test: the gate's pumps hold it weakly.
    struct Harness {
        let gate: PushToTalkGatedControl
        let service: FakePushToTalkChannel
        let inner: FakeTalkControl
    }

    func makeGate() async throws -> Harness {
        let service = FakePushToTalkChannel()
        let inner = FakeTalkControl()
        let gate = PushToTalkGatedControl(inner: inner, service: service, channel: channel)
        try await gate.start(channelName: "Kitchen")
        return Harness(gate: gate, service: service, inner: inner)
    }

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

    @Test("remote speaker is mirrored into the system UI by display name and cleared on idle")
    func mirrorsActiveSpeaker() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        inner.roster.send([becca])
        await eventually { await gate.currentRoster == [becca] }
        inner.states.send(.receiving(from: becca.id))
        await eventually { await service.count(.speaker("Becca", channel)) == 1 }
        inner.states.send(.idle)
        await eventually { await service.count(.speaker(nil, channel)) == 1 }
        inner.states.send(.requesting)  // no remote speaker change → no redundant system call
        inner.states.send(.receiving(from: ParticipantID("stranger")))
        await eventually { await service.count(.speaker("stranger", channel)) == 1 }
        #expect(await service.count(.speaker(nil, channel)) == 1)
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

func eventually(attempts: Int = 500, _ condition: () async -> Bool) async {
    for _ in 0..<attempts where !(await condition()) {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(2))
    }
}
