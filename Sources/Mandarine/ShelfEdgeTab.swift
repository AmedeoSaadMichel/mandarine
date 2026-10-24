import AppKit

/// The saved frame always describes the expanded shelf, never this edge tab.
enum ShelfEdgeTabGeometry {
    static func frame(shelf: CGRect, screen: CGRect, edge: ShelfEdge) -> CGRect {
        let height = min(100, screen.height)
        return CGRect(x: edge == .left ? screen.minX : screen.maxX - 26,
                      y: min(max(shelf.midY - height / 2, screen.minY), screen.maxY - height),
                      width: 26, height: height)
    }
}

struct ShelfAutoHide {
    static let delay: TimeInterval = 0.7
    private(set) var lastInteraction: TimeInterval = 0
    mutating func hold(at time: TimeInterval) { lastInteraction = time }
    mutating func shouldHide(at time: TimeInterval, pointerInside: Bool, interacting: Bool) -> Bool {
        if pointerInside || interacting { hold(at: time); return false }
        return time - lastInteraction >= Self.delay
    }
}

/// A native file drop target: it accepts a quick release as well as spring-opening
/// the shelf, so files are not lost if released before the destination changes.
final class ShelfEdgeTab: NSView {
    var reveal: (() -> Void)?
    var receive: (([URL]) -> Void)?
    var count = 0 { didSet { needsDisplay = true; setAccessibilityLabel("Shelf, \(count) files") } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        toolTip = "Shelf: hover or drop files here"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        ShelfCitrus.cream.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8).fill()
        ShelfCitrus.yellow.setFill()
        NSBezierPath(ovalIn: NSRect(x: bounds.midX - 6, y: bounds.midY + 12, width: 12, height: 12)).fill()
        ShelfCitrus.selected.setFill()
        NSBezierPath(ovalIn: NSRect(x: bounds.midX + 1, y: bounds.midY + 21, width: 6, height: 3)).fill()
        let text = "\(count)" as NSString
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        text.draw(in: NSRect(x: 0, y: bounds.midY - 14, width: bounds.width, height: 24), withAttributes: [
            .font: ShelfCitrus.heading(14),
            .foregroundColor: ShelfCitrus.background, .paragraphStyle: style
        ])
    }
    override func mouseDown(with event: NSEvent) { reveal?() }
    override func accessibilityPerformPress() -> Bool { reveal?(); return true }
    func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(from: sender.draggingPasteboard).isEmpty else { return [] }
        reveal?()
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(from: sender.draggingPasteboard).isEmpty ? [] : .copy
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !fileURLs(from: sender.draggingPasteboard).isEmpty
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        ShelfDrag.acceptInternalDrop(from: sender.draggingSource)
        receive?(urls)
        return true
    }
}
