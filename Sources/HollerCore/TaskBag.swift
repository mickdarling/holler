import Synchronization

/// Owns background tasks and cancels them when it is deallocated. Lets main-actor types clean up without an isolated deinit.
public final class TaskBag: Sendable {
    private let tasks = Mutex<[Task<Void, Never>]>([])

    public init() {}

    public func add(_ task: Task<Void, Never>) {
        tasks.withLock { $0.append(task) }
    }

    public func cancelAll() {
        let pending = tasks.withLock { store -> [Task<Void, Never>] in
            let values = store
            store.removeAll()
            return values
        }
        pending.forEach { $0.cancel() }
    }

    public var count: Int { tasks.withLock { $0.count } }
    public var isEmpty: Bool { tasks.withLock { $0.isEmpty } }

    deinit { cancelAll() }
}
