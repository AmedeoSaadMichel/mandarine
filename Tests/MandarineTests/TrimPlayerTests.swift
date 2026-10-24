import AVFoundation
import XCTest
@testable import Mandarine

final class TrimRangeTests: XCTestCase {
    func testStartsAsTheWholeClip() {
        let r = TrimRange(duration: 10)
        XCTAssertEqual(r.start, 0); XCTAssertEqual(r.end, 10); XCTAssertEqual(r.length, 10); XCTAssertTrue(r.isWholeClip)
    }

    func testSetStartAndEndClamp() {
        var r = TrimRange(duration: 10)
        r.setStart(-5); XCTAssertEqual(r.start, 0)
        r.setStart(4); XCTAssertEqual(r.start, 4); XCTAssertFalse(r.isWholeClip)
        r.setEnd(99); XCTAssertEqual(r.end, 10)
        r.setEnd(7); XCTAssertEqual(r.end, 7)
        r.setStart(20); XCTAssertEqual(r.start, 7 - TrimRange.minLength, accuracy: 1e-9, "l'inizio non supera la fine")
        r.setEnd(0); XCTAssertEqual(r.end, r.start + TrimRange.minLength, accuracy: 1e-9, "la fine non scende sotto l'inizio")
    }

    func testEndNeverExceedsDurationEvenNearTheEnd() {
        var r = TrimRange(duration: 1)
        r.setStart(0.95)
        XCTAssertLessThanOrEqual(r.end, 1)
        XCTAssertGreaterThanOrEqual(r.end, r.start)
    }

    func testIgnoresInvalidNumbers() {
        var r = TrimRange(duration: 10)
        r.setStart(.nan); r.setEnd(.infinity); r.setEnd(-.infinity)
        XCTAssertEqual(r.start, 0); XCTAssertEqual(r.end, 10)
    }

    func testEmptyClipIsSafe() {
        var r = TrimRange(duration: 0)
        r.setStart(1); r.setEnd(1)
        XCTAssertEqual(r.start, 0); XCTAssertEqual(r.end, 0)
        XCTAssertEqual(TrimRange(duration: -3).duration, 0)
    }

    func testContainsAndClamp() {
        var r = TrimRange(duration: 10); r.setStart(2); r.setEnd(6)
        XCTAssertTrue(r.contains(2)); XCTAssertTrue(r.contains(6)); XCTAssertTrue(r.contains(4))
        XCTAssertFalse(r.contains(1.9)); XCTAssertFalse(r.contains(6.1))
        XCTAssertEqual(r.clamp(-1), 0); XCTAssertEqual(r.clamp(99), 10); XCTAssertEqual(r.clamp(3), 3)
    }

    func testPlaybackStartsInsideTheSelectionOrAtItsStart() {
        var r = TrimRange(duration: 10); r.setStart(2); r.setEnd(6)
        XCTAssertEqual(r.playbackStart(from: 4), 4)
        XCTAssertEqual(r.playbackStart(from: 0.5), 2, "prima della selezione: parte dall'inizio")
        XCTAssertEqual(r.playbackStart(from: 8), 2, "dopo la selezione: parte dall'inizio")
        XCTAssertEqual(r.playbackStart(from: 6), 2, "alla fine esatta: riparte dall'inizio")
        XCTAssertEqual(r.playbackStart(from: 2), 2)
    }

    func testFormat() {
        XCTAssertEqual(TrimRange.format(0), "0:00.0"); XCTAssertEqual(TrimRange.format(65.5), "1:05.5")
        XCTAssertEqual(TrimRange.format(600), "10:00.0"); XCTAssertEqual(TrimRange.format(-4), "0:00.0")
        XCTAssertEqual(Tools.parseTime(TrimRange.format(125.5)), 125.5, "il testo mostrato si può rileggere")
    }
}

@MainActor
final class TrimPlayerTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipIf(Converter.ffmpegPath == nil, "ffmpeg serve per creare i file di prova")
    }

    private func ready(_ url: URL, video: Bool = true) async throws -> TrimPlayer {
        let p = TrimPlayer(url: url, hasVideo: video)
        await p.prepare()
        XCTAssertNil(p.errorMessage, p.errorMessage ?? "")
        XCTAssertTrue(p.ready)
        return p
    }

    private func wait(_ seconds: Double) async throws { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

    // MARK: Loading

    func testPrepareReadsDurationAndBuildsThumbnails() async throws {
        let f = try Fixtures()
        let p = try await ready(try f.video(seconds: 4))
        XCTAssertEqual(p.range.duration, 4, accuracy: 0.2)
        XCTAssertEqual(p.range.end, p.range.duration)
        XCTAssertEqual(p.thumbnails.count, 24)
        XCTAssertGreaterThan(p.thumbnails.compactMap { $0 }.count, 20, "quasi tutte le miniature devono esistere")
        XCTAssertEqual(p.frameDuration, 1.0 / 25, accuracy: 0.002)
        XCTAssertFalse(p.preparing)
    }

    func testThumbnailsReflectTheContentOverTime() async throws {
        let f = try Fixtures()
        let src = try f.media("shift.mp4", args: ["-f", "lavfi", "-i", "color=c=red:s=160x120:d=2", "-f", "lavfi", "-i", "color=c=blue:s=160x120:d=2", "-filter_complex", "[0][1]concat=n=2:v=1:a=0", "-pix_fmt", "yuv420p"])
        let thumbs = await TimelineArt.thumbnails(for: src, count: 8)
        let first = try XCTUnwrap(thumbs.first!), last = try XCTUnwrap(thumbs.last!)
        XCTAssertGreaterThan(pixel(first, 80, 60).r, 150); XCTAssertLessThan(pixel(first, 80, 60).b, 100)
        XCTAssertGreaterThan(pixel(last, 80, 60).b, 150); XCTAssertLessThan(pixel(last, 80, 60).r, 100)
    }

    func testAudioPrepareBuildsAWaveformThatFollowsTheSignal() async throws {
        let f = try Fixtures()
        let src = try f.media("burst.wav", args: ["-f", "lavfi", "-i", "sine=d=4", "-af", "volume='if(between(t,2,3),1,0)':eval=frame"])
        let p = try await ready(src, video: false)
        XCTAssertEqual(p.waveform.count, 600)
        let quiet = p.waveform[50..<150].max() ?? 1, loud = p.waveform[320..<430].max() ?? 0
        XCTAssertLessThan(quiet, 0.02); XCTAssertGreaterThan(loud, 0.05)
        XCTAssertTrue(p.thumbnails.isEmpty)
    }

    func testNonMediaFilesReportAnError() async throws {
        let f = try Fixtures()
        let p = TrimPlayer(url: try f.text("x.mp4", "non è un video"), hasVideo: true)
        await p.prepare()
        XCTAssertFalse(p.ready); XCTAssertNotNil(p.errorMessage); XCTAssertFalse(p.preparing)
    }

    func testFormatsAVFoundationCannotPlayGetAPreviewProxy() async throws {
        let f = try Fixtures()
        let mp4 = try f.video(seconds: 2)
        for ext in ["mkv", "webm", "avi"] {
            let src = f.url("clip.\(ext)")
            do { try await Converter.runFFmpeg(["-y", "-i", mp4.path, src.path]) } catch { continue }
            let proxy = try await PreviewProxy.prepare(src, video: true)
            let isProxy = proxy != src
            if isProxy { XCTAssertEqual(proxy.pathExtension, "mp4") }
            let asset = AVURLAsset(url: proxy)
            let playable = try await asset.load(.isPlayable)
            XCTAssertTrue(playable, ext)
            let seconds = try await asset.load(.duration).seconds
            XCTAssertEqual(seconds, 2, accuracy: 0.3, ext)
            if isProxy { try? FileManager.default.removeItem(at: proxy) }
        }
    }

    func testPlayableFilesAreUsedAsTheyAre() async throws {
        let f = try Fixtures()
        let mp4 = try f.video(seconds: 1)
        let url = try await PreviewProxy.prepare(mp4, video: true)
        XCTAssertEqual(url, mp4)
    }

    func testProxyIsRemovedWhenThePlayerGoesAway() async throws {
        let f = try Fixtures()
        let mp4 = try f.video(seconds: 1)
        let mkv = f.url("c.mkv")
        try await Converter.runFFmpeg(["-y", "-i", mp4.path, "-c", "copy", mkv.path])
        var proxyPath: String?
        do {
            let p = try await ready(mkv)
            proxyPath = (p.player.currentItem?.asset as? AVURLAsset)?.url.path
            XCTAssertNotNil(proxyPath)
        }
        try await wait(0.3)
        if let proxyPath, proxyPath != mkv.path { XCTAssertFalse(FileManager.default.fileExists(atPath: proxyPath), "il file temporaneo va ripulito") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: mkv.path), "l'originale non si tocca")
    }

    // MARK: Playback rules

    func testPlayingStopsAtTheEndOfTheSelection() async throws {
        let f = try Fixtures()
        let p = try await ready(try f.video(seconds: 4))
        p.setStart(1); p.setEnd(2)
        p.seek(to: 1)
        p.play()
        XCTAssertTrue(p.isPlaying)
        try await wait(2.0)
        XCTAssertFalse(p.isPlaying, "si ferma da solo")
        XCTAssertEqual(p.playhead, 2, accuracy: 0.15)
        XCTAssertLessThan(p.player.currentTime().seconds, 2.2, "non supera la fine della selezione")
    }

    func testPlayFromOutsideTheSelectionJumpsToItsStart() async throws {
        let f = try Fixtures()
        let p = try await ready(try f.video(seconds: 4))
        p.setStart(1); p.setEnd(2)
        p.seek(to: 3.5)
        p.play()
        XCTAssertEqual(p.playhead, 1, accuracy: 0.05)
        p.pause()
    }

    func testPlayFromInsideTheSelectionContinuesThere() async throws {
        let f = try Fixtures()
        let p = try await ready(try f.video(seconds: 4))
        p.setStart(1); p.setEnd(3)
        p.seek(to: 2)
        p.play()
        XCTAssertEqual(p.playhead, 2, accuracy: 0.05)
        p.pause()
    }

    func testLoopKeepsPlayingInsideTheSelection() async throws {
        let f = try Fixtures()
        let p = try await ready(try f.video(seconds: 4))
        p.setStart(1); p.setEnd(1.6)
        p.loop = true
        p.seek(to: 1)
        p.play()
        try await wait(2.2)
        XCTAssertTrue(p.isPlaying, "il ciclo non si ferma")
        XCTAssertGreaterThanOrEqual(p.playhead, 0.95); XCTAssertLessThanOrEqual(p.playhead, 1.75)
        p.pause()
    }

    func testTogglePlayAndPause() async throws {
        let f = try Fixtures()
        let p = try await ready(try f.video(seconds: 4))
        p.togglePlay(); XCTAssertTrue(p.isPlaying)
        p.togglePlay(); XCTAssertFalse(p.isPlaying)
    }

    func testSeekIsFrameExactAndClamped() async throws {
        let f = try Fixtures()
        let p = try await ready(try f.video(seconds: 4))
        p.seek(to: 1.52)
        try await wait(0.3)
        XCTAssertEqual(p.playhead, 1.52, accuracy: 0.001)
        XCTAssertEqual(p.player.currentTime().seconds, 1.52, accuracy: 0.05)
        p.seek(to: -3); XCTAssertEqual(p.playhead, 0)
        p.seek(to: 99); XCTAssertEqual(p.playhead, p.range.duration)
    }

    func testStepPausesAndMovesByOneFrame() async throws {
        let f = try Fixtures()
        let p = try await ready(try f.video(seconds: 4))
        p.seek(to: 1)
        p.play()
        p.step(by: p.frameDuration)
        XCTAssertFalse(p.isPlaying)
        XCTAssertEqual(p.playhead, 1 + p.frameDuration, accuracy: 0.045, "un fotogramma")
        p.step(by: -1); XCTAssertEqual(p.playhead, p.frameDuration + 1 - 1, accuracy: 0.05)
    }

    func testSkipStaysInsideTheSelection() async throws {
        let f = try Fixtures()
        let p = try await ready(try f.video(seconds: 4))
        p.setStart(1); p.setEnd(3)
        p.seek(to: 2)
        p.skip(5); XCTAssertEqual(p.playhead, 3, accuracy: 0.001)
        p.skip(-5); XCTAssertEqual(p.playhead, 1, accuracy: 0.001)
    }

    func testScrubPausesAndDoesNotResume() async throws {
        let f = try Fixtures()
        let p = try await ready(try f.video(seconds: 4))
        p.seek(to: 0.5); p.play()
        p.scrub(to: 2)
        XCTAssertFalse(p.isPlaying)
        XCTAssertEqual(p.playhead, 2, accuracy: 0.001)
        p.endScrub()
        try await wait(0.2)
        XCTAssertEqual(p.playhead, 2, accuracy: 0.05, "il timer non riporta indietro la testina")
    }

    // MARK: Selection actions

    func testIAndOMarkTheSelectionAtThePlayhead() async throws {
        let f = try Fixtures()
        let p = try await ready(try f.video(seconds: 4))
        p.seek(to: 1.2); p.setStartHere()
        p.seek(to: 2.8); p.setEndHere()
        XCTAssertEqual(p.range.start, 1.2, accuracy: 0.001); XCTAssertEqual(p.range.end, 2.8, accuracy: 0.001)
        p.seek(to: 3.5); p.setStartHere()
        XCTAssertLessThan(p.range.start, p.range.end, "I dopo la fine non inverte la selezione")
        p.resetSelection()
        XCTAssertTrue(p.range.isWholeClip)
    }

    func testToStartAndToEnd() async throws {
        let f = try Fixtures()
        let p = try await ready(try f.video(seconds: 4))
        p.setStart(1); p.setEnd(3)
        p.toEnd(); XCTAssertEqual(p.playhead, 3, accuracy: 0.001)
        p.toStart(); XCTAssertEqual(p.playhead, 1, accuracy: 0.001)
    }

    func testTypedTimesAreParsedAndInvalidOnesIgnored() async throws {
        let f = try Fixtures()
        let p = try await ready(try f.video(seconds: 4))
        XCTAssertTrue(p.commitStart(text: "0:01.5")); XCTAssertEqual(p.range.start, 1.5, accuracy: 0.001)
        XCTAssertTrue(p.commitEnd(text: "3")); XCTAssertEqual(p.range.end, 3, accuracy: 0.001)
        XCTAssertFalse(p.commitStart(text: "abc")); XCTAssertEqual(p.range.start, 1.5, accuracy: 0.001)
        XCTAssertFalse(p.commitEnd(text: "")); XCTAssertEqual(p.range.end, 3, accuracy: 0.001)
        XCTAssertTrue(p.commitEnd(text: "99")); XCTAssertEqual(p.range.end, p.range.duration, "oltre la durata: si ferma alla fine")
    }

    func testRangeChangesAreReported() async throws {
        let f = try Fixtures()
        let p = TrimPlayer(url: try f.video(seconds: 3), hasVideo: true)
        var seen: [TrimRange] = []
        p.onRangeChange = { seen.append($0) }
        await p.prepare()
        p.setStart(0.5); p.setEnd(2)
        XCTAssertEqual(seen.count, 3)
        XCTAssertEqual(seen.last?.start ?? 0, 0.5, accuracy: 0.001)
    }

    func testVolumeAndMute() async throws {
        let f = try Fixtures()
        let p = try await ready(try f.video(seconds: 2))
        p.volume = 0.4; XCTAssertEqual(p.player.volume, 0.4, accuracy: 0.001)
        p.muted = true; XCTAssertTrue(p.player.isMuted)
        p.volume = 0.6; XCTAssertFalse(p.muted, "alzare il volume toglie il muto")
        XCTAssertFalse(p.player.isMuted)
    }
}

@MainActor
final class TrimIntegrationTests: XCTestCase {
    override func setUpWithError() throws { try XCTSkipIf(Converter.ffmpegPath == nil, "ffmpeg non installato") }

    private func readySession(_ f: Fixtures, tool: ToolID = .trimVideo, url: URL) async throws -> ToolSession {
        let s = ToolSession(tool: tool, files: [url])
        let player = try XCTUnwrap(s.trimPlayer)
        for _ in 0..<100 where !player.ready { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertTrue(player.ready)
        return s
    }

    private func waitForResults(_ s: ToolSession) async throws {
        for _ in 0..<200 where s.running || (s.results.isEmpty && s.errorMessage == nil) { try await Task.sleep(nanoseconds: 100_000_000) }
    }

    func testOnlyTheTrimToolsGetTheTimelineEditor() throws {
        let f = try Fixtures()
        XCTAssertNotNil(ToolSession(tool: .trimVideo, files: [try f.video(seconds: 1)]).trimPlayer)
        XCTAssertNotNil(ToolSession(tool: .trimAudio, files: [try f.tone(seconds: 1)]).trimPlayer)
        XCTAssertNil(ToolSession(tool: .cropVideo, files: [try f.video("c.mp4", seconds: 1)]).trimPlayer)
        XCTAssertNil(ToolSession(tool: .resizeImage, files: [try f.quadrants()]).trimPlayer)
    }

    func testRangeChangesFlowIntoTheValuesAndTheCutUsesThem() async throws {
        let f = try Fixtures()
        let s = try await readySession(f, url: try f.video(seconds: 6))
        let p = try XCTUnwrap(s.trimPlayer)
        p.setStart(1); p.setEnd(3.5)
        XCTAssertEqual(s.values.string("start"), "1.000"); XCTAssertEqual(s.values.string("end"), "3.500")
        s.run()
        try await waitForResults(s)
        XCTAssertNil(s.errorMessage)
        let out = try XCTUnwrap(s.results.first)
        XCTAssertEqual(duration(out), 2.5, accuracy: 0.4)
        XCTAssertEqual(out.lastPathComponent, "v trimmed.mp4")
    }

    func testTypingTimesAlsoUpdatesTheCut() async throws {
        let f = try Fixtures()
        let s = try await readySession(f, url: try f.video(seconds: 6))
        let p = try XCTUnwrap(s.trimPlayer)
        XCTAssertTrue(p.commitStart(text: "0:02")); XCTAssertTrue(p.commitEnd(text: "0:04.5"))
        s.run()
        try await waitForResults(s)
        XCTAssertEqual(duration(try XCTUnwrap(s.results.first)), 2.5, accuracy: 0.4)
    }

    func testAudioTrimUsesTheSameEditor() async throws {
        let f = try Fixtures()
        let s = try await readySession(f, tool: .trimAudio, url: try f.tone(seconds: 6))
        let p = try XCTUnwrap(s.trimPlayer)
        XCTAssertFalse(p.hasVideo); XCTAssertEqual(p.waveform.count, 600)
        p.setStart(2); p.setEnd(5)
        s.run()
        try await waitForResults(s)
        XCTAssertEqual(duration(try XCTUnwrap(s.results.first)), 3, accuracy: 0.3)
    }

    func testFastModeCutsOnTheKeyframeWithoutReencoding() async throws {
        let f = try Fixtures()
        // Un fotogramma chiave al secondo: 25 fps con GOP di 25.
        let src = try f.media("gop.mp4", args: ["-f", "lavfi", "-i", "testsrc=d=8:s=320x240:r=25", "-g", "25", "-keyint_min", "25", "-sc_threshold", "0", "-pix_fmt", "yuv420p"])
        let precise = try await runTool(.trimVideo, [src], ["start": .text("2.5"), "end": .text("5"), "precise": .bool(true)])[0]
        let fast = try await runTool(.trimVideo, [src], ["start": .text("2.5"), "end": .text("5"), "precise": .bool(false)])[0]
        XCTAssertEqual(duration(precise), 2.5, accuracy: 0.3, "preciso: esattamente quanto richiesto")
        XCTAssertGreaterThanOrEqual(duration(fast), 2.4, "veloce: parte dal fotogramma chiave precedente, quindi non è più corto")
        XCTAssertLessThanOrEqual(duration(fast), 3.6)
        let info = Shell.captureStderr(Converter.ffmpegPath!, ["-hide_banner", "-i", fast.path])
        XCTAssertTrue(info.contains("h264"), "stesso codec: nessuna ricodifica")
    }

    func testPreciseIsTheDefaultAndExposedAsAParameter() throws {
        let f = try Fixtures()
        let p = ToolEngine.params(for: .trimVideo, files: [try f.video(seconds: 1)])
        XCTAssertEqual(p.first { $0.id == "precise" }?.defaultValue, .bool(true))
    }

    func testRunStaysDisabledUntilThePreviewIsReady() throws {
        let f = try Fixtures()
        let s = ToolSession(tool: .trimVideo, files: [try f.video(seconds: 1)])
        XCTAssertFalse(try XCTUnwrap(s.trimPlayer).ready, "subito dopo l'apertura il file non è ancora pronto")
    }

    func testClosingTheWindowStopsPlayback() async throws {
        let f = try Fixtures()
        let s = try await readySession(f, url: try f.video(seconds: 4))
        let p = try XCTUnwrap(s.trimPlayer)
        p.play(); XCTAssertTrue(p.isPlaying)
        s.close()
        XCTAssertFalse(p.isPlaying)
    }
}
