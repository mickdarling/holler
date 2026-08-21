/// Owns one SignalingTransport and keeps it connected forever (or until `stop()`), publishing HealthState
/// and forwarding inbound WireMessages. All decisions live in ConnectionMachine and LivenessMachine;
/// this actor performs effects.
public actor ConnectionSupervisor {
    private let transport: any SignalingTransport
    private let sleeper: any Sleeper
    private let random: any RandomUnitSource
    private let policy: BackoffPolicy
    private let livenessInterval: Duration?
    private let machine = ConnectionMachine()
    private let liveness = LivenessMachine()
    private var state: ConnectionMachine.State = .idle
    private var livenessState = LivenessMachine.State()
    private var retryTask: Task<Void, Never>?
    private var livenessTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private let healthBroadcaster = Broadcaster<HealthState>()
    private let messageBroadcaster = Broadcaster<WireMessage>(bufferingPolicy: .bufferingNewest(256))

    /// - Parameter livenessInterval: ping cadence while connected; `nil` disables the watchdog.
    public init(
        transport: any SignalingTransport,
        sleeper: any Sleeper = ContinuousClockSleeper(),
        random: any RandomUnitSource = SystemRandomUnitSource(),
        policy: BackoffPolicy = .default,
        livenessInterval: Duration? = .seconds(15)
    ) {
        self.transport = transport
        self.sleeper = sleeper
        self.random = random
        self.policy = policy
        self.livenessInterval = livenessInterval
    }

    public var currentState: ConnectionMachine.State { state }
    public var currentLiveness: LivenessMachine.State { livenessState }

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
        let wasConnected = state == .connected
        state = next
        for effect in effects { await perform(effect) }
        if next == .connected, !wasConnected { startLiveness() }
        if next != .connected, wasConnected { stopLiveness() }
    }

    /// Liveness entry point (also the test seam).
    public func handleLiveness(_ event: LivenessMachine.Event) async {
        let (next, effects) = liveness.reduce(livenessState, event)
        livenessState = next
        for effect in effects {
            switch effect {
            case let .sendPing(nonce): try? await transport.send(.ping(nonce: nonce))
            case .declareDead:
                await transport.disconnect()
                await handle(.socketClosed(reason: "liveness: \(liveness.maxMissed) pings unanswered"))
            }
        }
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

    private func startLiveness() {
        guard let interval = livenessInterval else { return }
        livenessState = LivenessMachine.State()
        livenessTask?.cancel()
        livenessTask = Task { [weak self, sleeper] in
            while !Task.isCancelled {
                guard (try? await sleeper.sleep(for: interval)) != nil else { return }
                await self?.handleLiveness(.tick)
            }
        }
    }

    private func stopLiveness() {
        livenessTask?.cancel()
        livenessTask = nil
        livenessState = LivenessMachine.State()
    }

    private func pumpTransportEvents() async {
        for await event in transport.events {
            switch event {
            case .connected: await handle(.socketOpened)
            case let .disconnected(reason): await handle(.socketClosed(reason: reason))
            case let .message(message):
                if case let .pong(nonce) = message { await handleLiveness(.pong(nonce: nonce)) }
                messageBroadcaster.send(message)
            }
        }
    }
}
