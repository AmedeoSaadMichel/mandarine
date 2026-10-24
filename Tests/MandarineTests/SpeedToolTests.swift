import AVFoundation
import XCTest
@testable import Mandarine

/// Positive-going zero crossings per second of the first audio channel: a good pitch estimate for a sine.
func dominantFrequency(_ url: URL) -> Double {
    guard let ff = Converter.ffmpegPath else { return 0 }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: ff)
    p.arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-i", url.path, "-vn", "-ac", "1", "-ar", "8000", "-f", "s16le", "-"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return 0 }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    guard samples.count > 8000 else { return 0 }
    var crossings = 0
    for i in 1..<samples.count where samples[i - 1] < 0 && samples[i] >= 0 { crossings += 1 }
    return Double(crossings) / (Double(samples.count) / 8000)
}

final class SpeedMathTests: XCTestCase {
    func testPresetsAreInsideTheRange() {
        XCTAssertEqual(SpeedMath.presets, [0.25, 0.5, 1, 1.5, 2, 4])
        XCTAssertTrue(SpeedMath.presets.allSatisfy { SpeedMath.range.contains($0) })
    }

    func testClampAndNewLength() {
        XCTAssertEqual(SpeedMath.clamp(0.01), 0.25); XCTAssertEqual(SpeedMath.clamp(99), 4); XCTAssertEqual(SpeedMath.clamp(2), 2)
        XCTAssertEqual(SpeedMath.newLength(duration: 20, factor: 2), 10)
        XCTAssertEqual(SpeedMath.newLength(duration: 20, factor: 0.5), 40)
        XCTAssertEqual(SpeedMath.newLength(duration: 20, factor: 0), 20 / 0.0001, accuracy: 1, "mai una divisione per zero")
    }

    func testLabels() {
        XCTAssertEqual(SpeedMath.label(2), "2×"); XCTAssertEqual(SpeedMath.label(0.25), "0.25×"); XCTAssertEqual(SpeedMath.label(1.5), "1.5×"); XCTAssertEqual(SpeedMath.label(4), "4×")
    }

    func testAudioFilters() {
        XCTAssertEqual(MediaOps.speedAudioFilter(factor: 1.5, preservePitch: true), "atempo=1.5000")
        XCTAssertEqual(MediaOps.speedAudioFilter(factor: 2, preservePitch: false), "aresample=48000,asetrate=96000.0,aresample=48000")
        XCTAssertTrue(MediaOps.speedAudioFilter(factor: 0.5, preservePitch: false).contains("asetrate=24000.0"))
    }
}

@MainActor
final class SpeedToolTests: XCTestCase {
    override func setUpWithError() throws { try XCTSkipIf(Converter.ffmpegPath == nil, "ffmpeg non installato") }

    // MARK: Engine

    func testPreservePitchKeepsTheNote() async throws {
        let f = try Fixtures()
        let src = try f.video(seconds: 4)
        XCTAssertEqual(dominantFrequency(src), 440, accuracy: 25, "la sorgente è un LA a 440 Hz")
        let out = try await runTool(.changeVideoSpeed, [src], ["speed": .number(2), "preservePitch": .bool(true)])[0]
        XCTAssertEqual(duration(out), 2, accuracy: 0.4)
        XCTAssertEqual(dominantFrequency(out), 440, accuracy: 40)
    }

    func testWithoutPreservePitchTheNoteFollowsTheSpeed() async throws {
        let f = try Fixtures()
        let src = try f.video(seconds: 4)
        let fast = try await runTool(.changeVideoSpeed, [src], ["speed": .number(2), "preservePitch": .bool(false)])[0]
        XCTAssertEqual(duration(fast), 2, accuracy: 0.4)
        XCTAssertEqual(dominantFrequency(fast), 880, accuracy: 70, "il doppio più veloce suona un'ottava sopra")
        let slow = try await runTool(.changeVideoSpeed, [src], ["speed": .number(0.5), "preservePitch": .bool(false)])[0]
        XCTAssertEqual(duration(slow), 8, accuracy: 0.8)
        XCTAssertEqual(dominantFrequency(slow), 220, accuracy: 25, "metà velocità: un'ottava sotto")
    }

    func testPreservePitchIsTheDefault() throws {
        let f = try Fixtures()
        let p = ToolEngine.params(for: .changeVideoSpeed, files: [try f.video(seconds: 1)])
        XCTAssertEqual(p.first { $0.id == "preservePitch" }?.defaultValue, .bool(true))
        XCTAssertTrue(p.allSatisfy(\.custom), "le schede della velocità sono dedicate")
    }

    func testVideoWithoutAudioIgnoresThePitchOption() async throws {
        let f = try Fixtures()
        let out = try await runTool(.changeVideoSpeed, [try f.video(audio: false)], ["speed": .number(2), "preservePitch": .bool(false)])[0]
        XCTAssertEqual(duration(out), 1.5, accuracy: 0.4)
        XCTAssertFalse(MediaInfo.hasAudio(out))
    }

    func testEverySpeedPresetProducesTheRightLength() async throws {
        let f = try Fixtures()
        let src = try f.video(seconds: 4)
        for factor in SpeedMath.presets {
            let out = try await runTool(.changeVideoSpeed, [src], ["speed": .number(factor)])[0]
            XCTAssertEqual(duration(out), 4 / factor, accuracy: max(0.35, 0.1 * 4 / factor), "×\(factor)")
        }
    }

    // MARK: Session and player

    func testSpeedWindowHasPlayerAndNoGenericCards() async throws {
        let f = try Fixtures()
        let s = ToolSession(tool: .changeVideoSpeed, files: [try f.video(seconds: 2)])
        XCTAssertNotNil(s.trimPlayer)
        XCTAssertTrue(s.sidebarSections.isEmpty, "velocità e audio hanno schede proprie")
        XCTAssertTrue(s.hasAudio)
        XCTAssertFalse(ToolSession(tool: .changeVideoSpeed, files: [try f.video("n.mp4", seconds: 1, audio: false)]).hasAudio)
    }

    func testPreviewPlaysAtTheChosenFactor() async throws {
        let f = try Fixtures()
        let p = TrimPlayer(url: try f.video(seconds: 6), hasVideo: true)
        await p.prepare()
        XCTAssertTrue(p.ready)
        p.playbackRate = 4
        p.play()
        XCTAssertEqual(p.player.rate, 4, accuracy: 0.01)
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertGreaterThan(p.playhead, 2.5, "a 4× in 1,2 s avanza di oltre 2,5 s")
        p.pause()
        p.playbackRate = 1
        p.seek(to: 0); p.play()
        XCTAssertEqual(p.player.rate, 1, accuracy: 0.01)
        p.pause()
    }

    func testRateChangeWhilePlayingIsApplied() async throws {
        let f = try Fixtures()
        let p = TrimPlayer(url: try f.video(seconds: 6), hasVideo: true)
        await p.prepare()
        p.play()
        p.playbackRate = 2
        XCTAssertEqual(p.player.rate, 2, accuracy: 0.01)
        p.pause()
    }

    func testPitchAlgorithmFollowsTheOption() async throws {
        let f = try Fixtures()
        let p = TrimPlayer(url: try f.video(seconds: 2), hasVideo: true)
        await p.prepare()
        let natural: [AVAudioTimePitchAlgorithm] = [.spectral, .timeDomain]       // entrambi mantengono l'intonazione
        XCTAssertTrue(natural.contains(try XCTUnwrap(p.player.currentItem?.audioTimePitchAlgorithm)), "dopo prepare")
        p.preservePitch = false
        XCTAssertEqual(p.player.currentItem?.audioTimePitchAlgorithm, .varispeed, "intonazione spenta")
        p.preservePitch = true
        XCTAssertTrue(natural.contains(try XCTUnwrap(p.player.currentItem?.audioTimePitchAlgorithm)), "intonazione riaccesa")
    }

    func testSpeedSessionRunsWithTheChosenValues() async throws {
        let f = try Fixtures()
        let s = ToolSession(tool: .changeVideoSpeed, files: [try f.video(seconds: 4)])
        let p = try XCTUnwrap(s.trimPlayer)
        for _ in 0..<80 where !p.ready { try await Task.sleep(nanoseconds: 100_000_000) }
        s.setSpeedFactor(2)
        s.run()
        for _ in 0..<200 where s.running || (s.results.isEmpty && s.errorMessage == nil) { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertNil(s.errorMessage)
        XCTAssertEqual(duration(try XCTUnwrap(s.results.first)), 2, accuracy: 0.4)
    }
}
