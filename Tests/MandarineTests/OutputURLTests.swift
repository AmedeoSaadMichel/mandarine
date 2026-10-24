import XCTest
@testable import Mandarine

final class OutputURLTests: XCTestCase {
    func testOutputNextToSourceByDefault() throws {
        let f = try Fixtures()
        let src = try f.text("doc.txt", "x")
        XCTAssertEqual(Converter.outputURL(for: src, ext: "rtf", in: nil).deletingLastPathComponent().path,
                       f.dir.path.replacingOccurrences(of: "/private", with: ""), "stessa cartella")
    }

    func testOutputInCustomFolder() throws {
        let f = try Fixtures(), other = try Fixtures()
        let src = try f.text("doc.txt", "x")
        let out = Converter.outputURL(for: src, ext: "rtf", in: other.dir)
        XCTAssertEqual(out.lastPathComponent, "doc.rtf")
        XCTAssertEqual(out.deletingLastPathComponent().standardizedFileURL.path, other.dir.standardizedFileURL.path)
    }

    func testCollisionsGetNumberedNames() throws {
        let f = try Fixtures()
        let src = try f.text("doc.txt", "x")
        _ = try f.text("doc.rtf", "esiste")
        XCTAssertEqual(Converter.outputURL(for: src, ext: "rtf", in: nil).lastPathComponent, "doc 2.rtf")
        _ = try f.text("doc 2.rtf", "esiste")
        XCTAssertEqual(Converter.outputURL(for: src, ext: "rtf", in: nil).lastPathComponent, "doc 3.rtf")
    }

    func testConversionNeverOverwritesOriginalOrExistingOutput() async throws {
        let f = try Fixtures()
        let src = try f.text("data.csv", "a,b\n1,2\n")
        let existing = try f.text("data.tsv", "NON TOCCARE")
        let out = try await convert(src, "tsv")
        XCTAssertEqual(try String(contentsOf: existing), "NON TOCCARE")
        XCTAssertEqual(out.lastPathComponent, "data 2.tsv")
        XCTAssertEqual(try String(contentsOf: src), "a,b\n1,2\n")
    }
}
