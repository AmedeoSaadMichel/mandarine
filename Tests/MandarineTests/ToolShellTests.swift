import AppKit
import ImageIO
import XCTest
@testable import Mandarine

@MainActor
final class ToolShellTests: XCTestCase {
    // MARK: Footer button

    func testEveryToolHasAMainButtonTitle() {
        for tool in ToolID.allCases {
            XCTAssertFalse(tool.primaryTitle(fileCount: 1).isEmpty, tool.title)
            XCTAssertFalse(tool.primaryTitle(fileCount: 3).isEmpty, tool.title)
        }
    }

    func testMainButtonTitles() {
        XCTAssertEqual(ToolID.compress.primaryTitle(fileCount: 1), "Compress")
        XCTAssertEqual(ToolID.compress.primaryTitle(fileCount: 3), "Compress 3 files")
        XCTAssertEqual(ToolID.editMetadata.primaryTitle(fileCount: 1), "Save copy")
        XCTAssertEqual(ToolID.editMetadata.primaryTitle(fileCount: 2), "Apply to 2 files")
        XCTAssertEqual(ToolID.cropImage.primaryTitle(fileCount: 1), "Crop")
        XCTAssertEqual(ToolID.cropVideo.primaryTitle(fileCount: 1), "Crop")
        XCTAssertEqual(ToolID.trimVideo.primaryTitle(fileCount: 1), "Trim")
        XCTAssertEqual(ToolID.redactVideo.primaryTitle(fileCount: 1), "Redact")
        XCTAssertEqual(ToolID.splitVideo.primaryTitle(fileCount: 1), "Split")
        XCTAssertTrue(ToolID.splitVideo.usesPlayer)
        XCTAssertEqual(ToolID.mergePDF.primaryTitle(fileCount: 2), "Merge")
        XCTAssertEqual(ToolID.resizeImage.primaryTitle(fileCount: 4), "Resize 4 files")
        XCTAssertEqual(ToolID.rotateImage.primaryTitle(fileCount: 2), "Save 2 copies")
    }

    // MARK: Window classes

    func testWindowClassesFollowTheDesign() {
        for t in [ToolID.compress, .resizeImage, .rotateImage, .createPDF, .mergePDF, .splitPDF, .audioChannels] { XCTAssertEqual(t.windowClass, .compact, t.title) }
        for t in [ToolID.editMetadata, .normalizeAudio, .organizePDF, .createCollage, .joinVideos, .audioToVideo, .redactAudio] { XCTAssertEqual(t.windowClass, .standard, t.title) }
        for t in [ToolID.editImage, .cropImage, .trimVideo, .trimAudio, .cropVideo, .redactVideo, .videoSnapshots, .splitVideo] { XCTAssertEqual(t.windowClass, .editor, t.title) }
    }

    func testWindowSizesAreOrderedAndConsistent() {
        for t in ToolID.allCases {
            XCTAssertGreaterThanOrEqual(t.defaultWindowSize.width, t.minimumWindowSize.width, t.title)
            XCTAssertGreaterThanOrEqual(t.defaultWindowSize.height, t.minimumWindowSize.height, t.title)
            XCTAssertGreaterThanOrEqual(t.defaultWindowSize.width - t.sidebarWidth, 300, "\(t.title): resta spazio per la scheda principale")
        }
        XCTAssertLessThan(ToolID.compress.defaultWindowSize.width, ToolID.editMetadata.defaultWindowSize.width)
        XCTAssertLessThan(ToolID.editMetadata.defaultWindowSize.width, ToolID.cropImage.defaultWindowSize.width)
        XCTAssertLessThan(ToolID.compress.sidebarWidth, ToolID.cropImage.sidebarWidth)
    }

    // MARK: Sidebar sections

    private func session(_ tool: ToolID, _ f: Fixtures, files: [URL]? = nil) throws -> ToolSession {
        let list: [URL]
        if let files { list = files }
        else {
            switch tool.category {
            case .some(.video): list = [try f.video(seconds: 1)]
            case .some(.audio): list = [try f.tone(seconds: 1)]
            case .some(.document): list = [try f.pdf("d.pdf", pages: 2)]
            default: list = [try f.quadrants()]
            }
        }
        return ToolSession(tool: tool, files: list)
    }

    func testEveryVisibleParameterBelongsToACard() throws {
        let f = try Fixtures()
        let multi: [ToolID: [URL]] = [.createCollage: [try f.quadrants("a.png"), try f.quadrants("b.png")], .mergePDF: [try f.pdf("m1.pdf", pages: 1), try f.pdf("m2.pdf", pages: 1)]]
        for tool in ToolID.allCases where !(tool.needsFFmpeg && Converter.ffmpegPath == nil) {
            if tool == .joinVideos { continue }
            let s = try session(tool, f, files: multi[tool])
            for p in s.params {
                if case .rect = p.kind { continue }
                if p.inMain || p.custom || (tool == .organizePDF && p.id == "pages") { continue }
                XCTAssertNotNil(p.section, "\(tool): il parametro \(p.id) non ha una scheda")
            }
        }
    }

    func testSectionOrderAndGrouping() throws {
        let f = try Fixtures()
        XCTAssertEqual(try session(.editImage, f).sidebarSections.map(\.title), ["Light", "Color", "Detail"])
        XCTAssertEqual(try session(.frameImage, f).sidebarSections.map(\.title), ["Background", "Style"])
        XCTAssertEqual(try session(.cropImage, f).sidebarSections.map(\.title), ["Aspect ratio"])
        XCTAssertEqual(try session(.rotateImage, f).sidebarSections.map(\.title), ["Rotation", "Flip"])
        let edit = try session(.editImage, f).sidebarSections
        XCTAssertEqual(edit[0].params.map(\.id), ["exposure", "brightness", "contrast"])
        XCTAssertEqual(edit[1].params.map(\.id), ["saturation", "filter"])
    }

    func testHiddenParametersLeaveTheirCard() throws {
        let f = try Fixtures()
        let s = try session(.resizeImage, f)
        XCTAssertEqual(s.sidebarSections.flatMap(\.params).map(\.id), ["mode", "max", "upscale"])
        s.values["mode"] = .text("percent")
        XCTAssertEqual(s.sidebarSections.flatMap(\.params).map(\.id), ["mode", "percent"])
        s.values["mode"] = .text("exact")
        XCTAssertEqual(s.sidebarSections.flatMap(\.params).map(\.id), ["mode", "width", "height", "keep"])
    }

    func testRectParametersAndMetadataFieldsAreNotInTheSidebar() throws {
        let f = try Fixtures()
        let crop = try session(.cropImage, f)
        XCTAssertFalse(crop.sidebarSections.flatMap(\.params).contains { $0.id == "area" })
        let meta = try session(.editMetadata, f)
        XCTAssertTrue(meta.params.filter { $0.id.hasPrefix("f_") }.allSatisfy(\.inMain))
        XCTAssertFalse(meta.sidebarSections.flatMap(\.params).contains { $0.id.hasPrefix("f_") })
        XCTAssertEqual(meta.sidebarSections.map(\.title), ["Removal"])
    }

    func testToolsWithoutParametersHaveNoCards() throws {
        let f = try Fixtures()
        let merge = try session(.mergePDF, f, files: [try f.pdf("a.pdf", pages: 1), try f.pdf("b.pdf", pages: 1)])
        XCTAssertTrue(merge.sidebarSections.isEmpty)
        let organize = try session(.organizePDF, f)
        XCTAssertTrue(organize.sidebarSections.isEmpty, "le pagine si modificano nella scheda principale")
    }

    // MARK: Footer state

    func testFileLabel() throws {
        let f = try Fixtures()
        XCTAssertEqual(try session(.resizeImage, f).fileLabel, "quad.png")
        XCTAssertEqual(try session(.resizeImage, f, files: [try f.quadrants("a.png"), try f.quadrants("b.png"), try f.quadrants("c.png")]).fileLabel, "3 files")
    }

    func testMainButtonIsEnabledOnlyWhenTheActionMakesSense() throws {
        let f = try Fixtures()
        let crop = try session(.cropImage, f)
        XCTAssertTrue(crop.canRun, "il ritaglio parte con un riquadro predefinito")
        crop.values["area"] = .rects([])
        XCTAssertFalse(crop.canRun)
        crop.values["area"] = .rects([CGRect(x: 0.2, y: 0.2, width: 0, height: 0)])
        XCTAssertFalse(crop.canRun, "un riquadro vuoto non basta")
        crop.values["area"] = .rects([CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3)])
        XCTAssertTrue(crop.canRun)

        let redact = try session(.redactImage, f)
        XCTAssertFalse(redact.canRun, "senza aree non c'è niente da oscurare")
        redact.values["areas"] = .rects([CGRect(x: 0, y: 0, width: 0.2, height: 0.2)])
        XCTAssertTrue(redact.canRun)

        XCTAssertTrue(try session(.resizeImage, f).canRun)
    }

    func testTrimButtonWaitsForThePreview() async throws {
        try XCTSkipIf(Converter.ffmpegPath == nil)
        let f = try Fixtures()
        let s = try session(.trimVideo, f)
        XCTAssertFalse(s.canRun, "il file non è ancora pronto")
        let p = try XCTUnwrap(s.trimPlayer)
        for _ in 0..<100 where !p.ready { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertTrue(s.canRun)
    }

    func testButtonIsDisabledWhileRunning() throws {
        let f = try Fixtures()
        let s = try session(.resizeImage, f)
        s.run()
        XCTAssertTrue(s.running)
        XCTAssertFalse(s.canRun)
        s.cancel()
    }

    func testCancelClosesTheWindowWhenIdleAndStopsAJobWhenRunning() throws {
        let f = try Fixtures()
        let s = try session(.resizeImage, f)
        var closed = 0
        s.requestClose = { closed += 1 }
        s.cancelOrClose()
        XCTAssertEqual(closed, 1)
        s.run()
        s.cancelOrClose()
        XCTAssertEqual(closed, 1, "durante l'esecuzione Annulla ferma il lavoro e non chiude")
    }

    func testClosingStopsPlaybackAndCancelsTheJob() async throws {
        try XCTSkipIf(Converter.ffmpegPath == nil)
        let f = try Fixtures()
        let s = try session(.trimVideo, f)
        let p = try XCTUnwrap(s.trimPlayer)
        for _ in 0..<100 where !p.ready { try await Task.sleep(nanoseconds: 100_000_000) }
        p.play()
        var closed = false
        s.requestClose = { closed = true }
        s.cancelOrClose()
        XCTAssertTrue(closed); XCTAssertFalse(p.isPlaying)
    }

    // MARK: Crop card

    func testCropDescription() {
        XCTAssertEqual(CropInfoCard.describe(CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8), in: CGSize(width: 1280, height: 720)), "1024 × 576 at 128, 72")
        XCTAssertEqual(CropInfoCard.describe(CGRect(x: 0, y: 0, width: 1, height: 1), in: CGSize(width: 100, height: 50)), "100 × 50 at 0, 0")
    }

    func testSourceSizeOfImagesAndVideos() async throws {
        let f = try Fixtures()
        let img = try session(.cropImage, f, files: [try f.quadrants("w.png", width: 300, height: 120)])
        for _ in 0..<50 where img.sourceSize == nil { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(img.sourceSize, CGSize(width: 300, height: 120))
        if Converter.ffmpegPath != nil {
            let vid = try session(.cropVideo, f, files: [try f.video("v.mp4", seconds: 1, size: "320x180")])
            for _ in 0..<80 where vid.sourceSize == nil { try await Task.sleep(nanoseconds: 100_000_000) }
            XCTAssertEqual(vid.sourceSize, CGSize(width: 320, height: 180))
        }
    }

    func testOrientedSizeSwapsForRotatedPhotos() throws {
        let f = try Fixtures()
        let base = try ImageOps.load(try f.quadrants("o.png", width: 100, height: 40)).image
        let jpg = f.url("o.jpg")
        let dest = CGImageDestinationCreateWithURL(jpg as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, base, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        XCTAssertEqual(ImageOps.orientedSize(jpg), CGSize(width: 40, height: 100))
        XCTAssertEqual(ImageOps.orientedSize(try f.quadrants("n.png", width: 100, height: 40)), CGSize(width: 100, height: 40))
        XCTAssertNil(ImageOps.orientedSize(f.url("missing.png")))
    }

    func testOrientedSizeOfSVG() throws {
        let f = try Fixtures()
        let svg = try f.text("a.svg", "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"200\" height=\"100\" viewBox=\"0 0 200 100\"><rect width=\"200\" height=\"100\" fill=\"red\"/></svg>")
        XCTAssertEqual(ImageOps.orientedSize(svg), CGSize(width: 1024, height: 512))
    }

    // MARK: Areas

    func testAreasCardOperationsOnTheValues() throws {
        let f = try Fixtures()
        let s = try session(.redactImage, f)
        s.values["areas"] = .rects([CGRect(x: 0, y: 0, width: 0.2, height: 0.2), CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2)])
        XCTAssertEqual(s.values.rects("areas").count, 2)
        XCTAssertTrue(s.canRun)
    }

    func testWindowManagerGivesEachToolItsOwnSizeAndCloseHook() throws {
        let f = try Fixtures()
        let before = ToolWindowManager.shared.openCount
        ToolWindowManager.shared.open(.resizeImage, files: [try f.quadrants()])
        XCTAssertEqual(ToolWindowManager.shared.openCount, before + 1)
        let window = NSApp.windows.last { $0.title.hasPrefix("Resize images") }
        XCTAssertNotNil(window)
        XCTAssertEqual(window?.contentRect(forFrameRect: window!.frame).width ?? 0, ToolID.resizeImage.defaultWindowSize.width, accuracy: 2)
        XCTAssertEqual(window?.minSize.width ?? 0, ToolID.resizeImage.minimumWindowSize.width, accuracy: 2)
        window?.close()
        XCTAssertEqual(ToolWindowManager.shared.openCount, before, "chiudere la finestra la libera")
    }
}
