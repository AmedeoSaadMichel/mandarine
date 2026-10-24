import AppKit
import Foundation
import PDFKit

/// Parameter definitions and execution for every tool in the catalogue.
enum ToolEngine {
    typealias Progress = @Sendable (Double) -> Void

    // MARK: Parameter helpers

    private static func slider(_ id: String, _ label: String, _ lo: Double, _ hi: Double, step: Double = 1, value: Double, unit: String = "",
                               help: String? = nil, visible: ((ToolValues) -> Bool)? = nil) -> ToolParam {
        ToolParam(id: id, label: label, kind: .slider(min: lo, max: hi, step: step, unit: unit), defaultValue: .number(value), help: help, visible: visible)
    }

    private static func number(_ id: String, _ label: String, value: Double, unit: String = "", visible: ((ToolValues) -> Bool)? = nil) -> ToolParam {
        ToolParam(id: id, label: label, kind: .number(unit: unit), defaultValue: .number(value), visible: visible)
    }

    private static func choice(_ id: String, _ label: String, _ options: [Choice], value: String, visible: ((ToolValues) -> Bool)? = nil) -> ToolParam {
        ToolParam(id: id, label: label, kind: .choice(options), defaultValue: .text(value), visible: visible)
    }

    private static func toggle(_ id: String, _ label: String, value: Bool, help: String? = nil, visible: ((ToolValues) -> Bool)? = nil) -> ToolParam {
        ToolParam(id: id, label: label, kind: .toggle, defaultValue: .bool(value), help: help, visible: visible)
    }

    private static func text(_ id: String, _ label: String, _ placeholder: String, value: String = "", help: String? = nil,
                             visible: ((ToolValues) -> Bool)? = nil) -> ToolParam {
        ToolParam(id: id, label: label, kind: .text(placeholder: placeholder), defaultValue: .text(value), help: help, visible: visible)
    }

    private static func time(_ id: String, _ label: String, value: String, help: String? = nil, visible: ((ToolValues) -> Bool)? = nil) -> ToolParam {
        ToolParam(id: id, label: label, kind: .time, defaultValue: .text(value), help: help, visible: visible)
    }

    private static func color(_ id: String, _ label: String, value: String) -> ToolParam {
        ToolParam(id: id, label: label, kind: .color, defaultValue: .text(value))
    }

    private static func rect(_ id: String, _ label: String, multi: Bool, value: [CGRect] = []) -> ToolParam {
        ToolParam(id: id, label: label, kind: .rect(multi: multi), defaultValue: .rects(value))
    }

    static let qualityChoices = [Choice(id: "balanced", label: "Balanced"), Choice(id: "strong", label: "Stronger (smaller file)")]
    static let cropAspects = [Choice(id: "free", label: "Free"), Choice(id: "original", label: "Same as original"), Choice(id: "1:1", label: "1:1"),
                              Choice(id: "4:3", label: "4:3"), Choice(id: "3:2", label: "3:2"), Choice(id: "16:9", label: "16:9"), Choice(id: "9:16", label: "9:16")]
    static let redactStyles = [Choice(id: "black", label: "Black box"), Choice(id: "pixelate", label: "Pixel"), Choice(id: "blur", label: "Blur")]

    // MARK: Parameters

    /// Sidebar card of every parameter, in the order the cards first appear.
    static let sections: [ToolID: [String: String]] = [
        .compress: ["level": "Compression"],
        .editMetadata: ["mode": "Removal", "gps": "Removal"],
        .editImage: ["exposure": "Light", "brightness": "Light", "contrast": "Light", "saturation": "Color", "filter": "Color", "sharpness": "Detail"],
        .frameImage: ["padding": "Background", "color": "Background", "aspect": "Background", "corner": "Style", "shadow": "Style"],
        .cropImage: ["aspect": "Aspect ratio"],
        .redactImage: ["style": "Style", "strength": "Style"],
        .resizeImage: ["mode": "Size", "max": "Size", "upscale": "Size", "percent": "Size", "width": "Size", "height": "Size", "keep": "Size"],
        .rotateImage: ["rotation": "Rotation", "flipH": "Flip", "flipV": "Flip"],
        .createPDF: ["pageSize": "Page", "margin": "Page"],
        .createCollage: ["columns": "Layout", "cell": "Layout", "spacing": "Layout", "fit": "Layout", "color": "Appearance", "format": "Appearance"],
        .cropVideo: ["aspect": "Aspect ratio"],
        .changeVideoSpeed: ["speed": "Speed", "preservePitch": "Audio"],
        .joinVideos: ["size": "Output", "format": "Output"],
                .splitVideo: ["mode": "Split", "seconds": "Split", "points": "Split"],
        .redactVideo: ["style": "Style", "strength": "Style"],
        .normalizeAudio: ["target": "Level"],
        .audioToVideo: ["style": "Style", "color": "Style", "size": "Output"],
        .audioChannels: ["mode": "Channels"],
        .redactAudio: ["ranges": "Zones", "replace": "Replace with"],
        .trimVideo: ["start": "Range", "end": "Range", "precise": "Output"],
        .trimAudio: ["start": "Range", "end": "Range", "precise": "Output"],
        .splitPDF: ["mode": "Split", "every": "Split", "ranges": "Split"],
    ]

    static func params(for tool: ToolID, files: [URL]) -> [ToolParam] {
        var list = rawParams(for: tool, files: files)
        for i in list.indices {
            list[i].section = sections[tool]?[list[i].id]
            if tool == .editMetadata, list[i].id.hasPrefix("f_") { list[i].inMain = true }
            if tool == .changeVideoSpeed || tool == .videoSnapshots || tool == .splitVideo { list[i].custom = true }
            if tool == .cropVideo, ["sameSize", "outWidth", "outHeight", "keepRatio"].contains(list[i].id) { list[i].custom = true }
        }
        return list
    }

    private static func rawParams(for tool: ToolID, files: [URL]) -> [ToolParam] {
        let first = files.first
        let duration = first.flatMap(MediaInfo.duration)
        let durationText = duration.map(Tools.formatTime) ?? ""
        switch tool {
        case .compress:
            return [choice("level", "Compression level", qualityChoices, value: "balanced")]

        case .editMetadata:
            let single = files.count == 1
            var keys: [MetadataOps.Field] = first.map(MetadataOps.fields) ?? []
            for f in files.dropFirst() { let k = Set(MetadataOps.fields(for: f).map(\.key)); keys = keys.filter { k.contains($0.key) } }
            let current = single ? MetadataOps.read(first!) : [:]
            var p: [ToolParam] = [choice("mode", "Action", [Choice(id: "edit", label: "Edit fields"), Choice(id: "clean", label: "Remove all metadata")], value: "edit")]
            for f in keys {
                p.append(text("f_\(f.key)", f.label, single ? "" : "Leave blank to keep unchanged", value: current[f.key] ?? "", visible: { $0.string("mode") == "edit" }))
            }
            if files.allSatisfy({ Category.of($0) == .image }) {
                p.append(toggle("gps", "Remove GPS location", value: first.map(MetadataOps.hasGPS) ?? false, visible: { $0.string("mode") == "edit" }))
            }
            return p

        case .editImage:
            return [slider("exposure", "Exposure", -2, 2, step: 0.05, value: 0, unit: " EV"),
                    slider("brightness", "Brightness", -0.5, 0.5, step: 0.01, value: 0),
                    slider("contrast", "Contrast", 0.5, 1.5, step: 0.01, value: 1),
                    slider("saturation", "Saturation", 0, 2, step: 0.01, value: 1),
                    slider("sharpness", "Sharpness", 0, 2, step: 0.05, value: 0),
                    choice("filter", "Filter", ImageOps.filterChoices, value: "none")]

        case .frameImage:
            return [slider("padding", "Margin", 0, 50, step: 1, value: 10, unit: "%"),
                    color("color", "Background color", value: "#FFFFFF"),
                    choice("aspect", "Aspect ratio", ImageOps.aspectChoices, value: "original"),
                    slider("corner", "Rounded corners", 0, 30, step: 1, value: 0, unit: "%"),
                    toggle("shadow", "Shadow", value: false)]

        case .cropImage:
            return [choice("aspect", "Aspect ratio", cropAspects, value: "free"),
                    rect("area", "Area to keep", multi: false, value: [CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)])]

        case .redactImage:
            return [choice("style", "Style", redactStyles, value: "black"),
                    slider("strength", "Strength", 4, 80, step: 1, value: 24, visible: { $0.string("style") != "black" }),
                    rect("areas", "Areas to redact", multi: true)]

        case .resizeImage:
            return [choice("mode", "Mode", [Choice(id: "max", label: "Longest edge"), Choice(id: "percent", label: "Percentage"), Choice(id: "exact", label: "Exact dimensions")], value: "max"),
                    number("max", "Longest edge", value: 1024, unit: "px", visible: { $0.string("mode") == "max" }),
                    toggle("upscale", "Upscale smaller images", value: false, visible: { $0.string("mode") == "max" }),
                    slider("percent", "Scale", 5, 200, step: 1, value: 50, unit: "%", visible: { $0.string("mode") == "percent" }),
                    number("width", "Width", value: 1920, unit: "px", visible: { $0.string("mode") == "exact" }),
                    number("height", "Height", value: 1080, unit: "px", visible: { $0.string("mode") == "exact" }),
                    toggle("keep", "Keep aspect ratio", value: true, visible: { $0.string("mode") == "exact" })]

        case .rotateImage:
            return [choice("rotation", "Rotation", [Choice(id: "0", label: "None"), Choice(id: "90", label: "90° clockwise"), Choice(id: "180", label: "180°"), Choice(id: "270", label: "90° counterclockwise")], value: "90"),
                    toggle("flipH", "Flip horizontally", value: false),
                    toggle("flipV", "Flip vertically", value: false)]

        case .createPDF:
            return [choice("pageSize", "Page", ImageOps.pageSizes, value: "fit"),
                    slider("margin", "Margin", 0, 100, step: 1, value: 24, unit: " pt", visible: { $0.string("pageSize") != "fit" })]

        case .createCollage:
            return [slider("columns", "Columns", 1, 8, step: 1, value: Double(min(3, max(files.count, 1)))),
                    number("cell", "Cell size", value: 600, unit: "px"),
                    number("spacing", "Image spacing", value: 12, unit: "px"),
                    color("color", "Background color", value: "#FFFFFF"),
                    choice("fit", "Fit", [Choice(id: "fill", label: "Fill (crop)"), Choice(id: "fit", label: "Fit (with borders)")], value: "fill"),
                    choice("format", "Format", [Choice(id: "png", label: "PNG"), Choice(id: "jpg", label: "JPG")], value: "png")]

        case .trimVideo, .trimAudio:
            return [time("start", "Start", value: "0:00", help: "Seconds (90) or minutes:seconds (1:30)."),
                    time("end", "End", value: durationText),
                    toggle("precise", "Precise trim (re-encode)", value: true, help: "When off, copiess without re-encoding: fast, but trims at the previous keyframe.")]

        case .cropVideo:
            return [choice("aspect", "Aspect ratio", cropAspects, value: "free"),
                    rect("area", "Area to keep", multi: false, value: [CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)]),
                    toggle("sameSize", "Same as crop area", value: true),
                    number("outWidth", "Width", value: 0, unit: "px"),
                    number("outHeight", "Height", value: 0, unit: "px"),
                    toggle("keepRatio", "Keep aspect ratio", value: true)]

        case .changeVideoSpeed:
            return [toggle("useZones", "Speed zones", value: false),
                    ToolParam(id: "speedZones", label: "Zones", kind: .text(placeholder: ""), defaultValue: .speedZones([])),
                    slider("speed", "Speed", 0.25, 4, step: 0.05, value: 1, unit: "×"),
                    toggle("preservePitch", "Preserve pitch", value: true,
                           help: "Keeps the original pitch. Turn off for a tape effect: faster playback sounds higher.")]

        case .joinVideos:
            return [choice("size", "Resolution", [Choice(id: "first", label: "Same as first video"), Choice(id: "1080", label: "1080p"), Choice(id: "720", label: "720p"), Choice(id: "480", label: "480p")], value: "first"),
                    choice("format", "Format", [Choice(id: "mp4", label: "MP4"), Choice(id: "mov", label: "MOV"), Choice(id: "mkv", label: "MKV"), Choice(id: "webm", label: "WebM")], value: "mp4")]

        case .videoSnapshots:
            return [text("times", "Selected frames", "1.5, 3.25", help: "Times in seconds, separated by commas."),
                    toggle("every", "Every N seconds", value: false),
                    number("everyN", "Every", value: 5, unit: "s"),
                    choice("format", "Format", MediaOps.frameFormats, value: "png")]

        case .splitVideo:
            return [choice("mode", "Mode", [Choice(id: "points", label: "Custom cuts"), Choice(id: "equal", label: "Equal parts")], value: "points"),
                    text("points", "Cut points", "1:30, 3:00", help: "Separated by commas."),
                    number("parts", "Number of parts", value: 2)]

        case .redactVideo:
            return [choice("style", "Style", redactStyles, value: "black"),
                    slider("strength", "Strength", 4, 80, step: 1, value: 24, visible: { $0.string("style") != "black" }),
                    ToolParam(id: "areas", label: "Areas to redact", kind: .rect(multi: true), defaultValue: .areas([]))]

        case .normalizeAudio:
            return [choice("target", "Level", [Choice(id: "-16", label: "−16 LUFS · Podcast"), Choice(id: "-14", label: "−14 LUFS · Streaming"), Choice(id: "-23", label: "−23 LUFS · Broadcast (EBU R128)")], value: "-16")]

        case .audioToVideo:
            return [choice("style", "Style", MediaOps.visualizerStyles, value: "waves"),
                    choice("size", "Dimensions", MediaOps.visualizerSizes, value: "1280x720"),
                    color("color", "Background color", value: "#101820")]

        case .audioChannels:
            return [choice("mode", "Channels", MediaOps.channelModes, value: "mono")]

        case .redactAudio:
            return [text("ranges", "Zones", "1:10-1:14, 2:30-2:33", help: "Start–end ranges, separated by commas."),
                    choice("replace", "Replace with", [Choice(id: "bleep", label: "1 kHz bleep"), Choice(id: "silence", label: "Silence")], value: "bleep")]

        case .mergePDF:
            return []

        case .organizePDF:
            let count = first.flatMap { PDFDocument(url: $0)?.pageCount } ?? 0
            return [text("pages", "Pages", "1,2,3", value: (1...max(count, 1)).map(String.init).joined(separator: ","),
                         help: "Page order in the output. Add a rotation if needed, for example 3:90.")]

        case .splitPDF:
            return [choice("mode", "Mode", [Choice(id: "pages", label: "One page per file"), Choice(id: "every", label: "Every N pages"), Choice(id: "ranges", label: "Page groups")], value: "pages"),
                    number("every", "Pages per part", value: 5, visible: { $0.string("mode") == "every" }),
                    text("ranges", "Groups", "1-3; 4-6, 9", help: "Each semicolon-separated group becomes a PDF.", visible: { $0.string("mode") == "ranges" })]
        }
    }

    // MARK: Preview

    /// Transform used for the live preview of tools that change every pixel.
    static func previewTransform(_ tool: ToolID, _ v: ToolValues) -> ((CGImage) -> CGImage)? {
        switch tool {
        case .editImage: let e = edit(v); return { ImageOps.edit($0, e) }
        case .frameImage: let f = frame(v); return { ImageOps.frame($0, f) }
        case .rotateImage: let t = rotation(v); return { ImageOps.rotate($0, quarterTurns: t.0, flipH: t.1, flipV: t.2) }
        default: return nil
        }
    }

    private static func edit(_ v: ToolValues) -> ImageOps.Edit {
        ImageOps.Edit(brightness: v.number("brightness"), contrast: v.number("contrast", default: 1), saturation: v.number("saturation", default: 1),
                      exposure: v.number("exposure"), sharpness: v.number("sharpness"), filter: v.string("filter", default: "none"))
    }

    private static func frame(_ v: ToolValues) -> ImageOps.Frame {
        ImageOps.Frame(paddingPercent: v.number("padding", default: 10), color: NSColor(hex: v.string("color", default: "#FFFFFF")) ?? .white,
                       aspect: v.string("aspect", default: "original"), cornerPercent: v.number("corner"), shadow: v.bool("shadow"))
    }

    private static func rotation(_ v: ToolValues) -> (Int, Bool, Bool) {
        ((Int(v.string("rotation", default: "0")) ?? 0) / 90, v.bool("flipH"), v.bool("flipV"))
    }

    /// The crop box must keep the chosen ratio on the *pixel* grid, so the picker needs the image size.
    static func aspectRatio(_ id: String, imageSize: CGSize) -> Double? {
        switch id {
        case "free": return nil
        case "original": return imageSize.height > 0 ? Double(imageSize.width / imageSize.height) : nil
        default: return ImageOps.aspectValue(id)
        }
    }

    // MARK: Running

    static func run(_ tool: ToolID, files: [URL], values v: ToolValues, folder: URL?, progress: @escaping Progress = { _ in }) async throws -> [URL] {
        guard let source = files.first else { throw ToolError.invalid("Select at least one file.") }
        // Independent batch tools keep each result beside its own source by default.
        if folder == nil, files.count > 1,
           Set(files.map { $0.deletingLastPathComponent().resolvingSymlinksInPath().path }).count > 1,
           [.compress, .editMetadata, .resizeImage, .rotateImage].contains(tool) {
            var results: [URL] = []
            for (index, file) in files.enumerated() {
                results += try await OutputStore.transaction(source: file, folder: nil) { stage in
                    try await runStaged(tool, files: [file], values: v, folder: stage, metadataBatch: true) { value in
                        progress((Double(index) + value) / Double(files.count))
                    }
                }
            }
            return results
        }
        return try await OutputStore.transaction(source: source, folder: folder) { stage in
            try await runStaged(tool, files: files, values: v, folder: stage, progress: progress)
        }
    }

    private static func runStaged(_ tool: ToolID, files: [URL], values v: ToolValues, folder: URL?, metadataBatch: Bool = false, progress: @escaping Progress) async throws -> [URL] {
        guard tool.applies(to: files) else { throw ToolError.invalid("\(tool.title) is not available for this selection.") }
        let first = files[0]
        switch tool {
        case .compress:
            let q: Quality = v.string("level", default: "balanced") == "strong" ? .strong : .balanced
            return try await each(files, progress) { try await Tools.run(.compress, on: $0, folder: folder, quality: q) }

        case .editMetadata:
            let clean = v.string("mode", default: "edit") == "clean"
            let single = files.count == 1 && !metadataBatch
            return try await each(files, progress) { f in
                var fields: [String: String] = [:]
                if !clean {
                    for field in MetadataOps.fields(for: f) {
                        guard let value = v["f_\(field.key)"], case .text(let t) = value else { continue }
                        if single || !t.isEmpty { fields[field.key] = t }
                    }
                }
                let out = Converter.outputURL(for: f, ext: f.pathExtension, in: folder, suffix: clean ? " clean" : " edited")
                try await MetadataOps.write(f, to: out, fields: fields, stripAll: clean, stripLocation: v.bool("gps"))
                return out
            }

        case .editImage, .frameImage, .rotateImage:
            guard let t = previewTransform(tool, v) else { return [] }
            let suffix = tool == .editImage ? " edited" : tool == .frameImage ? " framed" : " rotated"
            return try await imageEach(files, folder, suffix, progress) { img, _ in t(img) }

        case .cropImage:
            guard let area = v.rects("area").first else { throw ToolError.invalid("Draw the area to keep.") }
            return try await imageEach(files, folder, " cropped", progress) { img, _ in try ImageOps.crop(img, to: area) }

        case .redactImage:
            let style = ImageOps.RedactStyle(rawValue: v.string("style", default: "black")) ?? .black
            let rects = v.rects("areas"), strength = v.number("strength", default: 24)
            return try await imageEach(files, folder, " redacted", progress) { img, _ in try ImageOps.redact(img, rects: rects, style: style, strength: strength) }

        case .resizeImage:
            let mode: ImageOps.ResizeMode
            switch v.string("mode", default: "max") {
            case "percent": mode = .percent(v.number("percent", default: 50))
            case "exact": mode = .exact(Int(v.number("width", default: 1920)), Int(v.number("height", default: 1080)), keepAspect: v.bool("keep", default: true))
            default: mode = .maxDimension(Int(v.number("max", default: 1024)), allowUpscale: v.bool("upscale"))
            }
            if case .maxDimension(let m, _) = mode, m < 1 { throw ToolError.invalid("The longest edge must be at least 1 px.") }
            if case .exact(let w, let h, _) = mode, w < 1 || h < 1 { throw ToolError.invalid("Width and height must be at least 1 px.") }
            if case .percent(let p) = mode, p <= 0 { throw ToolError.invalid("The scale must be greater than zero.") }
            return try await imageEach(files, folder, " resized", progress) { img, _ in ImageOps.resize(img, mode) }

        case .createPDF:
            var images: [CGImage] = []
            for f in files { images.append(try ImageOps.load(f).image) }
            let out = Converter.outputURL(for: first, ext: "pdf", in: folder, suffix: files.count > 1 ? " (+\(files.count - 1))" : "")
            try ImageOps.writePDF(images, to: out, pageSize: v.string("pageSize", default: "fit"), margin: v.number("margin", default: 24))
            progress(1)
            return [out]

        case .createCollage:
            var images: [CGImage] = []
            for f in files { images.append(try ImageOps.load(f, maxPixel: 4000).image) }
            let c = ImageOps.Collage(columns: Int(v.number("columns", default: 3)), cell: Int(v.number("cell", default: 600)), spacing: Int(v.number("spacing", default: 12)),
                                     color: NSColor(hex: v.string("color", default: "#FFFFFF")) ?? .white, fill: v.string("fit", default: "fill") == "fill")
            let ext = v.string("format", default: "png") == "jpg" ? "jpg" : "png"
            let out = Converter.outputURL(for: first, ext: ext, in: folder, suffix: " collage")
            try ImageOps.write(try ImageOps.collage(images, c), to: out, ext: ext)
            progress(1)
            return [out]

        case .trimVideo, .trimAudio:
            let startText = v.string("start").trimmingCharacters(in: .whitespaces)
            guard let start = startText.isEmpty ? 0 : Tools.parseTime(startText) else { throw ToolError.invalid("Invalid start time: \(startText). Use seconds (90) or minutes:seconds (1:30).") }
            guard let end = v.time("end") else { throw ToolError.invalid("Enter an end time, for example 1:30.") }
            if let d = MediaInfo.duration(first), start >= d { throw ToolError.invalid("The start (\(Tools.formatTime(start))) is beyond the end of the file (\(Tools.formatTime(d))).") }
            let out = Converter.outputURL(for: first, ext: first.pathExtension, in: folder, suffix: " trimmed")
            try await MediaOps.trim(first, out, start: start, end: end, copy: !v.bool("precise", default: true), progress: progress)
            return [out]

        case .cropVideo:
            guard let area = v.rects("area").first else { throw ToolError.invalid("Draw the area to keep.") }
            let out = Converter.outputURL(for: first, ext: first.pathExtension, in: folder, suffix: " cropped")
            var outputSize: (Int, Int)?
            if !v.bool("sameSize", default: true), let size = MediaInfo.videoSize(first) {
                let box = CropGeometry.pixels(area, in: CGSize(width: size.width, height: size.height))
                let w = Int(v.number("outWidth")), h = Int(v.number("outHeight"))
                outputSize = CropGeometry.outputSize(crop: box, sameAsCrop: false, width: w > 0 ? w : nil, height: h > 0 ? h : nil, keepRatio: v.bool("keepRatio", default: true))
            }
            try await MediaOps.crop(first, out, rect: area, outputSize: outputSize, progress: progress)
            return [out]

        case .changeVideoSpeed:
            let out = Converter.outputURL(for: first, ext: first.pathExtension, in: folder, suffix: " speed")
            if v.bool("useZones") {
                guard !v.speedZones().isEmpty else { throw ToolError.invalid("Add at least one speed zone.") }
                try await MediaOps.speed(first, out, zones: v.speedZones(), preservePitch: v.bool("preservePitch", default: true), progress: progress)
            } else {
                try await MediaOps.speed(first, out, factor: v.number("speed", default: 1), preservePitch: v.bool("preservePitch", default: true), progress: progress)
            }
            return [out]

        case .joinVideos:
            let ext = v.string("format", default: "mp4")
            let maxH: Int? = ["1080": 1080, "720": 720, "480": 480][v.string("size", default: "first")]
            let out = Converter.outputURL(for: first, ext: ext, in: folder, suffix: " joined")
            try await MediaOps.join(files, out, maxHeight: maxH, progress: progress)
            return [out]

        case .videoSnapshots:
            let times = try snapshotTimes(v, duration: MediaInfo.duration(first) ?? 0)
            let ext = v.string("format", default: "png")
            let base = first.deletingPathExtension().lastPathComponent
            let dir = PDFOps.uniqueFolder(in: folder ?? first.deletingLastPathComponent(), named: "\(base) frames")
            return try await MediaOps.extractFrames(first, into: dir, base: base, times: times, ext: ext, progress: progress)

        case .splitVideo:
            guard let d = MediaInfo.duration(first) else { throw ConversionError(message: "Unable to read the video duration") }
            guard let custom = SplitPlan.parse(v.string("points")) else { throw ToolError.invalid("Invalid cut point: \(v.string("points"))") }
            let equal = v.string("mode", default: "points") == "equal"
            let n = Int(v.number("parts", default: 2))
            if equal && !SplitPlan.partsRange.contains(n) { throw ToolError.invalid("The number of parts must be between 2 and 50.") }
            let points = SplitPlan.combined(duration: d, parts: equal ? n : nil, custom: custom)
            let ranges = MediaOps.splitRanges(duration: d, at: points)
            let base = first.deletingPathExtension().lastPathComponent
            let dir = PDFOps.uniqueFolder(in: folder ?? first.deletingLastPathComponent(), named: "\(base) parts")
            return try await MediaOps.split(first, into: dir, base: base, ranges: ranges, progress: progress)

        case .redactVideo:
            let style = ImageOps.RedactStyle(rawValue: v.string("style", default: "black")) ?? .black
            let out = Converter.outputURL(for: first, ext: first.pathExtension, in: folder, suffix: " redacted")
            try await MediaOps.redactVideo(first, out, areas: v.areas("areas"), style: style, strength: v.number("strength", default: 24), progress: progress)
            return [out]

        case .normalizeAudio:
            let out = Converter.outputURL(for: first, ext: first.pathExtension, in: folder, suffix: " normalized")
            try await MediaOps.normalize(first, out, lufs: Double(v.string("target", default: "-16")) ?? -16, progress: progress)
            return [out]

        case .audioToVideo:
            let out = Converter.outputURL(for: first, ext: "mp4", in: folder, suffix: " visualizer")
            try await MediaOps.visualizer(first, out, style: v.string("style", default: "waves"), size: v.string("size", default: "1280x720"),
                                          color: NSColor(hex: v.string("color", default: "#101820")) ?? .black, progress: progress)
            return [out]

        case .audioChannels:
            let out = Converter.outputURL(for: first, ext: first.pathExtension, in: folder, suffix: " channels")
            try await MediaOps.channels(first, out, mode: v.string("mode", default: "mono"), progress: progress)
            return [out]

        case .redactAudio:
            let ranges = try TimeRanges.parse(v.string("ranges"))
            let out = Converter.outputURL(for: first, ext: first.pathExtension, in: folder, suffix: " bleeped")
            try await MediaOps.bleep(first, out, ranges: ranges, silence: v.string("replace", default: "bleep") == "silence", progress: progress)
            return [out]

        case .mergePDF:
            let out = try Tools.mergePDFs(files, folder: folder)
            progress(1)
            return [out]

        case .organizePDF:
            let doc = try Tools.openPDF(first)
            let specs = try PDFOps.parsePageSpecs(v.string("pages"), pageCount: doc.pageCount)
            let out = Converter.outputURL(for: first, ext: "pdf", in: folder, suffix: " organized")
            try PDFOps.organize(first, out, specs: specs)
            progress(1)
            return [out]

        case .splitPDF:
            let doc = try Tools.openPDF(first)
            let groups: [[Int]]
            switch v.string("mode", default: "pages") {
            case "every": groups = try PDFOps.chunks(pageCount: doc.pageCount, every: Int(v.number("every", default: 5)))
            case "ranges": groups = try PDFOps.parseGroups(v.string("ranges"), pageCount: doc.pageCount)
            default: groups = try PDFOps.chunks(pageCount: doc.pageCount, every: 1)
            }
            let result = try PDFOps.splitGroups(first, groups: groups, folder: folder, label: v.string("mode") == "pages" ? "pages" : "parts")
            progress(1)
            return result.files
        }
    }

    /// Frame times from the values: the picked ones ("1.5, 3.25") plus every N seconds when switched on.
    static func snapshotTimes(_ v: ToolValues, duration: Double) throws -> [Double] {
        var chosen: [Double] = []
        for part in v.string("times").split(separator: ",") {
            let text = part.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            guard let t = Tools.parseTime(text) else { throw ToolError.invalid("Invalid time: \(text)") }
            chosen.append(t)
        }
        var every: Double?
        if v.bool("every") {
            let n = v.number("everyN", default: 5)
            guard n > 0 else { throw ToolError.invalid("The interval must be greater than zero.") }
            every = n
        }
        let times = MediaOps.frameTimes(chosen: chosen, every: every, duration: duration)
        guard !times.isEmpty else { throw ToolError.invalid("Select at least one frame.") }
        return times
    }

    // MARK: Batch helpers

    private static func each(_ files: [URL], _ progress: @escaping Progress, _ body: (URL) async throws -> URL) async throws -> [URL] {
        var out: [URL] = []
        for (i, f) in files.enumerated() {
            try Task.checkCancellation()
            out.append(try await body(f))
            progress(Double(i + 1) / Double(files.count))
        }
        return out
    }

    private static func imageEach(_ files: [URL], _ folder: URL?, _ suffix: String, _ progress: @escaping Progress,
                                  _ transform: (CGImage, URL) throws -> CGImage) async throws -> [URL] {
        try await each(files, progress) { f in
            let loaded = try ImageOps.load(f)
            let image = try transform(loaded.image, f)
            let ext = ImageOps.outputExt(for: f)
            let out = Converter.outputURL(for: f, ext: ext, in: folder, suffix: suffix)
            try ImageOps.write(image, to: out, ext: ext, quality: 0.92, properties: loaded.properties)
            return out
        }
    }
}
