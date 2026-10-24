import AppKit
import Foundation

// MARK: - Tool catalogue

/// The tools offered by the Tools wheel. Each one opens a window with its own parameters.
enum ToolID: String, CaseIterable, Identifiable {
    // Any file
    case compress, editMetadata
    // Images
    case editImage, frameImage, cropImage, redactImage, resizeImage, rotateImage, createPDF, createCollage
    // Video
    case trimVideo, cropVideo, changeVideoSpeed, joinVideos, videoSnapshots, splitVideo, redactVideo
    // Audio
    case normalizeAudio, audioToVideo, trimAudio, audioChannels, redactAudio
    // PDF
    case mergePDF, organizePDF, splitPDF

    var id: String { rawValue }

    enum Arity { case single, any, multiple }

    var title: String {
        switch self {
        case .compress: return "Compress"
        case .editMetadata: return "Edit metadata"
        case .editImage: return "Edit photo"
        case .frameImage: return "Add a background"
        case .cropImage: return "Crop image"
        case .redactImage: return "Redact photo"
        case .resizeImage: return "Resize images"
        case .rotateImage: return "Rotate & flip"
        case .createPDF: return "Create a PDF"
        case .createCollage: return "Create a collage"
        case .trimVideo: return "Trim video"
        case .cropVideo: return "Crop video"
        case .changeVideoSpeed: return "Change speed"
        case .joinVideos: return "Join videos"
        case .videoSnapshots: return "Save frames"
        case .splitVideo: return "Split video"
        case .redactVideo: return "Redact video"
        case .normalizeAudio: return "Normalize volume"
        case .audioToVideo: return "Audio visualizer"
        case .trimAudio: return "Trim audio"
        case .audioChannels: return "Audio channels"
        case .redactAudio: return "Bleep audio"
        case .mergePDF: return "Merge PDFs"
        case .organizePDF: return "Organize pages"
        case .splitPDF: return "Split PDF"
        }
    }

    /// Short caption for the wheel cell.
    var shortTitle: String {
        switch self {
        case .editMetadata: return "Metadata"
        case .editImage: return "Edit"
        case .frameImage: return "Background"
        case .cropImage, .cropVideo: return "Crop"
        case .redactImage, .redactVideo: return "Redact"
        case .resizeImage: return "Resize"
        case .rotateImage: return "Rotate"
        case .createPDF: return "To PDF"
        case .createCollage: return "Collage"
        case .trimVideo, .trimAudio: return "Trim"
        case .changeVideoSpeed: return "Speed"
        case .joinVideos: return "Join"
        case .videoSnapshots: return "Frames"
        case .splitVideo, .splitPDF: return "Split"
        case .normalizeAudio: return "Normalize"
        case .audioToVideo: return "Visualizer"
        case .audioChannels: return "Channels"
        case .redactAudio: return "Bleep"
        case .mergePDF: return "Merge"
        case .organizePDF: return "Pages"
        case .compress: return "Compress"
        }
    }

    var symbol: String {
        switch self {
        case .compress: return "arrow.down.right.and.arrow.up.left"
        case .editMetadata: return "tag"
        case .editImage: return "slider.horizontal.3"
        case .frameImage: return "photo.artframe"
        case .cropImage, .cropVideo: return "crop"
        case .redactImage, .redactVideo: return "eye.slash"
        case .resizeImage: return "arrow.up.left.and.arrow.down.right"
        case .rotateImage: return "rotate.right"
        case .createPDF: return "doc.richtext"
        case .createCollage: return "square.grid.2x2"
        case .trimVideo, .trimAudio: return "scissors"
        case .changeVideoSpeed: return "speedometer"
        case .joinVideos: return "rectangle.stack"
        case .videoSnapshots: return "camera.viewfinder"
        case .splitVideo, .splitPDF: return "rectangle.split.2x1"
        case .normalizeAudio: return "waveform"
        case .audioToVideo: return "waveform.circle"
        case .audioChannels: return "speaker.wave.2"
        case .redactAudio: return "speaker.slash"
        case .mergePDF: return "doc.on.doc"
        case .organizePDF: return "list.number"
        }
    }

    var arity: Arity {
        switch self {
        case .compress, .editMetadata, .resizeImage, .rotateImage, .createPDF: return .any
        case .createCollage, .joinVideos, .mergePDF: return .multiple
        default: return .single
        }
    }

    /// Category of files the tool works on; nil for the tools that work on several.
    var category: Category? {
        switch self {
        case .compress, .editMetadata: return nil
        case .editImage, .frameImage, .cropImage, .redactImage, .resizeImage, .rotateImage, .createPDF, .createCollage: return .image
        case .trimVideo, .cropVideo, .changeVideoSpeed, .joinVideos, .videoSnapshots, .splitVideo, .redactVideo: return .video
        case .normalizeAudio, .audioToVideo, .trimAudio, .audioChannels, .redactAudio: return .audio
        case .mergePDF, .organizePDF, .splitPDF: return .document
        }
    }

    var needsFFmpeg: Bool {
        switch self {
        case .trimVideo, .cropVideo, .changeVideoSpeed, .joinVideos, .videoSnapshots, .splitVideo, .redactVideo,
             .normalizeAudio, .audioToVideo, .trimAudio, .audioChannels, .redactAudio: return true
        default: return false
        }
    }

    /// Whether the tool is offered for this exact selection.
    func applies(to files: [URL]) -> Bool {
        switch arity {
        case .single: guard files.count == 1 else { return false }
        case .any: guard files.count >= 1 else { return false }
        case .multiple: guard files.count >= 2 else { return false }
        }
        if needsFFmpeg && Converter.ffmpegPath == nil { return false }
        switch self {
        case .compress: return files.allSatisfy { Tools.supports(.compress, $0) }
        case .editMetadata: return files.allSatisfy { MetadataOps.supports($0) }
        default:
            guard let category else { return false }
            return files.allSatisfy { f in
                guard Category.of(f) == category else { return false }
                if category == .document { return Category.normalized(f.pathExtension) == "pdf" }
                return true
            }
        }
    }

    static func available(for files: [URL]) -> [ToolID] { allCases.filter { $0.applies(to: files) } }

    /// Tools whose window has a video or audio player.
    var usesPlayer: Bool { [.trimVideo, .trimAudio, .changeVideoSpeed, .videoSnapshots, .redactVideo, .splitVideo].contains(self) }
    var isTrim: Bool { self == .trimVideo || self == .trimAudio }

    // MARK: Window

    enum WindowClass { case compact, standard, editor }

    var windowClass: WindowClass {
        switch self {
        case .compress, .resizeImage, .rotateImage, .createPDF, .mergePDF, .splitPDF, .audioChannels: return .compact
        case .editMetadata, .normalizeAudio, .organizePDF, .createCollage, .joinVideos, .audioToVideo, .redactAudio: return .standard
        default: return .editor
        }
    }

    var defaultWindowSize: CGSize {
        if self == .redactVideo { return CGSize(width: 1180, height: 800) }
        switch windowClass {
        case .compact: return CGSize(width: 700, height: 560)
        case .standard: return CGSize(width: 860, height: 620)
        case .editor: return CGSize(width: 1040, height: 740)
        }
    }

    var minimumWindowSize: CGSize {
        if self == .redactVideo { return CGSize(width: 900, height: 650) }
        switch windowClass {
        case .compact: return CGSize(width: 580, height: 420)
        case .standard: return CGSize(width: 680, height: 460)
        case .editor: return CGSize(width: 800, height: 560)
        }
    }

    var sidebarWidth: CGFloat {
        switch windowClass {
        case .compact: return 260
        case .standard: return 290
        case .editor: return 320
        }
    }

    /// Label of the footer's main button.
    func primaryTitle(fileCount n: Int) -> String {
        switch self {
        case .compress: return n > 1 ? "Compress \(n) files" : "Compress"
        case .editMetadata: return n > 1 ? "Apply to \(n) files" : "Save copy"
        case .cropImage, .cropVideo: return "Crop"
        case .redactImage, .redactVideo: return "Redact"
        case .resizeImage: return n > 1 ? "Resize \(n) files" : "Resize"
        case .createPDF: return "Create PDF"
        case .createCollage: return "Create collage"
        case .trimVideo, .trimAudio: return "Trim"
        case .joinVideos: return "Merge"
        case .videoSnapshots: return "Save frames"
        case .splitVideo, .splitPDF: return "Split"
        case .normalizeAudio: return "Normalize"
        case .audioToVideo: return "Create video"
        case .redactAudio: return "Apply bleep"
        case .mergePDF: return "Merge"
        case .editImage, .frameImage, .rotateImage, .changeVideoSpeed, .audioChannels, .organizePDF: return n > 1 ? "Save \(n) copies" : "Save copy"
        }
    }
}

// MARK: - Parameters

struct Choice: Hashable {
    let id: String
    let label: String
}

enum ParamKind {
    case slider(min: Double, max: Double, step: Double, unit: String)
    case number(unit: String)
    case choice([Choice])
    case toggle
    case text(placeholder: String)
    case color
    /// Time as "90", "1:30", "0:01:30.5".
    case time
    /// Rectangles drawn on a preview, in 0…1 coordinates from the top-left.
    case rect(multi: Bool)
}

/// A redacted area of a video with the time range in which it is covered (nil = the whole video).
enum RedactShape: String, CaseIterable { case rectangle, ellipse, freehand }

struct TimedArea: Equatable {
    var rect: CGRect
    var shape: RedactShape = .rectangle
    /// Vertices relative to the bounding rectangle, retained when moving/resizing.
    var points: [CGPoint] = []
    var start: Double? = nil
    var end: Double? = nil

    var isWholeVideo: Bool { start == nil || end == nil }
    var window: (Double, Double)? { isWholeVideo ? nil : (start!, end!) }

    func covers(_ t: Double) -> Bool { window.map { t >= $0.0 - 0.0005 && t <= $0.1 + 0.0005 } ?? true }
}

enum ToolValue: Equatable {
    case number(Double)
    case text(String)
    case bool(Bool)
    case rects([CGRect])
    case areas([TimedArea])
    case speedZones([SpeedZone])
}

struct ToolParam: Identifiable {
    let id: String
    let label: String
    let kind: ParamKind
    let defaultValue: ToolValue
    var help: String? = nil
    var visible: ((ToolValues) -> Bool)? = nil
    /// Title of the sidebar card the parameter belongs to.
    var section: String? = nil
    /// Shown in the main card instead of the sidebar (the metadata fields).
    var inMain = false
    /// Drawn by a dedicated card, not by the generic parameter rows.
    var custom = false
}

struct ToolValues {
    var storage: [String: ToolValue] = [:]

    init(_ storage: [String: ToolValue] = [:]) { self.storage = storage }

    init(defaultsFor params: [ToolParam]) {
        for p in params { storage[p.id] = p.defaultValue }
    }

    subscript(id: String) -> ToolValue? {
        get { storage[id] }
        set { storage[id] = newValue }
    }

    func number(_ id: String, default d: Double = 0) -> Double {
        if case .number(let v)? = storage[id] { return v }
        if case .text(let s)? = storage[id], let v = Double(s) { return v }
        return d
    }

    func string(_ id: String, default d: String = "") -> String {
        if case .text(let s)? = storage[id] { return s }
        return d
    }

    func bool(_ id: String, default d: Bool = false) -> Bool {
        if case .bool(let b)? = storage[id] { return b }
        return d
    }

    func rects(_ id: String) -> [CGRect] {
        if case .rects(let r)? = storage[id] { return r }
        if case .areas(let a)? = storage[id] { return a.map(\.rect) }
        return []
    }

    /// Areas with their time ranges; plain rectangles count as covering the whole video.
    func areas(_ id: String) -> [TimedArea] {
        if case .areas(let a)? = storage[id] { return a }
        if case .rects(let r)? = storage[id] { return r.map { TimedArea(rect: $0) } }
        return []
    }

    func speedZones(_ id: String = "speedZones") -> [SpeedZone] {
        if case .speedZones(let zones)? = storage[id] { return zones }
        return []
    }

    /// Time field → seconds (nil when empty or invalid).
    func time(_ id: String) -> Double? { Tools.parseTime(string(id)) }
}

enum ToolError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let m) = self { return m }; return nil }
}

// MARK: - Colors as hex strings

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
}
