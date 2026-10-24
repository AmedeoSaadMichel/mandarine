import XCTest
@testable import Mandarine

final class CropGeometryTests: XCTestCase {
    private let size = CGSize(width: 1280, height: 720)

    func testPixelsAndBackAreConsistent() {
        let p = CropGeometry.pixels(CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8), in: size)
        XCTAssertEqual(p, PixelRect(x: 128, y: 72, width: 1024, height: 576))
        let back = CropGeometry.normalized(p, in: size)
        XCTAssertEqual(back.minX, 0.1, accuracy: 1e-9); XCTAssertEqual(back.width, 0.8, accuracy: 1e-9)
        XCTAssertEqual(CropGeometry.pixels(back, in: size), p)
    }

    func testPixelsClampToTheImage() {
        XCTAssertEqual(CropGeometry.pixels(CGRect(x: 0.9, y: 0.9, width: 0.5, height: 0.5), in: size), PixelRect(x: 1152, y: 648, width: 128, height: 72))
        XCTAssertEqual(CropGeometry.pixels(CGRect(x: -1, y: -1, width: 0, height: 0), in: size), PixelRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(CropGeometry.pixels(CGRect(x: 2, y: 2, width: 1, height: 1), in: size).x, 1279)
    }

    func testEditingWidthKeepsTheTopLeftCorner() {
        let box = PixelRect(x: 100, y: 50, width: 400, height: 300)
        let e = CropGeometry.edit(box, field: .width, value: 600, size: size, aspect: nil)
        XCTAssertEqual(e, PixelRect(x: 100, y: 50, width: 600, height: 300))
    }

    func testEditingWidthShiftsTheBoxOnlyWhenItWouldOverflow() {
        let box = PixelRect(x: 1000, y: 50, width: 200, height: 100)
        let e = CropGeometry.edit(box, field: .width, value: 500, size: size, aspect: nil)
        XCTAssertEqual(e.width, 500); XCTAssertEqual(e.x, 780, "spostato per restare dentro l'immagine"); XCTAssertEqual(e.x + e.width, 1280)
    }

    func testEditingBeyondTheImageClamps() {
        let box = PixelRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(CropGeometry.edit(box, field: .width, value: 99999, size: size, aspect: nil).width, 1280)
        XCTAssertEqual(CropGeometry.edit(box, field: .height, value: 99999, size: size, aspect: nil).height, 720)
        XCTAssertEqual(CropGeometry.edit(box, field: .width, value: 0, size: size, aspect: nil).width, 1)
        XCTAssertEqual(CropGeometry.edit(box, field: .height, value: -5, size: size, aspect: nil).height, 1)
    }

    func testXAndYMoveTheBoxInsideTheImage() {
        let box = PixelRect(x: 100, y: 100, width: 400, height: 300)
        XCTAssertEqual(CropGeometry.edit(box, field: .x, value: 5000, size: size, aspect: nil).x, 880)
        XCTAssertEqual(CropGeometry.edit(box, field: .x, value: -10, size: size, aspect: nil).x, 0)
        XCTAssertEqual(CropGeometry.edit(box, field: .y, value: 5000, size: size, aspect: nil).y, 420)
        XCTAssertEqual(CropGeometry.edit(box, field: .y, value: 7, size: size, aspect: nil).y, 7)
    }

    func testAspectRatioFollowsTheTypedSide() {
        let box = PixelRect(x: 0, y: 0, width: 400, height: 225)
        let byWidth = CropGeometry.edit(box, field: .width, value: 640, size: size, aspect: 16.0 / 9.0)
        XCTAssertEqual(byWidth.width, 640); XCTAssertEqual(byWidth.height, 360)
        let byHeight = CropGeometry.edit(box, field: .height, value: 270, size: size, aspect: 16.0 / 9.0)
        XCTAssertEqual(byHeight.height, 270); XCTAssertEqual(byHeight.width, 480)
        let square = CropGeometry.edit(PixelRect(x: 0, y: 0, width: 200, height: 200), field: .width, value: 300, size: size, aspect: 1)
        XCTAssertEqual(square.width, 300); XCTAssertEqual(square.height, 300)
    }

    func testAspectRatioNeverOverflowsTheImage() {
        let box = PixelRect(x: 900, y: 500, width: 100, height: 100)
        let e = CropGeometry.edit(box, field: .width, value: 700, size: size, aspect: 1)
        XCTAssertLessThanOrEqual(e.x + e.width, 1280); XCTAssertLessThanOrEqual(e.y + e.height, 720)
        XCTAssertEqual(e.width, e.height, "il quadrato resta quadrato")
        let tall = CropGeometry.edit(PixelRect(x: 0, y: 600, width: 100, height: 100), field: .height, value: 500, size: size, aspect: 2)
        XCTAssertLessThanOrEqual(tall.y + tall.height, 720); XCTAssertLessThanOrEqual(tall.x + tall.width, 1280)
    }

    func testCentered() {
        XCTAssertEqual(CropGeometry.centered(PixelRect(x: 0, y: 0, width: 400, height: 200), in: size), PixelRect(x: 440, y: 260, width: 400, height: 200))
        XCTAssertEqual(CropGeometry.centered(PixelRect(x: 5, y: 5, width: 1280, height: 720), in: size), PixelRect(x: 0, y: 0, width: 1280, height: 720))
    }

    func testEvenSizes() {
        XCTAssertEqual(CropGeometry.even(101), 100); XCTAssertEqual(CropGeometry.even(100), 100); XCTAssertEqual(CropGeometry.even(1), 2); XCTAssertEqual(CropGeometry.even(0), 2)
    }

    func testOutputSize() {
        let crop = PixelRect(x: 0, y: 0, width: 801, height: 451)
        XCTAssertEqual(CropGeometry.outputSize(crop: crop, sameAsCrop: true, width: nil, height: nil, keepRatio: true).0, 800)
        let scaled = CropGeometry.outputSize(crop: PixelRect(x: 0, y: 0, width: 800, height: 400), sameAsCrop: false, width: 400, height: nil, keepRatio: true)
        XCTAssertEqual(scaled.0, 400); XCTAssertEqual(scaled.1, 200)
        let free = CropGeometry.outputSize(crop: PixelRect(x: 0, y: 0, width: 800, height: 400), sameAsCrop: false, width: 300, height: 300, keepRatio: false)
        XCTAssertEqual(free.0, 300); XCTAssertEqual(free.1, 300)
        let linked = CropGeometry.outputSize(crop: PixelRect(x: 0, y: 0, width: 800, height: 400), sameAsCrop: false, width: 301, height: 999, keepRatio: true)
        XCTAssertEqual(linked.0, 300); XCTAssertEqual(linked.1, 150, "con le proporzioni bloccate conta la larghezza")
    }

    func testLinkedSide() {
        XCTAssertEqual(CropGeometry.linked(400, ratio: 2, typedIsWidth: true), 200)
        XCTAssertEqual(CropGeometry.linked(200, ratio: 2, typedIsWidth: false), 400)
        XCTAssertEqual(CropGeometry.linked(0, ratio: 2, typedIsWidth: true), 1)
    }
}

@MainActor
final class CropToolTests: XCTestCase {
    override func setUpWithError() throws { try XCTSkipIf(Converter.ffmpegPath == nil, "ffmpeg non installato") }

    private func readySession(_ tool: ToolID, _ url: URL) async throws -> ToolSession {
        let s = ToolSession(tool: tool, files: [url])
        for _ in 0..<80 where s.sourceSize == nil { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertNotNil(s.sourceSize)
        return s
    }

    func testSessionConvertsTheBoxToPixels() async throws {
        let f = try Fixtures()
        let s = try await readySession(.cropVideo, try f.video("v.mp4", seconds: 1, size: "320x180"))
        XCTAssertEqual(s.cropBox, PixelRect(x: 32, y: 18, width: 256, height: 144))
    }

    func testTypingAFieldMovesTheDrawnBox() async throws {
        let f = try Fixtures()
        let s = try await readySession(.cropVideo, try f.video("v.mp4", seconds: 1, size: "320x180"))
        s.setCrop(.width, 100)
        XCTAssertEqual(s.cropBox?.width, 100); XCTAssertEqual(s.cropBox?.x, 32)
        s.setCrop(.x, 0); XCTAssertEqual(s.cropBox?.x, 0)
        s.centerCrop()
        XCTAssertEqual(s.cropBox?.x, 110)
        s.wholeImageCrop()
        XCTAssertEqual(s.cropBox, PixelRect(x: 0, y: 0, width: 320, height: 180))
    }

    func testAspectLockAppliesToTypedFields() async throws {
        let f = try Fixtures()
        let s = try await readySession(.cropImage, try f.quadrants("q.png", width: 400, height: 200))
        s.values["aspect"] = .text("1:1")
        s.setCrop(.width, 100)
        XCTAssertEqual(s.cropBox?.width, 100); XCTAssertEqual(s.cropBox?.height, 100)
    }

    func testOutputSizeFieldsKeepTheRatio() async throws {
        let f = try Fixtures()
        let s = try await readySession(.cropVideo, try f.video("v.mp4", seconds: 1, size: "320x180"))
        s.values["area"] = .rects([CGRect(x: 0, y: 0, width: 0.5, height: 0.5)])           // 160 × 90
        s.values["sameSize"] = .bool(false)
        s.setOutput(width: 80)
        XCTAssertEqual(s.values.number("outWidth"), 80); XCTAssertEqual(s.values.number("outHeight"), 44, "45 arrotondato a pari")
        s.values["keepRatio"] = .bool(false)
        s.setOutput(height: 60)
        XCTAssertEqual(s.values.number("outHeight"), 60); XCTAssertEqual(s.values.number("outWidth"), 80, "senza blocco l'altro lato resta")
    }

    func testCropFieldsAreNotDuplicatedInTheGenericCards() async throws {
        let f = try Fixtures()
        let s = try await readySession(.cropVideo, try f.video("v.mp4", seconds: 1, size: "320x180"))
        let ids = s.sidebarSections.flatMap(\.params).map(\.id)
        XCTAssertEqual(ids, ["aspect"])
        XCTAssertEqual(s.sidebarSections.map(\.title), ["Aspect ratio"])
    }

    // MARK: Engine

    func testVideoCropWithSameSizeKeepsTheBox() async throws {
        let f = try Fixtures()
        let out = try await runTool(.cropVideo, [try f.video("v.mp4", seconds: 1, size: "320x180")], ["area": .rects([CGRect(x: 0, y: 0, width: 0.5, height: 0.5)])])[0]
        let size = try XCTUnwrap(MediaInfo.videoSize(out))
        XCTAssertEqual(size.width, 160); XCTAssertEqual(size.height, 90)
    }

    func testVideoCropWithOutputDimensionsScales() async throws {
        let f = try Fixtures()
        let src = try f.video("v.mp4", seconds: 1, size: "320x180")
        let area: [String: ToolValue] = ["area": .rects([CGRect(x: 0, y: 0, width: 0.5, height: 0.5)]), "sameSize": .bool(false)]
        var v = area; v["outWidth"] = .number(80); v["outHeight"] = .number(0)
        let ratio = try await runTool(.cropVideo, [src], v)[0]
        XCTAssertEqual(MediaInfo.videoSize(ratio)?.width, 80); XCTAssertEqual(MediaInfo.videoSize(ratio)?.height, 44)
        var w = area; w["keepRatio"] = .bool(false); w["outWidth"] = .number(200); w["outHeight"] = .number(60)
        let free = try await runTool(.cropVideo, [src], w)[0]
        XCTAssertEqual(MediaInfo.videoSize(free)?.width, 200); XCTAssertEqual(MediaInfo.videoSize(free)?.height, 60)
        XCTAssertTrue(MediaInfo.hasAudio(free), "l'audio resta")
    }

    func testVideoCropContentIsTheChosenRegion() async throws {
        let f = try Fixtures()
        // Metà sinistra rossa, metà destra blu.
        let src = try f.media("rb.mp4", args: ["-f", "lavfi", "-i", "color=c=red:s=160x80:d=1", "-f", "lavfi", "-i", "color=c=blue:s=160x80:d=1", "-filter_complex", "[0][1]hstack", "-pix_fmt", "yuv420p"])
        let right = try await runTool(.cropVideo, [src], ["area": .rects([CGRect(x: 0.5, y: 0, width: 0.5, height: 1)])])[0]
        let p = pixel(try XCTUnwrap(MediaInfo.frame(right, at: 0.3)), 40, 40)
        XCTAssertGreaterThan(p.b, 150); XCTAssertLessThan(p.r, 100)
        XCTAssertEqual(MediaInfo.videoSize(right)?.width, 160)
    }
}
