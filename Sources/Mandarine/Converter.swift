import AppKit
import Foundation

enum Category: String, CaseIterable {
    case image, document, spreadsheet, audio, video

    var extensions: [String] {
        switch self {
        case .image: return ["jpg", "png", "heic", "tiff", "bmp", "gif", "webp", "avif", "pdf"]
        case .document: return ["pdf", "txt", "rtf", "html", "docx", "md", "epub", "rtfd"]
        case .spreadsheet: return ["csv", "tsv", "xlsx", "ods"]
        case .audio: return ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff"]
        case .video: return ["mp4", "mov", "mkv", "webm", "gif", "mp3"]
        }
    }

    static func of(_ url: URL) -> Category? {
        let e = normalized(url.pathExtension)
        switch e {
        case "jpg", "png", "heic", "tiff", "bmp", "gif", "webp", "avif", "svg": return .image
        case "pdf", "txt", "rtf", "html", "docx", "md", "rtfd", "epub": return .document
        case "csv", "tsv", "xlsx", "ods": return .spreadsheet
        case "mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma": return .audio
        case "mp4", "mov", "mkv", "webm", "avi", "m4v": return .video
        default: return nil
        }
    }

    static func normalized(_ ext: String) -> String {
        let e = ext.lowercased()
        switch e {
        case "jpeg": return "jpg"
        case "tif": return "tiff"
        case "htm": return "html"
        case "markdown": return "md"
        default: return e
        }
    }
}

struct ConversionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum Quality: String, CaseIterable, Codable {
    case best, balanced, strong

    var label: String {
        switch self {
        case .best: return "Best"
        case .balanced: return "Balanced"
        case .strong: return "Smaller"
        }
    }

    func pick<T>(best: T, balanced: T, strong: T) -> T {
        switch self {
        case .best: return best
        case .balanced: return balanced
        case .strong: return strong
        }
    }

    /// JPEG/HEIC quality factor.
    var imageQuality: Double { pick(best: 0.95, balanced: 0.8, strong: 0.55) }
}

/// Per-format conversion settings (the "Formats" tab).
struct FormatPrefs: Codable, Equatable {
    var quality: Quality = .balanced
    var preserveMetadata = true
    /// Longest side in pixels; 0 keeps the original size.
    var maxDimension = 0
}

enum Converter {
    /// Prefer the self-contained runtime shipped in the app. External paths support source builds.
    static func findFFmpeg(bundleURL: URL = Bundle.main.bundleURL,
                           externalPaths: [String] = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]) -> String? {
        let bundled = bundleURL.appendingPathComponent("Contents/Helpers/ffmpeg").path
        return ([bundled] + externalPaths).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var ffmpegPath: String? { findFFmpeg() }
    static var bundledFFmpeg: Bool {
        ffmpegPath == Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ffmpeg").path
    }

    /// Encoders reported by the installed ffmpeg (empty when ffmpeg is missing).
    static let ffmpegEncoders: Set<String> = {
        guard let ff = ffmpegPath else { return [] }
        guard let result = try? ProcessRunner.blocking(ff, ["-hide_banner", "-encoders"]), result.status == 0 else { return [] }
        let data = result.stdout
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        return Set(lines.compactMap { $0.split(separator: " ").dropFirst().first.map(String.init) })
    }()

    /// Whether this Mac can actually produce `ext` from a file of the given category.
    static func canProduce(_ ext: String, from cat: Category) -> Bool {
        let e = ffmpegEncoders
        switch ext {
        case "webp": return e.contains("libwebp")
        case "avif": return e.contains("libaom-av1") || e.contains("libsvtav1")
        case "ogg": return e.contains("libvorbis") || e.contains("vorbis")
        case "opus": return e.contains("libopus") || e.contains("opus")
        case "webm": return e.contains("libvpx-vp9")
        case "mp4": return e.contains("libx264")
        case "mp3": return e.contains("libmp3lame")
        case "m4a": return e.contains("aac")
        case "wav", "flac", "aiff", "mov", "mkv": return !e.isEmpty
        case "gif" where cat == .video: return !e.isEmpty
        default:
            // Everything else is handled by system tools (sips, textutil, CoreText).
            return cat == .audio || cat == .video ? !e.isEmpty : true
        }
    }

    /// What each kind of document can really be converted to.
    static func documentTargets(from src: String) -> [String] {
        switch src {
        case "pdf": return ["txt"]
        case "epub": return ["txt", "html", "md", "pdf", "rtf", "docx"]
        default: return ["pdf", "txt", "rtf", "html", "docx", "md", "epub", "rtfd"].filter { $0 != src }
        }
    }

    /// Target formats offered for a source file (same format excluded, unavailable encoders hidden).
    static func targets(for url: URL) -> [String] {
        guard let cat = Category.of(url) else { return [] }
        let src = Category.normalized(url.pathExtension)
        if cat == .document { return documentTargets(from: src) }
        return cat.extensions.filter { $0 != src && canProduce($0, from: cat) }
    }

    /// Formats every file in the selection can be converted to, in the order offered for the first one.
    static func targets(for urls: [URL]) -> [String] {
        guard let first = urls.first else { return [] }
        var common = targets(for: first)
        for url in urls.dropFirst() {
            let other = Set(targets(for: url))
            common = common.filter { other.contains($0) }
        }
        return common
    }

    /// Output URL that never overwrites an existing file.
    static func outputURL(for source: URL, ext: String, in folder: URL?, suffix: String = "") -> URL {
        let dir = folder ?? source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent + suffix
        func make(_ name: String) -> URL {
            let u = dir.appendingPathComponent(name)
            return ext.isEmpty ? u : u.appendingPathExtension(ext)
        }
        var candidate = make(base)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = make("\(base) \(n)")
            n += 1
        }
        return candidate
    }

    static func convert(_ source: URL, to ext: String, outputFolder: URL?, quality: Quality, prefs: FormatPrefs? = nil,
                        progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        let outputs = try await OutputStore.transaction(source: source, folder: outputFolder) { stage in
            [try await convertStaged(source, to: ext, outputFolder: stage, quality: quality, prefs: prefs, progress: progress)]
        }
        return outputs[0]
    }

    private static func convertStaged(_ source: URL, to ext: String, outputFolder: URL?, quality: Quality, prefs: FormatPrefs?,
                                      progress: (@Sendable (Double) -> Void)?) async throws -> URL {
        let prefs = prefs ?? FormatPrefs(quality: quality)
        guard let cat = Category.of(source) else {
            throw ConversionError(message: "Unsupported format: .\(source.pathExtension)")
        }
        guard FileManager.default.isReadableFile(atPath: source.path) else {
            throw ConversionError(message: "File not found or unreadable: \(source.lastPathComponent)")
        }
        let out = outputURL(for: source, ext: ext, in: outputFolder)
        switch cat {
        case .image: try await convertImage(source, out, ext, prefs, progress)
        case .audio, .video: try await ffmpeg(source, out, ext, prefs.quality, progress: progress)
        case .document: try await convertDocument(source, out, ext)
        case .spreadsheet: try convertSheet(source, out, ext)
        }
        // Some tools (sips) exit 0 without writing anything: never report a phantom success.
        let size = ((try? FileManager.default.attributesOfItem(atPath: out.path))?[.size] as? Int) ?? 0
        guard size > 0 else {
            try? FileManager.default.removeItem(at: out)
            throw ConversionError(message: "Conversion failed: \(source.lastPathComponent) → .\(ext)")
        }
        return out
    }

    // MARK: Images

    private static func convertImage(_ src: URL, _ out: URL, _ ext: String, _ prefs: FormatPrefs, _ progress: (@Sendable (Double) -> Void)?) async throws {
        let srcExt = Category.normalized(src.pathExtension)
        let imageIOTargets = ImageOps.writableExts.union(["pdf"])
        if imageIOTargets.contains(ext), !["webp", "avif"].contains(srcExt) {
            let loaded = try ImageOps.load(src)
            var image = loaded.image
            if prefs.maxDimension > 0 { image = ImageOps.resize(image, .maxDimension(prefs.maxDimension, allowUpscale: false)) }
            if ext == "pdf" {
                try ImageOps.writePDF([image], to: out, pageSize: "fit", margin: 0)
            } else {
                if ["jpg", "bmp"].contains(ext) { image = ImageOps.flattenOnWhite(image) }
                try ImageOps.write(image, to: out, ext: ext, quality: prefs.quality.imageQuality, properties: prefs.preserveMetadata ? loaded.properties : nil)
            }
        } else {
            var extra: [String] = []
            if prefs.maxDimension > 0 {
                let m = prefs.maxDimension
                extra = ["-vf", "scale='if(gt(iw,ih),min(\(m),iw),-2)':'if(gt(iw,ih),-2,min(\(m),ih))'"]
            }
            try await ffmpeg(src, out, ext, prefs.quality, extra: extra, progress: progress)
        }
    }

    // MARK: Audio / video

    /// `raw` skips the per-format codec presets (used by tools that pass their own flags).
    static func ffmpeg(_ src: URL, _ out: URL, _ ext: String, _ q: Quality,
                       extra: [String] = [], raw: Bool = false, extraBeforeInput: Bool = false,
                       progress: (@Sendable (Double) -> Void)? = nil) async throws {
        var args = ["-y"]
        if extraBeforeInput { args += extra }
        args += ["-i", src.path]
        if !extraBeforeInput { args += extra }
        switch raw ? "" : ext {
        case "mp3": args += ["-vn", "-q:a", q.pick(best: "0", balanced: "2", strong: "6")]
        case "m4a": args += ["-vn", "-c:a", "aac", "-b:a", q.pick(best: "256k", balanced: "192k", strong: "96k")]
        case "opus": args += ["-vn", "-c:a", ffmpegEncoders.contains("libopus") ? "libopus" : "opus", "-strict", "-2"]
        case "ogg": args += ["-vn", "-c:a", ffmpegEncoders.contains("libvorbis") ? "libvorbis" : "vorbis", "-strict", "-2", "-ac", "2"]
        case "gif" where Category.of(src) == .video: args += ["-vf", "fps=12,scale=480:-1:flags=lanczos"]
        case "mp4": args += ["-c:v", "libx264", "-crf", q.pick(best: "18", balanced: "23", strong: "30"), "-c:a", "aac"]
        case "webm": args += ["-c:v", "libvpx-vp9", "-crf", q.pick(best: "24", balanced: "32", strong: "40"), "-b:v", "0"]
        case "avif": args += ffmpegEncoders.contains("libaom-av1") ? ["-c:v", "libaom-av1", "-still-picture", "1"] : ["-c:v", "libsvtav1"]
        case "webp": args += ["-quality", String(Int(q.imageQuality * 100))]
        default: break
        }
        args.append(out.path)
        try await runFFmpeg(args, duration: progress == nil ? nil : MediaInfo.duration(src), progress: progress)
    }

    // MARK: Documents

    private static func convertDocument(_ src: URL, _ out: URL, _ ext: String) async throws {
        let srcExt = Category.normalized(src.pathExtension)
        if srcExt == "pdf" {
            guard ext == "txt" else { throw ConversionError(message: "PDF can only be converted to TXT") }
            let text = try await MainActor.run { () -> String in
                guard let doc = CGPDFDocumentTextExtractor.text(from: src) else {
                    throw ConversionError(message: "Unable to read PDF")
                }
                return doc
            }
            try text.write(to: out, atomically: true, encoding: .utf8)
            return
        }
        if srcExt == "epub" {
            let text = try EPUBOps.readText(src)
            if ext == "txt" { try text.write(to: out, atomically: true, encoding: .utf8); return }
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
            try text.write(to: temp, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: temp) }
            try await convertDocument(temp, out, ext)
            return
        }
        if ext == "epub" {
            let text: String
            if srcExt == "txt" || srcExt == "md" { text = try String(contentsOf: src, encoding: .utf8) }
            else { text = Shell.capture("/usr/bin/textutil", ["-convert", "txt", "-stdout", src.path]) }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConversionError(message: "The document contains no text: \(src.lastPathComponent)") }
            try EPUBOps.write(text: text, title: src.deletingPathExtension().lastPathComponent, to: out)
            return
        }
        if ext == "rtfd" {
            var readable = src
            if srcExt == "md" {
                readable = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
                try String(contentsOf: src, encoding: .utf8).write(to: readable, atomically: true, encoding: .utf8)
            }
            defer { if readable != src { try? FileManager.default.removeItem(at: readable) } }
            try await run("/usr/bin/textutil", ["-convert", "rtfd", "-output", out.path, readable.path])
            return
        }
        if srcExt == "md" {
            // Markdown → via attributed string (inline markdown), then treat as rich text.
            let md = try String(contentsOf: src, encoding: .utf8)
            let attr = (try? NSAttributedString(markdown: md, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? NSAttributedString(string: md)
            try write(attr, to: out, ext: ext)
            return
        }
        if ext == "md" {
            try await run("/usr/bin/textutil", ["-convert", "txt", "-output", out.path, src.path])
            return
        }
        if ext == "pdf" {
            var readable = src
            if Category.normalized(src.pathExtension) != "md" {
                // textutil → RTF avoids the WebKit importer, which needs the main thread.
                readable = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".rtf")
                try await run("/usr/bin/textutil", ["-convert", "rtf", "-output", readable.path, src.path])
            }
            defer { if readable != src { try? FileManager.default.removeItem(at: readable) } }
            try write(try loadAttributed(readable), to: out, ext: "pdf")
            return
        }
        let tu = ["txt": "txt", "rtf": "rtf", "html": "html", "docx": "docx"]
        guard let fmt = tu[ext] else { throw ConversionError(message: "Unsupported conversion: \(srcExt) → \(ext)") }
        try await run("/usr/bin/textutil", ["-convert", fmt, "-output", out.path, src.path])
    }

    private static func loadAttributed(_ url: URL) throws -> NSAttributedString {
        if Category.normalized(url.pathExtension) == "md" {
            let s = try String(contentsOf: url, encoding: .utf8)
            return (try? NSAttributedString(markdown: s)) ?? NSAttributedString(string: s)
        }
        return try NSAttributedString(url: url, options: [:], documentAttributes: nil)
    }

    private static func write(_ attr: NSAttributedString, to out: URL, ext: String) throws {
        let range = NSRange(location: 0, length: attr.length)
        switch ext {
        case "pdf":
            try writePDF(attr, to: out)
        case "txt": try attr.string.write(to: out, atomically: true, encoding: .utf8)
        case "rtf": try attr.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]).write(to: out)
        case "html": try attr.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.html]).write(to: out)
        case "docx": try attr.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]).write(to: out)
        default: throw ConversionError(message: "Unsupported output format: \(ext)")
        }
    }

    /// Paginated A4 PDF through CoreText (safe off the main thread).
    private static func writePDF(_ source: NSAttributedString, to out: URL) throws {
        let text = NSMutableAttributedString(attributedString: source)
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if value == nil { text.addAttribute(.font, value: NSFont.systemFont(ofSize: 12), range: range) }
        }
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let ctx = CGContext(out as CFURL, mediaBox: &box, nil) else {
            throw ConversionError(message: "Unable to create PDF")
        }
        let setter = CTFramesetterCreateWithAttributedString(text)
        let area = box.insetBy(dx: 50, dy: 50)
        var location = 0
        repeat {
            ctx.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: location, length: 0), CGPath(rect: area, transform: nil), nil)
            CTFrameDraw(frame, ctx)
            ctx.endPDFPage()
            let visible = CTFrameGetVisibleStringRange(frame)
            if visible.length == 0 { break }
            location += visible.length
        } while location < text.length
        ctx.closePDF()
    }

    // MARK: Spreadsheets

    private static func convertSheet(_ src: URL, _ out: URL, _ ext: String) throws {
        try SheetIO.write(try SheetIO.read(src), to: out)
    }

    // MARK: Process helper

    /// Thread-safe byte buffer for process output.
    final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var partial = ""
        func append(_ d: Data) { lock.lock(); data.append(d.prefix(max(0, 2_000_000 - data.count))); lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
        /// Feeds `d` and returns the complete lines received so far.
        func lines(_ d: Data) -> [String] {
            lock.lock(); defer { lock.unlock() }
            partial += String(decoding: d, as: UTF8.self)
            var out = partial.components(separatedBy: "\n")
            partial = String(out.removeLast().suffix(4096))
            return out
        }
    }

    /// Uses the same bounded, cancellable process runner as probes and archive readers.
    static func run(_ exe: String, _ args: [String], duration: Double? = nil, progress: (@Sendable (Double) -> Void)? = nil,
                    timeout: TimeInterval = 3600) async throws {
        let lines = OutputBuffer()
        let result = try await ProcessRunner.run(exe, args, timeout: timeout) { data in
            guard let duration, duration > 0, let progress else { return }
            for line in lines.lines(data) {
                guard line.hasPrefix("out_time_us="), let us = Double(line.dropFirst(12)), us.isFinite else { continue }
                progress(min(max(us / 1_000_000 / duration, 0), 1))
            }
        }
        try Task.checkCancellation()
        guard result.status == 0 else {
            throw ConversionError(message: String(String(decoding: result.stderr, as: UTF8.self).suffix(400)))
        }
        progress?(1)
    }

    /// Runs ffmpeg quietly, with progress when `duration` is known.
    static func runFFmpeg(_ args: [String], duration: Double? = nil, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard let ff = ffmpegPath else { throw ConversionError(message: "FFmpeg is missing. Reinstall Mandarine from the latest DMG. For source builds, install FFmpeg separately.") }
        var full = ["-hide_banner", "-loglevel", "error", "-nostdin"]
        if progress != nil, (duration ?? 0) > 0 { full += ["-progress", "pipe:1", "-nostats"] }
        try await run(ff, full + args, duration: duration, progress: progress)
    }
}

import PDFKit
enum CGPDFDocumentTextExtractor {
    static func text(from url: URL) -> String? { PDFDocument(url: url)?.string }
}
