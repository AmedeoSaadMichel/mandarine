import AppKit
import XCTest
@testable import Mandarine

final class DragDetectorTests: XCTestCase {
    private let files = [URL(fileURLWithPath: "/tmp/a.png")]
    private var detector: DragModifierDetector!

    override func setUp() {
        detector = DragModifierDetector { m in
            switch m {
            case .shift: return .conversion
            case .command: return .tools
            case .control: return .actions
            case .option: return nil
            }
        }
    }

    private func step(down: Bool, count: Int = 10, flags: NSEvent.ModifierFlags = [], read: [URL]? = nil) -> DragModifierDetector.Action? {
        detector.update(mouseDown: down, dragChangeCount: count, flags: flags) { read ?? self.files }
    }

    func testCustomShelfModifierReplacesOption() {
        detector = DragModifierDetector(shelfEnabled: { true }, shelfModifier: { .control }) { _ in nil }
        _ = step(down: true)
        XCTAssertNil(step(down: true, count: 11, flags: .option))
        XCTAssertEqual(step(down: true, count: 11, flags: .control), .shelf)
    }

    func testCustomShelfModifierHonoursWheelPriorityAndDisabledSetting() {
        detector = DragModifierDetector(shelfEnabled: { true }, shelfModifier: { .shift }) { $0 == .shift ? .conversion : nil }
        _ = step(down: true)
        XCTAssertEqual(step(down: true, count: 11, flags: .shift), .show(.conversion, files))
        detector = DragModifierDetector(shelfEnabled: { false }, shelfModifier: { .control }) { _ in nil }
        _ = step(down: true)
        XCTAssertNil(step(down: true, count: 11, flags: .control))
    }

    func testShelfModifierPersistsAndDefaultsToOption() {
        let name = "MandarineShelfShortcutTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(Settings(defaults: defaults).shelfModifier, .option)
        let settings = Settings(defaults: defaults)
        settings.shelfModifier = .command
        settings.optionOpensShelf = false
        let reloaded = Settings(defaults: defaults)
        XCTAssertEqual(reloaded.shelfModifier, .command)
        XCTAssertFalse(reloaded.optionOpensShelf)
    }

    func testOptionRevealsShelfDuringFileDragOnlyOnce() {
        detector = DragModifierDetector(shelfEnabled: { true }) { _ in nil }
        _ = step(down: true)
        _ = step(down: true, count: 11)
        XCTAssertEqual(step(down: true, count: 11, flags: .option), .shelf)
        XCTAssertNil(step(down: true, count: 11, flags: .option))
        _ = step(down: true, count: 11)
        XCTAssertEqual(step(down: true, count: 11, flags: .option), .shelf)
    }

    func testHeldOptionOpensShelfButPlainOptionClickDoesNot() {
        detector = DragModifierDetector(shelfEnabled: { true }) { _ in nil }
        XCTAssertNil(step(down: false, flags: .option))
        XCTAssertNil(step(down: true, flags: .option))
        XCTAssertNil(step(down: true, flags: .option))
        XCTAssertEqual(step(down: true, count: 11, flags: .option), .shelf)
    }

    func testOptionAssignedToWheelTakesPriorityOverShelf() {
        detector = DragModifierDetector(shelfEnabled: { true }) { $0 == .option ? .tools : nil }
        _ = step(down: true)
        XCTAssertEqual(step(down: true, count: 11, flags: .option), .show(.tools, files))
    }

    func testShelfOptionIgnoresTextDragsAndChords() {
        detector = DragModifierDetector(shelfEnabled: { true }) { _ in nil }
        _ = step(down: true)
        XCTAssertNil(step(down: true, count: 11, flags: .option, read: []))
        _ = step(down: false, count: 11)
        _ = step(down: true, count: 11)
        XCTAssertNil(step(down: true, count: 12, flags: [.option, .shift]))
    }

    func testNothingHappensWithoutMouseButton() {
        XCTAssertNil(step(down: false, flags: .shift))
        XCTAssertNil(step(down: false))
    }

    func testDragThenShowsOnShiftPress() {
        XCTAssertNil(step(down: true))                       // mouse down on a file
        XCTAssertNil(step(down: true, count: 11))            // drag starts: pasteboard changes
        XCTAssertEqual(step(down: true, count: 11, flags: .shift), .show(.conversion, files))
    }

    func testEachModifierOpensItsWheel() {
        for (flag, kind) in [(NSEvent.ModifierFlags.shift, WheelKind.conversion), (.command, .tools), (.control, .actions)] {
            setUp()
            _ = step(down: true); _ = step(down: true, count: 11)
            XCTAssertEqual(step(down: true, count: 11, flags: flag), .show(kind, files), "\(kind)")
        }
    }

    func testCommandDuringDragOpensToolsWheel() {
        _ = step(down: true)
        _ = step(down: true, count: 11)
        XCTAssertEqual(step(down: true, count: 11, flags: .command), .show(.tools, files))
    }

    func testClickHoldThenShiftThenMoveShowsWheelAsSoonAsDragStarts() {
        // "Click on the file, press shift, then start moving": the tap is remembered.
        _ = step(down: true)
        XCTAssertNil(step(down: true, flags: .shift), "ancora nessun file in trascinamento")
        XCTAssertNil(step(down: true), "shift rilasciato, ancora fermo")
        XCTAssertEqual(step(down: true, count: 11), .show(.conversion, files))
    }

    func testHoldingShiftThroughTheWholeDragOpensTheWheel() {
        // Sequenza reale dal log: Shift premuto, poi mouse giù, poi il trascinamento parte con Shift ancora tenuto.
        XCTAssertNil(step(down: false, flags: .shift))
        XCTAssertNil(step(down: true, flags: .shift))
        XCTAssertEqual(step(down: true, count: 11, flags: .shift), .show(.conversion, files))
        XCTAssertNil(step(down: true, count: 11, flags: .shift), "una sola volta finché Shift resta premuto")
        XCTAssertEqual(step(down: false, count: 11, flags: .shift), .hide)
    }

    func testShiftClickWithoutDraggingFilesDoesNothing() {
        _ = step(down: true, flags: .shift)
        XCTAssertNil(step(down: true, flags: .shift))
        XCTAssertNil(step(down: true, flags: .shift))
        XCTAssertEqual(step(down: false, flags: .shift), .hide)
    }

    func testHoldingCommandThroughDragOpensToolsWheel() {
        _ = step(down: true, flags: .command)
        XCTAssertEqual(step(down: true, count: 11, flags: .command), .show(.tools, files))
    }

    func testHeldModifierWithoutMappingDoesNotOpenAnything() {
        _ = step(down: true, flags: .option)
        XCTAssertNil(step(down: true, count: 11, flags: .option))
    }

    func testHeldModifierThenReleasedAndTappedShowsAgain() {
        _ = step(down: true, flags: .shift)
        XCTAssertNotNil(step(down: true, count: 11, flags: .shift))
        XCTAssertNil(step(down: true, count: 11))
        XCTAssertEqual(step(down: true, count: 11, flags: .command), .show(.tools, files), "si può cambiare ruota a metà trascinamento")
    }

    func testReleaseAndPressAgainShowsAgain() {
        _ = step(down: true); _ = step(down: true, count: 11)
        XCTAssertNotNil(step(down: true, count: 11, flags: .shift))
        XCTAssertNil(step(down: true, count: 11, flags: .shift), "tasto tenuto: una sola volta")
        XCTAssertNil(step(down: true, count: 11))
        XCTAssertEqual(step(down: true, count: 11, flags: .shift), .show(.conversion, files))
    }

    func testStaleDragPasteboardFromEarlierDragIsIgnored() {
        // Il pasteboard non cambia dopo il mouse-down: è un vecchio trascinamento, non c'è nessun file.
        _ = step(down: true, count: 50)
        XCTAssertNil(step(down: true, count: 50, flags: .shift))
        XCTAssertNil(step(down: true, count: 50))
    }

    func testPlainClickWithoutFilesNeverShows() {
        _ = step(down: true, count: 7, read: [])
        _ = step(down: true, count: 8, read: [])             // pasteboard cambia ma senza file (testo trascinato)
        XCTAssertNil(step(down: true, count: 8, flags: .shift, read: []))
    }

    func testMouseUpHidesWheelOnce() {
        _ = step(down: true); _ = step(down: true, count: 11)
        _ = step(down: true, count: 11, flags: .shift)
        XCTAssertEqual(step(down: false, count: 11), .hide)
        XCTAssertNil(step(down: false, count: 11), "nessun secondo hide")
    }

    func testStateIsResetBetweenDrags() {
        _ = step(down: true); _ = step(down: true, count: 11)
        _ = step(down: true, count: 11, flags: .shift)
        _ = step(down: false)
        // Nuovo clic senza trascinare: il vecchio pasteboard non deve riapparire.
        _ = step(down: true, count: 11)
        XCTAssertNil(step(down: true, count: 11, flags: .command))
    }

    func testMultipleModifiersAtOnceAreNotATap() {
        _ = step(down: true); _ = step(down: true, count: 11)
        XCTAssertNil(step(down: true, count: 11, flags: [.shift, .command]))
    }

    func testUnmappedModifierDoesNothing() {
        _ = step(down: true); _ = step(down: true, count: 11)
        XCTAssertNil(step(down: true, count: 11, flags: .option))
    }

    func testCapsLockAndFunctionFlagsAreIgnored() {
        _ = step(down: true); _ = step(down: true, count: 11)
        XCTAssertNil(step(down: true, count: 11, flags: [.capsLock]))
        XCTAssertEqual(step(down: true, count: 11, flags: [.shift, .capsLock]), .show(.conversion, files))
    }

    func testMultipleFilesAreAllReported() {
        let many = (1...3).map { URL(fileURLWithPath: "/tmp/\($0).png") }
        _ = step(down: true)
        _ = step(down: true, count: 11, read: many)
        XCTAssertEqual(step(down: true, count: 11, flags: .shift, read: many), .show(.conversion, many))
    }
}
