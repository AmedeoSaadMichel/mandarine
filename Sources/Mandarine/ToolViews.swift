import AppKit
import PDFKit
import SwiftUI

// MARK: - Window

struct ToolWindowView: View {
    @ObservedObject var session: ToolSession

    var body: some View {
        if session.tool == .redactVideo, let player = session.trimPlayer {
            MidnightRedactEditor(session: session, player: player)
        } else {
            ToolShell(session: session) { mainContent } side: { sidebarContent }
        }
    }

    @ViewBuilder private var mainContent: some View {
        if let player = session.trimPlayer, session.tool.isTrim {
            TrimStage(session: session, player: player)
        } else if let player = session.trimPlayer, session.tool == .changeVideoSpeed {
            SpeedStage(session: session, player: player)
        } else if let player = session.trimPlayer, session.tool == .videoSnapshots {
            FramesStage(session: session, player: player)
        } else if let player = session.trimPlayer, session.tool == .redactVideo {
            RedactStage(session: session, player: player)
        } else if let player = session.trimPlayer, session.tool == .splitVideo {
            SplitStage(session: session, player: player)
        } else if session.tool == .organizePDF {
            ScrollView { PageOrganizerView(session: session).padding(16) }
        } else if session.hasAreaPicker {
            if let image = session.baseImage { AreaPickerSection(session: session, image: image).padding(14) }
            else { ProgressView() }
        } else if session.supportsPreview {
            PreviewMain(session: session)
        } else if session.tool == .editMetadata {
            MetadataMain(session: session)
        } else {
            FilesMain(session: session)
        }
    }

    @ViewBuilder private var sidebarContent: some View {
        if let player = session.trimPlayer, session.tool.isTrim {
            TrimSidebar(session: session, player: player)
        } else if let player = session.trimPlayer, session.tool == .changeVideoSpeed {
            SpeedCard(session: session, player: player)
            SpeedZonesCard(session: session, player: player)
            SpeedAudioCard(session: session, player: player)
        } else if let player = session.trimPlayer, session.tool == .videoSnapshots {
            FramesCard(session: session, player: player)
            FramesFormatCard(session: session)
        } else if let player = session.trimPlayer, session.tool == .redactVideo {
            ParamSections(session: session)
            RedactTimeCard(session: session, player: player)
            RedactAreasCard(session: session)
        } else if let player = session.trimPlayer, session.tool == .splitVideo {
            SplitCard(session: session, player: player)
            SidebarCard(title: "Output") {
                Text("All clips are saved in a new folder next to the original, numbered in order.").font(.callout).foregroundStyle(.secondary)
            }
        } else {
            ParamSections(session: session)
            if session.tool == .cropImage || session.tool == .cropVideo { CropInfoCard(session: session) }
            if session.tool == .cropVideo { OutputSizeCard(session: session) }
            if session.tool == .redactImage || session.tool == .redactVideo { AreasCard(session: session) }
            if session.tool == .organizePDF {
                SummaryCard(lines: ["\(session.organizerPages.count) pages in the output", "Use the arrows to reorder, rotate, or remove pages."])
            }
            if session.tool == .editMetadata, let first = session.files.first {
                SummaryCard(lines: ["\(MetadataOps.fields(for: first).count) editable fields", "Changes are saved to a copy. The original stays unchanged."])
            }
        }
    }
}

struct ResultsView: View {
    let results: [URL]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(results.count == 1 ? "Done" : "Done: \(results.count) files", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout.bold())
            ForEach(results.prefix(4), id: \.self) { url in
                HStack {
                    Text(url.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(.link).font(.caption)
                    Button("Open") { NSWorkspace.shared.open(url) }.buttonStyle(.link).font(.caption)
                }
            }
            if results.count > 4 {
                HStack {
                    Text("and \(results.count - 4)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Show all") { NSWorkspace.shared.activateFileViewerSelecting(results) }.buttonStyle(.link).font(.caption)
                }
            }
        }
    }
}

struct CheckerboardView: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 10
            for y in 0..<Int(size.height / s) + 1 {
                for x in 0..<Int(size.width / s) + 1 where (x + y) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: CGFloat(x) * s, y: CGFloat(y) * s, width: s, height: s)), with: .color(.gray.opacity(0.15)))
                }
            }
        }
    }
}

// MARK: - File order

struct FileListView: View {
    @ObservedObject var session: ToolSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.orderMatters ? "Files, in the order they will be used" : "File").font(.caption.bold()).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(Array(session.files.enumerated()), id: \.offset) { i, url in
                    HStack {
                        Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 20)
                        Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if session.orderMatters {
                            Button { session.move(i, by: -1) } label: { Image(systemName: "chevron.up") }.disabled(i == 0)
                            Button { session.move(i, by: 1) } label: { Image(systemName: "chevron.down") }.disabled(i == session.files.count - 1)
                        }
                    }
                    .buttonStyle(.borderless)
                    .padding(.vertical, 5).padding(.horizontal, 8)
                    if i < session.files.count - 1 { Divider() }
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.08)))
        }
    }
}

// MARK: - Parameters

struct ParamRow: View {
    @ObservedObject var session: ToolSession
    let param: ToolParam
    /// False when the card title already says what the control is.
    var showLabel = true

    private func binding<T>(get: @escaping (ToolValues) -> T, set: @escaping (T) -> ToolValue) -> Binding<T> {
        Binding(get: { get(session.values) }, set: { session.values[param.id] = set($0); session.valuesChanged() })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch param.kind {
            case .slider(let lo, let hi, let step, let unit):
                let b = binding(get: { $0.number(param.id, default: lo) }, set: { .number(step > 0 ? (($0 - lo) / step).rounded() * step + lo : $0) })
                HStack {
                    if showLabel { Text(param.label) }
                    Spacer()
                    Text(format(b.wrappedValue, step: step) + unit).monospacedDigit().foregroundStyle(.secondary)
                }
                if step >= 1 { Slider(value: b, in: lo...hi, step: step) } else { Slider(value: b, in: lo...hi) }
            case .number(let unit):
                let b = Binding<String>(
                    get: { format(session.values.number(param.id), step: 1) },
                    set: { session.values[param.id] = .number(Double($0.replacingOccurrences(of: ",", with: ".")) ?? 0); session.valuesChanged() })
                HStack {
                    if showLabel { Text(param.label) }
                    Spacer()
                    TextField("", text: b).multilineTextAlignment(.trailing).frame(width: 90).textFieldStyle(.roundedBorder)
                    if !unit.isEmpty { Text(unit).foregroundStyle(.secondary) }
                }
            case .choice(let options):
                let b = binding(get: { $0.string(param.id) }, set: { .text($0) })
                HStack {
                    if showLabel { Text(param.label) }
                    if showLabel { Spacer() }
                    Picker("", selection: b) { ForEach(options, id: \.id) { Text($0.label).tag($0.id) } }
                        .labelsHidden().fixedSize()
                    if !showLabel { Spacer() }
                }
            case .toggle:
                Toggle(param.label, isOn: binding(get: { $0.bool(param.id) }, set: { .bool($0) }))
            case .text(let placeholder):
                Text(param.label)
                TextField(placeholder, text: binding(get: { $0.string(param.id) }, set: { .text($0) })).textFieldStyle(.roundedBorder)
            case .time:
                HStack {
                    Text(param.label)
                    Spacer()
                    TextField("0:00", text: binding(get: { $0.string(param.id) }, set: { .text($0) }))
                        .multilineTextAlignment(.trailing).frame(width: 110).textFieldStyle(.roundedBorder)
                }
            case .color:
                HStack {
                    Text(param.label)
                    Spacer()
                    ColorPicker("", selection: Binding(
                        get: { Color(nsColor: NSColor(hex: session.values.string(param.id)) ?? .white) },
                        set: { session.values[param.id] = .text(NSColor($0).hexString); session.valuesChanged() }), supportsOpacity: false)
                        .labelsHidden()
                }
            case .rect:
                EmptyView()
            }
            if let help = param.help { Text(help).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func format(_ v: Double, step: Double) -> String {
        step >= 1 ? String(Int(v.rounded())) : String(format: step >= 0.1 ? "%.1f" : "%.2f", v)
    }
}

// MARK: - Area picker

struct AreaPickerSection: View {
    @ObservedObject var session: ToolSession
    let image: CGImage

    private var rectParam: ToolParam? { session.params.first { if case .rect = $0.kind { return true }; return false } }
    private var multi: Bool { if case .rect(let m)? = rectParam?.kind { return m }; return false }

    private var aspect: Double? {
        guard session.values["aspect"] != nil else { return nil }
        let size = session.sourceSize ?? CGSize(width: image.width, height: image.height)
        return ToolEngine.aspectRatio(session.values.string("aspect"), imageSize: size)
    }

    private var rectsBinding: Binding<[CGRect]> {
        Binding(get: { session.values.rects(rectParam?.id ?? "") },
                set: { session.values[rectParam?.id ?? ""] = .rects($0); session.valuesChanged() })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(multi ? "Drag on the image to add an area" : "Drag on the image to select an area")
                .font(.caption.bold()).foregroundStyle(.secondary)
            RectPicker(imageSize: CGSize(width: image.width, height: image.height), rects: rectsBinding, multi: multi, aspect: aspect) {
                Image(nsImage: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))).resizable()
            }
            .frame(maxWidth: .infinity, minHeight: 240, maxHeight: .infinity)
            if session.isVideoSource && session.duration > 0 {
                HStack {
                    Text("Frame").font(.caption).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { session.previewTime }, set: { session.previewTime = $0 }), in: 0...max(session.duration - 0.05, 0.1)) { editing in
                        if !editing { session.loadVideoFrame() }
                    }
                    Text(Tools.formatTime(session.previewTime)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: session.values.string("aspect")) { _ in
            guard !multi, let a = aspect, let r = rectsBinding.wrappedValue.first else { return }
            rectsBinding.wrappedValue = [RectMath.fit(r, aspect: a, imageSize: CGSize(width: image.width, height: image.height))]
        }
    }
}

/// Pure helpers for the rectangle picker.
enum RectMath {
    /// Adjusts `rect` to the aspect ratio (w/h in pixels), shrinking it around its centre and keeping it inside the image.
    static func fit(_ rect: CGRect, aspect: Double, imageSize: CGSize) -> CGRect {
        let W = Double(imageSize.width), H = Double(imageSize.height)
        var w = Double(rect.width) * W, h = Double(rect.height) * H
        if w / h > aspect { w = h * aspect } else { h = w / aspect }
        let cx = Double(rect.midX), cy = Double(rect.midY)
        var nw = w / W, nh = h / H
        nw = min(nw, 1); nh = min(nh, 1)
        let x = min(max(cx - nw / 2, 0), 1 - nw), y = min(max(cy - nh / 2, 0), 1 - nh)
        return CGRect(x: x, y: y, width: nw, height: nh)
    }

    /// Index of the topmost rectangle under `p` (later rectangles are drawn above earlier ones).
    static func hit(_ p: CGPoint, in rects: [CGRect]) -> Int? {
        rects.indices.reversed().first { rects[$0].contains(p) }
    }

    /// Moves `rect` by `delta`, keeping it inside the unit square.
    static func moved(_ rect: CGRect, by delta: CGPoint) -> CGRect {
        var r = rect
        r.origin.x = min(max(rect.minX + delta.x, 0), 1 - rect.width)
        r.origin.y = min(max(rect.minY + delta.y, 0), 1 - rect.height)
        return r
    }
    /// Corner resize in normalised coordinates, bounded by the image and a minimum size.
    static func resized(_ rect: CGRect, corner: Int, to point: CGPoint) -> CGRect {
        let left = corner == 0 || corner == 2
        let top = corner == 0 || corner == 1
        let x = left ? min(max(point.x, 0), rect.maxX - 0.01) : max(min(point.x, 1), rect.minX + 0.01)
        let y = top ? min(max(point.y, 0), rect.maxY - 0.01) : max(min(point.y, 1), rect.minY + 0.01)
        return CGRect(x: left ? x : rect.minX, y: top ? y : rect.minY,
                      width: left ? rect.maxX - x : x - rect.minX,
                      height: top ? rect.maxY - y : y - rect.minY)
    }

}

struct RectLook {
    var fill = CitrusEditor.coral.opacity(0.18)
    var stroke = CitrusEditor.coral
    var lineWidth: CGFloat = 2
    var dash: [CGFloat] = []
}

/// Draws and moves rectangles over any content (a picture or a playing video), in 0…1 coordinates.
struct RectPicker<Background: View>: View {
    let imageSize: CGSize
    @Binding var rects: [CGRect]
    let multi: Bool
    let aspect: Double?
    var selected: Int? = nil
    var onSelect: ((Int?) -> Void)? = nil
    var look: (Int, Bool) -> RectLook = { _, selected in RectLook(lineWidth: selected ? 3 : 2) }
    var vertices: [CGPoint] = []
    var selectedVertex: Int? = nil
    var onVertexSelect: ((Int) -> Void)? = nil
    var onVertexMove: ((Int, CGPoint) -> Void)? = nil
    var onContourDoubleClick: ((CGPoint, CGSize) -> Void)? = nil
    var areaPath: ((Int, CGRect) -> Path)? = nil
    var freehand = false
    var onFreehand: ((TimedArea) -> Void)? = nil
    @ViewBuilder var background: () -> Background

    private enum Drag { case vertex(Int), drawing(CGPoint), moving(index: Int, start: CGRect, origin: CGPoint), resizing(index: Int, start: CGRect, corner: Int) }
    @State private var drag: Drag?
    @State private var live: CGRect?
    @State private var lastContourClick: (point: CGPoint, time: TimeInterval)?
    @State private var drawnPoints: [CGPoint] = []

    var body: some View {
        GeometryReader { geo in
            let box = fitted(in: geo.size)
            ZStack(alignment: .topLeading) {
                background().frame(width: box.width, height: box.height).position(x: box.midX, y: box.midY)
                ForEach(shown, id: \.id) { item in
                    let r = item.rect
                    let frame = CGRect(x: box.minX + r.minX * box.width, y: box.minY + r.minY * box.height, width: r.width * box.width, height: r.height * box.height)
                    let l = look(item.index, item.index == selected)
                    let local = CGRect(origin: .zero, size: frame.size)
                    let path = item.index == rects.count && freehand
                        ? (TimedArea.freehand(drawnPoints)?.path(in: local) ?? Path(local))
                        : (areaPath?(item.index, local) ?? Path(local))
                    path.fill(l.fill)
                        .overlay(path.stroke(l.stroke, style: StrokeStyle(lineWidth: l.lineWidth, dash: l.dash)))
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                        .allowsHitTesting(false)
                    if item.index == selected || !multi {
                        ForEach(0..<4, id: \.self) { corner in
                            RoundedRectangle(cornerRadius: 2).fill(Color.white)
                                .overlay(RoundedRectangle(cornerRadius: 2).stroke(l.stroke, lineWidth: 2))
                                .frame(width: 10, height: 10)
                                .position(x: corner == 0 || corner == 2 ? frame.minX : frame.maxX,
                                          y: corner < 2 ? frame.minY : frame.maxY)
                                .allowsHitTesting(false)
                        }
                    }
                }
                ForEach(vertices.indices, id: \.self) { i in
                    Circle().fill(i == selectedVertex ? CitrusEditor.coral : Color.white)
                        .overlay(Circle().stroke(CitrusEditor.coral, lineWidth: 1.5))
                        .frame(width: i == selectedVertex ? 12 : 8, height: i == selectedVertex ? 12 : 8)
                        .position(x: box.minX + vertices[i].x * box.width, y: box.minY + vertices[i].y * box.height)
                }
            }
            .allowsHitTesting(false)
            .frame(width: geo.size.width, height: geo.size.height)
            .overlay {
                Color.clear.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { g in change(g, box) }
                        .onEnded { g in end(g, box) })
            }
        }
        .background(Color.black.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private struct Shown { let id: Int; let index: Int; let rect: CGRect }

    /// Stored rectangles (the moved one replaced by its live position) plus the one being drawn.
    private var shown: [Shown] {
        var out = rects.enumerated().map { Shown(id: $0.offset, index: $0.offset, rect: $0.element) }
        if let live {
            if let i = editingIndex, out.indices.contains(i) { out[i] = Shown(id: i, index: i, rect: live) }
            else if case .drawing? = drag { out.append(Shown(id: rects.count, index: rects.count, rect: live)) }
        }
        return out
    }

    private func hit(_ point: CGPoint, in candidates: [CGRect]) -> Int? {
        candidates.indices.reversed().first { index in
            areaPath?(index, candidates[index]).contains(point) ?? candidates[index].contains(point)
        }
    }

    private var editingIndex: Int? {
        switch drag {
        case .moving(let i, _, _)?, .resizing(let i, _, _)?: return i
        default: return nil
        }
    }

    private func change(_ g: DragGesture.Value, _ box: CGRect) {
        let start = normalized(g.startLocation, box), now = normalized(g.location, box)
        if drag == nil {
            if let vertex = vertices.indices.min(by: {
                hypot((vertices[$0].x - start.x) * box.width, (vertices[$0].y - start.y) * box.height) < hypot((vertices[$1].x - start.x) * box.width, (vertices[$1].y - start.y) * box.height)
            }), hypot((vertices[vertex].x - start.x) * box.width, (vertices[vertex].y - start.y) * box.height) <= 9 {
                drag = .vertex(vertex)
                onVertexSelect?(vertex)
            }
        }
        if drag == nil {
            let candidates = multi ? rects : Array(rects.prefix(1))
            let selectedIndex = multi ? selected : (rects.isEmpty ? nil : 0)
            if let i = selectedIndex, rects.indices.contains(i), let corner = (0..<4).first(where: { corner in
                let r = rects[i]
                let px = box.minX + (corner == 0 || corner == 2 ? r.minX : r.maxX) * box.width
                let py = box.minY + (corner < 2 ? r.minY : r.maxY) * box.height
                return abs(g.startLocation.x - px) <= 10 && abs(g.startLocation.y - py) <= 10
            }) {
                drag = .resizing(index: i, start: rects[i], corner: corner)
            } else if let i = hit(start, in: candidates) {
                drag = .moving(index: i, start: rects[i], origin: start)
            } else {
                guard box.contains(g.startLocation) else { return }
                drag = .drawing(start)
            }
        }
        guard hypot(g.location.x - g.startLocation.x, g.location.y - g.startLocation.y) >= 3 else { return }
        switch drag {
        case .vertex(let i)?: onVertexMove?(i, now)
        case .moving(_, let rectStart, let origin)?: live = RectMath.moved(rectStart, by: CGPoint(x: now.x - origin.x, y: now.y - origin.y))
        case .resizing(_, let original, let corner)?:
            let resized = RectMath.resized(original, corner: corner, to: now)
            live = aspect.map { RectMath.fit(resized, aspect: $0, imageSize: imageSize) } ?? resized
        case .drawing(let a)?:
            if freehand {
                if drawnPoints.isEmpty { drawnPoints = [a] }
                if let last = drawnPoints.last, hypot(now.x - last.x, now.y - last.y) > 0.003, drawnPoints.count < 2048 { drawnPoints.append(now) }
                live = TimedArea.freehand(drawnPoints)?.rect
            } else { live = draw(from: a, to: now) }
        case nil: break
        }
    }

    private func end(_ g: DragGesture.Value, _ box: CGRect) {
        defer { drag = nil; live = nil; drawnPoints = [] }
        if case .vertex? = drag { lastContourClick = nil; return }
        let travel = hypot(g.location.x - g.startLocation.x, g.location.y - g.startLocation.y)
        if travel < 3 {
            let point = normalized(g.location, box)
            if let onContourDoubleClick,
               RedactContour.insertion(at: point, vertices: vertices, size: box.size) != nil {
                let now = ProcessInfo.processInfo.systemUptime
                if let previous = lastContourClick, now - previous.time <= NSEvent.doubleClickInterval,
                   hypot(g.location.x - previous.point.x, g.location.y - previous.point.y) <= 5 {
                    onContourDoubleClick(point, box.size)
                    lastContourClick = nil
                } else { lastContourClick = (g.location, now) }
                return
            }
            lastContourClick = nil
            // A click: select the rectangle under the pointer (or nothing).
            if multi { onSelect?(hit(normalized(g.startLocation, box), in: rects)) }
            return
        }
        guard let r = live, r.width > 0.005, r.height > 0.005 else { return }
        switch drag {
        case .moving(let i, _, _)?, .resizing(let i, _, _)?:
            var all = rects; all[i] = r; rects = all
            if multi { onSelect?(i) }
        case .drawing?:
            if freehand, let area = TimedArea.freehand(drawnPoints), let onFreehand { onFreehand(area); return }
            if multi { rects = rects + [r]; onSelect?(rects.count - 1) } else { rects = [r] }
        case .vertex?, nil: break
        }
    }

    private func fitted(in size: CGSize) -> CGRect {
        let iw = max(imageSize.width, 1), ih = max(imageSize.height, 1)
        let k = min(size.width / iw, size.height / ih)
        let w = iw * k, h = ih * k
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func normalized(_ p: CGPoint, _ box: CGRect) -> CGPoint {
        CGPoint(x: min(max((p.x - box.minX) / box.width, 0), 1), y: min(max((p.y - box.minY) / box.height, 0), 1))
    }

    private func draw(from a: CGPoint, to b: CGPoint) -> CGRect {
        var dx = b.x - a.x, dy = b.y - a.y
        if let aspect {
            // Keep the ratio in pixels: height (normalised) = width (normalised) * W / aspect / H.
            let W = imageSize.width, H = imageSize.height
            let hFromW = abs(dx) * W / CGFloat(aspect) / H
            dy = (dy < 0 ? -1 : 1) * hFromW
            if a.y + dy > 1 || a.y + dy < 0 {
                let room = dy > 0 ? 1 - a.y : a.y
                dy = (dy < 0 ? -1 : 1) * room
                dx = (dx < 0 ? -1 : 1) * room * H * CGFloat(aspect) / W
            }
        }
        return CGRect(x: min(a.x, a.x + dx), y: min(a.y, a.y + dy), width: abs(dx), height: abs(dy))
    }
}

// MARK: - PDF page organiser

struct PageOrganizerView: View {
    @ObservedObject var session: ToolSession
    @State private var thumbnails: [Int: NSImage] = [:]
    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Pages").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                Text("\(session.organizerPages.count) in the output").font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(Array(session.organizerPages.enumerated()), id: \.offset) { i, spec in
                    VStack(spacing: 4) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 4).fill(Color.white).shadow(radius: 1)
                            if let t = thumbnails[spec.index] {
                                Image(nsImage: t).resizable().scaledToFit().rotationEffect(.degrees(Double(spec.rotation))).padding(3)
                            }
                        }
                        .frame(height: 120)
                        Text("Page \(spec.index + 1)").font(.caption2).foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Button { move(i, -1) } label: { Image(systemName: "arrow.left") }.disabled(i == 0)
                            Button { rotate(i) } label: { Image(systemName: "rotate.right") }
                            Button { move(i, 1) } label: { Image(systemName: "arrow.right") }.disabled(i == session.organizerPages.count - 1)
                            Button { delete(i) } label: { Image(systemName: "trash") }.disabled(session.organizerPages.count <= 1)
                        }
                        .buttonStyle(.borderless).font(.caption)
                    }
                }
            }
        }
        .onAppear(perform: loadThumbnails)
    }

    private func loadThumbnails() {
        guard let url = session.files.first, let doc = PDFDocument(url: url) else { return }
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i) { thumbnails[i] = page.thumbnail(of: CGSize(width: 220, height: 280), for: .mediaBox) }
        }
    }

    private func move(_ i: Int, _ d: Int) {
        let j = i + d
        guard session.organizerPages.indices.contains(j) else { return }
        session.organizerPages.swapAt(i, j)
        session.syncOrganizer()
    }

    private func rotate(_ i: Int) {
        let s = session.organizerPages[i]
        session.organizerPages[i] = PDFOps.PageSpec(index: s.index, rotation: (s.rotation + 90) % 360)
        session.syncOrganizer()
    }

    private func delete(_ i: Int) {
        guard session.organizerPages.count > 1 else { return }
        session.organizerPages.remove(at: i)
        session.syncOrganizer()
    }
}
