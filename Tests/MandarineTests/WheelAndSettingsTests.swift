import XCTest
@testable import Mandarine

final class WheelAndSettingsTests: XCTestCase {
    private var saved: (Modifier, Modifier, Modifier)!

    override func setUp() {
        let s = Settings.shared
        saved = (s.conversionModifier, s.toolsModifier, s.actionsModifier)
    }

    override func tearDown() {
        let s = Settings.shared
        (s.conversionModifier, s.toolsModifier, s.actionsModifier) = saved
    }

    func testDefaultModifiersMapToWheels() {
        let s = Settings.shared
        s.conversionModifier = .shift; s.toolsModifier = .command; s.actionsModifier = .control
        XCTAssertEqual(s.wheel(for: .shift), .conversion)
        XCTAssertEqual(s.wheel(for: .command), .tools)
        XCTAssertEqual(s.wheel(for: .control), .actions)
        XCTAssertNil(s.wheel(for: .option))
    }

    func testRemappingModifiers() {
        let s = Settings.shared
        s.conversionModifier = .option; s.toolsModifier = .shift; s.actionsModifier = .command
        XCTAssertEqual(s.wheel(for: .option), .conversion)
        XCTAssertEqual(s.wheel(for: .shift), .tools)
        XCTAssertNil(s.wheel(for: .control))
    }

    func testModifierFlags() {
        XCTAssertEqual(Modifier.shift.flag, .shift)
        XCTAssertEqual(Modifier.command.flag, .command)
        XCTAssertEqual(Modifier.control.flag, .control)
        XCTAssertEqual(Modifier.option.flag, .option)
    }

    func testSettingsArePersisted() {
        let s = Settings.shared
        s.toolsModifier = .option
        XCTAssertEqual(UserDefaults.standard.string(forKey: "tools"), "option")
    }

    func testOutputFolderSetting() {
        let s = Settings.shared
        let old = s.outputFolderPath
        defer { s.outputFolderPath = old }
        s.outputFolderPath = ""
        XCTAssertNil(s.outputFolder)
        s.outputFolderPath = "/tmp"
        XCTAssertEqual(s.outputFolder?.path, "/tmp")
    }

    func testConversionWheelListsTargetsForTheDraggedFile() {
        let items = WheelBuilder.items(kind: .conversion, files: [URL(fileURLWithPath: "/tmp/a.png")])
        let titles = items.map(\.title)
        XCTAssertTrue(titles.contains("JPG"))
        XCTAssertFalse(titles.contains("PNG"))
        XCTAssertEqual(titles.count, Converter.targets(for: URL(fileURLWithPath: "/tmp/a.png")).count)
    }

    func testConversionWheelEmptyForUnsupportedOrNoFiles() {
        XCTAssertTrue(WheelBuilder.items(kind: .conversion, files: []).isEmpty)
        XCTAssertTrue(WheelBuilder.items(kind: .conversion, files: [URL(fileURLWithPath: "/tmp/a.xyz")]).isEmpty)
    }

    func testConversionWheelItemActuallyConverts() async throws {
        let f = try Fixtures()
        let src = try f.png()
        let item = try XCTUnwrap(WheelBuilder.items(kind: .conversion, files: [src]).first { $0.title == "JPG" })
        let s = Settings.shared
        let old = s.outputFolderPath
        defer { s.outputFolderPath = old }
        s.outputFolderPath = ""
        try await item.run(src)
        XCTAssertFileExists(f.url("img.jpg"))
    }
}
