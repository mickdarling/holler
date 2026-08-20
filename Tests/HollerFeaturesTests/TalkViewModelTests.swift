import Testing
import HollerCore
import HollerCoreTestSupport
@testable import HollerFeatures

@Suite("TalkViewModel")
@MainActor
struct TalkViewModelTests {
    @Test("mirrors talk state, health, roster, and notices from the control layer")
    func mirrors() async {
        let control = FakeTalkControl()
        let health = Broadcaster<HealthState>()
        let model = TalkViewModel(channelName: "Kitchen", control: control, health: health.subscribe())
        let becca = Participant(id: ParticipantID("b"), displayName: "Becca")
        health.send(.online)
        control.roster.send([becca])
        control.states.send(.receiving(from: becca.id))
        control.notices.send(.denied(heldBy: becca.id))
        await waitUntil { model.lastNotice != nil && model.health == .online && model.roster.count == 1 }
        #expect(model.health == .online)
        #expect(model.speakerName == "Becca")
        #expect(model.canTalk == false)
        #expect(model.lastNotice == .denied(heldBy: becca.id))
    }

    @Test("press and release reach the control layer")
    func pressRelease() async {
        let control = FakeTalkControl()
        let model = TalkViewModel(channelName: "Kitchen", control: control, health: AsyncStream { $0.finish() })
        var calls = control.calls.subscribe().makeAsyncIterator()
        model.pressed()
        #expect(await calls.next() == "press")
        model.released()
        #expect(await calls.next() == "release")
    }

    @Test("canTalk requires online and idle")
    func canTalk() async {
        let control = FakeTalkControl()
        let health = Broadcaster<HealthState>()
        let model = TalkViewModel(channelName: "Kitchen", control: control, health: health.subscribe())
        #expect(model.canTalk == false)
        health.send(.online)
        await waitUntil { model.health == .online }
        #expect(model.canTalk == true)
    }
}

@MainActor
func waitUntil(attempts: Int = 200, _ condition: @MainActor () -> Bool) async {
    for _ in 0..<attempts where !condition() {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(2))
    }
}
