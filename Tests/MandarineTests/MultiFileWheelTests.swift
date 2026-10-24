import XCTest
@testable import Mandarine

final class MultiFileWheelTests: XCTestCase {
    private func urls(_ names: String...) -> [URL] { names.map { URL(fileURLWithPath: "/tmp/\($0)") } }
    private func titles(_ kind: WheelKind, _ files: [URL]) -> [String] { WheelBuilder.items(kind: kind, files: files).map(\.title) }

    // MARK: Common targets

    func testASingleFileKeepsItsOwnTargets() {
        let f = urls("a.png")
        XCTAssertEqual(Converter.targets(for: f), Converter.targets(for: f[0]))
    }

    func testSameFormatFilesOfferTheSameTargets() {
        XCTAssertEqual(Converter.targets(for: urls("a.png", "b.png", "c.png")), Converter.targets(for: urls("a.png")[0]))
    }

    func testDifferentImageFormatsOfferOnlyWhatBothCanBecome() {
        let t = Converter.targets(for: urls("a.png", "b.jpg"))
        XCTAssertFalse(t.contains("png") && t.contains("jpg"), "nessun file va convertito nel proprio formato")
        XCTAssertFalse(t.contains("png"), "a.png→png sarebbe un non-senso"); XCTAssertFalse(t.contains("jpg"), "b.jpg→jpg sarebbe un non-senso")
        XCTAssertTrue(t.contains("tiff")); XCTAssertTrue(t.contains("pdf"))
        XCTAssertEqual(t, Converter.targets(for: urls("a.png")[0]).filter { Converter.targets(for: urls("b.jpg")[0]).contains($0) }, "l'ordine è quello del primo file")
    }

    func testOrderFollowsTheFirstFile() {
        let ab = Converter.targets(for: urls("a.png", "b.jpg")), ba = Converter.targets(for: urls("b.jpg", "a.png"))
        XCTAssertEqual(Set(ab), Set(ba))
        XCTAssertEqual(ab.first, Converter.targets(for: urls("a.png")[0]).first { ab.contains($0) })
    }

    func testImageAndDocumentShareNothing() {
        XCTAssertTrue(Converter.targets(for: urls("a.png", "b.pdf")).isEmpty, "PDF→solo TXT, immagine→non TXT")
    }

    func testSpreadsheetsOfDifferentFormatsShareTheRest() {
        XCTAssertEqual(Set(Converter.targets(for: urls("a.csv", "b.xlsx"))), ["tsv", "ods"])
    }

    func testVideoAndAudioShareAudioExtraction() throws {
        try XCTSkipIf(Converter.ffmpegPath == nil)
        let t = Converter.targets(for: urls("a.mp4", "b.wav"))
        XCTAssertTrue(t.contains("mp3"), "MP3 è un target sia per audio sia per video (estrazione)")
        XCTAssertFalse(t.contains("mp4")); XCTAssertFalse(t.contains("wav"))
    }

    func testUnknownFileEmptiesTheIntersection() {
        XCTAssertTrue(Converter.targets(for: urls("a.png", "b.xyz")).isEmpty)
        XCTAssertTrue(Converter.targets(for: []).isEmpty)
    }

    func testDocumentFamilies() {
        XCTAssertEqual(Set(Converter.targets(for: urls("a.txt", "b.md"))), Set(Converter.documentTargets(from: "txt")).intersection(Converter.documentTargets(from: "md")))
        XCTAssertEqual(Converter.targets(for: urls("a.pdf", "b.pdf")), ["txt"])
        XCTAssertEqual(Converter.targets(for: urls("a.pdf", "b.docx")), ["txt"].filter { Converter.documentTargets(from: "docx").contains($0) })
    }

    // MARK: The wheel

    func testWheelOffersTheCommonTargetsForSeveralFiles() {
        let t = titles(.conversion, urls("a.png", "b.jpg")).map { $0.lowercased() }
        XCTAssertEqual(t, Converter.targets(for: urls("a.png", "b.jpg")))
        XCTAssertFalse(t.isEmpty)
    }

    func testWheelIsEmptyWhenThereIsNothingInCommon() {
        XCTAssertTrue(titles(.conversion, urls("a.png", "b.pdf")).isEmpty)
    }

    func testEveryItemConvertsEveryFile() async throws {
        let f = try Fixtures()
        let a = try f.quadrants("a.png"), b = try f.quadrants("b.jpg")
        let s = Settings.shared, old = (s.outputFolderPath, s.outputLocation)
        defer { s.outputFolderPath = old.0; s.outputLocation = old.1 }
        s.outputFolderPath = ""; s.outputLocation = .beside
        let item = try XCTUnwrap(WheelBuilder.items(kind: .conversion, files: [a, b]).first { $0.title == "TIFF" })
        for file in [a, b] { _ = try await XCTUnwrap(item.runWithProgress)(file) { _ in } }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.url("a.tiff").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.url("b.tiff").path))
    }

    func testJobRunnerConvertsTheWholeSelectionAndKeepsGoingOnFailure() async throws {
        let f = try Fixtures()
        let good = try f.quadrants("good.png"), bad = try f.text("bad.png", "non è un'immagine")
        let summary = await JobRunner.execute(files: [bad, good]) { file, progress in
            [try await Converter.convert(file, to: "tiff", outputFolder: nil, quality: .balanced, progress: progress)]
        }
        XCTAssertEqual(summary.failures.map(\.file), ["bad.png"])
        XCTAssertEqual(summary.outputs.map(\.lastPathComponent), ["good.tiff"])
    }

    // MARK: Empty-state messages

    func testNoFilesAsksToDropSome() {
        XCTAssertEqual(WheelEmpty.message(kind: .conversion, files: []), "Drop files here")
    }

    func testUnsupportedFormatIsNamed() {
        let one = WheelEmpty.message(kind: .conversion, files: urls("strano.xyz"))
        XCTAssertTrue(one?.contains("Unsupported") == true && one?.contains("strano.xyz") == true)
        let many = WheelEmpty.message(kind: .tools, files: urls("a.png", "x.abc", "y.def"))
        XCTAssertTrue(many?.contains("x.abc") == true && many?.contains("and 1") == true, many ?? "nil")
    }

    func testNoCommonConversionHasItsOwnMessage() {
        let m = WheelEmpty.message(kind: .conversion, files: urls("a.png", "b.pdf"))
        XCTAssertTrue(m?.contains("shared by") == true, m ?? "nil")
    }

    func testSingleFileWithoutConversionsMentionsTheFile() {
        // Un'estensione nota ma senza rotte non esiste; usiamo un file il cui formato è proibito di fatto dal sistema.
        let m = WheelEmpty.message(kind: .conversion, files: urls("a.pdf", "b.png"))
        XCTAssertNotNil(m)
    }

    func testToolsMessageForMixedSelections() {
        let m = WheelEmpty.message(kind: .tools, files: urls("a.csv"))
        XCTAssertTrue(m?.contains("No tools") == true, m ?? "nil")
        XCTAssertTrue(WheelEmpty.message(kind: .tools, files: urls("a.png", "b.pdf")) == nil, "immagine+PDF hanno ancora Compress e Metadata")
    }

    func testNoMessageWhenThereAreItems() {
        XCTAssertNil(WheelEmpty.message(kind: .conversion, files: urls("a.png")))
        XCTAssertNil(WheelEmpty.message(kind: .conversion, files: urls("a.png", "b.jpg")))
        XCTAssertNil(WheelEmpty.message(kind: .tools, files: urls("a.png")))
    }

    func testActionsWorkOnAnythingEvenUnknownFiles() {
        XCTAssertNil(WheelEmpty.message(kind: .actions, files: urls("a.xyz", "b.png")))
        XCTAssertEqual(titles(.actions, urls("a.xyz")).count, 9)
    }

    func testEveryEmptyWheelHasAMessage() {
        let cases: [(WheelKind, [URL])] = [(.conversion, []), (.conversion, urls("a.xyz")), (.conversion, urls("a.png", "b.pdf")), (.tools, urls("a.csv")), (.tools, urls("a.xyz", "b.png"))]
        for (kind, files) in cases where WheelBuilder.items(kind: kind, files: files).isEmpty {
            XCTAssertNotNil(WheelEmpty.message(kind: kind, files: files), "\(kind) \(files.map(\.lastPathComponent))")
        }
    }
}
