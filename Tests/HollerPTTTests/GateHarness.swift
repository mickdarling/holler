import Testing
import HollerCore
import HollerCoreTestSupport
@testable import HollerPTT

let kitchen = ChannelID("kitchen")
let becca = Participant(id: ParticipantID("b"), displayName: "Becca")

/// Keep the harness (and so the gate) alive for the whole test: the gate's pumps hold it weakly.
struct GateHarness {
    let gate: PushToTalkGatedControl
    let service: FakePushToTalkChannel
    let inner: RecordingTalkControl
}

/// A started gate whose membership the fake system has confirmed (`.joined` is emitted by the fake's `join`).
func makeGate() async throws -> GateHarness {
    let service = FakePushToTalkChannel()
    let inner = RecordingTalkControl()
    let gate = PushToTalkGatedControl(inner: inner, service: service, channel: kitchen)
    try await gate.start(channelName: "Kitchen")
    try #require(await eventually { await gate.isJoinedToSystemChannel })
    return GateHarness(gate: gate, service: service, inner: inner)
}

/// Polls until `condition` holds or the wall-clock deadline passes; returns false on timeout so callers can `#require`
/// it (a silent timeout would let a later assertion pass vacuously or hang on a held continuation). The deadline is
/// generous because the simulator lane runs suites in parallel under load; passing checks return on the first poll.
@discardableResult
func eventually(within timeout: Duration = .seconds(10), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while true {
        if await condition() { return true }
        if ContinuousClock.now >= deadline { return false }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(2))
    }
}

/// Emit an event and wait until the gate has dequeued and handled it (so a negative assertion afterwards is meaningful).
func emitAndAwaitHandled(_ event: PushToTalkEvent, on service: FakePushToTalkChannel,
                         gate: PushToTalkGatedControl) async throws {
    let before = await gate.handledEventCount
    service.emit(event)
    try #require(await eventually { await gate.handledEventCount > before })
}

/// Push a talk state and wait until the gate's state pump has processed it.
func sendStateAndAwait(_ state: TalkMachine.State, on inner: RecordingTalkControl,
                       gate: PushToTalkGatedControl) async throws {
    let before = await gate.handledStateCount
    inner.sendState(state)
    try #require(await eventually { await gate.handledStateCount > before })
}
