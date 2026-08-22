import Testing
import HollerCore
import HollerCoreTestSupport
@testable import HollerPTT

@Suite("PushToTalkGatedControl sessions (stop, restart, rejoin; speaker cache across them)",
       .timeLimit(.minutes(1)))
struct PushToTalkGatedControlSessionTests {
    let channel = kitchen

    @Test("stop releases the coordinator, leaves, and the gate can be started again")
    func stopReleasesAndRestarts() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        await gate.stop()
        #expect(await inner.recorded == ["release"])  // an in-progress transmission must not outlive the gate
        #expect(await service.calls.last == .leave(channel))
        try await gate.start(channelName: "Kitchen")
        try #require(await eventually { await gate.isJoinedToSystemChannel })
        try await emitAndAwaitHandled(.beginTransmittingRequested(channel), on: service, gate: gate)
        #expect(await inner.recorded == ["release", "press"])
        withExtendedLifetime(gate) {}
    }

    @Test("a transmit callback buffered before a stop is not forwarded after the restart")
    func staleBufferedCallbackNotReplayed() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        await inner.setHoldReleases(true)
        service.emit(.endTransmittingRequested(channel))  // pump parks in inner.release()
        try #require(await eventually { await inner.pendingReleases == 1 })
        service.emit(.beginTransmittingRequested(channel))  // stale: buffered behind the parked pump
        let stopping = Task { await gate.stop() }
        try #require(await eventually { await inner.pendingReleases == 2 })  // stop() is now suspended in release() too
        await inner.releaseAll()
        await stopping.value
        try await gate.start(channelName: "Kitchen")
        try #require(await eventually { await gate.isJoinedToSystemChannel })
        // drain past the stale begin
        try await emitAndAwaitHandled(.joined(ChannelID("other")), on: service, gate: gate)
        #expect(await inner.recorded.filter { $0 == "press" }.isEmpty)  // the stale begin was dropped
        withExtendedLifetime(gate) {}
    }

    @Test("start on a running gate restarts: release, leave, prepare, join")
    func restartOnRunningGate() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        try await gate.start(channelName: "Kitchen")
        let expected: [FakePushToTalkChannel.Call] = [
            .prepare, .join(channel, "Kitchen"), .leave(channel), .prepare, .join(channel, "Kitchen")
        ]
        #expect(await service.calls == expected)
        #expect(await inner.recorded == ["release"])
        try #require(await eventually { await gate.isJoinedToSystemChannel })
        withExtendedLifetime(gate) {}
    }

    @Test("a failed start leaves the gate stopped until a later start succeeds")
    func failedStartIsStopped() async throws {
        let service = FakePushToTalkChannel()
        let inner = RecordingTalkControl()
        let gate = PushToTalkGatedControl(inner: inner, service: service, channel: channel)
        await service.setPrepareFailures(1)
        await #expect(throws: FakePushToTalkChannel.Rejected.self) { try await gate.start(channelName: "Kitchen") }
        try await emitAndAwaitHandled(.beginTransmittingRequested(channel), on: service, gate: gate)
        #expect(await inner.recorded.isEmpty)
        try await gate.start(channelName: "Kitchen")
        try #require(await eventually { await gate.isJoinedToSystemChannel })
        try await emitAndAwaitHandled(.beginTransmittingRequested(channel), on: service, gate: gate)
        #expect(await inner.recorded == ["press"])
        withExtendedLifetime(gate) {}
    }

    @Test("coordinator changes while stopped are mirrored on restart; nothing is sent while stopped")
    func restartMirrorsCurrentSpeaker() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        inner.sendRoster([becca])
        #expect(await eventually { await gate.currentRoster == [becca] })
        await gate.stop()
        inner.sendState(.receiving(from: becca.id))  // happens while the gate is stopped
        try await gate.start(channelName: "Kitchen")
        #expect(await eventually { await service.count(.speaker("Becca", channel)) == 1 })
        #expect(await service.speakerCalls == [.speaker("Becca", channel)])
        withExtendedLifetime(gate) {}
    }

    @Test("a speaker result that returns after the channel was left is discarded; the rejoin re-sends it")
    func speakerResultAfterLeaveDiscarded() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        await service.setHoldSpeakerCalls(true)
        inner.sendState(.receiving(from: becca.id))
        try #require(await eventually { await service.pendingSpeakerCalls == 1 })  // "b" in flight
        // rejoin → .joined queued
        try await emitAndAwaitHandled(.left(channel, reason: .unknown), on: service, gate: gate)
        await service.releaseSpeakerCalls()  // the pre-leave result returns now and must not be cached
        try #require(await eventually { await service.pendingSpeakerCalls == 1 })  // the joined refresh re-sends "b"
        await service.releaseSpeakerCalls()
        #expect(await eventually { await service.count(.speaker("b", channel)) == 2 })
        withExtendedLifetime(gate) {}
    }

    @Test("a speaker result that returns after stop() is not cached: the restart re-sends it")
    func stopDuringSpeakerCall() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        await service.setHoldSpeakerCalls(true)
        inner.sendState(.receiving(from: becca.id))
        try #require(await eventually { await service.pendingSpeakerCalls == 1 })
        await gate.stop()
        await service.releaseSpeakerCalls()  // returns after stop invalidated the cache
        try await gate.start(channelName: "Kitchen")
        try #require(await eventually { await service.pendingSpeakerCalls == 1 })  // the restart re-mirrors "b"
        await service.releaseSpeakerCalls()
        #expect(await eventually { await service.count(.speaker("b", channel)) == 2 })
        withExtendedLifetime(gate) {}
    }

    @Test("three lifecycle callers are served strictly in order")
    func lifecycleIsFIFO() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        await inner.setHoldReleases(true)
        let first = Task { await gate.stop() }
        try #require(await eventually { await inner.pendingReleases == 1 })
        let second = Task { try await gate.start(channelName: "Kitchen") }
        try #require(await eventually { await gate.pendingLifecycleWaiters == 1 })
        let third = Task { await gate.stop() }
        try #require(await eventually { await gate.pendingLifecycleWaiters == 2 })
        await inner.releaseAll()
        await first.value
        try await second.value
        try #require(await eventually { await inner.pendingReleases == 1 })  // third (stop) is now running
        await inner.releaseAll()
        await third.value
        let expected: [FakePushToTalkChannel.Call] = [
            .prepare, .join(channel, "Kitchen"), .leave(channel), .prepare, .join(channel, "Kitchen"), .leave(channel)
        ]
        #expect(await service.calls == expected)
        withExtendedLifetime(gate) {}
    }
}
