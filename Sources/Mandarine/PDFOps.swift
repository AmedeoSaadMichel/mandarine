import Foundation
import PDFKit

enum PDFOps {
    /// One page of the result: 0-based source page and the rotation to add (multiple of 90).
    struct PageSpec: Equatable { let index: Int; let rotation: Int }

    /// "3:90,1,2:180" → pages (1-based) with optional rotation.
    static func parsePageSpecs(_ text: String, pageCount: Int) throws -> [PageSpec] {
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { throw ToolError.invalid("The resulting PDF would have no pages.") }
        return try parts.map { part in
            let pieces = part.split(separator: ":").map { String($0) }
            guard (1...2).contains(pieces.count), let n = Int(pieces[0]), n >= 1, n <= pageCount else {
                throw ToolError.invalid("Invalid page: \(part) (the PDF has \(pageCount) pages).")
            }
            let rot = pieces.count == 2 ? Int(pieces[1]) : 0
            guard let rot, rot % 90 == 0 else { throw ToolError.invalid("Invalid rotation: \(part)") }
            return PageSpec(index: n - 1, rotation: ((rot % 360) + 360) % 360)
        }
    }

    static func encode(_ specs: [PageSpec]) -> String {
        specs.map { $0.rotation == 0 ? "\($0.index + 1)" : "\($0.index + 1):\($0.rotation)" }.joined(separator: ",")
    }

    /// Rebuilds the PDF with the given pages, order and rotations.
    static func organize(_ src: URL, _ out: URL, specs: [PageSpec]) throws {
        let doc = try Tools.openPDF(src)
        guard !specs.isEmpty else { throw ToolError.invalid("The resulting PDF would have no pages.") }
        let result = PDFDocument()
        for spec in specs {
            guard spec.index >= 0, spec.index < doc.pageCount, let page = doc.page(at: spec.index)?.copy() as? PDFPage else {
                throw ToolError.invalid("Page \(spec.index + 1) not found.")
            }
            page.rotation = (page.rotation + spec.rotation) % 360
            result.insert(page, at: result.pageCount)
        }
        guard result.write(to: out) else { throw ConversionError(message: "Unable to write PDF") }
    }

    static func uniqueFolder(in parent: URL, named base: String) -> URL {
        var dir = parent.appendingPathComponent(base)
        var n = 2
        while FileManager.default.fileExists(atPath: dir.path) { dir = parent.appendingPathComponent("\(base) \(n)"); n += 1 }
        return dir
    }

    /// Groups of pages written as separate PDFs inside a new folder. Returns the folder and files.
    static func splitGroups(_ src: URL, groups: [[Int]], folder: URL?, label: String = "parts") throws -> (folder: URL, files: [URL]) {
        let doc = try Tools.openPDF(src)
        guard !groups.isEmpty else { throw ToolError.invalid("No page groups to extract.") }
        let base = src.deletingPathExtension().lastPathComponent
        let dir = uniqueFolder(in: folder ?? src.deletingLastPathComponent(), named: "\(base) \(label)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let width = String(groups.count).count
        var files: [URL] = []
        for (i, group) in groups.enumerated() {
            let part = PDFDocument()
            for idx in group {
                guard idx >= 0, idx < doc.pageCount, let page = doc.page(at: idx)?.copy() as? PDFPage else { continue }
                part.insert(page, at: part.pageCount)
            }
            guard part.pageCount > 0 else { continue }
            let url = dir.appendingPathComponent("\(base) " + String(format: "%0\(width)d", i + 1) + ".pdf")
            guard part.write(to: url) else { throw ConversionError(message: "Unable to write part \(i + 1) failed") }
            files.append(url)
        }
        return (dir, files)
    }

    /// Consecutive chunks of `n` pages.
    static func chunks(pageCount: Int, every n: Int) throws -> [[Int]] {
        guard n >= 1 else { throw ToolError.invalid("Enter at least 1 page per part.") }
        return stride(from: 0, to: pageCount, by: n).map { Array($0..<min($0 + n, pageCount)) }
    }

    /// "1-3; 4-6, 9" → one group per `;`, each with its own ranges.
    static func parseGroups(_ text: String, pageCount: Int) throws -> [[Int]] {
        let parts = text.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { throw ToolError.invalid("Enter pages, for example 1-3; 4-6.") }
        return try parts.map { try Tools.parsePageRanges($0, pageCount: pageCount) }
    }
}
