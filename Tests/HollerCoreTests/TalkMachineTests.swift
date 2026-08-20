import Testing
@testable import HollerCore

@Suite("TalkMachine")
struct TalkMachineTests {
    typealias S = TalkMachine.State
    typealias E = TalkMachine.Event
    let machine = TalkMachine()
    let alice = ParticipantID("alice")
    let bob = ParticipantID("bob")

    @Test("press requests the floor")
    func press() {
        let (state, effects) = machine.reduce(.idle, .pressed)
        #expect(state == .requesting)
        #expect(effects == [.sendFloorRequest])
    }

    @Test("grant starts capture")
    func grant() {
        let (state, effects) = machine.reduce(.requesting, .granted)
        #expect(state == .transmitting)
        #expect(effects == [.startCapture])
    }

    @Test("deny returns to idle and notifies")
    func deny() {
        let (state, effects) = machine.reduce(.requesting, .denied(heldBy: bob))
        #expect(state == .idle)
        #expect(effects == [.notifyDenied(heldBy: bob)])
    }

    @Test("release while requesting releases without capture")
    func releaseWhileRequesting() {
        let (state, effects) = machine.reduce(.requesting, .released)
        #expect(state == .idle)
        #expect(effects == [.sendFloorRelease])
    }

    @Test("release while transmitting stops capture then releases floor")
    func releaseWhileTransmitting() {
        let (state, effects) = machine.reduce(.transmitting, .released)
        #expect(state == .idle)
        #expect(effects == [.stopCapture, .sendFloorRelease])
    }

    @Test("remote speaker starts playback")
    func remoteStart() {
        let (state, effects) = machine.reduce(.idle, .remoteStarted(alice))
        #expect(state == .receiving(from: alice))
        #expect(effects == [.startPlayback(from: alice)])
    }

    @Test("only the current speaker stopping ends playback")
    func remoteStop() {
        let (still, none) = machine.reduce(.receiving(from: alice), .remoteStopped(bob))
        #expect(still == .receiving(from: alice))
        #expect(none.isEmpty)
        let (state, effects) = machine.reduce(.receiving(from: alice), .remoteStopped(alice))
        #expect(state == .idle)
        #expect(effects == [.stopPlayback])
    }

    @Test("pressing while receiving is denied locally")
    func pressWhileReceiving() {
        let (state, effects) = machine.reduce(.receiving(from: alice), .pressed)
        #expect(state == .receiving(from: alice))
        #expect(effects == [.notifyDenied(heldBy: alice)])
    }

    @Test("disconnect cleans up every active state", arguments: [
        (S.transmitting, [TalkMachine.Effect.stopCapture]),
        (S.receiving(from: ParticipantID("alice")), [.stopPlayback]),
        (S.requesting, []),
    ])
    func disconnect(pair: (S, [TalkMachine.Effect])) {
        let (state, effects) = machine.reduce(pair.0, .disconnected)
        #expect(state == .idle)
        #expect(effects == pair.1)
    }
}
