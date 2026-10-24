import AppKit
import Quartz
import SwiftUI
import Combine

struct ShelfFile: Codable {
    var path: String
    var bookmark: Data?

    init(url: URL) {
        path = url.standardizedFileURL.path
        bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    var url: URL {
        var stale = false
        if let bookmark, let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale) {
            return resolved
        }
        return URL(fileURLWithPath: path)
    }
}

enum ShelfEdge: String, Codable { case left, right }

struct ShelfSnapshot: Codable {
    var id = UUID()
    var files: [ShelfFile] = []
    var frame = CGRect(x: 180, y: 180, width: 340, height: 300)
    var edge: ShelfEdge?
    var expandedFrame: CGRect?
    var expandedViewMode: ShelfViewMode?
    private var storedViewMode: ShelfViewMode?
    var viewMode: ShelfViewMode {
        get { storedViewMode ?? .list }
        set { storedViewMode = newValue }
    }
    enum CodingKeys: String, CodingKey {
        case id, files, frame, edge, expandedFrame, expandedViewMode
        case storedViewMode = "viewMode"
    }

    mutating func add(_ urls: [URL]) {
        var known = Set(files.map { $0.url.standardizedFileURL.path })
        for url in urls where url.isFileURL {
            if known.insert(url.standardizedFileURL.path).inserted { files.append(ShelfFile(url: url)) }
        }
    }
}

enum ShelfGeometry {
    static func edge(for frame: CGRect, screen: CGRect) -> ShelfEdge? {
        if abs(frame.minX - screen.minX) <= 24 { return .left }
        if abs(frame.maxX - screen.maxX) <= 24 { return .right }
        return nil
    }

    static func fit(_ frame: CGRect, screen: CGRect, edge: ShelfEdge?, minimum: CGSize = CGSize(width: 280, height: 180)) -> CGRect {
        var r = frame
        r.size.width = min(max(minimum.width, r.width), screen.width)
        r.size.height = min(max(minimum.height, r.height), screen.height)
        r.origin.x = min(max(r.minX, screen.minX), screen.maxX - r.width)
        r.origin.y = min(max(r.minY, screen.minY), screen.maxY - r.height)
        if let edge { r.origin.x = edge == .left ? screen.minX : screen.maxX - r.width }
        return r
    }
}

enum ShelfStore {
    static var location: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mandarine/shelves.json")
    }
    static func load(from url: URL = location) throws -> [ShelfSnapshot] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([ShelfSnapshot].self, from: Data(contentsOf: url))
    }
    static func save(_ shelves: [ShelfSnapshot], to url: URL = location) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(shelves).write(to: url, options: .atomic)
    }
}

@MainActor
final class ShelfManager {
    static let shared = ShelfManager()
    private(set) var windows: [ShelfWindowController] = []
    private(set) var lastUsed: ShelfWindowController?
    private let storeURL: URL
    private let settings: Settings
    init(storeURL: URL = ShelfStore.location, settings: Settings = .shared) { self.storeURL = storeURL; self.settings = settings }
    private var restoring = false
    private var persistenceFailed = false
    private var preserveUnreadableStore = false

    func restore() {
        restoring = true
        do {
            for snapshot in try ShelfStore.load(from: storeURL) { open(snapshot) }
        } catch {
            // Preserve the unreadable state before allowing any subsequent saves.
            do {
                let backup = storeURL.deletingLastPathComponent().appendingPathComponent("shelves-unreadable-" + UUID().uuidString + ".json")
                try FileManager.default.copyItem(at: storeURL, to: backup)
            } catch { preserveUnreadableStore = true }
            report(error)
        }
        restoring = false
    }

    func create(files: [URL] = []) {
        var snapshot = ShelfSnapshot()
        snapshot.add(files)
        snapshot.frame.origin = NSEvent.mouseLocation
        open(snapshot)
        save()
    }

    private func open(_ snapshot: ShelfSnapshot) {
        let controller = ShelfWindowController(snapshot: snapshot, manager: self, settings: settings)
        windows.append(controller)
        lastUsed = controller
        controller.showWindow(nil)
    }

    func showForDrop(at point: CGPoint) {
        if windows.isEmpty { create() }
        (lastUsed ?? windows.last)?.prepareForDrop(at: point)
    }

    func addToLast(_ files: [URL]) {
        guard let target = lastUsed ?? windows.last else { create(files: files); return }
        target.add(files)
        target.showWindow(nil)
    }

    func used(_ controller: ShelfWindowController) { lastUsed = controller }
    func removed(_ controller: ShelfWindowController) {
        windows.removeAll { $0 === controller }
        if lastUsed === controller { lastUsed = windows.last }
        save()
    }
    func showAll() { for controller in windows { controller.showWindow(nil) } }
    func save() {
        guard !restoring, !preserveUnreadableStore else { return }
        do {
            try ShelfStore.save(windows.map { $0.snapshot }, to: storeURL)
            persistenceFailed = false
        } catch { report(error) }
    }
    private func report(_ error: Error) {
        guard !persistenceFailed else { return }
        persistenceFailed = true
        let alert = NSAlert()
        alert.messageText = "Unable to save or restore shelves"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}

final class ShelfPanel: NSPanel {
    weak var shelf: ShelfWindowController?
    override var canBecomeKey: Bool { true }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = shelf
        panel.delegate = shelf
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }
}

final class ShelfTable: NSTableView, ShelfDragOrigin {
    var internalDropAccepted: (() -> Void)?
    var preview: (() -> Void)?
    var remove: (() -> Void)?
    var open: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: preview?()
        case 51, 117: remove?()
        case 36: open?()
        default: super.keyDown(with: event)
        }
    }
}

final class ShelfWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, QLPreviewPanelDataSource, QLPreviewPanelDelegate, NSCollectionViewDataSource, NSCollectionViewDelegate {
    var snapshot: ShelfSnapshot
    private weak var manager: ShelfManager?
    private let table = ShelfTable()
    private let grid = ShelfGrid()
    private let scroll = NSScrollView()
    private let viewPicker = ShelfViewPicker()
    private let pile = ShelfStack()
    private let heading = NSTextField(labelWithString: "Shelf")
    private let subtitle = NSTextField(labelWithString: "")
    private let selectionHint = NSTextField(labelWithString: "⌥ Shelf · Space: Quick Look")
    private let removeToggle = ShelfRemoveToggle(checkboxWithTitle: "Remove after dragging", target: nil, action: nil)
    private let safetyHint = NSTextField(labelWithString: "Original files stay in place.")
    private var settingsObservation: AnyCancellable?
    private let hint = NSTextField(wrappingLabelWithString: "Drop files here · Space: Quick Look\n⌫: remove from shelf · Drag the title bar to an edge to dock")
    private var minimumSize: NSSize { snapshot.viewMode == .compact ? NSSize(width: 260, height: 180) : NSSize(width: 320, height: 300) }
    private var adjusting = false
    private(set) var isCollapsed = false
    private(set) var edgeTabPanel: NSPanel?
    private let edgeTab = ShelfEdgeTab(frame: .zero)
    private var hidePolicy = ShelfAutoHide()
    private var edgeTimer: Timer?
    private var closed = false
    private let shelfSettings: Settings
    private var outgoingPaths: Set<String> = []
    private var removeOnCompletion = false
    private var internalDrop = false

    init(snapshot: ShelfSnapshot, manager: ShelfManager, settings: Settings = .shared) {
        self.snapshot = snapshot
        self.manager = manager
        self.shelfSettings = settings
        let panel = ShelfPanel(contentRect: snapshot.frame, styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.shelf = self
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = ShelfCitrus.background
        panel.titlebarAppearsTransparent = true
        let titleMark = NSTitlebarAccessoryViewController()
        let titleImage = NSImageView(frame: NSRect(x: 0, y: 0, width: 22, height: 20))
        titleImage.image = ShelfCitrus.mark(size: 20)
        titleImage.setAccessibilityLabel("Mandarine")
        titleMark.view = titleImage
        titleMark.layoutAttribute = .left
        panel.addTitlebarAccessoryViewController(titleMark)
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = minimumSize
        let screen = NSScreen.screens.first { $0.visibleFrame.intersects(snapshot.frame) } ?? NSScreen.main
        if let screen { panel.setFrame(ShelfGeometry.fit(snapshot.frame, screen: screen.visibleFrame, edge: snapshot.edge, minimum: minimumSize), display: false) }
        self.snapshot.frame = panel.frame

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.title = "File"
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 58
        table.backgroundColor = ShelfCitrus.background
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.preview = { [weak self] in self?.togglePreview() }
        table.remove = { [weak self] in self?.removeSelected() }
        table.open = { [weak self] in self?.openSelected() }
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 144, height: 158)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        grid.collectionViewLayout = layout
        grid.register(ShelfGridItem.self, forItemWithIdentifier: ShelfGridItem.identifier)
        grid.isSelectable = true
        grid.allowsMultipleSelection = true
        grid.dataSource = self
        grid.delegate = self
        grid.backgroundColors = [ShelfCitrus.background]
        grid.registerForDraggedTypes([.fileURL])
        grid.setDraggingSourceOperationMask(.copy, forLocal: false)
        grid.setDraggingSourceOperationMask(.copy, forLocal: true)
        grid.preview = { [weak self] in self?.togglePreview() }
        grid.remove = { [weak self] in self?.removeSelected() }
        grid.open = { [weak self] in self?.openSelected() }
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = ShelfCitrus.background
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay
        scroll.documentView = table
        viewPicker.segmentCount = 3
        viewPicker.trackingMode = .selectOne
        viewPicker.segmentStyle = .separated
        viewPicker.selectedSegmentBezelColor = ShelfCitrus.mint
        viewPicker.controlSize = .small
        viewPicker.setLabel("List", forSegment: 0)
        viewPicker.setLabel("Grid", forSegment: 1)
        viewPicker.setLabel("Stack", forSegment: 2)
        viewPicker.setImage(NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "Compact stack"), forSegment: 2)
        viewPicker.setToolTip("Compact stack: drag all files together", forSegment: 2)
        viewPicker.setImage(NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "List"), forSegment: 0)
        viewPicker.setImage(NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Grid"), forSegment: 1)
        viewPicker.setToolTip("List view", forSegment: 0)
        viewPicker.setToolTip("Grid view with thumbnails", forSegment: 1)
        viewPicker.setAccessibilityLabel("Shelf view")
        viewPicker.target = self
        viewPicker.action = #selector(changeViewMode)
        heading.isHidden = true
        heading.font = ShelfCitrus.heading(25)
        heading.textColor = ShelfCitrus.cream
        subtitle.font = .systemFont(ofSize: 10)
        subtitle.textColor = ShelfCitrus.muted
        subtitle.lineBreakMode = .byTruncatingTail
        let titles = NSStackView(views: [heading, subtitle])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 1
        let mark = NSHostingView(rootView: WheelCitrusMark())
        mark.translatesAutoresizingMaskIntoConstraints = false
        mark.widthAnchor.constraint(equalToConstant: 30).isActive = true
        mark.heightAnchor.constraint(equalToConstant: 30).isActive = true
        heading.lineBreakMode = .byTruncatingTail
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        viewPicker.setContentCompressionResistancePriority(.required, for: .horizontal)
        let spacer = NSView()
        let toolbar = NSStackView(views: [mark, titles, spacer, viewPicker])
        toolbar.orientation = .horizontal
        toolbar.setHuggingPriority(.defaultLow, for: .horizontal)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = ShelfCitrus.muted
        hint.stringValue = "Drop files here · ⌫ removes references\nDrag the title bar to an edge to dock."
        selectionHint.font = .systemFont(ofSize: 10, weight: .medium)
        selectionHint.textColor = ShelfCitrus.mint
        selectionHint.lineBreakMode = .byTruncatingTail
        removeToggle.font = .systemFont(ofSize: 11)
        removeToggle.contentTintColor = ShelfCitrus.mint
        removeToggle.target = self
        removeToggle.action = #selector(toggleRemoveAfterDrag)
        removeToggle.toolTip = "Removes references only, after a successful drop."
        safetyHint.font = .systemFont(ofSize: 10)
        safetyHint.textColor = ShelfCitrus.muted
        settingsObservation = shelfSettings.$removeShelfFilesAfterDrag.sink { [weak self] enabled in
            self?.removeToggle.state = enabled ? .on : .off
            self?.removeToggle.needsDisplay = true
        }
        let stack = ShelfChrome(views: [toolbar, selectionHint, scroll, hint, removeToggle, safetyHint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        for view in [toolbar, selectionHint, scroll, hint, removeToggle, safetyHint] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }
        pile.expand = { [weak self] in
            guard let self else { return }
            self.setViewMode(self.snapshot.expandedViewMode == .list ? .list : .grid)
        }
        table.internalDropAccepted = { [weak self] in self?.internalDrop = true }
        grid.internalDropAccepted = { [weak self] in self?.internalDrop = true }
        pile.internalDropAccepted = { [weak self] in self?.internalDrop = true }
        pile.dragBegan = { [weak self] in self?.beginOutgoingDrag(urls: $0) }
        pile.dragEnded = { [weak self] in self?.finishOutgoingDrag(operation: $0) }
        pile.preview = { [weak self] in self?.togglePreview() }
        pile.receive = { [weak self] in self?.add($0) }
        panel.contentView = stack
        applyViewMode(selection: [])
        updateTitle()
        edgeTab.reveal = { [weak self] in self?.reveal() }
        edgeTab.receive = { [weak self] urls in self?.add(urls); self?.reveal() }
        NotificationCenter.default.addObserver(self, selector: #selector(screenLayoutChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    deinit { edgeTimer?.invalidate(); NotificationCenter.default.removeObserver(self) }

    override func showWindow(_ sender: Any?) {
        reveal()
        window?.makeKeyAndOrderFront(sender)
        if edgeTimer == nil {
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                self?.updateEdgeVisibility()
            }
            edgeTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func prepareForDrop(at point: CGPoint) {
        guard let window, !closed else { return }
        if snapshot.edge == nil,
           let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main {
            adjusting = true
            var frame = window.frame
            frame.origin = CGPoint(x: point.x + 24, y: point.y - frame.height / 2)
            frame = ShelfGeometry.fit(frame, screen: screen.visibleFrame, edge: nil, minimum: minimumSize)
            window.setFrame(frame, display: true)
            snapshot.frame = frame
            adjusting = false
            manager?.save()
        }
        reveal()
    }

    func reveal() {
        guard !closed else { return }
        isCollapsed = false
        hidePolicy.hold(at: ProcessInfo.processInfo.systemUptime)
        let wasAdjusting = adjusting
        adjusting = true
        window?.orderFrontRegardless()
        adjusting = wasAdjusting
        // Keep the tab under the shelf while a drag retargets to the table.
        if let tab = edgeTabPanel, let window { tab.order(.below, relativeTo: window.windowNumber) }
    }

    func collapse() {
        guard !closed, snapshot.edge != nil, let window else { return }
        configureEdgeTab()
        guard let tab = edgeTabPanel else { return }
        isCollapsed = true
        tab.orderFrontRegardless()
        window.orderOut(nil)
    }

    private func configureEdgeTab() {
        guard let edge = snapshot.edge,
              let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(snapshot.frame) }) ?? NSScreen.main else { return }
        if edgeTabPanel == nil {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = edgeTab
            edgeTabPanel = panel
        }
        edgeTab.count = snapshot.files.count
        edgeTabPanel?.setFrame(ShelfEdgeTabGeometry.frame(shelf: snapshot.frame, screen: screen.visibleFrame, edge: edge), display: true)
    }

    func updateEdgeVisibility(pointer: CGPoint? = nil, time: TimeInterval? = nil) {
        guard !closed, snapshot.edge != nil, let window else { return }
        let point = pointer ?? NSEvent.mouseLocation
        if isCollapsed {
            if edgeTabPanel?.frame.contains(point) == true { reveal() }
            return
        }
        let previewing = QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared()?.isVisible == true && QLPreviewPanel.shared()?.dataSource === self
        if hidePolicy.shouldHide(at: time ?? ProcessInfo.processInfo.systemUptime,
                                 pointerInside: window.frame.contains(point),
                                 interacting: NSEvent.pressedMouseButtons != 0 || previewing || window.attachedSheet != nil) {
            collapse()
        }
    }

    @objc private func screenLayoutChanged() {
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(snapshot.frame) }) ?? NSScreen.main else { return }
        adjusting = true
        snapshot.frame = ShelfGeometry.fit(snapshot.frame, screen: screen.visibleFrame, edge: snapshot.edge, minimum: minimumSize)
        window?.setFrame(snapshot.frame, display: true)
        adjusting = false
        configureEdgeTab()
        manager?.save()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private var selectedIndexes: IndexSet {
        switch snapshot.viewMode {
        case .list: return table.selectedRowIndexes
        case .grid: return IndexSet(grid.selectionIndexPaths.map(\.item))
        case .compact: return IndexSet(snapshot.files.indices)
        }
    }
    private var selectedURLs: [URL] { selectedIndexes.compactMap { snapshot.files.indices.contains($0) ? snapshot.files[$0].url : nil } }

    @objc private func changeViewMode() {
        setViewMode(viewPicker.selectedSegment == 2 ? .compact : viewPicker.selectedSegment == 1 ? .grid : .list)
    }
    func setViewMode(_ mode: ShelfViewMode) {
        guard snapshot.viewMode != mode else { return }
        let selection = selectedIndexes
        let wasCompact = snapshot.viewMode == .compact
        if mode == .compact {
            snapshot.expandedFrame = snapshot.frame
            snapshot.expandedViewMode = snapshot.viewMode
        }
        snapshot.viewMode = mode
        adjusting = true
        window?.minSize = minimumSize
        if let window, let screen = window.screen ?? NSScreen.main {
            var frame = window.frame
            if mode == .compact {
                frame = CGRect(x: frame.minX, y: frame.maxY - 218, width: 260, height: 218)
            } else if wasCompact, let expanded = snapshot.expandedFrame {
                frame = CGRect(x: frame.minX, y: frame.maxY - expanded.height, width: expanded.width, height: expanded.height)
            }
            frame = ShelfGeometry.fit(frame, screen: screen.visibleFrame, edge: snapshot.edge, minimum: minimumSize)
            window.setFrame(frame, display: true)
            snapshot.frame = frame
        }
        adjusting = false
        if snapshot.edge != nil { configureEdgeTab() }
        applyViewMode(selection: selection)
        manager?.used(self)
        manager?.save()
    }
    private func applyViewMode(selection: IndexSet) {
        let compact = snapshot.viewMode == .compact
        viewPicker.selectedSegment = compact ? 2 : snapshot.viewMode == .grid ? 1 : 0
        viewPicker.needsDisplay = true
        subtitle.isHidden = compact
        heading.font = ShelfCitrus.heading(compact ? 18 : 25)
        selectionHint.isHidden = compact
        removeToggle.isHidden = compact
        safetyHint.isHidden = compact
        hint.isHidden = compact
        for index in 0..<3 { viewPicker.setLabel("", forSegment: index) }
        if compact {
            pile.configure(urls: snapshot.files.map(\.url))
            pile.frame = NSRect(origin: .zero, size: scroll.contentSize)
            pile.autoresizingMask = [.width, .height]
            scroll.documentView = pile
            window?.makeFirstResponder(pile)
        } else if snapshot.viewMode == .grid {
            grid.frame = NSRect(origin: .zero, size: scroll.contentSize)
            grid.autoresizingMask = [.width]
            scroll.documentView = grid
            grid.reloadData()
            grid.selectionIndexPaths = Set(selection.map { IndexPath(item: $0, section: 0) })
            window?.makeFirstResponder(grid)
        } else {
            scroll.documentView = table
            table.reloadData()
            table.selectRowIndexes(selection, byExtendingSelection: false)
            window?.makeFirstResponder(table)
        }
    }
    private func reloadFiles() {
        if snapshot.viewMode == .compact { pile.configure(urls: snapshot.files.map(\.url)) }
        table.reloadData()
        grid.reloadData()
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { snapshot.files.count }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: ShelfGridItem.identifier, for: indexPath) as! ShelfGridItem
        item.configure(url: snapshot.files[indexPath.item].url)
        return item
    }
    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        let url = snapshot.files[indexPath.item].url
        return FileManager.default.fileExists(atPath: url.path) ? url as NSURL : nil
    }
    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo, proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>, dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        proposedDropOperation.pointee = .before
        return droppedURLs(draggingInfo).isEmpty ? [] : .copy
    }
    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo, indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        let urls = droppedURLs(draggingInfo)
        guard !urls.isEmpty else { return false }
        ShelfDrag.acceptInternalDrop(from: draggingInfo.draggingSource)
        add(urls)
        return true
    }
    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { selectionChanged() }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { selectionChanged() }
    func add(_ urls: [URL]) {
        snapshot.add(urls)
        reloadFiles()
        updateTitle()
        manager?.used(self)
        manager?.save()
    }
    @objc private func toggleRemoveAfterDrag() {
        shelfSettings.removeShelfFilesAfterDrag = removeToggle.state == .on
    }
    private func updateTitle() {
        window?.title = ShelfCitrus.fileCount(snapshot.files.count)
        edgeTab.count = snapshot.files.count
        subtitle.stringValue = ShelfCitrus.fileCount(snapshot.files.count)
        updateSelectionHint()
    }
    private func updateSelectionHint() {
        let count = selectedIndexes.count
        selectionHint.stringValue = count > 0 ? "✓ \(count) selected · Space: Quick Look" : "⌥ Shelf · Space: Quick Look"
    }
    func numberOfRows(in tableView: NSTableView) -> Int { snapshot.files.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let url = snapshot.files[row].url
        let cell = NSTableCellView()
        let icon = ShelfThumbnailView(url: url)
        let label = NSTextField(labelWithString: url.lastPathComponent)
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = ShelfCitrus.cream
        if !FileManager.default.fileExists(atPath: url.path) { label.textColor = .secondaryLabelColor; label.stringValue += " (unavailable)" }
        let detail = NSTextField(labelWithString: ShelfCitrus.detail(for: url))
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = ShelfCitrus.muted
        let labels = NSStackView(views: [label, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        let stack = NSStackView(views: [icon, labels])
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 54), icon.heightAnchor.constraint(equalToConstant: 38),
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        cell.toolTip = url.path
        return cell
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ShelfCitrusRow() }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let url = snapshot.files[row].url
        return FileManager.default.fileExists(atPath: url.path) ? url as NSURL : nil
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        tableView.setDropRow(-1, dropOperation: .on)
        return droppedURLs(info).isEmpty ? [] : .copy
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        let urls = droppedURLs(info)
        guard !urls.isEmpty else { return false }
        ShelfDrag.acceptInternalDrop(from: info.draggingSource)
        add(urls)
        return true
    }
    func beginOutgoingDrag(urls: [URL]) {
        let dragged = Set(urls.map { $0.standardizedFileURL.path })
        outgoingPaths = Set(snapshot.files.filter { dragged.contains($0.url.standardizedFileURL.path) }.map(\.path))
        removeOnCompletion = shelfSettings.removeShelfFilesAfterDrag
        internalDrop = false
    }
    func finishOutgoingDrag(operation: NSDragOperation) {
        defer { outgoingPaths = []; removeOnCompletion = false; internalDrop = false }
        guard !closed, removeOnCompletion, !internalDrop,
              !operation.intersection([.copy, .move, .link, .generic]).isEmpty else { return }
        // Stable saved paths also match bookmarks whose URLs changed after the drop.
        snapshot.files.removeAll { outgoingPaths.contains($0.path) }
        table.deselectAll(nil)
        grid.selectionIndexPaths = []
        reloadFiles()
        updateTitle()
        selectionChanged()
        manager?.save()
    }
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        beginOutgoingDrag(urls: rowIndexes.compactMap { snapshot.files.indices.contains($0) ? snapshot.files[$0].url : nil }.filter { FileManager.default.fileExists(atPath: $0.path) })
    }
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { finishOutgoingDrag(operation: operation) }
    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>) {
        beginOutgoingDrag(urls: indexPaths.compactMap { snapshot.files.indices.contains($0.item) ? snapshot.files[$0.item].url : nil }.filter { FileManager.default.fileExists(atPath: $0.path) })
    }
    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, dragOperation operation: NSDragOperation) { finishOutgoingDrag(operation: operation) }

    private func droppedURLs(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    func tableViewSelectionDidChange(_ notification: Notification) { selectionChanged() }
    private func selectionChanged() {
        updateSelectionHint()
        manager?.used(self)
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible, panel.dataSource === self {
            panel.reloadData()
        }
    }
    @objc private func openSelected() { for url in selectedURLs { NSWorkspace.shared.open(url) } }
    private func removeSelected() {
        for index in selectedIndexes.reversed() { snapshot.files.remove(at: index) }
        table.deselectAll(nil)
        grid.selectionIndexPaths = []
        reloadFiles()
        updateTitle()
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.dataSource === self { panel.reloadData() }
        manager?.save()
    }
    private func togglePreview() {
        guard !selectedURLs.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible, panel.dataSource === self { panel.orderOut(nil); return }
        window?.makeKeyAndOrderFront(nil)
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { selectedURLs.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        let urls = selectedURLs
        return urls.indices.contains(index) ? urls[index] as NSURL : nil
    }
    func windowDidBecomeKey(_ notification: Notification) { manager?.used(self) }
    func windowDidMove(_ notification: Notification) { positionChanged() }
    func windowDidResize(_ notification: Notification) { positionChanged() }
    private func positionChanged() {
        guard !adjusting, !isCollapsed, let window, let screen = window.screen else { return }
        edgeTabPanel?.orderOut(nil)
        hidePolicy.hold(at: ProcessInfo.processInfo.systemUptime)
        adjusting = true
        let edge = ShelfGeometry.edge(for: window.frame, screen: screen.visibleFrame)
        // Save docking immediately, but snap only after the title-bar drag ends.
        snapshot.edge = edge
        snapshot.frame = window.frame
        adjusting = false
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(snap), object: nil)
        perform(#selector(snap), with: nil, afterDelay: 0.2)
    }
    @objc private func snap() {
        if NSEvent.pressedMouseButtons & 1 != 0 { perform(#selector(snap), with: nil, afterDelay: 0.2); return }
        guard let window, let screen = window.screen else { return }
        adjusting = true
        let frame = ShelfGeometry.fit(window.frame, screen: screen.visibleFrame, edge: snapshot.edge, minimum: minimumSize)
        window.setFrame(frame, display: true)
        snapshot.frame = frame
        adjusting = false
        if snapshot.edge != nil { configureEdgeTab() }
        else { edgeTabPanel?.orderOut(nil) }
        hidePolicy.hold(at: ProcessInfo.processInfo.systemUptime)
        manager?.save()
    }
    func windowWillClose(_ notification: Notification) {
        closed = true
        edgeTimer?.invalidate()
        edgeTimer = nil
        edgeTabPanel?.orderOut(nil)
        edgeTabPanel = nil
        NotificationCenter.default.removeObserver(self)
        NSObject.cancelPreviousPerformRequests(withTarget: self)
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.dataSource === self { panel.orderOut(nil); panel.dataSource = nil; panel.delegate = nil }
        manager?.removed(self)
    }
}
