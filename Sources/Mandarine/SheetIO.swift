import Foundation

/// Reads and writes spreadsheets as plain rows of text: CSV, TSV, XLSX and ODS (first sheet only).
enum SheetIO {
    static let maxRows = 100_000
    static let maxColumns = 16_384
    static let maxCells = 1_000_000
    static let maxInputBytes = 32 * 1024 * 1024

    static func validateSize(rows: Int, columns: Int) throws {
        guard rows >= 0, columns >= 0, rows <= maxRows, columns <= maxColumns,
              columns == 0 || rows <= maxCells / columns else {
            throw ConversionError(message: "Spreadsheet too large: maximum 100,000 rows, 16,384 columns and 1,000,000 cells. No data was converted.")
        }
    }

    static let formats: Set<String> = ["csv", "tsv", "xlsx", "ods"]

    static func read(_ url: URL) throws -> [[String]] {
        switch Category.normalized(url.pathExtension) {
        case "csv": return try checkedDelimited(text(url), ",")
        case "tsv": return try checkedDelimited(text(url), "\t")
        case "xlsx": return try XLSX.read(url)
        case "ods": return try ODS.read(url)
        default: throw ConversionError(message: "Unsupported spreadsheet: .\(url.pathExtension)")
        }
    }

    private static func checkedDelimited(_ text: String, _ separator: Character) throws -> [[String]] {
        let rows = try parse(text, separator, bounded: true)
        try validateSize(rows: rows.count, columns: rows.map(\.count).max() ?? 0)
        return rows
    }

    static func write(_ rows: [[String]], to url: URL) throws {
        switch Category.normalized(url.pathExtension) {
        case "csv": try serialize(rows, ",").write(to: url, atomically: true, encoding: .utf8)
        case "tsv": try serialize(rows, "\t").write(to: url, atomically: true, encoding: .utf8)
        case "xlsx": try XLSX.write(rows, to: url)
        case "ods": try ODS.write(rows, to: url)
        default: throw ConversionError(message: "Unsupported output format: .\(url.pathExtension)")
        }
    }

    private static func text(_ url: URL) throws -> String {
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= maxInputBytes else {
            throw ConversionError(message: "Text spreadsheet is too large (32 MB limit).")
        }
        let data = try Data(contentsOf: url)
        // UTF-8 (with or without BOM), falling back to Windows-1252 as spreadsheet exports often use.
        if let s = String(data: data, encoding: .utf8) { return s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s }
        if let s = String(data: data, encoding: .windowsCP1252) { return s }
        throw ConversionError(message: "Unknown text encoding: \(url.lastPathComponent)")
    }

    // MARK: Delimited text

    static func serialize(_ rows: [[String]], _ sep: Character) -> String {
        rows.map { row in
            row.map { cell in
                cell.contains(sep) || cell.contains("\"") || cell.contains("\n") || cell.contains("\r")
                    ? "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : cell
            }.joined(separator: String(sep))
        }.joined(separator: "\n")
    }

    static func parseDelimited(_ text: String, _ sep: Character) -> [[String]] {
        // Unbounded convenience for trusted, small strings; file imports use the checked parser.
        (try? parse(text, sep, bounded: false)) ?? []
    }

    private static func parse(_ text: String, _ sep: Character, bounded: Bool) throws -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], cell = "", quoted = false
        var it = text.makeIterator()
        var pending: Character?
        while let c = pending ?? it.next() {
            pending = nil
            if quoted {
                if c == "\"" {
                    if let n = it.next() {
                        if n == "\"" { cell.append("\"") } else { quoted = false; pending = n }
                    } else { quoted = false }
                } else { cell.append(c) }
            } else if c == "\"" { quoted = true }
            else if c == sep {
                if bounded { try validateSize(rows: rows.count + 1, columns: row.count + 2) }
                row.append(cell); cell = ""
            }
            else if c == "\n" || c == "\r\n" {
                if bounded { try validateSize(rows: rows.count + 1, columns: row.count + 1) }
                row.append(cell); rows.append(row); row = []; cell = ""
            }
            else { cell.append(c) }
        }
        if !cell.isEmpty || !row.isEmpty {
            if bounded { try validateSize(rows: rows.count + 1, columns: row.count + 1) }
            row.append(cell); rows.append(row)
        }
        return rows
    }

    // MARK: Shared helpers

    /// "12", "-3.5", "0.25" are numbers; "007", "1e5", "+1" and "" stay text.
    static func isPlainNumber(_ s: String) -> Bool {
        s.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?$"#, options: .regularExpression) != nil
    }

    static func xmlEscape(_ s: String) -> String {
        var out = ""
        for ch in s.unicodeScalars {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\u{9}", "\u{A}", "\u{D}": out.unicodeScalars.append(ch)
            default:
                // XML 1.0 forbids most control characters.
                if ch.value >= 0x20 && !(0xD800...0xDFFF).contains(ch.value) { out.unicodeScalars.append(ch) }
            }
        }
        return out
    }

    /// 0 → "A", 25 → "Z", 26 → "AA".
    static func columnName(_ index: Int) -> String {
        var n = index, s = ""
        repeat { s = String(UnicodeScalar(UInt8(65 + n % 26))) + s; n = n / 26 - 1 } while n >= 0
        return s
    }

    /// "AB12" → (row 11, column 27).
    static func position(of ref: String) -> (row: Int, col: Int)? {
        let letters = ref.prefix { $0.isASCII && $0.isLetter }
        let digits = ref.dropFirst(letters.count)
        guard !letters.isEmpty, letters.count <= 3, !digits.isEmpty,
              digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let r = Int(digits), (1...1_048_576).contains(r) else { return nil }
        var col = 0
        for ch in letters.uppercased().unicodeScalars { col = col * 26 + Int(ch.value) - 64 }
        guard (1...maxColumns).contains(col) else { return nil }
        return (r - 1, col - 1)
    }

    static func dense(_ cells: [Int: [Int: String]]) throws -> [[String]] {
        guard let lastRow = cells.keys.max() else { return [] }
        let width = (cells.values.flatMap { $0.keys }.max() ?? -1) + 1
        guard cells.keys.allSatisfy({ $0 >= 0 }), cells.values.allSatisfy({ $0.keys.allSatisfy { $0 >= 0 } }) else {
            throw ConversionError(message: "Invalid spreadsheet coordinates.")
        }
        try validateSize(rows: lastRow + 1, columns: width)
        return (0...lastRow).map { r in (0..<width).map { cells[r]?[$0] ?? "" } }
    }
}

// MARK: - Archives

enum Archive {
    static func entries(_ zip: URL) -> [String] {
        Shell.capture("/usr/bin/unzip", ["-Z1", zip.path]).split(separator: "\n").map(String.init)
    }

    /// One file of the archive; nil when missing.
    static func read(_ zip: URL, _ path: String) -> Data? {
        let literal = path.reduce(into: "") { out, ch in if "[]*?\\".contains(ch) { out.append("\\") }; out.append(ch) }
        guard let result = try? ProcessRunner.blocking("/usr/bin/unzip", ["-p", zip.path, literal],
                                                      outputLimit: SheetIO.maxInputBytes), result.status == 0 else { return nil }
        return result.stdout
    }

    /// Builds a zip from `files` (relative path → data). `first` entries go in first and uncompressed (EPUB/ODS "mimetype").
    static func write(_ files: [(String, Data)], first: [String] = [], to out: URL) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mandarine-zip-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (path, data) in files {
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let packed = dir.appendingPathComponent(".packed-" + UUID().uuidString + ".zip")
        func zip(_ args: [String]) throws {
            let result = try ProcessRunner.blocking("/usr/bin/zip", args, directory: dir)
            guard result.status == 0 else { throw ConversionError(message: "Unable to create the archive") }
        }
        if !first.isEmpty { try zip(["-X", "-0", packed.path] + first) }
        let rest = files.map(\.0).filter { !first.contains($0) }
        if !rest.isEmpty { try zip(["-X", packed.path] + rest) }
        // copyItem refuses to replace an existing destination, including symlinks.
        try FileManager.default.copyItem(at: packed, to: out)
    }
}

// MARK: - XML reading helper

/// Collects text and attributes with a small handler per element.
final class XMLWalker: NSObject, XMLParserDelegate {
    private(set) var error: Error?
    func fail(_ message: String) { if error == nil { error = ConversionError(message: message) } }
    var onStart: ((String, [String: String]) -> Void)?
    var onEnd: ((String) -> Void)?
    var onText: ((String) -> Void)?

    static func parse(_ data: Data, walker: XMLWalker) throws {
        let parser = XMLParser(data: data)
        parser.delegate = walker
        guard data.count <= SheetIO.maxInputBytes else { throw ConversionError(message: "XML document is too large (32 MB limit).") }
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        let parsed = parser.parse()
        if let error = walker.error { throw error }
        guard parsed else { throw ConversionError(message: "Invalid XML file") }
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) { if error == nil { onStart?(name, attributes) }; if error != nil { parser.abortParsing() } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { if error == nil { onEnd?(name) }; if error != nil { parser.abortParsing() } }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if error == nil { onText?(string) }; if error != nil { parser.abortParsing() } }
}

// MARK: - XLSX

enum XLSX {
    static func read(_ url: URL) throws -> [[String]] {
        let names = Archive.entries(url)
        guard names.contains("xl/workbook.xml") else { throw ConversionError(message: "Invalid XLSX file: \(url.lastPathComponent)") }
        var shared: [String] = []
        if let data = Archive.read(url, "xl/sharedStrings.xml") { shared = try sharedStrings(data) }
        let sheet = names.contains("xl/worksheets/sheet1.xml") ? "xl/worksheets/sheet1.xml"
            : names.filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }.sorted().first
        guard let sheet, let data = Archive.read(url, sheet) else { throw ConversionError(message: "No worksheet in \(url.lastPathComponent)") }

        var cells: [Int: [Int: String]] = [:]
        var ref = "", type = "", value = "", inline = ""
        var inV = false, inT = false, inIS = false, nextRow = 0, nextCol = 0
        let w = XMLWalker()
        w.onStart = { name, attrs in
            switch name {
            case "row":
                nextCol = 0
                if let raw = attrs["r"] {
                    guard let r = Int(raw), (1...SheetIO.maxRows).contains(r) else { w.fail("XLSX row index is invalid or too large."); return }
                    nextRow = r - 1
                }
            case "c": ref = attrs["r"] ?? ""; type = attrs["t"] ?? ""; value = ""; inline = ""
            case "v": inV = true
            case "is": inIS = true
            case "t": if inIS { inT = true }
            default: break
            }
        }
        w.onText = { s in if inV { value += s } else if inT { inline += s } }
        w.onEnd = { name in
            switch name {
            case "v": inV = false
            case "t": inT = false
            case "is": inIS = false
            case "c":
                var text: String
                switch type {
                case "s":
                    guard let index = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)), shared.indices.contains(index) else {
                        w.fail("Invalid XLSX sharedStrings index."); return
                    }
                    text = shared[index]
                case "inlineStr": text = inline
                case "b": text = value == "1" ? "TRUE" : "FALSE"
                default: text = value
                }
                guard ref.isEmpty || SheetIO.position(of: ref) != nil else { w.fail("Invalid XLSX coordinate."); return }
                let pos = SheetIO.position(of: ref) ?? (nextRow, nextCol)
                guard pos.row >= 0, pos.row < SheetIO.maxRows, pos.col >= 0, pos.col < SheetIO.maxColumns else {
                    w.fail("XLSX coordinates exceed converter limits."); return
                }
                if !text.isEmpty { cells[pos.row, default: [:]][pos.col] = text }
                nextCol = pos.col + 1
            case "row": nextRow += 1
            default: break
            }
        }
        try XMLWalker.parse(data, walker: w)
        return try SheetIO.dense(cells)
    }

    private static func sharedStrings(_ data: Data) throws -> [String] {
        var out: [String] = [], current = ""
        var inT = false, skip = 0
        let w = XMLWalker()
        w.onStart = { name, _ in
            if name == "si" { current = "" }
            if name == "t" { inT = true }
            if name == "rPh" { skip += 1 }
        }
        w.onText = { s in if inT && skip == 0 { current += s } }
        w.onEnd = { name in
            if name == "t" { inT = false }
            if name == "rPh" { skip -= 1 }
            if name == "si" { out.append(current) }
        }
        try XMLWalker.parse(data, walker: w)
        return out
    }

    static func write(_ rows: [[String]], to url: URL) throws {
        var sheet = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
        sheet += #"<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>"#
        for (r, row) in rows.enumerated() {
            sheet += "<row r=\"\(r + 1)\">"
            for (c, cell) in row.enumerated() where !cell.isEmpty {
                let ref = SheetIO.columnName(c) + String(r + 1)
                if SheetIO.isPlainNumber(cell) { sheet += "<c r=\"\(ref)\"><v>\(cell)</v></c>" }
                else { sheet += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(SheetIO.xmlEscape(cell))</t></is></c>" }
            }
            sheet += "</row>"
        }
        sheet += "</sheetData></worksheet>"
        let header = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
        let files: [(String, Data)] = [
            ("[Content_Types].xml", Data((header + #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>"#).utf8)),
            ("_rels/.rels", Data((header + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>"#).utf8)),
            ("xl/workbook.xml", Data((header + #"<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Foglio1" sheetId="1" r:id="rId1"/></sheets></workbook>"#).utf8)),
            ("xl/_rels/workbook.xml.rels", Data((header + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>"#).utf8)),
            ("xl/worksheets/sheet1.xml", Data(sheet.utf8)),
        ]
        try Archive.write(files, to: url)
    }
}

// MARK: - ODS

enum ODS {
    static func read(_ url: URL) throws -> [[String]] {
        guard let data = Archive.read(url, "content.xml") else { throw ConversionError(message: "Invalid ODS file: \(url.lastPathComponent)") }
        var cells: [Int: [Int: String]] = [:]
        var row: [Int: String] = [:]
        var rowIndex = 0, columnIndex = 0
        var cellText = "", cellValue: String?, cellType = ""
        var cellRepeat = 1, rowRepeat = 1
        var tableDepth = 0, firstTableDone = false, inCell = false, paragraphs = 0
        let w = XMLWalker()
        w.onStart = { name, attrs in
            switch name {
            case "table:table": tableDepth += 1
            case "table:table-row" where tableDepth == 1 && !firstTableDone:
                row = [:]; columnIndex = 0
                guard let count = Int(attrs["table:number-rows-repeated"] ?? "1"), count > 0, count <= 1_048_576,
                      rowIndex <= 1_048_576 - count else { w.fail("Invalid ODS row repetition."); return }
                rowRepeat = count
            case "table:table-cell", "table:covered-table-cell":
                guard tableDepth == 1, !firstTableDone else { return }
                inCell = true; cellText = ""; paragraphs = 0
                guard let count = Int(attrs["table:number-columns-repeated"] ?? "1"), count > 0,
                      count <= SheetIO.maxColumns, columnIndex <= SheetIO.maxColumns - count else {
                    w.fail("Invalid ODS column repetition."); return
                }
                cellRepeat = count
                cellType = attrs["office:value-type"] ?? ""
                cellValue = ["float", "percentage", "currency"].contains(cellType) ? attrs["office:value"] : (cellType == "boolean" ? attrs["office:boolean-value"].map { $0 == "true" ? "TRUE" : "FALSE" } : nil)
            case "text:p" where inCell: if paragraphs > 0 { cellText += "\n" }; paragraphs += 1
            default: break
            }
        }
        w.onText = { s in if inCell { cellText += s } }
        w.onEnd = { name in
            switch name {
            case "table:table-cell", "table:covered-table-cell":
                guard inCell else { return }
                inCell = false
                let text = cellValue ?? cellText
                if !text.isEmpty {
                    do { try SheetIO.validateSize(rows: rowIndex + rowRepeat, columns: columnIndex + cellRepeat) }
                    catch { w.fail(error.localizedDescription); return }
                    for column in columnIndex..<(columnIndex + cellRepeat) { row[column] = text }
                }
                columnIndex += cellRepeat
            case "table:table-row":
                guard tableDepth == 1, !firstTableDone else { return }
                if !row.isEmpty {
                    for index in rowIndex..<(rowIndex + rowRepeat) { cells[index] = row }
                }
                rowIndex += rowRepeat
            case "table:table": tableDepth -= 1; if tableDepth == 0 { firstTableDone = true }
            default: break
            }
        }
        try XMLWalker.parse(data, walker: w)
        return try SheetIO.dense(cells)
    }

    static func write(_ rows: [[String]], to url: URL) throws {
        var table = ""
        for row in rows {
            table += "<table:table-row>"
            for cell in row {
                if cell.isEmpty { table += "<table:table-cell/>" }
                else if SheetIO.isPlainNumber(cell) {
                    table += "<table:table-cell office:value-type=\"float\" office:value=\"\(cell)\"><text:p>\(cell)</text:p></table:table-cell>"
                } else {
                    let paras = cell.components(separatedBy: "\n").map { "<text:p>\(SheetIO.xmlEscape($0))</text:p>" }.joined()
                    table += "<table:table-cell office:value-type=\"string\">\(paras)</table:table-cell>"
                }
            }
            table += "</table:table-row>"
        }
        let header = #"<?xml version="1.0" encoding="UTF-8"?>"#
        let content = header + #"<office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" office:version="1.2"><office:body><office:spreadsheet><table:table table:name="Foglio1">"# + table + "</table:table></office:spreadsheet></office:body></office:document-content>"
        let manifest = header + #"<manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2"><manifest:file-entry manifest:full-path="/" manifest:media-type="application/vnd.oasis.opendocument.spreadsheet"/><manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/></manifest:manifest>"#
        try Archive.write([("mimetype", Data("application/vnd.oasis.opendocument.spreadsheet".utf8)),
                           ("content.xml", Data(content.utf8)), ("META-INF/manifest.xml", Data(manifest.utf8))], first: ["mimetype"], to: url)
    }
}
