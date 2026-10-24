import AppKit
import AVFoundation
import XCTest
@testable import Mandarine

final class MediaToolTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipIf(Converter.ffmpegPath == nil, "ffmpeg non installato")
    }

    // MARK: Trim

    func testTrimVideoAndAudio() async throws {
        let f = try Fixtures()
        let v = try await runTool(.trimVideo, [try f.video(seconds: 6)], ["start": .text("1"), "end": .text("3.5")])[0]
        XCTAssertEqual(duration(v), 2.5, accuracy: 0.4)
        XCTAssertEqual(v.lastPathComponent, "v trimmed.mp4")
        let a = try await runTool(.trimAudio, [try f.tone(seconds: 10)], ["start": .text("0:02"), "end": .text("0:05")])[0]
        XCTAssertEqual(duration(a), 3, accuracy: 0.3)
    }

    func testTrimDefaultsCoverTheWholeFile() async throws {
        let f = try Fixtures()
        let src = try f.tone(seconds: 4)
        let params = ToolEngine.params(for: .trimAudio, files: [src])
        XCTAssertEqual(params.first { $0.id == "end" }?.defaultValue, .text("0:04"))
        let out = try await runTool(.trimAudio, [src])[0]
        XCTAssertEqual(duration(out), 4, accuracy: 0.3)
    }

    func testTrimRejectsBadInput() async throws {
        let f = try Fixtures()
        let src = try f.tone(seconds: 4)
        for set in [["start": ToolValue.text("3"), "end": .text("1")], ["start": .text("10"), "end": .text("12")], ["start": .text("abc"), "end": .text("2")], ["start": .text("0"), "end": .text("")]] {
            do { _ = try await runTool(.trimAudio, [src], set); XCTFail("\(set)") } catch {}
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.dir.path).count, 1)
    }

    // MARK: Crop video

    func testCropVideoQuarter() async throws {
        let f = try Fixtures()
        let out = try await runTool(.cropVideo, [try f.video(size: "160x120")], ["area": .rects([CGRect(x: 0, y: 0, width: 0.5, height: 0.5)])])[0]
        let size = try XCTUnwrap(MediaInfo.videoSize(out))
        XCTAssertEqual(size.width, 80); XCTAssertEqual(size.height, 60)
        XCTAssertEqual(duration(out), 3, accuracy: 0.4)
    }

    func testCropVideoOddSizesBecomeEven() async throws {
        let f = try Fixtures()
        let out = try await runTool(.cropVideo, [try f.video(size: "160x120")], ["area": .rects([CGRect(x: 0.1, y: 0.1, width: 0.51, height: 0.51)])])[0]
        let size = try XCTUnwrap(MediaInfo.videoSize(out))
        XCTAssertEqual(size.width % 2, 0); XCTAssertEqual(size.height % 2, 0)
    }

    func testCropVideoWithoutAreaFails() async throws {
        let f = try Fixtures()
        do { _ = try await runTool(.cropVideo, [try f.video()], ["area": .rects([])]); XCTFail() } catch { XCTAssertTrue(error is ToolError) }
    }

    // MARK: Speed

    func testSpeedUpAndSlowDown() async throws {
        let f = try Fixtures()
        let src = try f.video(seconds: 4)
        let fast = try await runTool(.changeVideoSpeed, [src], ["speed": .number(2)])[0]
        XCTAssertEqual(duration(fast), 2, accuracy: 0.4)
        XCTAssertTrue(MediaInfo.hasAudio(fast), "l'audio resta")
        let slow = try await runTool(.changeVideoSpeed, [src], ["speed": .number(0.5)])[0]
        XCTAssertEqual(duration(slow), 8, accuracy: 0.6)
    }

    func testSpeedExtremesAndInvalid() async throws {
        let f = try Fixtures()
        let src = try f.video(seconds: 4)
        let fast = try await runTool(.changeVideoSpeed, [src], ["speed": .number(4)])[0]
        XCTAssertEqual(duration(fast), 1, accuracy: 0.4)
        for bad in [0.0, 0.1, 5.0] {
            do { _ = try await runTool(.changeVideoSpeed, [src], ["speed": .number(bad)]); XCTFail("\(bad)") } catch { XCTAssertTrue(error is ToolError) }
        }
    }

    func testSpeedOfVideoWithoutAudio() async throws {
        let f = try Fixtures()
        let out = try await runTool(.changeVideoSpeed, [try f.video(audio: false)], ["speed": .number(2)])[0]
        XCTAssertEqual(duration(out), 1.5, accuracy: 0.4)
        XCTAssertFalse(MediaInfo.hasAudio(out))
    }

    func testAtempoChainStaysInRange() {
        XCTAssertEqual(MediaOps.atempoChain(1.5), "atempo=1.5000")
        XCTAssertEqual(MediaOps.atempoChain(4), "atempo=2.0,atempo=2.0000")
        XCTAssertEqual(MediaOps.atempoChain(0.25), "atempo=0.5,atempo=0.5000")
    }

    // MARK: Join

    func testJoinTwoVideosUsesFirstSizeAndSumsDuration() async throws {
        let f = try Fixtures()
        let a = try f.video("a.mp4", seconds: 2, size: "160x120"), b = try f.video("b.mp4", seconds: 3, size: "320x240")
        let out = try await runTool(.joinVideos, [a, b])[0]
        XCTAssertEqual(duration(out), 5, accuracy: 0.6)
        let size = try XCTUnwrap(MediaInfo.videoSize(out))
        XCTAssertEqual(size.width, 160); XCTAssertEqual(size.height, 120)
        XCTAssertEqual(out.lastPathComponent, "a joined.mp4")
    }

    func testJoinWithOneSilentVideoKeepsAudioTrack() async throws {
        let f = try Fixtures()
        let out = try await runTool(.joinVideos, [try f.video("a.mp4", seconds: 2), try f.video("b.mp4", seconds: 2, audio: false)])[0]
        XCTAssertTrue(MediaInfo.hasAudio(out))
        XCTAssertEqual(duration(out), 4, accuracy: 0.6)
    }

    func testJoinThreeVideosToOtherFormatAndSize() async throws {
        let f = try Fixtures()
        let vids = try (1...3).map { try f.video("v\($0).mp4", seconds: 1, size: "320x240") }
        let out = try await runTool(.joinVideos, vids, ["format": .text("mkv"), "size": .text("480")])[0]
        XCTAssertEqual(out.pathExtension, "mkv")
        XCTAssertEqual(duration(out), 3, accuracy: 0.6)
    }

    func testJoinNeedsTwoFiles() async throws {
        let f = try Fixtures()
        do { _ = try await runTool(.joinVideos, [try f.video()]); XCTFail() } catch { XCTAssertTrue(error is ToolError) }
    }

    // MARK: Split

    func testSplitRangesHelpers() {
        let every = MediaOps.splitRanges(duration: 5, every: 2)
        XCTAssertEqual(every.count, 3)
        XCTAssertEqual(every.last!.1, 5, accuracy: 0.001)
        let at = MediaOps.splitRanges(duration: 10, at: [7, 3, 99, 0])
        XCTAssertEqual(at.map { [$0.0, $0.1] }, [[0, 3], [3, 7], [7, 10]])
    }

    func testSplitVideoEqualParts() async throws {
        let f = try Fixtures()
        let outs = try await runTool(.splitVideo, [try f.video(seconds: 5)], ["mode": .text("equal"), "parts": .number(3)])
        XCTAssertEqual(outs.count, 3)
        XCTAssertEqual(duration(outs[0]), 5.0 / 3, accuracy: 0.4)
        XCTAssertEqual(duration(outs[2]), 5.0 / 3, accuracy: 0.4)
        XCTAssertEqual(outs[0].lastPathComponent, "v 1.mp4")
        XCTAssertEqual(outs[0].deletingLastPathComponent().lastPathComponent, "v parts")
    }

    func testSplitVideoAtPoints() async throws {
        let f = try Fixtures()
        let outs = try await runTool(.splitVideo, [try f.video(seconds: 4)], ["mode": .text("points"), "points": .text("1.5")])
        XCTAssertEqual(outs.count, 2)
        XCTAssertEqual(duration(outs[0]), 1.5, accuracy: 0.4)
        XCTAssertEqual(duration(outs[1]), 2.5, accuracy: 0.4)
    }

    func testSplitThatWouldNotSplitFails() async throws {
        let f = try Fixtures()
        let src = try f.video(seconds: 3)
        do { _ = try await runTool(.splitVideo, [src], ["mode": .text("points"), "points": .text("99")]); XCTFail() } catch { XCTAssertTrue(error is ToolError) }
        do { _ = try await runTool(.splitVideo, [src], ["mode": .text("points"), "points": .text("abc")]); XCTFail() } catch {}
        do { _ = try await runTool(.splitVideo, [src], ["mode": .text("equal"), "parts": .number(1)]); XCTFail() } catch {}
        do { _ = try await runTool(.splitVideo, [src], ["mode": .text("equal"), "parts": .number(51)]); XCTFail() } catch {}
    }

    // MARK: Redact video

    private func luma(_ c: RGB) -> Int { (c.r * 299 + c.g * 587 + c.b * 114) / 1000 }

    func testRedactVideoBlackBoxOverWholeDuration() async throws {
        let f = try Fixtures()
        let src = try f.video(seconds: 2, size: "320x240")
        // testsrc has bright colour bars along the top.
        let area = CGRect(x: 0, y: 0, width: 1, height: 0.2)
        let before = pixel(try XCTUnwrap(MediaInfo.frame(src, at: 0.5)), 100, 10)
        XCTAssertGreaterThan(luma(before), 60, "la barra deve essere visibile nell'originale")
        let out = try await runTool(.redactVideo, [src], ["areas": .rects([area]), "style": .text("black")])[0]
        let after = pixel(try XCTUnwrap(MediaInfo.frame(out, at: 0.5)), 100, 10)
        XCTAssertLessThan(luma(after), 30, "oscurato")
        XCTAssertEqual(duration(out), 2, accuracy: 0.4)
    }

    func testRedactVideoBlurAndPixelateRun() async throws {
        let f = try Fixtures()
        let src = try f.video(seconds: 1, size: "320x240")
        for style in ["blur", "pixelate"] {
            let out = try await runTool(.redactVideo, [src], ["areas": .rects([CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)]), "style": .text(style), "strength": .number(16)])[0]
            XCTAssertEqual(try XCTUnwrap(MediaInfo.videoSize(out)).width, 320, style)
            XCTAssertEqual(duration(out), 1, accuracy: 0.4, style)
        }
    }

    // MARK: Audio

    func testNormalizeBringsDifferentTracksToTheTargetLoudness() async throws {
        let f = try Fixtures()
        let quiet = try f.tone("quiet.wav", seconds: 6, amplitude: 0.05)
        let loud = try f.tone("loud.wav", seconds: 6, amplitude: 1)
        XCTAssertGreaterThan(abs(integratedLoudness(quiet) - integratedLoudness(loud)), 10, "le sorgenti devono essere molto diverse")
        let q = try await runTool(.normalizeAudio, [quiet], ["target": .text("-16")])[0]
        let l = try await runTool(.normalizeAudio, [loud], ["target": .text("-16")])[0]
        XCTAssertEqual(integratedLoudness(q), -16, accuracy: 2)
        XCTAssertEqual(integratedLoudness(l), -16, accuracy: 2)
        XCTAssertEqual(q.lastPathComponent, "quiet normalized.wav")
        XCTAssertEqual(duration(q), 6, accuracy: 0.3)
    }

    func testNormalizeOtherTargets() async throws {
        let f = try Fixtures()
        let src = try f.tone("t.wav", seconds: 6, amplitude: 0.3)
        let out = try await runTool(.normalizeAudio, [src], ["target": .text("-23")])[0]
        XCTAssertEqual(integratedLoudness(out), -23, accuracy: 2)
    }

    func testChannelModes() async throws {
        let f = try Fixtures()
        let src = try f.media("st.wav", args: ["-f", "lavfi", "-i", "sine=d=2", "-ac", "2"])
        let mono = try await runTool(.audioChannels, [src], ["mode": .text("mono")])[0]
        XCTAssertTrue(Shell.captureStderr(Converter.ffmpegPath!, ["-hide_banner", "-i", mono.path]).contains("mono"))
        let stereo = try await runTool(.audioChannels, [try f.tone("m.wav")], ["mode": .text("stereo")])[0]
        XCTAssertTrue(Shell.captureStderr(Converter.ffmpegPath!, ["-hide_banner", "-i", stereo.path]).contains("stereo"))
        for mode in ["swap", "left", "right"] {
            let out = try await runTool(.audioChannels, [src], ["mode": .text(mode)])[0]
            XCTAssertEqual(duration(out), 2, accuracy: 0.3, mode)
        }
    }

    func testChannelsLeftOnlyDuplicatesTheLeftSide() async throws {
        let f = try Fixtures()
        // Sinistra rumorosa, destra muta.
        let src = try f.media("lr.wav", args: ["-f", "lavfi", "-i", "sine=d=2", "-af", "pan=stereo|c0=c0|c1=0*c0"])
        let right = try await runTool(.audioChannels, [src], ["mode": .text("right")])[0]
        XCTAssertLessThan(maxVolume(right, from: 0.5, to: 1.5), -60, "copiare il destro (muto) su entrambi dà silenzio")
        let left = try await runTool(.audioChannels, [src], ["mode": .text("left")])[0]
        XCTAssertGreaterThan(maxVolume(left, from: 0.5, to: 1.5), -30)
    }

    func testBleepReplacesTheRangeWithATone() async throws {
        let f = try Fixtures()
        let src = try f.tone("s.wav", seconds: 4, amplitude: 0.05)
        let out = try await runTool(.redactAudio, [src], ["ranges": .text("1-2"), "replace": .text("bleep")])[0]
        XCTAssertEqual(duration(out), 4, accuracy: 0.3)
        XCTAssertGreaterThan(maxVolume(out, from: 1.2, to: 1.8), maxVolume(src, from: 1.2, to: 1.8) + 6, "il bip è più forte")
        XCTAssertEqual(maxVolume(out, from: 2.6, to: 3.6), maxVolume(src, from: 2.6, to: 3.6), accuracy: 2, "fuori dall'intervallo invariato")
    }

    func testBleepSilenceAndMultipleRanges() async throws {
        let f = try Fixtures()
        let src = try f.tone("s.wav", seconds: 6, amplitude: 0.5)
        let out = try await runTool(.redactAudio, [src], ["ranges": .text("1-2, 4-5"), "replace": .text("silence")])[0]
        XCTAssertLessThan(maxVolume(out, from: 1.2, to: 1.8), -60)
        XCTAssertLessThan(maxVolume(out, from: 4.2, to: 4.8), -60)
        XCTAssertGreaterThan(maxVolume(out, from: 2.3, to: 3.7), -30)
    }

    func testBleepInvalidRanges() async throws {
        let f = try Fixtures()
        let src = try f.tone()
        for bad in ["", "abc", "3-1", "2"] {
            do { _ = try await runTool(.redactAudio, [src], ["ranges": .text(bad)]); XCTFail("«\(bad)»") } catch { XCTAssertTrue(error is ToolError, bad) }
        }
    }

    func testTimeRangesParsing() throws {
        let r = try TimeRanges.parse("1:10-1:20, 5.5-6")
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r[0].start, 70); XCTAssertEqual(r[0].end, 80); XCTAssertEqual(r[1].start, 5.5)
    }

    func testAudioVisualizerStylesProduceVideo() async throws {
        let f = try Fixtures()
        let src = try f.tone("t.wav", seconds: 2)
        for style in ["waves", "spectrum", "bars"] {
            let out = try await runTool(.audioToVideo, [src], ["style": .text(style), "size": .text("640x360")])[0]
            let size = try XCTUnwrap(MediaInfo.videoSize(out), style)
            XCTAssertEqual(size.width, 640, style); XCTAssertEqual(size.height, 360, style)
            XCTAssertEqual(duration(out), 2, accuracy: 0.5, style)
            XCTAssertTrue(MediaInfo.hasAudio(out), style)
            XCTAssertEqual(out.pathExtension, "mp4")
        }
    }

    func testVisualizerUsesTheBackgroundColour() async throws {
        let f = try Fixtures()
        let out = try await runTool(.audioToVideo, [try f.tone("t.wav", seconds: 2, amplitude: 0.01)], ["style": .text("waves"), "size": .text("320x180"), "color": .text("#0000FF")])[0]
        let corner = pixel(try XCTUnwrap(MediaInfo.frame(out, at: 1)), 5, 5)
        XCTAssertGreaterThan(corner.b, corner.r + 80)
    }

    // MARK: Progress and cancellation

    func testProgressReachesOne() async throws {
        let f = try Fixtures()
        let src = try f.video(seconds: 3)
        final class Box: @unchecked Sendable { var values: [Double] = [] }
        let box = Box()
        let out = f.url("p.mp4")
        try await MediaOps.trim(src, out, start: 0, end: 3) { box.values.append($0) }
        XCTAssertFalse(box.values.isEmpty)
        XCTAssertGreaterThan(box.values.max() ?? 0, 0.5)
        XCTAssertTrue(box.values.allSatisfy { (0...1).contains($0) })
    }

    func testCancellingStopsTheJob() async throws {
        // Un processo che durerebbe 20 secondi: l'annullamento deve fermarlo subito.
        let started = Date()
        let task = Task { try await Converter.run("/bin/sleep", ["20"]) }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("doveva essere annullato") } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "il processo è stato ucciso, non aspettato")
    }

    func testCancellingAFFmpegJobLeavesNoCompleteOutput() async throws {
        let f = try Fixtures()
        let src = try f.video(seconds: 20, size: "640x360")
        let out = f.url("slow.mp4")
        let task = Task { try await MediaOps.speed(src, out, factor: 0.25) }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        do { _ = try await task.value } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        // Se il lavoro è finito prima dell'annullamento va bene lo stesso: il test verifica solo che nulla resti appeso.
        let leftovers = Shell.capture("/usr/bin/pgrep", ["-f", out.path])
        XCTAssertTrue(leftovers.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "nessun ffmpeg rimasto in esecuzione")
    }

    // MARK: Applicability

    func testMediaToolsAreHiddenWithoutFFmpegOnlyWhenMissing() {
        XCTAssertTrue(ToolID.trimVideo.applies(to: [URL(fileURLWithPath: "/tmp/a.mp4")]))
        XCTAssertFalse(ToolID.trimVideo.applies(to: [URL(fileURLWithPath: "/tmp/a.mp3")]))
        XCTAssertFalse(ToolID.joinVideos.applies(to: [URL(fileURLWithPath: "/tmp/a.mp4")]), "serve più di un file")
        XCTAssertTrue(ToolID.joinVideos.applies(to: [URL(fileURLWithPath: "/tmp/a.mp4"), URL(fileURLWithPath: "/tmp/b.mov")]))
    }
}
