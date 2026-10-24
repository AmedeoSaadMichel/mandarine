import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Catalogue and compatibility data (UI independent)

enum FormatCatalog {
    struct Group: Identifiable {
        let category: Category
        let title: String
        let extensions: [String]
        var id: String { category.rawValue }
    }

    static let groups: [Group] = [
        Group(category: .image, title: "Images", extensions: ["jpg", "png", "webp", "heic", "tiff", "svg", "avif", "bmp", "gif"]),
        Group(category: .document, title: "Documents", extensions: ["pdf", "docx", "txt", "md", "rtf", "rtfd", "html", "epub"]),
        Group(category: .spreadsheet, title: "Spreadsheets", extensions: ["xlsx", "ods", "csv", "tsv"]),
        Group(category: .audio, title: "Audio", extensions: ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma"]),
        Group(category: .video, title: "Video", extensions: ["mp4", "mov", "mkv", "webm", "avi", "m4v"]),
    ]

    static func category(of ext: String) -> Category? { groups.first { $0.extensions.contains(Category.normalized(ext)) }?.category }

    /// Which settings make sense for a format.
    struct Options: Equatable {
        var quality: Bool
        var metadata: Bool
        var size: Bool
    }

    static func options(for ext: String) -> Options {
        let e = Category.normalized(ext)
        switch category(of: e) {
        case .image:
            let lossy = ["jpg", "heic", "webp", "avif"].contains(e)
            return Options(quality: lossy, metadata: ImageOps.writableExts.contains(e), size: true)
        case .audio, .video: return Options(quality: true, metadata: false, size: false)
        default: return Options(quality: false, metadata: false, size: false)
        }
    }

    static let sizeChoices: [(label: String, value: Int)] = [
        ("Original dimensions", 0), ("4096 px", 4096), ("2048 px", 2048), ("1920 px", 1920), ("1280 px", 1280), ("1024 px", 1024), ("512 px", 512),
    ]
}

struct CompatibilityItem: Identifiable, Equatable {
    let name: String
    let ok: Bool
    let detail: String
    var id: String { name }
}

enum CompatibilityReport {
    static func build(ffmpegPath: String? = Converter.ffmpegPath, encoders: Set<String> = Converter.ffmpegEncoders) -> [CompatibilityItem] {
        var items: [CompatibilityItem] = []
        items.append(CompatibilityItem(name: "ffmpeg", ok: ffmpegPath != nil, detail: ffmpegPath ?? "Not found. Install with: brew install ffmpeg"))
        let needs: [(String, String, [String])] = [
            ("MP3", "audio", ["libmp3lame"]), ("Ogg Vorbis", "audio", ["libvorbis", "vorbis"]), ("Opus", "audio", ["libopus", "opus"]),
            ("H.264 (MP4)", "video", ["libx264"]), ("VP9 (WebM)", "video", ["libvpx-vp9"]),
            ("WebP", "images", ["libwebp"]), ("AVIF", "images", ["libaom-av1", "libsvtav1"]),
        ]
        for (name, kind, any) in needs {
            let ok = any.contains { encoders.contains($0) }
            items.append(CompatibilityItem(name: name, ok: ok, detail: ok ? "Available" : (ffmpegPath == nil ? "Requires ffmpeg" : "Your ffmpeg installation has no encoder for \(kind) \(name)")))
        }
        items.append(CompatibilityItem(name: "Images, PDFs, documents", ok: true, detail: "Built-in macOS features"))
        return items
    }
}

// MARK: - Settings window

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, shelves, formats, folders, compatibility, about
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .shelves: return "square.stack.3d.up"
        case .formats: return "doc.on.doc"
        case .folders: return "folder"
        case .compatibility: return "checkmark.shield"
        case .about: return "info.circle"
        }
    }
    var subtitle: String {
        switch self {
        case .general: return "A few small touches. A smoother everyday."
        case .shelves: return "Keep files close. Pick up where you left off."
        case .formats: return "Your favourite formats, just the way you like them."
        case .folders: return "A comfortable landing place for every new file."
        case .compatibility: return "Everything you need, ready for the next drop."
        case .about: return "A small app with a lot of possibilities."
        }
    }
}

struct SettingsView: View {
    @State private var selection: SettingsPage
    init(initialPage: SettingsPage = .general) { _selection = State(initialValue: initialPage) }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 8) {
                    WheelCitrusMark().frame(width: 40, height: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Mandarine").font(CitrusEditor.heading(23))
                        Text("YOUR FILE UNIVERSE").font(.system(size: 8, weight: .semibold)).foregroundStyle(CitrusEditor.muted)
                    }
                }.padding(.top, 20).padding(.bottom, 8)
                VStack(spacing: 6) {
                    ForEach(SettingsPage.allCases) { page in
                        Button { selection = page } label: {
                            HStack(spacing: 12) {
                                Image(systemName: page.symbol).frame(width: 20)
                                Text(page.title).font(.system(size: 14, weight: selection == page ? .semibold : .regular))
                                Spacer()
                            }
                            .foregroundStyle(selection == page ? CitrusEditor.mint : CitrusEditor.muted)
                            .padding(.horizontal, 12).frame(height: 42)
                            .background(selection == page ? Color(nsColor: ShelfCitrus.selected) : .clear, in: RoundedRectangle(cornerRadius: 10))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selection == page ? .isSelected : [])
                    }
                }
                Spacer()
                VStack(alignment: .leading, spacing: 5) {
                    Text("Made for your Mac.").font(.system(size: 12))
                    Text("Everything stays local.").font(.system(size: 11)).foregroundStyle(CitrusEditor.muted)
                }.padding(10)
            }
            .padding(.horizontal, 16).padding(.bottom, 14).frame(width: 212)
            Rectangle().fill(CitrusEditor.border.opacity(0.6)).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(selection.title).font(CitrusEditor.heading(36))
                    Text(selection.subtitle).font(.system(size: 13)).foregroundStyle(CitrusEditor.muted)
                }.padding(.horizontal, 30).padding(.top, 28).padding(.bottom, 24)
                Group {
                    switch selection {
                    case .general: GeneralTab()
                    case .shelves: ShelvesSettingsTab()
                    case .formats: FormatsTab()
                    case .folders: FoldersTab()
                    case .compatibility: CompatibilityTab()
                    case .about: AboutTab()
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 960, height: 760)
        .background(Color(nsColor: ShelfCitrus.background))
        .foregroundStyle(WheelCitrus.cream)
        .tint(CitrusEditor.mint)
        .preferredColorScheme(.dark)
        .toggleStyle(SettingsSwitchStyle())
        .buttonStyle(CitrusFooterButtonStyle())
    }
}

private struct SettingsSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer(minLength: 16)
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .labelsHidden().toggleStyle(.switch).tint(CitrusEditor.mint)
        }
    }
}

/// Scrollable cards keep every native control reachable, including at larger text sizes.
private struct SettingsForm<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24, content: content)
                .padding(.horizontal, 30).padding(.bottom, 30)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SettingsCard<Content: View>: View {
    var title: String?
    @ViewBuilder var content: () -> Content
    init(_ title: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.content = content
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title { Text(title).font(CitrusEditor.heading(21)).foregroundStyle(WheelCitrus.cream) }
            VStack(alignment: .leading, spacing: 18, content: content)
                .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                .background(CitrusEditor.panel, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(CitrusEditor.border.opacity(0.45)))
        }
    }
}

struct ShelvesSettingsTab: View {
    @ObservedObject var s = Settings.shared
    var body: some View {
        SettingsForm {
            SettingsCard("Drag & go") {
                Toggle("Open a shelf while dragging", isOn: $s.optionOpensShelf)
                ModifierShortcutRow(title: "Shelf shortcut", modifier: $s.shelfModifier)
                    .disabled(!s.optionOpensShelf)
                Text("Click the shortcut, then press ⇧ Shift, ⌘ Command, ⌃ Control or ⌥ Option. Esc cancels.")
                    .font(.caption).foregroundStyle(CitrusEditor.muted)
                if s.optionOpensShelf, let wheel = s.wheel(for: s.shelfModifier) {
                    Label("\(s.shelfModifier.label) is assigned to the \(wheel.title.lowercased()) wheel. That wheel takes priority; choose a free modifier or change its shortcut in General.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(CitrusEditor.yellow)
                }
                Divider()
                Toggle("Remove from shelf after dragging", isOn: $s.removeShelfFilesAfterDrag)
                Text("Only after a successful drop into another app or folder. Original files stay in place.")
                    .font(.caption).foregroundStyle(CitrusEditor.muted)
            }
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    WheelCitrusMark().frame(width: 44, height: 44)
                    Text("A little space for your next move.").font(CitrusEditor.heading(24))
                }
                HStack(spacing: 25) {
                    Image(systemName: "square.stack.3d.up.fill").font(.system(size: 48)).rotationEffect(.degrees(-8)).foregroundStyle(CitrusEditor.yellow)
                    Image(systemName: "arrow.right").font(.title2).foregroundStyle(CitrusEditor.mint)
                    Label("Your app", systemImage: "folder").padding(20).background(CitrusEditor.surface, in: RoundedRectangle(cornerRadius: 12))
                }.frame(maxWidth: .infinity).padding(.vertical, 15).accessibilityHidden(true)
                Text("Grid, list or a whole stack. Quick Look with Space.")
                Text("Dock to an edge. Hover or drag over the tab to bring it back.")
                    .font(.callout).foregroundStyle(CitrusEditor.muted)
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: ShelfCitrus.selected).opacity(0.8), in: RoundedRectangle(cornerRadius: 16))
            Label("Shelves and their view are saved automatically.", systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(CitrusEditor.mint)
        }
    }
}

struct GeneralTab: View {
    @ObservedObject var s = Settings.shared
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?

    var body: some View {
        SettingsForm {
            SettingsCard("Appearance") {
                Picker("Style", selection: $s.appearance) { ForEach(AppearanceStyle.allCases) { Text($0.label).tag($0) } }.pickerStyle(.segmented)
                Picker("Progress", selection: $s.progressStyle) { ForEach(ProgressStyle.allCases) { Text($0.label).tag($0) } }
            }
            SettingsCard("Startup and feedback") {
                Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: setLogin))
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                Toggle("Completion sound", isOn: $s.soundEnabled)
                Toggle("Haptic feedback", isOn: $s.hapticEnabled)
            }
            SettingsCard("Wheels — tap a modifier while dragging files") {
                ModifierShortcutRow(title: "Conversion wheel", modifier: $s.conversionModifier)
                ModifierShortcutRow(title: "Tools wheel", modifier: $s.toolsModifier)
                ModifierShortcutRow(title: "Actions wheel", modifier: $s.actionsModifier)
                Text("Click a shortcut, then press ⇧ Shift, ⌘ Command, ⌃ Control or ⌥ Option. Esc cancels.")
                    .font(.caption).foregroundStyle(CitrusEditor.muted)
                if Set([s.conversionModifier, s.toolsModifier, s.actionsModifier]).count < 3 {
                    Label("Two wheels use the same modifier: only one will open.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            }
            SettingsCard("Terminal") {
                HStack {
                    Text("Terminal app")
                    Spacer()
                    Text(URL(fileURLWithPath: s.terminalAppPath).deletingPathExtension().lastPathComponent).foregroundStyle(.secondary)
                    Button("Choose…") { chooseTerminal() }
                }
            }
            SettingsCard("Excluded apps") {
                ExcludedAppsList()
            }
        }
        
    }

    private func setLogin(_ on: Bool) {
        do { try LoginItem.set(on); launchAtLogin = on; loginError = nil }
        catch { launchAtLogin = LoginItem.isEnabled; loginError = "Unable to change launch at login: \(error.localizedDescription)" }
    }

    private func chooseTerminal() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.application]
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        if p.runModal() == .OK, let u = p.url { s.terminalAppPath = u.path }
    }
}

struct ExcludedAppsList: View {
    @ObservedObject var s = Settings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Drag gestures are ignored in the apps listed below.").font(.caption).foregroundStyle(.secondary)
            ForEach(s.excludedApps, id: \.self) { id in
                HStack {
                    Text(name(for: id))
                    Text(id).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { s.include(id) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                }
            }
            Button("Add app…") {
                let p = NSOpenPanel()
                p.allowedContentTypes = [.application]
                p.directoryURL = URL(fileURLWithPath: "/Applications")
                if p.runModal() == .OK, let u = p.url, let id = Bundle(url: u)?.bundleIdentifier { s.exclude(id) }
            }
        }
    }

    private func name(for bundleID: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { FileManager.default.displayName(atPath: $0.path) } ?? bundleID
    }
}

struct FormatsTab: View {
    @ObservedObject var s = Settings.shared
    @State private var selected = "jpg"
    @State private var search = ""

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                TextField("Search", text: $search).textFieldStyle(.roundedBorder).padding(8)
                List(selection: $selected) {
                    ForEach(FormatCatalog.groups) { group in
                        let items = group.extensions.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }
                        if !items.isEmpty {
                            Section(group.title) {
                                ForEach(items, id: \.self) { ext in
                                    HStack {
                                        Text(ext.uppercased())
                                        if s.hasCustomPrefs(for: ext) { Spacer(); Circle().fill(Color.orange).frame(width: 6, height: 6) }
                                    }.tag(ext)
                                }
                            }
                        }
                    }
                }.scrollContentBackground(.hidden).listStyle(.sidebar)
            }
            .frame(width: 170).background(CitrusEditor.panel)
            FormatDetail(ext: selected).frame(maxWidth: .infinity)
        }
    }
}

struct FormatDetail: View {
    @ObservedObject var s = Settings.shared
    let ext: String
    @State private var targets: [String] = []

    private var prefs: Binding<FormatPrefs> { Binding(get: { s.prefs(for: ext) }, set: { s.setPrefs($0, for: ext) }) }

    var body: some View {
        let options = FormatCatalog.options(for: ext)
        SettingsForm {
            SettingsCard {
                Text(ext.uppercased()).font(CitrusEditor.heading(30))
                Text(summary).font(.callout).foregroundStyle(.secondary)
            }
            if options.quality || options.metadata || options.size {
                SettingsCard("Output format: \(ext.uppercased())") {
                    if options.quality {
                        Picker("Quality", selection: prefs.quality) { ForEach(Quality.allCases, id: \.self) { Text($0.label).tag($0) } }
                    }
                    if options.metadata { Toggle("Preserve metadata", isOn: prefs.preserveMetadata) }
                    if options.size {
                        Picker("Image size", selection: prefs.maxDimension) {
                            ForEach(FormatCatalog.sizeChoices, id: \.value) { Text($0.label).tag($0.value) }
                        }
                    }
                }
                SettingsCard { Button("Restore defaults") { s.restoreDefaults(for: ext) }.disabled(!s.hasCustomPrefs(for: ext)) }
            } else {
                SettingsCard { Text("No specific settings for this format.").foregroundStyle(.secondary) }
            }
        }
        .task(id: ext) {
            let format = ext
            let values = await Task.detached {
                Converter.targets(for: URL(fileURLWithPath: "/tmp/a.\(format)")).map { $0.uppercased() }
            }.value
            guard !Task.isCancelled else { return }
            targets = values
        }
    }

    private var summary: String {
        let group = FormatCatalog.groups.first { $0.extensions.contains(ext) }?.title ?? ""
        return targets.isEmpty ? group : "\(group) · converts to: " + targets.joined(separator: ", ")
    }
}

struct FoldersTab: View {
    @ObservedObject var s = Settings.shared

    var body: some View {
        SettingsForm {
            SettingsCard("Save output to") {
                Picker("Location", selection: $s.outputLocation) { ForEach(OutputLocation.allCases) { Text($0.label).tag($0) } }
                    .disabled(!s.outputFolderPath.isEmpty)
                HStack {
                    Text("Custom folder")
                    Spacer()
                    Text(s.outputFolderPath.isEmpty ? "None" : s.outputFolderPath).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button("Choose…") {
                        let p = NSOpenPanel()
                        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                        if p.runModal() == .OK, let u = p.url { s.outputFolderPath = u.path }
                    }
                    if !s.outputFolderPath.isEmpty { Button("Remove") { s.outputFolderPath = "" } }
                }
                Text("A custom folder overrides the location setting. Existing files are never overwritten: a number is added to the name.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SettingsCard("Default quality") {
                Picker("For formats without custom settings", selection: $s.quality) { ForEach(Quality.allCases, id: \.self) { Text($0.label).tag($0) } }
            }
        }
        
    }
}

struct CompatibilityTab: View {
    @State private var items: [CompatibilityItem] = []
    var body: some View {
        SettingsForm {
            SettingsCard("Components") {
                if items.isEmpty { ProgressView("Checking components…") }
                ForEach(items) { item in
                    HStack(alignment: .top) {
                        Image(systemName: item.ok ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(item.ok ? .green : .red)
                        VStack(alignment: .leading) {
                            Text(item.name)
                            Text(item.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            SettingsCard("System") {
                Text(ProcessInfo.processInfo.operatingSystemVersionString)
                Text("\(ToolID.allCases.filter { $0.needsFFmpeg }.count) tools require ffmpeg").font(.caption).foregroundStyle(.secondary)
            }
        }
        .task {
            items = await Task.detached { CompatibilityReport.build() }.value
        }
    }
}

struct AboutTab: View {
    var body: some View {
        VStack(spacing: 16) {
            WheelCitrusMark().frame(width: 126, height: 126)
            Text("Mandarine").font(CitrusEditor.heading(48))
            Text("MIT License · © 2026 AmedeoSaadMichel").font(.caption).foregroundStyle(.secondary)
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1")").foregroundStyle(.secondary)
            Text("Convert and edit files by dropping them on a wheel. Everything runs on your Mac.").multilineTextAlignment(.center).padding(.horizontal, 40)
            CoffeeBanner()
                .padding(.top, 12)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Local vector banner: no tracking pixels or network requests when opening About.
private struct CoffeeBanner: View {
    static let url = URL(string: "https://buymeacoffee.com/asmichel")!
    var body: some View {
        Link(destination: Self.url) {
            HStack(spacing: 14) {
                Image(systemName: "cup.and.saucer.fill").font(.system(size: 29))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Buy me a coffee").font(CitrusEditor.heading(25))
                    Text("Support the little universe of Mandarine").font(.system(size: 11, weight: .medium))
                }
                Image(systemName: "arrow.up.right").font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(Color(red: 0.12, green: 0.09, blue: 0.16))
            .padding(.horizontal, 24).padding(.vertical, 18)
            .background(CitrusEditor.yellow, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .help("Open Buy Me a Coffee in your browser")
        .accessibilityLabel("Buy me a coffee. Support Mandarine.")
    }
}
