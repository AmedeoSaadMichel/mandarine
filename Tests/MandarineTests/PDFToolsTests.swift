import CoreText
import PDFKit
import XCTest
@testable import Mandarine

extension Fixtures {
    /// PDF whose page k contains the text "<label> k".
    func pdf(_ name: String, pages: Int, label: String = "Page") throws -> URL {
        let u = url(name)
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        let ctx = try XCTUnwrap(CGContext(u as CFURL, mediaBox: &box, nil))
        for k in 1...pages {
            ctx.beginPDFPage(nil)
            let text = NSAttributedString(string: "\(label) \(k)", attributes: [.font: NSFont.systemFont(ofSize: 24)])
            ctx.textPosition = CGPoint(x: 40, y: 200)
            CTLineDraw(CTLineCreateWithAttributedString(text), ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return u
    }

    /// A PDF with one big embedded noisy image: compressible by downsampling.
    func heavyPDF(_ name: String = "heavy.pdf") throws -> URL {
        let noise = try media("n.png", args: ["-f", "lavfi", "-i", "nullsrc=s=1600x1600,geq=random(1)*255:random(2)*255:random(3)*255", "-frames:v", "1"])
        let image = try XCTUnwrap(NSImage(contentsOf: noise)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let u = url(name)
        var box = CGRect(x: 0, y: 0, width: 300, height: 300)
        let ctx = try XCTUnwrap(CGContext(u as CFURL, mediaBox: &box, nil))
        ctx.beginPDFPage(nil)
        ctx.draw(image, in: box)
        let text = NSAttributedString(string: "Testo vivo", attributes: [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.white])
        ctx.textPosition = CGPoint(x: 20, y: 150)
        CTLineDraw(CTLineCreateWithAttributedString(text), ctx)
        ctx.endPDFPage()
        ctx.closePDF()
        return u
    }
}

final class PDFToolsTests: XCTestCase {
    private func pageTexts(_ url: URL) -> [String] {
        guard let doc = PDFDocument(url: url) else { return [] }
        return (0..<doc.pageCount).map { (doc.page(at: $0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func size(_ url: URL) -> Int { ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0 }

    private func names(_ dir: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() }

    // MARK: Fixtures sanity

    func testFixturePDFHasExpectedPagesAndText() throws {
        let f = try Fixtures()
        let u = try f.pdf("doc.pdf", pages: 3)
        XCTAssertEqual(pageTexts(u), ["Page 1", "Page 2", "Page 3"])
    }

    // MARK: Availability

    func testPDFToolAvailability() {
        let pdf = URL(fileURLWithPath: "/tmp/a.pdf"), txt = URL(fileURLWithPath: "/tmp/a.txt")
        XCTAssertTrue(Tools.supports(.compress, pdf))
        XCTAssertTrue(Tools.supports(.split, pdf))
        XCTAssertTrue(Tools.supports(.extractPages, pdf))
        XCTAssertFalse(Tools.supports(.trim, pdf))
        XCTAssertFalse(Tools.supports(.resize1024, pdf))
        XCTAssertFalse(Tools.supports(.split, txt))
        XCTAssertFalse(Tools.supports(.compress, txt))
        XCTAssertFalse(Tools.supports(.extractPages, URL(fileURLWithPath: "/tmp/a.docx")))
    }

    // MARK: Compress

    func testCompressPDFReducesSizeKeepsPagesAndText() async throws {
        let f = try Fixtures()
        let src = try f.heavyPDF()
        let out = try await Tools.run(.compress, on: src, folder: nil)
        XCTAssertLessThan(size(out), size(src))
        XCTAssertEqual(PDFDocument(url: out)?.pageCount, 1)
        XCTAssertTrue(pageTexts(out).first?.contains("Testo vivo") ?? false, "il testo resta selezionabile")
        XCTAssertEqual(out.lastPathComponent, "heavy compressed.pdf")
    }

    func testCompressPDFKeepsOriginalUntouched() async throws {
        let f = try Fixtures()
        let src = try f.heavyPDF()
        let before = try Data(contentsOf: src)
        _ = try await Tools.run(.compress, on: src, folder: nil)
        XCTAssertEqual(try Data(contentsOf: src), before)
    }

    func testCompressAlreadySmallPDFFailsCleanly() async throws {
        let f = try Fixtures()
        let src = try f.pdf("tiny.pdf", pages: 1)
        do { _ = try await Tools.run(.compress, on: src, folder: nil); XCTFail("non c'è nulla da comprimere") }
        catch { XCTAssertTrue(error is ConversionError); XCTAssertTrue(error.localizedDescription.contains("optimized")) }
        XCTAssertEqual(names(f.dir), ["tiny.pdf"], "nessun file residuo")
    }

    func testCompressCorruptPDFFails() async throws {
        let f = try Fixtures()
        let bad = try f.text("broken.pdf", "non sono un pdf")
        do { _ = try await Tools.run(.compress, on: bad, folder: nil); XCTFail() } catch { XCTAssertTrue(error is ConversionError) }
        XCTAssertEqual(names(f.dir), ["broken.pdf"])
    }

    func testCompressHonoursOutputFolder() async throws {
        let f = try Fixtures(), dest = try Fixtures()
        let out = try await Tools.run(.compress, on: try f.heavyPDF(), folder: dest.dir)
        XCTAssertEqual(out.deletingLastPathComponent().standardizedFileURL.path, dest.dir.standardizedFileURL.path)
    }

    // MARK: Merge

    func testMergeKeepsOrderAndAllPages() throws {
        let f = try Fixtures()
        let a = try f.pdf("a.pdf", pages: 2, label: "A"), b = try f.pdf("b.pdf", pages: 3, label: "B")
        let out = try Tools.mergePDFs([a, b], folder: nil)
        XCTAssertEqual(pageTexts(out), ["A 1", "A 2", "B 1", "B 2", "B 3"])
        XCTAssertEqual(out.lastPathComponent, "a merged.pdf")
    }

    func testMergeFollowsTheOrderGiven() throws {
        let f = try Fixtures()
        let a = try f.pdf("a.pdf", pages: 1, label: "A"), b = try f.pdf("b.pdf", pages: 1, label: "B")
        XCTAssertEqual(pageTexts(try Tools.mergePDFs([b, a], folder: nil)), ["B 1", "A 1"])
    }

    func testMergeThreeFilesAndSameFileTwice() throws {
        let f = try Fixtures()
        let a = try f.pdf("a.pdf", pages: 1, label: "A"), b = try f.pdf("b.pdf", pages: 1, label: "B"), c = try f.pdf("c.pdf", pages: 1, label: "C")
        XCTAssertEqual(pageTexts(try Tools.mergePDFs([a, b, c], folder: nil)), ["A 1", "B 1", "C 1"])
        XCTAssertEqual(pageTexts(try Tools.mergePDFs([a, a], folder: nil)), ["A 1", "A 1"])
    }

    func testMergeLeavesOriginalsUntouchedAndNeverOverwrites() throws {
        let f = try Fixtures()
        let a = try f.pdf("a.pdf", pages: 2, label: "A"), b = try f.pdf("b.pdf", pages: 2, label: "B")
        let before = (try Data(contentsOf: a), try Data(contentsOf: b))
        let first = try Tools.mergePDFs([a, b], folder: nil)
        let second = try Tools.mergePDFs([a, b], folder: nil)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(second.lastPathComponent, "a merged 2.pdf")
        XCTAssertEqual(try Data(contentsOf: a), before.0); XCTAssertEqual(try Data(contentsOf: b), before.1)
    }

    func testMergeNeedsAtLeastTwoFiles() throws {
        let f = try Fixtures()
        let a = try f.pdf("a.pdf", pages: 1)
        XCTAssertThrowsError(try Tools.mergePDFs([a], folder: nil))
        XCTAssertThrowsError(try Tools.mergePDFs([], folder: nil))
    }

    func testMergeWithCorruptOrLockedPDFFailsWithoutOutput() throws {
        let f = try Fixtures()
        let a = try f.pdf("a.pdf", pages: 1)
        let bad = try f.text("bad.pdf", "no")
        XCTAssertThrowsError(try Tools.mergePDFs([a, bad], folder: nil))
        let locked = f.url("locked.pdf")
        XCTAssertTrue(PDFDocument(url: a)!.write(to: locked, withOptions: [.userPasswordOption: "pw", .ownerPasswordOption: "pw"]))
        XCTAssertThrowsError(try Tools.mergePDFs([a, locked], folder: nil)) {
            XCTAssertTrue($0.localizedDescription.localizedCaseInsensitiveContains("password"))
        }
        XCTAssertFalse(names(f.dir).contains { $0.contains("merged") })
    }

    func testMergeHonoursOutputFolder() throws {
        let f = try Fixtures(), dest = try Fixtures()
        let out = try Tools.mergePDFs([try f.pdf("a.pdf", pages: 1), try f.pdf("b.pdf", pages: 1)], folder: dest.dir)
        XCTAssertEqual(out.deletingLastPathComponent().standardizedFileURL.path, dest.dir.standardizedFileURL.path)
    }

    // MARK: Split

    func testSplitCreatesOnePDFPerPageInNewFolder() async throws {
        let f = try Fixtures()
        let src = try f.pdf("doc.pdf", pages: 4)
        let folder = try await Tools.run(.split, on: src, folder: nil)
        XCTAssertEqual(folder.lastPathComponent, "doc pages")
        XCTAssertEqual(names(folder), ["doc 1.pdf", "doc 2.pdf", "doc 3.pdf", "doc 4.pdf"])
        for k in 1...4 {
            XCTAssertEqual(pageTexts(folder.appendingPathComponent("doc \(k).pdf")), ["Page \(k)"])
        }
    }

    func testSplitPadsNumbersSoTheySortCorrectly() throws {
        let f = try Fixtures()
        let (folder, files) = try Tools.splitPDF(try f.pdf("big.pdf", pages: 12), folder: nil)
        XCTAssertEqual(files.count, 12)
        XCTAssertEqual(names(folder).first, "big 01.pdf")
        XCTAssertEqual(names(folder).last, "big 12.pdf")
        XCTAssertEqual(pageTexts(folder.appendingPathComponent("big 10.pdf")), ["Page 10"])
    }

    func testSplitSinglePagePDF() throws {
        let f = try Fixtures()
        let (_, files) = try Tools.splitPDF(try f.pdf("one.pdf", pages: 1), folder: nil)
        XCTAssertEqual(files.count, 1)
    }

    func testSplitTwiceUsesNewFolderAndKeepsOriginal() throws {
        let f = try Fixtures()
        let src = try f.pdf("doc.pdf", pages: 2)
        let before = try Data(contentsOf: src)
        let a = try Tools.splitPDF(src, folder: nil).folder, b = try Tools.splitPDF(src, folder: nil).folder
        XCTAssertEqual(a.lastPathComponent, "doc pages"); XCTAssertEqual(b.lastPathComponent, "doc pages 2")
        XCTAssertEqual(try Data(contentsOf: src), before)
    }

    func testSplitHonoursOutputFolder() throws {
        let f = try Fixtures(), dest = try Fixtures()
        let folder = try Tools.splitPDF(try f.pdf("doc.pdf", pages: 2), folder: dest.dir).folder
        XCTAssertEqual(folder.deletingLastPathComponent().standardizedFileURL.path, dest.dir.standardizedFileURL.path)
    }

    func testSplitCorruptPDFFailsAndCreatesNoFolder() throws {
        let f = try Fixtures()
        XCTAssertThrowsError(try Tools.splitPDF(try f.text("bad.pdf", "no"), folder: nil))
        XCTAssertEqual(names(f.dir), ["bad.pdf"])
    }

    // MARK: Extract pages

    func testExtractRangeAndSinglePages() async throws {
        let f = try Fixtures()
        let src = try f.pdf("doc.pdf", pages: 6)
        let out = try await Tools.run(.extractPages, on: src, folder: nil, pages: "1-3,5")
        XCTAssertEqual(pageTexts(out), ["Page 1", "Page 2", "Page 3", "Page 5"])
        XCTAssertEqual(out.lastPathComponent, "doc pages.pdf")
    }

    func testExtractKeepsRequestedOrder() async throws {
        let f = try Fixtures()
        let out = try await Tools.run(.extractPages, on: try f.pdf("doc.pdf", pages: 5), folder: nil, pages: "5, 1")
        XCTAssertEqual(pageTexts(out), ["Page 5", "Page 1"])
    }

    func testExtractWholeDocumentAndLastPage() async throws {
        let f = try Fixtures()
        let src = try f.pdf("doc.pdf", pages: 3)
        let all = try await Tools.run(.extractPages, on: src, folder: nil, pages: "1-3")
        XCTAssertEqual(pageTexts(all).count, 3)
        let last = try await Tools.run(.extractPages, on: src, folder: nil, pages: "3")
        XCTAssertEqual(pageTexts(last), ["Page 3"])
    }

    func testExtractInvalidRangesFailWithoutOutput() async throws {
        let f = try Fixtures()
        let src = try f.pdf("doc.pdf", pages: 3)
        for bad in ["0", "4", "3-1", "1-9", "a", "", "  ", "1-2-3", "-1", "1,x"] {
            do { _ = try await Tools.run(.extractPages, on: src, folder: nil, pages: bad); XCTFail("«\(bad)» doveva fallire") }
            catch { XCTAssertTrue(error is ConversionError, bad) }
        }
        XCTAssertEqual(names(f.dir), ["doc.pdf"], "nessun file creato")
    }

    func testExtractWithoutRangeMeansCancelled() async throws {
        let f = try Fixtures()
        do { _ = try await Tools.run(.extractPages, on: try f.pdf("doc.pdf", pages: 2), folder: nil); XCTFail() }
        catch { XCTAssertTrue(error is ToolCancelled) }
    }

    func testParsePageRanges() throws {
        XCTAssertEqual(try Tools.parsePageRanges("1-3,5", pageCount: 6), [0, 1, 2, 4])
        XCTAssertEqual(try Tools.parsePageRanges(" 2 - 3 , 6 ", pageCount: 6), [1, 2, 5])
        XCTAssertEqual(try Tools.parsePageRanges("2,2", pageCount: 3), [1, 1], "ripetere una pagina è consentito")
        XCTAssertEqual(try Tools.parsePageRanges("1,,2", pageCount: 3), [0, 1])
        XCTAssertThrowsError(try Tools.parsePageRanges("7", pageCount: 6))
    }
}
