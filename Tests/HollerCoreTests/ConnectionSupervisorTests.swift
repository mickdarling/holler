import Testing
import HollerCoreTestSupport
@testable import HollerCore

@Suite("ConnectionSupervisor")
struct ConnectionSupervisorTests {
    let policy = BackoffPolicy(initial: .milliseconds(10), multiplier: 2, cap: .seconds(1), jitter: 0)

    func makeSupervisor(_ transport: FakeSignalingTransport,
                        sleeper: FakeSleeper = FakeSleeper(),
                        liveness: Duration? = nil) -> ConnectionSupervisor {
        ConnectionSupervisor(transport: transport, sleeper: sleeper, random: FixedRandomUnitSource(0.5),
                             policy: policy, livenessInterval: liveness)
    }

    @Test("connects on start and goes online when the socket opens")
    func happyPath() async {
        let transport = FakeSignalingTransport()
        let supervisor = makeSupervisor(transport)
        await supervisor.start()
        #expect(await transport.connectCount == 1)
        await supervisor.handle(.socketOpened)
        #expect(await supervisor.currentState == .connected)
    }

    @Test("a failing connect schedules a retry with the policy delay")
    func retryAfterFailure() async {
        let transport = FakeSignalingTransport(
            connectResults: [.failure(.connectionFailed("refused")), .success(())]
        )
        let sleeper = FakeSleeper(holdUntilReleased: true)
        let supervisor = makeSupervisor(transport, sleeper: sleeper)
        await supervisor.start()
        #expect(await supervisor.currentState == .backingOff(attempt: 1))
        await waitUntil { await sleeper.pendingCount == 1 }
        #expect(await sleeper.requested == [.milliseconds(10)])
        await sleeper.releaseAll()
        await waitUntil { await transport.connectCount == 2 }
        #expect(await supervisor.currentState == .connecting(attempt: 2))
    }

    @Test("a drop while connected restarts from attempt 1")
    func dropWhileConnected() async {
        let transport = FakeSignalingTransport()
        let sleeper = FakeSleeper(holdUntilReleased: true)
        let supervisor = makeSupervisor(transport, sleeper: sleeper)
        await supervisor.start()
        await supervisor.handle(.socketOpened)
        await supervisor.handle(.socketClosed(reason: "wifi off"))
        #expect(await supervisor.currentState == .backingOff(attempt: 1))
        await waitUntil { await sleeper.pendingCount == 1 }
    }

    @Test("stop closes the socket and cancels the retry")
    func stop() async {
        let transport = FakeSignalingTransport()
        let supervisor = makeSupervisor(transport)
        await supervisor.start()
        await supervisor.handle(.socketOpened)
        await supervisor.stop()
        #expect(await supervisor.currentState == .stopped)
        #expect(await transport.calls.contains(.disconnect))
    }

    @Test("health stream publishes transitions in order")
    func healthStream() async {
        let transport = FakeSignalingTransport()
        let supervisor = makeSupervisor(transport)
        var iterator = supervisor.subscribeHealth().makeAsyncIterator()
        await supervisor.start()
        await supervisor.handle(.socketOpened)
        #expect(await iterator.next() == .connecting(attempt: 1))
        #expect(await iterator.next() == .online)
    }

    @Test("inbound messages are forwarded to subscribers")
    func messageForwarding() async {
        let transport = FakeSignalingTransport()
        let supervisor = makeSupervisor(transport)
        var messages = supervisor.subscribeMessages().makeAsyncIterator()
        await supervisor.start()
        await transport.emit(.message(.ping(nonce: 9)))
        #expect(await messages.next() == .ping(nonce: 9))
    }

    @Test("transport events drive the machine")
    func transportEvents() async {
        let transport = FakeSignalingTransport()
        let supervisor = makeSupervisor(transport)
        await supervisor.start()
        await transport.emit(.connected)
        await waitUntil { await supervisor.currentState == .connected }
        #expect(await supervisor.currentState == .connected)
    }
}

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
        #expect(await supervisor.currentLiveness == LivenessMachine.State())
    }

    @Test("a stale tick from a previous connection generation is ignored")
    func staleGeneration() async {
        let transport = FakeSignalingTransport()
        let supervisor = await connected(transport, sleeper: FakeSleeper(holdUntilReleased: true))
        await supervisor.handleLiveness(.tick, generation: 0)
        #expect(await supervisor.currentLiveness == LivenessMachine.State())
        #expect(await transport.calls.filter { if case .send = $0 { return true } else { return false } }.isEmpty)
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

/// Polls a condition with short yields; bounded so a regression fails instead of hanging.
func waitUntil(attempts: Int = 200, _ condition: @Sendable () async -> Bool) async {
    for _ in 0..<attempts where !(await condition()) {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(2))
    }
}
