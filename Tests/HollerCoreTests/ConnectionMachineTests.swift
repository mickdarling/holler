import Testing
@testable import HollerCore

@Suite("ConnectionMachine")
struct ConnectionMachineTests {
    typealias State = ConnectionMachine.State
    typealias Event = ConnectionMachine.Event
    let machine = ConnectionMachine()

    @Test("start from idle opens socket on attempt 1")
    func startFromIdle() {
        let (state, effects) = machine.reduce(.idle, .start)
        #expect(state == .connecting(attempt: 1))
        #expect(effects == [.publish(.connecting(attempt: 1)), .openSocket])
    }

    @Test("socket opened while connecting goes online")
    func opened() {
        let (state, effects) = machine.reduce(.connecting(attempt: 3), .socketOpened)
        #expect(state == .connected)
        #expect(effects == [.publish(.online)])
    }

    @Test("closed while connecting backs off with same attempt")
    func closedWhileConnecting() {
        let (state, effects) = machine.reduce(.connecting(attempt: 2), .socketClosed(reason: "refused"))
        #expect(state == .backingOff(attempt: 2))
        #expect(effects == [.publish(.retrying(attempt: 2)), .scheduleRetry(attempt: 2)])
    }

    @Test("closed while connected restarts backoff at attempt 1")
    func closedWhileConnected() {
        let (state, effects) = machine.reduce(.connected, .socketClosed(reason: "network"))
        #expect(state == .backingOff(attempt: 1))
        #expect(effects == [.publish(.retrying(attempt: 1)), .scheduleRetry(attempt: 1)])
    }

    @Test("retry timer increments attempt and reopens")
    func retry() {
        let (state, effects) = machine.reduce(.backingOff(attempt: 4), .retryTimerFired)
        #expect(state == .connecting(attempt: 5))
        #expect(effects == [.publish(.connecting(attempt: 5)), .openSocket])
    }

    @Test("stop while connected closes socket", arguments: [State.connected])
    func stopConnected(state: State) {
        let (next, effects) = machine.reduce(state, .stop)
        #expect(next == .stopped)
        #expect(effects == [.closeSocket, .publish(.stopped)])
    }

    @Test("stop while not connected only publishes",
          arguments: [State.idle, .connecting(attempt: 1), .backingOff(attempt: 2)])
    func stopElsewhere(state: State) {
        let (next, effects) = machine.reduce(state, .stop)
        #expect(next == .stopped)
        #expect(effects == [.publish(.stopped)])
    }

    @Test("stopped can be restarted")
    func restart() {
        let (state, _) = machine.reduce(.stopped, .start)
        #expect(state == .connecting(attempt: 1))
    }

    @Test("irrelevant events are no-ops", arguments: [
        (State.idle, Event.socketOpened), (State.idle, Event.retryTimerFired), (State.connected, Event.socketOpened),
        (State.connected, Event.retryTimerFired), (State.stopped, Event.socketClosed(reason: "late")),
        (State.connecting(attempt: 1), Event.start)
    ])
    func noOps(pair: (State, Event)) {
        let (next, effects) = machine.reduce(pair.0, pair.1)
        #expect(next == pair.0)
        #expect(effects.isEmpty)
    }
}
