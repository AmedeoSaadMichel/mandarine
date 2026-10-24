import AppKit
import AVFoundation
import SwiftUI

// MARK: - Speed

enum SpeedMath {
    static let presets: [Double] = [0.25, 0.5, 1, 1.5, 2, 4]
    static let range: ClosedRange<Double> = 0.25...4

    static func clamp(_ f: Double) -> Double { min(max(f, range.lowerBound), range.upperBound) }
    static func newLength(duration: Double, factor: Double) -> Double { duration / max(factor, 0.0001) }

    /// "2×", "0.25×", "1.5×".
    static func label(_ f: Double) -> String { String(format: "%g×", f) }
}

/// Main card of the Speed tool: the video, its controls and a position bar.
struct SpeedStage: View {
    @ObservedObject var session: ToolSession
    @ObservedObject var player: TrimPlayer
    @State private var window: NSWindow?

    var body: some View {
        VStack(spacing: 10) {
            PlayerScreen(player: player, cornerRadius: session.fullscreen ? 0 : 8)
            TransportBar(player: player, fullscreen: session.fullscreen) { window?.toggleFullScreen(nil) }
            SpeedZoneOverview(session: session, player: player)
            TrimTimelineView(player: player, hasVideo: true)
        }
        .padding(session.fullscreen ? 14 : 12)
        .background(session.fullscreen ? Color.black.opacity(0.9) : Color.clear)
        .background(WindowReader { window = $0 })
        .playerKeys(player, session)
    }
}

/// Factor slider, quick values and the resulting length.
struct SpeedCard: View {
    @ObservedObject var session: ToolSession
    @ObservedObject var player: TrimPlayer

    private var factor: Double { session.speedFactor }

    var body: some View {
        SidebarCard(title: "Speed") {
            Text("Change the speed of the selected zone. Outside the zones, the video plays at 1×.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("Factor")
                Spacer()
                Text(String(format: "%.2f×", factor)).font(.body.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { factor }, set: { set($0) }), in: SpeedMath.range)
                .disabled(session.speedUsesZones && session.currentSpeedZone == nil)
            HStack(spacing: 6) {
                ForEach(SpeedMath.presets, id: \.self) { f in
                    Button(SpeedMath.label(f)) { set(f) }
                        .buttonStyle(.bordered).controlSize(.small).tint(abs(factor - f) < 0.001 ? CitrusEditor.mint : nil)
                        .disabled(session.speedUsesZones && session.currentSpeedZone == nil)
                }
            }
            Text("New duration: \(TrimRange.format(session.speedOutputDuration))")
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func set(_ f: Double) { session.setSpeedFactor(f) }
}

struct SpeedAudioCard: View {
    @ObservedObject var session: ToolSession
    @ObservedObject var player: TrimPlayer

    var body: some View {
        SidebarCard(title: "Audio") {
            if session.hasAudio {
                Toggle("Preserve pitch", isOn: Binding(get: { session.values.bool("preservePitch", default: true) }, set: {
                    session.values["preservePitch"] = .bool($0); player.preservePitch = $0; session.valuesChanged()
                }))
                Text("Keeps the original pitch. Turn off for a tape effect: faster playback sounds higher.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("This video has no audio.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Frames

/// Main card of the Frames tool: the player with the picked frames marked on the position bar.
struct FramesStage: View {
    @ObservedObject var session: ToolSession
    @ObservedObject var player: TrimPlayer

    var body: some View {
        VStack(spacing: 10) {
            PlayerScreen(player: player)
            TransportBar(player: player)
            ScrubBar(player: player, markers: session.frameTimes)
        }
        .padding(12)
        .playerKeys(player, session, fullscreenKey: false) { key in
            if key == "f" { session.toggleCurrentFrame(); return true }
            return false
        }
    }
}

struct FramesCard: View {
    @ObservedObject var session: ToolSession
    @ObservedObject var player: TrimPlayer

    var body: some View {
        SidebarCard(title: "Frames") {
            Toggle("Every N seconds", isOn: Binding(get: { session.values.bool("every") }, set: { session.values["every"] = .bool($0); session.valuesChanged() }))
            if session.values.bool("every") {
                PixelField(title: "Range", value: Int(session.values.number("everyN", default: 5)), unit: "s") {
                    session.values["everyN"] = .number(Double(max($0, 1))); session.valuesChanged()
                }
            }
            Button(addTitle) { session.toggleCurrentFrame() }.disabled(!player.ready)
            Text("Use ←/→ to choose the exact frame, then press F or click the button. \(session.chosenFrames.count) selected.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(session.chosenFrames.enumerated()), id: \.offset) { i, t in
                HStack {
                    Button { player.seek(to: t) } label: { Text(TrimRange.format(t)).font(.callout.monospacedDigit()) }.buttonStyle(.link)
                    Spacer()
                    Button { session.removeFrame(at: i) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                }
            }
            if !session.chosenFrames.isEmpty {
                Button("Remove all") { session.setChosenFrames([]) }.buttonStyle(.link)
            }
        }
    }

    private var addTitle: String {
        session.chosenFrames.contains { abs($0 - player.playhead) < 0.5 * player.frameDuration } ? "Remove current frame (F)" : "Add current frame (F)"
    }
}

struct FramesFormatCard: View {
    @ObservedObject var session: ToolSession

    var body: some View {
        SidebarCard(title: "Format") {
            Picker("", selection: Binding(get: { session.values.string("format", default: "png") }, set: { session.values["format"] = .text($0); session.valuesChanged() })) {
                ForEach(MediaOps.frameFormats, id: \.id) { Text($0.label).tag($0.id) }
            }
            .pickerStyle(.radioGroup).labelsHidden()
            Text("Frames are saved at the video's resolution in a single folder next to the original.").font(.caption).foregroundStyle(.secondary)
            if session.frameTimes.count > 0 {
                Text("Will save \(session.frameTimes.count) images.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Redact video

/// Main card of Redact video: the playing video with the areas on top, and the timeline of the selected area.
struct RedactStage: View {
    @ObservedObject var session: ToolSession
    @ObservedObject var player: TrimPlayer
    @State private var window: NSWindow?

    private var size: CGSize { session.sourceSize ?? CGSize(width: 16, height: 9) }
    private var style: ImageOps.RedactStyle { ImageOps.RedactStyle(rawValue: session.values.string("style", default: "black")) ?? .black }

    private var rects: Binding<[CGRect]> {
        Binding(get: { session.areas.map(\.rect) }, set: { new in
            var list = session.areas
            for (i, r) in new.enumerated() {
                if list.indices.contains(i) { list[i].rect = r } else { list.append(TimedArea(rect: r, shape: session.redactShape)) }
            }
            session.setAreas(list)
        })
    }

    var body: some View {
        VStack(spacing: 10) {
            Text("Drag on the video to add an area · Click to select · Drag to move · Use corners to resize")
                .font(.caption.bold()).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            RectPicker(imageSize: size, rects: rects, multi: true, aspect: nil, selected: session.selectedArea,
                       onSelect: { session.selectArea($0) }, look: look,
                       vertices: session.redactVertices, selectedVertex: session.selectedRedactPoint,
                       onVertexSelect: { session.selectedRedactPoint = $0 },
                       onVertexMove: { session.moveRedactPoint($0, to: $1) },
                       onContourDoubleClick: { session.insertRedactPoint(at: $0, displaySize: $1) },
                       areaPath: { index, box in
                           session.areas.indices.contains(index) ? session.areas[index].path(in: box) : TimedArea(rect: .zero, shape: session.redactShape).path(in: box)
                       }, freehand: session.redactShape == .freehand,
                       onFreehand: { area in session.setAreas(session.areas + [area]); session.selectArea(session.areas.count - 1) }) {
                ZStack {
                    Color.black
                    PlayerSurface(player: player.player).opacity(player.ready ? 1 : 0)
                    if player.preparing { ProgressView().controlSize(.large) }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 220, maxHeight: .infinity)
            TransportBar(player: player)
            TrimTimelineView(player: player, hasVideo: true)
        }
        .padding(14)
        .tint(CitrusEditor.coral)
        .background(WindowReader { window = $0 })
        .playerKeys(player, session, fullscreenKey: false) { key in
            guard key == "\u{7f}" || key == "\u{8}", session.selectedRedactPoint != nil else { return false }
            session.deleteRedactPoint()
            return true
        }
    }

    /// Solid areas show as black while the playhead is inside their time range; the others only as outlines.
    private func look(_ index: Int, _ selected: Bool) -> RectLook {
        guard session.areas.indices.contains(index) else { return RectLook() }
        let covered = session.areas[index].covers(player.playhead)
        let stroke = selected ? CitrusEditor.coral : WheelCitrus.cream
        switch style {
        case .black: return RectLook(fill: Color.black.opacity(covered ? 0.82 : 0.12), stroke: stroke, lineWidth: selected ? 3 : 1.5, dash: covered ? [] : [5, 4])
        default: return RectLook(fill: CitrusEditor.coral.opacity(covered ? 0.25 : 0.06), stroke: stroke, lineWidth: selected ? 3 : 1.5, dash: covered ? [] : [5, 4])
        }
    }
}

/// When the selected area is covered.
struct RedactTimeCard: View {
    @ObservedObject var session: ToolSession
    @ObservedObject var player: TrimPlayer

    var body: some View {
        SidebarCard(title: "Time range") {
            if let i = session.selectedArea, session.areas.indices.contains(i) {
                let area = session.areas[i]
                Toggle("Entire video", isOn: Binding(get: { area.isWholeVideo }, set: { session.setWholeVideo($0) }))
                if let w = area.window {
                    HStack(alignment: .bottom, spacing: 8) {
                        TimeField(title: "Da", value: w.0, commit: { text in
                            guard let t = Tools.parseTime(text), t < w.1 else { return false }
                            session.setAreaWindow(i, start: t, end: w.1); return true
                        })
                        Button("Here") { session.setAreaWindow(i, start: min(player.playhead, w.1 - 0.1), end: w.1) }.help("Set start to the current position")
                    }
                    HStack(alignment: .bottom, spacing: 8) {
                        TimeField(title: "A", value: w.1, commit: { text in
                            guard let t = Tools.parseTime(text), t > w.0 else { return false }
                            session.setAreaWindow(i, start: w.0, end: min(t, player.range.duration)); return true
                        })
                        Button("Here") { session.setAreaWindow(i, start: w.0, end: max(player.playhead, w.0 + 0.1)) }.help("Set end to the current position")
                    }
                }
                if let w = area.window {
                    Text("Active for \(TrimRange.format(w.1 - w.0))")
                        .font(.caption.monospacedDigit()).padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Midnight.leaf.opacity(0.35), in: Capsule())
                }
                Text(area.isWholeVideo ? "The area is covered for the entire duration." : "Drag the timeline handles to adjust the time range.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Select an area to set when it is covered. New areas cover the entire video.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .disabled(!player.ready)
    }
}

struct RedactAreasCard: View {
    @ObservedObject var session: ToolSession

    var body: some View {
        let areas = session.areas
        SidebarCard(title: "Areas (\(areas.count))") {
            Picker("Shape", selection: Binding(get: { session.redactShape }, set: { session.changeRedactShape($0) })) {
                Text("Rectangle").tag(RedactShape.rectangle)
                Text("Circle / ellipse").tag(RedactShape.ellipse)
                Text("Freehand").tag(RedactShape.freehand)
            }
            if !session.redactVertices.isEmpty {
                Text("Points: \(session.redactVertices.count). Drag a point to move it. Double-click the outline to add one; Backspace deletes the selected point.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Add point") { session.addRedactPoint() }
                        .disabled(session.redactVertices.count >= 2048)
                    Button("Delete point") { session.deleteRedactPoint() }
                        .disabled(session.selectedRedactPoint == nil || session.redactVertices.count <= 3)
                }
                Text("The new point is inserted on the edge after the selected point.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Choose a shape and drag on the video. A freehand outline closes when you release.")
                .font(.caption).foregroundStyle(.secondary)
            if areas.isEmpty {
                Text("Drag on the video to add a redaction area. Each area can have its own time range.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(areas.enumerated()), id: \.offset) { i, a in
                HStack {
                    Button { session.selectArea(i) } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Area \(i + 1)").font(.callout.weight(session.selectedArea == i ? .bold : .regular))
                            Text(Self.timeText(a)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(session.selectedArea == i ? .isSelected : [])
                    Spacer()
                    Button { session.removeArea(i) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("Delete area \(i + 1)")
                        .accessibilityLabel("Delete area \(i + 1)")
                }
                .padding(12)
                .background(session.selectedArea == i ? CitrusEditor.mint.opacity(0.14) : CitrusEditor.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(session.selectedArea == i ? CitrusEditor.mint : CitrusEditor.border))
            }
            Button {
                let rect = CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3)
                let area = TimedArea(rect: rect, shape: session.redactShape,
                                     points: session.redactShape == .freehand ? [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0.5, y: 1)] : [])
                session.setAreas(session.areas + [area]); session.selectArea(session.areas.count - 1)
            } label: {
                Label("Add area", systemImage: "plus")
            }
            .help("Adds a box at the center of the video that you can drag to move")
            .disabled(session.sourceSize == nil || session.trimPlayer?.ready != true)
            if !areas.isEmpty { Button("Clear all") { session.setAreas([]); session.selectArea(nil) }.buttonStyle(.link) }
        }
    }

    static func timeText(_ a: TimedArea) -> String {
        guard let w = a.window else { return "Entire video" }
        return "\(TrimRange.format(w.0)) – \(TrimRange.format(w.1))"
    }
}


// MARK: - Split video

/// Main card of Split video: the video and a timeline with the cut points (no range handles).
struct SplitStage: View {
    @ObservedObject var session: ToolSession
    @ObservedObject var player: TrimPlayer
    @State private var window: NSWindow?

    var body: some View {
        VStack(spacing: 10) {
            PlayerScreen(player: player, cornerRadius: session.fullscreen ? 0 : 8)
            TransportBar(player: player, fullscreen: session.fullscreen) { window?.toggleFullScreen(nil) }
            SplitTimeline(session: session, player: player)
        }
        .padding(session.fullscreen ? 14 : 12)
        .background(session.fullscreen ? Color.black.opacity(0.9) : Color.clear)
        .background(WindowReader { window = $0 })
        .playerKeys(player, session) { key in
            if key == "s" { session.addSplit(); return true }
            return false
        }
    }
}

/// One gesture owns the strip: custom marker drags edit cuts; other drags scrub.
struct SplitTimeline: View {
    @ObservedObject var session: ToolSession
    @ObservedObject var player: TrimPlayer
    @State private var dragging = false
    @State private var draggedIndex: Int?
    @State private var dragOffset: CGFloat = 0
    private let height: CGFloat = 64

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, d = max(player.range.duration, 0.001)
            let x: (Double) -> CGFloat = { CGFloat($0 / d) * w }
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(Array(player.thumbnails.enumerated()), id: \.offset) { _, img in
                        if let img { Image(decorative: img, scale: 1).resizable().scaledToFill().frame(maxWidth: .infinity).clipped() }
                        else { Color.gray.opacity(0.3).frame(maxWidth: .infinity) }
                    }
                }
                .frame(width: w, height: height)
                .background(Color.gray.opacity(0.25))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                ForEach(Array(session.splitAutomaticPoints.enumerated()), id: \.offset) { _, t in
                    Rectangle().fill(CitrusEditor.coral).frame(width: 3, height: height + 8).offset(x: x(t) - 1.5, y: -4)
                }
                ForEach(Array(session.splitPoints.enumerated()), id: \.offset) { i, t in
                    VStack(spacing: 0) {
                        Image(systemName: "diamond.fill").font(.system(size: 12))
                        Rectangle().frame(width: draggedIndex == i ? 4 : 3)
                    }
                    .foregroundStyle(Color.cyan)
                    .frame(width: 16, height: height + 8)
                    .offset(x: x(t) - 8, y: -4)
                }
                Rectangle().fill(Color.yellow).frame(width: 2, height: height + 8).offset(x: x(player.playhead) - 1, y: -4)
            }
            .allowsHitTesting(false)
            .frame(height: height + 8)
            .overlay {
                Color.clear.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            if !dragging {
                                dragging = true
                                draggedIndex = session.splitPoints.indices.min(by: {
                                    abs(x(session.splitPoints[$0]) - g.startLocation.x) < abs(x(session.splitPoints[$1]) - g.startLocation.x)
                                }).flatMap { abs(x(session.splitPoints[$0]) - g.startLocation.x) <= 14 ? $0 : nil }
                                if let i = draggedIndex { dragOffset = x(session.splitPoints[i]) - g.startLocation.x }
                            }
                            if let i = draggedIndex {
                                let time = Double((g.location.x + dragOffset) / max(w, 1)) * d
                                if let next = session.moveSplit(at: i, to: time) { draggedIndex = next }
                            } else {
                                player.scrub(to: Double(min(max(g.location.x, 0), w) / max(w, 1)) * d)
                            }
                        }
                        .onEnded { _ in
                            if draggedIndex == nil { player.endScrub() }
                            dragging = false
                            draggedIndex = nil
                            dragOffset = 0
                        })
            }
            .help("Drag the blue points to move them. Orange cuts for equal parts stay fixed.")
        }
        .frame(height: height + 8)
        .disabled(!player.ready)
    }
}

/// Automatic subdivisions and additional custom cuts can be combined.
struct SplitCard: View {
    @ObservedObject var session: ToolSession
    @ObservedObject var player: TrimPlayer

    var body: some View {
        SidebarCard(title: "Split") {
            Toggle("Equal parts", isOn: Binding(get: { session.splitEqual }, set: { session.setSplitEqual($0) }))
            if session.splitEqual { equal }
            Divider()
            Text("Custom cuts").font(.headline)
            Text("Drag the blue points on the timeline to move them.").font(.caption).foregroundStyle(.secondary)
            custom
            Text("Total: \(session.clipCount) clip").font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var custom: some View {
        Button { session.addSplit() } label: { Label("Add cut here", systemImage: "scissors").frame(maxWidth: .infinity) }
            .buttonStyle(.bordered).disabled(!player.ready)
            .help("Adds a cut point at the current position (S)")
        if session.splitPoints.isEmpty {
            Text("Move the playhead on the timeline and add cut points.").font(.callout).foregroundStyle(.secondary)
        } else {
            ForEach(Array(session.splitPoints.enumerated()), id: \.offset) { i, t in
                HStack {
                    Text("\(i + 1)").foregroundStyle(.secondary).frame(width: 18, alignment: .leading)
                    Text(TrimRange.format(t)).font(.body.monospacedDigit())
                    Spacer()
                    Button { player.seek(to: t) } label: { Image(systemName: "arrow.right.to.line") }.buttonStyle(.borderless).help("Go to this point")
                    Button { session.removeSplit(at: i) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Delete point")
                }
            }
        }
    }

    @ViewBuilder private var equal: some View {
        Stepper(value: Binding(get: { session.splitParts }, set: { session.setSplitParts($0) }), in: SplitPlan.partsRange) {
            Text("Parts: \(session.splitParts)")
        }
        Text("Base split: \(TrimRange.format(player.range.duration / Double(session.splitParts))) per part. You can add more cuts.")
            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
    }
}
