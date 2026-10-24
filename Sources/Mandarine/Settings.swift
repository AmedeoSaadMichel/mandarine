import AppKit
import ServiceManagement
import SwiftUI

enum Modifier: String, CaseIterable, Identifiable {
    case shift, command, control, option
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var flag: NSEvent.ModifierFlags {
        switch self {
        case .shift: return .shift
        case .command: return .command
        case .control: return .control
        case .option: return .option
        }
    }
}

enum OutputLocation: String, CaseIterable, Identifiable {
    case beside, downloads, desktop
    var id: String { rawValue }
    var label: String {
        switch self {
        case .beside: return "Next to original"
        case .downloads: return "Downloads"
        case .desktop: return "Desktop"
        }
    }
}

enum WheelKind: String, CaseIterable {
    case conversion, tools, actions
    var title: String { rawValue.capitalized }
}

enum AppearanceStyle: String, CaseIterable, Identifiable {
    case glass, solid
    var id: String { rawValue }
    var label: String { self == .glass ? "Glass" : "Solid" }
}

enum ProgressStyle: String, CaseIterable, Identifiable {
    case floating, notch
    var id: String { rawValue }
    var label: String { self == .floating ? "Floating window" : "Notch" }
}

final class Settings: ObservableObject {
    static let shared = Settings(defaults: .standard)
    let defaults: UserDefaults

    @Published var conversionModifier: Modifier { didSet { defaults.set(conversionModifier.rawValue, forKey: "conv") } }
    @Published var toolsModifier: Modifier { didSet { defaults.set(toolsModifier.rawValue, forKey: "tools") } }
    @Published var actionsModifier: Modifier { didSet { defaults.set(actionsModifier.rawValue, forKey: "actions") } }
    /// Default quality for formats that have no settings of their own.
    @Published var quality: Quality { didSet { defaults.set(quality.rawValue, forKey: "quality") } }
    @Published var soundEnabled: Bool { didSet { defaults.set(soundEnabled, forKey: "sound") } }
    @Published var shelfModifier: Modifier { didSet { defaults.set(shelfModifier.rawValue, forKey: "shelfModifier") } }
    @Published var optionOpensShelf: Bool { didSet { defaults.set(optionOpensShelf, forKey: "optionOpensShelf") } }
    @Published var removeShelfFilesAfterDrag: Bool { didSet { defaults.set(removeShelfFilesAfterDrag, forKey: "removeShelfFilesAfterDrag") } }
    @Published var hapticEnabled: Bool { didSet { defaults.set(hapticEnabled, forKey: "haptic") } }
    @Published var outputFolderPath: String { didSet { defaults.set(outputFolderPath, forKey: "outFolder") } }
    @Published var outputLocation: OutputLocation { didSet { defaults.set(outputLocation.rawValue, forKey: "outLoc") } }
    @Published var terminalAppPath: String { didSet { defaults.set(terminalAppPath, forKey: "terminal") } }
    @Published var appearance: AppearanceStyle { didSet { defaults.set(appearance.rawValue, forKey: "appearance") } }
    @Published var progressStyle: ProgressStyle { didSet { defaults.set(progressStyle.rawValue, forKey: "progressStyle") } }
    /// Bundle identifiers of apps in which the drag gestures are ignored.
    @Published var excludedApps: [String] { didSet { defaults.set(excludedApps, forKey: "excludedApps") } }
    @Published private(set) var formatPrefs: [String: FormatPrefs] { didSet { saveFormatPrefs() } }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        func mod(_ key: String, _ def: Modifier) -> Modifier { Modifier(rawValue: defaults.string(forKey: key) ?? "") ?? def }
        conversionModifier = mod("conv", .shift)
        toolsModifier = mod("tools", .command)
        actionsModifier = mod("actions", .control)
        quality = Quality(rawValue: defaults.string(forKey: "quality") ?? "") ?? .balanced
        shelfModifier = mod("shelfModifier", .option)
        optionOpensShelf = defaults.object(forKey: "optionOpensShelf") as? Bool ?? true
        removeShelfFilesAfterDrag = defaults.bool(forKey: "removeShelfFilesAfterDrag")
        soundEnabled = defaults.object(forKey: "sound") as? Bool ?? true
        hapticEnabled = defaults.object(forKey: "haptic") as? Bool ?? true
        outputFolderPath = defaults.string(forKey: "outFolder") ?? ""
        outputLocation = OutputLocation(rawValue: defaults.string(forKey: "outLoc") ?? "") ?? .beside
        terminalAppPath = defaults.string(forKey: "terminal") ?? "/System/Applications/Utilities/Terminal.app"
        appearance = AppearanceStyle(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .glass
        progressStyle = ProgressStyle(rawValue: defaults.string(forKey: "progressStyle") ?? "") ?? .floating
        excludedApps = defaults.stringArray(forKey: "excludedApps") ?? []
        if let data = defaults.data(forKey: "formatPrefs"), let decoded = try? JSONDecoder().decode([String: FormatPrefs].self, from: data) {
            formatPrefs = decoded
        } else {
            formatPrefs = [:]
        }
    }

    // MARK: Output

    /// Where results go: a custom folder when set, otherwise by location; nil means next to the original.
    var outputFolder: URL? {
        if !outputFolderPath.isEmpty { return URL(fileURLWithPath: outputFolderPath) }
        switch outputLocation {
        case .beside: return nil
        case .downloads: return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        case .desktop: return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        }
    }

    func outputFolder(for file: URL?) -> URL? { outputFolder }

    // MARK: Wheels

    func wheel(for modifier: Modifier) -> WheelKind? {
        if modifier == conversionModifier { return .conversion }
        if modifier == toolsModifier { return .tools }
        if modifier == actionsModifier { return .actions }
        return nil
    }

    // MARK: Per-format settings

    func prefs(for ext: String) -> FormatPrefs {
        formatPrefs[Category.normalized(ext)] ?? FormatPrefs(quality: quality)
    }

    func setPrefs(_ prefs: FormatPrefs, for ext: String) { formatPrefs[Category.normalized(ext)] = prefs }

    func restoreDefaults(for ext: String) { formatPrefs[Category.normalized(ext)] = nil }

    func hasCustomPrefs(for ext: String) -> Bool { formatPrefs[Category.normalized(ext)] != nil }

    private func saveFormatPrefs() {
        if let data = try? JSONEncoder().encode(formatPrefs) { defaults.set(data, forKey: "formatPrefs") }
    }

    // MARK: Excluded apps

    func isExcluded(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return excludedApps.contains(bundleID)
    }

    func exclude(_ bundleID: String) {
        guard !excludedApps.contains(bundleID) else { return }
        excludedApps.append(bundleID)
    }

    func include(_ bundleID: String) { excludedApps.removeAll { $0 == bundleID } }
}

/// "Launch at login" through the system login-item service.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
