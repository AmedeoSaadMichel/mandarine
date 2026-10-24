import AppKit
import AVFoundation
import AVKit
import SwiftUI

// MARK: - Video surface

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .none
        v.videoGravity = .resizeAspect
        v.showsFullScreenToggleButton = false
        return v
    }

    func updateNSView(_ view: AVPlayerView, context: Context) { if view.player !== player { view.player = player } }
}

/// Reports the hosting window, to scope the keyboard shortcuts to it.
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { onWindow(v.window) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) { DispatchQueue.main.async { onWindow(nsView.window) } }
}

// MARK: - Shared player pieces

/// The video (or audio artwork) with its loading and error states.
struct PlayerScreen: View {
    @ObservedObject var player: TrimPlayer
    var cornerRadius: CGFloat = 8

    var body: some View {
        ZStack {
            Color.black
            if player.hasVideo { PlayerSurface(player: player.player).opacity(player.ready ? 1 : 0) }
            else if player.ready { AudioStage(player: player) }
            if player.preparing {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.large)
                    Text(player.prepareProgress > 0 ? "Preparing preview… \(Int(player.prepareProgress * 100))%" : "Loading file…")
                        .font(.callout).foregroundStyle(.white.opacity(0.8))
                }
            }
            if let error = player.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.white).padding().multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 220, maxHeight: .infinity)
        .layoutPriority(1)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .contentShape(Rectangle())
        .onTapGesture { player.togglePlay() }
    }
}

/// Volume, transport buttons, time and full screen.
struct TransportBar: View {
    @ObservedObject var player: TrimPlayer
    var fullscreen = false
    var onFullscreen: (() -> Void)? = nil

    var body: some View {
        ZStack {
            HStack(spacing: 6) {
                Button { player.muted.toggle() } label: { Image(systemName: player.muted || player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill") }
                    .help(player.muted ? "Unmute (M)" : "Muto (M)")
                Slider(value: $player.volume, in: 0...1).frame(width: 90)
                Spacer()
                Text(TrimRange.format(player.playhead) + " / " + TrimRange.format(player.range.duration))
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                if let onFullscreen {
                    Button(action: onFullscreen) { Image(systemName: fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") }
                        .help("Full screen (F) · Esc to exit")
                }
            }
            HStack(spacing: 14) {
                Button { player.toStart() } label: { Image(systemName: "backward.end.fill") }.help("Go to start")
                Button { player.step(by: -player.frameDuration) } label: { Image(systemName: "backward.frame.fill") }.help("Previous frame (←)")
                Button { player.skip(-5) } label: { Image(systemName: "gobackward.5") }.help("Back 5 seconds")
                Button { player.togglePlay() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title2).frame(width: 30) }
                    .help(player.isPlaying ? "Pause (Space)" : "Play (Space)")
                Button { player.skip(5) } label: { Image(systemName: "goforward.5") }.help("Forward 5 seconds")
                Button { player.step(by: player.frameDuration) } label: { Image(systemName: "forward.frame.fill") }.help("Next frame (→)")
                Button { player.toEnd() } label: { Image(systemName: "forward.end.fill") }.help("Go to end")
            }
        }
        .buttonStyle(.borderless).font(.title3).disabled(!player.ready)
    }
}

/// A plain position slider for tools that have no selection to draw.
struct ScrubBar: View {
    @ObservedObject var player: TrimPlayer
    /// Positions to mark (chosen frames).
    var markers: [Double] = []

    var body: some View {
        VStack(spacing: 2) {
            GeometryReader { geo in
                let w = geo.size.width, d = max(player.range.duration, 0.001)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.gray.opacity(0.35)).frame(height: 6)
                    Capsule().fill(CitrusEditor.coral.opacity(0.6)).frame(width: CGFloat(player.playhead / d) * w, height: 6)
                    ForEach(Array(markers.enumerated()), id: \.offset) { _, t in
                        Rectangle().fill(Color.yellow).frame(width: 2, height: 16).offset(x: CGFloat(t / d) * w - 1)
                    }
                    Circle().fill(Color.white).shadow(radius: 1).frame(width: 14, height: 14).offset(x: CGFloat(player.playhead / d) * w - 7)
                }
                .frame(height: 20)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in player.scrub(to: Double(min(max(g.location.x, 0), w) / max(w, 1)) * d) }
                    .onEnded { _ in player.endScrub() })
            }
            .frame(height: 20)
        }
        .disabled(!player.ready)
    }
}

/// Space, arrows, Home/End, L, M and F for a player window; `extra` handles the tool's own keys.
struct PlayerKeys: ViewModifier {
    @ObservedObject var player: TrimPlayer
    @ObservedObject var session: ToolSession
    var fullscreenKey = true
    var extra: (String) -> Bool = { _ in false }
    @State private var window: NSWindow?
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .background(WindowReader { window = $0 })
            .onAppear(perform: install)
            .onDisappear(perform: remove)
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { n in if n.object as? NSWindow === window { session.fullscreen = true } }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { n in if n.object as? NSWindow === window { session.fullscreen = false } }
    }

    private func install() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let w = window, event.window === w, player.ready else { return event }
            if w.firstResponder is NSTextView { return event }
            if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return event }
            let shift = event.modifierFlags.contains(.shift)
            switch event.keyCode {
            case 49: player.togglePlay()
            case 123: player.step(by: shift ? -1 : -player.frameDuration)
            case 124: player.step(by: shift ? 1 : player.frameDuration)
            case 115: player.toStart()
            case 119: player.toEnd()
            case 53: if session.fullscreen { w.toggleFullScreen(nil) } else { return event }
            default:
                let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
                if extra(key) { break }
                switch key {
                case "f" where fullscreenKey: w.toggleFullScreen(nil)
                case "l": player.loop.toggle()
                case "m": player.muted.toggle()
                default: return event
                }
            }
            return nil
        }
    }

    private func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        player.pause()
    }
}

extension View {
    func playerKeys(_ player: TrimPlayer, _ session: ToolSession, fullscreenKey: Bool = true, extra: @escaping (String) -> Bool = { _ in false }) -> some View {
        modifier(PlayerKeys(player: player, session: session, fullscreenKey: fullscreenKey, extra: extra))
    }
}

// MARK: - Trim stage (main card)

/// Player, transport buttons and timeline: the large card of the trim tools.
struct TrimStage: View {
    @ObservedObject var session: ToolSession
    @ObservedObject var player: TrimPlayer
    @State private var window: NSWindow?

    private var fullscreen: Bool { session.fullscreen }

    var body: some View {
        VStack(spacing: 10) {
            PlayerScreen(player: player, cornerRadius: fullscreen ? 0 : 8)
            TransportBar(player: player, fullscreen: fullscreen) { window?.toggleFullScreen(nil) }
            TrimTimelineView(player: player, hasVideo: player.hasVideo)
        }
        .padding(fullscreen ? 14 : 12)
        .background(fullscreen ? Color.black.opacity(0.9) : Color.clear)
        .background(WindowReader { window = $0 })
        .playerKeys(player, session) { key in
            switch key {
            case "i": player.setStartHere(); return true
            case "o": player.setEndHere(); return true
            default: return false
            }
        }
    }
}

// MARK: - Sidebar cards

/// Range, preview and output cards of the trim tools.
struct TrimSidebar: View {
    @ObservedObject var session: ToolSession
    @ObservedObject var player: TrimPlayer

    var body: some View {
        SidebarCard(title: "Range") {
            HStack(alignment: .bottom, spacing: 8) {
                TimeField(title: "Start", value: player.range.start, commit: { player.commitStart(text: $0) })
                Button("Here (I)") { player.setStartHere() }.help("Set start to the current position")
            }
            HStack(alignment: .bottom, spacing: 8) {
                TimeField(title: "End", value: player.range.end, commit: { player.commitEnd(text: $0) })
                Button("Here (O)") { player.setEndHere() }.help("Set end to the current position")
            }
            HStack {
                Text("Duration").foregroundStyle(.secondary)
                Spacer()
                Text(TrimRange.format(player.range.length)).font(.body.monospacedDigit())
                Button("All") { player.resetSelection() }.disabled(player.range.isWholeClip)
            }
        }
        .disabled(!player.ready)
        SidebarCard(title: "Preview") {
            HStack {
                Button("Play selection") { player.toStart(); player.play() }
                Toggle(isOn: $player.loop) { Image(systemName: "repeat") }.toggleStyle(.button).help("Loop selection (L)")
            }
            Text("Space: play · ←/→: one frame (Shift = 1 s) · I/O: set start/end · F: full screen · M: mute.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(!player.ready)
        SidebarCard(title: "Output") {
            Picker("", selection: Binding(get: { session.values.bool("precise", default: true) }, set: { session.values["precise"] = .bool($0) })) {
                Text("Precise").tag(true)
                Text("Fast").tag(false)
            }
            .pickerStyle(.segmented).labelsHidden()
            Text(session.values.bool("precise", default: true)
                 ? "Re-encodes and trims at the exact frame."
                 : "Copies without re-encoding: fast, but trims at the previous keyframe.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Editable time ("1:05.5" or seconds). Invalid text snaps back to the current value.
struct TimeField: View {
    @Environment(\.midnightSidebar) private var midnight
    let title: String
    let value: Double
    let commit: (String) -> Bool
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField("0:00.0", text: $text)
                .textFieldStyle(.roundedBorder).frame(width: midnight ? 150 : 84)
                .font(midnight ? .system(size: 20, weight: .medium, design: .monospaced) : .body).monospacedDigit()
                .focused($focused)
                .onSubmit(apply)
                .onChange(of: focused) { if !$0 { apply() } }
        }
        .onAppear { text = TrimRange.format(value) }
        .onChange(of: value) { if !focused { text = TrimRange.format($0) } }
    }

    private func apply() {
        if !commit(text) { text = TrimRange.format(value) }
    }
}

struct AudioStage: View {
    @ObservedObject var player: TrimPlayer
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "waveform").font(.system(size: 54)).foregroundStyle(.orange)
            Text(TrimRange.format(player.playhead) + " / " + TrimRange.format(player.range.duration))
                .font(.title2.monospacedDigit()).foregroundStyle(.white.opacity(0.85))
        }
    }
}

// MARK: - Timeline

/// Reserve room for the complete handle at both clip edges. All gestures use this
/// same coordinate system, including the first drag from start == 0.
struct TrimTimelineGeometry {
    enum Target: Equatable { case start, end, playhead }
    static let hitWidth: CGFloat = 28
    let width: CGFloat
    let duration: Double
    var inset: CGFloat { min(Self.hitWidth / 2, max(width, 0) / 4) }
    var trackWidth: CGFloat { max(width - 2 * inset, 1) }

    func x(_ time: Double) -> CGFloat {
        inset + CGFloat(min(max(time, 0), max(duration, 0)) / max(duration, 0.001)) * trackWidth
    }

    func time(_ x: CGFloat) -> Double {
        Double(min(max((x - inset) / trackWidth, 0), 1)) * max(duration, 0)
    }

    func target(at x: CGFloat, start: Double, end: Double) -> Target {
        let ds = abs(x - self.x(start)), de = abs(x - self.x(end))
        if min(ds, de) <= Self.hitWidth / 2 { return ds <= de ? .start : .end }
        return .playhead
    }
}

struct TrimTimelineView: View {
    @ObservedObject var player: TrimPlayer
    let hasVideo: Bool

    private let height: CGFloat = 64
    private let handleWidth: CGFloat = 14
    @State private var dragTarget: TrimTimelineGeometry.Target?

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width
                let layout = TrimTimelineGeometry(width: w, duration: player.range.duration)
                let xs = layout.x(player.range.start), xe = layout.x(player.range.end), xp = layout.x(player.playhead)
                ZStack(alignment: .topLeading) {
                    track(width: layout.trackWidth).offset(x: layout.inset).allowsHitTesting(false)
                    // Dim what will be cut away.
                    Rectangle().fill(Color.black.opacity(0.62)).frame(width: max(xs - layout.inset, 0), height: height).offset(x: layout.inset).allowsHitTesting(false)
                    Rectangle().fill(Color.black.opacity(0.62)).frame(width: max(w - layout.inset - xe, 0), height: height).offset(x: xe).allowsHitTesting(false)
                    Rectangle().stroke(CitrusEditor.coral, lineWidth: 2).frame(width: max(xe - xs, 0), height: height).offset(x: xs).allowsHitTesting(false)
                    // Playhead
                    Rectangle().fill(Color.yellow).frame(width: 2, height: height + 10).offset(x: xp - 1, y: -5).allowsHitTesting(false)
                    Circle().fill(Color.yellow).frame(width: 9, height: 9).offset(x: xp - 4.5, y: -8).allowsHitTesting(false)
                    handle(at: xs)
                    handle(at: xe)
                }
                .frame(width: w, height: height, alignment: .topLeading)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { g in
                        if dragTarget == nil {
                            dragTarget = layout.target(at: g.startLocation.x, start: player.range.start, end: player.range.end)
                        }
                        let time = layout.time(g.location.x)
                        switch dragTarget {
                        case .start?: player.setStart(time); player.scrub(to: player.range.start)
                        case .end?: player.setEnd(time); player.scrub(to: player.range.end)
                        default: player.scrub(to: time)
                        }
                    }
                    .onEnded { _ in dragTarget = nil; player.endScrub() })
            }
            .frame(height: height + 12)
            ticks.padding(.horizontal, TrimTimelineGeometry.hitWidth / 2)
        }
        .disabled(!player.ready)
        .opacity(player.ready ? 1 : 0.5)
    }

    @ViewBuilder private func track(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.25)).frame(width: width, height: height)
            if hasVideo {
                let thumbs = player.thumbnails
                HStack(spacing: 0) {
                    ForEach(Array(thumbs.enumerated()), id: \.offset) { _, img in
                        Group {
                            if let img { Image(decorative: img, scale: 1).resizable().scaledToFill() } else { Color.clear }
                        }
                        .frame(width: width / CGFloat(max(thumbs.count, 1)), height: height).clipped()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Canvas { ctx, size in
                    let peaks = player.waveform
                    guard !peaks.isEmpty else { return }
                    let barW = size.width / CGFloat(peaks.count)
                    for (i, p) in peaks.enumerated() {
                        let h = max(CGFloat(p) * size.height, 1)
                        ctx.fill(Path(CGRect(x: CGFloat(i) * barW, y: (size.height - h) / 2, width: max(barW, 1), height: h)), with: .color(.orange.opacity(0.85)))
                    }
                }
                .frame(width: width, height: height)
            }
        }
    }

    private func handle(at x: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4).fill(CitrusEditor.coral)
            .overlay(Rectangle().fill(Color.black).frame(width: 2, height: 22))
            .frame(width: handleWidth, height: height + 10)
            .offset(x: x - handleWidth / 2, y: -5)
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
    }

    private var ticks: some View {
        HStack {
            ForEach(0..<5, id: \.self) { i in
                Text(TrimRange.format(player.range.duration * Double(i) / 4)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                if i < 4 { Spacer() }
            }
        }
    }
}
