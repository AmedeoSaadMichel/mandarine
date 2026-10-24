import AppKit
import AVFoundation
import Foundation

/// Facts about a media file, from AVFoundation with an ffmpeg fallback.
enum MediaInfo {
    static func duration(_ url: URL) -> Double? {
        let d = AVURLAsset(url: url).duration.seconds
        if d.isFinite, d > 0 { return d }
        guard let ff = Converter.ffmpegPath else { return nil }
        let text = Shell.captureStderr(ff, ["-hide_banner", "-i", url.path])
        guard let r = text.range(of: #"Duration: (\d+):(\d+):(\d+(\.\d+)?)"#, options: .regularExpression) else { return nil }
        let parts = text[r].dropFirst("Duration: ".count).split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }

    static func videoSize(_ url: URL) -> (width: Int, height: Int)? {
        if let t = AVURLAsset(url: url).tracks(withMediaType: .video).first {
            let s = t.naturalSize.applying(t.preferredTransform)
            if abs(s.width) >= 1, abs(s.height) >= 1 { return (Int(abs(s.width)), Int(abs(s.height))) }
        }
        guard let ff = Converter.ffmpegPath else { return nil }
        let text = Shell.captureStderr(ff, ["-hide_banner", "-i", url.path])
        guard let line = text.split(separator: "\n").first(where: { $0.contains("Video:") }),
              let r = line.range(of: #"\b(\d{2,5})x(\d{2,5})\b"#, options: .regularExpression) else { return nil }
        let p = line[r].split(separator: "x")
        guard p.count == 2, let w = Int(p[0]), let h = Int(p[1]) else { return nil }
        return (w, h)
    }

    static func hasAudio(_ url: URL) -> Bool {
        if !AVURLAsset(url: url).tracks(withMediaType: .audio).isEmpty { return true }
        guard let ff = Converter.ffmpegPath else { return false }
        return Shell.captureStderr(ff, ["-hide_banner", "-i", url.path]).contains("Audio:")
    }

    /// A frame (default: the first) as an image, for previews.
    static func frame(_ url: URL, at seconds: Double = 0) -> CGImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        if let img = try? gen.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil) { return img }
        guard let ff = Converter.ffmpegPath else { return nil }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = Shell.captureStderr(ff, ["-hide_banner", "-loglevel", "error", "-nostdin", "-ss", String(seconds), "-i", url.path, "-frames:v", "1", "-y", tmp.path])
        return (try? ImageOps.load(tmp))?.image
    }
}

/// Time ranges such as "1.5-3, 1:10-1:20".
enum TimeRanges {
    static func parse(_ text: String) throws -> [(start: Double, end: Double)] {
        let parts = text.split(whereSeparator: { $0 == "," || $0 == ";" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { throw ToolError.invalid("Enter at least one range, for example 1:10-1:20.") }
        return try parts.map { part in
            let ends = part.split(separator: "-", omittingEmptySubsequences: false).map { Tools.parseTime(String($0)) }
            guard ends.count == 2, let s = ends[0], let e = ends[1], e > s else {
                throw ToolError.invalid("Invalid range: \(part). Use start–end, with the end after the start.")
            }
            return (s, e)
        }
    }
}

/// ffmpeg-based video and audio operations.
enum MediaOps {
    typealias Progress = @Sendable (Double) -> Void

    static func videoCodecArgs(_ ext: String) -> [String] {
        switch ext {
        case "webm": return ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-c:a", "libopus"]
        case "mp4", "mov", "m4v", "mkv": return ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "20", "-c:a", "aac"]
        default: return []
        }
    }

    private static func even(_ v: Int) -> Int { max(v - v % 2, 2) }

    // MARK: Trim

    /// `copy` cuts without re-encoding: instant, but video starts on the keyframe before `start`.
    static func trim(_ src: URL, _ out: URL, start: Double, end: Double, copy: Bool = false, progress: Progress? = nil) async throws {
        guard start >= 0, end > start else { throw ConversionError(message: "Invalid range: the end must be after the start.") }
        let ext = Category.normalized(src.pathExtension)
        let isVideo = Category.of(src) == .video
        let codec: [String] = copy ? ["-c", "copy"] : (isVideo ? videoCodecArgs(ext) : [])
        let args = ["-y", "-ss", String(start), "-to", String(end), "-i", src.path] + codec + [out.path]
        try await Converter.runFFmpeg(args, duration: end - start, progress: progress)
    }

    // MARK: Crop

    /// `rect` is normalised 0…1 from the top-left.
    static func crop(_ src: URL, _ out: URL, rect: CGRect, outputSize: (Int, Int)? = nil, progress: Progress? = nil) async throws {
        guard let size = MediaInfo.videoSize(src) else { throw ConversionError(message: "Unable to read video dimensions") }
        let x = max(0, Int(rect.minX * CGFloat(size.width))), y = max(0, Int(rect.minY * CGFloat(size.height)))
        let w = even(min(Int(rect.width * CGFloat(size.width)), size.width - x)), h = even(min(Int(rect.height * CGFloat(size.height)), size.height - y))
        guard w >= 2, h >= 2 else { throw ToolError.invalid("The crop area is empty.") }
        let ext = Category.normalized(src.pathExtension)
        var filter = "crop=\(w):\(h):\(x):\(y)"
        if let (ow, oh) = outputSize, (ow, oh) != (w, h) { filter += ",scale=\(even(ow)):\(even(oh)):flags=lanczos,setsar=1" }
        try await Converter.runFFmpeg(["-y", "-i", src.path, "-vf", filter] + videoCodecArgs(ext) + [out.path],
                                      duration: MediaInfo.duration(src), progress: progress)
    }

    // MARK: Speed

    static func atempoChain(_ factor: Double) -> String {
        var f = factor
        var parts: [String] = []
        while f > 2 { parts.append("atempo=2.0"); f /= 2 }
        while f < 0.5 { parts.append("atempo=0.5"); f /= 0.5 }
        parts.append("atempo=\(String(format: "%.4f", f))")
        return parts.joined(separator: ",")
    }

    /// Audio filter for a speed change. With `preservePitch` the voice keeps its pitch (atempo);
    /// without it the pitch follows the speed, like a tape (asetrate).
    static func speedAudioFilter(factor: Double, preservePitch: Bool) -> String {
        preservePitch ? atempoChain(factor) : "aresample=48000,asetrate=\(String(format: "%.1f", 48000 * factor)),aresample=48000"
    }

    static func speed(_ src: URL, _ out: URL, factor: Double, preservePitch: Bool = true, progress: Progress? = nil) async throws {
        guard factor >= 0.25, factor <= 4 else { throw ToolError.invalid("Speed must be between 0.25× and 4×.") }
        let ext = Category.normalized(src.pathExtension)
        let audio = MediaInfo.hasAudio(src)
        var filter = "[0:v]setpts=PTS/\(String(format: "%.4f", factor))[v]"
        var maps = ["-map", "[v]"]
        if audio { filter += ";[0:a]\(speedAudioFilter(factor: factor, preservePitch: preservePitch))[a]"; maps += ["-map", "[a]"] }
        let duration = (MediaInfo.duration(src) ?? 0) / factor
        try await Converter.runFFmpeg(["-y", "-i", src.path, "-filter_complex", filter] + maps + videoCodecArgs(ext) + [out.path],
                                      duration: duration, progress: progress)
    }

    /// Retimes each source interval, filling untouched gaps at 1×, then concatenates in source order.
    static func speed(_ src: URL, _ out: URL, zones: [SpeedZone], preservePitch: Bool = true, progress: Progress? = nil) async throws {
        guard let duration = MediaInfo.duration(src) else { throw ToolError.invalid("Unable to read the video duration.") }
        let segments = try SpeedPlan.segments(duration: duration, zones: zones)
        let audio = MediaInfo.hasAudio(src)
        let n = segments.count
        func decimal(_ value: Double) -> String { String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value) }
        var fps = 30.0
        if let track = try? await AVURLAsset(url: src).loadTracks(withMediaType: .video).first,
           let rate = try? await track.load(.nominalFrameRate), rate.isFinite, rate > 0 {
            fps = Double(rate)
        }
        var chains = ["[0:v]split=\(n)" + (0..<n).map { "[sv\($0)]" }.joined()]
        if audio { chains.append("[0:a]asplit=\(n)" + (0..<n).map { "[sa\($0)]" }.joined()) }
        var concat = ""
        for (i, segment) in segments.enumerated() {
            let start = decimal(segment.start), end = decimal(segment.end), length = decimal(segment.outputDuration)
            chains.append("[sv\(i)]trim=start=\(start):end=\(end),setpts=(PTS-STARTPTS)/\(decimal(segment.factor)),fps=\(decimal(fps)),tpad=stop_mode=clone:stop_duration=0.1,trim=duration=\(length),setpts=PTS-STARTPTS[v\(i)]")
            concat += "[v\(i)]"
            if audio {
                chains.append("[sa\(i)]atrim=start=\(start):end=\(end),asetpts=PTS-STARTPTS,\(speedAudioFilter(factor: segment.factor, preservePitch: preservePitch)),apad,atrim=duration=\(length),asetpts=PTS-STARTPTS[a\(i)]")
                concat += "[a\(i)]"
            }
        }
        chains.append("\(concat)concat=n=\(n):v=1:a=\(audio ? 1 : 0)[v]" + (audio ? "[a]" : ""))
        var args = ["-y", "-i", src.path, "-filter_complex", chains.joined(separator: ";"), "-map", "[v]"]
        if audio { args += ["-map", "[a]"] }
        args += videoCodecArgs(Category.normalized(src.pathExtension))
        args.append(out.path)
        try await Converter.runFFmpeg(args, duration: segments.reduce(0) { $0 + $1.outputDuration }, progress: progress)
    }

    // MARK: Join

    static func join(_ urls: [URL], _ out: URL, maxHeight: Int?, progress: Progress? = nil) async throws {
        guard urls.count >= 2 else { throw ToolError.invalid("Select at least two videos to join.") }
        guard var size = MediaInfo.videoSize(urls[0]) else { throw ConversionError(message: "Unable to read video dimensions") }
        if let maxHeight, size.height > maxHeight {
            size = (even(size.width * maxHeight / size.height), even(maxHeight))
        }
        size = (even(size.width), even(size.height))
        let withAudio = urls.map(MediaInfo.hasAudio)
        var inputs: [String] = []
        for u in urls { inputs += ["-i", u.path] }
        var silenceIndex: [Int: Int] = [:]
        var next = urls.count
        if withAudio.contains(true) {
            for (i, u) in urls.enumerated() where !withAudio[i] {
                inputs += ["-f", "lavfi", "-t", String(MediaInfo.duration(u) ?? 1), "-i", "anullsrc=r=44100:cl=stereo"]
                silenceIndex[i] = next; next += 1
            }
        }
        var chains: [String] = []
        var concatInputs = ""
        for i in urls.indices {
            let w = size.width, h = size.height
            var vf = "[\(i):v]scale=\(w):\(h):force_original_aspect_ratio=decrease,"
            vf += "pad=\(w):\(h):(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30,format=yuv420p[v\(i)]"
            chains.append(vf)
            concatInputs += "[v\(i)]"
            if withAudio.contains(true) {
                let idx = withAudio[i] ? i : silenceIndex[i]!
                chains.append("[\(idx):a]aresample=44100,aformat=sample_fmts=fltp:channel_layouts=stereo[a\(i)]")
                concatInputs += "[a\(i)]"
            }
        }
        let hasA = withAudio.contains(true)
        chains.append("\(concatInputs)concat=n=\(urls.count):v=1:a=\(hasA ? 1 : 0)[v]" + (hasA ? "[a]" : ""))
        var maps: [String] = ["-map", "[v]"]
        if hasA { maps += ["-map", "[a]"] }
        let ext = Category.normalized(out.pathExtension)
        var total = 0.0
        for u in urls { total += MediaInfo.duration(u) ?? 0 }
        var args: [String] = ["-y"]
        args += inputs
        args += ["-filter_complex", chains.joined(separator: ";")]
        args += maps
        args += videoCodecArgs(ext)
        args.append(out.path)
        try await Converter.runFFmpeg(args, duration: total, progress: progress)
    }

    // MARK: Frames

    /// Times to save: the frames picked by hand plus one every `every` seconds, sorted, without near-duplicates,
    /// all inside the clip.
    static func frameTimes(chosen: [Double], every: Double?, duration: Double, frameDuration: Double = 0.04) -> [Double] {
        var all = chosen.filter { $0.isFinite && $0 >= 0 }
        if let step = every, step > 0, duration > 0 {
            var t = 0.0
            while t < duration - 0.001 { all.append(t); t += step }
        }
        let last = max(duration - frameDuration, 0)
        let clamped = all.map { duration > 0 ? min($0, last) : $0 }.sorted()
        var result: [Double] = []
        for t in clamped where result.last.map({ t - $0 > 0.02 }) ?? true { result.append(t) }
        return result
    }

    static let frameFormats: [Choice] = [Choice(id: "png", label: "PNG (lossless)"), Choice(id: "jpg", label: "JPG"), Choice(id: "heic", label: "HEIC")]

    /// Saves one image per time into `folder`, named "<base> 001.png"…; returns the files.
    static func extractFrames(_ src: URL, into folder: URL, base: String, times: [Double], ext: String, progress: Progress? = nil) async throws -> [URL] {
        guard !times.isEmpty else { throw ToolError.invalid("Select at least one frame.") }
        guard ["png", "jpg", "heic"].contains(ext) else { throw ToolError.invalid("Unsupported format: \(ext)") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let width = max(String(times.count).count, 3)
        var outputs: [URL] = []
        for (i, t) in times.enumerated() {
            try Task.checkCancellation()
            let out = folder.appendingPathComponent("\(base) " + String(format: "%0\(width)d", i + 1) + ".\(ext)")
            if ext == "heic" {
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
                defer { try? FileManager.default.removeItem(at: tmp) }
                try await Converter.runFFmpeg(["-y", "-ss", String(t), "-i", src.path, "-frames:v", "1", tmp.path])
                try ImageOps.write(try ImageOps.load(tmp).image, to: out, ext: "heic", quality: 0.9)
            } else {
                try await Converter.runFFmpeg(["-y", "-ss", String(t), "-i", src.path, "-frames:v", "1"] + (ext == "jpg" ? ["-q:v", "2"] : []) + [out.path])
            }
            guard ((try? FileManager.default.attributesOfItem(atPath: out.path))?[.size] as? Int ?? 0) > 0 else {
                throw ConversionError(message: "No frame at \(TrimRange.format(t))")
            }
            outputs.append(out)
            progress?(Double(i + 1) / Double(times.count))
        }
        return outputs
    }

    // MARK: Split

    /// Cut points → consecutive ranges covering the whole file.
    static func splitRanges(duration: Double, every: Double) -> [(Double, Double)] {
        guard every > 0, duration > 0 else { return [] }
        var r: [(Double, Double)] = []
        var t = 0.0
        while t < duration - 0.01 { r.append((t, min(t + every, duration))); t += every }
        return r
    }

    static func splitRanges(duration: Double, at points: [Double]) -> [(Double, Double)] {
        let cuts = ([0] + points.filter { $0 > 0 && $0 < duration }.sorted() + [duration])
        return zip(cuts, cuts.dropFirst()).map { ($0, $1) }.filter { $1 - $0 > 0.01 }
    }

    static func split(_ src: URL, into folder: URL, base: String, ranges: [(Double, Double)], progress: Progress? = nil) async throws -> [URL] {
        guard ranges.count >= 2 else { throw ToolError.invalid("These settings do not split the file: add at least one cut point within its duration.") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = src.pathExtension
        let width = String(ranges.count).count
        var outputs: [URL] = []
        for (i, r) in ranges.enumerated() {
            let out = folder.appendingPathComponent("\(base) " + String(format: "%0\(width)d", i + 1) + ".\(ext)")
            try await trim(src, out, start: r.0, end: r.1)
            outputs.append(out)
            progress?(Double(i + 1) / Double(ranges.count))
        }
        return outputs
    }

    // MARK: Redact video

    static func redactFilter(size: (width: Int, height: Int), areas: [TimedArea], style: ImageOps.RedactStyle, strength: Double) -> String {
        var current = "0:v"
        var chain: [String] = []
        for (i, area) in areas.enumerated() {
            let r = area.rect
            let enable = area.window.map { ":enable='between(t,\($0.0),\($0.1))'" } ?? ""
            let x = max(0, Int(r.minX * CGFloat(size.width))), y = max(0, Int(r.minY * CGFloat(size.height)))
            let w = max(2, min(Int(r.width * CGFloat(size.width)), size.width - x)), h = max(2, min(Int(r.height * CGFloat(size.height)), size.height - y))
            let masked = area.shape != .rectangle
            if masked {
                chain.append("[\(current)]split[original\(i)][input\(i)]")
                current = "input\(i)"
            }
            let next = masked ? "effect\(i)" : "r\(i)"
            switch style {
            case .black:
                chain.append("[\(current)]drawbox=x=\(x):y=\(y):w=\(w):h=\(h):color=black:t=fill\(enable)[\(next)]")
            case .blur:
                // FFmpeg requires a kernel smaller than each plane, including subsampled chroma.
                let radius = max(Int(strength), 2)
                chain.append("[\(current)]split[o\(i)][b\(i)];[b\(i)]crop=\(w):\(h):\(x):\(y),boxblur=luma_radius='min(\(radius),floor((min(w,h)-1)/2))':luma_power=2:chroma_radius='min(\(radius),floor((min(cw,ch)-1)/2))'[c\(i)];[o\(i)][c\(i)]overlay=\(x):\(y)\(enable)[\(next)]")
            case .pixelate:
                let block = max(Int(strength), 2)
                chain.append("[\(current)]split[o\(i)][b\(i)];[b\(i)]crop=\(w):\(h):\(x):\(y),scale=max(iw/\(block)\\,1):max(ih/\(block)\\,1),scale=\(w):\(h):flags=neighbor[c\(i)];[o\(i)][c\(i)]overlay=\(x):\(y)\(enable)[\(next)]")
            }
            if masked {
                let input = areas.prefix(i + 1).filter { $0.shape != .rectangle }.count
                chain.append("[\(input):v]format=gbrp[mask\(i)];[original\(i)]format=gbrp[base\(i)];[\(next)]format=gbrp[fx\(i)];[base\(i)][fx\(i)][mask\(i)]maskedmerge[r\(i)]")
            }
            current = "r\(i)"
        }
        return chain.joined(separator: ";") + ";[\(current)]format=yuv420p[vout]"
    }

    /// Each area is covered only inside its own time range (the whole video when it has none).
    static func redactVideo(_ src: URL, _ out: URL, areas: [TimedArea], style: ImageOps.RedactStyle, strength: Double,
                            progress: Progress? = nil) async throws {
        guard !areas.isEmpty else { throw ToolError.invalid("Draw at least one redaction area.") }
        let duration = MediaInfo.duration(src)
        for (i, a) in areas.enumerated() {
            guard let w = a.window else { continue }
            guard w.1 > w.0, w.0 >= 0 else { throw ToolError.invalid("Area \(i + 1): the end must be after the start.") }
            if let d = duration, w.0 >= d { throw ToolError.invalid("Area \(i + 1): the start is beyond the end of the video.") }
        }
        guard let size = MediaInfo.videoSize(src) else { throw ConversionError(message: "Unable to read video dimensions") }
        let masks = FileManager.default.temporaryDirectory.appendingPathComponent("mandarine-masks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: masks, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: masks) }
        var inputs = ["-y", "-i", src.path]
        for (i, area) in areas.filter({ $0.shape != .rectangle }).enumerated() {
            if area.shape == .freehand && area.points.count < 3 { throw ToolError.invalid("The outline needs at least three points.") }
            let url = masks.appendingPathComponent("mask\(i).png")
            try area.writeMask(size: size, to: url)
            inputs += ["-i", url.path]
        }
        let filter = redactFilter(size: size, areas: areas, style: style, strength: strength)
        let ext = Category.normalized(src.pathExtension)
        try await Converter.runFFmpeg(inputs + ["-filter_complex", filter, "-map", "[vout]", "-map", "0:a?"] + videoCodecArgs(ext) + [out.path],
                                      duration: duration, progress: progress)
    }

    // MARK: Audio

    static func normalize(_ src: URL, _ out: URL, lufs: Double, progress: Progress? = nil) async throws {
        guard lufs >= -40, lufs <= -5 else { throw ToolError.invalid("The level must be between -40 and -5 LUFS.") }
        try await Converter.runFFmpeg(["-y", "-i", src.path, "-af", "loudnorm=I=\(lufs):TP=-1.5:LRA=11", out.path],
                                      duration: MediaInfo.duration(src), progress: progress)
    }

    static let channelModes: [Choice] = [
        Choice(id: "mono", label: "Mono (mescola i canali)"), Choice(id: "stereo", label: "Stereo"), Choice(id: "swap", label: "Swap left and right"),
        Choice(id: "left", label: "Left channel on both"), Choice(id: "right", label: "Right channel on both"),
    ]

    static func channels(_ src: URL, _ out: URL, mode: String, progress: Progress? = nil) async throws {
        let af: [String]
        switch mode {
        case "mono": af = ["-ac", "1"]
        case "stereo": af = ["-ac", "2"]
        case "swap": af = ["-af", "pan=stereo|c0=c1|c1=c0"]
        case "left": af = ["-af", "pan=stereo|c0=c0|c1=c0"]
        case "right": af = ["-af", "pan=stereo|c0=c1|c1=c1"]
        default: throw ToolError.invalid("Unknown channel mode: \(mode)")
        }
        try await Converter.runFFmpeg(["-y", "-i", src.path] + af + [out.path], duration: MediaInfo.duration(src), progress: progress)
    }

    /// Replaces the given ranges with a 1 kHz bleep (or silence).
    static func bleep(_ src: URL, _ out: URL, ranges: [(start: Double, end: Double)], silence: Bool, progress: Progress? = nil) async throws {
        guard !ranges.isEmpty else { throw ToolError.invalid("Enter at least one range.") }
        let inRange = ranges.map { "between(t,\($0.start),\($0.end))" }.joined(separator: "+")
        let duration = MediaInfo.duration(src)
        if silence {
            try await Converter.runFFmpeg(["-y", "-i", src.path, "-af", "volume='if(gt(\(inRange),0),0,1)':eval=frame", out.path], duration: duration, progress: progress)
        } else {
            let filter = "[0:a]volume='if(gt(\(inRange),0),0,1)':eval=frame[a0];[1:a]volume='if(gt(\(inRange),0),3,0)':eval=frame[a1];[a0][a1]amix=inputs=2:duration=first,volume=2[a]"
            try await Converter.runFFmpeg(["-y", "-i", src.path, "-f", "lavfi", "-i", "sine=f=1000", "-filter_complex", filter, "-map", "[a]", out.path],
                                          duration: duration, progress: progress)
        }
    }

    static let visualizerStyles: [Choice] = [
        Choice(id: "waves", label: "Wave"), Choice(id: "spectrum", label: "Spectrum"), Choice(id: "bars", label: "Frequency bars"),
    ]
    static let visualizerSizes: [Choice] = [
        Choice(id: "1280x720", label: "1280×720"), Choice(id: "1920x1080", label: "1920×1080"), Choice(id: "1080x1080", label: "1080×1080 (square)"),
    ]

    static func visualizer(_ src: URL, _ out: URL, style: String, size: String, color: NSColor, progress: Progress? = nil) async throws {
        let hex = String(color.hexString.dropFirst())
        let viz: String
        switch style {
        case "waves": viz = "showwaves=s=\(size):mode=cline:colors=white:scale=sqrt"
        case "spectrum": viz = "showspectrum=s=\(size):mode=combined:color=intensity:scale=log:legend=0"
        case "bars": viz = "showfreqs=s=\(size):mode=bar:colors=white:ascale=log:fscale=log"
        default: throw ToolError.invalid("Unknown style: \(style)")
        }
        let filter = style == "spectrum"
            ? "[0:a]\(viz),format=yuv420p[v]"
            : "color=c=0x\(hex):s=\(size)[bg];[0:a]\(viz),format=rgba[w];[bg][w]overlay=shortest=1:format=auto,format=yuv420p[v]"
        try await Converter.runFFmpeg(["-y", "-i", src.path, "-filter_complex", filter, "-map", "[v]", "-map", "0:a", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", out.path],
                                      duration: MediaInfo.duration(src), progress: progress)
    }
}


/// Rules for split points, kept apart from the UI so they can be tested.
enum SplitPlan {
    /// A point closer than this to either end of the clip is refused.
    static let edgeMargin = 0.1
    /// Two points closer than this are considered the same.
    static let pointGap = 0.05
    static let partsRange = 2...50

    /// The sorted list with `t` added, or nil when it is too close to an end or to an existing point.
    static func adding(_ t: Double, to points: [Double], duration: Double) -> [Double]? {
        guard t.isFinite, t >= edgeMargin, t <= duration - edgeMargin else { return nil }
        guard !points.contains(where: { abs($0 - t) < pointGap }) else { return nil }
        return (points + [t]).sorted()
    }

    /// Cut points that divide `duration` into `parts` equal clips.
    static func equalPoints(duration: Double, parts: Int) -> [Double] {
        let n = min(max(parts, partsRange.lowerBound), partsRange.upperBound)
        guard duration > 0 else { return [] }
        return (1..<n).map { duration * Double($0) / Double(n) }
    }

    /// Preserve automatic boundaries and merge custom cuts without duplicate clips.
    static func combined(duration: Double, parts: Int?, custom: [Double]) -> [Double] {
        var points = parts.map { equalPoints(duration: duration, parts: $0) } ?? []
        for point in custom.sorted() where point.isFinite && point > 0 && point < duration {
            if !points.contains(where: { abs($0 - point) < pointGap }) { points.append(point) }
        }
        return points.sorted()
    }

    static func parse(_ text: String) -> [Double]? {
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var out: [Double] = []
        for p in parts { guard let t = Tools.parseTime(p) else { return nil }; out.append(t) }
        return out.sorted()
    }

    static func serialize(_ points: [Double]) -> String { points.map { String(format: "%.3f", $0) }.joined(separator: ", ") }
}
