import AppKit
import PDFKit
import SwiftUI

// MARK: - Cards

/// A titled card in the sidebar.
struct SidebarCard<Content: View>: View {
    let title: String
    @Environment(\.midnightSidebar) private var midnight
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(midnight ? title.uppercased() : title).font(midnight ? .system(size: 10, weight: .semibold) : .headline)
                .foregroundStyle(midnight ? CitrusEditor.muted : .primary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(midnight ? 18 : 14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(midnight ? .clear : Color.gray.opacity(0.12)))
        .overlay(alignment: .top) {
            if midnight { Rectangle().fill(CitrusEditor.border).frame(height: 1).padding(.horizontal, 18) }
            else { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(CitrusEditor.border) }
        }
    }
}

/// The large card on the left that holds the preview or the files.
struct MainCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(CitrusEditor.panel))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(CitrusEditor.border))
    }
}

// MARK: - Shell

/// Common frame of every tool window: preview card on the left, sidebar cards on the right,
/// footer with the tool icon, the file name, Cancel and the main button.
struct ToolShell<Main: View, Side: View>: View {
    @ObservedObject var session: ToolSession
    @ViewBuilder var main: Main
    @ViewBuilder var side: Side

    var body: some View {
        VStack(spacing: 0) {
            if !session.fullscreen { CitrusEditorHeader(session: session) }
            HStack(alignment: .top, spacing: 16) {
                MainCard { main }
                if !session.fullscreen {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.tool.shortTitle)
                                .font(CitrusEditor.heading(29)).foregroundStyle(WheelCitrus.cream)
                                .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 8)
                            side
                        }
                        .padding(.bottom, 14)
                    }
                    .frame(width: session.tool.sidebarWidth)
                    .background(CitrusEditor.panel, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(CitrusEditor.border))
                    .environment(\.midnightSidebar, true)
                }
            }
            .padding(session.fullscreen ? 0 : 16)
            if !session.fullscreen { ToolFooter(session: session, midnight: true) }
        }
        .background(CitrusEditor.background)
        .foregroundStyle(WheelCitrus.cream)
        .tint(CitrusEditor.coral)
        .environment(\.colorScheme, .dark)
        .frame(minWidth: session.tool.minimumWindowSize.width, minHeight: session.tool.minimumWindowSize.height)
    }
}

struct ToolFooter: View {
    @ObservedObject var session: ToolSession
    var midnight = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = session.errorMessage, error != "Cancelled." {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .background(midnight ? CitrusEditor.background.opacity(0.96) : .clear, in: RoundedRectangle(cornerRadius: 8))
            }
            if !session.results.isEmpty && !session.running { ResultsView(results: session.results) }
            HStack(spacing: 12) {
                Image(systemName: midnight ? "checkmark.shield" : session.tool.symbol)
                    .foregroundStyle(midnight ? CitrusEditor.mint : .secondary).frame(width: 18)
                Text(midnight ? "Your original stays safe. We save a copy." : session.fileLabel)
                    .font(midnight ? .caption : .body).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    .padding(6).background(midnight ? CitrusEditor.background.opacity(0.94) : .clear, in: RoundedRectangle(cornerRadius: 6))
                if session.running {
                    ProgressView(value: session.progress).progressViewStyle(.linear).frame(maxWidth: 180)
                } else if session.errorMessage == "Cancelled." {
                    Text("Cancelled").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(session.running ? "Cancel" : (session.results.isEmpty ? "Cancel" : "Close")) { session.cancelOrClose() }
                    .buttonStyle(CitrusFooterButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .padding(4).background(midnight ? CitrusEditor.background.opacity(0.94) : .clear, in: RoundedRectangle(cornerRadius: 8))
                Button(session.results.isEmpty || session.running ? session.primaryTitle : "Run again") { session.run() }
                    .buttonStyle(CitrusFooterButtonStyle(primary: true))
                    .foregroundStyle(midnight ? WheelCitrus.ink : .white)
                    .keyboardShortcut(session.trimPlayer == nil ? KeyboardShortcut.defaultAction : KeyboardShortcut(.return, modifiers: .command))
                    .disabled(!session.canRun)
                    .padding(4).background(midnight ? CitrusEditor.background.opacity(0.94) : .clear, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(minHeight: midnight ? 76 : nil)
        .background {
            if midnight {
                CitrusEditor.background
                CitrusFooterArt()
            } else { Color(nsColor: .windowBackgroundColor) }
        }
    }
}

// MARK: - Sidebar contents

/// Parameter cards, one per section.
struct ParamSections: View {
    @ObservedObject var session: ToolSession

    var body: some View {
        ForEach(session.sidebarSections, id: \.title) { section in
            SidebarCard(title: section.title) {
                ForEach(section.params) { p in
                    ParamRow(session: session, param: p, showLabel: !(section.params.count == 1 && p.label == section.title))
                }
            }
        }
    }
}

/// A whole-number field that applies its value on Return or when it loses focus.
struct PixelField: View {
    let title: String
    let value: Int
    var unit = "px"
    var disabled = false
    let commit: (Int) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                TextField("", text: $text).textFieldStyle(.roundedBorder).monospacedDigit().multilineTextAlignment(.trailing)
                    .focused($focused).onSubmit(apply).onChange(of: focused) { if !$0 { apply() } }
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(disabled).opacity(disabled ? 0.5 : 1)
        .onAppear { text = String(value) }
        .onChange(of: value) { if !focused { text = String($0) } }
    }

    private func apply() {
        if let v = Int(text.trimmingCharacters(in: .whitespaces)) { commit(v) } else { text = String(value) }
    }
}

/// Crop: position and size of the box in pixels, with Center and Whole image.
struct CropInfoCard: View {
    @ObservedObject var session: ToolSession

    var body: some View {
        SidebarCard(title: "Crop area") {
            if let box = session.cropBox, let size = session.sourceSize {
                Grid(horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        PixelField(title: "X", value: box.x) { session.setCrop(.x, $0) }
                        PixelField(title: "Y", value: box.y) { session.setCrop(.y, $0) }
                    }
                    GridRow {
                        PixelField(title: "Width", value: box.width) { session.setCrop(.width, $0) }
                        PixelField(title: "Height", value: box.height) { session.setCrop(.height, $0) }
                    }
                }
                Text("Original: \(Int(size.width)) × \(Int(size.height)) px").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Drag on the image to select an area.").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button("Center") { session.centerCrop() }.disabled(session.cropBox == nil)
                Button("Full image") { session.wholeImageCrop() }
            }
        }
    }

    /// "1024 × 576 a 128, 72".
    static func describe(_ rect: CGRect, in size: CGSize) -> String {
        let p = CropGeometry.pixels(rect, in: size)
        return "\(p.width) × \(p.height) at \(p.x), \(p.y)"
    }
}

/// Video crop: size of the file that is written.
struct OutputSizeCard: View {
    @ObservedObject var session: ToolSession

    var body: some View {
        let same = session.values.bool("sameSize", default: true)
        let box = session.cropBox
        SidebarCard(title: "Output dimensions") {
            Toggle("Same as crop area", isOn: Binding(get: { same }, set: { on in
                session.values["sameSize"] = .bool(on)
                if !on, let b = box {
                    session.values["outWidth"] = .number(Double(CropGeometry.even(b.width)))
                    session.values["outHeight"] = .number(Double(CropGeometry.even(b.height)))
                }
                session.valuesChanged()
            }))
            HStack(spacing: 10) {
                PixelField(title: "Width", value: same ? CropGeometry.even(box?.width ?? 0) : Int(session.values.number("outWidth")), disabled: same) { session.setOutput(width: $0) }
                PixelField(title: "Height", value: same ? CropGeometry.even(box?.height ?? 0) : Int(session.values.number("outHeight")), disabled: same) { session.setOutput(height: $0) }
            }
            Toggle("Keep aspect ratio", isOn: Binding(get: { session.values.bool("keepRatio", default: true) }, set: { session.values["keepRatio"] = .bool($0); session.valuesChanged() }))
                .disabled(same)
            Text("Audio stays unchanged. Output is MP4 (H.264); dimensions are rounded to even numbers.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Redact: the areas drawn so far.
struct AreasCard: View {
    @ObservedObject var session: ToolSession

    var body: some View {
        let areas = session.values.rects("areas")
        SidebarCard(title: "Areas (\(areas.count))") {
            if areas.isEmpty {
                Text("Drag on the image to add an area to redact.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(areas.enumerated()), id: \.offset) { i, r in
                HStack {
                    Text("Area \(i + 1)").font(.callout)
                    Text("\(Int(r.width * 100))% × \(Int(r.height * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    Button { remove(i) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                }
            }
            if !areas.isEmpty { Button("Clear all") { session.values["areas"] = .rects([]); session.valuesChanged() }.buttonStyle(.link) }
        }
    }

    private func remove(_ i: Int) {
        var a = session.values.rects("areas")
        guard a.indices.contains(i) else { return }
        a.remove(at: i)
        session.values["areas"] = .rects(a)
        session.valuesChanged()
    }
}

struct SummaryCard: View {
    let lines: [String]
    var body: some View {
        SidebarCard(title: "Summary") {
            ForEach(lines, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
        }
    }
}

// MARK: - Main card contents

/// Live preview of a pixel tool, over a checkerboard so transparency shows.
struct PreviewMain: View {
    @ObservedObject var session: ToolSession

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                CheckerboardView()
                if let p = session.previewImage {
                    Image(nsImage: p).resizable().scaledToFit().padding(12)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if session.files.count > 1 { Divider(); FileListView(session: session).padding(12) }
        }
    }
}

/// Files with icon, name, size. For tools where the order matters, with arrows.
struct FilesMain: View {
    @ObservedObject var session: ToolSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if session.files.count > 1 {
                    Text(session.orderMatters ? "Files, in the order they will be used" : "File").font(.caption.bold()).foregroundStyle(.secondary)
                }
                ForEach(Array(session.files.enumerated()), id: \.offset) { i, url in
                    HStack(spacing: 12) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(url.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
                            Text(Self.detail(url)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if session.orderMatters && session.files.count > 1 {
                            Button { session.move(i, by: -1) } label: { Image(systemName: "chevron.up") }.disabled(i == 0)
                            Button { session.move(i, by: 1) } label: { Image(systemName: "chevron.down") }.disabled(i == session.files.count - 1)
                        }
                    }
                    .buttonStyle(.borderless)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(CitrusEditor.panel))
                }
            }
            .padding(16)
        }
    }

    /// "7,3 MB · MP4".
    static func detail(_ url: URL) -> String {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 ?? 0
        let bytes = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        return url.pathExtension.isEmpty ? bytes : "\(bytes) · \(url.pathExtension.uppercased())"
    }
}

/// Edit metadata: file facts and the editable fields.
struct MetadataMain: View {
    @ObservedObject var session: ToolSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                FilesMain.factsBlock(session.files)
                let fields = session.params.filter { $0.inMain }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Fields").font(.headline)
                    if session.values.string("mode", default: "edit") == "clean" {
                        Text("All metadata will be removed from the copy.").font(.callout).foregroundStyle(.secondary)
                    } else if fields.isEmpty {
                        Text("No editable fields for this selection.").font(.callout).foregroundStyle(.secondary)
                    } else {
                        ForEach(fields) { ParamRow(session: session, param: $0) }
                    }
                }
                .opacity(session.values.string("mode", default: "edit") == "clean" ? 0.4 : 1)
            }
            .padding(18)
        }
    }
}

extension FilesMain {
    /// Name, size and type of the first file, plus how many more there are.
    static func factsBlock(_ files: [URL]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                if let f = files.first { Image(nsImage: NSWorkspace.shared.icon(forFile: f.path)).resizable().frame(width: 36, height: 36) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(files.first?.lastPathComponent ?? "").font(.headline).lineLimit(1).truncationMode(.middle)
                    Text(files.count > 1 ? "and \(files.count - 1) files" : detail(files[0])).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
