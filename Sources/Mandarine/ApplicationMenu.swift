import AppKit

/// Standard editing shortcuts must be in the main menu so AppKit can route them to
/// the active field editor. A status-item menu alone does not provide this routing.
enum ApplicationMenu {
    static func make(fileItems: [NSMenuItem] = []) -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let app = NSMenu(title: "Mandarine")
        app.addItem(withTitle: "Quit Mandarine", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app
        main.addItem(appItem)

        if !fileItems.isEmpty {
            let fileItem = NSMenuItem()
            let file = NSMenu(title: "File")
            for original in fileItems {
                let item = original.copy() as! NSMenuItem
                // Command+A belongs to the field editor, never to a file action.
                if item.keyEquivalent == "a" { item.keyEquivalent = "" }
                file.addItem(item)
            }
            fileItem.submenu = file
            main.addItem(fileItem)
        }

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }
}
