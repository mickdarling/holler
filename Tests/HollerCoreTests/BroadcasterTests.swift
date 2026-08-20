import Testing
@testable import HollerCore

@Suite("Broadcaster")
struct BroadcasterTests {
    @Test("every subscriber receives every value")
    func fanOut() async {
        let broadcaster = Broadcaster<Int>()
        var first = broadcaster.subscribe().makeAsyncIterator()
        var second = broadcaster.subscribe().makeAsyncIterator()
        broadcaster.send(1)
        broadcaster.send(2)
        #expect(await first.next() == 1)
        #expect(await first.next() == 2)
        #expect(await second.next() == 1)
        #expect(await second.next() == 2)
    }

    @Test("late subscribers only see future values")
    func lateSubscriber() async {
        let broadcaster = Broadcaster<Int>()
        broadcaster.send(1)
        var late = broadcaster.subscribe().makeAsyncIterator()
        broadcaster.send(2)
        #expect(await late.next() == 2)
    }

    @Test("finish ends all streams and clears subscribers")
    func finish() async {
        let broadcaster = Broadcaster<Int>()
        var stream = broadcaster.subscribe().makeAsyncIterator()
        broadcaster.finish()
        #expect(await stream.next() == nil)
        #expect(broadcaster.subscriberCount == 0)
    }
}
