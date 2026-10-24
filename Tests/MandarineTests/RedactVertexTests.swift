import XCTest
@testable import Mandarine

@MainActor
final class RedactVertexTests: XCTestCase {
    func testInsertAtClickedSegmentIncludingClosingEdge() throws {
        let f = try Fixtures(), s = ToolSession(tool: .redactVideo, files: [try f.video(seconds: 4)])
        let vertices = [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.2), CGPoint(x: 0.8, y: 0.8), CGPoint(x: 0.2, y: 0.8)]
        s.setAreas([try XCTUnwrap(TimedArea.freehand(vertices))]); s.selectArea(0)
        let size = CGSize(width: 1000, height: 500)
        XCTAssertTrue(s.insertRedactPoint(at: CGPoint(x: 0.45, y: 0.21), displaySize: size))
        XCTAssertEqual(s.selectedRedactPoint, 1)
        XCTAssertEqual(s.redactVertices[1].x, 0.45, accuracy: 0.0001)
        XCTAssertEqual(s.redactVertices[1].y, 0.2, accuracy: 0.0001)
        XCTAssertTrue(s.insertRedactPoint(at: CGPoint(x: 0.2, y: 0.5), displaySize: size))
        XCTAssertEqual(s.selectedRedactPoint, 5)
        XCTAssertEqual(s.redactVertices.count, 6)
        XCTAssertFalse(s.insertRedactPoint(at: CGPoint(x: 0.5, y: 0.5), displaySize: size))
        XCTAssertFalse(s.insertRedactPoint(at: vertices[0], displaySize: size))
        s.deleteRedactPoint()
        XCTAssertEqual(s.redactVertices.count, 5)
    }

    func testChangingShapeTransformsSelectedAreaAndKeepsGeometryAndTime() throws {
        let f = try Fixtures()
        let s = ToolSession(tool: .redactVideo, files: [try f.video(seconds: 4)])
        let rect = CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        s.setAreas([TimedArea(rect: rect, start: 1, end: 3), TimedArea(rect: .init(x: 0, y: 0, width: 0.1, height: 0.1))])
        s.selectArea(0)
        s.changeRedactShape(.ellipse)
        XCTAssertEqual(s.areas[0].shape, .ellipse)
        XCTAssertEqual(s.areas[0].rect, rect)
        XCTAssertEqual(s.areas[0].start, 1)
        XCTAssertEqual(s.areas[0].end, 3)
        s.changeRedactShape(.freehand)
        XCTAssertEqual(s.redactVertices.count, 24)
        let points = s.areas[0].points
        s.changeRedactShape(.rectangle)
        s.changeRedactShape(.freehand)
        XCTAssertEqual(s.areas[0].points, points)
        s.selectArea(1)
        XCTAssertEqual(s.redactShape, .rectangle)
        XCTAssertEqual(s.areas[0].shape, .freehand)
    }

    func testMoveAddDeleteVerticesPreservesOthersAndMinimumCount() throws {
        let f = try Fixtures()
        let s = ToolSession(tool: .redactVideo, files: [try f.video(seconds: 4)])
        let original = [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.2), CGPoint(x: 0.5, y: 0.8)]
        var area = try XCTUnwrap(TimedArea.freehand(original))
        area.start = 1; area.end = 3
        s.setAreas([area]); s.selectArea(0)
        s.moveRedactPoint(0, to: CGPoint(x: 0.1, y: 0.3))
        XCTAssertEqual(s.redactVertices[0].x, 0.1, accuracy: 0.0001)
        XCTAssertEqual(s.redactVertices[1].x, original[1].x, accuracy: 0.0001)
        XCTAssertEqual(s.redactVertices[2].y, original[2].y, accuracy: 0.0001)
        s.addRedactPoint()
        XCTAssertEqual(s.redactVertices.count, 4)
        XCTAssertEqual(s.selectedRedactPoint, 1)
        XCTAssertEqual(s.redactVertices[1].x, 0.45, accuracy: 0.0001)
        s.deleteRedactPoint()
        XCTAssertEqual(s.redactVertices.count, 3)
        s.deleteRedactPoint()
        XCTAssertEqual(s.redactVertices.count, 3)
        XCTAssertEqual(s.areas[0].start, 1)
        XCTAssertEqual(s.areas[0].end, 3)
        s.moveRedactPoint(0, to: CGPoint(x: -10, y: 10))
        XCTAssertEqual(s.redactVertices[0], CGPoint(x: 0, y: 1))
    }
}
