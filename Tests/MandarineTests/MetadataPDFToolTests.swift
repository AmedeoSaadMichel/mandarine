import AppKit
import ImageIO
import PDFKit
import XCTest
@testable import Mandarine

final class MetadataPDFToolTests: XCTestCase {
    private func taggedJPEG(_ f: Fixtures, gps: Bool = true) throws -> URL {
        let img = try ImageOps.load(try f.quadrants()).image
        let u = f.url("foto.jpg")
        let dest = CGImageDestinationCreateWithURL(u as CFURL, "public.jpeg" as CFString, 1, nil)!
        var props: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "Anna", kCGImagePropertyTIFFCopyright: "(c) Anna", kCGImagePropertyTIFFImageDescription: "Mare"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "estate"],
        ]
        if gps { props[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 45.0, kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitude: 9.0, kCGImagePropertyGPSLongitudeRef: "E"] }
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return u
    }

    // MARK: Metadata – images

    func testReadImageMetadata() throws {
        let f = try Fixtures()
        let m = MetadataOps.read(try taggedJPEG(f))
        XCTAssertEqual(m["artist"], "Anna"); XCTAssertEqual(m["title"], "Mare"); XCTAssertEqual(m["comment"], "estate"); XCTAssertEqual(m["copyright"], "(c) Anna")
    }

    func testParamsArePrefilledFromTheFile() throws {
        let f = try Fixtures()
        let params = ToolEngine.params(for: .editMetadata, files: [try taggedJPEG(f)])
        XCTAssertEqual(params.first { $0.id == "f_artist" }?.defaultValue, .text("Anna"))
        XCTAssertEqual(params.first { $0.id == "gps" }?.defaultValue, .bool(true), "la foto ha il GPS")
    }

    func testEditImageMetadataChangesOnlyWhatWasEdited() async throws {
        let f = try Fixtures()
        let src = try taggedJPEG(f)
        let out = try await runTool(.editMetadata, [src], ["f_artist": .text("Luca"), "f_title": .text("Monte"), "gps": .bool(false)])[0]
        let m = MetadataOps.read(out)
        XCTAssertEqual(m["artist"], "Luca"); XCTAssertEqual(m["title"], "Monte")
        XCTAssertEqual(m["copyright"], "(c) Anna", "i campi non toccati restano")
        XCTAssertTrue(MetadataOps.hasGPS(out), "il GPS resta se non richiesto")
        XCTAssertEqual(out.lastPathComponent, "foto edited.jpg")
        XCTAssertEqual(MetadataOps.read(src)["artist"], "Anna", "l'originale non cambia")
    }

    func testEmptyFieldRemovesTheTagOnASingleFile() async throws {
        let f = try Fixtures()
        let out = try await runTool(.editMetadata, [try taggedJPEG(f)], ["f_comment": .text("")])[0]
        XCTAssertNil(MetadataOps.read(out)["comment"])
        XCTAssertEqual(MetadataOps.read(out)["artist"], "Anna")
    }

    func testRemoveGPSOnly() async throws {
        let f = try Fixtures()
        let out = try await runTool(.editMetadata, [try taggedJPEG(f)], ["gps": .bool(true)])[0]
        XCTAssertFalse(MetadataOps.hasGPS(out))
        XCTAssertEqual(MetadataOps.read(out)["artist"], "Anna")
    }

    func testCleanRemovesEverything() async throws {
        let f = try Fixtures()
        let out = try await runTool(.editMetadata, [try taggedJPEG(f)], ["mode": .text("clean")])[0]
        XCTAssertTrue(MetadataOps.read(out).isEmpty)
        XCTAssertFalse(MetadataOps.hasGPS(out))
        XCTAssertEqual(out.lastPathComponent, "foto clean.jpg")
        XCTAssertEqual(try imageSize(out).0, 100)
    }

    func testMultipleFilesOnlyApplyFilledFields() async throws {
        let f = try Fixtures()
        let a = try taggedJPEG(f)
        let b = f.url("b.jpg")
        try FileManager.default.copyItem(at: a, to: b)
        let outs = try await runTool(.editMetadata, [a, b], ["f_copyright": .text("(c) Studio"), "f_artist": .text("")])
        XCTAssertEqual(outs.count, 2)
        for o in outs {
            XCTAssertEqual(MetadataOps.read(o)["copyright"], "(c) Studio")
            XCTAssertEqual(MetadataOps.read(o)["artist"], "Anna", "campo vuoto = non cambiare con più file")
        }
    }

    // MARK: Metadata – audio / video / PDF

    func testAudioTagsRoundTrip() async throws {
        try XCTSkipIf(Converter.ffmpegPath == nil)
        let f = try Fixtures()
        let src = try f.media("s.mp3", args: ["-f", "lavfi", "-i", "sine=d=1", "-metadata", "title=Vecchio", "-metadata", "artist=Tizio"])
        XCTAssertEqual(MetadataOps.read(src)["title"], "Vecchio")
        let out = try await runTool(.editMetadata, [src], ["f_title": .text("Nuovo"), "f_album": .text("Disco"), "f_artist": .text("")])[0]
        let m = MetadataOps.read(out)
        XCTAssertEqual(m["title"], "Nuovo"); XCTAssertEqual(m["album"], "Disco"); XCTAssertNil(m["artist"])
        XCTAssertEqual(duration(out), 1, accuracy: 0.3)
    }

    func testVideoCleanRemovesTags() async throws {
        try XCTSkipIf(Converter.ffmpegPath == nil)
        let f = try Fixtures()
        let src = try f.media("v.mp4", args: ["-f", "lavfi", "-i", "testsrc=d=1:s=160x120", "-pix_fmt", "yuv420p", "-metadata", "title=Privato", "-metadata", "comment=segreto"])
        XCTAssertEqual(MetadataOps.read(src)["title"], "Privato")
        let out = try await runTool(.editMetadata, [src], ["mode": .text("clean")])[0]
        let m = MetadataOps.read(out)
        XCTAssertNil(m["title"]); XCTAssertNil(m["comment"])
    }

    func testPDFMetadataEditAndClean() async throws {
        let f = try Fixtures()
        let src = try f.pdf("doc.pdf", pages: 1)
        let edited = try await runTool(.editMetadata, [src], ["f_title": .text("Relazione"), "f_author": .text("Anna"), "f_keywords": .text("uno, due")])[0]
        let m = MetadataOps.read(edited)
        XCTAssertEqual(m["title"], "Relazione"); XCTAssertEqual(m["author"], "Anna"); XCTAssertEqual(m["keywords"], "uno, due")
        let clean = try await runTool(.editMetadata, [edited], ["mode": .text("clean")])[0]
        let c = MetadataOps.read(clean)
        XCTAssertTrue((c["title"] ?? "").isEmpty); XCTAssertTrue((c["author"] ?? "").isEmpty)
        XCTAssertEqual(PDFDocument(url: clean)?.pageCount, 1)
    }

    func testMixedSelectionOnlyOffersCommonFields() throws {
        let f = try Fixtures()
        let params = ToolEngine.params(for: .editMetadata, files: [try f.quadrants(), try f.pdf("d.pdf", pages: 1)])
        let ids = params.map(\.id)
        XCTAssertTrue(ids.contains("f_title"))
        XCTAssertFalse(ids.contains("f_artist")); XCTAssertFalse(ids.contains("f_author"))
        XCTAssertFalse(ids.contains("gps"), "il GPS ha senso solo per sole immagini")
    }

    // MARK: Compress through the engine

    func testCompressLevelsAndFormats() async throws {
        let f = try Fixtures()
        let noisy = try f.media("n.png", args: ["-f", "lavfi", "-i", "nullsrc=s=400x400,geq=random(1)*255:random(2)*255:random(3)*255", "-frames:v", "1"])
        let jpg = try await Converter.convert(noisy, to: "jpg", outputFolder: f.dir, quality: .balanced)
        let balanced = try await runTool(.compress, [jpg], ["level": .text("balanced")])[0]
        let strong = try await runTool(.compress, [jpg], ["level": .text("strong")])[0]
        XCTAssertLessThan(try Data(contentsOf: strong).count, try Data(contentsOf: balanced).count)
        XCTAssertLessThan(try Data(contentsOf: balanced).count, try Data(contentsOf: jpg).count)
    }

    func testCompressMixedBatch() async throws {
        try XCTSkipIf(Converter.ffmpegPath == nil)
        let f = try Fixtures()
        let outs = try await runTool(.compress, [try f.heavyPDF(), try f.video(seconds: 1)])
        XCTAssertEqual(outs.count, 2)
        XCTAssertEqual(Set(outs.map(\.pathExtension)), ["pdf", "mp4"])
    }

    // MARK: PDF organise

    func testParsePageSpecs() throws {
        XCTAssertEqual(try PDFOps.parsePageSpecs("3:90, 1,2:180", pageCount: 3),
                       [.init(index: 2, rotation: 90), .init(index: 0, rotation: 0), .init(index: 1, rotation: 180)])
        XCTAssertEqual(try PDFOps.parsePageSpecs("1:-90", pageCount: 1), [.init(index: 0, rotation: 270)])
        for bad in ["", "0", "4", "a", "1:45", "1:2:3"] { XCTAssertThrowsError(try PDFOps.parsePageSpecs(bad, pageCount: 3), bad) }
        XCTAssertEqual(PDFOps.encode([.init(index: 2, rotation: 90), .init(index: 0, rotation: 0)]), "3:90,1")
    }

    func testOrganizeReordersDeletesAndRotates() async throws {
        let f = try Fixtures()
        let src = try f.pdf("doc.pdf", pages: 4)
        let out = try await runTool(.organizePDF, [src], ["pages": .text("3:90,1,4")])[0]
        let doc = try XCTUnwrap(PDFDocument(url: out))
        XCTAssertEqual(doc.pageCount, 3)
        XCTAssertEqual((0..<3).map { (doc.page(at: $0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }, ["Page 3", "Page 1", "Page 4"])
        XCTAssertEqual(doc.page(at: 0)?.rotation, 90)
        XCTAssertEqual(doc.page(at: 1)?.rotation, 0)
        XCTAssertEqual(out.lastPathComponent, "doc organized.pdf")
    }

    func testOrganizeCanDuplicateAndRejectsEmpty() async throws {
        let f = try Fixtures()
        let src = try f.pdf("doc.pdf", pages: 2)
        let dup = try await runTool(.organizePDF, [src], ["pages": .text("1,1,2")])[0]
        XCTAssertEqual(PDFDocument(url: dup)?.pageCount, 3)
        do { _ = try await runTool(.organizePDF, [src], ["pages": .text("")]); XCTFail() } catch { XCTAssertTrue(error is ToolError) }
        do { _ = try await runTool(.organizePDF, [src], ["pages": .text("9")]); XCTFail() } catch { XCTAssertTrue(error is ToolError) }
    }

    func testOrganizeDefaultKeepsEveryPageInOrder() throws {
        let f = try Fixtures()
        let p = ToolEngine.params(for: .organizePDF, files: [try f.pdf("d.pdf", pages: 3)])
        XCTAssertEqual(p.first?.defaultValue, .text("1,2,3"))
    }

    // MARK: PDF split modes

    func testSplitPDFEveryPage() async throws {
        let f = try Fixtures()
        let outs = try await runTool(.splitPDF, [try f.pdf("doc.pdf", pages: 3)], ["mode": .text("pages")])
        XCTAssertEqual(outs.count, 3)
        XCTAssertTrue(outs.allSatisfy { PDFDocument(url: $0)?.pageCount == 1 })
        XCTAssertEqual(outs[0].deletingLastPathComponent().lastPathComponent, "doc pages")
    }

    func testSplitPDFEveryN() async throws {
        let f = try Fixtures()
        let outs = try await runTool(.splitPDF, [try f.pdf("doc.pdf", pages: 5)], ["mode": .text("every"), "every": .number(2)])
        XCTAssertEqual(outs.compactMap { PDFDocument(url: $0)?.pageCount }, [2, 2, 1])
        XCTAssertEqual(outs[0].deletingLastPathComponent().lastPathComponent, "doc parts")
        do { _ = try await runTool(.splitPDF, [try f.pdf("d2.pdf", pages: 2)], ["mode": .text("every"), "every": .number(0)]); XCTFail() } catch { XCTAssertTrue(error is ToolError) }
    }

    func testSplitPDFByGroups() async throws {
        let f = try Fixtures()
        let outs = try await runTool(.splitPDF, [try f.pdf("doc.pdf", pages: 6)], ["mode": .text("ranges"), "ranges": .text("1-2; 4, 6")])
        XCTAssertEqual(outs.compactMap { PDFDocument(url: $0)?.pageCount }, [2, 2])
        let texts: [[String]] = outs.compactMap { PDFDocument(url: $0) }.map { doc in
            (0..<doc.pageCount).map { i in (doc.page(at: i)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        XCTAssertEqual(texts[1], ["Page 4", "Page 6"])
    }

    func testSplitPDFInvalidGroups() async throws {
        let f = try Fixtures()
        let src = try f.pdf("doc.pdf", pages: 3)
        for bad in ["", "9", "3-1", "a"] {
            do { _ = try await runTool(.splitPDF, [src], ["mode": .text("ranges"), "ranges": .text(bad)]); XCTFail("«\(bad)»") } catch { XCTAssertFalse(error.localizedDescription.isEmpty, bad) }
        }
    }

    func testMergePDFThroughEngine() async throws {
        let f = try Fixtures()
        let out = try await runTool(.mergePDF, [try f.pdf("a.pdf", pages: 2, label: "A"), try f.pdf("b.pdf", pages: 1, label: "B")])[0]
        XCTAssertEqual(PDFDocument(url: out)?.pageCount, 3)
    }

    // MARK: Which tools are offered

    private func urls(_ names: String...) -> [URL] { names.map { URL(fileURLWithPath: "/tmp/\($0)") } }

    func testAvailableToolsForOneImage() {
        let t = Set(ToolID.available(for: urls("a.png")))
        for expected in [ToolID.compress, .editMetadata, .editImage, .frameImage, .cropImage, .redactImage, .resizeImage, .rotateImage, .createPDF] {
            XCTAssertTrue(t.contains(expected), expected.title)
        }
        XCTAssertFalse(t.contains(.createCollage)); XCTAssertFalse(t.contains(.trimVideo)); XCTAssertFalse(t.contains(.mergePDF))
    }

    func testAvailableToolsForSeveralImages() {
        let t = Set(ToolID.available(for: urls("a.png", "b.jpg", "c.heic")))
        XCTAssertTrue(t.isSuperset(of: [.compress, .editMetadata, .resizeImage, .rotateImage, .createPDF, .createCollage]))
        for single in [ToolID.editImage, .frameImage, .cropImage, .redactImage] { XCTAssertFalse(t.contains(single), single.title) }
    }

    func testAvailableToolsForVideoAndAudio() throws {
        try XCTSkipIf(Converter.ffmpegPath == nil)
        let one = Set(ToolID.available(for: urls("a.mp4")))
        XCTAssertTrue(one.isSuperset(of: [.compress, .editMetadata, .trimVideo, .cropVideo, .changeVideoSpeed, .videoSnapshots, .splitVideo, .redactVideo]))
        XCTAssertFalse(one.contains(.joinVideos)); XCTAssertFalse(one.contains(.trimAudio))
        let two = Set(ToolID.available(for: urls("a.mp4", "b.mov")))
        XCTAssertTrue(two.contains(.joinVideos)); XCTAssertFalse(two.contains(.trimVideo))
        let audio = Set(ToolID.available(for: urls("a.mp3")))
        XCTAssertTrue(audio.isSuperset(of: [.compress, .editMetadata, .normalizeAudio, .audioToVideo, .trimAudio, .audioChannels, .redactAudio]))
        XCTAssertFalse(audio.contains(.trimVideo))
    }

    func testAvailableToolsForPDFs() {
        let one = Set(ToolID.available(for: urls("a.pdf")))
        XCTAssertTrue(one.isSuperset(of: [.compress, .editMetadata, .organizePDF, .splitPDF]))
        XCTAssertFalse(one.contains(.mergePDF))
        let two = Set(ToolID.available(for: urls("a.pdf", "b.pdf")))
        XCTAssertTrue(two.contains(.mergePDF)); XCTAssertFalse(two.contains(.organizePDF)); XCTAssertFalse(two.contains(.splitPDF))
    }

    func testMixedAndUnsupportedSelections() throws {
        let mixed = Set(ToolID.available(for: urls("a.png", "b.pdf")))
        XCTAssertTrue(mixed.isSubset(of: [.compress, .editMetadata]))
        XCTAssertTrue(ToolID.available(for: urls("a.csv")).isEmpty)
        XCTAssertTrue(ToolID.available(for: urls("a.xyz")).isEmpty)
        XCTAssertTrue(ToolID.available(for: []).isEmpty)
        XCTAssertTrue(ToolID.available(for: urls("a.txt", "b.docx")).isEmpty)
        XCTAssertFalse(ToolID.available(for: urls("a.png", "b.xyz")).contains(.resizeImage), "un file sconosciuto esclude gli strumenti immagine")
    }

    func testEveryToolHasConsistentMetadata() {
        XCTAssertEqual(ToolID.allCases.count, 25)
        for t in ToolID.allCases {
            XCTAssertFalse(t.title.isEmpty); XCTAssertFalse(t.symbol.isEmpty); XCTAssertFalse(t.shortTitle.isEmpty)
            XCTAssertNotNil(NSImage(systemSymbolName: t.symbol, accessibilityDescription: nil), "simbolo SF mancante: \(t.symbol)")
        }
        XCTAssertEqual(Set(ToolID.allCases.map(\.rawValue)).count, 25)
    }

    func testEveryToolDefinesValidDefaults() throws {
        let f = try Fixtures()
        let samples: [ToolID: [URL]] = [
            .compress: [try f.quadrants()], .editMetadata: [try f.quadrants()], .editImage: [try f.quadrants("e.png")], .frameImage: [try f.quadrants("f.png")],
            .cropImage: [try f.quadrants("c.png")], .redactImage: [try f.quadrants("r.png")], .resizeImage: [try f.quadrants("z.png")], .rotateImage: [try f.quadrants("o.png")],
            .createPDF: [try f.quadrants("p.png")], .createCollage: [try f.quadrants("c1.png"), try f.quadrants("c2.png")],
            .mergePDF: [try f.pdf("m1.pdf", pages: 1), try f.pdf("m2.pdf", pages: 1)], .organizePDF: [try f.pdf("o.pdf", pages: 2)], .splitPDF: [try f.pdf("s.pdf", pages: 2)],
        ]
        for (tool, files) in samples {
            let params = ToolEngine.params(for: tool, files: files)
            XCTAssertEqual(Set(params.map(\.id)).count, params.count, "\(tool): id duplicati")
            let values = ToolValues(defaultsFor: params)
            for p in params { XCTAssertNotNil(values[p.id], "\(tool).\(p.id)"); _ = p.visible?(values) }
        }
    }

    func testToolValuesAccessors() {
        var v = ToolValues(["n": .number(3), "t": .text("x"), "b": .bool(true), "r": .rects([CGRect(x: 0, y: 0, width: 1, height: 1)]), "num": .text("2.5")])
        XCTAssertEqual(v.number("n"), 3); XCTAssertEqual(v.number("num"), 2.5); XCTAssertEqual(v.number("missing", default: 7), 7)
        XCTAssertEqual(v.string("t"), "x"); XCTAssertTrue(v.bool("b")); XCTAssertEqual(v.rects("r").count, 1); XCTAssertTrue(v.rects("none").isEmpty)
        v["t"] = .text("1:30"); XCTAssertEqual(v.time("t"), 90)
    }

    func testColorHexRoundTrip() {
        XCTAssertEqual(NSColor(hex: "#FF8000")?.hexString, "#FF8000")
        XCTAssertEqual(NSColor(hex: "00ff00")?.hexString, "#00FF00")
        XCTAssertNil(NSColor(hex: "nope")); XCTAssertNil(NSColor(hex: "#12345"))
    }

    func testRunRefusesAToolThatDoesNotApply() async throws {
        let f = try Fixtures()
        do { _ = try await ToolEngine.run(.createCollage, files: [try f.quadrants()], values: ToolValues(), folder: nil); XCTFail() } catch { XCTAssertTrue(error is ToolError) }
        do { _ = try await ToolEngine.run(.mergePDF, files: [try f.quadrants()], values: ToolValues(), folder: nil); XCTFail() } catch {}
    }
}
