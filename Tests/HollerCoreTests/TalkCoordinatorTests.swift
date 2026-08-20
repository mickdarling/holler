import Foundation
import Testing
import HollerCoreTestSupport
@testable import HollerCore

@Suite("TalkCoordinator")
struct TalkCoordinatorTests {
    let me = ParticipantID("me")
    let participant = Participant(id: ParticipantID("me"), displayName: "Me")
    let channel = ChannelID("kitchen")
    let other = ParticipantID("other")
    let frame = AudioFrame(sequence: 1, timestampMilliseconds: 1, payload: Data([1, 2]))

    struct Harness {
        let coordinator: TalkCoordinator
        let transport: FakeSignalingTransport
        let capture: FakeAudioCapturing
        let playback: FakeAudioPlaying
    }

    func makeHarness(frames: [AudioFrame] = []) -> Harness {
        let transport = FakeSignalingTransport()
        let capture = FakeAudioCapturing(frames: frames)
        let playback = FakeAudioPlaying()
        let coordinator = TalkCoordinator(
            participant: participant, channel: channel, transport: transport, capture: capture, playback: playback
        )
        return Harness(coordinator: coordinator, transport: transport, capture: capture, playback: playback)
    }

    @Test("press sends a floor request; grant starts capture and streams audio")
    func pressGrantTransmit() async {
        let harness = makeHarness(frames: [frame])
        await harness.coordinator.press()
        #expect(await harness.transport.calls == [.send(.floorRequest(from: me))])
        await harness.coordinator.receive(.floorGranted(to: me))
        #expect(await harness.coordinator.currentState == .transmitting)
        await waitUntil { await harness.transport.calls.contains(.send(.audio(from: me, frame: frame))) }
        #expect(await harness.capture.startCount == 1)
        await harness.coordinator.release()
        #expect(await harness.capture.stopCount == 1)
        #expect(await harness.transport.calls.last == .send(.floorReleased(by: me)))
    }

    @Test("denied publishes a notice and returns to idle")
    func denied() async {
        let harness = makeHarness()
        var notices = harness.coordinator.subscribeNotices().makeAsyncIterator()
        await harness.coordinator.press()
        await harness.coordinator.receive(.floorDenied(to: me, heldBy: other))
        #expect(await notices.next() == .denied(heldBy: other))
        #expect(await harness.coordinator.currentState == .idle)
    }

    @Test("audio from the current speaker is played; audio from others is not")
    func playback() async {
        let harness = makeHarness()
        await harness.coordinator.receive(.floorGranted(to: other))
        #expect(await harness.coordinator.currentState == .receiving(from: other))
        await harness.coordinator.receive(.audio(from: other, frame: frame))
        await harness.coordinator.receive(.audio(from: ParticipantID("stranger"), frame: frame))
        #expect(await harness.playback.played.count == 1)
        await harness.coordinator.receive(.floorReleased(by: other))
        #expect(await harness.coordinator.currentState == .idle)
        #expect(await harness.playback.stopAllCount == 1)
    }

    @Test("roster follows welcome/join/leave and is sorted by name")
    func roster() async {
        let harness = makeHarness()
        let zed = Participant(id: ParticipantID("z"), displayName: "Zed")
        let amy = Participant(id: ParticipantID("a"), displayName: "Amy")
        await harness.coordinator.receive(.welcome(participants: [zed]))
        await harness.coordinator.receive(.participantJoined(participant: amy))
        #expect(await harness.coordinator.currentRoster == [amy, zed])
        await harness.coordinator.receive(.participantLeft(id: zed.id))
        #expect(await harness.coordinator.currentRoster == [amy])
    }

    @Test("ping is answered with pong")
    func ping() async {
        let harness = makeHarness()
        await harness.coordinator.receive(.ping(nonce: 5))
        #expect(await harness.transport.calls == [.send(.pong(nonce: 5))])
    }

    @Test("going online sends hello for this participant and channel")
    func helloOnOnline() async {
        let harness = makeHarness()
        let health = Broadcaster<HealthState>()
        await harness.coordinator.attach(messages: AsyncStream { $0.finish() }, health: health.subscribe())
        health.send(.online)
        let hello = WireMessage.hello(participant: participant, channel: channel)
        await waitUntil { await harness.transport.calls.contains(.send(hello)) }
        #expect(await harness.transport.calls == [.send(hello)])
        await harness.coordinator.detach()
    }

    @Test("a health drop while transmitting stops capture")
    func healthDrop() async {
        let harness = makeHarness()
        let health = Broadcaster<HealthState>()
        await harness.coordinator.attach(messages: AsyncStream { $0.finish() }, health: health.subscribe())
        await harness.coordinator.press()
        await harness.coordinator.receive(.floorGranted(to: me))
        health.send(.retrying(attempt: 1))
        await waitUntil { await harness.coordinator.currentState == .idle }
        #expect(await harness.capture.stopCount == 1)
        await harness.coordinator.detach()
    }
}
