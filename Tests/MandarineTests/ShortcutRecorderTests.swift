import AppKit
import XCTest
@testable import Mandarine

final class ShortcutRecorderTests: XCTestCase {
    private func event(_ code: UInt16, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags,
                        timestamp: 0, windowNumber: 0, context: nil,
                        characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
    }
    func testBothSidesOfEachModifierCanBeRecorded() {
        for (modifier, codes): (Modifier, [UInt16]) in [(.shift, [56, 60]), (.command, [55, 54]), (.control, [59, 62]), (.option, [58, 61])] {
            for code in codes { XCTAssertEqual(Modifier.pressed(in: event(code, modifier.flag)), modifier) }
        }
    }
    func testReleaseAndCombinationsDoNotRecord() {
        XCTAssertNil(Modifier.pressed(in: event(56, [])))
        XCTAssertNil(Modifier.pressed(in: event(56, [.shift, .command])))
        XCTAssertNil(Modifier.pressed(in: event(57, .capsLock)))
        XCTAssertEqual(Modifier.pressed(in: event(58, [.option, .capsLock])), .option)
    }
}
