import XCTest
@testable import RufCore

final class CoalescingRequestQueueTests: XCTestCase {
    func testStartsOneRequestAndKeepsOnlyTheLatestPendingValuePerKey() {
        var queue = CoalescingRequestQueue<String, Int>()

        XCTAssertEqual(
            queue.submit("frame-1", coalescingKey: 1),
            "frame-1"
        )
        XCTAssertNil(queue.submit("frame-2", coalescingKey: 1))
        XCTAssertNil(queue.submit("frame-3", coalescingKey: 1))

        XCTAssertEqual(queue.completeCurrentRequest(), "frame-3")
        XCTAssertNil(queue.completeCurrentRequest())
    }

    func testPreservesUnkeyedRequestsAndOrderingAcrossKeys() {
        var queue = CoalescingRequestQueue<String, Int>()

        XCTAssertEqual(queue.submit("active", coalescingKey: 1), "active")
        XCTAssertNil(queue.submit("settle", coalescingKey: nil))
        XCTAssertNil(queue.submit("new-frame-1", coalescingKey: 2))
        XCTAssertNil(queue.submit("new-frame-2", coalescingKey: 2))

        XCTAssertEqual(queue.completeCurrentRequest(), "settle")
        XCTAssertEqual(queue.completeCurrentRequest(), "new-frame-2")
        XCTAssertNil(queue.completeCurrentRequest())
    }

    func testCanDiscardStalePendingRequestsWithoutAffectingTheActiveOne() {
        var queue = CoalescingRequestQueue<String, Int>()

        XCTAssertEqual(queue.submit("active", coalescingKey: 1), "active")
        XCTAssertNil(queue.submit("stale", coalescingKey: 1))
        XCTAssertNil(queue.submit("keep", coalescingKey: 2))

        queue.removePendingRequests(coalescingKey: 1)

        XCTAssertEqual(queue.completeCurrentRequest(), "keep")
        XCTAssertNil(queue.completeCurrentRequest())
    }

    func testDoesNotCoalesceAcrossAnOrderedBarrier() {
        var queue = CoalescingRequestQueue<String, Int>()

        XCTAssertEqual(queue.submit("active", coalescingKey: 1), "active")
        XCTAssertNil(queue.submit("before-barrier", coalescingKey: 2))
        XCTAssertNil(queue.submit("barrier", coalescingKey: nil))
        XCTAssertNil(queue.submit("after-barrier", coalescingKey: 2))

        XCTAssertEqual(queue.completeCurrentRequest(), "before-barrier")
        XCTAssertEqual(queue.completeCurrentRequest(), "barrier")
        XCTAssertEqual(queue.completeCurrentRequest(), "after-barrier")
        XCTAssertNil(queue.completeCurrentRequest())
    }
}
