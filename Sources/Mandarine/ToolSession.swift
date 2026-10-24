import AppKit
import PDFKit
import SwiftUI

/// State of one open tool window.
@MainActor
final class ToolSession: ObservableObject, Identifiable {
    let id = UUID()
    let tool: ToolID
    @Published var files: [URL]
    let params: [ToolParam]
    @Published var values: ToolValues
    /// Source picture for area pickers (first image, or a video frame).
    @Published var baseImage: CGImage?
    /// Live preview for tools that change every pixel.
    @Published var previewImage: NSImage?
    /// Size of the original picture or video, in pixels.
    @Published var sourceSize: CGSize?
    @Published var previewTime = 0.0
    @Published var duration = 0.0
    @Published var running = false
    @Published var progress = 0.0
    @Published var results: [URL] = []
    @Published var errorMessage: String?
    @Published var organizerPages: [PDFOps.PageSpec] = []
    /// Redact video: the area whose time range the timeline edits.
    @Published var selectedRedactPoint: Int?
    @Published var redactShape: RedactShape = .rectangle
    @Published var selectedArea: Int?
    private var syncingRange = false
    @Published var selectedSpeedZone: UUID?
    var syncingSpeedRange = false
    /// True while the window is in full screen: only the preview stays on screen.
    @Published var fullscreen = false
    /// Closes the hosting window (set by the window manager).
    var requestClose: (() -> Void)?

    /// Timeline editor for the trim tools.
    private(set) var trimPlayer: TrimPlayer?

    private var task: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    var onFinish: ((ToolSession) -> Void)?

    init(tool: ToolID, files: [URL]) {
        self.tool = tool
        self.files = files
        let p = ToolEngine.params(for: tool, files: files)
        params = p
        values = ToolValues(defaultsFor: p)
        if tool.usesPlayer, let first = files.first {
            let player = TrimPlayer(url: first, hasVideo: tool.category == .video)
            if tool == .changeVideoSpeed {
                player.confinesPlaybackToSelection = false
                player.onRangeChange = { [weak self] range in self?.speedRangeChanged(range) }
                player.playbackRateAtTime = { [weak self] time in
                    guard let self else { return 1 }
                    return self.speedUsesZones ? SpeedPlan.rate(at: time, zones: self.speedZones) : self.values.number("speed", default: 1)
                }
            }
            if tool == .redactVideo {
                player.onRangeChange = { [weak self] r in self?.rangeChanged(r) }
            }
            if tool.isTrim {
                player.onRangeChange = { [weak self] r in
                    self?.values["start"] = .text(String(format: "%.3f", r.start))
                    self?.values["end"] = .text(String(format: "%.3f", r.end))
                    self?.errorMessage = nil
                }
            }
            trimPlayer = player
            Task { [weak self] in
                await player.prepare()
                self?.objectWillChange.send()
                if tool == .changeVideoSpeed { self?.initializeSpeedTimeline() }
            }
            if tool == .redactVideo { loadBase() }
        } else {
            loadBase()
        }
        if tool == .organizePDF, let doc = files.first.flatMap({ PDFDocument(url: $0) }) {
            organizerPages = (0..<doc.pageCount).map { PDFOps.PageSpec(index: $0, rotation: 0) }
        }
    }

    /// "clip.mp4" or "3 file", as shown in the footer.
    var fileLabel: String { files.count == 1 ? files[0].lastPathComponent : "\(files.count) files" }

    var primaryTitle: String {
        if tool == .videoSnapshots { let n = frameTimes.count; return n == 1 ? "Save 1 frame" : "Save \(n) frames" }
        if tool == .splitVideo { return "Split into \(clipCount) clip" }
        return tool.primaryTitle(fileCount: files.count)
    }

    // MARK: Split video

    var splitEqual: Bool { values.string("mode", default: "points") == "equal" }
    var splitPoints: [Double] { SplitPlan.parse(values.string("points")) ?? [] }
    var splitParts: Int { min(max(Int(values.number("parts", default: 2)), SplitPlan.partsRange.lowerBound), SplitPlan.partsRange.upperBound) }
    /// Clips produced by the combined automatic and custom cuts.
    var clipCount: Int { splitMarkers.count + 1 }
    /// Points drawn on the timeline.
    var splitMarkers: [Double] {
        SplitPlan.combined(duration: trimPlayer?.range.duration ?? 0, parts: splitEqual ? splitParts : nil, custom: splitPoints)
    }

    func setSplitEqual(_ on: Bool) {
        values["mode"] = .text(on ? "equal" : "points")
        valuesChanged()
    }

    func setSplitParts(_ n: Int) {
        values["parts"] = .number(Double(min(max(n, SplitPlan.partsRange.lowerBound), SplitPlan.partsRange.upperBound)))
        valuesChanged()
    }

    /// Adds a cut at `t` (default: the playhead). False when the point is too close to an end or to another point.
    @discardableResult
    func addSplit(at t: Double? = nil) -> Bool {
        guard let player = trimPlayer, player.ready,
              SplitPlan.adding(t ?? player.playhead, to: splitMarkers, duration: player.range.duration) != nil,
              let list = SplitPlan.adding(t ?? player.playhead, to: splitPoints, duration: player.range.duration) else { return false }
        values["points"] = .text(SplitPlan.serialize(list))
        valuesChanged()
        return true
    }

    var splitAutomaticPoints: [Double] {
        splitEqual ? SplitPlan.equalPoints(duration: trimPlayer?.range.duration ?? 0, parts: splitParts) : []
    }

    /// Returns the new sorted index so a drag keeps tracking the same cut across other cuts.
    @discardableResult
    func moveSplit(at index: Int, to time: Double) -> Int? {
        guard let player = trimPlayer, player.ready else { return nil }
        var points = splitPoints
        guard points.indices.contains(index) else { return nil }
        points.remove(at: index)
        let rounded = (time * 1000).rounded() / 1000
        guard SplitPlan.adding(rounded, to: points + splitAutomaticPoints, duration: player.range.duration) != nil,
              let updated = SplitPlan.adding(rounded, to: points, duration: player.range.duration) else { return nil }
        values["points"] = .text(SplitPlan.serialize(updated))
        valuesChanged()
        return updated.firstIndex(of: rounded)
    }

    func removeSplit(at index: Int) {
        var list = splitPoints
        guard list.indices.contains(index) else { return }
        list.remove(at: index)
        values["points"] = .text(SplitPlan.serialize(list))
        valuesChanged()
    }

    // MARK: Redact video areas

    var areas: [TimedArea] { values.areas("areas") }

    func setAreas(_ list: [TimedArea]) {
        values["areas"] = .areas(list)
        valuesChanged()
    }

    /// Selects an area (nil = none) and shows its time range on the timeline.
    func selectArea(_ index: Int?) {
        selectedRedactPoint = nil
        selectedArea = index.flatMap { areas.indices.contains($0) ? $0 : nil }
        if let i = selectedArea { redactShape = areas[i].shape }
        syncRangeFromSelection()
    }

    func addArea(_ rect: CGRect) {
        setAreas(areas + [TimedArea(rect: rect)])
        selectArea(areas.count - 1)
    }

    func removeArea(_ index: Int) {
        var list = areas
        guard list.indices.contains(index) else { return }
        list.remove(at: index)
        setAreas(list)
        if let sel = selectedArea {
            if sel == index { selectArea(nil) } else if sel > index { selectedArea = sel - 1 }
        }
    }

    func setAreaWindow(_ index: Int, start: Double?, end: Double?) {
        var list = areas
        guard list.indices.contains(index) else { return }
        list[index].start = start
        list[index].end = end
        setAreas(list)
        if selectedArea == index { syncRangeFromSelection() }
    }

    /// "Whole video" switch of the selected area: on clears its range, off starts from the timeline's range.
    func setWholeVideo(_ whole: Bool) {
        guard let i = selectedArea, areas.indices.contains(i), let p = trimPlayer else { return }
        if whole { setAreaWindow(i, start: nil, end: nil) }
        else {
            let d = p.range.duration
            let start = min(p.playhead, max(d - 0.5, 0))
            setAreaWindow(i, start: start, end: min(start + max(d / 4, 1), d))
        }
    }

    /// Moves the timeline handles to the selected area's range (or the whole clip).
    private func syncRangeFromSelection() {
        guard let p = trimPlayer else { return }
        syncingRange = true
        defer { syncingRange = false }
        p.resetSelection()
        if let i = selectedArea, areas.indices.contains(i), let w = areas[i].window {
            p.setStart(w.0)
            p.setEnd(w.1)
        }
    }

    /// The user dragged the handles: store the new range on the selected area.
    private func rangeChanged(_ r: TrimRange) {
        guard !syncingRange, let i = selectedArea, areas.indices.contains(i) else { return }
        var list = areas
        if r.isWholeClip { list[i].start = nil; list[i].end = nil } else { list[i].start = r.start; list[i].end = r.end }
        values["areas"] = .areas(list)
        errorMessage = nil
        objectWillChange.send()
    }

    // MARK: Frames

    /// Frames picked by hand, in seconds, sorted.
    var chosenFrames: [Double] {
        values.string("times").split(separator: ",").compactMap { Tools.parseTime($0.trimmingCharacters(in: .whitespaces)) }.sorted()
    }

    /// Everything that will be saved: picked frames plus the ones from "every N seconds".
    var frameTimes: [Double] {
        let every = values.bool("every") && values.number("everyN", default: 5) > 0 ? values.number("everyN", default: 5) : nil
        return MediaOps.frameTimes(chosen: chosenFrames, every: every, duration: trimPlayer?.range.duration ?? 0, frameDuration: trimPlayer?.frameDuration ?? 0.04)
    }

    func setChosenFrames(_ times: [Double]) {
        values["times"] = .text(times.sorted().map { String(format: "%.3f", $0) }.joined(separator: ", "))
        valuesChanged()
    }

    /// Adds the frame under the playhead (a second press on the same frame removes it).
    func toggleCurrentFrame() {
        guard let p = trimPlayer, p.ready else { return }
        var list = chosenFrames
        if let i = list.firstIndex(where: { abs($0 - p.playhead) < 0.5 * p.frameDuration }) { list.remove(at: i) }
        else { list.append(p.playhead) }
        setChosenFrames(list)
    }

    func removeFrame(at index: Int) {
        var list = chosenFrames
        guard list.indices.contains(index) else { return }
        list.remove(at: index)
        setChosenFrames(list)
    }

    /// Whether the (first) video has an audio track.
    var hasAudio: Bool { files.first.map(MediaInfo.hasAudio) ?? false }

    /// Crop box in pixels of the original, when a box is drawn and the size is known.
    var cropBox: PixelRect? {
        guard let size = sourceSize, let r = values.rects("area").first else { return nil }
        return CropGeometry.pixels(r, in: size)
    }

    /// Aspect ratio (w/h) the crop box must keep, from the Aspect ratio card.
    var cropAspect: Double? {
        guard let size = sourceSize, values["aspect"] != nil else { return nil }
        return ToolEngine.aspectRatio(values.string("aspect"), imageSize: size)
    }

    /// A typed crop field: updates the drawn box.
    func setCrop(_ field: CropGeometry.Field, _ value: Int) {
        guard let size = sourceSize, let box = cropBox else { return }
        let edited = CropGeometry.edit(box, field: field, value: value, size: size, aspect: cropAspect)
        values["area"] = .rects([CropGeometry.normalized(edited, in: size)])
        valuesChanged()
    }

    func centerCrop() {
        guard let size = sourceSize, let box = cropBox else { return }
        values["area"] = .rects([CropGeometry.normalized(CropGeometry.centered(box, in: size), in: size)])
        valuesChanged()
    }

    func wholeImageCrop() {
        values["area"] = .rects([CGRect(x: 0, y: 0, width: 1, height: 1)])
        valuesChanged()
    }

    /// Output size typed in the video crop card: with the ratio locked the other side follows the box.
    func setOutput(width: Int? = nil, height: Int? = nil) {
        guard let box = cropBox else { return }
        let ratio = Double(box.width) / Double(max(box.height, 1))
        let lock = values.bool("keepRatio", default: true)
        if let w = width {
            values["outWidth"] = .number(Double(w))
            if lock { values["outHeight"] = .number(Double(CropGeometry.even(CropGeometry.linked(w, ratio: ratio, typedIsWidth: true)))) }
        }
        if let h = height {
            values["outHeight"] = .number(Double(h))
            if lock { values["outWidth"] = .number(Double(CropGeometry.even(CropGeometry.linked(h, ratio: ratio, typedIsWidth: false)))) }
        }
        valuesChanged()
    }

    /// Whether the main button can run right now.
    var canRun: Bool {
        if running { return false }
        if let p = trimPlayer, !p.ready { return false }
        switch tool {
        case .cropImage, .cropVideo: return values.rects("area").contains { $0.width > 0.001 && $0.height > 0.001 }
        case .redactImage, .redactVideo: return !values.rects("areas").isEmpty
        case .videoSnapshots: return !frameTimes.isEmpty
        case .splitVideo: return clipCount >= 2
        case .changeVideoSpeed: return !speedUsesZones || (!speedZones.isEmpty && speedZonesError == nil)
        default: return true
        }
    }

    /// Cancel button: stops a running job, otherwise closes the window.
    func cancelOrClose() {
        if running { cancel() } else { close(); requestClose?() }
    }

    /// Cards for the sidebar: parameters grouped by section, in order of appearance.
    var sidebarSections: [(title: String, params: [ToolParam])] {
        var order: [String] = []
        var groups: [String: [ToolParam]] = [:]
        for p in visibleParams where !p.inMain && !p.custom {
            if case .rect = p.kind { continue }
            if tool == .organizePDF && p.id == "pages" { continue }
            let title = p.section ?? tool.title
            if groups[title] == nil { order.append(title) }
            groups[title, default: []].append(p)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    var visibleParams: [ToolParam] { params.filter { $0.visible?(values) ?? true } }
    var hasAreaPicker: Bool { params.contains { if case .rect = $0.kind { return true }; return false } }
    var supportsPreview: Bool { ToolEngine.previewTransform(tool, values) != nil }
    var isVideoSource: Bool { tool.category == .video }
    /// Tools whose result depends on the order of the dragged files.
    var orderMatters: Bool { [.mergePDF, .joinVideos, .createPDF, .createCollage].contains(tool) }

    // MARK: Preview

    private func loadBase() {
        guard let first = files.first else { return }
        let tool = self.tool
        Task.detached(priority: .userInitiated) { [weak self] in
            var image: CGImage?
            var dur = 0.0
            var size: CGSize?
            if tool.category == .image { image = try? ImageOps.load(first, maxPixel: 1400).image; size = ImageOps.orientedSize(first) }
            else if tool.category == .video { image = MediaInfo.frame(first, at: 0); dur = MediaInfo.duration(first) ?? 0; size = MediaInfo.videoSize(first).map { CGSize(width: $0.width, height: $0.height) } }
            let result = image, d = dur, sz = size
            await MainActor.run {
                self?.baseImage = result
                self?.sourceSize = sz
                self?.duration = d
                self?.updatePreview()
            }
        }
    }

    func loadVideoFrame() {
        guard let first = files.first, isVideoSource else { return }
        let t = previewTime
        Task.detached(priority: .userInitiated) { [weak self] in
            let img = MediaInfo.frame(first, at: t)
            await MainActor.run { if let img { self?.baseImage = img } }
        }
    }

    func valuesChanged() {
        errorMessage = nil
        if tool == .changeVideoSpeed { trimPlayer?.refreshPlaybackRate() }
        updatePreview()
    }

    func updatePreview() {
        previewTask?.cancel()
        guard let base = baseImage, let transform = ToolEngine.previewTransform(tool, values) else { previewImage = nil; return }
        previewTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            if Task.isCancelled { return }
            let small = await Task.detached { () -> CGImage in
                let longest = max(base.width, base.height)
                return longest > 700 ? ImageOps.resize(base, .maxDimension(700, allowUpscale: false)) : base
            }.value
            let out = await Task.detached { transform(small) }.value
            if Task.isCancelled { return }
            self?.previewImage = NSImage(cgImage: out, size: NSSize(width: out.width, height: out.height))
        }
    }

    // MARK: Files

    func move(_ index: Int, by delta: Int) {
        let target = index + delta
        guard files.indices.contains(index), files.indices.contains(target) else { return }
        files.swapAt(index, target)
    }

    func remove(_ index: Int) {
        guard files.count > 2 || !orderMatters, files.indices.contains(index) else { return }
        files.remove(at: index)
    }

    // MARK: Organizer

    func syncOrganizer() {
        values["pages"] = .text(PDFOps.encode(organizerPages))
        errorMessage = nil
    }

    // MARK: Running

    func run() {
        guard !running else { return }
        running = true
        progress = 0
        results = []
        errorMessage = nil
        let tool = self.tool, files = self.files, values = self.values
        let folder = Settings.shared.outputFolder(for: files.first)
        task = Task { [weak self] in
            do {
                let outs = try await ToolEngine.run(tool, files: files, values: values, folder: folder) { p in
                    Task { @MainActor in self?.progress = p }
                }
                await MainActor.run {
                    self?.results = outs
                    self?.progress = 1
                    self?.running = false
                    if Settings.shared.soundEnabled { NSSound(named: "Glass")?.play() }
                    if let self { self.onFinish?(self) }
                }
            } catch is CancellationError {
                await MainActor.run { self?.running = false; self?.errorMessage = "Cancelled." }
            } catch {
                await MainActor.run {
                    self?.running = false
                    self?.errorMessage = error.localizedDescription
                    if Settings.shared.soundEnabled { NSSound(named: "Basso")?.play() }
                }
            }
        }
    }

    func cancel() { task?.cancel() }

    /// Called when the window closes.
    func close() {
        cancel()
        trimPlayer?.pause()
    }
}

/// Opens one window per tool run and keeps them alive.
@MainActor
final class ToolWindowManager: NSObject, NSWindowDelegate {
    static let shared = ToolWindowManager()
    private var windows: [ObjectIdentifier: (NSWindow, ToolSession)] = [:]

    func open(_ tool: ToolID, files: [URL]) {
        let session = ToolSession(tool: tool, files: files)
        let host = NSHostingController(rootView: ToolWindowView(session: session))
        let window = NSWindow(contentViewController: host)
        if tool == .redactVideo {
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(Midnight.background)
            window.titlebarAppearsTransparent = true
        }
        window.title = "\(tool.title) — \(files.count == 1 ? files[0].lastPathComponent : "\(files.count) files")"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(tool.defaultWindowSize)
        window.minSize = tool.minimumWindowSize
        session.requestClose = { [weak window] in window?.close() }
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        windows[ObjectIdentifier(window)] = (window, session)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, let entry = windows.removeValue(forKey: ObjectIdentifier(w)) else { return }
        entry.1.close()
    }

    var openCount: Int { windows.count }
}
