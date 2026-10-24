import AppKit
import XCTest
@testable import Mandarine

final class WheelTests: XCTestCase {
    private func items(_ kind: WheelKind, _ names: [String]) -> [WheelItem] {
        WheelBuilder.items(kind: kind, files: names.map { URL(fileURLWithPath: "/tmp/\($0)") })
    }

    // MARK: Tools wheel

    func testToolsWheelListsTheApplicableTools() {
        let titles = items(.tools, ["a.png"]).map(\.title)
        XCTAssertEqual(titles, ToolID.available(for: [URL(fileURLWithPath: "/tmp/a.png")]).map(\.shortTitle))
        for expected in ["Compress", "Metadata", "Edit", "Background", "Crop", "Redact", "Resize", "Rotate", "To PDF"] {
            XCTAssertTrue(titles.contains(expected), expected)
        }
    }

    func testToolsWheelItemsOpenWindowsSilently() {
        for item in items(.tools, ["a.png"]) {
            XCTAssertNotNil(item.batch, item.title)
            XCTAssertTrue(item.silent, "aprire una finestra non deve suonare: \(item.title)")
            XCTAssertNotNil(item.symbol, item.title)
        }
    }

    func testToolsWheelIsEmptyForUnsupportedFiles() {
        XCTAssertTrue(items(.tools, ["a.csv"]).isEmpty)
        XCTAssertTrue(items(.tools, ["a.xyz"]).isEmpty)
        XCTAssertTrue(items(.tools, []).isEmpty)
    }

    func testToolsWheelPerCategory() throws {
        func titles(_ names: String...) -> [String] { items(.tools, names).map(\.title) }
        XCTAssertFalse(titles("a.jpg").contains("Trim"))
        XCTAssertTrue(titles("a.jpg", "b.jpg").contains("Collage"))
        XCTAssertFalse(titles("a.jpg", "b.jpg").contains("Crop"), "ritaglio: una sola immagine")
        XCTAssertTrue(titles("a.pdf").contains("Pages")); XCTAssertTrue(titles("a.pdf").contains("Split"))
        XCTAssertTrue(titles("a.pdf", "b.pdf").contains("Merge")); XCTAssertFalse(titles("a.pdf").contains("Merge"))
        if Converter.ffmpegPath != nil {
            XCTAssertTrue(titles("a.mp4").contains("Speed")); XCTAssertTrue(titles("a.mp4").contains("Frames"))
            XCTAssertTrue(titles("a.mp4", "b.mp4").contains("Join"))
            XCTAssertTrue(titles("a.mp3").contains("Normalize")); XCTAssertTrue(titles("a.mp3").contains("Bleep"))
        }
    }

    func testMixedSelectionOnlyOffersCompressAndMetadata() {
        let t = Set(items(.tools, ["a.png", "b.pdf"]).map(\.title))
        XCTAssertTrue(t.isSubset(of: ["Compress", "Metadata"]))
        XCTAssertFalse(t.isEmpty)
    }

    func testPanelFitsEveryToolItemWithoutOverlap() {
        for names in [["a.png"], ["a.png", "b.png"], ["a.mp4"], ["a.mp3"], ["a.pdf"]] {
            let count = items(.tools, names).count
            let size = WheelView.panelSize(for: count)
            let radius = Double(size) / 2 - Double(WheelView.cell) / 2 - 14
            let spacing = 2 * Double.pi * radius / Double(max(count, 1))
            XCTAssertGreaterThanOrEqual(spacing, Double(WheelView.cell) + 4, "\(names): celle sovrapposte")
            XCTAssertLessThan(size, 560)
        }
        XCTAssertLessThan(WheelView.panelSize(for: 3), WheelView.panelSize(for: 12))
    }

    // MARK: Actions wheel

    func testActionsWheelItems() {
        let a = items(.actions, ["a.png"])
        XCTAssertEqual(a.map(\.title), ["Shelf", "Add to Shelf", "Reveal", "Copy files", "Copy paths", "Duplicate", "SHA-256", "Terminal", "Open"])
        XCTAssertTrue(a.allSatisfy { $0.symbol != nil })
        XCTAssertTrue(items(.actions, []).isEmpty)
        let silent = Set(a.filter(\.silent).map(\.title))
        XCTAssertEqual(silent, ["Shelf", "Add to Shelf", "Reveal", "Terminal", "Open"])
    }

    func testActionsWorkOnAnyFileType() {
        XCTAssertEqual(items(.actions, ["a.xyz"]).count, 9)
        XCTAssertEqual(items(.actions, ["a.csv", "b.txt", "c"]).count, 9)
    }

    @MainActor
    func testCopyPathsPutsOnePathPerLine() async throws {
        let list = [URL(fileURLWithPath: "/tmp/uno.png"), URL(fileURLWithPath: "/tmp/due file.pdf")]
        let item = try XCTUnwrap(WheelBuilder.items(kind: .actions, files: list).first { $0.title == "Copy paths" })
        try await XCTUnwrap(item.batch)(list)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "/tmp/uno.png\n/tmp/due file.pdf")
    }

    @MainActor
    func testCopyFilesPutsFileURLsOnThePasteboard() async throws {
        let f = try Fixtures()
        let a = try f.text("a.txt", "x"), b = try f.text("b.txt", "y")
        let item = try XCTUnwrap(WheelBuilder.items(kind: .actions, files: [a, b]).first { $0.title == "Copy files" })
        try await XCTUnwrap(item.batch)([a, b])
        let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        XCTAssertEqual(urls?.map(\.lastPathComponent), ["a.txt", "b.txt"])
    }

    func testSHA256KnownVectors() throws {
        let f = try Fixtures()
        XCTAssertEqual(try FileActions.sha256(try f.text("abc.txt", "abc")), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(try FileActions.sha256(try f.text("empty.txt", "")), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testSHA256StreamsLargeFiles() throws {
        let f = try Fixtures()
        let big = f.url("big.bin")
        let chunk = Data(repeating: 0x61, count: 1 << 20)
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let h = try FileHandle(forWritingTo: big)
        for _ in 0..<5 { h.write(chunk) }          // 5 MB: more than one read chunk
        try h.close()
        let reference = Shell.capture("/usr/bin/shasum", ["-a", "256", big.path]).split(separator: " ").first.map(String.init)
        XCTAssertEqual(try FileActions.sha256(big), reference)
    }

    func testChecksumsFormatMatchesShasum() throws {
        let f = try Fixtures()
        let out = try FileActions.checksums([try f.text("abc.txt", "abc"), try f.text("b.txt", "")])
        XCTAssertEqual(out, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  abc.txt\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  b.txt")
    }

    func testSHA256OfMissingFileThrows() {
        XCTAssertThrowsError(try FileActions.sha256(URL(fileURLWithPath: "/nonexistent/file.bin")))
    }

    @MainActor
    func testSHA256ItemCopiesTheChecksum() async throws {
        let f = try Fixtures()
        let a = try f.text("abc.txt", "abc")
        let item = try XCTUnwrap(WheelBuilder.items(kind: .actions, files: [a]).first { $0.title == "SHA-256" })
        try await XCTUnwrap(item.batch)([a])
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  abc.txt")
    }

    func testDuplicateCreatesACopyBesideTheOriginal() throws {
        let f = try Fixtures()
        let src = try f.text("nota.txt", "ciao")
        let copy = try FileActions.duplicate(src)
        XCTAssertEqual(copy.lastPathComponent, "nota copy.txt")
        XCTAssertEqual(try String(contentsOf: copy), "ciao")
        let second = try FileActions.duplicate(src)
        XCTAssertEqual(second.lastPathComponent, "nota copy 2.txt", "mai sovrascrivere")
        XCTAssertEqual(try String(contentsOf: src), "ciao")
    }

    func testDuplicateWorksWithoutExtensionAndForFolders() throws {
        let f = try Fixtures()
        let bare = try f.text("Makefile", "all:")
        XCTAssertEqual(try FileActions.duplicate(bare).lastPathComponent, "Makefile copy")
        let dir = f.url("cartella")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "x".write(to: dir.appendingPathComponent("dentro.txt"), atomically: true, encoding: .utf8)
        let copy = try FileActions.duplicate(dir)
        XCTAssertEqual(copy.lastPathComponent, "cartella copy")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.appendingPathComponent("dentro.txt").path))
    }

    func testDuplicateItemRunsPerFile() async throws {
        let f = try Fixtures()
        let a = try f.text("a.txt", "1"), b = try f.text("b.txt", "2")
        let item = try XCTUnwrap(WheelBuilder.items(kind: .actions, files: [a, b]).first { $0.title == "Duplicate" })
        XCTAssertNil(item.batch)
        try await item.run(a); try await item.run(b)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.url("a copy.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.url("b copy.txt").path))
    }

    // MARK: Merge item

    func testMergeItemAppearsOnlyForSeveralPDFsAndMergesInOrder() async throws {
        let f = try Fixtures()
        let a = try f.pdf("a.pdf", pages: 1, label: "A"), b = try f.pdf("b.pdf", pages: 2, label: "B")
        XCTAssertTrue(WheelBuilder.items(kind: .tools, files: [a, b]).contains { $0.title == "Merge" })
        XCTAssertFalse(WheelBuilder.items(kind: .tools, files: [a]).contains { $0.title == "Merge" })
        XCTAssertFalse(WheelBuilder.items(kind: .tools, files: [a, try f.quadrants()]).contains { $0.title == "Merge" })
    }

    // MARK: Conversion wheel stays text-only

    func testConversionItemsHaveNoSymbolAndRunPerFile() {
        let c = items(.conversion, ["a.png"])
        XCTAssertFalse(c.isEmpty)
        XCTAssertTrue(c.allSatisfy { $0.symbol == nil && $0.batch == nil && !$0.silent })
    }

    // MARK: Output location

    func testOutputLocationSettings() {
        let s = Settings.shared
        let oldPath = s.outputFolderPath, oldLoc = s.outputLocation
        defer { s.outputFolderPath = oldPath; s.outputLocation = oldLoc }
        s.outputFolderPath = ""
        s.outputLocation = .beside
        XCTAssertNil(s.outputFolder)
        s.outputLocation = .downloads
        XCTAssertEqual(s.outputFolder?.lastPathComponent, "Downloads")
        s.outputLocation = .desktop
        XCTAssertEqual(s.outputFolder?.lastPathComponent, "Desktop")
        s.outputFolderPath = "/tmp"
        XCTAssertEqual(s.outputFolder?.path, "/tmp", "la cartella scelta ha la precedenza")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "outLoc"), "desktop")
    }
}
