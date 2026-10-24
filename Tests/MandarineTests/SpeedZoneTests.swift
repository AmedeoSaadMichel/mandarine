import AVFoundation
import XCTest
@testable import Mandarine

final class SpeedPlanTests: XCTestCase {
    func testGapsStayAtNormalSpeedAndUnsortedZonesUseSourceOrder() throws {
        let zones = [SpeedZone(start: 6, end: 8, factor: 4), SpeedZone(start: 2, end: 4, factor: 2)]
        let plan = try SpeedPlan.segments(duration: 8, zones: zones)
        XCTAssertEqual(plan.map(\.start), [0, 2, 4, 6])
        XCTAssertEqual(plan.map(\.end), [2, 4, 6, 8])
        XCTAssertEqual(plan.map(\.factor), [1, 2, 1, 4])
        XCTAssertEqual(plan.reduce(0) { $0 + $1.outputDuration }, 5.5, accuracy: 0.0001)
    }

    func testAdjacentZonesAndSlowMotion() throws {
        let plan = try SpeedPlan.segments(duration: 4, zones: [.init(start: 0, end: 2, factor: 2), .init(start: 2, end: 4, factor: 0.5)])
        XCTAssertEqual(plan.count, 2)
        XCTAssertEqual(plan.reduce(0) { $0 + $1.outputDuration }, 5)
    }

    func testPreviewUsesHalfOpenIntervalsAndNormalSpeedInGaps() {
        let zones = [SpeedZone(start: 1, end: 3, factor: 2), SpeedZone(start: 3, end: 4, factor: 4)]
        for (time, rate) in [(0.0, 1.0), (1, 2), (2.9, 2), (3, 4), (4, 1), (7, 1)] {
            XCTAssertEqual(SpeedPlan.rate(at: time, zones: zones), rate)
        }
    }

    func testInvalidRangesAndFactorsAreRejected() {
        for zone in [SpeedZone(start: -1, end: 2, factor: 2), .init(start: 3, end: 2, factor: 2),
                     .init(start: 1, end: 1.01, factor: 2), .init(start: 0, end: 9, factor: 2),
                     .init(start: .nan, end: 2, factor: 2), .init(start: 0, end: .infinity, factor: 2),
                     .init(start: 0, end: 2, factor: .nan), .init(start: 0, end: 2, factor: 0),
                     .init(start: 0, end: 2, factor: 5)] {
            XCTAssertThrowsError(try SpeedPlan.segments(duration: 8, zones: [zone]))
        }
    }

    func testOverlapAndExcessiveZoneCountAreRejected() {
        XCTAssertThrowsError(try SpeedPlan.segments(duration: 8, zones: [.init(start: 1, end: 4, factor: 2), .init(start: 3, end: 5, factor: 4)]))
        let zones = (0...SpeedPlan.maxZones).map { SpeedZone(start: Double($0), end: Double($0 + 1), factor: 2) }
        XCTAssertThrowsError(try SpeedPlan.segments(duration: 100, zones: zones))
    }

    func testEmptyPlanLeavesTheClipUntouched() throws {
        XCTAssertEqual(try SpeedPlan.segments(duration: 8, zones: []), [.init(start: 0, end: 8, factor: 1)])
    }
}

@MainActor
final class SpeedZoneTests: XCTestCase {
    override func setUpWithError() throws { try XCTSkipIf(Converter.ffmpegPath == nil, "ffmpeg non installato") }

    private let zones = [SpeedZone(start: 2, end: 4, factor: 2), SpeedZone(start: 6, end: 8, factor: 4)]
    private func session(_ f: Fixtures) async throws -> ToolSession {
        let session = ToolSession(tool: .changeVideoSpeed, files: [try f.video(seconds: 8)])
        for _ in 0..<100 where session.trimPlayer?.ready != true { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertTrue(session.trimPlayer?.ready == true)
        return session
    }

    func testExportRetimesTwoZonesAndRetainsTheOriginalGapsAndAudio() async throws {
        let f = try Fixtures()
        var args: [String] = []
        for color in ["red", "lime", "blue", "yellow"] {
            args += ["-f", "lavfi", "-i", "color=c=\(color):s=160x120:r=30:d=2"]
        }
        args += ["-f", "lavfi", "-i", "sine=frequency=440:duration=8", "-filter_complex", "[0:v][1:v][2:v][3:v]concat=n=4:v=1:a=0[v]", "-map", "[v]", "-map", "4:a", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac"]
        let source = try f.media("colors.mp4", args: args)
        let out = try await runTool(.changeVideoSpeed, [source], ["useZones": .bool(true), "speedZones": .speedZones(zones)])[0]
        XCTAssertEqual(duration(out), 5.5, accuracy: 0.12)
        XCTAssertTrue(MediaInfo.hasAudio(out))
        XCTAssertEqual(dominantFrequency(out), 440, accuracy: 35)
        for (time, sourceTime) in [(1.0, 1.0), (2.5, 3), (4.0, 5), (5.25, 7)] {
            let image = try XCTUnwrap(MediaInfo.frame(out, at: time))
            let original = try XCTUnwrap(MediaInfo.frame(source, at: sourceTime))
            let actual = pixel(image, 80, 60), expected = pixel(original, 80, 60)
            XCTAssertTrue(isClose(actual, expected, tolerance: 12), "tempo \(time): \(actual), sorgente \(expected)")
        }
    }

    func testExportWithoutAudioAndWithSourceFrameRate() async throws {
        let f = try Fixtures()
        let out = try await runTool(.changeVideoSpeed, [try f.video(seconds: 8, audio: false)], ["useZones": .bool(true), "speedZones": .speedZones(zones)])[0]
        XCTAssertEqual(duration(out), 5.5, accuracy: 0.15)
        XCTAssertFalse(MediaInfo.hasAudio(out))
        let tracks = try await AVURLAsset(url: out).loadTracks(withMediaType: .video)
        let fps = try await XCTUnwrap(tracks.first).load(.nominalFrameRate)
        XCTAssertEqual(fps, 25, accuracy: 0.1)
    }

    func testZoneAudioRespectsThePitchToggle() async throws {
        let f = try Fixtures(), source = try f.video(seconds: 4)
        let out = try await runTool(.changeVideoSpeed, [source], ["useZones": .bool(true), "speedZones": .speedZones([.init(start: 0, end: 4, factor: 2)]), "preservePitch": .bool(false)])[0]
        XCTAssertEqual(duration(out), 2, accuracy: 0.15)
        XCTAssertEqual(dominantFrequency(out), 880, accuracy: 60)
    }

    func testInvalidZoneExportDoesNotPublishAFile() async throws {
        let f = try Fixtures(), source = try f.video(seconds: 2)
        for zones: [SpeedZone] in [[], [.init(start: 0, end: 3, factor: 2)], [.init(start: 0, end: 1.5, factor: 2), .init(start: 1, end: 2, factor: 4)]] {
            do {
                _ = try await runTool(.changeVideoSpeed, [source], ["useZones": .bool(true), "speedZones": .speedZones(zones)])
                XCTFail("Intervalli non validi accettati")
            } catch { XCTAssertTrue(error is ToolError) }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.dir.path), ["v.mp4"])
    }

    func testStartsWithWholeVideoAndAddsIntervalsBySplitting() async throws {
        let f = try Fixtures(), s = try await session(f)
        let first = try XCTUnwrap(s.currentSpeedZone)
        XCTAssertTrue(s.speedUsesZones)
        XCTAssertEqual(first.start, 0)
        XCTAssertEqual(first.end, 8)
        XCTAssertEqual(first.factor, 1)
        XCTAssertEqual(s.speedOutputDuration, 8)
        XCTAssertTrue(try XCTUnwrap(s.trimPlayer).range.isWholeClip)
        XCTAssertTrue(s.canRun)
        s.setSpeedFactor(1.5)
        s.trimPlayer?.seek(to: 3)
        s.addSpeedZone()
        XCTAssertEqual(s.speedZones.map(\.start), [0, 3])
        XCTAssertEqual(s.speedZones.map(\.end), [3, 8])
        XCTAssertEqual(s.speedZones.map(\.factor), [1.5, 1.5])
        s.setSpeedFactor(4)
        XCTAssertEqual(s.speedZones.map(\.factor), [1.5, 4])
        s.trimPlayer?.seek(to: 0)
        s.addSpeedZone()
        XCTAssertEqual(s.currentSpeedZone?.start, 5.5)
        XCTAssertEqual(s.currentSpeedZone?.end, 8)
        XCTAssertEqual(s.speedZones.count, 3)
        XCTAssertNil(s.speedZonesError)
    }

    func testSessionAddsIndependentZonesAndEditsTheSelectedOne() async throws {
        let f = try Fixtures(), s = try await session(f)
        for zone in s.speedZones { s.removeSpeedZone(zone.id) }
        XCTAssertFalse(s.canRun)
        s.addSpeedZone()
        let first = try XCTUnwrap(s.currentSpeedZone)
        XCTAssertEqual(first.start, 0); XCTAssertEqual(first.end, 2)
        s.trimPlayer?.seek(to: 4); s.addSpeedZone()
        let second = try XCTUnwrap(s.currentSpeedZone)
        XCTAssertEqual(second.start, 4); XCTAssertEqual(second.end, 6)
        s.setSpeedFactor(4)
        XCTAssertEqual(s.speedZones.first { $0.id == first.id }?.factor, 1)
        XCTAssertEqual(s.currentSpeedZone?.factor, 4)
        XCTAssertEqual(s.speedOutputDuration, 6.5, accuracy: 0.001)
        s.selectSpeedZone(first.id)
        s.trimPlayer?.setStart(1)
        XCTAssertEqual(s.currentSpeedZone?.start, 1)
        XCTAssertEqual(s.speedZones.first { $0.id == second.id }?.start, 4)
        XCTAssertFalse(s.updateSpeedZone(first.id, end: 5), "non deve sovrapporsi al secondo")
        XCTAssertEqual(s.currentSpeedZone?.end, 2)
        s.removeSpeedZone(first.id)
        XCTAssertEqual(s.currentSpeedZone?.id, second.id)
    }

    func testSwitchingToWholeVideoRetainsZonesAndUsesTheGlobalFactor() async throws {
        let f = try Fixtures(), s = try await session(f)
        s.setSpeedZonesEnabled(false)
        s.setSpeedFactor(1.5)
        s.setSpeedZonesEnabled(true); s.addSpeedZone(); s.setSpeedFactor(4)
        let zones = s.speedZones
        s.setSpeedZonesEnabled(false)
        XCTAssertEqual(s.speedFactor, 1.5)
        XCTAssertEqual(s.speedZones, zones)
        XCTAssertTrue(try XCTUnwrap(s.trimPlayer).range.isWholeClip)
        s.setSpeedZonesEnabled(true)
        XCTAssertEqual(s.currentSpeedZone?.factor, zones.first?.factor)
    }

    func testNormalPlaybackUsesRatesWithoutAnExtraPreviewMode() async throws {
        let f = try Fixtures(), s = try await session(f)
        s.values["speedZones"] = .speedZones([.init(start: 0, end: 1, factor: 4), .init(start: 1, end: 8, factor: 0.5)])
        let p = try XCTUnwrap(s.trimPlayer)
        p.seek(to: 0)
        p.play()
        XCTAssertEqual(p.player.rate, 4, accuracy: 0.01)
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertTrue(p.isPlaying)
        XCTAssertGreaterThan(p.playhead, 1)
        XCTAssertEqual(p.player.rate, 0.5, accuracy: 0.01)
        s.selectSpeedZone(s.speedZones[1].id)
        s.setSpeedFactor(2)
        XCTAssertEqual(p.player.rate, 2, accuracy: 0.01)
        p.pause()
    }

    func testPreviewRatesFollowZonesAndGapsAfterSeeking() async throws {
        let f = try Fixtures(), s = try await session(f)
        s.values["speedZones"] = .speedZones(zones)
        s.setSpeedZonesEnabled(true)
        let p = try XCTUnwrap(s.trimPlayer)
        for (time, rate) in [(1.0, 1.0), (2, 2), (4, 1), (6, 4), (8, 1)] {
            p.seek(to: time)
            XCTAssertEqual(Double(p.playbackRate), rate, accuracy: 0.001)
        }
    }

    func testPreviewCrossesZoneBoundaryWithoutStoppingAtTheSelectionEnd() async throws {
        let f = try Fixtures(), s = try await session(f)
        s.values["speedZones"] = .speedZones([.init(start: 0, end: 1, factor: 4)])
        s.setSpeedZonesEnabled(true)
        let p = try XCTUnwrap(s.trimPlayer)
        p.play()
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertTrue(p.isPlaying)
        XCTAssertGreaterThan(p.playhead, 1)
        XCTAssertEqual(p.playbackRate, 1, "fuori dall'intervallo torna a velocità normale")
        p.pause()
    }
}
