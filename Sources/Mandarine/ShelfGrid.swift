import AppKit
import QuickLookThumbnailing

enum ShelfViewMode: String, Codable { case list, grid, compact }

final class ShelfGrid: NSCollectionView, ShelfDragOrigin {
    var internalDropAccepted: (() -> Void)?
    var preview: (() -> Void)?
    var remove: (() -> Void)?
    var open: (() -> Void)?
    override func layout() {
        super.layout()
        guard let layout = collectionViewLayout as? NSCollectionViewFlowLayout else { return }
        let available = max(144, bounds.width - 24)
        let columns = max(1, Int((available + 8) / 152))
        let width = floor((available - CGFloat(columns - 1) * 8) / CGFloat(columns))
        let size = NSSize(width: width, height: 158)
        if layout.itemSize != size { layout.itemSize = size }
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: preview?()
        case 51, 117: remove?()
        case 36: open?()
        default: super.keyDown(with: event)
        }
    }
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 { open?() }
    }
}

final class ShelfGridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ShelfGridItem")
    private var request: QLThumbnailGenerator.Request?
    private var generation = UUID()
    private let detail = NSTextField(labelWithString: "")
    private let check = NSTextField(labelWithString: "✓")

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 12
        view.layer?.borderWidth = 1
        view.layer?.borderColor = ShelfCitrus.border.cgColor
        let preview = NSImageView()
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.alignment = .left
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(preview)
        view.addSubview(label)
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = ShelfCitrus.muted
        detail.lineBreakMode = .byTruncatingTail
        detail.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(detail)
        check.font = .systemFont(ofSize: 12, weight: .bold)
        check.textColor = ShelfCitrus.background
        check.backgroundColor = ShelfCitrus.mint
        check.drawsBackground = true
        check.alignment = .center
        check.wantsLayer = true
        check.layer?.cornerRadius = 8
        check.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(check)
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            preview.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            preview.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
            preview.heightAnchor.constraint(equalToConstant: 100),
            label.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 5),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            detail.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 3),
            detail.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: label.trailingAnchor),
            check.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            check.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            check.widthAnchor.constraint(equalToConstant: 18),
            check.heightAnchor.constraint(equalToConstant: 18)
        ])
        imageView = preview
        textField = label
    }

    override var isSelected: Bool { didSet { updateSelection() } }
    private func updateSelection() {
        view.layer?.backgroundColor = (isSelected ? ShelfCitrus.selected : ShelfCitrus.surface).cgColor
        textField?.textColor = ShelfCitrus.cream
        view.layer?.borderColor = (isSelected ? ShelfCitrus.mint : ShelfCitrus.border).cgColor
        check.isHidden = !isSelected
    }

    func configure(url: URL) {
        _ = view
        cancelThumbnail()
        imageView?.image = NSWorkspace.shared.icon(forFile: url.path)
        let exists = FileManager.default.fileExists(atPath: url.path)
        textField?.stringValue = url.lastPathComponent + (exists ? "" : " (unavailable)")
        detail.stringValue = ShelfCitrus.detail(for: url)
        view.toolTip = url.path
        view.setAccessibilityLabel(textField?.stringValue)
        updateSelection()
        guard exists else { return }
        let token = generation
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 180, height: 100), scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .all)
        self.request = request
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token, let representation else { return }
                self.imageView?.image = representation.nsImage
            }
        }
    }
    private func cancelThumbnail() {
        generation = UUID()
        if let request { QLThumbnailGenerator.shared.cancel(request) }
        request = nil
    }
    override func prepareForReuse() { super.prepareForReuse(); cancelThumbnail(); imageView?.image = nil }
    deinit { if let request { QLThumbnailGenerator.shared.cancel(request) } }
}
