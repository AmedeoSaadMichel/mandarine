import Foundation

/// Minimal HTML → plain text, enough for EPUB chapters.
enum HTMLText {
    static func convert(_ html: String) -> String {
        var s = html
        s = s.replacingOccurrences(of: #"(?is)<(script|style|head)\b.*?</\1>"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)</(p|div|h[1-6]|li|tr|blockquote|section|article)>"#, with: "\n\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        s = decodeEntities(s)
        s = s.replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ s: String) -> String {
        var out = s
        let named = ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&#39;": "'", "&rsquo;": "’", "&lsquo;": "‘", "&hellip;": "…", "&mdash;": "—", "&ndash;": "–"]
        for (k, v) in named { out = out.replacingOccurrences(of: k, with: v) }
        // Numeric references: &#233; and &#xE9;
        let regex = try? NSRegularExpression(pattern: #"&#(x[0-9A-Fa-f]+|[0-9]+);"#)
        let ns = out as NSString
        var result = "", last = 0
        for m in regex?.matches(in: out, range: NSRange(location: 0, length: ns.length)) ?? [] {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let body = ns.substring(with: m.range(at: 1))
            let code = body.hasPrefix("x") ? UInt32(body.dropFirst(), radix: 16) : UInt32(body)
            if let code, let scalar = UnicodeScalar(code) { result.unicodeScalars.append(scalar) }
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }
}

enum EPUBOps {
    // MARK: Read

    /// Plain text of the whole book, chapters in reading order.
    static func readText(_ url: URL) throws -> String {
        guard let container = Archive.read(url, "META-INF/container.xml") else { throw ConversionError(message: "Invalid EPUB: \(url.lastPathComponent)") }
        var opfPath: String?
        let c = XMLWalker()
        c.onStart = { name, attrs in if name == "rootfile", opfPath == nil { opfPath = attrs["full-path"] } }
        try XMLWalker.parse(container, walker: c)
        guard let opfPath, let opf = Archive.read(url, opfPath) else { throw ConversionError(message: "EPUB has no OPF package") }

        var manifest: [String: String] = [:]
        var spine: [String] = []
        let o = XMLWalker()
        o.onStart = { name, attrs in
            if name == "item", let id = attrs["id"], let href = attrs["href"] { manifest[id] = href }
            if name == "itemref", let ref = attrs["idref"] { spine.append(ref) }
        }
        try XMLWalker.parse(opf, walker: o)

        let base = (opfPath as NSString).deletingLastPathComponent
        var chapters: [String] = []
        var totalBytes = 0
        for id in spine {
            guard let href = manifest[id] else { continue }
            let decoded = href.removingPercentEncoding ?? href
            let path = base.isEmpty ? decoded : base + "/" + decoded
            guard let data = Archive.read(url, path) else { throw ConversionError(message: "EPUB chapter is missing or too large.") }
            totalBytes += data.count
            guard totalBytes <= SheetIO.maxInputBytes else { throw ConversionError(message: "EPUB text is too large (32 MB limit).") }
            let text = HTMLText.convert(String(decoding: data, as: UTF8.self))
            if !text.isEmpty { chapters.append(text) }
        }
        guard !chapters.isEmpty else { throw ConversionError(message: "No text found in \(url.lastPathComponent)") }
        return chapters.joined(separator: "\n\n")
    }

    // MARK: Write

    /// A one-chapter EPUB 3: paragraphs are separated by blank lines.
    static func write(text: String, title: String, to url: URL) throws {
        let esc = SheetIO.xmlEscape
        let paragraphs = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let body = paragraphs.map { "<p>" + esc($0).replacingOccurrences(of: "\n", with: "<br/>") + "</p>" }.joined(separator: "\n")
        let xml = #"<?xml version="1.0" encoding="UTF-8"?>"#
        let chapter = xml + "\n" + #"<html xmlns="http://www.w3.org/1999/xhtml"><head><meta charset="utf-8"/><title>"# + esc(title) + "</title></head><body><h1>" + esc(title) + "</h1>\n" + body + "</body></html>"
        let nav = xml + "\n" + #"<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><meta charset="utf-8"/><title>Indice</title></head><body><nav epub:type="toc"><ol><li><a href="chapter.xhtml">"# + esc(title) + "</a></li></ol></nav></body></html>"
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        let opf = xml + "\n" + #"<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">urn:uuid:"# + UUID().uuidString + "</dc:identifier><dc:title>" + esc(title) + "</dc:title><dc:language>it</dc:language><meta property=\"dcterms:modified\">" + stamp + #"</meta></metadata><manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="chapter"/></spine></package>"#
        let container = xml + "\n" + #"<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>"#
        try Archive.write([("mimetype", Data("application/epub+zip".utf8)), ("META-INF/container.xml", Data(container.utf8)),
                           ("OEBPS/content.opf", Data(opf.utf8)), ("OEBPS/nav.xhtml", Data(nav.utf8)), ("OEBPS/chapter.xhtml", Data(chapter.utf8))],
                          first: ["mimetype"], to: url)
    }
}
