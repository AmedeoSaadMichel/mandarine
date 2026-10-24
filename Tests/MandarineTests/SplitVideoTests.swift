import XCTest
@testable import Mandarine

final class SplitPlanTests: XCTestCase {
    func testAddingKeepsPointsSortedAndRejectsTooClose() {
        var p = SplitPlan.adding(5, to: [], duration: 10)!
        p = SplitPlan.adding(2, to: p, duration: 10)!
        XCTAssertEqual(p, [2, 5])
        XCTAssertNil(SplitPlan.adding(0.05, to: p, duration: 10))   // too close to the start
        XCTAssertNil(SplitPlan.adding(9.95, to: p, duration: 10))   // too close to the end
        XCTAssertNil(SplitPlan.adding(5.03, to: p, duration: 10))   // too close to a point
        XCTAssertNotNil(SplitPlan.adding(5.06, to: p, duration: 10))
        XCTAssertNotNil(SplitPlan.adding(0.1, to: [], duration: 10))
    }

    func testEqualPoints() {
        XCTAssertEqual(SplitPlan.equalPoints(duration: 10, parts: 2), [5])
        XCTAssertEqual(SplitPlan.equalPoints(duration: 9, parts: 3), [3, 6])
        XCTAssertEqual(SplitPlan.equalPoints(duration: 100, parts: 50).count, 49)
        XCTAssertEqual(SplitPlan.equalPoints(duration: 100, parts: 80).count, 49)
        XCTAssertEqual(SplitPlan.equalPoints(duration: 100, parts: 1).count, 1)
    }

    func testCombinedKeepsAutomaticCutsAndDeduplicatesCustomPoints() {
        XCTAssertEqual(SplitPlan.combined(duration: 8, parts: 2, custom: [6, 2, 4.02, 2]), [2, 4, 6])
        XCTAssertEqual(SplitPlan.combined(duration: 8, parts: nil, custom: [6, 2]), [2, 6])
    }

    func testCombinedExportUsesBothKindsOfCuts() async throws {
        let f = try Fixtures()
        let outputs = try await runTool(.splitVideo, [try f.video(seconds: 8)], [
            "mode": .text("equal"), "parts": .number(2), "points": .text("2, 4, 6")
        ])
        XCTAssertEqual(outputs.count, 4)
        for output in outputs { XCTAssertEqual(duration(output), 2, accuracy: 0.15) }
    }

    func testParseRoundTrip() {
        XCTAssertEqual(SplitPlan.parse("3, 1.5"), [1.5, 3])
        XCTAssertEqual(SplitPlan.parse(""), [])
        XCTAssertNil(SplitPlan.parse("abc"))
        XCTAssertEqual(SplitPlan.parse(SplitPlan.serialize([1.25, 3])), [1.25, 3])
    }
}

@MainActor
final class SplitSessionTests: XCTestCase {
    func testAddingCustomCutsAfterEqualPartsAndRemovingThem() async throws {
        let f = try Fixtures()
        let s = ToolSession(tool: .splitVideo, files: [try f.video(seconds: 8)])
        for _ in 0..<100 where s.trimPlayer?.ready != true { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertTrue(s.trimPlayer?.ready == true)
        s.setSplitEqual(true)
        XCTAssertEqual(s.splitMarkers, [4])
        XCTAssertTrue(s.addSplit(at: 2))
        XCTAssertTrue(s.addSplit(at: 6))
        XCTAssertFalse(s.addSplit(at: 4))
        XCTAssertEqual(s.splitMarkers, [2, 4, 6])
        XCTAssertEqual(s.clipCount, 4)
        s.setSplitEqual(false)
        XCTAssertEqual(s.splitMarkers, [2, 6])
        s.setSplitEqual(true)
        s.removeSplit(at: 0)
        XCTAssertEqual(s.splitMarkers, [4, 6])
        XCTAssertEqual(s.splitPoints, [6])
    }

    func testMovingCustomCutKeepsAutomaticCutsAndTracksReordering() async throws {
        let f = try Fixtures()
        let s = ToolSession(tool: .splitVideo, files: [try f.video(seconds: 8)])
        for _ in 0..<100 where s.trimPlayer?.ready != true { try await Task.sleep(nanoseconds: 100_000_000) }
        s.setSplitEqual(true)
        XCTAssertTrue(s.addSplit(at: 2))
        XCTAssertTrue(s.addSplit(at: 6))
        XCTAssertEqual(s.moveSplit(at: 0, to: 3), 0)
        XCTAssertEqual(s.splitMarkers, [3, 4, 6])
        for invalid in [0.01, 7.99, 4, 4.02, 6, Double.nan] {
            XCTAssertNil(s.moveSplit(at: 0, to: invalid))
            XCTAssertEqual(s.splitPoints, [3, 6])
        }
        let moved = try XCTUnwrap(s.moveSplit(at: 0, to: 7))
        XCTAssertEqual(moved, 1)
        XCTAssertEqual(s.moveSplit(at: moved, to: 5), 0)
        XCTAssertEqual(s.splitPoints, [5, 6])
        XCTAssertEqual(s.splitAutomaticPoints, [4])
        XCTAssertEqual(s.clipCount, 4)
        XCTAssertNil(s.moveSplit(at: 99, to: 2))
    }

    func testClipCountAndTitleFollowPoints() async throws {
        let f = try Fixtures()
        let s = ToolSession(tool: .splitVideo, files: [try f.video(seconds: 4)])
        for _ in 0..<100 where s.trimPlayer?.ready != true { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertTrue(s.trimPlayer?.ready == true)
        XCTAssertEqual(s.clipCount, 1)
        XCTAssertFalse(s.canRun)
        XCTAssertEqual(s.primaryTitle, "Split into 1 clip")
        s.values["points"] = .text("1, 2")
        XCTAssertEqual(s.clipCount, 3)
        XCTAssertEqual(s.primaryTitle, "Split into 3 clip")
        s.removeSplit(at: 0)
        XCTAssertEqual(s.splitPoints, [2])
        s.setSplitEqual(true)
        s.setSplitParts(80)
        XCTAssertEqual(s.clipCount, 50)
        s.setSplitParts(0)
        XCTAssertEqual(s.clipCount, 2)
    }
}
