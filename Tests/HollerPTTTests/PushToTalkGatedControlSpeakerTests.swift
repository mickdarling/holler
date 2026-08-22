import Testing
import HollerCore
import HollerCoreTestSupport
@testable import HollerPTT

@Suite("PushToTalkGatedControl speaker mirroring", .timeLimit(.minutes(1)))
struct PushToTalkGatedControlSpeakerTests {
    let channel = kitchen

    @Test("remote speaker is mirrored by display name, cleared on idle, no redundant calls")
    func mirrorsActiveSpeaker() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        inner.sendRoster([becca])
        #expect(await eventually { await gate.currentRoster == [becca] })
        try await sendStateAndAwait(.receiving(from: becca.id), on: inner, gate: gate)
        #expect(await eventually { await service.count(.speaker("Becca", channel)) == 1 })
        try await sendStateAndAwait(.idle, on: inner, gate: gate)
        #expect(await eventually { await service.count(.speaker(nil, channel)) == 1 })
        try await sendStateAndAwait(.requesting, on: inner, gate: gate)  // no remote speaker change → no call
        try await sendStateAndAwait(.receiving(from: ParticipantID("stranger")), on: inner, gate: gate)
        #expect(await eventually { await service.count(.speaker("stranger", channel)) == 1 })
        let expected: [FakePushToTalkChannel.Call] = [
            .speaker("Becca", channel), .speaker(nil, channel), .speaker("stranger", channel)
        ]
        #expect(await service.speakerCalls == expected)
        withExtendedLifetime(gate) {}
    }

    @Test("a roster that arrives after .receiving re-mirrors by display name")
    func rosterAfterReceiving() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        inner.sendState(.receiving(from: becca.id))
        #expect(await eventually { await service.count(.speaker("b", channel)) == 1 })
        inner.sendRoster([becca])
        #expect(await eventually { await service.count(.speaker("Becca", channel)) == 1 })
        inner.sendRoster([becca, Participant(id: ParticipantID("c"), displayName: "Cass")])  // same name: no call
        #expect(await eventually { await gate.currentRoster.count == 2 })
        #expect(await service.speakerCalls == [.speaker("b", channel), .speaker("Becca", channel)])
        withExtendedLifetime(gate) {}
    }

    @Test("a rejected setActiveSpeaker is retried on the next emission")
    func speakerMirrorRetries() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        await service.setSpeakerFailures(1)
        inner.sendState(.receiving(from: becca.id))
        #expect(await eventually { await service.count(.speaker("b", channel)) == 1 })
        inner.sendRoster([])  // any later emission retries because the rejected name was not cached
        #expect(await eventually { await service.count(.speaker("b", channel)) == 2 })
        withExtendedLifetime(gate) {}
    }

    @Test("overlapping speaker updates are serialized: the newest resolved name wins, in order")
    func speakerUpdatesSerialized() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        await service.setHoldSpeakerCalls(true)
        inner.sendState(.receiving(from: becca.id))
        try #require(await eventually { await service.pendingSpeakerCalls == 1 })  // "b" in flight
        inner.sendRoster([becca])
        #expect(await eventually { await gate.currentRoster == [becca] })
        #expect(await service.count(.speaker("Becca", channel)) == 0)  // queued behind the in-flight call
        await service.releaseSpeakerCalls()
        try #require(await eventually { await service.pendingSpeakerCalls == 1 })  // the re-evaluation sends "Becca"
        await service.releaseSpeakerCalls()
        #expect(await eventually { await service.count(.speaker("Becca", channel)) == 1 })
        #expect(await service.speakerCalls == [.speaker("b", channel), .speaker("Becca", channel)])
        withExtendedLifetime(gate) {}
    }

    @Test("mirroring is deferred while the system transmits for us and resumes when it ends")
    func deferredDuringSystemTransmission() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        try await emitAndAwaitHandled(.beginTransmittingRequested(channel), on: service, gate: gate)
        inner.sendRoster([becca])
        try #require(await eventually { await gate.currentRoster == [becca] })
        let refreshes = await gate.refreshCount
        try await sendStateAndAwait(.receiving(from: becca.id), on: inner, gate: gate)  // receiving while system transmits
        #expect(await eventually { await service.count(.stop(channel)) == 1 })  // the gate stops the transmission…
        try #require(await eventually { await gate.refreshCount > refreshes })  // the worker ran for that state…
        #expect(await service.speakerCalls.isEmpty)  // …and did not mirror
        try await emitAndAwaitHandled(.endTransmittingRequested(channel), on: service, gate: gate)
        #expect(await eventually { await service.count(.speaker("Becca", channel)) == 1 })
        withExtendedLifetime(gate) {}
    }

    @Test("a push-delivered speaker (incomingSpeaker) syncs the cache so the next change is mirrored")
    func incomingSpeakerSyncsCache() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        inner.sendRoster([becca])
        inner.sendState(.receiving(from: becca.id))
        #expect(await eventually { await service.count(.speaker("Becca", channel)) == 1 })
        let push = PushToTalkEvent.incomingSpeaker(channel, speaker: ParticipantID("c"), displayName: "Cass")
        try await emitAndAwaitHandled(push, on: service, gate: gate)
        #expect(await eventually { await service.count(.speaker("Becca", channel)) == 2 })  // system showed Cass
        withExtendedLifetime(gate) {}
    }

    @Test("a push-delivered speaker arriving during an in-flight mirror call is not overwritten by its result")
    func incomingSpeakerDuringInFlightMirror() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        await service.setHoldSpeakerCalls(true)
        inner.sendRoster([becca])
        try #require(await eventually { await gate.currentRoster == [becca] })  // roster before state: name is "Becca"
        try await sendStateAndAwait(.receiving(from: becca.id), on: inner, gate: gate)
        try #require(await eventually { await service.pendingSpeakerCalls == 1 })  // "Becca" in flight
        let push = PushToTalkEvent.incomingSpeaker(channel, speaker: ParticipantID("c"), displayName: "Cass")
        try await emitAndAwaitHandled(push, on: service, gate: gate)  // the system now shows Cass
        await service.setHoldSpeakerCalls(false)
        await service.releaseSpeakerCalls()  // the "Becca" result returns: must not be cached over "Cass"
        #expect(await eventually { await service.count(.speaker("Becca", channel)) == 2 })  // re-asserted
        withExtendedLifetime(gate) {}
    }

    @Test("a push-delivered speaker stays shown while the coordinator is still idle, until it reports a state")
    func pushedSpeakerRetainedWhileIdle() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        let refreshes = await gate.refreshCount
        let push = PushToTalkEvent.incomingSpeaker(channel, speaker: ParticipantID("c"), displayName: "Cass")
        try await emitAndAwaitHandled(push, on: service, gate: gate)
        try #require(await eventually { await gate.refreshCount > refreshes })
        #expect(await service.speakerCalls.isEmpty)  // no setActiveSpeaker(nil): the pushed name is kept
        inner.sendRoster([becca])
        try await sendStateAndAwait(.receiving(from: becca.id), on: inner, gate: gate)  // coordinator catches up
        #expect(await eventually { await service.count(.speaker("Becca", channel)) == 1 })
        withExtendedLifetime(gate) {}
    }
}
