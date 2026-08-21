import Testing
import HollerCore
import HollerCoreTestSupport
@testable import HollerPTT

@Suite("PushToTalkGatedControl")
struct PushToTalkGatedControlTests {
    let channel = kitchen

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

    @Test("stop releases the coordinator, leaves, and the gate can be started again")
    func stopReleasesAndRestarts() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        var innerCalls = inner.calls.subscribe().makeAsyncIterator()
        await gate.stop()
        #expect(await innerCalls.next() == "release")  // an in-progress transmission must not outlive the gate
        #expect(await service.calls.last == .leave(channel))
        try await gate.start(channelName: "Kitchen")
        service.emit(.beginTransmittingRequested(channel))
        #expect(await innerCalls.next() == "press")  // system events still reach the coordinator after a restart
        #expect(await service.count(.prepare) == 2)
        withExtendedLifetime(gate) {}
    }

    @Test("transmit callbacks for other channels are ignored")
    func otherChannelCallbacksIgnored() async throws {
        let harness = try await makeGate()
        let (gate, service, inner) = (harness.gate, harness.service, harness.inner)
        var innerCalls = inner.calls.subscribe().makeAsyncIterator()
        service.emit(.beginTransmittingRequested(ChannelID("other")))
        service.emit(.endTransmittingRequested(ChannelID("other")))
        service.emit(.beginTransmittingRequested(channel))
        #expect(await innerCalls.next() == "press")  // only ours arrived
        withExtendedLifetime(gate) {}
    }
}
