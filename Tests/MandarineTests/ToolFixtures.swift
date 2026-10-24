import AppKit
import AVFoundation
import XCTest
@testable import Mandarine

typealias RGB = (r: Int, g: Int, b: Int)

extension Fixtures {
    /// Top-left red, top-right green, bottom-left blue, bottom-right yellow.
    @discardableResult
    func quadrants(_ name: String = "quad.png", width: Int = 100, height: Int = 80) throws -> URL {
        let ctx = ImageOps.context(width, height)
        let colors: [NSColor] = [.red, .green, .blue, .yellow]
        for (i, c) in colors.enumerated() {
            let col = i % 2, row = i / 2
            ctx.setFillColor(c.usingColorSpace(.sRGB)!.cgColor)
            // CG origin is bottom-left: row 0 (top) is the upper half.
            ctx.fill(CGRect(x: col * width / 2, y: (1 - row) * height / 2, width: width / 2, height: height / 2))
        }
        let u = url(name)
        let ext = u.pathExtension.lowercased() == "jpg" ? "jpg" : "png"
        try ImageOps.write(ctx.makeImage()!, to: u, ext: ext, quality: 1)
        return u
    }

    func solid(_ name: String, _ color: NSColor, width: Int = 40, height: Int = 40) throws -> URL {
        let ctx = ImageOps.context(width, height)
        ctx.setFillColor(color.usingColorSpace(.sRGB)!.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let u = url(name)
        try ImageOps.write(ctx.makeImage()!, to: u, ext: u.pathExtension.lowercased() == "jpg" ? "jpg" : "png", quality: 1)
        return u
    }

    func video(_ name: String = "v.mp4", seconds: Int = 3, size: String = "160x120", audio: Bool = true) throws -> URL {
        var args = ["-f", "lavfi", "-i", "testsrc=d=\(seconds):s=\(size):r=25"]
        if audio { args += ["-f", "lavfi", "-i", "sine=d=\(seconds)", "-shortest"] }
        args += ["-pix_fmt", "yuv420p"]
        return try media(name, args: args)
    }

    func tone(_ name: String = "tone.wav", seconds: Int = 4, amplitude: Double = 0.5) throws -> URL {
        try media(name, args: ["-f", "lavfi", "-i", "sine=d=\(seconds)", "-af", "volume=\(amplitude)"])
    }
}

func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> RGB {
    let ctx = ImageOps.context(1, 1)
    ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
    let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
    return (Int(p[2]), Int(p[1]), Int(p[0]))
}

func pixel(_ url: URL, _ x: Int, _ y: Int) throws -> RGB { pixel(try ImageOps.load(url).image, x, y) }

func isClose(_ a: RGB, _ b: RGB, tolerance: Int = 40) -> Bool {
    abs(a.r - b.r) <= tolerance && abs(a.g - b.g) <= tolerance && abs(a.b - b.b) <= tolerance
}

let red: RGB = (255, 0, 0), green: RGB = (0, 255, 0), blue: RGB = (0, 0, 255), yellow: RGB = (255, 255, 0)

func imageSize(_ url: URL) throws -> (Int, Int) { let i = try ImageOps.load(url).image; return (i.width, i.height) }

func duration(_ url: URL) -> Double { MediaInfo.duration(url) ?? 0 }

/// Volume of a time window, in dB, as reported by ffmpeg's volumedetect.
func maxVolume(_ url: URL, from: Double, to: Double) -> Double {
    guard let ff = Converter.ffmpegPath else { return 0 }
    let out = Shell.captureStderr(ff, ["-hide_banner", "-nostdin", "-ss", String(from), "-t", String(to - from), "-i", url.path, "-af", "volumedetect", "-f", "null", "-"])
    guard let r = out.range(of: #"max_volume: (-?[\d.]+|-inf) dB"#, options: .regularExpression) else { return 0 }
    let v = out[r].replacingOccurrences(of: "max_volume: ", with: "").replacingOccurrences(of: " dB", with: "")
    return Double(v) ?? -200
}

func runTool(_ tool: ToolID, _ files: [URL], _ set: [String: ToolValue] = [:], folder: URL? = nil) async throws -> [URL] {
    var values = ToolValues(defaultsFor: ToolEngine.params(for: tool, files: files))
    for (k, v) in set { values[k] = v }
    return try await ToolEngine.run(tool, files: files, values: values, folder: folder)
}

/// Integrated loudness (LUFS) as measured by ffmpeg's loudnorm analysis.
func integratedLoudness(_ url: URL) -> Double {
    guard let ff = Converter.ffmpegPath else { return 0 }
    let out = Shell.captureStderr(ff, ["-hide_banner", "-nostdin", "-i", url.path, "-af", "loudnorm=print_format=json", "-f", "null", "-"])
    guard let r = out.range(of: #""input_i"\s*:\s*"(-?[\d.]+)""#, options: .regularExpression) else { return 0 }
    let digits = out[r].split(separator: ":").last!.replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces)
    return Double(digits) ?? 0
}
