import HollerCore
import HollerCoreTestSupport
@testable import HollerPTT

let kitchen = ChannelID("kitchen")
let becca = Participant(id: ParticipantID("b"), displayName: "Becca")

/// Keep the harness (and so the gate) alive for the whole test: the gate's pumps hold it weakly.
struct GateHarness {
    let gate: PushToTalkGatedControl
    let service: FakePushToTalkChannel
    let inner: FakeTalkControl
}

func makeGate() async throws -> GateHarness {
    let service = FakePushToTalkChannel()
    let inner = FakeTalkControl()
    let gate = PushToTalkGatedControl(inner: inner, service: service, channel: kitchen)
    try await gate.start(channelName: "Kitchen")
    return GateHarness(gate: gate, service: service, inner: inner)
}

func eventually(attempts: Int = 500, _ condition: () async -> Bool) async {
    for _ in 0..<attempts where !(await condition()) {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(2))
    }
}
