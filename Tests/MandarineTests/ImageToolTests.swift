import AppKit
import ImageIO
import PDFKit
import XCTest
@testable import Mandarine

final class ImageToolTests: XCTestCase {
    // MARK: Crop

    func testCropTopLeftQuarterKeepsRed() async throws {
        let f = try Fixtures()
        let out = try await runTool(.cropImage, [try f.quadrants()], ["area": .rects([CGRect(x: 0, y: 0, width: 0.5, height: 0.5)])])[0]
        let (w, h) = try imageSize(out)
        XCTAssertEqual(w, 50); XCTAssertEqual(h, 40)
        XCTAssertTrue(isClose(try pixel(out, 10, 10), red), "l'origine del ritaglio è in alto a sinistra")
        XCTAssertEqual(out.lastPathComponent, "quad cropped.png")
    }

    func testCropBottomRightQuarterKeepsYellow() async throws {
        let f = try Fixtures()
        let out = try await runTool(.cropImage, [try f.quadrants()], ["area": .rects([CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)])])[0]
        XCTAssertTrue(isClose(try pixel(out, 10, 10), yellow))
    }

    func testCropOutsideBoundsIsClampedAndEmptyFails() async throws {
        let f = try Fixtures()
        let src = try f.quadrants()
        let out = try await runTool(.cropImage, [src], ["area": .rects([CGRect(x: 0.8, y: 0.8, width: 0.9, height: 0.9)])])[0]
        let (w, h) = try imageSize(out)
        XCTAssertLessThanOrEqual(w, 20); XCTAssertLessThanOrEqual(h, 16)
        do { _ = try await runTool(.cropImage, [src], ["area": .rects([])]); XCTFail() } catch { XCTAssertTrue(error is ToolError) }
        do { _ = try await runTool(.cropImage, [src], ["area": .rects([CGRect(x: 0.2, y: 0.2, width: 0, height: 0)])]); XCTFail() } catch {}
    }

    func testAspectRatioHelper() {
        XCTAssertNil(ToolEngine.aspectRatio("free", imageSize: CGSize(width: 100, height: 50)))
        XCTAssertEqual(ToolEngine.aspectRatio("original", imageSize: CGSize(width: 100, height: 50)), 2)
        XCTAssertEqual(ToolEngine.aspectRatio("16:9", imageSize: .zero)!, 16.0 / 9.0, accuracy: 0.0001)
        XCTAssertEqual(ToolEngine.aspectRatio("1:1", imageSize: .zero), 1)
    }

    // MARK: Resize

    func testResizeMaxDimension() async throws {
        let f = try Fixtures()
        let src = try f.quadrants(width: 200, height: 100)
        let out = try await runTool(.resizeImage, [src], ["mode": .text("max"), "max": .number(50)])[0]
        let (w, h) = try imageSize(out)
        XCTAssertEqual(w, 50); XCTAssertEqual(h, 25)
        XCTAssertTrue(isClose(try pixel(out, 5, 5), red))
        XCTAssertEqual(out.lastPathComponent, "quad resized.png")
    }

    func testResizeDoesNotUpscaleUnlessAsked() async throws {
        let f = try Fixtures()
        let src = try f.quadrants(width: 100, height: 50)
        let same = try await runTool(.resizeImage, [src], ["mode": .text("max"), "max": .number(400)])[0]
        XCTAssertEqual(try imageSize(same).0, 100)
        let big = try await runTool(.resizeImage, [src], ["mode": .text("max"), "max": .number(400), "upscale": .bool(true)])[0]
        XCTAssertEqual(try imageSize(big).0, 400)
    }

    func testResizePercentAndExact() async throws {
        let f = try Fixtures()
        let src = try f.quadrants(width: 200, height: 100)
        let half = try await runTool(.resizeImage, [src], ["mode": .text("percent"), "percent": .number(50)])[0]
        XCTAssertEqual(try imageSize(half).0, 100); XCTAssertEqual(try imageSize(half).1, 50)
        let fit = try await runTool(.resizeImage, [src], ["mode": .text("exact"), "width": .number(100), "height": .number(100), "keep": .bool(true)])[0]
        XCTAssertEqual(try imageSize(fit).0, 100); XCTAssertEqual(try imageSize(fit).1, 50)
        let stretch = try await runTool(.resizeImage, [src], ["mode": .text("exact"), "width": .number(100), "height": .number(100), "keep": .bool(false)])[0]
        XCTAssertEqual(try imageSize(stretch).0, 100); XCTAssertEqual(try imageSize(stretch).1, 100)
    }

    func testResizeInvalidValuesAreRejected() async throws {
        let f = try Fixtures()
        let src = try f.quadrants()
        for set in [["mode": ToolValue.text("max"), "max": .number(0)], ["mode": .text("percent"), "percent": .number(0)],
                    ["mode": .text("exact"), "width": .number(0), "height": .number(10)]] {
            do { _ = try await runTool(.resizeImage, [src], set); XCTFail("\(set)") } catch { XCTAssertTrue(error is ToolError) }
        }
    }

    func testResizeBatchProducesOneOutputPerFileAndKeepsFormat() async throws {
        let f = try Fixtures()
        let a = try f.quadrants("a.png"), b = try f.quadrants("b.jpg")
        let outs = try await runTool(.resizeImage, [a, b], ["mode": .text("percent"), "percent": .number(50)])
        XCTAssertEqual(outs.map(\.lastPathComponent), ["a resized.png", "b resized.jpg"])
    }

    func testResizeAppliesExifOrientationAndKeepsMetadata() async throws {
        let f = try Fixtures()
        let base = try f.quadrants("o.png", width: 100, height: 40)
        let img = try ImageOps.load(base).image
        let tagged = f.url("o.jpg")
        let dest = CGImageDestinationCreateWithURL(tagged as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, [kCGImagePropertyOrientation: 6, kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "ricordo"]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let out = try await runTool(.resizeImage, [tagged], ["mode": .text("percent"), "percent": .number(100)])[0]
        let (w, h) = try imageSize(out)
        XCTAssertEqual(w, 40); XCTAssertEqual(h, 100, "orientamento applicato ai pixel")
        XCTAssertEqual(MetadataOps.read(out)["comment"], "ricordo", "i metadati restano")
        let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(out as CFURL, nil)!, 0, nil) as! [CFString: Any]
        XCTAssertNotEqual(props[kCGImagePropertyOrientation] as? Int, 6, "niente doppia rotazione")
    }

    // MARK: Rotate / flip

    func testRotateClockwiseMovesRedToTopRight() async throws {
        let f = try Fixtures()
        let out = try await runTool(.rotateImage, [try f.quadrants(width: 100, height: 50)], ["rotation": .text("90")])[0]
        let (w, h) = try imageSize(out)
        XCTAssertEqual(w, 50); XCTAssertEqual(h, 100)
        XCTAssertTrue(isClose(try pixel(out, 45, 5), red), "rosso in alto a destra")
        XCTAssertTrue(isClose(try pixel(out, 5, 5), blue), "blu in alto a sinistra")
    }

    func testRotate180AndCounterClockwise() async throws {
        let f = try Fixtures()
        let src = try f.quadrants(width: 100, height: 50)
        let r180 = try await runTool(.rotateImage, [src], ["rotation": .text("180")])[0]
        XCTAssertTrue(isClose(try pixel(r180, 95, 45), red), "rosso in basso a destra")
        let ccw = try await runTool(.rotateImage, [src], ["rotation": .text("270")])[0]
        XCTAssertTrue(isClose(try pixel(ccw, 5, 95), red), "rosso in basso a sinistra")
    }

    func testFlips() async throws {
        let f = try Fixtures()
        let src = try f.quadrants()
        let h = try await runTool(.rotateImage, [src], ["rotation": .text("0"), "flipH": .bool(true)])[0]
        XCTAssertTrue(isClose(try pixel(h, 95, 5), red)); XCTAssertEqual(try imageSize(h).0, 100)
        let v = try await runTool(.rotateImage, [src], ["rotation": .text("0"), "flipV": .bool(true)])[0]
        XCTAssertTrue(isClose(try pixel(v, 5, 75), red))
        let both = try await runTool(.rotateImage, [src], ["rotation": .text("0"), "flipH": .bool(true), "flipV": .bool(true)])[0]
        XCTAssertTrue(isClose(try pixel(both, 95, 75), red))
    }

    func testFourRotationsReturnToTheOriginal() throws {
        let f = try Fixtures()
        let src = try ImageOps.load(try f.quadrants()).image
        var img = src
        for _ in 0..<4 { img = ImageOps.rotate(img, quarterTurns: 1, flipH: false, flipV: false) }
        XCTAssertEqual(img.width, src.width)
        for (x, y) in [(5, 5), (95, 5), (5, 75), (95, 75)] { XCTAssertTrue(isClose(pixel(img, x, y), pixel(src, x, y))) }
    }

    // MARK: Redact

    func testRedactBlackCoversOnlyTheSelectedArea() async throws {
        let f = try Fixtures()
        let out = try await runTool(.redactImage, [try f.quadrants()], ["areas": .rects([CGRect(x: 0, y: 0, width: 0.4, height: 0.4)]), "style": .text("black")])[0]
        XCTAssertTrue(isClose(try pixel(out, 10, 10), (0, 0, 0), tolerance: 5))
        XCTAssertTrue(isClose(try pixel(out, 95, 5), green), "fuori dall'area resta invariato")
        XCTAssertTrue(isClose(try pixel(out, 5, 75), blue))
    }

    func testRedactPixelateAndBlurChangeTheAreaButNotTheRest() async throws {
        let f = try Fixtures()
        let src = try f.quadrants(width: 120, height: 120)
        let area = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)  // centre, spans all four colours
        let original = try ImageOps.load(src).image
        for style in ["pixelate", "blur"] {
            let out = try await runTool(.redactImage, [src], ["areas": .rects([area]), "style": .text(style), "strength": .number(24)])[0]
            let img = try ImageOps.load(out).image
            XCTAssertTrue(isClose(pixel(img, 5, 5), red), "\(style): angolo invariato")
            // Il bordo tra due colori nel centro viene alterato.
            let before = pixel(original, 58, 58), after = pixel(img, 58, 58)
            XCTAssertFalse(isClose(before, after, tolerance: 3) && isClose(pixel(original, 62, 58), pixel(img, 62, 58), tolerance: 3), "\(style): l'area è cambiata")
        }
    }

    func testRedactWithoutAreasFails() async throws {
        let f = try Fixtures()
        do { _ = try await runTool(.redactImage, [try f.quadrants()]); XCTFail() } catch { XCTAssertTrue(error is ToolError) }
    }

    func testRedactMultipleAreas() async throws {
        let f = try Fixtures()
        let out = try await runTool(.redactImage, [try f.quadrants()], ["areas": .rects([CGRect(x: 0, y: 0, width: 0.2, height: 0.2), CGRect(x: 0.8, y: 0.8, width: 0.2, height: 0.2)])])[0]
        XCTAssertTrue(isClose(try pixel(out, 3, 3), (0, 0, 0), tolerance: 5))
        XCTAssertTrue(isClose(try pixel(out, 97, 77), (0, 0, 0), tolerance: 5))
        XCTAssertTrue(isClose(try pixel(out, 95, 5), green))
    }

    // MARK: Edit

    func testEditMonoFilterRemovesColour() async throws {
        let f = try Fixtures()
        let out = try await runTool(.editImage, [try f.quadrants()], ["filter": .text("mono")])[0]
        let p = try pixel(out, 10, 10)
        XCTAssertLessThan(abs(p.r - p.g), 12); XCTAssertLessThan(abs(p.g - p.b), 12)
    }

    func testEditSaturationZeroIsGreyAndBrightnessLightens() async throws {
        let f = try Fixtures()
        let grey = try await runTool(.editImage, [try f.quadrants()], ["saturation": .number(0)])[0]
        let p = try pixel(grey, 10, 10)
        XCTAssertLessThan(abs(p.r - p.b), 12)
        let dark = try f.solid("dark.png", NSColor(white: 0.3, alpha: 1))
        let lighter = try await runTool(.editImage, [dark], ["brightness": .number(0.3)])[0]
        XCTAssertGreaterThan(try pixel(lighter, 5, 5).r, try pixel(dark, 5, 5).r + 20)
    }

    func testEditExposureAndSepia() async throws {
        let f = try Fixtures()
        let dark = try f.solid("dark.png", NSColor(white: 0.2, alpha: 1))
        let bright = try await runTool(.editImage, [dark], ["exposure": .number(1.5)])[0]
        XCTAssertGreaterThan(try pixel(bright, 5, 5).r, try pixel(dark, 5, 5).r + 30)
        let sepia = try await runTool(.editImage, [try f.solid("g.png", NSColor(white: 0.5, alpha: 1))], ["filter": .text("sepia")])[0]
        let p = try pixel(sepia, 5, 5)
        XCTAssertGreaterThan(p.r, p.b, "la seppia scalda i toni")
    }

    func testEditWithDefaultsKeepsPixels() async throws {
        let f = try Fixtures()
        let src = try f.quadrants()
        let out = try await runTool(.editImage, [src])[0]
        XCTAssertTrue(isClose(try pixel(out, 10, 10), red, tolerance: 6))
        XCTAssertEqual(try imageSize(out).0, 100)
    }

    // MARK: Background

    func testFrameAddsPaddingAndColour() async throws {
        let f = try Fixtures()
        let src = try f.solid("s.png", .red, width: 100, height: 100)
        let out = try await runTool(.frameImage, [src], ["padding": .number(10), "color": .text("#0000FF"), "aspect": .text("original")])[0]
        XCTAssertEqual(try imageSize(out).0, 120); XCTAssertEqual(try imageSize(out).1, 120)
        XCTAssertTrue(isClose(try pixel(out, 2, 2), blue))
        XCTAssertTrue(isClose(try pixel(out, 60, 60), red))
    }

    func testFrameAspectRatioExpandsTheCanvas() async throws {
        let f = try Fixtures()
        let out = try await runTool(.frameImage, [try f.solid("s.png", .red, width: 100, height: 100)], ["padding": .number(0), "aspect": .text("16:9")])[0]
        let (w, h) = try imageSize(out)
        XCTAssertEqual(Double(w) / Double(h), 16.0 / 9.0, accuracy: 0.03)
        XCTAssertGreaterThanOrEqual(h, 100)
        let tall = try await runTool(.frameImage, [try f.solid("t.png", .red, width: 100, height: 100)], ["padding": .number(0), "aspect": .text("9:16")])[0]
        XCTAssertEqual(Double(try imageSize(tall).0) / Double(try imageSize(tall).1), 9.0 / 16.0, accuracy: 0.03)
    }

    func testFrameRoundedCornersShowBackground() async throws {
        let f = try Fixtures()
        let out = try await runTool(.frameImage, [try f.solid("s.png", .red, width: 100, height: 100)], ["padding": .number(10), "color": .text("#FFFFFF"), "corner": .number(30)])[0]
        XCTAssertTrue(isClose(try pixel(out, 11, 11), (255, 255, 255), tolerance: 30), "l'angolo è arrotondato")
        XCTAssertTrue(isClose(try pixel(out, 60, 60), red))
    }

    // MARK: Collage

    func testCollageLayoutAndColours() async throws {
        let f = try Fixtures()
        let imgs = [try f.solid("a.png", .red), try f.solid("b.png", .green), try f.solid("c.png", .blue), try f.solid("d.png", .yellow)]
        let out = try await runTool(.createCollage, imgs, ["columns": .number(2), "cell": .number(100), "spacing": .number(10), "color": .text("#FFFFFF")])[0]
        let (w, h) = try imageSize(out)
        XCTAssertEqual(w, 230); XCTAssertEqual(h, 230)
        XCTAssertTrue(isClose(try pixel(out, 60, 60), red))
        XCTAssertTrue(isClose(try pixel(out, 170, 60), green))
        XCTAssertTrue(isClose(try pixel(out, 60, 170), blue))
        XCTAssertTrue(isClose(try pixel(out, 170, 170), yellow))
        XCTAssertTrue(isClose(try pixel(out, 5, 5), (255, 255, 255), tolerance: 5), "spazio tra le celle")
        XCTAssertEqual(out.lastPathComponent, "a collage.png")
    }

    func testCollageWithOddCountAndJPEG() async throws {
        let f = try Fixtures()
        let imgs = [try f.solid("a.png", .red), try f.solid("b.png", .green), try f.solid("c.png", .blue)]
        let out = try await runTool(.createCollage, imgs, ["columns": .number(2), "cell": .number(80), "spacing": .number(0), "format": .text("jpg")])[0]
        XCTAssertEqual(out.pathExtension, "jpg")
        XCTAssertEqual(try imageSize(out).0, 160); XCTAssertEqual(try imageSize(out).1, 160)
    }

    func testCollageFillCropsAndFitLeavesBorders() async throws {
        let f = try Fixtures()
        let wide = try f.solid("w.png", .red, width: 200, height: 100)
        let other = try f.solid("o.png", .red, width: 200, height: 100)
        let fill = try await runTool(.createCollage, [wide, other], ["columns": .number(2), "cell": .number(100), "spacing": .number(0), "fit": .text("fill"), "color": .text("#000000")])[0]
        XCTAssertTrue(isClose(try pixel(fill, 50, 5), red), "riempie la cella")
        let fit = try await runTool(.createCollage, [wide, other], ["columns": .number(2), "cell": .number(100), "spacing": .number(0), "fit": .text("fit"), "color": .text("#000000")])[0]
        XCTAssertTrue(isClose(try pixel(fit, 50, 5), (0, 0, 0), tolerance: 10), "bordo nero sopra")
        XCTAssertTrue(isClose(try pixel(fit, 50, 50), red))
    }

    // MARK: PDF from images

    func testCreatePDFPagesAndSizes() async throws {
        let f = try Fixtures()
        let imgs = [try f.quadrants("a.png", width: 100, height: 50), try f.quadrants("b.png", width: 60, height: 80), try f.quadrants("c.png")]
        let fit = try await runTool(.createPDF, imgs, ["pageSize": .text("fit")])[0]
        let doc = try XCTUnwrap(PDFDocument(url: fit))
        XCTAssertEqual(doc.pageCount, 3)
        XCTAssertEqual(doc.page(at: 0)!.bounds(for: .mediaBox).width, 100, accuracy: 1)
        XCTAssertEqual(doc.page(at: 1)!.bounds(for: .mediaBox).height, 80, accuracy: 1)
        XCTAssertEqual(fit.lastPathComponent, "a (+2).pdf")
    }

    func testCreatePDFA4PortraitAndLandscape() async throws {
        let f = try Fixtures()
        let out = try await runTool(.createPDF, [try f.quadrants("land.png", width: 200, height: 100), try f.quadrants("port.png", width: 100, height: 200)],
                                    ["pageSize": .text("a4"), "margin": .number(20)])[0]
        let doc = try XCTUnwrap(PDFDocument(url: out))
        let first = doc.page(at: 0)!.bounds(for: .mediaBox), second = doc.page(at: 1)!.bounds(for: .mediaBox)
        XCTAssertEqual(first.width, 842, accuracy: 1); XCTAssertEqual(first.height, 595, accuracy: 1)
        XCTAssertEqual(second.width, 595, accuracy: 1); XCTAssertEqual(second.height, 842, accuracy: 1)
    }

    func testCreatePDFFromSingleImageKeepsName() async throws {
        let f = try Fixtures()
        let out = try await runTool(.createPDF, [try f.quadrants("solo.png")])[0]
        XCTAssertEqual(out.lastPathComponent, "solo.pdf")
        XCTAssertEqual(PDFDocument(url: out)?.pageCount, 1)
    }

    // MARK: Preview transforms

    func testPreviewTransformsExistOnlyForPixelTools() {
        XCTAssertNotNil(ToolEngine.previewTransform(.editImage, ToolValues()))
        XCTAssertNotNil(ToolEngine.previewTransform(.frameImage, ToolValues()))
        XCTAssertNotNil(ToolEngine.previewTransform(.rotateImage, ToolValues(["rotation": .text("90")])))
        XCTAssertNil(ToolEngine.previewTransform(.compress, ToolValues()))
        XCTAssertNil(ToolEngine.previewTransform(.cropImage, ToolValues()))
    }

    func testOutputFolderIsHonoured() async throws {
        let f = try Fixtures(), dest = try Fixtures()
        let out = try await runTool(.rotateImage, [try f.quadrants()], folder: dest.dir)[0]
        XCTAssertEqual(out.deletingLastPathComponent().standardizedFileURL.path, dest.dir.standardizedFileURL.path)
    }

    func testToolsNeverTouchTheOriginal() async throws {
        let f = try Fixtures()
        let src = try f.quadrants()
        let before = try Data(contentsOf: src)
        for tool in [ToolID.editImage, .frameImage, .rotateImage, .resizeImage] { _ = try await runTool(tool, [src]) }
        XCTAssertEqual(try Data(contentsOf: src), before)
    }
}
