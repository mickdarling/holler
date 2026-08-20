import Testing
import HollerCoreTestSupport
@testable import HollerCore

@Suite("ConnectionSupervisor")
struct ConnectionSupervisorTests {
    let policy = BackoffPolicy(initial: .milliseconds(10), multiplier: 2, cap: .seconds(1), jitter: 0)

    func makeSupervisor(_ transport: FakeSignalingTransport,
                        sleeper: FakeSleeper = FakeSleeper()) -> ConnectionSupervisor {
        ConnectionSupervisor(transport: transport, sleeper: sleeper, random: FixedRandomUnitSource(0.5), policy: policy)
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

/// Polls a condition with short yields; bounded so a regression fails instead of hanging.
func waitUntil(attempts: Int = 200, _ condition: @Sendable () async -> Bool) async {
    for _ in 0..<attempts where !(await condition()) {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(2))
    }
}
