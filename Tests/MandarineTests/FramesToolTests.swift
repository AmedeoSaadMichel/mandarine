import AppKit
import XCTest
@testable import Mandarine

final class FrameTimesTests: XCTestCase {
    func testPickedFramesAreSortedAndDeduplicated() {
        XCTAssertEqual(MediaOps.frameTimes(chosen: [3, 1, 1.005, 2], every: nil, duration: 10), [1, 2, 3])
    }

    func testEveryNAddsFramesFromZero() {
        XCTAssertEqual(MediaOps.frameTimes(chosen: [], every: 2, duration: 7), [0, 2, 4, 6])
        XCTAssertEqual(MediaOps.frameTimes(chosen: [], every: 5, duration: 5), [0], "il secondo 5 è la fine: non c'è un fotogramma")
    }

    func testPickedAndPeriodicFramesMerge() {
        XCTAssertEqual(MediaOps.frameTimes(chosen: [2.5], every: 2, duration: 7), [0, 2, 2.5, 4, 6])
        XCTAssertEqual(MediaOps.frameTimes(chosen: [2], every: 2, duration: 5), [0, 2, 4], "un fotogramma scelto che coincide non si duplica")
    }

    func testTimesBeyondTheClipAreClampedToTheLastFrame() {
        let t = MediaOps.frameTimes(chosen: [99], every: nil, duration: 10, frameDuration: 0.04)
        XCTAssertEqual(t.count, 1); XCTAssertEqual(t[0], 9.96, accuracy: 1e-9)
        XCTAssertEqual(MediaOps.frameTimes(chosen: [9.99, 10.5, 99], every: nil, duration: 10).count, 1, "tutti finiscono sullo stesso ultimo fotogramma")
    }

    func testInvalidInputIsIgnored() {
        XCTAssertEqual(MediaOps.frameTimes(chosen: [-1, .nan, .infinity, 2], every: nil, duration: 10), [2])
        XCTAssertEqual(MediaOps.frameTimes(chosen: [], every: 0, duration: 10), [])
        XCTAssertEqual(MediaOps.frameTimes(chosen: [], every: -3, duration: 10), [])
        XCTAssertEqual(MediaOps.frameTimes(chosen: [], every: 2, duration: 0), [])
    }

    func testSnapshotTimesParsing() throws {
        var v = ToolValues(["times": .text("1.5, 0:03, ,2")])
        XCTAssertEqual(try ToolEngine.snapshotTimes(v, duration: 10), [1.5, 2, 3])
        v["times"] = .text("abc")
        XCTAssertThrowsError(try ToolEngine.snapshotTimes(v, duration: 10))
        XCTAssertThrowsError(try ToolEngine.snapshotTimes(ToolValues(["times": .text("")]), duration: 10), "nessun fotogramma")
        XCTAssertThrowsError(try ToolEngine.snapshotTimes(ToolValues(["every": .bool(true), "everyN": .number(0)]), duration: 10))
        XCTAssertEqual(try ToolEngine.snapshotTimes(ToolValues(["every": .bool(true), "everyN": .number(4)]), duration: 10), [0, 4, 8])
    }
}

@MainActor
final class FramesToolTests: XCTestCase {
    override func setUpWithError() throws { try XCTSkipIf(Converter.ffmpegPath == nil, "ffmpeg non installato") }

    private func readySession(_ f: Fixtures, seconds: Int = 4) async throws -> ToolSession {
        let s = ToolSession(tool: .videoSnapshots, files: [try f.video("v.mp4", seconds: seconds)])
        let p = try XCTUnwrap(s.trimPlayer)
        for _ in 0..<100 where !p.ready { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertTrue(p.ready)
        return s
    }

    private func waitForResults(_ s: ToolSession) async throws {
        for _ in 0..<300 where s.running || (s.results.isEmpty && s.errorMessage == nil) { try await Task.sleep(nanoseconds: 100_000_000) }
    }

    // MARK: Engine

    func testSavesTheChosenFramesIntoOneFolder() async throws {
        let f = try Fixtures()
        let outs = try await runTool(.videoSnapshots, [try f.video(seconds: 4)], ["times": .text("0.5, 2, 3.2")])
        XCTAssertEqual(outs.count, 3)
        XCTAssertEqual(outs.map(\.lastPathComponent), ["v 001.png", "v 002.png", "v 003.png"])
        XCTAssertEqual(outs[0].deletingLastPathComponent().lastPathComponent, "v frames")
        for u in outs { XCTAssertNotNil(NSImage(contentsOf: u)) }
        XCTAssertEqual(try imageSize(outs[0]).0, 160, "alla risoluzione del video")
    }

    func testFramesShowTheContentAtTheChosenTime() async throws {
        let f = try Fixtures()
        let src = try f.media("rb.mp4", args: ["-f", "lavfi", "-i", "color=c=red:s=160x90:d=2", "-f", "lavfi", "-i", "color=c=blue:s=160x90:d=2", "-filter_complex", "[0][1]concat=n=2:v=1:a=0", "-pix_fmt", "yuv420p"])
        let outs = try await runTool(.videoSnapshots, [src], ["times": .text("1, 3")])
        let first = try pixel(outs[0], 80, 45), second = try pixel(outs[1], 80, 45)
        XCTAssertGreaterThan(first.r, 150); XCTAssertGreaterThan(second.b, 150)
    }

    func testEveryNSecondsAndFormats() async throws {
        let f = try Fixtures()
        let src = try f.video(seconds: 4)
        let jpg = try await runTool(.videoSnapshots, [src], ["every": .bool(true), "everyN": .number(1), "format": .text("jpg")])
        XCTAssertEqual(jpg.count, 4); XCTAssertTrue(jpg.allSatisfy { $0.pathExtension == "jpg" })
        let heic = try await runTool(.videoSnapshots, [src], ["times": .text("1"), "format": .text("heic")])
        XCTAssertEqual(heic.count, 1); XCTAssertEqual(heic[0].pathExtension, "heic")
        XCTAssertNotNil(NSImage(contentsOf: heic[0]))
    }

    func testPickedAndPeriodicFramesCombine() async throws {
        let f = try Fixtures()
        let outs = try await runTool(.videoSnapshots, [try f.video(seconds: 4)], ["times": .text("1.5"), "every": .bool(true), "everyN": .number(2)])
        XCTAssertEqual(outs.count, 3, "0 s, 1,5 s e 2 s")
    }

    func testNothingPickedIsAnError() async throws {
        let f = try Fixtures()
        do { _ = try await runTool(.videoSnapshots, [try f.video()]); XCTFail() } catch { XCTAssertTrue(error is ToolError) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.dir.path), ["v.mp4"], "nessuna cartella creata")
    }

    func testSecondRunUsesANewFolder() async throws {
        let f = try Fixtures()
        let src = try f.video(seconds: 2)
        let a = try await runTool(.videoSnapshots, [src], ["times": .text("0.5")])
        let b = try await runTool(.videoSnapshots, [src], ["times": .text("0.5")])
        XCTAssertEqual(a[0].deletingLastPathComponent().lastPathComponent, "v frames")
        XCTAssertEqual(b[0].deletingLastPathComponent().lastPathComponent, "v frames 2")
    }

    // MARK: Session

    func testPickingFramesWithThePlayhead() async throws {
        let f = try Fixtures()
        let s = try await readySession(f)
        let p = try XCTUnwrap(s.trimPlayer)
        XCTAssertFalse(s.canRun, "senza frames il pulsante è spento")
        XCTAssertEqual(s.primaryTitle, "Save 0 frames")
        p.seek(to: 1); s.toggleCurrentFrame()
        p.seek(to: 2.5); s.toggleCurrentFrame()
        XCTAssertEqual(s.chosenFrames.count, 2)
        XCTAssertEqual(s.chosenFrames[0], 1, accuracy: 0.001); XCTAssertEqual(s.chosenFrames[1], 2.5, accuracy: 0.001)
        XCTAssertTrue(s.canRun)
        XCTAssertEqual(s.primaryTitle, "Save 2 frames")
    }

    func testPressingFOnTheSameFrameTwiceRemovesIt() async throws {
        let f = try Fixtures()
        let s = try await readySession(f)
        let p = try XCTUnwrap(s.trimPlayer)
        p.seek(to: 1.2)
        s.toggleCurrentFrame(); XCTAssertEqual(s.chosenFrames.count, 1); XCTAssertEqual(s.primaryTitle, "Save 1 frame")
        s.toggleCurrentFrame(); XCTAssertEqual(s.chosenFrames.count, 0)
    }

    func testRemovingAndClearingFrames() async throws {
        let f = try Fixtures()
        let s = try await readySession(f)
        s.setChosenFrames([3, 1, 2])
        XCTAssertEqual(s.chosenFrames, [1, 2, 3], "sempre in ordine")
        s.removeFrame(at: 1)
        XCTAssertEqual(s.chosenFrames, [1, 3])
        s.removeFrame(at: 9)
        XCTAssertEqual(s.chosenFrames, [1, 3], "indice inesistente: nessun effetto")
        s.setChosenFrames([])
        XCTAssertTrue(s.chosenFrames.isEmpty); XCTAssertFalse(s.canRun)
    }

    func testEveryNCountsInTheButtonTitle() async throws {
        let f = try Fixtures()
        let s = try await readySession(f, seconds: 4)
        s.values["every"] = .bool(true); s.values["everyN"] = .number(1)
        XCTAssertEqual(s.frameTimes.count, 4)
        XCTAssertEqual(s.primaryTitle, "Save 4 frames")
        s.setChosenFrames([0.5])
        XCTAssertEqual(s.frameTimes.count, 5)
    }

    func testFramesSidebarUsesDedicatedCards() async throws {
        let f = try Fixtures()
        let s = ToolSession(tool: .videoSnapshots, files: [try f.video("v.mp4", seconds: 1)])
        XCTAssertTrue(s.sidebarSections.isEmpty)
        XCTAssertTrue(s.params.allSatisfy(\.custom))
    }

    func testSessionRunSavesWhatWasPicked() async throws {
        let f = try Fixtures()
        let s = try await readySession(f)
        let p = try XCTUnwrap(s.trimPlayer)
        p.seek(to: 1); s.toggleCurrentFrame()
        p.seek(to: 3); s.toggleCurrentFrame()
        s.values["format"] = .text("jpg")
        s.run()
        try await waitForResults(s)
        XCTAssertNil(s.errorMessage)
        XCTAssertEqual(s.results.count, 2)
        XCTAssertTrue(s.results.allSatisfy { $0.pathExtension == "jpg" })
    }
}
