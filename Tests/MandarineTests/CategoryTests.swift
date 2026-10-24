import XCTest
@testable import Mandarine

final class CategoryTests: XCTestCase {
    func testCategoryDetection() {
        let cases: [(String, Category?)] = [
            ("a.jpg", .image), ("a.JPEG", .image), ("a.png", .image), ("a.tif", .image), ("a.heic", .image),
            ("a.pdf", .document), ("a.docx", .document), ("a.md", .document), ("a.htm", .document),
            ("a.csv", .spreadsheet), ("a.tsv", .spreadsheet),
            ("a.mp3", .audio), ("a.flac", .audio),
            ("a.mp4", .video), ("a.mov", .video),
            ("a.xyz", nil), ("noext", nil),
        ]
        for (name, expected) in cases {
            XCTAssertEqual(Category.of(URL(fileURLWithPath: "/tmp/\(name)")), expected, name)
        }
    }

    func testExtensionNormalization() {
        XCTAssertEqual(Category.normalized("JPEG"), "jpg")
        XCTAssertEqual(Category.normalized("TIF"), "tiff")
        XCTAssertEqual(Category.normalized("htm"), "html")
        XCTAssertEqual(Category.normalized("markdown"), "md")
        XCTAssertEqual(Category.normalized("PNG"), "png")
    }

    func testTargetsExcludeSourceFormat() {
        let t = Converter.targets(for: URL(fileURLWithPath: "/tmp/a.png"))
        XCTAssertFalse(t.contains("png"))
        XCTAssertTrue(t.contains("jpg"))
        let jpeg = Converter.targets(for: URL(fileURLWithPath: "/tmp/a.jpeg"))
        XCTAssertFalse(jpeg.contains("jpg"), "jpeg e jpg sono lo stesso formato")
    }

    func testTargetsEmptyForUnknownFormat() {
        XCTAssertTrue(Converter.targets(for: URL(fileURLWithPath: "/tmp/a.xyz")).isEmpty)
    }

    func testEveryCategoryOffersTargets() {
        for (name, cat) in [("a.png", Category.image), ("a.txt", .document), ("a.csv", .spreadsheet),
                            ("a.wav", .audio), ("a.mp4", .video)] {
            XCTAssertEqual(Category.of(URL(fileURLWithPath: "/tmp/\(name)")), cat)
            XCTAssertFalse(Converter.targets(for: URL(fileURLWithPath: "/tmp/\(name)")).isEmpty, name)
        }
    }
}
