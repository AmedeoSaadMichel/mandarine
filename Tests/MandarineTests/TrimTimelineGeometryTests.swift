import XCTest
@testable import Mandarine

final class TrimTimelineGeometryTests: XCTestCase {
    private let layout = TrimTimelineGeometry(width: 600, duration: 8)

    func testInitialStartAndEndHandlesAreFullyInsideTheTimeline() {
        XCTAssertGreaterThanOrEqual(layout.x(0) - TrimTimelineGeometry.hitWidth / 2, 0)
        XCTAssertLessThanOrEqual(layout.x(8) + TrimTimelineGeometry.hitWidth / 2, 600)
    }

    func testFirstDragSelectsTheStartHandleWithoutEditingATimeField() {
        let initial = TrimRange(duration: 8)
        for x in [CGFloat(0), layout.x(0), layout.x(0) + 6] {
            XCTAssertEqual(layout.target(at: x, start: initial.start, end: initial.end), .start)
        }
        var range = initial
        range.setStart(layout.time(layout.x(2)))
        XCTAssertEqual(range.start, 2, accuracy: 0.001)
        XCTAssertEqual(range.end, 8)
    }

    func testEndHandleAndTrackScrubbingRemainDistinct() {
        XCTAssertEqual(layout.target(at: 600, start: 0, end: 8), .end)
        XCTAssertEqual(layout.target(at: layout.x(8), start: 0, end: 8), .end)
        XCTAssertEqual(layout.target(at: layout.x(4), start: 0, end: 8), .playhead)
    }

    func testHandlesAtTheClipEdgesCanReturnToTheEntireClip() {
        XCTAssertEqual(layout.time(-40), 0)
        XCTAssertEqual(layout.time(640), 8)
        for time in [0.0, 1, 3, 7, 8] {
            XCTAssertEqual(layout.time(layout.x(time)), time, accuracy: 0.0001)
        }
    }

    func testCloseHandlesChooseTheNearestEdge() {
        XCTAssertEqual(layout.target(at: layout.x(3), start: 3, end: 3.1), .start)
        XCTAssertEqual(layout.target(at: layout.x(3.1), start: 3, end: 3.1), .end)
    }
}
