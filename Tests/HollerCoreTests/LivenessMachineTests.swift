import Testing
@testable import HollerCore

@Suite("LivenessMachine")
struct LivenessMachineTests {
    typealias State = LivenessMachine.State
    let machine = LivenessMachine(maxMissed: 2)

    @Test("first tick sends ping 1 and records it as outstanding")
    func firstTick() {
        let (state, effects) = machine.reduce(State(), .tick)
        #expect(state == State(nextNonce: 2, outstanding: [1], missed: 0))
        #expect(effects == [.sendPing(nonce: 1)])
    }

    @Test("matching pong clears outstanding and resets misses")
    func pong() {
        let (state, effects) = machine.reduce(State(nextNonce: 2, outstanding: [1], missed: 1), .pong(nonce: 1))
        #expect(state == State(nextNonce: 2, outstanding: [], missed: 0))
        #expect(effects.isEmpty)
    }

    @Test("a delayed pong for an older outstanding ping still proves liveness")
    func delayedPong() {
        let start = State(nextNonce: 4, outstanding: [2, 3], missed: 1)
        let (state, effects) = machine.reduce(start, .pong(nonce: 2))
        #expect(state == State(nextNonce: 4, outstanding: [3], missed: 0))
        #expect(effects.isEmpty)
    }

    @Test("unknown pong is ignored")
    func stalePong() {
        let start = State(nextNonce: 3, outstanding: [2], missed: 0)
        let (state, effects) = machine.reduce(start, .pong(nonce: 1))
        #expect(state == start)
        #expect(effects.isEmpty)
    }

    @Test("tick with an unanswered ping counts a miss and pings again")
    func missOnce() {
        let (state, effects) = machine.reduce(State(nextNonce: 2, outstanding: [1], missed: 0), .tick)
        #expect(state == State(nextNonce: 3, outstanding: [1, 2], missed: 1))
        #expect(effects == [.sendPing(nonce: 2)])
    }

    @Test("outstanding window is bounded to maxMissed + 1 (defensive; death normally comes first)")
    func boundedWindow() {
        let lenient = LivenessMachine(maxMissed: 5)
        let full = State(nextNonce: 7, outstanding: [1, 2, 3, 4, 5, 6], missed: 0)
        let (state, effects) = lenient.reduce(full, .tick)
        #expect(state.outstanding == [2, 3, 4, 5, 6, 7])
        #expect(state.missed == 1)
        #expect(effects == [.sendPing(nonce: 7)])
    }

    @Test("reaching maxMissed declares the connection dead and resets")
    func dead() {
        let (state, effects) = machine.reduce(State(nextNonce: 3, outstanding: [1, 2], missed: 1), .tick)
        #expect(state == State(nextNonce: 3))
        #expect(effects == [.declareDead])
    }

    @Test("reset keeps the nonce sequence and clears the rest")
    func reset() {
        let (state, effects) = machine.reduce(State(nextNonce: 9, outstanding: [8], missed: 1), .reset)
        #expect(state == State(nextNonce: 9))
        #expect(effects.isEmpty)
    }

    @Test("maxMissed below 1 is clamped to 1")
    func clamp() {
        let strict = LivenessMachine(maxMissed: 0)
        let (_, effects) = strict.reduce(State(nextNonce: 2, outstanding: [1], missed: 0), .tick)
        #expect(effects == [.declareDead])
    }
}
