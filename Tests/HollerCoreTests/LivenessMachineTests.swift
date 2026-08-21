import Testing
@testable import HollerCore

@Suite("LivenessMachine")
struct LivenessMachineTests {
    typealias State = LivenessMachine.State
    let machine = LivenessMachine(maxMissed: 2)

    @Test("first tick sends ping 1 and records it as pending")
    func firstTick() {
        let (state, effects) = machine.reduce(State(), .tick)
        #expect(state == State(nextNonce: 2, pending: 1, missed: 0))
        #expect(effects == [.sendPing(nonce: 1)])
    }

    @Test("matching pong clears pending and resets misses")
    func pong() {
        let (state, effects) = machine.reduce(State(nextNonce: 2, pending: 1, missed: 1), .pong(nonce: 1))
        #expect(state == State(nextNonce: 2, pending: nil, missed: 0))
        #expect(effects.isEmpty)
    }

    @Test("stale or unknown pong is ignored")
    func stalePong() {
        let start = State(nextNonce: 3, pending: 2, missed: 0)
        let (state, effects) = machine.reduce(start, .pong(nonce: 1))
        #expect(state == start)
        #expect(effects.isEmpty)
    }

    @Test("tick with an unanswered ping counts a miss and pings again")
    func missOnce() {
        let (state, effects) = machine.reduce(State(nextNonce: 2, pending: 1, missed: 0), .tick)
        #expect(state == State(nextNonce: 3, pending: 2, missed: 1))
        #expect(effects == [.sendPing(nonce: 2)])
    }

    @Test("reaching maxMissed declares the connection dead and resets")
    func dead() {
        let (state, effects) = machine.reduce(State(nextNonce: 3, pending: 2, missed: 1), .tick)
        #expect(state == State())
        #expect(effects == [.declareDead])
    }

    @Test("reset clears everything")
    func reset() {
        let (state, effects) = machine.reduce(State(nextNonce: 9, pending: 8, missed: 1), .reset)
        #expect(state == State())
        #expect(effects.isEmpty)
    }

    @Test("maxMissed below 1 is clamped to 1")
    func clamp() {
        let strict = LivenessMachine(maxMissed: 0)
        let (_, effects) = strict.reduce(State(nextNonce: 2, pending: 1, missed: 0), .tick)
        #expect(effects == [.declareDead])
    }
}
