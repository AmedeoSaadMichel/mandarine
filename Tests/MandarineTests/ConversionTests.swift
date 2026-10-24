import PDFKit
import XCTest
@testable import Mandarine

final class ConversionTests: XCTestCase {
    // MARK: Images

    func testPNGToEverySystemImageFormat() async throws {
        let f = try Fixtures()
        let src = try f.png()
        for ext in ["jpg", "tiff", "bmp", "gif", "heic", "pdf"] {
            let out = try await convert(src, ext)
            XCTAssertFileExists(out)
            XCTAssertEqual(out.pathExtension, ext)
        }
    }

    func testImageOutputIsReallyThatFormat() async throws {
        let f = try Fixtures()
        let jpg = try await convert(try f.png(), "jpg")
        let magic = try Data(contentsOf: jpg).prefix(3)
        XCTAssertEqual(Array(magic), [0xFF, 0xD8, 0xFF], "firma JPEG")
        let pdf = try await convert(try f.png("b.png"), "pdf")
        XCTAssertNotNil(PDFDocument(url: pdf))
    }

    func testStrongQualityProducesSmallerOrEqualJPEG() async throws {
        let f = try Fixtures()
        // Rumore: la compressione si nota solo su contenuto non uniforme.
        let src = try f.media("noise.png", args: ["-f", "lavfi", "-i", "nullsrc=s=256x256,geq=random(1)*255:128:128", "-frames:v", "1"])
        let a = try await convert(src, "jpg", quality: .balanced)
        let b = try await convert(src, "jpg", quality: .strong)
        let sa = try Data(contentsOf: a).count, sb = try Data(contentsOf: b).count
        XCTAssertLessThanOrEqual(sb, sa)
    }

    func testJPGToPNGRoundTrip() async throws {
        let f = try Fixtures()
        let jpg = try await convert(try f.png(), "jpg")
        let png = try await convert(jpg, "png")
        XCTAssertNotNil(NSImage(contentsOf: png))
    }

    func testWebPEncodingWhenAvailable() async throws {
        let f = try Fixtures()
        guard Converter.canProduce("webp", from: .image) else {
            XCTAssertFalse(Converter.targets(for: try f.png()).contains("webp"), "WebP non va proposto senza encoder")
            throw XCTSkip("ffmpeg senza encoder WebP")
        }
        XCTAssertFileExists(try await convert(try f.png(), "webp"))
    }

    func testUnavailableEncodersAreNotOffered() throws {
        let f = try Fixtures()
        let png = try f.png()
        for ext in ["webp", "avif"] where !Converter.canProduce(ext, from: .image) {
            XCTAssertFalse(Converter.targets(for: png).contains(ext), ext)
        }
    }

    // MARK: Audio / video

    func testAudioConversions() async throws {
        let f = try Fixtures()
        let wav = try f.wav()
        let offered = Converter.targets(for: wav)
        XCTAssertFalse(offered.isEmpty)
        for ext in offered {
            XCTAssertFileExists(try await convert(wav, ext), line: #line)
        }
    }

    func testVideoConversions() async throws {
        let f = try Fixtures()
        let mp4 = try f.mp4()
        for ext in Converter.targets(for: mp4) {
            let out = try await convert(mp4, ext)
            XCTAssertFileExists(out)
        }
    }

    func testMissingFFmpegGivesHelpfulError() async throws {
        // Non si può rimuovere ffmpeg: verifichiamo solo il messaggio previsto quando manca.
        guard Converter.ffmpegPath == nil else { throw XCTSkip("ffmpeg presente") }
        let f = try Fixtures()
        do { _ = try await convert(try f.text("a.wav", "x"), "mp3"); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("brew install ffmpeg")) }
    }

    // MARK: Documents

    func testTextDocumentConversions() async throws {
        let f = try Fixtures()
        let src = try f.text("note.txt", "Ciao mondo")
        for ext in ["rtf", "html", "docx", "pdf"] {
            let out = try await convert(src, ext)
            XCTAssertFileExists(out)
        }
    }

    func testTXTToPDFContainsText() async throws {
        let f = try Fixtures()
        let pdf = try await convert(try f.text("n.txt", "Parola unica zebra"), "pdf")
        XCTAssertTrue(PDFDocument(url: pdf)?.string?.contains("zebra") ?? false)
    }

    func testPDFToTXTExtractsText() async throws {
        let f = try Fixtures()
        let pdf = try await convert(try f.text("n.txt", "Contenuto estraibile"), "pdf")
        let txt = try await convert(pdf, "txt")
        XCTAssertTrue(try String(contentsOf: txt).contains("estraibile"))
    }

    func testPDFToOtherThanTXTIsRejected() async throws {
        let f = try Fixtures()
        let pdf = try await convert(try f.text("n.txt", "x"), "pdf")
        do { _ = try await convert(pdf, "docx"); XCTFail("doveva fallire") }
        catch { XCTAssertTrue(error is ConversionError) }
    }

    func testMarkdownConversions() async throws {
        let f = try Fixtures()
        let md = try f.text("readme.md", "# Titolo\n\nTesto *corsivo*")
        for ext in ["pdf", "docx", "html", "rtf", "txt"] {
            XCTAssertFileExists(try await convert(md, ext))
        }
    }

    func testHTMLToPDFAndDOCX() async throws {
        let f = try Fixtures()
        let html = try f.text("p.html", "<h1>Titolo</h1><p>Ciao <b>mondo</b></p>")
        XCTAssertFileExists(try await convert(html, "pdf"))
        XCTAssertFileExists(try await convert(html, "docx"))
    }

    func testLongDocumentProducesMultiplePDFPages() async throws {
        let f = try Fixtures()
        let long = (1...400).map { "Riga numero \($0) con un po' di testo per riempire la pagina" }.joined(separator: "\n")
        let pdf = try await convert(try f.text("long.txt", long), "pdf")
        XCTAssertGreaterThan(PDFDocument(url: pdf)?.pageCount ?? 0, 1)
    }

    func testEmptyDocumentDoesNotCrash() async throws {
        let f = try Fixtures()
        let out = try await convert(try f.text("empty.txt", ""), "pdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
    }

    // MARK: Spreadsheets

    func testCSVToTSVAndBack() async throws {
        let f = try Fixtures()
        let csv = try f.text("t.csv", "nome,città\nAnna,Roma\nLuca,Milano\n")
        let tsv = try await convert(csv, "tsv")
        XCTAssertEqual(try String(contentsOf: tsv), "nome\tcittà\nAnna\tRoma\nLuca\tMilano")
        let back = try await convert(tsv, "csv")
        XCTAssertEqual(try String(contentsOf: back), "nome,città\nAnna,Roma\nLuca,Milano")
    }

    func testCSVQuotingIsPreserved() async throws {
        let f = try Fixtures()
        let csv = try f.text("q.csv", "a,b\n1,\"x,y\"\n2,\"dice \"\"ciao\"\"\"\n")
        let tsv = try await convert(csv, "tsv")
        // Le virgole non richiedono virgolette in TSV; le doppie virgolette sì.
        let content = try String(contentsOf: tsv)
        XCTAssertTrue(content.contains("1\tx,y"))
        XCTAssertTrue(content.contains("\"dice \"\"ciao\"\"\""))
        let back = try await convert(tsv, "csv")
        let again = try String(contentsOf: back)
        XCTAssertTrue(again.contains("\"x,y\""), "la virgola nel campo va ri-quotata")
    }

    func testCSVWithCRLFLineEndings() async throws {
        let f = try Fixtures()
        let tsv = try await convert(try f.text("w.csv", "a,b\r\n1,2\r\n"), "tsv")
        XCTAssertEqual(try String(contentsOf: tsv), "a\tb\n1\t2")
    }

    // MARK: Errors

    func testUnsupportedExtensionThrows() async throws {
        let f = try Fixtures()
        do { _ = try await convert(try f.text("a.xyz", "x"), "png"); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("Unsupported")) }
    }

    func testMissingSourceFileThrowsAndLeavesNoOutput() async throws {
        let f = try Fixtures()
        let ghost = f.url("ghost.png")
        do { _ = try await convert(ghost, "jpg"); XCTFail() } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.url("ghost.jpg").path))
    }

    func testFilenameWithSpacesAndAccents() async throws {
        let f = try Fixtures()
        let src = try f.png("immagine città 1.png")
        let out = try await convert(src, "jpg")
        XCTAssertEqual(out.lastPathComponent, "immagine città 1.jpg")
        XCTAssertFileExists(out)
    }

    func testCustomOutputFolderIsUsed() async throws {
        let f = try Fixtures(), dest = try Fixtures()
        let out = try await convert(try f.png(), "jpg", folder: dest.dir)
        XCTAssertEqual(out.deletingLastPathComponent().standardizedFileURL.path, dest.dir.standardizedFileURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.url("img.jpg").path))
    }

    func testEveryAdvertisedTargetForSmallFilesConverts() async throws {
        // Matrice: ogni formato proposto dalla ruota per immagini e fogli deve funzionare
        // (salvo gli encoder opzionali di ffmpeg, che saltano il test).
        let f = try Fixtures()
        let optional: Set<String> = []
        for (src, label) in [(try f.png(), "png"), (try f.text("m.csv", "a,b\n1,2"), "csv")] {
            for ext in Converter.targets(for: src) {
                do { XCTAssertFileExists(try await convert(src, ext), line: #line) }
                catch where optional.contains(ext) { continue }
                catch { XCTFail("\(label) → \(ext): \(error.localizedDescription.suffix(150))") }
            }
        }
    }
}
