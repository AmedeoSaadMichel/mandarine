import AppKit
import ImageIO
import XCTest
@testable import Mandarine

final class SettingsJobTests: XCTestCase {
    private func freshSettings(_ name: String = #function) -> (Settings, UserDefaults) {
        let suite = "mandarine.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        addTeardownBlock { d.removePersistentDomain(forName: suite) }
        return (Settings(defaults: d), d)
    }

    // MARK: Settings

    func testDefaults() {
        let (s, _) = freshSettings()
        XCTAssertEqual(s.conversionModifier, .shift); XCTAssertEqual(s.toolsModifier, .command); XCTAssertEqual(s.actionsModifier, .control)
        XCTAssertEqual(s.quality, .balanced)
        XCTAssertTrue(s.soundEnabled); XCTAssertTrue(s.hapticEnabled)
        XCTAssertEqual(s.appearance, .glass); XCTAssertEqual(s.progressStyle, .floating)
        XCTAssertEqual(s.outputLocation, .beside); XCTAssertNil(s.outputFolder)
        XCTAssertTrue(s.excludedApps.isEmpty); XCTAssertTrue(s.terminalAppPath.hasSuffix("Terminal.app"))
    }

    func testEverySettingPersistsAcrossInstances() {
        let (s, d) = freshSettings()
        s.conversionModifier = .option; s.toolsModifier = .shift; s.actionsModifier = .command
        s.quality = .strong; s.soundEnabled = false; s.hapticEnabled = false
        s.appearance = .solid; s.progressStyle = .notch; s.outputLocation = .desktop
        s.terminalAppPath = "/Applications/iTerm.app"; s.outputFolderPath = "/tmp/out"
        s.exclude("com.example.app")
        let again = Settings(defaults: d)
        XCTAssertEqual(again.conversionModifier, .option); XCTAssertEqual(again.toolsModifier, .shift); XCTAssertEqual(again.actionsModifier, .command)
        XCTAssertEqual(again.quality, .strong); XCTAssertFalse(again.soundEnabled); XCTAssertFalse(again.hapticEnabled)
        XCTAssertEqual(again.appearance, .solid); XCTAssertEqual(again.progressStyle, .notch); XCTAssertEqual(again.outputLocation, .desktop)
        XCTAssertEqual(again.terminalAppPath, "/Applications/iTerm.app"); XCTAssertEqual(again.outputFolderPath, "/tmp/out")
        XCTAssertEqual(again.excludedApps, ["com.example.app"])
    }

    func testFormatPrefsFallBackToTheDefaultQualityAndPersist() {
        let (s, d) = freshSettings()
        s.quality = .strong
        XCTAssertEqual(s.prefs(for: "jpg"), FormatPrefs(quality: .strong))
        XCTAssertFalse(s.hasCustomPrefs(for: "jpg"))
        s.setPrefs(FormatPrefs(quality: .best, preserveMetadata: false, maxDimension: 1920), for: "JPEG")
        XCTAssertTrue(s.hasCustomPrefs(for: "jpg"), "jpeg e jpg sono lo stesso formato")
        XCTAssertEqual(s.prefs(for: "jpg").maxDimension, 1920)
        XCTAssertEqual(s.prefs(for: "png"), FormatPrefs(quality: .strong), "gli altri formati non cambiano")
        let again = Settings(defaults: d)
        XCTAssertEqual(again.prefs(for: "jpg"), FormatPrefs(quality: .best, preserveMetadata: false, maxDimension: 1920))
        again.restoreDefaults(for: "jpg")
        XCTAssertFalse(again.hasCustomPrefs(for: "jpg"))
        XCTAssertFalse(Settings(defaults: d).hasCustomPrefs(for: "jpg"))
    }

    func testCorruptedStoredPrefsAreIgnored() {
        let (_, d) = freshSettings()
        d.set(Data("non json".utf8), forKey: "formatPrefs")
        XCTAssertNoThrow(Settings(defaults: d).prefs(for: "jpg"))
    }

    func testExcludedApps() {
        let (s, _) = freshSettings()
        XCTAssertFalse(s.isExcluded("com.apple.finder")); XCTAssertFalse(s.isExcluded(nil))
        s.exclude("com.apple.finder"); s.exclude("com.apple.finder")
        XCTAssertEqual(s.excludedApps, ["com.apple.finder"], "nessun duplicato")
        XCTAssertTrue(s.isExcluded("com.apple.finder"))
        s.include("com.apple.finder")
        XCTAssertFalse(s.isExcluded("com.apple.finder"))
    }

    func testWheelForModifierWithConflicts() {
        let (s, _) = freshSettings()
        s.toolsModifier = .shift
        XCTAssertEqual(s.wheel(for: .shift), .conversion, "con un conflitto vince la prima ruota")
        XCTAssertNil(s.wheel(for: .option))
    }

    // MARK: Format catalogue

    func testCatalogueCoversEveryConvertibleFormat() {
        let all = Set(FormatCatalog.groups.flatMap(\.extensions))
        for cat in Category.allCases { for ext in cat.extensions { XCTAssertTrue(all.contains(ext), "\(ext) manca dal catalogo") } }
    }

    func testFormatOptions() {
        XCTAssertEqual(FormatCatalog.options(for: "jpg"), .init(quality: true, metadata: true, size: true))
        XCTAssertEqual(FormatCatalog.options(for: "png"), .init(quality: false, metadata: true, size: true))
        XCTAssertEqual(FormatCatalog.options(for: "mp3"), .init(quality: true, metadata: false, size: false))
        XCTAssertEqual(FormatCatalog.options(for: "mp4"), .init(quality: true, metadata: false, size: false))
        XCTAssertEqual(FormatCatalog.options(for: "pdf"), .init(quality: false, metadata: false, size: false))
        XCTAssertEqual(FormatCatalog.options(for: "JPEG"), FormatCatalog.options(for: "jpg"))
    }

    func testCompatibilityReport() {
        let none = CompatibilityReport.build(ffmpegPath: nil, encoders: [])
        XCTAssertFalse(none.first { $0.name == "ffmpeg" }!.ok)
        XCTAssertTrue(none.first { $0.name == "ffmpeg" }!.detail.contains("Reinstall Mandarine"))
        XCTAssertFalse(none.first { $0.name == "MP3" }!.ok)
        XCTAssertTrue(none.last!.ok, "le funzioni di sistema non dipendono da ffmpeg")
        let full = CompatibilityReport.build(ffmpegPath: "/opt/homebrew/bin/ffmpeg", encoders: ["libmp3lame", "libx264", "vorbis"])
        XCTAssertTrue(full.first { $0.name == "MP3" }!.ok)
        XCTAssertTrue(full.first { $0.name == "Ogg Vorbis" }!.ok, "vale anche l'encoder vorbis sperimentale")
        XCTAssertFalse(full.first { $0.name == "WebP" }!.ok)
        XCTAssertTrue(full.first { $0.name == "WebP" }!.detail.contains("ffmpeg"))
    }

    // MARK: Job runner

    private func tmp(_ names: String...) -> [URL] { names.map { URL(fileURLWithPath: "/tmp/\($0)") } }

    func testExecuteRunsEveryFile() async {
        let files = tmp("a", "b", "c")
        let summary = await JobRunner.execute(files: files) { f, _ in [f.appendingPathExtension("out")] }
        XCTAssertEqual(summary.total, 3); XCTAssertEqual(summary.outputs.count, 3)
        XCTAssertFalse(summary.hasFailures); XCTAssertFalse(summary.cancelled)
        XCTAssertEqual(summary.succeeded, 3)
    }

    func testOneFailureDoesNotStopTheOthers() async {
        struct Boom: LocalizedError { var errorDescription: String? { "esploso" } }
        let summary = await JobRunner.execute(files: tmp("a", "b", "c")) { f, _ in
            if f.lastPathComponent == "b" { throw Boom() }
            return [f]
        }
        XCTAssertEqual(summary.outputs.count, 2)
        XCTAssertEqual(summary.failures, [.init(file: "b", message: "esploso")])
        XCTAssertEqual(summary.succeeded, 2)
    }

    func testAllFailing() async {
        let summary = await JobRunner.execute(files: tmp("a", "b")) { _, _ in throw ConversionError(message: "no") }
        XCTAssertEqual(summary.failures.count, 2); XCTAssertEqual(summary.succeeded, 0); XCTAssertTrue(summary.outputs.isEmpty)
    }

    func testCancellationStopsTheBatch() async {
        final class Counter: @unchecked Sendable { var n = 0 }
        let counter = Counter()
        let task = Task { await JobRunner.execute(files: self.tmp("a", "b", "c", "d")) { f, _ in
            counter.n += 1
            if counter.n == 2 { throw CancellationError() }
            return [f]
        } }
        let summary = await task.value
        XCTAssertTrue(summary.cancelled)
        XCTAssertEqual(counter.n, 2, "dopo l'annullamento non si prosegue")
        XCTAssertEqual(summary.outputs.count, 1)
    }

    func testTaskCancelBeforeStartCancelsEverything() async {
        let task = Task { () -> JobSummary in
            try? await Task.sleep(nanoseconds: 50_000_000)
            return await JobRunner.execute(files: self.tmp("a", "b")) { f, _ in [f] }
        }
        task.cancel()
        let summary = await task.value
        XCTAssertTrue(summary.cancelled)
        XCTAssertTrue(summary.outputs.isEmpty)
    }

    func testProgressIsMonotonicAndEndsAtOne() async {
        final class Log: @unchecked Sendable { var fractions: [Double] = []; var names: [String] = []; let lock = NSLock()
            func add(_ f: Double, _ n: String) { lock.lock(); fractions.append(f); names.append(n); lock.unlock() } }
        let log = Log()
        _ = await JobRunner.execute(files: tmp("a", "b")) { f, progress in
            progress(0.5); progress(1)
            return [f]
        } onUpdate: { _, name, fraction in log.add(fraction, name) }
        XCTAssertEqual(log.fractions.last, 1)
        XCTAssertEqual(log.fractions, log.fractions.sorted(), "l'avanzamento non torna indietro")
        XCTAssertTrue(log.fractions.contains(0.25) && log.fractions.contains(0.75), "mezzo file = metà della sua quota: \(log.fractions)")
        XCTAssertTrue(log.names.contains("a") && log.names.contains("b"))
    }

    func testProgressValuesAreClamped() async {
        final class Log: @unchecked Sendable { var fractions: [Double] = []; let lock = NSLock() }
        let log = Log()
        _ = await JobRunner.execute(files: tmp("a")) { f, progress in progress(-3); progress(7); return [f] } onUpdate: { _, _, f in log.lock.lock(); log.fractions.append(f); log.lock.unlock() }
        XCTAssertTrue(log.fractions.allSatisfy { (0...1).contains($0) })
    }

    func testEmptyBatch() async {
        let summary = await JobRunner.execute(files: []) { f, _ in [f] }
        XCTAssertEqual(summary.total, 0); XCTAssertFalse(summary.hasFailures)
    }

    @MainActor
    func testRunnerStateMachine() async throws {
        let runner = JobRunner()
        XCTAssertEqual(runner.state, .idle)
        runner.start(title: "Prova", files: tmp("a", "b")) { f, _ in [f] }
        XCTAssertTrue(runner.isRunning)
        for _ in 0..<50 where runner.isRunning { try await Task.sleep(nanoseconds: 50_000_000) }
        guard case .finished(let title, let summary) = runner.state else { return XCTFail("\(runner.state)") }
        XCTAssertEqual(title, "Prova"); XCTAssertEqual(summary.outputs.count, 2)
        runner.dismiss()
        XCTAssertEqual(runner.state, .idle)
    }

    @MainActor
    func testRunnerKeepsFirstJobActiveWhileSecondIsQueued() async throws {
        let runner = JobRunner()
        runner.start(title: "Lungo", files: tmp("a")) { f, _ in try await Task.sleep(nanoseconds: 300_000_000); return [f] }
        runner.start(title: "Intruso", files: tmp("b")) { f, _ in [f] }
        guard case .running(let title, _, _, _, _) = runner.state else { return XCTFail() }
        XCTAssertEqual(title, "Lungo")
        XCTAssertEqual(runner.queuedCount, 1)
        runner.cancel()
        for _ in 0..<50 where runner.isRunning { try await Task.sleep(nanoseconds: 50_000_000) }
        runner.dismiss()
    }

    @MainActor
    func testRunnerCancelProducesACancelledSummary() async throws {
        let runner = JobRunner()
        runner.start(title: "Lungo", files: tmp("a", "b")) { f, _ in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return [f]
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        runner.cancel()
        for _ in 0..<60 where runner.isRunning { try await Task.sleep(nanoseconds: 50_000_000) }
        guard case .finished(_, let summary) = runner.state else { return XCTFail("\(runner.state)") }
        XCTAssertTrue(summary.cancelled)
        runner.dismiss()
    }

    // MARK: Conversions honour the per-format settings

    func testMaxDimensionLimitsConvertedImages() async throws {
        let f = try Fixtures()
        let src = try f.quadrants(width: 400, height: 200)
        let out = try await Converter.convert(src, to: "jpg", outputFolder: nil, quality: .balanced, prefs: FormatPrefs(maxDimension: 100))
        XCTAssertEqual(try imageSize(out).0, 100); XCTAssertEqual(try imageSize(out).1, 50)
        let keep = try await Converter.convert(src, to: "png", outputFolder: nil, quality: .balanced, prefs: FormatPrefs(maxDimension: 0))
        XCTAssertEqual(try imageSize(keep).0, 400)
        let small = try f.quadrants("small.png", width: 50, height: 20)
        let noUpscale = try await Converter.convert(small, to: "jpg", outputFolder: nil, quality: .balanced, prefs: FormatPrefs(maxDimension: 100))
        XCTAssertEqual(try imageSize(noUpscale).0, 50, "non ingrandisce")
    }

    func testPreserveMetadataSwitch() async throws {
        let f = try Fixtures()
        let base = try f.quadrants("src.png")
        let tagged = f.url("tagged.jpg")
        let img = try ImageOps.load(base).image
        let dest = CGImageDestinationCreateWithURL(tagged as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "Anna"], kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "nota"],
                                               kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 45.0, kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitude: 9.0, kCGImagePropertyGPSLongitudeRef: "E"]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let kept = try await Converter.convert(tagged, to: "png", outputFolder: nil, quality: .balanced, prefs: FormatPrefs(preserveMetadata: true))
        XCTAssertEqual(MetadataOps.read(kept)["artist"], "Anna")
        XCTAssertEqual(MetadataOps.read(kept)["comment"], "nota")
        let dropped = try await Converter.convert(tagged, to: "heic", outputFolder: nil, quality: .balanced, prefs: FormatPrefs(preserveMetadata: false))
        XCTAssertTrue(MetadataOps.read(dropped).isEmpty, "metadati rimossi")
        XCTAssertFalse(MetadataOps.hasGPS(dropped))
    }

    func testQualityLevelsChangeTheFileSize() async throws {
        let f = try Fixtures()
        let noisy = try f.media("n.png", args: ["-f", "lavfi", "-i", "nullsrc=s=500x500,geq=random(1)*255:random(2)*255:random(3)*255", "-frames:v", "1"])
        var sizes: [Int] = []
        for q in [Quality.best, .balanced, .strong] {
            let out = try await Converter.convert(noisy, to: "jpg", outputFolder: f.dir, quality: q, prefs: FormatPrefs(quality: q))
            sizes.append(try Data(contentsOf: out).count)
        }
        XCTAssertGreaterThan(sizes[0], sizes[1]); XCTAssertGreaterThan(sizes[1], sizes[2])
    }

    func testTransparentImagesBecomeWhiteInJPEG() async throws {
        let f = try Fixtures()
        let ctx = ImageOps.context(20, 20)           // fully transparent
        let src = f.url("clear.png")
        try ImageOps.write(ctx.makeImage()!, to: src, ext: "png")
        let jpg = try await Converter.convert(src, to: "jpg", outputFolder: nil, quality: .best)
        let p = try pixel(jpg, 10, 10)
        XCTAssertGreaterThan(p.r, 240); XCTAssertGreaterThan(p.g, 240); XCTAssertGreaterThan(p.b, 240)
        let png = try await Converter.convert(src, to: "tiff", outputFolder: nil, quality: .best)
        XCTAssertNotNil(NSImage(contentsOf: png))
    }

    func testImageToPDFAndGIFAndBMP() async throws {
        let f = try Fixtures()
        let src = try f.quadrants()
        for ext in ["pdf", "gif", "bmp", "tiff", "heic"] {
            let out = try await Converter.convert(src, to: ext, outputFolder: nil, quality: .balanced)
            XCTAssertGreaterThan(try Data(contentsOf: out).count, 0, ext)
        }
    }

    func testConversionProgressReachesOneForMedia() async throws {
        try XCTSkipIf(Converter.ffmpegPath == nil)
        final class Box: @unchecked Sendable { var values: [Double] = [] }
        let box = Box()
        let f = try Fixtures()
        _ = try await Converter.convert(try f.tone("t.wav", seconds: 3), to: "mp3", outputFolder: nil, quality: .balanced) { box.values.append($0) }
        XCTAssertFalse(box.values.isEmpty)
        XCTAssertTrue(box.values.allSatisfy { (0...1).contains($0) })
    }

    func testWheelConversionItemUsesThePerFormatPrefs() async throws {
        let f = try Fixtures()
        let src = try f.quadrants(width: 400, height: 200)
        let s = Settings.shared
        let old = (s.prefs(for: "jpg"), s.hasCustomPrefs(for: "jpg"), s.outputFolderPath, s.outputLocation)
        defer {
            if old.1 { s.setPrefs(old.0, for: "jpg") } else { s.restoreDefaults(for: "jpg") }
            s.outputFolderPath = old.2; s.outputLocation = old.3
        }
        s.outputFolderPath = ""; s.outputLocation = .beside
        s.setPrefs(FormatPrefs(maxDimension: 100), for: "jpg")
        let item = try XCTUnwrap(WheelBuilder.items(kind: .conversion, files: [src]).first { $0.title == "JPG" })
        let outs = try await XCTUnwrap(item.runWithProgress)(src) { _ in }
        XCTAssertEqual(outs.count, 1)
        XCTAssertEqual(try imageSize(outs[0]).0, 100)
    }
}
