import AppKit
import XCTest
@testable import Mandarine

@MainActor
final class EditingShortcutTests: XCTestCase {
    private func withTimeEditor(_ body: (NSMenu, NSTextField, NSTextView) throws -> Void) throws {
        _ = NSApplication.shared
        let previousMenu = NSApp.mainMenu
        let menu = ApplicationMenu.make()
        NSApp.mainMenu = menu
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let field = NSTextField(string: "0:04.5")
        field.frame = NSRect(x: 20, y: 30, width: 140, height: 24)
        window.contentView?.addSubview(field)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(field)
        defer { window.orderOut(nil); NSApp.mainMenu = previousMenu }
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        // SwiftPM's test host cannot become the OS key app. Bind its isolated field
        // editor explicitly here; the production responder-chain routing is checked in the UI.
        let selectAll = try XCTUnwrap(menu.items.last?.submenu?.items.first { $0.action == #selector(NSText.selectAll(_:)) })
        XCTAssertNil(selectAll.target)
        selectAll.target = editor
        try body(menu, field, editor)
    }

    private func commandA() throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
                                     timestamp: 0, windowNumber: NSApp.keyWindow?.windowNumber ?? 0,
                                     context: nil, characters: "a", charactersIgnoringModifiers: "a",
                                     isARepeat: false, keyCode: 0))
    }

    func testCommandASelectsTheEntireTimeInTheNativeFieldEditor() throws {
        try withTimeEditor { menu, _, editor in
            XCTAssertTrue(menu.performKeyEquivalent(with: try commandA()))
            XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 6))
        }
    }

    func testTypingAfterCommandAReplacesRatherThanConcatenatesTheTime() throws {
        try withTimeEditor { menu, field, editor in
            XCTAssertTrue(menu.performKeyEquivalent(with: try commandA()))
            editor.insertText("0:01.0", replacementRange: editor.selectedRange())
            XCTAssertEqual(editor.string, "0:01.0")
            editor.window?.makeFirstResponder(nil)
            XCTAssertEqual(field.stringValue, "0:01.0")
        }
    }
    func testFileActionsDoNotStealCommandA() {
        let actions = NSMenuItem(title: "Actions", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let menu = ApplicationMenu.make(fileItems: [actions])
        let file = menu.items[1].submenu!
        XCTAssertEqual(file.items[0].keyEquivalent, "")
        XCTAssertEqual(actions.keyEquivalent, "a", "Building the menu must not mutate its inputs")
    }

}
