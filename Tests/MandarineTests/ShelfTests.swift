import AppKit
import XCTest
@testable import Mandarine

final class ShelfTests: XCTestCase {
    func testPersistenceRoundTripAndReferencesDoNotModifyFiles() throws {
        let fixture = try Fixtures()
        let source = try fixture.text("original.txt", "originale")
        let store = fixture.dir.appendingPathComponent("state/shelves.json")
        var shelf = ShelfSnapshot()
        shelf.add([source])
        shelf.edge = .right
        shelf.frame = CGRect(x: -500, y: 200, width: 340, height: 300)
        try ShelfStore.save([shelf], to: store)
        let restored = try XCTUnwrap(ShelfStore.load(from: store).first)
        XCTAssertEqual(restored.id, shelf.id)
        XCTAssertEqual(restored.edge, .right)
        XCTAssertEqual(restored.frame, shelf.frame)
        XCTAssertEqual(restored.files.first?.url.standardizedFileURL, source.standardizedFileURL)
        try ShelfStore.save([], to: store)
        XCTAssertEqual(try String(contentsOf: source), "originale")
    }

    func testDeduplicationAndNonFileURLs() throws {
        let fixture = try Fixtures()
        let source = try fixture.text("a.txt", "a")
        var shelf = ShelfSnapshot()
        shelf.add([source, source, URL(string: "https://example.com")!])
        shelf.add([source])
        XCTAssertEqual(shelf.files.count, 1)
    }

    func testMissingFileReferenceIsRetained() throws {
        let fixture = try Fixtures()
        let missing = fixture.dir.appendingPathComponent("missing.txt")
        var shelf = ShelfSnapshot()
        shelf.add([missing])
        let store = fixture.dir.appendingPathComponent("shelves.json")
        try ShelfStore.save([shelf], to: store)
        XCTAssertEqual(try ShelfStore.load(from: store)[0].files[0].url, missing)
    }

    func testCorruptStoreIsReportedAndNotOverwritten() throws {
        let fixture = try Fixtures()
        let store = try fixture.text("shelves.json", "invalid")
        XCTAssertThrowsError(try ShelfStore.load(from: store))
        XCTAssertEqual(try String(contentsOf: store), "invalid")
    }

    func testDockingUsesScreenOriginAndCanBeDetached() {
        let screen = CGRect(x: -1920, y: 80, width: 1920, height: 1000)
        let left = CGRect(x: -1910, y: 300, width: 340, height: 300)
        XCTAssertEqual(ShelfGeometry.edge(for: left, screen: screen), .left)
        XCTAssertEqual(ShelfGeometry.fit(left, screen: screen, edge: .left).minX, -1920)
        let right = CGRect(x: -350, y: 300, width: 340, height: 300)
        XCTAssertEqual(ShelfGeometry.edge(for: right, screen: screen), .right)
        XCTAssertEqual(ShelfGeometry.fit(right, screen: screen, edge: .right).maxX, 0)
        XCTAssertNil(ShelfGeometry.edge(for: CGRect(x: -900, y: 300, width: 340, height: 300), screen: screen))
    }

    func testRestoreClampsOffscreenFrameAfterDisplayRemoval() {
        let screen = CGRect(x: 0, y: 25, width: 1440, height: 850)
        let frame = ShelfGeometry.fit(CGRect(x: -2000, y: 1800, width: 340, height: 300), screen: screen, edge: nil)
        XCTAssertTrue(screen.contains(frame))
    }

    @MainActor func testWindowRestoresFilesAndRemovalOnlyChangesShelf() throws {
        _ = NSApplication.shared
        let fixture = try Fixtures()
        let source = try fixture.text("example.txt", "keep me")
        let store = fixture.dir.appendingPathComponent("shelves.json")
        var snapshot = ShelfSnapshot()
        snapshot.add([source])
        try ShelfStore.save([snapshot], to: store)
        let manager = ShelfManager(storeURL: store)
        manager.restore()
        let controller = try XCTUnwrap(manager.windows.first)
        let window = try XCTUnwrap(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()
        func findTable(_ view: NSView) -> ShelfTable? {
            if let table = view as? ShelfTable { return table }
            return view.subviews.compactMap { findTable($0) }.first
        }
        let table = try XCTUnwrap(window.contentView.flatMap { findTable($0) })
        XCTAssertEqual(table.numberOfRows, 1)
        XCTAssertGreaterThan(table.enclosingScrollView?.frame.height ?? 0, 40)
        let writer = controller.tableView(table, pasteboardWriterForRow: 0)
        XCTAssertNotNil(writer)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertEqual(controller.numberOfPreviewItems(in: nil), 1)
        XCTAssertEqual(controller.previewPanel(nil, previewItemAt: 0)?.previewItemURL?.standardizedFileURL, source.standardizedFileURL)
        table.remove?()
        XCTAssertEqual(table.numberOfRows, 0)
        XCTAssertEqual(try ShelfStore.load(from: store)[0].files.count, 0)
        XCTAssertEqual(try String(contentsOf: source), "keep me")
        window.close()
        XCTAssertTrue(manager.windows.isEmpty)
        XCTAssertTrue(try ShelfStore.load(from: store).isEmpty)
    }

    func testAutoHideDelayRestartsAfterPointerOrDragInteraction() {
        var policy = ShelfAutoHide()
        policy.hold(at: 10)
        XCTAssertFalse(policy.shouldHide(at: 10.3, pointerInside: false, interacting: false))
        XCTAssertFalse(policy.shouldHide(at: 11, pointerInside: true, interacting: false))
        XCTAssertFalse(policy.shouldHide(at: 11.5, pointerInside: false, interacting: false))
        XCTAssertFalse(policy.shouldHide(at: 12, pointerInside: false, interacting: true))
        XCTAssertFalse(policy.shouldHide(at: 12.5, pointerInside: false, interacting: false))
        XCTAssertTrue(policy.shouldHide(at: 12.8, pointerInside: false, interacting: false))
    }

    func testEdgeTabFitsBothEdgesOnAnOffsetDisplay() {
        let screen = CGRect(x: -1920, y: 100, width: 1920, height: 900)
        for y in [-1000.0, 400, 2000] {
            let shelf = CGRect(x: -1920, y: y, width: 340, height: 300)
            let left = ShelfEdgeTabGeometry.frame(shelf: shelf, screen: screen, edge: .left)
            let right = ShelfEdgeTabGeometry.frame(shelf: shelf, screen: screen, edge: .right)
            XCTAssertTrue(screen.contains(left))
            XCTAssertTrue(screen.contains(right))
            XCTAssertEqual(left.minX, screen.minX)
            XCTAssertEqual(right.maxX, screen.maxX)
        }
    }

    @MainActor func testCollapsedShelfRevealsOnHoverAndKeepsExpandedFrameInStore() throws {
        _ = NSApplication.shared
        let fixture = try Fixtures()
        let source = try fixture.text("hover.txt", "original")
        let store = fixture.dir.appendingPathComponent("shelves.json")
        var snapshot = ShelfSnapshot()
        snapshot.edge = .left
        snapshot.add([source])
        try ShelfStore.save([snapshot], to: store)
        let manager = ShelfManager(storeURL: store)
        manager.restore()
        let controller = try XCTUnwrap(manager.windows.first)
        let expanded = controller.snapshot.frame
        controller.updateEdgeVisibility(pointer: CGPoint(x: -100000, y: -100000), time: ProcessInfo.processInfo.systemUptime + 10)
        XCTAssertTrue(controller.isCollapsed)
        XCTAssertFalse(controller.window!.isVisible)
        let tab = try XCTUnwrap(controller.edgeTabPanel)
        XCTAssertTrue(tab.isVisible)
        manager.save()
        XCTAssertEqual(try ShelfStore.load(from: store)[0].frame, expanded)
        controller.updateEdgeVisibility(pointer: CGPoint(x: tab.frame.midX, y: tab.frame.midY))
        XCTAssertFalse(controller.isCollapsed)
        XCTAssertTrue(controller.window!.isVisible)
        XCTAssertEqual(controller.snapshot.frame, expanded)
        controller.collapse()
        manager.showAll()
        XCTAssertFalse(controller.isCollapsed)
        controller.window?.close()
        XCTAssertFalse(tab.isVisible)
        XCTAssertTrue(manager.windows.isEmpty)
    }

    @MainActor func testEdgeTabReceivesFilesAndUndockedShelfStaysVisible() throws {
        _ = NSApplication.shared
        let fixture = try Fixtures()
        let source = try fixture.text("drop.txt", "keep")
        let store = fixture.dir.appendingPathComponent("shelves.json")
        var snapshot = ShelfSnapshot()
        snapshot.edge = .right
        let manager = ShelfManager(storeURL: store)
        let controller = ShelfWindowController(snapshot: snapshot, manager: manager)
        controller.showWindow(nil)
        controller.collapse()
        let tab = try XCTUnwrap(controller.edgeTabPanel?.contentView as? ShelfEdgeTab)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects([source as NSURL])
        let files = tab.fileURLs(from: pasteboard)
        XCTAssertEqual(files.map(\.standardizedFileURL), [source.standardizedFileURL])
        tab.receive?(files)
        XCTAssertFalse(controller.isCollapsed)
        XCTAssertEqual(controller.snapshot.files.count, 1)
        controller.snapshot.edge = nil
        controller.collapse()
        XCTAssertFalse(controller.isCollapsed)
        controller.updateEdgeVisibility(pointer: CGPoint(x: -100000, y: -100000), time: ProcessInfo.processInfo.systemUptime + 10)
        XCTAssertTrue(controller.window!.isVisible)
        controller.window?.close()
        XCTAssertEqual(try String(contentsOf: source), "keep")
    }

    func testOldShelfStateLoadsAsListAndGridChoicePersists() throws {
        let fixture = try Fixtures()
        let store = fixture.dir.appendingPathComponent("shelves.json")
        try ShelfStore.save([ShelfSnapshot()], to: store)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store)) as? [[String: Any]])
        json[0].removeValue(forKey: "viewMode")
        try JSONSerialization.data(withJSONObject: json).write(to: store)
        var snapshot = try XCTUnwrap(ShelfStore.load(from: store).first)
        XCTAssertEqual(snapshot.viewMode, .list)
        snapshot.viewMode = .grid
        try ShelfStore.save([snapshot], to: store)
        XCTAssertEqual(try ShelfStore.load(from: store)[0].viewMode, .grid)
    }

    @MainActor func testGridKeepsSelectionQuickLookAndDraggingAcrossViewChanges() throws {
        _ = NSApplication.shared
        let fixture = try Fixtures()
        let first = try fixture.png("Foto.png")
        let second = try fixture.text("Appunti.txt", "Anteprima documento")
        let store = fixture.dir.appendingPathComponent("shelves.json")
        var snapshot = ShelfSnapshot()
        snapshot.add([first, second])
        try ShelfStore.save([snapshot], to: store)
        let manager = ShelfManager(storeURL: store)
        manager.restore()
        let controller = try XCTUnwrap(manager.windows.first)
        defer { controller.window?.close() }
        let window = try XCTUnwrap(controller.window)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
        let content = try XCTUnwrap(window.contentView)
        let table = try XCTUnwrap(descendants(content).compactMap { $0 as? ShelfTable }.first)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        let picker = try XCTUnwrap(descendants(content).compactMap { $0 as? NSSegmentedControl }.first)
        picker.selectedSegment = 1
        XCTAssertTrue(picker.sendAction(picker.action, to: picker.target))
        content.layoutSubtreeIfNeeded()
        let grid = try XCTUnwrap(descendants(content).compactMap { $0 as? ShelfGrid }.first)
        grid.layoutSubtreeIfNeeded()
        XCTAssertEqual(grid.numberOfItems(inSection: 0), 2)
        XCTAssertEqual(grid.selectionIndexPaths, [IndexPath(item: 1, section: 0)])
        XCTAssertEqual(controller.previewPanel(nil, previewItemAt: 0)?.previewItemURL?.standardizedFileURL, second.standardizedFileURL)
        XCTAssertNotNil(controller.collectionView(grid, pasteboardWriterForItemAt: IndexPath(item: 0, section: 0)))
        XCTAssertEqual(try ShelfStore.load(from: store)[0].viewMode, .grid)
        let item = controller.collectionView(grid, itemForRepresentedObjectAt: IndexPath(item: 0, section: 0))
        XCTAssertNotNil(item.imageView?.image)
        XCTAssertEqual(item.textField?.stringValue, "Foto.png")
        controller.setViewMode(.list)
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: 1))
        controller.setViewMode(.grid)
        grid.remove?()
        XCTAssertEqual(controller.snapshot.files.count, 1)
        XCTAssertEqual(controller.snapshot.files[0].url.standardizedFileURL, first.standardizedFileURL)
        XCTAssertEqual(try String(contentsOf: second), "Anteprima documento")
    }

    @MainActor func testGridRestoresAndLaysOutMultipleRows() async throws {
        _ = NSApplication.shared
        let fixture = try Fixtures()
        let store = fixture.dir.appendingPathComponent("shelves.json")
        var snapshot = ShelfSnapshot()
        snapshot.viewMode = .grid
        snapshot.add(try (0..<9).map { try fixture.png("Foto \($0).png") })
        try ShelfStore.save([snapshot], to: store)
        let manager = ShelfManager(storeURL: store)
        manager.restore()
        let controller = try XCTUnwrap(manager.windows.first)
        defer { controller.window?.close() }
        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(content.subviews.compactMap { $0 as? NSScrollView }.first)
        let grid = try XCTUnwrap(scroll.documentView as? ShelfGrid)
        grid.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(grid.collectionViewLayout!.collectionViewContentSize.height, scroll.contentSize.height)
        XCTAssertEqual(grid.numberOfItems(inSection: 0), 9)
        // Optional render for visual QA without taking a screenshot of the desktop.
        if let path = ProcessInfo.processInfo.environment["MANDARINE_GRID_PREVIEW"] {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    @MainActor func testCompactModePersistsAndRestoresExpandedSize() throws {
        _ = NSApplication.shared
        let fixture = try Fixtures()
        let store = fixture.dir.appendingPathComponent("shelves.json")
        var snapshot = ShelfSnapshot()
        snapshot.viewMode = .grid
        snapshot.add([try fixture.png(), try fixture.text("notes.txt", "keep")])
        try ShelfStore.save([snapshot], to: store)
        let manager = ShelfManager(storeURL: store)
        manager.restore()
        let controller = try XCTUnwrap(manager.windows.first)
        let expanded = controller.snapshot.frame
        controller.setViewMode(.compact)
        XCTAssertLessThan(controller.snapshot.frame.width, expanded.width)
        XCTAssertLessThan(controller.snapshot.frame.height, expanded.height)
        let saved = try XCTUnwrap(ShelfStore.load(from: store).first)
        XCTAssertEqual(saved.viewMode, .compact)
        XCTAssertEqual(saved.expandedFrame, expanded)
        XCTAssertEqual(saved.expandedViewMode, .grid)
        let restoredManager = ShelfManager(storeURL: fixture.dir.appendingPathComponent("other.json"))
        let restored = ShelfWindowController(snapshot: saved, manager: restoredManager)
        restored.showWindow(nil)
        defer { restored.window?.close(); controller.window?.close() }
        let scroll = try XCTUnwrap(restored.window?.contentView?.subviews.compactMap { $0 as? NSScrollView }.first)
        let pile = try XCTUnwrap(scroll.documentView as? ShelfStack)
        XCTAssertEqual(pile.urls.count, 2)
        XCTAssertEqual(restored.numberOfPreviewItems(in: nil), 2)
        pile.expand?()
        XCTAssertEqual(restored.snapshot.viewMode, .grid)
        XCTAssertEqual(restored.snapshot.frame.size, expanded.size)
    }

    @MainActor func testPileDragContainsEveryExistingFileAndFolder() throws {
        _ = NSApplication.shared
        let fixture = try Fixtures()
        let image = try fixture.png()
        let text = try fixture.text("notes.txt", "original")
        let folder = fixture.dir.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let missing = fixture.dir.appendingPathComponent("missing.txt")
        let pile = ShelfStack(frame: CGRect(x: 0, y: 0, width: 204, height: 150))
        pile.configure(urls: [image, text, folder, missing])
        XCTAssertEqual(pile.urls.count, 4)
        let items = pile.draggingItems()
        XCTAssertEqual(items.count, 3)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let writers = items.compactMap { $0.item as? NSPasteboardWriting }
        XCTAssertEqual(writers.count, 3)
        XCTAssertTrue(pasteboard.writeObjects(writers))
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        XCTAssertEqual(Set(urls.map { $0.standardizedFileURL.path }), Set([image, text, folder].map { $0.standardizedFileURL.path }))
        XCTAssertEqual(try String(contentsOf: text), "original")
        pile.configure(urls: [])
        XCTAssertTrue(pile.draggingItems().isEmpty)
    }

    @MainActor func testCompactPileUpdatesWhenFilesAreAddedAndSurvivesEdgeHiding() throws {
        _ = NSApplication.shared
        let fixture = try Fixtures()
        var snapshot = ShelfSnapshot()
        snapshot.edge = .right
        let manager = ShelfManager(storeURL: fixture.dir.appendingPathComponent("shelves.json"))
        let controller = ShelfWindowController(snapshot: snapshot, manager: manager)
        controller.showWindow(nil)
        defer { controller.window?.close() }
        controller.setViewMode(.compact)
        let scroll = try XCTUnwrap(controller.window?.contentView?.subviews.compactMap { $0 as? NSScrollView }.first)
        let pile = try XCTUnwrap(scroll.documentView as? ShelfStack)
        controller.add([try fixture.text("new.txt", "content")])
        XCTAssertEqual(pile.urls.count, 1)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(pile.bounds.height, 124)
        controller.collapse()
        XCTAssertTrue(controller.isCollapsed)
        controller.reveal()
        XCTAssertEqual(controller.snapshot.viewMode, .compact)
        XCTAssertTrue(controller.window!.isVisible)
    }

    func testRemoveAfterDragPreferenceDefaultsOffAndPersists() throws {
        let suite = "mandarine-shelf-drag-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = Settings(defaults: defaults)
        XCTAssertFalse(settings.removeShelfFilesAfterDrag)
        settings.removeShelfFilesAfterDrag = true
        XCTAssertTrue(Settings(defaults: defaults).removeShelfFilesAfterDrag)
    }

    @MainActor func testSuccessfulExportRemovesOnlyDraggedReferencesInEveryView() throws {
        _ = NSApplication.shared
        for mode in [ShelfViewMode.list, .grid, .compact] {
            let fixture = try Fixtures()
            let suite = "mandarine-shelf-drag-" + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = Settings(defaults: defaults)
            settings.removeShelfFilesAfterDrag = true
            let first = try fixture.text("one.txt", "original one")
            let second = try fixture.text("two.txt", "original two")
            let added = try fixture.text("added.txt", "new")
            let store = fixture.dir.appendingPathComponent("shelves.json")
            var snapshot = ShelfSnapshot()
            snapshot.viewMode = mode
            snapshot.add([first, second])
            try ShelfStore.save([snapshot], to: store)
            let manager = ShelfManager(storeURL: store, settings: settings)
            manager.restore()
            let controller = try XCTUnwrap(manager.windows.first)
            defer { controller.window?.close() }
            let scroll = try XCTUnwrap(controller.window?.contentView?.subviews.compactMap { $0 as? NSScrollView }.first)
            if let pile = scroll.documentView as? ShelfStack {
                pile.dragBegan?([first, second])
                controller.add([added])
                pile.dragEnded?(.copy)
                XCTAssertEqual(controller.snapshot.files.map(\.path), [added.standardizedFileURL.path])
            } else {
                controller.beginOutgoingDrag(urls: [first])
                controller.add([added])
                controller.finishOutgoingDrag(operation: .copy)
                XCTAssertEqual(controller.snapshot.files.map(\.path), [second, added].map { $0.standardizedFileURL.path })
            }
            XCTAssertEqual(try ShelfStore.load(from: store)[0].files.count, controller.snapshot.files.count)
            XCTAssertEqual(try String(contentsOf: first), "original one")
            XCTAssertEqual(try String(contentsOf: second), "original two")
        }
    }

    @MainActor func testCancelledAndInternalDragsKeepShelfReferences() throws {
        _ = NSApplication.shared
        let fixture = try Fixtures()
        let suite = "mandarine-shelf-drag-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = Settings(defaults: defaults)
        let source = try fixture.text("original.txt", "keep")
        var snapshot = ShelfSnapshot()
        snapshot.add([source])
        let manager = ShelfManager(storeURL: fixture.dir.appendingPathComponent("shelves.json"), settings: settings)
        let controller = ShelfWindowController(snapshot: snapshot, manager: manager, settings: settings)
        controller.showWindow(nil)
        defer { controller.window?.close() }
        controller.beginOutgoingDrag(urls: [source])
        controller.finishOutgoingDrag(operation: .copy)
        XCTAssertEqual(controller.snapshot.files.count, 1, "Default off")
        settings.removeShelfFilesAfterDrag = true
        for mode in [ShelfViewMode.list, .grid, .compact] {
            controller.setViewMode(mode)
            controller.beginOutgoingDrag(urls: [source])
            controller.finishOutgoingDrag(operation: [])
            XCTAssertEqual(controller.snapshot.files.count, 1, "Cancelled drag")
            controller.finishOutgoingDrag(operation: .copy)
            XCTAssertEqual(controller.snapshot.files.count, 1, "Cancelled state is cleared")
            controller.beginOutgoingDrag(urls: [source])
            let scroll = try XCTUnwrap(controller.window?.contentView?.subviews.compactMap { $0 as? NSScrollView }.first)
            ShelfDrag.acceptInternalDrop(from: scroll.documentView)
            controller.finishOutgoingDrag(operation: .copy)
            XCTAssertEqual(controller.snapshot.files.count, 1, "Internal drop")
        }
        XCTAssertEqual(try String(contentsOf: source), "keep")
    }

    @MainActor func testOptionDropTargetReusesShelfWithoutAddingDraggedFiles() throws {
        _ = NSApplication.shared
        let fixture = try Fixtures()
        let manager = ShelfManager(storeURL: fixture.dir.appendingPathComponent("shelves.json"))
        manager.showForDrop(at: CGPoint(x: 250, y: 350))
        XCTAssertEqual(manager.windows.count, 1)
        let shelf = try XCTUnwrap(manager.windows.first)
        defer { shelf.window?.close() }
        XCTAssertTrue(shelf.snapshot.files.isEmpty)
        manager.showForDrop(at: CGPoint(x: 350, y: 350))
        XCTAssertEqual(manager.windows.count, 1)
        shelf.snapshot.edge = .left
        shelf.collapse()
        manager.showForDrop(at: CGPoint(x: 400, y: 400))
        XCTAssertFalse(shelf.isCollapsed)
        XCTAssertEqual(shelf.snapshot.edge, .left)
    }

    @MainActor func testCitrusToggleKeepsThePersistedPreferenceInSync() throws {
        _ = NSApplication.shared
        let fixture = try Fixtures()
        let suite = "mandarine-citrus-toggle-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = Settings(defaults: defaults)
        let manager = ShelfManager(storeURL: fixture.dir.appendingPathComponent("shelves.json"), settings: settings)
        let controller = ShelfWindowController(snapshot: ShelfSnapshot(), manager: manager, settings: settings)
        defer { controller.window?.close() }
        let content = try XCTUnwrap(controller.window?.contentView)
        let toggle = try XCTUnwrap(content.subviews.compactMap { $0 as? ShelfRemoveToggle }.first)
        XCTAssertEqual(toggle.state, .off)
        toggle.performClick(nil)
        XCTAssertTrue(settings.removeShelfFilesAfterDrag)
        XCTAssertTrue(Settings(defaults: defaults).removeShelfFilesAfterDrag)
        settings.removeShelfFilesAfterDrag = false
        XCTAssertEqual(toggle.state, .off)
    }

    @MainActor func testShelfHeaderHasOnlyCountAndThreeEyedTitlebarIcon() throws {
        _ = NSApplication.shared
        let fixture = try Fixtures()
        var snapshot = ShelfSnapshot()
        snapshot.add([try fixture.text("sample.txt", "test")])
        let manager = ShelfManager(storeURL: fixture.dir.appendingPathComponent("shelves.json"))
        let controller = ShelfWindowController(snapshot: snapshot, manager: manager)
        defer { controller.window?.close() }
        let window = try XCTUnwrap(controller.window)
        XCTAssertEqual(window.title, "1 file")
        XCTAssertEqual(window.titlebarAccessoryViewControllers.count, 1)
        let mark = try XCTUnwrap(window.titlebarAccessoryViewControllers.first?.view as? NSImageView)
        XCTAssertNotNil(mark.image)
        func labels(_ view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { labels($0) }
        }
        let content = try XCTUnwrap(window.contentView)
        XCTAssertFalse(labels(content).contains { !$0.isHidden && ["Shelf", "Scaffale"].contains($0.stringValue) })
        controller.setViewMode(.compact)
        XCTAssertEqual(window.title, "1 file")
        controller.add([try fixture.text("second.txt", "test")])
        XCTAssertEqual(window.title, "2 files")
        XCTAssertEqual(ShelfCitrus.fileCount(0), "0 files")
    }

    @MainActor func testWheelOffersShelvesForArbitraryFiles() {
        let items = WheelBuilder.items(kind: .actions, files: [URL(fileURLWithPath: "/tmp/file.unknown")])
        XCTAssertTrue(items.contains { $0.title == "Shelf" && $0.silent && $0.batch != nil })
        XCTAssertTrue(items.contains { $0.title == "Add to Shelf" && $0.silent && $0.batch != nil })
    }
}
