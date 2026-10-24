import XCTest
@testable import Mandarine

final class TimedAreaTests: XCTestCase {
    func testWholeVideoAndWindow() {
        let whole = TimedArea(rect: .zero)
        XCTAssertTrue(whole.isWholeVideo); XCTAssertNil(whole.window)
        XCTAssertTrue(whole.covers(0)); XCTAssertTrue(whole.covers(999))
        let timed = TimedArea(rect: .zero, start: 2, end: 5)
        XCTAssertFalse(timed.isWholeVideo); XCTAssertEqual(timed.window?.0, 2); XCTAssertEqual(timed.window?.1, 5)
        XCTAssertFalse(timed.covers(1.9)); XCTAssertTrue(timed.covers(2)); XCTAssertTrue(timed.covers(5)); XCTAssertFalse(timed.covers(5.1))
        XCTAssertTrue(TimedArea(rect: .zero, start: 2, end: nil).isWholeVideo, "un intervallo a metà non conta")
    }

    func testValuesAcceptRectsAndAreas() {
        let r = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        let fromRects = ToolValues(["areas": .rects([r])])
        XCTAssertEqual(fromRects.areas("areas"), [TimedArea(rect: r)])
        let fromAreas = ToolValues(["areas": .areas([TimedArea(rect: r, start: 1, end: 2)])])
        XCTAssertEqual(fromAreas.rects("areas"), [r])
        XCTAssertTrue(ToolValues().areas("areas").isEmpty)
    }

    func testCornerResizeKeepsOppositeCornerAndStaysInsideImage() {
        let r = CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.4)
        let grown = RectMath.resized(r, corner: 3, to: CGPoint(x: 0.9, y: 0.8))
        XCTAssertEqual(grown.minX, r.minX)
        XCTAssertEqual(grown.minY, r.minY)
        XCTAssertEqual(grown.width, 0.7, accuracy: 0.0001)
        XCTAssertEqual(grown.height, 0.5, accuracy: 0.0001)
        for corner in 0..<4 {
            for point in [CGPoint(x: -2, y: -2), CGPoint(x: 2, y: 2)] {
                let resized = RectMath.resized(r, corner: corner, to: point)
                XCTAssertGreaterThanOrEqual(resized.minX, 0)
                XCTAssertGreaterThanOrEqual(resized.minY, 0)
                XCTAssertLessThanOrEqual(resized.maxX, 1.00001)
                XCTAssertLessThanOrEqual(resized.maxY, 1.00001)
                XCTAssertGreaterThanOrEqual(resized.width, 0.00999)
                XCTAssertGreaterThanOrEqual(resized.height, 0.00999)
            }
        }
    }

    func testRectMathHitAndMove() {
        let rects = [CGRect(x: 0, y: 0, width: 0.5, height: 0.5), CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)]
        XCTAssertEqual(RectMath.hit(CGPoint(x: 0.1, y: 0.1), in: rects), 0)
        XCTAssertEqual(RectMath.hit(CGPoint(x: 0.4, y: 0.4), in: rects), 1, "in cima vince l'ultima")
        XCTAssertNil(RectMath.hit(CGPoint(x: 0.9, y: 0.9), in: rects))
        XCTAssertNil(RectMath.hit(.zero, in: []))
        let moved = RectMath.moved(CGRect(x: 0.5, y: 0.5, width: 0.4, height: 0.4), by: CGPoint(x: 0.5, y: -0.9))
        XCTAssertEqual(moved.minX, 0.6, accuracy: 1e-9); XCTAssertEqual(moved.minY, 0, accuracy: 1e-9)
    }

    func testFilterAppliesEachAreasOwnWindow() {
        let areas = [TimedArea(rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), start: 1, end: 2), TimedArea(rect: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))]
        let f = MediaOps.redactFilter(size: (320, 240), areas: areas, style: .black, strength: 20)
        XCTAssertTrue(f.contains("drawbox=x=0:y=0:w=160:h=120:color=black:t=fill:enable='between(t,1.0,2.0)'"), f)
        XCTAssertTrue(f.contains("drawbox=x=160:y=120:w=160:h=120:color=black:t=fill[r1]"), "senza intervallo non c'è enable: \(f)")
        let blur = MediaOps.redactFilter(size: (320, 240), areas: areas, style: .blur, strength: 20)
        XCTAssertEqual(blur.components(separatedBy: "enable=").count - 1, 1, "solo l'area con intervallo")
    }
}

@MainActor
final class RedactVideoTests: XCTestCase {
    override func setUpWithError() throws { try XCTSkipIf(Converter.ffmpegPath == nil, "ffmpeg non installato") }

    private func luma(_ c: RGB) -> Int { (c.r * 299 + c.g * 587 + c.b * 114) / 1000 }

    private func brightness(_ url: URL, at t: Double, _ x: Int, _ y: Int) throws -> Int {
        luma(pixel(try XCTUnwrap(MediaInfo.frame(url, at: t)), x, y))
    }

    // MARK: Engine

    func testEachAreaIsCoveredOnlyInItsOwnTimeRange() async throws {
        let f = try Fixtures()
        let src = try f.video("v.mp4", seconds: 4, size: "320x240")
        // testsrc ha barre colorate luminose in alto.
        let a = TimedArea(rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.2), start: 1, end: 2)
        let b = TimedArea(rect: CGRect(x: 0.5, y: 0, width: 0.5, height: 0.2))
        let left = (80, 10), right = (240, 10)
        XCTAssertGreaterThan(try brightness(src, at: 0.5, left.0, left.1), 60); XCTAssertGreaterThan(try brightness(src, at: 0.5, right.0, right.1), 60)
        var v = ToolValues(defaultsFor: ToolEngine.params(for: .redactVideo, files: [src]))
        v["areas"] = .areas([a, b])
        let out = try await ToolEngine.run(.redactVideo, files: [src], values: v, folder: nil)[0]
        XCTAssertGreaterThan(try brightness(out, at: 0.5, left.0, left.1), 60, "A prima del suo intervallo: visibile")
        XCTAssertLessThan(try brightness(out, at: 0.5, right.0, right.1), 30, "B copre tutto il video")
        XCTAssertLessThan(try brightness(out, at: 1.5, left.0, left.1), 30, "A dentro il suo intervallo: coperta")
        XCTAssertLessThan(try brightness(out, at: 1.5, right.0, right.1), 30)
        XCTAssertGreaterThan(try brightness(out, at: 3.2, left.0, left.1), 60, "A dopo il suo intervallo: visibile")
        XCTAssertLessThan(try brightness(out, at: 3.2, right.0, right.1), 30)
        XCTAssertEqual(duration(out), 4, accuracy: 0.4)
        XCTAssertTrue(MediaInfo.hasAudio(out))
    }

    func testBlurAndPixelateWithTimedAreas() async throws {
        let f = try Fixtures()
        let src = try f.video("v.mp4", seconds: 2, size: "320x240")
        for style in ["blur", "pixelate"] {
            var v = ToolValues(defaultsFor: ToolEngine.params(for: .redactVideo, files: [src]))
            v["style"] = .text(style); v["strength"] = .number(16)
            v["areas"] = .areas([TimedArea(rect: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5), start: 0.5, end: 1.5)])
            let out = try await ToolEngine.run(.redactVideo, files: [src], values: v, folder: nil)[0]
            XCTAssertEqual(MediaInfo.videoSize(out)?.width, 320, style); XCTAssertEqual(duration(out), 2, accuracy: 0.4, style)
        }
    }

    func testValidation() async throws {
        let f = try Fixtures()
        let src = try f.video("v.mp4", seconds: 2)
        func run(_ areas: [TimedArea]) async throws -> [URL] {
            var v = ToolValues(defaultsFor: ToolEngine.params(for: .redactVideo, files: [src]))
            v["areas"] = .areas(areas)
            return try await ToolEngine.run(.redactVideo, files: [src], values: v, folder: nil)
        }
        let r = CGRect(x: 0, y: 0, width: 0.3, height: 0.3)
        for bad in [[], [TimedArea(rect: r, start: 2, end: 1)], [TimedArea(rect: r, start: 1, end: 1)], [TimedArea(rect: r, start: 10, end: 12)], [TimedArea(rect: r, start: -1, end: 1)]] {
            do { _ = try await run(bad); XCTFail("\(bad)") } catch { XCTAssertTrue(error is ToolError, "\(bad)") }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.dir.path), ["v.mp4"])
    }

    func testPlainRectsStillWorkAsWholeVideoAreas() async throws {
        let f = try Fixtures()
        let src = try f.video("v.mp4", seconds: 1, size: "320x240")
        let out = try await runTool(.redactVideo, [src], ["areas": .rects([CGRect(x: 0, y: 0, width: 1, height: 0.2)])])[0]
        XCTAssertLessThan(try brightness(out, at: 0.5, 100, 10), 30)
    }

    // MARK: Session

    private func readySession(_ f: Fixtures) async throws -> ToolSession {
        let s = ToolSession(tool: .redactVideo, files: [try f.video("v.mp4", seconds: 6, size: "320x240")])
        let p = try XCTUnwrap(s.trimPlayer)
        for _ in 0..<100 where !(p.ready && s.sourceSize != nil) { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertTrue(p.ready)
        return s
    }

    func testAddingAnAreaSelectsItAndCoversTheWholeVideo() async throws {
        let f = try Fixtures()
        let s = try await readySession(f)
        XCTAssertFalse(s.canRun)
        s.addArea(CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        XCTAssertEqual(s.areas.count, 1); XCTAssertEqual(s.selectedArea, 0)
        XCTAssertTrue(s.areas[0].isWholeVideo); XCTAssertTrue(s.canRun)
        XCTAssertTrue(try XCTUnwrap(s.trimPlayer).range.isWholeClip)
    }

    func testSelectingAnAreaShowsItsRangeOnTheTimeline() async throws {
        let f = try Fixtures()
        let s = try await readySession(f)
        let p = try XCTUnwrap(s.trimPlayer)
        s.addArea(CGRect(x: 0, y: 0, width: 0.2, height: 0.2))
        s.addArea(CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2))
        s.setAreaWindow(0, start: 1, end: 3)
        s.selectArea(0)
        XCTAssertEqual(p.range.start, 1, accuracy: 0.001); XCTAssertEqual(p.range.end, 3, accuracy: 0.001)
        s.selectArea(1)
        XCTAssertTrue(p.range.isWholeClip, "l'area 2 copre tutto")
        s.selectArea(nil)
        XCTAssertTrue(p.range.isWholeClip)
        s.selectArea(7)
        XCTAssertNil(s.selectedArea, "indice inesistente: nessuna selezione")
    }

    func testDraggingTheTimelineHandlesEditsTheSelectedArea() async throws {
        let f = try Fixtures()
        let s = try await readySession(f)
        let p = try XCTUnwrap(s.trimPlayer)
        s.addArea(CGRect(x: 0, y: 0, width: 0.3, height: 0.3))
        s.addArea(CGRect(x: 0.5, y: 0.5, width: 0.3, height: 0.3))
        s.selectArea(0)
        p.setStart(1); p.setEnd(2.5)
        XCTAssertEqual(s.areas[0].window?.0 ?? -1, 1, accuracy: 0.001); XCTAssertEqual(s.areas[0].window?.1 ?? -1, 2.5, accuracy: 0.001)
        XCTAssertTrue(s.areas[1].isWholeVideo, "le altre aree non cambiano")
        p.resetSelection()
        XCTAssertTrue(s.areas[0].isWholeVideo, "riportare le maniglie agli estremi = tutto il video")
    }

    func testHandlesDoNothingWithoutASelection() async throws {
        let f = try Fixtures()
        let s = try await readySession(f)
        let p = try XCTUnwrap(s.trimPlayer)
        s.addArea(CGRect(x: 0, y: 0, width: 0.3, height: 0.3))
        s.selectArea(nil)
        p.setStart(2)
        XCTAssertTrue(s.areas[0].isWholeVideo)
    }

    func testWholeVideoSwitch() async throws {
        let f = try Fixtures()
        let s = try await readySession(f)
        let p = try XCTUnwrap(s.trimPlayer)
        s.addArea(CGRect(x: 0, y: 0, width: 0.3, height: 0.3))
        p.seek(to: 2)
        s.setWholeVideo(false)
        let w = try XCTUnwrap(s.areas[0].window)
        XCTAssertEqual(w.0, 2, accuracy: 0.05); XCTAssertGreaterThan(w.1, w.0)
        XCTAssertEqual(p.range.start, w.0, accuracy: 0.001)
        s.setWholeVideo(true)
        XCTAssertTrue(s.areas[0].isWholeVideo); XCTAssertTrue(p.range.isWholeClip)
    }

    func testRemovingAreasKeepsTheSelectionConsistent() async throws {
        let f = try Fixtures()
        let s = try await readySession(f)
        for i in 0..<3 { s.addArea(CGRect(x: Double(i) * 0.2, y: 0, width: 0.1, height: 0.1)) }
        s.selectArea(2)
        s.removeArea(0)
        XCTAssertEqual(s.selectedArea, 1, "l'indice scala")
        s.removeArea(1)
        XCTAssertNil(s.selectedArea, "la selezione sparisce con l'area")
        s.removeArea(9)
        XCTAssertEqual(s.areas.count, 1)
        s.setAreas([])
        XCTAssertFalse(s.canRun)
    }

    func testSidebarHasOnlyTheStyleCard() async throws {
        let f = try Fixtures()
        let s = ToolSession(tool: .redactVideo, files: [try f.video("v.mp4", seconds: 1)])
        XCTAssertEqual(s.sidebarSections.map(\.title), ["Style"])
        XCTAssertEqual(s.sidebarSections[0].params.map(\.id), ["style"], "l'intensità compare solo per sfocatura e pixel")
        s.values["style"] = .text("blur")
        XCTAssertEqual(s.sidebarSections[0].params.map(\.id), ["style", "strength"])
    }

    func testTimeTextOfAnArea() {
        XCTAssertEqual(RedactAreasCard.timeText(TimedArea(rect: .zero)), "Entire video")
        XCTAssertEqual(RedactAreasCard.timeText(TimedArea(rect: .zero, start: 65.5, end: 70)), "1:05.5 – 1:10.0")
    }

    func testSessionRunUsesEachAreasRange() async throws {
        let f = try Fixtures()
        let s = try await readySession(f)
        s.addArea(CGRect(x: 0, y: 0, width: 0.5, height: 0.2))
        s.setAreaWindow(0, start: 1, end: 2)
        s.run()
        for _ in 0..<300 where s.running || (s.results.isEmpty && s.errorMessage == nil) { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertNil(s.errorMessage)
        let out = try XCTUnwrap(s.results.first)
        XCTAssertGreaterThan(luma(pixel(try XCTUnwrap(MediaInfo.frame(out, at: 0.3)), 80, 10)), 60)
        XCTAssertLessThan(luma(pixel(try XCTUnwrap(MediaInfo.frame(out, at: 1.5)), 80, 10)), 30)
    }
}
