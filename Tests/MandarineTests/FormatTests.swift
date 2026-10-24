import AppKit
import PDFKit
import XCTest
@testable import Mandarine

final class FormatTests: XCTestCase {
    private func convertTo(_ src: URL, _ ext: String) async throws -> URL {
        try await Converter.convert(src, to: ext, outputFolder: nil, quality: .balanced)
    }

    private let sample: [[String]] = [["Nome", "Età", "Nota"], ["Anna", "30", "ciao, mondo"], ["Luca", "-4.5", "dice \"sì\""], ["", "007", "riga\ndue"], ["<&>", "1e5", " spazi "]]

    // MARK: Spreadsheets

    func testEverySheetFormatRoundTripsThroughEveryOther() async throws {
        let f = try Fixtures()
        for from in ["csv", "tsv", "xlsx", "ods"] {
            // Each input has its own basename: writing a fixture must not replace a previous conversion.
            let src = f.url("source-\(from).\(from)")
            try SheetIO.write(sample, to: src)
            XCTAssertEqual(try SheetIO.read(src), sample, "scrittura+lettura \(from)")
            for to in ["csv", "tsv", "xlsx", "ods"] where to != from {
                let out = try await convertTo(src, to)
                XCTAssertEqual(try SheetIO.read(out), sample, "\(from) → \(to)")
            }
        }
    }

    func testSheetTargets() {
        XCTAssertEqual(Set(Converter.targets(for: URL(fileURLWithPath: "/tmp/a.csv"))), ["tsv", "xlsx", "ods"])
        XCTAssertEqual(Set(Converter.targets(for: URL(fileURLWithPath: "/tmp/a.xlsx"))), ["csv", "tsv", "ods"])
        XCTAssertEqual(Category.of(URL(fileURLWithPath: "/tmp/a.XLSX")), .spreadsheet)
    }

    func testXLSXPackageStructure() throws {
        let f = try Fixtures()
        let x = f.url("t.xlsx")
        try SheetIO.write([["a", "1"]], to: x)
        let names = Archive.entries(x)
        for required in ["[Content_Types].xml", "_rels/.rels", "xl/workbook.xml", "xl/_rels/workbook.xml.rels", "xl/worksheets/sheet1.xml"] { XCTAssertTrue(names.contains(required), required) }
        XCTAssertTrue(Shell.capture("/usr/bin/unzip", ["-t", x.path]).contains("No errors"))
        let sheet = String(decoding: Archive.read(x, "xl/worksheets/sheet1.xml")!, as: UTF8.self)
        XCTAssertTrue(sheet.contains("<c r=\"B1\"><v>1</v></c>"), "i numeri sono numeri")
        XCTAssertTrue(sheet.contains("t=\"inlineStr\""), "il testo è testo")
        for xml in names where xml.hasSuffix(".xml") || xml.hasSuffix(".rels") {
            XCTAssertNoThrow(try XMLWalker.parse(Archive.read(x, xml)!, walker: XMLWalker()), "XML ben formato: \(xml)")
        }
    }

    func testODSPackageStructure() throws {
        let f = try Fixtures()
        let o = f.url("t.ods")
        try SheetIO.write([["a", "1"]], to: o)
        XCTAssertEqual(Archive.entries(o).first, "mimetype", "il mimetype deve essere il primo")
        XCTAssertEqual(String(decoding: Archive.read(o, "mimetype")!, as: UTF8.self), "application/vnd.oasis.opendocument.spreadsheet")
        let listing = Shell.capture("/usr/bin/unzip", ["-v", o.path])
        XCTAssertTrue(listing.contains("Stored"), "mimetype non compresso")
        XCTAssertTrue(Shell.capture("/usr/bin/unzip", ["-t", o.path]).contains("No errors"))
        XCTAssertNoThrow(try XMLWalker.parse(Archive.read(o, "content.xml")!, walker: XMLWalker()))
    }

    func testReadXLSXWithSharedStringsBooleansAndSparseCells() throws {
        let f = try Fixtures()
        let head = #"<?xml version="1.0" encoding="UTF-8"?>"#
        let shared = head + #"<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><si><t>Ciao</t></si><si><r><t>Ric</t></r><r><t>co</t></r></si><si><t>Mondo</t><rPh><t>XX</t></rPh></si></sst>"#
        let sheet = head + #"<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="C1" t="s"><v>1</v></c></row><row r="3"><c r="B3" t="b"><v>1</v></c><c r="C3"><f>1+1</f><v>2</v></c><c r="D3" t="s"><v>2</v></c></row></sheetData></worksheet>"#
        let x = f.url("shared.xlsx")
        try Archive.write([("[Content_Types].xml", Data(head.utf8)), ("xl/workbook.xml", Data((head + "<workbook/>").utf8)),
                           ("xl/sharedStrings.xml", Data(shared.utf8)), ("xl/worksheets/sheet1.xml", Data(sheet.utf8))], to: x)
        XCTAssertEqual(try SheetIO.read(x), [["Ciao", "", "Ricco", ""], ["", "", "", ""], ["", "TRUE", "2", "Mondo"]])
    }

    func testReadODSWithRepeatedCellsRowsAndTypes() throws {
        let f = try Fixtures()
        let content = #"<?xml version="1.0"?><office:document-content xmlns:office="o" xmlns:table="t" xmlns:text="x"><office:body><office:spreadsheet><table:table><table:table-row><table:table-cell office:value-type="string"><text:p>x</text:p></table:table-cell><table:table-cell table:number-columns-repeated="2" office:value-type="float" office:value="7"><text:p>7,00</text:p></table:table-cell></table:table-row><table:table-row table:number-rows-repeated="2"><table:table-cell office:value-type="string"><text:p>r</text:p></table:table-cell></table:table-row><table:table-row><table:table-cell table:number-columns-repeated="1000"/></table:table-row></table:table><table:table><table:table-row><table:table-cell office:value-type="string"><text:p>secondo foglio</text:p></table:table-cell></table:table-row></table:table></office:spreadsheet></office:body></office:document-content>"#
        let o = f.url("rep.ods")
        try Archive.write([("mimetype", Data("application/vnd.oasis.opendocument.spreadsheet".utf8)), ("content.xml", Data(content.utf8))], first: ["mimetype"], to: o)
        let rows = try SheetIO.read(o)
        XCTAssertEqual(rows, [["x", "7", "7"], ["r", "", ""], ["r", "", ""]], "celle ripetute espanse, righe vuote finali tolte, solo il primo foglio")
    }

    func testLargeRepeatedODSRowsDoNotExplode() throws {
        let f = try Fixtures()
        let content = #"<?xml version="1.0"?><office:document-content xmlns:office="o" xmlns:table="t" xmlns:text="x"><office:body><office:spreadsheet><table:table><table:table-row><table:table-cell office:value-type="string"><text:p>a</text:p></table:table-cell></table:table-row><table:table-row table:number-rows-repeated="1048000"><table:table-cell table:number-columns-repeated="16000"/></table:table-row></table:table></office:spreadsheet></office:body></office:document-content>"#
        let o = f.url("big.ods")
        try Archive.write([("mimetype", Data("application/vnd.oasis.opendocument.spreadsheet".utf8)), ("content.xml", Data(content.utf8))], first: ["mimetype"], to: o)
        XCTAssertEqual(try SheetIO.read(o), [["a"]])
    }

    func testSheetEdgeCases() async throws {
        let f = try Fixtures()
        XCTAssertEqual(SheetIO.columnName(0), "A"); XCTAssertEqual(SheetIO.columnName(25), "Z"); XCTAssertEqual(SheetIO.columnName(26), "AA"); XCTAssertEqual(SheetIO.columnName(701), "ZZ"); XCTAssertEqual(SheetIO.columnName(702), "AAA")
        XCTAssertEqual(SheetIO.position(of: "AB12")?.col, 27); XCTAssertEqual(SheetIO.position(of: "AB12")?.row, 11); XCTAssertNil(SheetIO.position(of: "12"))
        for n in ["0", "12", "-3.5", "0.25"] { XCTAssertTrue(SheetIO.isPlainNumber(n), n) }
        for n in ["007", "1e5", "+1", "", "1.", ".5", "1,5", "abc"] { XCTAssertFalse(SheetIO.isPlainNumber(n), n) }
        XCTAssertEqual(SheetIO.xmlEscape("a<b>&\"\u{0}\u{1}"), "a&lt;b&gt;&amp;&quot;")
        let empty = f.url("e.csv"); try "".write(to: empty, atomically: true, encoding: .utf8)
        let x = try await convertTo(empty, "xlsx")
        XCTAssertEqual(try SheetIO.read(x), [])
        let wide = [(0..<30).map { "c\($0)" }]
        try SheetIO.write(wide, to: f.url("w.xlsx"))
        XCTAssertEqual(try SheetIO.read(f.url("w.xlsx")), wide, "oltre la colonna Z")
    }

    func testCSVEncodingsAndBOM() throws {
        let f = try Fixtures()
        let bom = f.url("bom.csv"); try Data([0xEF, 0xBB, 0xBF] + Array("a,b\n1,2".utf8)).write(to: bom)
        XCTAssertEqual(try SheetIO.read(bom), [["a", "b"], ["1", "2"]], "il BOM non finisce nella prima cella")
        let latin = f.url("latin.csv"); try Data("città;perché\n".utf8.map { $0 }).write(to: latin)
        try "citt\u{E0},perch\u{E9}".data(using: .windowsCP1252)!.write(to: latin)
        XCTAssertEqual(try SheetIO.read(latin), [["città", "perché"]], "Windows-1252")
    }

    func testBrokenSpreadsheetsFailCleanly() async throws {
        let f = try Fixtures()
        for name in ["bad.xlsx", "bad.ods"] {
            let bad = try f.text(name, "non sono uno zip")
            do { _ = try await convertTo(bad, "csv"); XCTFail(name) } catch { XCTAssertTrue(error is ConversionError, name) }
        }
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: f.dir.path)), ["bad.xlsx", "bad.ods"], "nessun file residuo")
    }

    func testXLSXOpensInAPythonReaderIfAvailable() throws {
        let f = try Fixtures()
        let x = f.url("py.xlsx")
        try SheetIO.write(sample, to: x)
        let script = "import zipfile,sys,xml.dom.minidom as m\nz=zipfile.ZipFile(sys.argv[1])\nassert z.testzip() is None\nfor n in z.namelist():\n    if n.endswith('.xml') or n.endswith('.rels'): m.parseString(z.read(n))\nprint('ok')"
        let out = Shell.capture("/usr/bin/python3", ["-c", script, x.path])
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "ok")
    }

    // MARK: EPUB

    private let book = "Primo paragrafo con è, à e &.\n\nSecondo paragrafo\nsu due righe.\n\nTerzo <b>tag</b> letterale."

    func testEPUBWriteAndReadRoundTrip() throws {
        let f = try Fixtures()
        let e = f.url("libro.epub")
        try EPUBOps.write(text: book, title: "Il libro", to: e)
        let text = try EPUBOps.readText(e)
        XCTAssertTrue(text.contains("Primo paragrafo con è, à e &."))
        XCTAssertTrue(text.contains("Terzo <b>tag</b> letterale."), "il testo non viene scambiato per markup")
        XCTAssertTrue(text.contains("Il libro"), "il titolo è un capitolo")
    }

    func testEPUBPackageStructure() throws {
        let f = try Fixtures()
        let e = f.url("s.epub")
        try EPUBOps.write(text: "x", title: "T & T", to: e)
        XCTAssertEqual(Archive.entries(e).first, "mimetype")
        XCTAssertEqual(String(decoding: Archive.read(e, "mimetype")!, as: UTF8.self), "application/epub+zip")
        XCTAssertTrue(Shell.capture("/usr/bin/unzip", ["-v", e.path]).contains("Stored"))
        for p in ["META-INF/container.xml", "OEBPS/content.opf", "OEBPS/nav.xhtml", "OEBPS/chapter.xhtml"] {
            XCTAssertNoThrow(try XMLWalker.parse(Archive.read(e, p)!, walker: XMLWalker()), "XML valido: \(p)")
        }
        XCTAssertTrue(String(decoding: Archive.read(e, "OEBPS/content.opf")!, as: UTF8.self).contains("T &amp; T"))
    }

    func testReadingOrderFollowsTheSpine() throws {
        let f = try Fixtures()
        let h = #"<?xml version="1.0"?>"#
        let container = h + #"<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>"#
        let opf = h + #"<package xmlns="http://www.idpf.org/2007/opf"><manifest><item id="a" href="a%20b.xhtml"/><item id="b" href="b.xhtml"/><item id="c" href="c.xhtml"/></manifest><spine><itemref idref="c"/><itemref idref="a"/><itemref idref="b"/></spine></package>"#
        func page(_ s: String) -> Data { Data("<html><head><title>no</title><style>p{}</style></head><body><p>\(s)</p></body></html>".utf8) }
        let e = f.url("order.epub")
        try Archive.write([("mimetype", Data("application/epub+zip".utf8)), ("META-INF/container.xml", Data(container.utf8)), ("OPS/book.opf", Data(opf.utf8)),
                           ("OPS/a b.xhtml", page("Uno")), ("OPS/b.xhtml", page("Due")), ("OPS/c.xhtml", page("Tre"))], first: ["mimetype"], to: e)
        XCTAssertEqual(try EPUBOps.readText(e), "Tre\n\nUno\n\nDue")
    }

    func testHTMLTextConversion() {
        XCTAssertEqual(HTMLText.convert("<p>Uno</p><p>Due<br/>tre</p>"), "Uno\n\nDue\ntre")
        XCTAssertEqual(HTMLText.convert("<h1>T</h1><script>x()</script><style>a{}</style><p>&lt;ok&gt; &amp; &#233; &#xE8; &quot;q&quot;</p>"), "T\n\n<ok> & é è \"q\"")
        XCTAssertEqual(HTMLText.convert("<p>a&nbsp;b</p>\n\n\n\n<p>c</p>"), "a b\n\nc")
        XCTAssertEqual(HTMLText.convert(""), "")
        XCTAssertEqual(HTMLText.convert("&amp;lt;"), "&lt;", "niente doppia decodifica")
    }

    func testEPUBToEveryDocumentFormat() async throws {
        let f = try Fixtures()
        let e = f.url("libro.epub")
        try EPUBOps.write(text: book, title: "Libro", to: e)
        XCTAssertEqual(Set(Converter.targets(for: e)), ["txt", "html", "md", "pdf", "rtf", "docx"])
        for ext in Converter.targets(for: e) {
            let out = try await convertTo(e, ext)
            XCTAssertGreaterThan((try? Data(contentsOf: out).count) ?? 0, 50, ext)
        }
        let txt = try String(contentsOf: try await convertTo(e, "txt"))
        XCTAssertTrue(txt.contains("Secondo paragrafo"))
        let pdf = try await convertTo(e, "pdf")
        XCTAssertTrue(PDFDocument(url: pdf)?.string?.contains("Secondo paragrafo") ?? false)
    }

    func testEveryTextualFormatToEPUBAndBack() async throws {
        let f = try Fixtures()
        let txt = try f.text("src.txt", book)
        let docx = try await convertTo(txt, "docx"), rtf = try await convertTo(txt, "rtf"), html = try await convertTo(txt, "html")
        let md = try f.text("note.md", "# Titolo\n\nParagrafo *uno*.\n\nParagrafo due.")
        for src in [txt, docx, rtf, html, md] {
            let epub = try await convertTo(src, "epub")
            XCTAssertEqual(epub.pathExtension, "epub")
            let back = try EPUBOps.readText(epub)
            XCTAssertTrue(back.contains(src.pathExtension == "md" ? "Paragrafo due." : "Secondo paragrafo"), "\(src.pathExtension): \(back.prefix(80))")
        }
    }

    func testEmptyDocumentToEPUBFailsAndPDFToEPUBIsNotOffered() async throws {
        let f = try Fixtures()
        do { _ = try await convertTo(try f.text("e.txt", "  \n"), "epub"); XCTFail() } catch { XCTAssertTrue(error is ConversionError) }
        XCTAssertFalse(Converter.targets(for: URL(fileURLWithPath: "/tmp/a.pdf")).contains("epub"))
        XCTAssertEqual(Converter.targets(for: URL(fileURLWithPath: "/tmp/a.pdf")), ["txt"])
    }

    func testBrokenEPUBsFailCleanly() async throws {
        let f = try Fixtures()
        do { _ = try await convertTo(try f.text("x.epub", "no"), "txt"); XCTFail() } catch { XCTAssertTrue(error is ConversionError) }
        let hollow = f.url("hollow.epub")
        try Archive.write([("mimetype", Data("application/epub+zip".utf8)), ("META-INF/container.xml", Data(#"<container><rootfiles><rootfile full-path="x.opf"/></rootfiles></container>"#.utf8))], first: ["mimetype"], to: hollow)
        do { _ = try await convertTo(hollow, "txt"); XCTFail() } catch { XCTAssertTrue(error is ConversionError) }
    }

    // MARK: RTFD

    func testRTFDOutputAndInput() async throws {
        let f = try Fixtures()
        let rtfd = try await convertTo(try f.text("n.txt", "Contenuto rtfd"), "rtfd")
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: rtfd.path, isDirectory: &isDir)); XCTAssertTrue(isDir.boolValue, "RTFD è un pacchetto")
        let back = try String(contentsOf: try await convertTo(rtfd, "txt"))
        XCTAssertTrue(back.contains("Contenuto rtfd"))
        XCTAssertEqual(Category.of(rtfd), .document)
        let fromMD = try await convertTo(try f.text("m.md", "# Ciao"), "rtfd")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fromMD.path))
    }

    // MARK: Document matrix

    func testDocumentTargetMatrix() {
        XCTAssertEqual(Converter.documentTargets(from: "pdf"), ["txt"])
        XCTAssertFalse(Converter.documentTargets(from: "md").contains("md"))
        XCTAssertTrue(Converter.documentTargets(from: "docx").contains("epub"))
        XCTAssertFalse(Converter.documentTargets(from: "html").contains("html"))
        XCTAssertEqual(Set(Converter.documentTargets(from: "txt")), ["pdf", "rtf", "html", "docx", "md", "epub", "rtfd"])
    }

    func testEveryAdvertisedDocumentAndSheetRouteWorks() async throws {
        let f = try Fixtures()
        let txt = try f.text("base.txt", book)
        var sources: [URL] = [txt, try f.text("m.md", "# T\n\nCorpo"), try await convertTo(txt, "docx"), try await convertTo(txt, "rtf"), try await convertTo(txt, "html"),
                              try await convertTo(txt, "rtfd"), try await convertTo(txt, "epub"), try await convertTo(txt, "pdf")]
        for ext in ["csv", "tsv", "xlsx", "ods"] { let u = f.url("sheet.\(ext)"); try SheetIO.write(sample, to: u); sources.append(u) }
        var failures: [String] = []
        var routes = 0
        for src in sources {
            for ext in Converter.targets(for: src) {
                routes += 1
                do { _ = try await convertTo(src, ext) } catch { failures.append("\(src.pathExtension) → \(ext): \(error.localizedDescription.prefix(80))") }
            }
        }
        XCTAssertGreaterThan(routes, 50)
        XCTAssertEqual(failures, [], "rotte pubblicizzate che falliscono")
    }

    // MARK: SVG

    private func svg(_ f: Fixtures, _ name: String = "a.svg", width: Int = 200, height: Int = 100) throws -> URL {
        try f.text(name, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(width)\" height=\"\(height)\" viewBox=\"0 0 \(width) \(height)\"><rect x=\"0\" y=\"0\" width=\"\(width / 2)\" height=\"\(height)\" fill=\"#ff0000\"/></svg>")
    }

    func testSVGIsRecognisedAsAnImageSource() throws {
        let f = try Fixtures()
        XCTAssertEqual(Category.of(try svg(f)), .image)
        XCTAssertFalse(Converter.targets(for: try svg(f)).contains("svg"))
        XCTAssertTrue(Converter.targets(for: try svg(f)).contains("png"))
    }

    func testSVGRendersAtOneThousandPixelsKeepingRatioAndTransparency() async throws {
        let f = try Fixtures()
        let png = try await convertTo(try svg(f), "png")
        let (w, h) = try imageSize(png)
        XCTAssertEqual(w, 1024); XCTAssertEqual(h, 512)
        XCTAssertTrue(isClose(try pixel(png, 100, 256), red), "la metà sinistra è rossa")
        let img = try ImageOps.load(png).image
        XCTAssertTrue(ImageOps.hasAlpha(img))
        XCTAssertEqual(CGImageGetAlphaAt(img, 900, 256), 0, "la metà destra è trasparente")
    }

    func testSVGToJPEGHasWhiteBackgroundAndToPDFWorks() async throws {
        let f = try Fixtures()
        let jpg = try await convertTo(try svg(f), "jpg")
        let p = try pixel(jpg, 900, 256)
        XCTAssertGreaterThan(p.r, 235); XCTAssertGreaterThan(p.g, 235); XCTAssertGreaterThan(p.b, 235)
        let pdf = try await convertTo(try svg(f, "b.svg"), "pdf")
        XCTAssertEqual(PDFDocument(url: pdf)?.pageCount, 1)
    }

    func testSVGWithMaxDimensionAndBrokenSVG() async throws {
        let f = try Fixtures()
        let out = try await Converter.convert(try svg(f), to: "png", outputFolder: nil, quality: .balanced, prefs: FormatPrefs(maxDimension: 300))
        XCTAssertEqual(try imageSize(out).0, 300)
        do { _ = try await convertTo(try f.text("bad.svg", "<svg"), "png"); XCTFail() } catch { XCTAssertTrue(error is ConversionError) }
    }

    func testImageToolsWorkOnSVGAndWriteAPNG() async throws {
        let f = try Fixtures()
        let outs = try await runTool(.resizeImage, [try svg(f)], ["mode": .text("max"), "max": .number(100)])
        XCTAssertEqual(outs[0].pathExtension, "png")
        XCTAssertEqual(try imageSize(outs[0]).0, 100)
    }
}

private func CGImageGetAlphaAt(_ image: CGImage, _ x: Int, _ y: Int) -> Int {
    let ctx = ImageOps.context(1, 1)
    ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
    return Int(ctx.data!.assumingMemoryBound(to: UInt8.self)[3])
}
