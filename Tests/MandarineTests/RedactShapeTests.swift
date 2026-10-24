import XCTest
@testable import Mandarine

final class RedactShapeTests: XCTestCase {
    func testFreehandNormalizesAndRetainsContourWhenResized() throws {
        var area = try XCTUnwrap(TimedArea.freehand([CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.2), CGPoint(x: 0.5, y: 0.8)]))
        XCTAssertEqual(area.shape, .freehand)
        XCTAssertEqual(area.points[0], .zero)
        area.rect = CGRect(x: 0, y: 0, width: 200, height: 100)
        let path = area.path(in: area.rect)
        XCTAssertTrue(path.contains(CGPoint(x: 100, y: 25)))
        XCTAssertFalse(path.contains(CGPoint(x: 10, y: 90)))
        XCTAssertNil(TimedArea.freehand([.zero, .zero]))
    }

    func testMaximumBlurExportsSmallAreasForEveryShape() async throws {
        let f = try Fixtures()
        let source = try f.video("small.mov", seconds: 2)
        for shape in [RedactShape.rectangle, .ellipse, .freehand] {
            // Both luma and subsampled chroma planes are smaller than radius 80.
            for width in [0.2, 0.02] {
                let area = TimedArea(rect: CGRect(x: 0.2, y: 0.2, width: width, height: 0.2), shape: shape,
                                     points: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0.5, y: 1)], start: 0.5, end: 1.5)
                let output = try await runTool(.redactVideo, [source], ["areas": .areas([area]), "style": .text("blur"), "strength": .number(80)])[0]
                XCTAssertFileExists(output)
                XCTAssertEqual(duration(output), 2, accuracy: 0.15)
                XCTAssertTrue(MediaInfo.hasAudio(output))
                let original = try XCTUnwrap(MediaInfo.frame(source, at: 1))
                let blurred = try XCTUnwrap(MediaInfo.frame(output, at: 1))
                XCTAssertEqual(blurred.width, original.width)
                XCTAssertEqual(blurred.height, original.height)
                XCTAssertTrue(isClose(pixel(blurred, 140, 90), pixel(original, 140, 90), tolerance: 25))
            }
        }
    }

    func testEllipseAndFreehandExportsPreserveOutsideContourAndTiming() async throws {
        let f = try Fixtures()
        let source = try f.video(seconds: 3)
        let rect = CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        for shape in [RedactShape.ellipse, .freehand] {
            let area = TimedArea(rect: rect, shape: shape,
                                 points: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0.5, y: 1)], start: 1, end: 2)
            for style in ["black", "blur", "pixelate"] {
                let output = try await runTool(.redactVideo, [source], ["areas": .areas([area]), "style": .text(style), "strength": .number(8)])[0]
                XCTAssertEqual(duration(output), 3, accuracy: 0.15)
                let original = try XCTUnwrap(MediaInfo.frame(source, at: 1.5))
                let inside = try XCTUnwrap(MediaInfo.frame(output, at: 1.5))
                let before = try XCTUnwrap(MediaInfo.frame(output, at: 0.5))
                let beforeSource = try XCTUnwrap(MediaInfo.frame(source, at: 0.5))
                // Inside the bounding rectangle, outside both the ellipse and triangle.
                XCTAssertTrue(isClose(pixel(inside, 34, 90), pixel(original, 34, 90), tolerance: 25), "\(shape) \(style): fuori contorno")
                XCTAssertTrue(isClose(pixel(before, 80, 60), pixel(beforeSource, 80, 60), tolerance: 25), "fuori intervallo")
                if style == "black" {
                    let center = pixel(inside, 80, 60)
                    XCTAssertLessThan(center.r + center.g + center.b, 30)
                }
            }
        }
    }
}
