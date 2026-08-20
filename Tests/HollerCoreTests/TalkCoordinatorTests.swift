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

    func makeCoordinator(frames: [AudioFrame] = []) -> (TalkCoordinator, FakeSignalingTransport, FakeAudioCapturing, FakeAudioPlaying) {
        let transport = FakeSignalingTransport()
        let capture = FakeAudioCapturing(frames: frames)
        let playback = FakeAudioPlaying()
        let coordinator = TalkCoordinator(participant: participant, channel: channel, transport: transport, capture: capture, playback: playback)
        return (coordinator, transport, capture, playback)
    }

    @Test("press sends a floor request; grant starts capture and streams audio")
    func pressGrantTransmit() async {
        let (coordinator, transport, capture, _) = makeCoordinator(frames: [frame])
        await coordinator.press()
        #expect(await transport.calls == [.send(.floorRequest(from: me))])
        await coordinator.receive(.floorGranted(to: me))
        #expect(await coordinator.currentState == .transmitting)
        await waitUntil { await transport.calls.contains(.send(.audio(from: me, frame: frame))) }
        #expect(await capture.startCount == 1)
        await coordinator.release()
        #expect(await capture.stopCount == 1)
        #expect(await transport.calls.last == .send(.floorReleased(by: me)))
    }

    @Test("denied publishes a notice and returns to idle")
    func denied() async {
        let (coordinator, _, _, _) = makeCoordinator()
        var notices = coordinator.subscribeNotices().makeAsyncIterator()
        await coordinator.press()
        await coordinator.receive(.floorDenied(to: me, heldBy: other))
        #expect(await notices.next() == .denied(heldBy: other))
        #expect(await coordinator.currentState == .idle)
    }

    @Test("audio from the current speaker is played; audio from others is not")
    func playback() async {
        let (coordinator, _, _, playback) = makeCoordinator()
        await coordinator.receive(.floorGranted(to: other))
        #expect(await coordinator.currentState == .receiving(from: other))
        await coordinator.receive(.audio(from: other, frame: frame))
        await coordinator.receive(.audio(from: ParticipantID("stranger"), frame: frame))
        #expect(await playback.played.count == 1)
        await coordinator.receive(.floorReleased(by: other))
        #expect(await coordinator.currentState == .idle)
        #expect(await playback.stopAllCount == 1)
    }

    @Test("roster follows welcome/join/leave and is sorted by name")
    func roster() async {
        let (coordinator, _, _, _) = makeCoordinator()
        let zed = Participant(id: ParticipantID("z"), displayName: "Zed")
        let amy = Participant(id: ParticipantID("a"), displayName: "Amy")
        await coordinator.receive(.welcome(participants: [zed]))
        await coordinator.receive(.participantJoined(participant: amy))
        #expect(await coordinator.currentRoster == [amy, zed])
        await coordinator.receive(.participantLeft(id: zed.id))
        #expect(await coordinator.currentRoster == [amy])
    }

    @Test("ping is answered with pong")
    func ping() async {
        let (coordinator, transport, _, _) = makeCoordinator()
        await coordinator.receive(.ping(nonce: 5))
        #expect(await transport.calls == [.send(.pong(nonce: 5))])
    }

    @Test("going online sends hello for this participant and channel")
    func helloOnOnline() async {
        let (coordinator, transport, _, _) = makeCoordinator()
        let health = Broadcaster<HealthState>()
        await coordinator.attach(messages: AsyncStream { $0.finish() }, health: health.subscribe())
        health.send(.online)
        await waitUntil { await transport.calls.contains(.send(.hello(participant: participant, channel: channel))) }
        #expect(await transport.calls == [.send(.hello(participant: participant, channel: channel))])
        await coordinator.detach()
    }

    @Test("a health drop while transmitting stops capture")
    func healthDrop() async {
        let (coordinator, _, capture, _) = makeCoordinator()
        let health = Broadcaster<HealthState>()
        await coordinator.attach(messages: AsyncStream { $0.finish() }, health: health.subscribe())
        await coordinator.press()
        await coordinator.receive(.floorGranted(to: me))
        health.send(.retrying(attempt: 1))
        await waitUntil { await coordinator.currentState == .idle }
        #expect(await capture.stopCount == 1)
        await coordinator.detach()
    }
}
