import AppKit
import XCTest
@testable import Mandarine

// Evita l'ambiguità con il typedef Category di objc/runtime.h.
typealias Category = Mandarine.Category

/// Creates sample files in a throwaway directory.
final class Fixtures {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mandarine-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

    func text(_ name: String, _ content: String) throws -> URL {
        let u = url(name)
        try content.write(to: u, atomically: true, encoding: .utf8)
        return u
    }

    func png(_ name: String = "img.png") throws -> URL {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.orange.setFill()
        NSRect(x: 0, y: 0, width: 32, height: 32).fill()
        NSGraphicsContext.restoreGraphicsState()
        let u = url(name)
        try rep.representation(using: .png, properties: [:])!.write(to: u)
        return u
    }

    /// Generates media with ffmpeg; throws XCTSkip when ffmpeg is missing.
    func media(_ name: String, args: [String]) throws -> URL {
        guard let ff = Converter.ffmpegPath else { throw XCTSkip("ffmpeg non installato") }
        let u = url(name)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ff)
        p.arguments = ["-loglevel", "error", "-y"] + args + [u.path]
        p.standardInput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "ffmpeg non ha generato \(name)")
        return u
    }

    func wav() throws -> URL { try media("tone.wav", args: ["-f", "lavfi", "-i", "sine=d=1"]) }
    func mp4() throws -> URL { try media("clip.mp4", args: ["-f", "lavfi", "-i", "testsrc=d=1:s=160x120", "-f", "lavfi", "-i", "sine=d=1", "-shortest", "-pix_fmt", "yuv420p"]) }
}

func convert(_ src: URL, _ ext: String, folder: URL? = nil, quality: Quality = .balanced) async throws -> URL {
    try await Converter.convert(src, to: ext, outputFolder: folder, quality: quality)
}

func XCTAssertFileExists(_ url: URL, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "manca \(url.lastPathComponent)", file: file, line: line)
    let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
    XCTAssertGreaterThan(size, 0, "\(url.lastPathComponent) è vuoto", file: file, line: line)
}
