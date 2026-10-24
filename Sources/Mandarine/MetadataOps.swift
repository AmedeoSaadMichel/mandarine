import AppKit
import Foundation
import ImageIO
import PDFKit

/// Reads and edits embedded metadata (images, audio/video, PDF).
enum MetadataOps {
    struct Field: Identifiable { let key: String; let label: String; var id: String { key } }

    static func supports(_ url: URL) -> Bool {
        guard let cat = Category.of(url) else { return false }
        let ext = Category.normalized(url.pathExtension)
        switch cat {
        case .image: return Tools.imageExts.contains(ext)
        case .audio, .video: return Converter.ffmpegPath != nil
        case .document: return ext == "pdf"
        case .spreadsheet: return false
        }
    }

    static func fields(for url: URL) -> [Field] {
        switch Category.of(url) {
        case .image:
            return [Field(key: "title", label: "Title"), Field(key: "artist", label: "Author"),
                    Field(key: "copyright", label: "Copyright"), Field(key: "comment", label: "Comment")]
        case .audio, .video:
            return [Field(key: "title", label: "Title"), Field(key: "artist", label: "Artist"), Field(key: "album", label: "Album"),
                    Field(key: "date", label: "Year"), Field(key: "genre", label: "Genre"), Field(key: "comment", label: "Comment")]
        case .document:
            return [Field(key: "title", label: "Title"), Field(key: "author", label: "Author"),
                    Field(key: "subject", label: "Subject"), Field(key: "keywords", label: "Keywords")]
        default: return []
        }
    }

    // MARK: Read

    static func read(_ url: URL) -> [String: String] {
        switch Category.of(url) {
        case .image: return readImage(url)
        case .audio, .video: return readMedia(url)
        case .document: return readPDF(url)
        default: return [:]
        }
    }

    private static func readImage(_ url: URL) -> [String: String] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return [:] }
        let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        var r: [String: String] = [:]
        if let v = tiff[kCGImagePropertyTIFFImageDescription] as? String { r["title"] = v }
        if let v = tiff[kCGImagePropertyTIFFArtist] as? String { r["artist"] = v }
        if let v = tiff[kCGImagePropertyTIFFCopyright] as? String { r["copyright"] = v }
        if let v = exif[kCGImagePropertyExifUserComment] as? String { r["comment"] = v }
        return r
    }

    /// True when the image carries GPS coordinates.
    static func hasGPS(_ url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return false }
        return p[kCGImagePropertyGPSDictionary] != nil
    }

    private static func readMedia(_ url: URL) -> [String: String] {
        guard let ff = Converter.ffmpegPath else { return [:] }
        let out = Shell.capture(ff, ["-v", "error", "-i", url.path, "-f", "ffmetadata", "-"])
        var r: [String: String] = [:]
        for line in out.split(separator: "\n") where !line.hasPrefix(";") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            r[String(line[..<eq]).lowercased()] = String(line[line.index(after: eq)...])
        }
        return r
    }

    private static func readPDF(_ url: URL) -> [String: String] {
        guard let a = PDFDocument(url: url)?.documentAttributes else { return [:] }
        var r: [String: String] = [:]
        if let v = a[PDFDocumentAttribute.titleAttribute] as? String { r["title"] = v }
        if let v = a[PDFDocumentAttribute.authorAttribute] as? String { r["author"] = v }
        if let v = a[PDFDocumentAttribute.subjectAttribute] as? String { r["subject"] = v }
        if let v = a[PDFDocumentAttribute.keywordsAttribute] as? [String] { r["keywords"] = v.joined(separator: ", ") }
        else if let v = a[PDFDocumentAttribute.keywordsAttribute] as? String { r["keywords"] = v }
        return r
    }

    // MARK: Write

    /// Writes a copy with `fields` set (empty value removes the tag). `stripAll` removes everything;
    /// `stripLocation` removes only GPS data from images.
    static func write(_ src: URL, to out: URL, fields: [String: String], stripAll: Bool, stripLocation: Bool) async throws {
        guard supports(src) else { throw ConversionError(message: "Metadata cannot be edited for \(src.lastPathComponent)") }
        switch Category.of(src) {
        case .image: try writeImage(src, out, fields, stripAll, stripLocation)
        case .audio, .video: try await writeMedia(src, out, fields, stripAll)
        case .document: try writePDF(src, out, fields, stripAll)
        default: break
        }
    }

    private static func writeImage(_ src: URL, _ out: URL, _ fields: [String: String], _ stripAll: Bool, _ stripLocation: Bool) throws {
        let ext = Category.normalized(src.pathExtension)
        if stripAll { try Tools.stripImage(src, out, ext); return }
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil),
              let type = CGImageSourceGetType(source),
              let dest = CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil) else {
            throw ConversionError(message: "Unable to read image: \(src.lastPathComponent)")
        }
        let original = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        var tiff = original[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        var exif = original[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        var iptc = original[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        func put(_ dict: inout [CFString: Any], _ key: CFString, _ value: String?) {
            // kCFNull tells ImageIO to delete the tag; merely omitting it would keep the original value.
            if let v = value, !v.isEmpty { dict[key] = v } else if value != nil { dict[key] = kCFNull }
        }
        put(&tiff, kCGImagePropertyTIFFImageDescription, fields["title"])
        put(&iptc, kCGImagePropertyIPTCObjectName, fields["title"])
        put(&tiff, kCGImagePropertyTIFFArtist, fields["artist"])
        put(&tiff, kCGImagePropertyTIFFCopyright, fields["copyright"])
        put(&exif, kCGImagePropertyExifUserComment, fields["comment"])
        var props: [CFString: Any] = [kCGImagePropertyTIFFDictionary: tiff, kCGImagePropertyExifDictionary: exif]
        if !iptc.isEmpty { props[kCGImagePropertyIPTCDictionary] = iptc }
        if stripLocation { props[kCGImageMetadataShouldExcludeGPS] = true }
        CGImageDestinationAddImageFromSource(dest, source, 0, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConversionError(message: "Unable to write image") }
    }

    private static func writeMedia(_ src: URL, _ out: URL, _ fields: [String: String], _ stripAll: Bool) async throws {
        var extra: [String] = []
        if stripAll { extra += ["-map_metadata", "-1"] }
        else { for (k, v) in fields.sorted(by: { $0.key < $1.key }) { extra += ["-metadata", "\(k)=\(v)"] } }
        extra += ["-c", "copy"]
        try await Converter.ffmpeg(src, out, Category.normalized(src.pathExtension), .balanced, extra: extra, raw: true)
    }

    private static func writePDF(_ src: URL, _ out: URL, _ fields: [String: String], _ stripAll: Bool) throws {
        let doc = try Tools.openPDF(src)
        var attrs: [AnyHashable: Any] = [:]
        if !stripAll {
            attrs = doc.documentAttributes ?? [:]
            func put(_ key: PDFDocumentAttribute, _ name: String) {
                guard let v = fields[name] else { return }
                if v.isEmpty { attrs[key] = nil } else { attrs[key] = name == "keywords" ? v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } : v }
            }
            put(.titleAttribute, "title"); put(.authorAttribute, "author"); put(.subjectAttribute, "subject"); put(.keywordsAttribute, "keywords")
        } else {
            for key in [PDFDocumentAttribute.titleAttribute, .authorAttribute, .subjectAttribute, .keywordsAttribute, .creatorAttribute, .producerAttribute] {
                attrs[key] = ""
            }
        }
        doc.documentAttributes = attrs
        guard doc.write(to: out) else { throw ConversionError(message: "Unable to write PDF") }
    }
}

/// Small synchronous process helper.
enum Shell {
    static func capture(_ exe: String, _ args: [String]) -> String {
        guard let result = try? ProcessRunner.blocking(exe, args) else { return "" }
        return String(decoding: result.stdout, as: UTF8.self)
    }

    static func captureStderr(_ exe: String, _ args: [String]) -> String {
        guard let result = try? ProcessRunner.blocking(exe, args) else { return "" }
        return String(decoding: result.stderr, as: UTF8.self)
    }
}
