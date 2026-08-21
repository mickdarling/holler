import Testing
import HollerCoreTestSupport
@testable import HollerCore

@Suite("ConnectionSupervisor liveness")
struct ConnectionSupervisorLivenessTests {
    let policy = BackoffPolicy(initial: .milliseconds(10), multiplier: 2, cap: .seconds(1), jitter: 0)

    func connected(_ transport: FakeSignalingTransport, sleeper: FakeSleeper) async -> ConnectionSupervisor {
        let supervisor = ConnectionSupervisor(transport: transport, sleeper: sleeper,
                                              random: FixedRandomUnitSource(0.5),
                                              policy: policy, livenessInterval: .seconds(15))
        await supervisor.start()
        await supervisor.handle(.socketOpened)
        return supervisor
    }

    @Test("pings on each interval while connected and a pong resets the count")
    func pingPong() async {
        let transport = FakeSignalingTransport()
        let sleeper = FakeSleeper(holdUntilReleased: true)
        let supervisor = await connected(transport, sleeper: sleeper)
        await waitUntil { await sleeper.pendingCount == 1 }
        #expect(await sleeper.requested == [.seconds(15)])
        await sleeper.releaseAll()
        await waitUntil { await transport.calls.contains(.send(.ping(nonce: 1))) }
        await transport.emit(.message(.pong(nonce: 1)))
        await waitUntil { await supervisor.currentLiveness.pending == nil }
        #expect(await supervisor.currentLiveness.missed == 0)
        #expect(await supervisor.currentState == .connected)
    }

    @Test("two unanswered pings drop the connection into backoff")
    func deadAfterTwoMisses() async {
        let transport = FakeSignalingTransport()
        let sleeper = FakeSleeper(holdUntilReleased: true)
        let supervisor = await connected(transport, sleeper: sleeper)
        for _ in 0..<3 {
            await waitUntil { await sleeper.pendingCount >= 1 }
            await sleeper.releaseAll()
            await waitUntil {
                let pending = await sleeper.pendingCount
                let state = await supervisor.currentState
                return pending >= 1 || state != .connected
            }
        }
        await waitUntil { await supervisor.currentState == .backingOff(attempt: 1) }
        #expect(await supervisor.currentState == .backingOff(attempt: 1))
        #expect(await transport.calls.contains(.disconnect))
    }

    @Test("a watchdog woken after stop() does not ping or touch state")
    func staleTickAfterStop() async {
        let transport = FakeSignalingTransport()
        let sleeper = FakeSleeper(holdUntilReleased: true)
        let supervisor = await connected(transport, sleeper: sleeper)
        await waitUntil { await sleeper.pendingCount == 1 }
        await supervisor.stop()
        await sleeper.releaseAll()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await transport.calls.filter { if case .send = $0 { return true } else { return false } }.isEmpty)
        #expect(await supervisor.currentLiveness.pending == nil)
    }

    @Test("nonces continue across reconnections so a late pong cannot match a new ping")
    func noncesSurviveReconnect() async {
        let transport = FakeSignalingTransport()
        let sleeper = FakeSleeper(holdUntilReleased: true)
        let supervisor = await connected(transport, sleeper: sleeper)
        await waitUntil { await sleeper.pendingCount == 1 }
        await sleeper.releaseAll()
        await waitUntil { await transport.calls.contains(.send(.ping(nonce: 1))) }
        await supervisor.handle(.socketClosed(reason: "drop"))
        await supervisor.handle(.socketOpened)
        // The cancelled first watchdog still holds its sleep; wait for the new watchdog's sleep to register too.
        await waitUntil { await sleeper.pendingCount >= 2 }
        await sleeper.releaseAll()
        await waitUntil { await transport.calls.contains(.send(.ping(nonce: 2))) }
        await transport.emit(.message(.pong(nonce: 1)))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await supervisor.currentLiveness.pending == 2)
    }

    @Test("a stale tick from a previous connection generation is ignored")
    func staleGeneration() async {
        let transport = FakeSignalingTransport()
        let supervisor = await connected(transport, sleeper: FakeSleeper(holdUntilReleased: true))
        await supervisor.handleLiveness(.tick, generation: 0)
        #expect(await supervisor.currentLiveness == LivenessMachine.State())
        #expect(await transport.calls.filter { if case .send = $0 { return true } else { return false } }.isEmpty)
    }

    @Test("intervals under one second are clamped to one second")
    func clampInterval() async {
        let transport = FakeSignalingTransport()
        let sleeper = FakeSleeper(holdUntilReleased: true)
        let supervisor = ConnectionSupervisor(transport: transport, sleeper: sleeper,
                                              random: FixedRandomUnitSource(0.5),
                                              policy: policy, livenessInterval: .zero)
        await supervisor.start()
        await supervisor.handle(.socketOpened)
        await waitUntil { await sleeper.pendingCount == 1 }
        #expect(await sleeper.requested == [.seconds(1)])
    }

    @Test("liveness is disabled when the interval is nil")
    func disabled() async {
        let transport = FakeSignalingTransport()
        let sleeper = FakeSleeper(holdUntilReleased: true)
        let supervisor = ConnectionSupervisor(transport: transport, sleeper: sleeper,
                                              random: FixedRandomUnitSource(0.5),
                                              policy: policy, livenessInterval: nil)
        await supervisor.start()
        await supervisor.handle(.socketOpened)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await sleeper.pendingCount == 0)
    }
}
