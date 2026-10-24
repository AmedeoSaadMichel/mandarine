import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let wheel = WheelPanel()
    private var settingsWindow: NSWindow?
    private var pollTimer: Timer?
    private var dragSourceExcluded: Bool?
    private lazy var detector = DragModifierDetector(shelfEnabled: { Settings.shared.optionOpensShelf }, shelfModifier: { Settings.shared.shelfModifier }) { Settings.shared.wheel(for: $0) }

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = ""
        statusItem.button?.image = ShelfCitrus.mark(size: 22)
        statusItem.button?.toolTip = "Mandarine"
        statusItem.button?.setAccessibilityLabel("Mandarine")
        NSApp.applicationIconImage = ShelfCitrus.mark(size: 256)
        let menu = NSMenu()
        for (title, kind, key) in [("Convert files…", WheelKind.conversion, "o"), ("Open tool for files…", .tools, "t"), ("File actions…", .actions, "")] {
            let item = NSMenuItem(title: title, action: #selector(chooseFiles(_:)), keyEquivalent: key)
            item.target = self
            item.representedObject = kind.rawValue
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "New shelf", action: #selector(newShelf), keyEquivalent: "n").target = self
        menu.addItem(withTitle: "Show shelves", action: #selector(showShelves), keyEquivalent: "").target = self
        NSApp.mainMenu = ApplicationMenu.make(fileItems: menu.items)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        MainActor.assumeIsolated { ShelfManager.shared.restore() }

        // Query ffmpeg's encoders now, off the main thread, so Settings never waits for it.
        DispatchQueue.global(qos: .utility).async { _ = Converter.ffmpegEncoders }

        // Polling needs no Input Monitoring / Accessibility permission.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(pollTimer!, forMode: .common)

        // Debug: Mandarine --show-wheel <kind> <file> draws the wheel at the mouse position.
        let a = CommandLine.arguments
        if a.count == 4, a[1] == "--show-wheel", let kind = WheelKind(rawValue: a[2]) {
            show(kind, files: [URL(fileURLWithPath: a[3])])
        }
    }

    // Opening the running menu-bar app again should expose a usable window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openSettings() }
        return true
    }

    // MARK: Drag + modifier detection

    private func poll() {
        var mouseDown = NSEvent.pressedMouseButtons & 1 != 0
        // The gestures are ignored while an excluded app is in front.
        if mouseDown {
            if dragSourceExcluded == nil { dragSourceExcluded = Settings.shared.isExcluded(NSWorkspace.shared.frontmostApplication?.bundleIdentifier) }
            if dragSourceExcluded == true { mouseDown = false }
        } else { dragSourceExcluded = nil }
        let pb = NSPasteboard(name: .drag)
        let action = detector.update(mouseDown: mouseDown, dragChangeCount: pb.changeCount, flags: NSEvent.modifierFlags) {
            (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        }
        switch action {
        case .show(let kind, let files):
            show(kind, files: files)
        case .shelf:
            wheel.orderOut(nil)
            MainActor.assumeIsolated { ShelfManager.shared.showForDrop(at: NSEvent.mouseLocation) }
        case .hide:
            wheel.scheduleHide()
        case nil: break
        }
    }

    private func show(_ kind: WheelKind, files: [URL], interactive: Bool = false) {
        Haptics.tap()
        wheel.show(kind: kind, files: files, at: NSEvent.mouseLocation, interactive: interactive) { [weak self] item, urls in
            self?.wheel.orderOut(nil)
            self?.perform(item, on: urls.isEmpty ? files : urls)
        }
    }

    /// Runs a wheel item. Items that only open a window run at once; the others get the progress HUD.
    private func perform(_ item: WheelItem, on files: [URL]) {
        if item.silent {
            Task {
                do {
                    if let batch = item.batch { try await batch(files) } else { for f in files { try await item.run(f) } }
                } catch is ToolCancelled {} catch {
                    await MainActor.run { Self.alert(error.localizedDescription) }
                }
            }
            return
        }
        Task { @MainActor in
            if let batch = item.batch {
                JobRunner.shared.start(title: item.title, files: Array(files.prefix(1))) { _, _ in try await batch(files); return [] }
            } else {
                JobRunner.shared.start(title: item.title, files: files) { file, progress in
                    if let r = item.runWithProgress { return try await r(file, progress) }
                    try await item.run(file)
                    return []
                }
            }
        }
    }

    @MainActor private static func alert(_ text: String) {
        let a = NSAlert()
        a.messageText = "Operation failed"
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    // MARK: Menu actions

    /// "Convert Files…", "Open Tool for Files…", "File Actions…": the wheels without dragging.
    @objc private func chooseFiles(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = WheelKind(rawValue: raw) else { return }
        NSApp.activate(ignoringOtherApps: true)
        let p = NSOpenPanel()
        p.prompt = "Open"
        p.allowsMultipleSelection = true
        p.canChooseDirectories = kind == .actions
        guard p.runModal() == .OK, !p.urls.isEmpty else { return }
        let files = p.urls
        let items = WheelBuilder.items(kind: kind, files: files)
        guard !items.isEmpty else { MainActor.assumeIsolated { Self.alert("No operations available for this selection.") }; return }
        show(kind, files: files, interactive: true)
    }

    private final class MenuChoice: NSObject {
        let item: WheelItem
        let files: [URL]
        init(item: WheelItem, files: [URL]) { self.item = item; self.files = files }
    }

    @objc private func runMenuItem(_ sender: NSMenuItem) {
        guard let c = sender.representedObject as? MenuChoice else { return }
        perform(c.item, on: c.files)
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { ShelfManager.shared.save() }
    }

    @objc private func newShelf() { MainActor.assumeIsolated { ShelfManager.shared.create() } }
    @objc private func showShelves() { MainActor.assumeIsolated { ShelfManager.shared.showAll() } }

    @objc private func openSettings() {
        // A menu-bar-only app has no Dock icon, so its window slips behind other apps and looks closed.
        // While Settings is open the app behaves like a normal one; it goes back to the menu bar on close.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "Mandarine Settings"
            w.styleMask = [.titled, .closable]
            w.appearance = NSAppearance(named: .darkAqua)
            w.backgroundColor = ShelfCitrus.background
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                NSApp.setActivationPolicy(.accessory)
            }
            settingsWindow = w
        }
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

// Export the shared vector mascot for the app bundle icon.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--render-icon" {
    _ = NSApplication.shared
    let mark = ShelfCitrus.mark(size: 1024)
    if let data = mark.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
       let png = bitmap.representation(using: .png, properties: [:]) {
        do { try png.write(to: URL(fileURLWithPath: CommandLine.arguments[2])); exit(0) }
        catch { print(error.localizedDescription); exit(1) }
    }
    exit(1)
}

// Debug: Mandarine --render tool <toolID> <out.png> <files…>  /  --render wheel <kind> <out.png> <files…>
// Draws the window offscreen to a PNG, to check layouts without Screen Recording permission.
if CommandLine.arguments.count >= 6, CommandLine.arguments[1] == "--render" {
    let a = CommandLine.arguments
    let renderApp = NSApplication.shared
    renderApp.setActivationPolicy(.accessory)
    let kind = a[2], name = a[3], out = URL(fileURLWithPath: a[4]), files = a[5...].map { URL(fileURLWithPath: $0) }
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            var size = NSSize(width: 1040, height: 760)
            let view: NSView
            var shelfPreview: ShelfWindowController?
            if kind == "shelf", let mode = ShelfViewMode(rawValue: name) {
                var snapshot = ShelfSnapshot()
                snapshot.viewMode = mode
                snapshot.frame = CGRect(x: 100, y: 100, width: mode == .compact ? 260 : 640, height: mode == .compact ? 218 : 640)
                snapshot.add(files)
                let manager = ShelfManager(storeURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
                let controller = ShelfWindowController(snapshot: snapshot, manager: manager)
                shelfPreview = controller
                view = controller.window!.contentView!
                size = view.bounds.size
                view.appearance = NSAppearance(named: .darkAqua)
            } else if kind == "tool", let tool = ToolID(rawValue: name) {
                size = NSSize(width: tool.defaultWindowSize.width, height: tool.defaultWindowSize.height)
                view = NSHostingView(rootView: ToolWindowView(session: ToolSession(tool: tool, files: files)))
            } else if kind == "wheel", let wk = WheelKind(rawValue: name) {
                let items = WheelBuilder.items(kind: wk, files: files)
                let s = items.isEmpty ? CGFloat(280) : max(300, WheelView.panelSize(for: items.count))
                size = NSSize(width: s, height: s)
                let note = items.isEmpty ? WheelEmpty.message(kind: wk, files: files) : nil
                view = NSHostingView(rootView: WheelView(kind: wk, items: items, onDrop: { _, _ in }, size: s, message: note).background(Color(nsColor: .windowBackgroundColor)))
            } else if kind == "settings", let page = SettingsPage(rawValue: name) {
                size = NSSize(width: 960, height: 760)
                view = NSHostingView(rootView: SettingsView(initialPage: page))
            } else if kind == "view" {
                size = NSSize(width: 660, height: 500)
                switch name {
                case "general": view = NSHostingView(rootView: GeneralTab())
                case "formats": view = NSHostingView(rootView: FormatsTab())
                case "folders": view = NSHostingView(rootView: FoldersTab())
                case "compat": view = NSHostingView(rootView: CompatibilityTab())
                case "hud":
                    size = NSSize(width: 380, height: 76)
                    JobRunner.shared.start(title: "Converting to PNG", files: files) { f, progress in
                        progress(0.4); try await Task.sleep(nanoseconds: 60_000_000_000); return [f]
                    }
                    view = NSHostingView(rootView: JobHUDView(runner: JobRunner.shared).background(Color(nsColor: .windowBackgroundColor)))
                default: print("ERR vista"); exit(1)
                }
            } else { print("ERR argomenti"); exit(1) }
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: kind == "settings" ? .darkAqua : .aqua)
            window.contentView = view
            window.setContentSize(size)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                MainActor.assumeIsolated {
                    _ = shelfPreview
                    window.displayIfNeeded()
                    view.layoutSubtreeIfNeeded()
                    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { print("ERR rep"); exit(1) }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: out)
                    print("OK \(out.path)")
                    exit(0)
                }
            }
        }
    }
    renderApp.run()
}

// Headless test mode: Mandarine --convert <file> <ext>
if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--convert" {
    let src = URL(fileURLWithPath: CommandLine.arguments[2])
    let ext = CommandLine.arguments[3]
    _ = NSApplication.shared
    Task.detached {
        do {
            let out = try await Converter.convert(src, to: ext, outputFolder: nil, quality: .balanced)
            print("OK \(out.path)")
            exit(0)
        } catch { print("ERR \(error.localizedDescription)"); exit(1) }
    }
    dispatchMain()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
