import AppKit
import XCTest
@testable import Mandarine

final class ReliabilityTests: XCTestCase {
    private func ods(_ content: String) throws -> (Fixtures, URL) {
        let f = try Fixtures(), url = f.url("repeat.ods")
        let xml = "<office:document-content xmlns:office=\"o\" xmlns:table=\"t\" xmlns:text=\"x\"><office:body><office:spreadsheet><table:table>" + content + "</table:table></office:spreadsheet></office:body></office:document-content>"
        try Archive.write([("content.xml", Data(xml.utf8))], to: url)
        return (f, url)
    }

    func testODSRetains1001RepeatedRows() throws {
        let (f, url) = try ods("<table:table-row table:number-rows-repeated=\"1001\"><table:table-cell><text:p>hello</text:p></table:table-cell></table:table-row>")
        withExtendedLifetime(f) {
            XCTAssertEqual(try? SheetIO.read(url).count, 1001)
        }
    }

    func testODSRetainsRepeatedColumnsAndInteriorBlanks() throws {
        let (f, url) = try ods("<table:table-row><table:table-cell table:number-columns-repeated=\"65\"><text:p>a</text:p></table:table-cell><table:table-cell table:number-columns-repeated=\"300\"/><table:table-cell><text:p>last</text:p></table:table-cell></table:table-row>")
        defer { withExtendedLifetime(f) {} }
        let row = try XCTUnwrap(SheetIO.read(url).first)
        XCTAssertEqual(row.count, 366)
        XCTAssertEqual(row[64], "a"); XCTAssertEqual(row[364], ""); XCTAssertEqual(row[365], "last")
    }

    func testODSRejectsExcessiveNonemptyRepetitions() throws {
        let (f, url) = try ods("<table:table-row table:number-rows-repeated=\"100001\"><table:table-cell><text:p>hello</text:p></table:table-cell></table:table-row>")
        defer { withExtendedLifetime(f) {} }
        XCTAssertThrowsError(try SheetIO.read(url))
    }

    func testODSRejectsNegativeRepetition() throws {
        let (f, url) = try ods("<table:table-row><table:table-cell table:number-columns-repeated=\"-1\"><text:p>x</text:p></table:table-cell></table:table-row>")
        defer { withExtendedLifetime(f) {} }
        XCTAssertThrowsError(try SheetIO.read(url))
    }

    func testODSInteriorRepeatedBlankRowsKeepTheirPositions() throws {
        let (f, url) = try ods("<table:table-row><table:table-cell><text:p>first</text:p></table:table-cell></table:table-row><table:table-row table:number-rows-repeated=\"1500\"><table:table-cell/></table:table-row><table:table-row><table:table-cell><text:p>last</text:p></table:table-cell></table:table-row>")
        defer { withExtendedLifetime(f) {} }
        let rows = try SheetIO.read(url)
        XCTAssertEqual(rows.count, 1502)
        XCTAssertEqual(rows[1501], ["last"])
    }

    func testDelimitedImportRejectsTooManyColumns() throws {
        let f = try Fixtures()
        let src = try f.text("wide.csv", String(repeating: ",", count: SheetIO.maxColumns))
        XCTAssertThrowsError(try SheetIO.read(src))
    }

    func testIndependentBatchToolsKeepEachSourceFolder() async throws {
        let a = try Fixtures(), b = try Fixtures()
        let first = try a.png(), second = try b.png()
        let values = ToolValues(defaultsFor: ToolEngine.params(for: .rotateImage, files: [first, second]))
        let outputs = try await ToolEngine.run(.rotateImage, files: [first, second], values: values, folder: nil)
        XCTAssertEqual(outputs.count, 2)
        XCTAssertEqual(outputs[0].deletingLastPathComponent().resolvingSymlinksInPath(), a.dir.resolvingSymlinksInPath())
        XCTAssertEqual(outputs[1].deletingLastPathComponent().resolvingSymlinksInPath(), b.dir.resolvingSymlinksInPath())
    }

    func testXLSXNegativeSharedStringIndexFailsWithoutCrash() throws {
        let f = try Fixtures(), url = f.url("bad.xlsx")
        try Archive.write([("xl/workbook.xml", Data("<workbook/>".utf8)),
                           ("xl/sharedStrings.xml", Data("<sst><si><t>hello</t></si></sst>".utf8)),
                           ("xl/worksheets/sheet1.xml", Data("<worksheet><sheetData><row r=\"1\"><c r=\"A1\" t=\"s\"><v>-1</v></c></row></sheetData></worksheet>".utf8))], to: url)
        XCTAssertThrowsError(try SheetIO.read(url))
    }

    func testSparseSheetCannotAllocateAnUnboundedRectangle() {
        XCTAssertThrowsError(try SheetIO.dense([99_999: [16_383: "x"]]))
        XCTAssertNil(SheetIO.position(of: "ZZZZZZZZZZZZ99999999999999999999999"))
        XCTAssertNil(SheetIO.position(of: "é1"))
    }

    func testParallelConversionsPreserveAllOutputsAndOriginal() async throws {
        let f = try Fixtures(), src = try f.text("same.csv", "a,b\n1,2")
        let existing = try f.text("same.tsv", "KEEP")
        let outputs = try await withThrowingTaskGroup(of: URL.self) { group in
            for _ in 0..<12 {
                group.addTask { try await Converter.convert(src, to: "tsv", outputFolder: nil, quality: .balanced) }
            }
            var urls: [URL] = []
            for try await url in group { urls.append(url) }
            return urls
        }
        XCTAssertEqual(Set(outputs.map(\.path)).count, 12)
        XCTAssertEqual(try String(contentsOf: existing), "KEEP")
        for output in outputs { XCTAssertEqual(try String(contentsOf: output), "a\tb\n1\t2") }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: f.dir.path).contains { $0.hasPrefix(".mandarine-") })
    }

    func testFailedTransactionRemovesPartialFiles() async throws {
        let f = try Fixtures(), src = try f.text("src.txt", "source")
        do {
            _ = try await OutputStore.transaction(source: src, folder: nil) { stage in
                try Data("partial".utf8).write(to: stage.appendingPathComponent("partial.txt"))
                throw ConversionError(message: "failure")
            }
            XCTFail("Expected failure")
        } catch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.dir.path), ["src.txt"])
    }

    func testPublishingDirectoryRemapsNestedOutputs() async throws {
        let f = try Fixtures(), src = try f.text("src.txt", "source")
        let old = f.url("parts")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: false)
        let outputs = try await OutputStore.transaction(source: src, folder: nil) { stage in
            let folder = stage.appendingPathComponent("parts")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let result = folder.appendingPathComponent("one.txt")
            try Data("new".utf8).write(to: result)
            return [result]
        }
        XCTAssertEqual(outputs.first?.deletingLastPathComponent().lastPathComponent, "parts 2")
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(outputs.first)), "new")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: old.path).isEmpty)
    }

    func testArchiveWriterRefusesToReplaceExistingFile() throws {
        let f = try Fixtures(), out = try f.text("keep.zip", "KEEP")
        XCTAssertThrowsError(try Archive.write([("x", Data("new".utf8))], to: out))
        XCTAssertEqual(try String(contentsOf: out), "KEEP")
    }

    func testCancellationBeforeProcessStartPreventsLaunch() throws {
        let control = ProcessControl()
        control.stop()
        XCTAssertThrowsError(try ProcessRunner.blocking("/usr/bin/true", [], control: control)) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    func testRunningProcessIsCancelled() async throws {
        let task = Task { try await Converter.run("/bin/sleep", ["10"]) }
        try await Task.sleep(nanoseconds: 80_000_000)
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testProcessTimeoutAndOutputLimit() throws {
        let before = Date()
        XCTAssertThrowsError(try ProcessRunner.blocking("/bin/sleep", ["10"], timeout: 0.1))
        XCTAssertLessThan(Date().timeIntervalSince(before), 4)
        XCTAssertThrowsError(try ProcessRunner.blocking("/usr/bin/yes", [], timeout: 3, outputLimit: 1024))
    }

    func testDragPublishedBetweenIdleAndMouseDownIsDetected() {
        let urls = [URL(fileURLWithPath: "/tmp/new.png")]
        let detector = DragModifierDetector { _ in .conversion }
        _ = detector.update(mouseDown: false, dragChangeCount: 10, flags: [], readFiles: { [] })
        XCTAssertEqual(detector.update(mouseDown: true, dragChangeCount: 11, flags: .shift, readFiles: { urls }), .show(.conversion, urls))
    }

    func testWheelKeyboardNavigationWraps() {
        let navigation = WheelNavigation()
        navigation.step(1, count: 3); XCTAssertEqual(navigation.selected, 0)
        navigation.step(-1, count: 3); XCTAssertEqual(navigation.selected, 2)
        navigation.step(1, count: 0); XCTAssertNil(navigation.selected)
    }

    @MainActor func testSecondJobIsQueuedAndExecuted() async throws {
        let runner = JobRunner()
        runner.start(title: "first", files: [URL(fileURLWithPath: "/tmp/a")]) { url, _ in
            try await Task.sleep(nanoseconds: 80_000_000); return [url]
        }
        runner.start(title: "second", files: [URL(fileURLWithPath: "/tmp/b")]) { url, _ in [url] }
        XCTAssertEqual(runner.queuedCount, 1)
        for _ in 0..<100 where runner.isRunning { try await Task.sleep(nanoseconds: 20_000_000) }
        guard case .finished(let title, let summary) = runner.state else { return XCTFail("Not finished") }
        XCTAssertEqual(title, "second"); XCTAssertEqual(summary.outputs.first?.lastPathComponent, "b")
        XCTAssertEqual(runner.queuedCount, 0)
        runner.dismiss()
    }
}
