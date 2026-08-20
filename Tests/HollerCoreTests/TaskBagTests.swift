import Testing
@testable import HollerCore

@Suite("TaskBag")
struct TaskBagTests {
    @Test("cancelAll cancels every task and empties the bag")
    func cancelAll() async {
        let bag = TaskBag()
        let task = Task<Void, Never> { while !Task.isCancelled { await Task.yield() } }
        bag.add(task)
        #expect(bag.count == 1)
        bag.cancelAll()
        #expect(bag.count == 0)
        #expect(task.isCancelled)
    }
}
