import AVFoundation
import ImageIO
import PDFKit
import XCTest
@testable import Mandarine

final class ToolsTests: XCTestCase {
    private func run(_ kind: Tools.Kind, _ url: URL, folder: URL? = nil, trim: (start: Double, end: Double)? = nil) async throws -> URL {
        try await Tools.run(kind, on: url, folder: folder, trim: trim)
    }

    private func duration(_ url: URL) -> Double { AVURLAsset(url: url).duration.seconds }

    private func size(_ url: URL) -> Int { ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0 }

    /// A JPEG with EXIF/GPS/TIFF metadata, built with ImageIO.
    private func jpegWithMetadata(_ f: Fixtures, width: Int = 64, height: Int = 32) throws -> URL {
        let png = try f.png("src.png")
        let source = CGImageSourceCreateWithURL(png as CFURL, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        let out = f.url("tagged.jpg")
        let dest = CGImageDestinationCreateWithURL(out as CFURL, "public.jpeg" as CFString, 1, nil)!
        let props: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "segreto"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 45.0, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 9.0, kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "FotoCamera", kCGImagePropertyTIFFModel: "X1"],
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out
    }

    private func properties(_ url: URL) -> [CFString: Any] {
        CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil) as? [CFString: Any] ?? [:]
    }

    // MARK: Availability

    func testToolAvailabilityByFileType() throws {
        let png = URL(fileURLWithPath: "/tmp/a.png"), wav = URL(fileURLWithPath: "/tmp/a.wav")
        let mp4 = URL(fileURLWithPath: "/tmp/a.mp4"), csv = URL(fileURLWithPath: "/tmp/a.csv")
        XCTAssertTrue(Tools.supports(.resize1024, png))
        XCTAssertTrue(Tools.supports(.resizeHalf, png))
        XCTAssertFalse(Tools.supports(.resize720, png))
        XCTAssertFalse(Tools.supports(.trim, png))
        XCTAssertFalse(Tools.supports(.resize1024, wav))
        XCTAssertTrue(Tools.available(for: csv).isEmpty)
        XCTAssertTrue(Tools.available(for: URL(fileURLWithPath: "/tmp/a.xyz")).isEmpty)
        if Converter.ffmpegPath != nil {
            XCTAssertTrue(Tools.supports(.trim, wav))
            XCTAssertTrue(Tools.supports(.trim, mp4))
            XCTAssertTrue(Tools.supports(.resize720, mp4))
            XCTAssertTrue(Tools.supports(.compress, mp4))
            XCTAssertFalse(Tools.supports(.compress, wav), "il WAV non si comprime: va convertito")
        }
    }

    func testUnsupportedToolThrowsAndWritesNothing() async throws {
        let f = try Fixtures()
        let csv = try f.text("a.csv", "a,b")
        do { _ = try await run(.compress, csv); XCTFail("doveva fallire") }
        catch { XCTAssertTrue(error is ConversionError) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.dir.path), ["a.csv"])
    }

    func testToolOnMissingFileThrows() async throws {
        let f = try Fixtures()
        do { _ = try await run(.resize1024, f.url("ghost.png")); XCTFail() } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.url("ghost 1024px.png").path))
    }

    // MARK: Resize

    private func bigImage(_ f: Fixtures, w: Int, h: Int, name: String = "big.png") throws -> URL {
        try f.media(name, args: ["-f", "lavfi", "-i", "testsrc=s=\(w)x\(h)", "-frames:v", "1"])
    }

    func testResizeLimitsLongestSideTo1024() async throws {
        let f = try Fixtures()
        let out = try await run(.resize1024, try bigImage(f, w: 2000, h: 1000))
        let (w, h) = try Tools.pixelSize(out)
        XCTAssertEqual(w, 1024)
        XCTAssertEqual(h, 512, "mantiene le proporzioni")
        XCTAssertEqual(out.lastPathComponent, "big 1024px.png")
    }

    func testResizeDoesNotUpscaleSmallImages() async throws {
        let f = try Fixtures()
        let small = try f.png()
        let out = try await run(.resize1024, small)
        let (w, _) = try Tools.pixelSize(out)
        XCTAssertLessThanOrEqual(w, 1024)
    }

    func testResizeHalf() async throws {
        let f = try Fixtures()
        let out = try await run(.resizeHalf, try bigImage(f, w: 400, h: 300))
        let (w, h) = try Tools.pixelSize(out)
        XCTAssertEqual(w, 200); XCTAssertEqual(h, 150)
        XCTAssertEqual(out.lastPathComponent, "big 50%.png")
    }

    func testResizeHalfOfTinyImageStaysValid() async throws {
        let f = try Fixtures()
        let one = try bigImage(f, w: 1, h: 1, name: "one.png")
        let (w, h) = try Tools.pixelSize(try await run(.resizeHalf, one))
        XCTAssertGreaterThanOrEqual(w, 1); XCTAssertGreaterThanOrEqual(h, 1)
    }

    func testResizeKeepsOriginalUntouched() async throws {
        let f = try Fixtures()
        let src = try bigImage(f, w: 300, h: 300)
        let before = try Data(contentsOf: src)
        _ = try await run(.resize1024, src)
        XCTAssertEqual(try Data(contentsOf: src), before)
    }

    func testResizeVideoTo720p() async throws {
        let f = try Fixtures()
        let big = try f.media("big.mp4", args: ["-f", "lavfi", "-i", "testsrc=d=1:s=1920x1080", "-pix_fmt", "yuv420p"])
        let out = try await run(.resize720, big)
        let track = try XCTUnwrap(AVURLAsset(url: out).tracks(withMediaType: .video).first)
        XCTAssertEqual(Int(track.naturalSize.height), 720)
        XCTAssertEqual(Int(track.naturalSize.width), 1280)
    }

    // MARK: Compress

    func testCompressJPEGReducesSize() async throws {
        let f = try Fixtures()
        let noisy = try f.media("noise.png", args: ["-f", "lavfi", "-i", "nullsrc=s=512x512,geq=random(1)*255:random(2)*255:random(3)*255", "-frames:v", "1"])
        let jpg = try await Converter.convert(noisy, to: "jpg", outputFolder: f.dir, quality: .balanced)
        let out = try await run(.compress, jpg)
        XCTAssertLessThan(size(out), size(jpg))
        XCTAssertEqual(out.lastPathComponent, "noise compressed.jpg")
    }

    func testCompressPNGKeepsPixelsIdentical() async throws {
        let f = try Fixtures()
        let src = try bigImage(f, w: 200, h: 200)
        let out = try await run(.compress, src)
        XCTAssertLessThanOrEqual(size(out), size(src) + 64)
        let a = try Tools.pixelSize(src), b = try Tools.pixelSize(out)
        XCTAssertEqual(a.0, b.0); XCTAssertEqual(a.1, b.1)
    }

    func testCompressTIFFIsReadable() async throws {
        let f = try Fixtures()
        let tiff = try await Converter.convert(try f.png(), to: "tiff", outputFolder: nil, quality: .balanced)
        let out = try await run(.compress, tiff)
        XCTAssertNotNil(NSImage(contentsOf: out))
    }

    func testCompressVideoReducesSizeAndKeepsDuration() async throws {
        let f = try Fixtures()
        let src = try f.media("hq.mp4", args: ["-f", "lavfi", "-i", "testsrc2=d=2:s=640x360", "-f", "lavfi", "-i", "sine=d=2",
                                                "-c:v", "libx264", "-crf", "10", "-pix_fmt", "yuv420p", "-shortest"])
        let out = try await run(.compress, src)
        XCTAssertLessThan(size(out), size(src))
        XCTAssertEqual(duration(out), duration(src), accuracy: 0.3)
    }

    func testCompressAudioReducesSize() async throws {
        let f = try Fixtures()
        let mp3 = try f.media("hq.mp3", args: ["-f", "lavfi", "-i", "sine=d=3", "-q:a", "0"])
        let out = try await run(.compress, mp3)
        XCTAssertLessThan(size(out), size(mp3))
        XCTAssertEqual(duration(out), duration(mp3), accuracy: 0.3)
    }

    // MARK: Strip metadata

    func testStripImageRemovesEXIFGPSAndTIFFTags() async throws {
        let f = try Fixtures()
        let tagged = try jpegWithMetadata(f)
        let before = properties(tagged)
        XCTAssertNotNil(before[kCGImagePropertyGPSDictionary], "la fixture deve contenere il GPS")
        let out = try await run(.stripMetadata, tagged)
        let after = properties(out)
        XCTAssertNil(after[kCGImagePropertyGPSDictionary])
        let exif = after[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertNil(exif?[kCGImagePropertyExifUserComment])
        let tiff = after[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        XCTAssertNil(tiff?[kCGImagePropertyTIFFMake])
        XCTAssertEqual(out.lastPathComponent, "tagged clean.jpg")
        // I pixel restano: stesse dimensioni.
        let a = try Tools.pixelSize(tagged), b = try Tools.pixelSize(out)
        XCTAssertEqual(a.0, b.0); XCTAssertEqual(a.1, b.1)
    }

    func testStripImageKeepsOriginalMetadata() async throws {
        let f = try Fixtures()
        let tagged = try jpegWithMetadata(f)
        _ = try await run(.stripMetadata, tagged)
        XCTAssertNotNil(properties(tagged)[kCGImagePropertyGPSDictionary], "l'originale non va toccato")
    }

    func testStripImageAppliesOrientation() async throws {
        let f = try Fixtures()
        let src = try bigImage(f, w: 100, h: 40)
        // Crea un JPEG con orientamento 6 (ruotato di 90°): la dimensione visiva è 40x100.
        let img = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(src as CFURL, nil)!, 0, nil)!
        let rotated = f.url("rot.jpg")
        let dest = CGImageDestinationCreateWithURL(rotated as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, [kCGImagePropertyOrientation: 6] as CFDictionary)
        CGImageDestinationFinalize(dest)
        let out = try await run(.stripMetadata, rotated)
        let (w, h) = try Tools.pixelSize(out)
        XCTAssertEqual(w, 40); XCTAssertEqual(h, 100, "l'orientamento viene applicato ai pixel")
        XCTAssertNil(properties(out)[kCGImagePropertyOrientation].flatMap { ($0 as? Int) == 6 ? $0 : nil })
    }

    func testStripPNGAndHEIC() async throws {
        let f = try Fixtures()
        let png = try f.png()
        XCTAssertFileExists(try await run(.stripMetadata, png))
        let heic = try await Converter.convert(png, to: "heic", outputFolder: nil, quality: .balanced)
        XCTAssertFileExists(try await run(.stripMetadata, heic))
    }

    func testStripAudioMetadata() async throws {
        let f = try Fixtures()
        let tagged = try f.media("song.mp3", args: ["-f", "lavfi", "-i", "sine=d=1", "-metadata", "title=Titolo", "-metadata", "artist=Artista"])
        let before = try await AVURLAsset(url: tagged).load(.commonMetadata)
        XCTAssertFalse(before.isEmpty, "la fixture deve avere tag")
        let out = try await run(.stripMetadata, tagged)
        let after = try await AVURLAsset(url: out).load(.commonMetadata)
        XCTAssertTrue(after.filter { ($0.commonKey?.rawValue ?? "") == "title" || ($0.commonKey?.rawValue ?? "") == "artist" }.isEmpty)
        XCTAssertEqual(duration(out), duration(tagged), accuracy: 0.2)
    }

    func testStripVideoMetadata() async throws {
        let f = try Fixtures()
        let tagged = try f.media("clip.mp4", args: ["-f", "lavfi", "-i", "testsrc=d=1:s=160x120", "-pix_fmt", "yuv420p", "-metadata", "title=Privato"])
        let out = try await run(.stripMetadata, tagged)
        let after = try await AVURLAsset(url: out).load(.commonMetadata)
        XCTAssertTrue(after.filter { $0.commonKey?.rawValue == "title" }.isEmpty)
    }

    // MARK: Trim

    func testTrimAudioToRange() async throws {
        let f = try Fixtures()
        let src = try f.media("long.wav", args: ["-f", "lavfi", "-i", "sine=d=10"])
        let out = try await run(.trim, src, trim: (2, 5))
        XCTAssertEqual(duration(out), 3, accuracy: 0.3)
        XCTAssertEqual(out.lastPathComponent, "long trimmed.wav")
    }

    func testTrimVideoToRange() async throws {
        let f = try Fixtures()
        let src = try f.media("v.mp4", args: ["-f", "lavfi", "-i", "testsrc=d=6:s=160x120", "-f", "lavfi", "-i", "sine=d=6",
                                               "-pix_fmt", "yuv420p", "-shortest"])
        let out = try await run(.trim, src, trim: (1, 3.5))
        XCTAssertEqual(duration(out), 2.5, accuracy: 0.4)
    }

    func testTrimFromStart() async throws {
        let f = try Fixtures()
        let src = try f.media("a.wav", args: ["-f", "lavfi", "-i", "sine=d=4"])
        let out = try await run(.trim, src, trim: (0, 1))
        XCTAssertEqual(duration(out), 1, accuracy: 0.2)
    }

    func testTrimEndBeyondDurationKeepsRest() async throws {
        let f = try Fixtures()
        let src = try f.media("a.wav", args: ["-f", "lavfi", "-i", "sine=d=3"])
        let out = try await run(.trim, src, trim: (1, 999))
        XCTAssertEqual(duration(out), 2, accuracy: 0.3)
    }

    func testTrimInvalidRangesAreRejected() async throws {
        let f = try Fixtures()
        let src = try f.media("a.wav", args: ["-f", "lavfi", "-i", "sine=d=3"])
        for range in [(3.0, 1.0), (2.0, 2.0), (-1.0, 2.0)] {
            do { _ = try await run(.trim, src, trim: range); XCTFail("\(range) doveva fallire") }
            catch { XCTAssertTrue(error is ConversionError, "\(range)") }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.dir.path).count, 1, "nessun file creato")
    }

    func testTrimWithoutRangeMeansCancelled() async throws {
        let f = try Fixtures()
        let src = try f.media("a.wav", args: ["-f", "lavfi", "-i", "sine=d=3"])
        do { _ = try await run(.trim, src); XCTFail() } catch { XCTAssertTrue(error is ToolCancelled) }
    }

    func testTrimStartPastEndOfFileDoesNotLeaveEmptyFile() async throws {
        let f = try Fixtures()
        let src = try f.media("a.wav", args: ["-f", "lavfi", "-i", "sine=d=2"])
        do { _ = try await run(.trim, src, trim: (10, 12)); XCTFail("doveva fallire") } catch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.dir.path).count, 1)
    }

    // MARK: Time parsing

    func testParseTime() {
        XCTAssertEqual(Tools.parseTime("90"), 90)
        XCTAssertEqual(Tools.parseTime("1:30"), 90)
        XCTAssertEqual(Tools.parseTime("0:01:30.5"), 90.5)
        XCTAssertEqual(Tools.parseTime(" 2,5 "), 2.5, "virgola decimale italiana")
        XCTAssertEqual(Tools.parseTime("1:00:00"), 3600)
        for bad in ["", "abc", "1:2:3:4", "-5", "1::"] { XCTAssertNil(Tools.parseTime(bad), bad) }
    }

    func testFormatTime() {
        XCTAssertEqual(Tools.formatTime(0), "0:00")
        XCTAssertEqual(Tools.formatTime(75), "1:15")
        XCTAssertEqual(Tools.formatTime(3725), "1:02:05")
        XCTAssertEqual(Tools.parseTime(Tools.formatTime(3725)), 3725)
    }

    // MARK: Output folder and naming

    func testToolsHonourOutputFolderAndNeverOverwrite() async throws {
        let f = try Fixtures(), dest = try Fixtures()
        let src = try bigImage(f, w: 300, h: 300)
        let a = try await run(.resize1024, src, folder: dest.dir)
        let b = try await run(.resize1024, src, folder: dest.dir)
        XCTAssertEqual(a.deletingLastPathComponent().standardizedFileURL.path, dest.dir.standardizedFileURL.path)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(b.lastPathComponent, "big 1024px 2.png")
    }
}
