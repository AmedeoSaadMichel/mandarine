import AppKit
import QuickLookThumbnailing

/// Every dragging item is a real file URL, so Finder and other apps receive the
/// individual files rather than an image of the pile or an artificial archive.
final class ShelfStack: NSView, NSDraggingSource, ShelfDragOrigin {
    var internalDropAccepted: (() -> Void)?
    var dragBegan: (([URL]) -> Void)?
    var dragEnded: ((NSDragOperation) -> Void)?
    var expand: (() -> Void)?
    var preview: (() -> Void)?
    var receive: (([URL]) -> Void)?
    private(set) var urls: [URL] = []
    private var images: [NSImage] = []
    private var requests: [QLThumbnailGenerator.Request] = []
    private var generation = UUID()
    private var mouseStart: NSPoint?
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(urls: [URL]) {
        cancelRequests()
        self.urls = urls
        images = urls.prefix(3).map { NSWorkspace.shared.icon(forFile: $0.path) }
        setAccessibilityLabel("Stack of \(urls.count) files. Double-click to expand.")
        toolTip = "Drag the stack to transfer all files · Double-click to expand · Space: Quick Look"
        needsDisplay = true
        let token = generation
        for (index, url) in urls.prefix(3).enumerated() where FileManager.default.fileExists(atPath: url.path) {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: NSSize(width: 88, height: 72), scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .all)
            requests.append(request)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] result, _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token, let result, self.images.indices.contains(index) else { return }
                    self.images[index] = result.nsImage
                    self.needsDisplay = true
                }
            }
        }
    }
    private func cancelRequests() {
        generation = UUID()
        for request in requests { QLThumbnailGenerator.shared.cancel(request) }
        requests.removeAll()
    }
    deinit { for request in requests { QLThumbnailGenerator.shared.cancel(request) } }

    override func draw(_ dirtyRect: NSRect) {
        let center = bounds.midX
        for index in images.indices.reversed() {
            let card = NSRect(x: center - 48 + CGFloat(index) * 7, y: 14 + CGFloat(index) * 5, width: 88, height: 72)
            NSGraphicsContext.saveGraphicsState()
            let transform = AffineTransform(translationByX: card.midX, byY: card.midY)
            var rotation = transform
            rotation.rotate(byDegrees: CGFloat(index) * 5 - 5)
            rotation.translate(x: -card.midX, y: -card.midY)
            (rotation as NSAffineTransform).concat()
            ShelfCitrus.cream.setFill()
            NSBezierPath(roundedRect: card, xRadius: 6, yRadius: 6).fill()
            ShelfCitrus.border.setStroke()
            NSBezierPath(roundedRect: card, xRadius: 6, yRadius: 6).stroke()
            images[index].draw(in: card.insetBy(dx: 4, dy: 4), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let title = urls.isEmpty ? "Drop files here" : ShelfCitrus.fileCount(urls.count)
        let badge = NSRect(x: center - 48, y: 104, width: 96, height: 22)
        ShelfCitrus.yellow.setFill()
        NSBezierPath(roundedRect: badge, xRadius: 11, yRadius: 11).fill()
        (title as NSString).draw(in: badge.insetBy(dx: 2, dy: 3), withAttributes: [.font: ShelfCitrus.heading(13), .foregroundColor: ShelfCitrus.background, .paragraphStyle: style])
        if bounds.height > 150 {
            ("Drag the stack · Double-click to expand" as NSString).draw(in: NSRect(x: 4, y: 136, width: bounds.width - 8, height: 18), withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: ShelfCitrus.muted, .paragraphStyle: style])
        }
    }
    /// Missing files stay on the shelf, but cannot be offered to a drag receiver.
    func draggingItems() -> [NSDraggingItem] {
        urls.filter { FileManager.default.fileExists(atPath: $0.path) }.map { url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(NSRect(x: bounds.midX - 32, y: 20, width: 64, height: 64), contents: NSWorkspace.shared.icon(forFile: url.path))
            return item
        }
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 { expand?(); mouseStart = nil }
        else { mouseStart = convert(event.locationInWindow, from: nil) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) > 4 else { return }
        mouseStart = nil
        let items = draggingItems()
        guard !items.isEmpty else { NSSound.beep(); return }
        dragBegan?(items.compactMap { $0.item as? URL })
        let session = beginDraggingSession(with: items, event: event, source: self)
        session.draggingFormation = .pile
        session.animatesToStartingPositionsOnCancelOrFail = true
    }
    override func mouseUp(with event: NSEvent) { mouseStart = nil }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { dragEnded?(operation) }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: preview?()
        case 36: expand?()
        default: super.keyDown(with: event)
        }
    }
    override func accessibilityPerformPress() -> Bool { expand?(); return true }
    private func droppedURLs(_ sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { droppedURLs(sender).isEmpty ? [] : .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !droppedURLs(sender).isEmpty }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = droppedURLs(sender)
        guard !files.isEmpty else { return false }
        ShelfDrag.acceptInternalDrop(from: sender.draggingSource)
        receive?(files)
        return true
    }
}
