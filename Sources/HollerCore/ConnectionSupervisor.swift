/// Owns one SignalingTransport and keeps it connected forever (or until `stop()`), publishing HealthState
/// and forwarding inbound WireMessages. All decisions live in ConnectionMachine; this actor performs effects.
public actor ConnectionSupervisor {
    private let transport: any SignalingTransport
    private let sleeper: any Sleeper
    private let random: any RandomUnitSource
    private let policy: BackoffPolicy
    private let machine = ConnectionMachine()
    private var state: ConnectionMachine.State = .idle
    private var retryTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private let healthBroadcaster = Broadcaster<HealthState>()
    private let messageBroadcaster = Broadcaster<WireMessage>(bufferingPolicy: .bufferingNewest(256))

    public init(
        transport: any SignalingTransport,
        sleeper: any Sleeper = ContinuousClockSleeper(),
        random: any RandomUnitSource = SystemRandomUnitSource(),
        policy: BackoffPolicy = .default
    ) {
        self.transport = transport
        self.sleeper = sleeper
        self.random = random
        self.policy = policy
    }

    public var currentState: ConnectionMachine.State { state }

    /// Subscribe before `start()` to observe the first transition.
    public nonisolated func subscribeHealth() -> AsyncStream<HealthState> { healthBroadcaster.subscribe() }
    public nonisolated func subscribeMessages() -> AsyncStream<WireMessage> { messageBroadcaster.subscribe() }

    public func start() async {
        if eventTask == nil { eventTask = Task { [weak self] in await self?.pumpTransportEvents() } }
        await handle(.start)
    }

    public func stop() async {
        await handle(.stop)
        retryTask?.cancel()
        retryTask = nil
    }

    /// Event entry point (also the test seam): apply one event and perform its effects.
    public func handle(_ event: ConnectionMachine.Event) async {
        let (next, effects) = machine.reduce(state, event)
        state = next
        for effect in effects { await perform(effect) }
    }

    private func perform(_ effect: ConnectionMachine.Effect) async {
        switch effect {
        case .openSocket:
            do { try await transport.connect() } catch { await handle(.socketClosed(reason: "\(error)")) }
        case .closeSocket:
            await transport.disconnect()
        case let .scheduleRetry(attempt):
            scheduleRetry(attempt: attempt)
        case let .publish(health):
            healthBroadcaster.send(health)
        }
    }

    private func scheduleRetry(attempt: Int) {
        let delay = policy.delay(forAttempt: attempt, unitRandom: random.nextUnit())
        retryTask?.cancel()
        retryTask = Task { [weak self, sleeper] in
            guard (try? await sleeper.sleep(for: delay)) != nil else { return }
            await self?.handle(.retryTimerFired)
        }
    }

    private func pumpTransportEvents() async {
        for await event in transport.events {
            switch event {
            case .connected: await handle(.socketOpened)
            case let .disconnected(reason): await handle(.socketClosed(reason: reason))
            case let .message(message): messageBroadcaster.send(message)
            }
        }
    }
}
