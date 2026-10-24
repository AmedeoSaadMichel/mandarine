import AppKit
import SwiftUI
import QuickLookThumbnailing

enum ShelfCitrus {
    static func fileCount(_ count: Int) -> String { count == 1 ? "1 file" : "\(count) files" }
    static let background = NSColor(srgbRed: 25/255, green: 17/255, blue: 35/255, alpha: 1)
    static let surface = NSColor(srgbRed: 43/255, green: 30/255, blue: 56/255, alpha: 1)
    static let border = NSColor(srgbRed: 89/255, green: 65/255, blue: 109/255, alpha: 1)
    static let cream = NSColor(srgbRed: 1, green: 239/255, blue: 185/255, alpha: 1)
    static let muted = NSColor(srgbRed: 190/255, green: 165/255, blue: 211/255, alpha: 1)
    static let mint = NSColor(srgbRed: 137/255, green: 225/255, blue: 180/255, alpha: 1)
    static let yellow = NSColor(srgbRed: 1, green: 225/255, blue: 103/255, alpha: 1)
    static let selected = NSColor(srgbRed: 41/255, green: 59/255, blue: 58/255, alpha: 1)
    static func heading(_ size: CGFloat) -> NSFont {
        _ = CitrusEditor.heading(size)
        return NSFont(name: "LilitaOne", size: size) ?? .systemFont(ofSize: size, weight: .heavy)
    }
    static func detail(for url: URL) -> String {
        let ext = url.pathExtension.uppercased()
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]) else { return "Unavailable" }
        if values.isDirectory == true { return "Folder" }
        let size = ByteCountFormatter.string(fromByteCount: Int64(values.fileSize ?? 0), countStyle: .file)
        return ext.isEmpty ? size : "\(ext) · \(size)"
    }
    /// The same native vector mark as the editors, rasterized at the display scale.
    static func mark(size: CGFloat) -> NSImage {
        let view = NSHostingView(rootView: WheelCitrusMark())
        view.frame = CGRect(x: 0, y: 0, width: size, height: size)
        let image = NSImage(size: view.frame.size)
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            image.addRepresentation(bitmap)
        }
        return image
    }
}

final class ShelfCitrusRow: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {
        ShelfCitrus.surface.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 3), xRadius: 9, yRadius: 9).fill()
    }
    override func drawSelection(in dirtyRect: NSRect) {
        ShelfCitrus.selected.setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 3), xRadius: 9, yRadius: 9)
        path.fill()
        ShelfCitrus.mint.setStroke()
        path.stroke()
    }
}

/// A reusable, cancellable native thumbnail for list rows.
final class ShelfThumbnailView: NSImageView {
    private var request: QLThumbnailGenerator.Request?
    init(url: URL) {
        super.init(frame: .zero)
        image = NSWorkspace.shared.icon(forFile: url.path)
        imageScaling = .scaleProportionallyUpOrDown
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.masksToBounds = true
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: NSSize(width: 60, height: 40), scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .all)
        self.request = request
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] result, _ in
            DispatchQueue.main.async { [weak self] in
                if let result { self?.image = result.nsImage }
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let request { QLThumbnailGenerator.shared.cancel(request) } }
}

final class ShelfChrome: NSStackView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        ShelfCitrus.background.setFill()
        bounds.fill()
        ShelfCitrus.border.setStroke()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12).stroke()
    }
}

/// Keep native segmented-control hit testing, keyboard navigation and AX values.
final class ShelfViewPicker: NSSegmentedControl {
    override func draw(_ dirtyRect: NSRect) {
        ShelfCitrus.surface.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
        let width = bounds.width / CGFloat(max(1, segmentCount))
        for index in 0..<segmentCount {
            let frame = NSRect(x: CGFloat(index) * width + 2, y: 2, width: width - 4, height: bounds.height - 4)
            if index == selectedSegment {
                ShelfCitrus.mint.setFill()
                NSBezierPath(roundedRect: frame, xRadius: 7, yRadius: 7).fill()
            }
            let color = index == selectedSegment ? ShelfCitrus.background : ShelfCitrus.muted
            color.setStroke()
            color.setFill()
            let x = frame.midX - 6, y = frame.midY - 6
            if index == 0 {
                let path = NSBezierPath()
                for offset in [CGFloat(1), 6, 11] { path.move(to: NSPoint(x: x, y: y + offset)); path.line(to: NSPoint(x: x + 12, y: y + offset)) }
                path.lineWidth = 1.5
                path.stroke()
            } else if index == 1 {
                for dx in [CGFloat(0), 7] { for dy in [CGFloat(0), 7] { NSBezierPath(roundedRect: NSRect(x: x + dx, y: y + dy, width: 5, height: 5), xRadius: 1, yRadius: 1).fill() } }
            } else {
                for offset in [CGFloat(4), 2, 0] {
                    let path = NSBezierPath(roundedRect: NSRect(x: x + offset / 2, y: y + offset, width: 11, height: 8), xRadius: 2, yRadius: 2)
                    ShelfCitrus.surface.setFill()
                    path.fill()
                    color.setStroke()
                    path.lineWidth = 1.3
                    path.stroke()
                }
            }
        }
    }
}

final class ShelfRemoveToggle: NSButton {
    override func draw(_ dirtyRect: NSRect) {
        let track = NSRect(x: 0, y: (bounds.height - 14) / 2, width: 26, height: 14)
        (state == .on ? ShelfCitrus.mint : ShelfCitrus.border).setFill()
        NSBezierPath(roundedRect: track, xRadius: 7, yRadius: 7).fill()
        (state == .on ? ShelfCitrus.background : ShelfCitrus.cream).setFill()
        NSBezierPath(ovalIn: NSRect(x: state == .on ? 14 : 3, y: track.minY + 3, width: 8, height: 8)).fill()
        (title as NSString).draw(in: NSRect(x: 34, y: (bounds.height - 14) / 2, width: bounds.width - 34, height: 16), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: ShelfCitrus.cream])
        if window?.firstResponder === self {
            ShelfCitrus.mint.setStroke()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5).stroke()
        }
    }
}
