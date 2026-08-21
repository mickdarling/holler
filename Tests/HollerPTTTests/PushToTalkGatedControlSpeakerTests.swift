import Testing
import HollerCore
import HollerCoreTestSupport
@testable import HollerPTT

@Suite("PushToTalkGatedControl speaker mirroring")
struct PushToTalkGatedControlSpeakerTests {
    let channel = kitchen

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

    @Test("a roster that arrives after .receiving re-mirrors the speaker by display name")
    func rosterAfterReceiving() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        inner.states.send(.receiving(from: becca.id))
        await eventually { await service.count(.speaker("b", channel)) == 1 }
        inner.roster.send([becca])
        await eventually { await service.count(.speaker("Becca", channel)) == 1 }
        inner.roster.send([becca, Participant(id: ParticipantID("c"), displayName: "Cass")])  // same name: no call
        await eventually { await gate.currentRoster.count == 2 }
        #expect(await service.count(.speaker("Becca", channel)) == 1)
        withExtendedLifetime(gate) {}
    }

    @Test("a rejected setActiveSpeaker is retried on the next emission")
    func speakerMirrorRetries() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        await service.setSpeakerFailures(1)
        inner.states.send(.receiving(from: becca.id))
        await eventually { await service.count(.speaker("b", channel)) == 1 }
        inner.roster.send([])  // any later emission retries because the rejected name was not cached
        await eventually { await service.count(.speaker("b", channel)) == 2 }
        inner.roster.send([becca])
        await eventually { await service.count(.speaker("Becca", channel)) == 1 }
        withExtendedLifetime(gate) {}
    }

    @Test("overlapping speaker updates are serialized: the newest resolved name wins")
    func speakerUpdatesSerialized() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        await service.setHoldSpeakerCalls(true)
        inner.states.send(.receiving(from: becca.id))
        await eventually { await service.pendingSpeakerCalls == 1 }  // "b" is in flight
        inner.roster.send([becca])
        await eventually { await gate.currentRoster == [becca] }
        #expect(await service.count(.speaker("Becca", channel)) == 0)  // coalesced behind the in-flight call
        await service.releaseSpeakerCalls()
        await eventually { await service.pendingSpeakerCalls == 1 }  // the re-evaluation sends "Becca"
        await service.releaseSpeakerCalls()
        await eventually { await service.count(.speaker("Becca", channel)) == 1 }
        let speakers = await service.calls.filter { if case .speaker = $0 { true } else { false } }
        #expect(speakers == [.speaker("b", channel), .speaker("Becca", channel)])
        withExtendedLifetime(gate) {}
    }

    @Test("coordinator changes while stopped are mirrored on restart")
    func restartMirrorsCurrentSpeaker() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        inner.roster.send([becca])
        await eventually { await gate.currentRoster == [becca] }
        await gate.stop()
        inner.states.send(.receiving(from: becca.id))  // happens while the gate is stopped
        try await gate.start(channelName: "Kitchen")
        await eventually { await service.count(.speaker("Becca", channel)) == 1 }
        let speakers = await service.calls.filter { if case .speaker = $0 { true } else { false } }
        #expect(speakers == [.speaker("Becca", channel)])  // nothing was sent while stopped
        withExtendedLifetime(gate) {}
    }

    @Test("a speaker result that returns after the channel was left is discarded")
    func speakerResultAfterLeaveDiscarded() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        await service.setHoldSpeakerCalls(true)
        inner.states.send(.receiving(from: becca.id))
        await eventually { await service.pendingSpeakerCalls == 1 }  // "b" in flight
        service.emit(.left(channel, reason: .unknown))
        await eventually { await service.count(.join(channel, "Kitchen")) == 2 }  // rejoined
        service.emit(.joined(channel))  // refresh requested while the stale call is still in flight
        await eventually { await gate.currentRoster.isEmpty }  // (let the joined event be processed)
        await service.releaseSpeakerCalls()  // the pre-leave result returns now and must not be cached
        await eventually { await service.pendingSpeakerCalls == 1 }  // the queued refresh drains and re-sends "b"
        await service.releaseSpeakerCalls()
        await eventually { await service.count(.speaker("b", channel)) == 2 }
        withExtendedLifetime(gate) {}
    }

    @Test("a rejoined channel is told the current speaker again")
    func rejoinRefreshesSpeaker() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        inner.roster.send([becca])
        await eventually { await gate.currentRoster == [becca] }
        inner.states.send(.receiving(from: becca.id))
        await eventually { await service.count(.speaker("Becca", channel)) == 1 }
        service.emit(.left(channel, reason: .unknown))
        service.emit(.joined(channel))
        await eventually { await service.count(.speaker("Becca", channel)) == 2 }
        #expect(await service.count(.join(channel, "Kitchen")) == 2)
        withExtendedLifetime(gate) {}
    }
}
