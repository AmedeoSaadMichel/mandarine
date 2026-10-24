import AppKit
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

struct WheelItem: Identifiable {
    let id = UUID()
    let title: String
    var symbol: String? = nil
    /// Runs once per dragged file, unless `batch` is set.
    let run: (URL) async throws -> Void
    /// Runs once for all dragged files together (merging PDFs, opening a tool…).
    var batch: (([URL]) async throws -> Void)? = nil
    /// Like `run`, but reports 0…1 progress and returns the files it wrote (for the HUD).
    var runWithProgress: ((URL, @escaping @Sendable (Double) -> Void) async throws -> [URL])? = nil
    /// True when the item only opens a window: no "done" sound.
    var silent = false
}

enum FileActions {
    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func duplicate(_ url: URL) throws -> URL {
        let parent = url.deletingLastPathComponent()
        let stage = parent.appendingPathComponent(".mandarine-copy-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: stage) }
        let base = stage.appendingPathComponent(url.deletingPathExtension().lastPathComponent + " copy")
        let copy = url.pathExtension.isEmpty ? base : base.appendingPathExtension(url.pathExtension)
        try FileManager.default.copyItem(at: url, to: copy)
        return try OutputStore.publish(copy, in: parent)
    }

    @MainActor static func copyToPasteboard(files: [URL]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(files as [NSURL])
    }

    @MainActor static func copyToPasteboard(text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @MainActor static func openTerminal(at url: URL) {
        let dir = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        let app = URL(fileURLWithPath: Settings.shared.terminalAppPath)
        NSWorkspace.shared.open([dir], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// "hash  name" lines, as `shasum` prints them.
    static func checksums(_ urls: [URL]) throws -> String {
        try urls.map { "\(try sha256($0))  \($0.lastPathComponent)" }.joined(separator: "\n")
    }
}

/// What the wheel says when it has nothing to offer.
enum WheelEmpty {
    static func message(kind: WheelKind, files: [URL]) -> String? {
        guard !files.isEmpty else { return "Drop files here" }
        let unknown = files.filter { Category.of($0) == nil }
        if kind != .actions, !unknown.isEmpty {
            let name = unknown[0].lastPathComponent
            return unknown.count == 1 ? "Unsupported format:\n\(name)" : "Unsupported format:\n\(name) and \(unknown.count - 1)"
        }
        switch kind {
        case .conversion:
            if !WheelBuilder.items(kind: kind, files: files).isEmpty { return nil }
            return files.count > 1 ? "No conversion formats\nshared by these files" : "No conversion\navailable for\n\(files[0].lastPathComponent)"
        case .tools:
            if !WheelBuilder.items(kind: kind, files: files).isEmpty { return nil }
            return files.count > 1 ? "No tools for this selection:\ntry files of the same type" : "No tools\navailable for\n\(files[0].lastPathComponent)"
        case .actions:
            return nil
        }
    }
}

enum WheelBuilder {
    static func items(kind: WheelKind, files: [URL]) -> [WheelItem] {
        switch kind {
        case .conversion:
            return Converter.targets(for: files).map { ext in
                var item = WheelItem(title: ext.uppercased()) { url in
                    let s = Settings.shared
                    _ = try await Converter.convert(url, to: ext, outputFolder: s.outputFolder, quality: s.quality, prefs: s.prefs(for: ext))
                }
                item.runWithProgress = { url, progress in
                    let s = Settings.shared
                    return [try await Converter.convert(url, to: ext, outputFolder: s.outputFolder, quality: s.quality, prefs: s.prefs(for: ext), progress: progress)]
                }
                return item
            }

        case .tools:
            return ToolID.available(for: files).map { tool in
                WheelItem(title: tool.shortTitle, symbol: tool.symbol, run: { _ in }, batch: { urls in
                    await MainActor.run { ToolWindowManager.shared.open(tool, files: urls) }
                }, silent: true)
            }

        case .actions:
            guard !files.isEmpty else { return [] }
            return [
                WheelItem(title: "Shelf", symbol: "tray", run: { _ in }, batch: { urls in
                    await MainActor.run { ShelfManager.shared.create(files: urls) }
                }, silent: true),
                WheelItem(title: "Add to Shelf", symbol: "tray.and.arrow.down", run: { _ in }, batch: { urls in
                    await MainActor.run { ShelfManager.shared.addToLast(urls) }
                }, silent: true),
                WheelItem(title: "Reveal", symbol: "folder", run: { _ in }, batch: { urls in
                    await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting(urls) }
                }, silent: true),
                WheelItem(title: "Copy files", symbol: "doc.on.doc", run: { _ in }, batch: { urls in
                    await MainActor.run { FileActions.copyToPasteboard(files: urls) }
                }),
                WheelItem(title: "Copy paths", symbol: "link", run: { _ in }, batch: { urls in
                    await MainActor.run { FileActions.copyToPasteboard(text: urls.map(\.path).joined(separator: "\n")) }
                }),
                WheelItem(title: "Duplicate", symbol: "plus.square.on.square", run: { url in _ = try FileActions.duplicate(url) }),
                WheelItem(title: "SHA-256", symbol: "number", run: { _ in }, batch: { urls in
                    let text = try FileActions.checksums(urls)
                    await MainActor.run { FileActions.copyToPasteboard(text: text) }
                }),
                WheelItem(title: "Terminal", symbol: "terminal", run: { _ in }, batch: { urls in
                    guard let first = urls.first else { return }
                    await MainActor.run { FileActions.openTerminal(at: first) }
                }, silent: true),
                WheelItem(title: "Open", symbol: "arrow.up.forward.app", run: { url in
                    await MainActor.run { _ = NSWorkspace.shared.open(url) }
                }, silent: true),
            ]
        }
    }
}

final class WheelNavigation: ObservableObject {
    @Published var selected: Int?
    @Published var hovered: Int?
    func step(_ delta: Int, count: Int) {
        guard count > 0 else { selected = nil; return }
        selected = ((selected ?? (delta > 0 ? -1 : 0)) + delta + count) % count
    }
}

struct WheelView: View {
    @ObservedObject var settings = Settings.shared
    @ObservedObject var navigation = WheelNavigation()
    let kind: WheelKind
    let items: [WheelItem]
    let onDrop: (WheelItem, [URL]) -> Void
    let size: CGFloat
    var message: String? = nil

    static let cell: CGFloat = 64

    /// Panel size that keeps `count` cells from touching each other.
    static func panelSize(for count: Int) -> CGFloat {
        let circumference = Double(max(count, 1)) * Double(cell + 10)
        let radius = max(100.0, circumference / (2 * Double.pi))
        return CGFloat(2 * (radius + Double(cell) / 2 + 16))
    }

    private func offset(_ idx: Int) -> CGSize {
        let count = Double(max(items.count, 1))
        let angle = 2.0 * Double.pi * Double(idx) / count - Double.pi / 2.0
        let r = Double(size) / 2.0 - Double(Self.cell) / 2 - 14.0
        return CGSize(width: cos(angle) * r, height: sin(angle) * r)
    }

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if settings.appearance == .glass && !reduceTransparency {
                Circle().fill(.ultraThinMaterial)
                Circle().fill(WheelCitrus.background.opacity(0.94))
            } else { Circle().fill(WheelCitrus.background) }
            Circle().strokeBorder(WheelCitrus.membrane.opacity(0.65), lineWidth: 1)
            if let message, items.isEmpty {
                VStack(spacing: 10) {
                    WheelCitrusMark().frame(width: 48, height: 48)
                    Text(message).font(.callout).multilineTextAlignment(.center).padding(.horizontal, 36)
                }
                .foregroundStyle(Midnight.cream)
            } else {
                VStack(spacing: 5) {
                    WheelCitrusMark().frame(width: 48, height: 48)
                    Text(kind.title.uppercased()).font(.system(size: 10, weight: .semibold))
                    Text("Choose and drop").font(.system(size: 9)).foregroundStyle(Midnight.muted)
                }
                .foregroundStyle(Midnight.cream)
                .frame(width: size * 0.42, height: size * 0.42)
                .background(Circle().fill(Midnight.panel))
                .overlay(Circle().stroke(Midnight.border.opacity(0.7)))
                .allowsHitTesting(false)
            }
            // Decoration never participates in AppKit's hit testing. Full-panel drop
            // views overlap even when SwiftUI supplies a sector contentShape.
            ForEach(0..<items.count, id: \.self) { idx in
                WheelSector(index: idx, count: items.count)
                    .fill((navigation.hovered ?? navigation.selected) == idx ? WheelCitrus.selected : WheelCitrus.flesh)
                    .overlay(WheelSector(index: idx, count: items.count)
                        .stroke((navigation.hovered ?? navigation.selected) == idx ? WheelCitrus.cream : WheelCitrus.membrane,
                                lineWidth: (navigation.hovered ?? navigation.selected) == idx ? 1.5 : 0.7))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            WheelCitrusTexture(count: items.count, active: navigation.hovered ?? navigation.selected)
            ForEach(0..<items.count, id: \.self) { idx in
                WheelCell(item: items[idx], onDrop: onDrop,
                          selected: (navigation.hovered ?? navigation.selected) == idx,
                          onTargetChange: { targeted in
                              if targeted { navigation.hovered = idx }
                              else if navigation.hovered == idx { navigation.hovered = nil }
                          })
                    .offset(offset(idx))
            }
        }
        .frame(width: size, height: size)
        .preferredColorScheme(.dark)
    }
}

struct WheelCell: View {
    let item: WheelItem
    let onDrop: (WheelItem, [URL]) -> Void
    var selected = false
    var onTargetChange: (Bool) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hover = false
    @State private var pointer = false

    private var active: Bool { hover || pointer || selected }

    var body: some View {
        Button { onDrop(item, []) } label: {
            VStack(spacing: 6) {
                if let symbol = item.symbol { Image(systemName: symbol).font(.system(size: 19, weight: .regular)) }
                Text(item.title)
                    .font(.system(size: item.symbol == nil ? 13 : 11, weight: active ? .semibold : .medium))
                    .lineLimit(1).minimumScaleFactor(0.65)
            }
            .frame(width: WheelView.cell, height: WheelView.cell)
            .foregroundStyle(WheelCitrus.ink)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .accessibilityLabel(item.title)
        .accessibilityHint("Runs the operation on the selected files")
        .accessibilityAddTraits(active ? .isSelected : [])
        .onHover { pointer = $0; onTargetChange($0 || hover) }
        .onChange(of: hover) { onTargetChange($0 || pointer) }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: active)
        .onDrop(of: [.fileURL], isTargeted: $hover) { providers in
            // Providers load asynchronously: keep the dragged order, it matters for merge and join.
            var urls = [URL?](repeating: nil, count: providers.count)
            let group = DispatchGroup()
            let lock = NSLock()
            for (i, p) in providers.enumerated() {
                group.enter()
                p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    if let d = data as? Data, let u = URL(dataRepresentation: d, relativeTo: nil) { lock.lock(); urls[i] = u; lock.unlock() }
                    group.leave()
                }
            }
            group.notify(queue: .main) { onDrop(item, urls.compactMap { $0 }) }
            return true
        }
    }
}

final class WheelPanel: NSPanel {
    private var hideWork: DispatchWorkItem?
    private let navigation = WheelNavigation()
    private var items: [WheelItem] = []
    private var selection: ((WheelItem, [URL]) -> Void)?
    override var canBecomeKey: Bool { true }

    func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            switch event.keyCode {
            case 53: orderOut(nil); return
            case 123, 126: navigation.step(-1, count: items.count); return
            case 124, 125: navigation.step(1, count: items.count); return
            case 36, 76:
                if let index = navigation.selected, items.indices.contains(index) { selection?(items[index], []) }
                return
            default: break
            }
        }
        super.sendEvent(event)
    }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
    }

    func show(kind: WheelKind, files: [URL], at point: NSPoint, interactive: Bool = false, onDrop: @escaping (WheelItem, [URL]) -> Void) {
        hideWork?.cancel()
        navigation.selected = nil
        navigation.hovered = nil
        let items = WheelBuilder.items(kind: kind, files: files)
        self.items = items
        selection = onDrop
        let message = items.isEmpty ? WheelEmpty.message(kind: kind, files: files) : nil
        guard !items.isEmpty || message != nil else { return }
        let size = items.isEmpty ? CGFloat(280) : max(300, WheelView.panelSize(for: items.count))
        let host = NSHostingView(rootView: WheelView(navigation: navigation, kind: kind, items: items, onDrop: onDrop, size: size, message: message))
        host.frame = NSRect(x: 0, y: 0, width: size, height: size)
        contentView = host
        var origin = NSPoint(x: point.x - size / 2, y: point.y - size / 2)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main {
            let f = screen.visibleFrame
            origin.x = min(max(origin.x, f.minX), f.maxX - size)
            origin.y = min(max(origin.y, f.minY), f.maxY - size)
        }
        setFrame(NSRect(origin: origin, size: NSSize(width: size, height: size)), display: true)
        if interactive {
            makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else { orderFrontRegardless() }
    }
}
