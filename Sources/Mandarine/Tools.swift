import AppKit
import AVFoundation
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

struct ToolCancelled: Error {}

/// File tools offered by the Tools wheel. Every tool writes a new file next to the original.
enum Tools {
    enum Kind: String, CaseIterable { case compress, resize1024, resizeHalf, resize720, stripMetadata, trim, split, extractPages }

    static let imageExts: Set<String> = ["jpg", "png", "heic", "tiff"]
    static let compressibleAudio: Set<String> = ["mp3", "m4a", "ogg", "opus", "flac"]

    // MARK: Availability

    static func supports(_ kind: Kind, _ url: URL) -> Bool {
        guard let cat = Category.of(url) else { return false }
        let ext = Category.normalized(url.pathExtension)
        let ffmpeg = Converter.ffmpegPath != nil
        switch kind {
        case .compress:
            switch cat {
            case .image: return imageExts.contains(ext) && (ext != "png" || ffmpeg)
            case .audio: return ffmpeg && compressibleAudio.contains(ext)
            case .video: return ffmpeg
            case .document: return ext == "pdf"
            default: return false
            }
        case .split, .extractPages: return ext == "pdf"
        case .resize1024, .resizeHalf: return cat == .image && imageExts.contains(ext)
        case .resize720: return cat == .video && ffmpeg
        case .stripMetadata:
            switch cat {
            case .image: return imageExts.contains(ext)
            case .audio, .video: return ffmpeg
            default: return false
            }
        case .trim: return (cat == .audio || cat == .video) && ffmpeg
        }
    }

    static func available(for url: URL) -> [Kind] { Kind.allCases.filter { supports($0, url) } }

    static func title(_ kind: Kind) -> String {
        switch kind {
        case .compress: return "Compress"
        case .resize1024: return "Resize 1024"
        case .resizeHalf: return "Resize 50%"
        case .resize720: return "Resize 720p"
        case .stripMetadata: return "No metadata"
        case .trim: return "Trim"
        case .split: return "Split pages"
        case .extractPages: return "Extract pages"
        }
    }

    /// Runs a tool; `trim` is the (start, end) range, only used by `.trim`.
    static func run(_ kind: Kind, on url: URL, folder: URL?, trim: (start: Double, end: Double)? = nil, pages: String? = nil, quality: Quality = .strong) async throws -> URL {
        let outputs = try await OutputStore.transaction(source: url, folder: folder) { stage in
            [try await runStaged(kind, on: url, folder: stage, trim: trim, pages: pages, quality: quality)]
        }
        return outputs[0]
    }

    private static func runStaged(_ kind: Kind, on url: URL, folder: URL?, trim: (start: Double, end: Double)?, pages: String?, quality: Quality) async throws -> URL {
        guard supports(kind, url) else {
            throw ConversionError(message: "\(title(kind)) is not available for \(url.lastPathComponent)")
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw ConversionError(message: "File not found or unreadable: \(url.lastPathComponent)")
        }
        let ext = Category.normalized(url.pathExtension)
        let out: URL
        switch kind {
        case .compress:
            out = Converter.outputURL(for: url, ext: url.pathExtension, in: folder, suffix: " compressed")
            try await compress(url, out, ext, quality)
        case .resize1024:
            out = Converter.outputURL(for: url, ext: url.pathExtension, in: folder, suffix: " 1024px")
            try await Converter.run("/usr/bin/sips", ["-Z", "1024", url.path, "--out", out.path])
        case .resizeHalf:
            out = Converter.outputURL(for: url, ext: url.pathExtension, in: folder, suffix: " 50%")
            let (w, h) = try pixelSize(url)
            try await Converter.run("/usr/bin/sips", ["-z", "\(max(h / 2, 1))", "\(max(w / 2, 1))", url.path, "--out", out.path])
        case .resize720:
            out = Converter.outputURL(for: url, ext: url.pathExtension, in: folder, suffix: " 720p")
            try await Converter.ffmpeg(url, out, ext, .balanced, extra: ["-vf", "scale=-2:720"])
        case .stripMetadata:
            out = Converter.outputURL(for: url, ext: url.pathExtension, in: folder, suffix: " clean")
            if Category.of(url) == .image { try stripImage(url, out, ext) }
            else { try await Converter.ffmpeg(url, out, ext, .balanced, extra: ["-map_metadata", "-1", "-c", "copy"], raw: true) }
        case .split:
            return try splitPDF(url, folder: folder).folder
        case .extractPages:
            guard let spec = pages else { throw ToolCancelled() }
            out = Converter.outputURL(for: url, ext: "pdf", in: folder, suffix: " pages")
            try extractPDF(url, out, spec)
        case .trim:
            guard let t = trim else { throw ToolCancelled() }
            guard t.start >= 0, t.end > t.start else {
                throw ConversionError(message: "Invalid range: the end must be after the start.")
            }
            let total = AVURLAsset(url: url).duration.seconds
            if total.isFinite, total > 0, t.start >= total {
                throw ConversionError(message: "The start (\(formatTime(t.start))) is beyond the end of the file (\(formatTime(total))).")
            }
            out = Converter.outputURL(for: url, ext: url.pathExtension, in: folder, suffix: " trimmed")
            try await Converter.ffmpeg(url, out, ext, .balanced,
                                       extra: ["-ss", String(t.start), "-to", String(t.end)], raw: true, extraBeforeInput: true)
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: out.path))?[.size] as? Int) ?? 0
        var empty = size == 0
        if kind == .trim {
            let d = AVURLAsset(url: out).duration.seconds
            if d.isFinite, d < 0.05 { empty = true }
        }
        guard !empty else {
            try? FileManager.default.removeItem(at: out)
            throw ConversionError(message: "\(title(kind)) failed for \(url.lastPathComponent)")
        }
        return out
    }

    // MARK: Compress

    private static func compress(_ src: URL, _ out: URL, _ ext: String, _ quality: Quality) async throws {
        let q = quality == .strong ? "50" : "75"
        switch ext {
        case "jpg", "heic":
            let fmt = ext == "jpg" ? "jpeg" : "heic"
            try await Converter.run("/usr/bin/sips", ["-s", "format", fmt, "-s", "formatOptions", q, src.path, "--out", out.path])
        case "tiff":
            try await Converter.run("/usr/bin/sips", ["-s", "format", "tiff", "-s", "formatOptions", "lzw", src.path, "--out", out.path])
        case "png":
            try await Converter.ffmpeg(src, out, ext, .balanced, extra: ["-c:v", "png", "-compression_level", "9", "-pred", "mixed"], raw: true)
        case "pdf":
            try compressPDF(src, out)
        default:
            // Audio and video: re-encode with the "strong" preset.
            try await Converter.ffmpeg(src, out, ext, quality)
        }
    }

    // MARK: PDF

    static func openPDF(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw ConversionError(message: "Unable to read PDF: \(url.lastPathComponent)") }
        guard !doc.isLocked else { throw ConversionError(message: "Password-protected PDF: \(url.lastPathComponent)") }
        guard doc.pageCount > 0 else { throw ConversionError(message: "PDF has no pages: \(url.lastPathComponent)") }
        return doc
    }

    /// Downsamples embedded images; text stays selectable. Fails when nothing can be saved.
    static func compressPDF(_ src: URL, _ out: URL) throws {
        let doc = try openPDF(src)
        guard #available(macOS 13.4, *) else {
            throw ConversionError(message: "PDF compression requires macOS 13.4 or later.")
        }
        guard doc.write(to: out, withOptions: [PDFDocumentWriteOption.optimizeImagesForScreenOption: true]) else {
            throw ConversionError(message: "PDF compression failed: \(src.lastPathComponent)")
        }
        let before = ((try? FileManager.default.attributesOfItem(atPath: src.path))?[.size] as? Int) ?? 0
        let after = ((try? FileManager.default.attributesOfItem(atPath: out.path))?[.size] as? Int) ?? 0
        guard after > 0, after < before else {
            try? FileManager.default.removeItem(at: out)
            throw ConversionError(message: "\(src.lastPathComponent) is already optimized and cannot be reduced further.")
        }
    }

    /// Merges PDFs in the given order into "<first> merged.pdf".
    static func mergePDFs(_ urls: [URL], folder: URL?) throws -> URL {
        guard urls.count >= 2 else { throw ConversionError(message: "Select at least two PDFs to merge.") }
        let merged = PDFDocument()
        for url in urls {
            let doc = try openPDF(url)
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
                merged.insert(page, at: merged.pageCount)
            }
        }
        let out = Converter.outputURL(for: urls[0], ext: "pdf", in: folder, suffix: " merged")
        guard merged.write(to: out) else { throw ConversionError(message: "Unable to write the merged PDF") }
        return out
    }

    /// One PDF per page, inside a new folder "<name> pages".
    static func splitPDF(_ src: URL, folder: URL?) throws -> (folder: URL, files: [URL]) {
        let doc = try openPDF(src)
        let parent = folder ?? src.deletingLastPathComponent()
        let base = src.deletingPathExtension().lastPathComponent
        var dir = parent.appendingPathComponent("\(base) pages")
        var n = 2
        while FileManager.default.fileExists(atPath: dir.path) { dir = parent.appendingPathComponent("\(base) pages \(n)"); n += 1 }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let width = String(doc.pageCount).count
        var files: [URL] = []
        for i in 0..<doc.pageCount {
            let single = PDFDocument()
            guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
            single.insert(page, at: 0)
            let name = "\(base) " + String(format: "%0\(width)d", i + 1) + ".pdf"
            let url = dir.appendingPathComponent(name)
            guard single.write(to: url) else { throw ConversionError(message: "Unable to write page \(i + 1) failed") }
            files.append(url)
        }
        return (dir, files)
    }

    static func extractPDF(_ src: URL, _ out: URL, _ spec: String) throws {
        let doc = try openPDF(src)
        let indexes = try parsePageRanges(spec, pageCount: doc.pageCount)
        let result = PDFDocument()
        for i in indexes {
            guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
            result.insert(page, at: result.pageCount)
        }
        guard result.write(to: out) else { throw ConversionError(message: "Unable to write the extracted PDF") }
    }

    /// "1-3,5" → [0, 1, 2, 4]. Pages are 1-based; an order of "3-1" is rejected.
    static func parsePageRanges(_ text: String, pageCount: Int) throws -> [Int] {
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { throw ConversionError(message: "Enter pages, for example 1-3,5") }
        var result: [Int] = []
        for part in parts {
            let ends = part.split(separator: "-", omittingEmptySubsequences: false).map { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard (1...2).contains(ends.count), !ends.contains(where: { $0 == nil }) else {
                throw ConversionError(message: "Invalid range: \(part)")
            }
            let a = ends[0]!, b = ends.count == 2 ? ends[1]! : ends[0]!
            guard a >= 1, b >= a, b <= pageCount else {
                throw ConversionError(message: "Pages out of range: \(part) (the PDF has \(pageCount) pages)")
            }
            result += Array((a - 1)...(b - 1))
        }
        return result
    }

    @MainActor
    static func askPageRange(for url: URL) -> String? {
        let pages = PDFDocument(url: url)?.pageCount ?? 0
        let field = NSTextField(string: pages > 0 ? "1-\(pages)" : "")
        field.frame.size = NSSize(width: 220, height: 22)
        let alert = NSAlert()
        alert.messageText = "Extract pages from \(url.lastPathComponent)"
        alert.informativeText = "The PDF has \(pages) pages. Example: 1-3,5"
        alert.accessoryView = field
        alert.addButton(withTitle: "Estrai")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    // MARK: Metadata

    /// Re-encodes the pixels only, so EXIF, GPS and other tags are dropped. Orientation is baked in.
    static func stripImage(_ src: URL, _ out: URL, _ ext: String) throws {
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw ConversionError(message: "Unable to read image: \(src.lastPathComponent)")
        }
        let w = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0, h = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h, 1),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else {
            throw ConversionError(message: "Unable to read pixels from \(src.lastPathComponent)")
        }
        let types: [String: UTType] = ["jpg": .jpeg, "png": .png, "heic": .heic, "tiff": .tiff]
        guard let type = types[ext], let dest = CGImageDestinationCreateWithURL(out as CFURL, type.identifier as CFString, 1, nil) else {
            throw ConversionError(message: "Cannot remove metadata from this format: .\(ext)")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw ConversionError(message: "Unable to write image") }
    }

    static func pixelSize(_ url: URL) throws -> (Int, Int) {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else {
            throw ConversionError(message: "Unable to read dimensions: \(url.lastPathComponent)")
        }
        return (w, h)
    }

    // MARK: Trim input

    /// Parses "90", "1:30", "0:01:30.5" into seconds.
    static func parseTime(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard let v = Double(part.replacingOccurrences(of: ",", with: ".")), v >= 0 else { return nil }
            total = total * 60 + v
        }
        return total
    }

    /// Asks the user for a start/end range; nil when cancelled.
    @MainActor
    static func askTrimRange(for url: URL) -> (start: Double, end: Double)? {
        let asset = AVURLAsset(url: url)
        let duration = asset.duration.seconds
        let start = NSTextField(string: "0:00")
        let end = NSTextField(string: duration.isFinite && duration > 0 ? formatTime(duration) : "")
        for f in [start, end] { f.frame.size = NSSize(width: 120, height: 22) }
        let grid = NSGridView(views: [[NSTextField(labelWithString: "Start"), start], [NSTextField(labelWithString: "End"), end]])
        grid.frame = NSRect(x: 0, y: 0, width: 220, height: 56)
        let alert = NSAlert()
        alert.messageText = "Trim \(url.lastPathComponent)"
        alert.informativeText = "Use seconds (90) or minutes:seconds (1:30)."
        alert.accessoryView = grid
        alert.addButton(withTitle: "Trim")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        guard let s = parseTime(start.stringValue), let e = parseTime(end.stringValue) else { return (-1, -1) }
        return (s, e)
    }

    static func formatTime(_ seconds: Double) -> String {
        let t = Int(seconds.rounded())
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}
