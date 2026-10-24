import AppKit
import AVFoundation
import Foundation

// MARK: - Selection

/// The part of the clip that is kept. Pure value type, so the rules are easy to test.
struct TrimRange: Equatable {
    static let minLength = 0.1

    var duration: Double
    private(set) var start = 0.0
    private(set) var end: Double

    init(duration: Double) {
        self.duration = max(duration, 0)
        end = self.duration
    }

    var length: Double { end - start }
    var isWholeClip: Bool { start <= 0.0005 && end >= duration - 0.0005 }

    mutating func setStart(_ t: Double) {
        guard t.isFinite else { return }
        start = min(max(t, 0), max(end - Self.minLength, 0))
    }

    mutating func setEnd(_ t: Double) {
        guard t.isFinite else { return }
        end = max(min(t, duration), min(start + Self.minLength, duration))
    }

    func contains(_ t: Double) -> Bool { t >= start - 0.0005 && t <= end + 0.0005 }

    func clamp(_ t: Double) -> Double { min(max(t, 0), duration) }

    /// Where playback begins: here if the playhead is inside the selection, otherwise at its start.
    func playbackStart(from playhead: Double) -> Double {
        playhead >= start && playhead < end - Self.minLength ? playhead : start
    }

    /// "1:05.5" — minutes, seconds and tenths.
    static func format(_ seconds: Double) -> String {
        let s = max(seconds, 0)
        let minutes = Int(s / 60)
        return String(format: "%d:%04.1f", minutes, s - Double(minutes) * 60)
    }
}

// MARK: - Preview preparation

enum PreviewProxy {
    /// A file AVFoundation can play: the original when possible, else a light H.264/AAC (or AAC) copy made with ffmpeg.
    static func prepare(_ url: URL, video: Bool, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        let asset = AVURLAsset(url: url)
        if (try? await asset.load(.isPlayable)) == true, !(try await asset.load(.tracks)).isEmpty { return url }
        guard Converter.ffmpegPath != nil else {
            throw ConversionError(message: "This format requires ffmpeg for playback (brew install ffmpeg).")
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("mandarine-preview-\(UUID().uuidString)." + (video ? "mp4" : "m4a"))
        var args = ["-y", "-i", url.path]
        if video { args += ["-vf", "scale=-2:480", "-c:v", "libx264", "-preset", "ultrafast", "-crf", "30", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "96k", "-movflags", "+faststart"] }
        else { args += ["-vn", "-c:a", "aac", "-b:a", "128k"] }
        try await Converter.runFFmpeg(args + [out.path], duration: MediaInfo.duration(url), progress: progress)
        return out
    }
}

enum TimelineArt {
    /// Thumbnails spread evenly over the clip; failed ones stay nil.
    static func thumbnails(for url: URL, count: Int, height: CGFloat = 120) async -> [CGImage?] {
        guard count > 0 else { return [] }
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds, duration > 0 else { return Array(repeating: nil, count: count) }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: height * 4, height: height)
        gen.requestedTimeToleranceBefore = CMTime(seconds: duration / Double(count), preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: duration / Double(count), preferredTimescale: 600)
        var result = [CGImage?](repeating: nil, count: count)
        for i in 0..<count {
            let t = CMTime(seconds: duration * (Double(i) + 0.5) / Double(count), preferredTimescale: 600)
            result[i] = try? gen.copyCGImage(at: t, actualTime: nil)
        }
        return result
    }

    /// Peak amplitude (0…1) per bucket, for drawing a waveform.
    static func waveform(for url: URL, buckets: Int) async -> [Float] {
        guard buckets > 0 else { return [] }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let duration = try? await asset.load(.duration).seconds, duration > 0,
              let reader = try? AVAssetReader(asset: asset) else { return [] }
        let rate = 8000.0
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVNumberOfChannelsKey: 1, AVSampleRateKey: rate,
        ])
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }
        let perBucket = max(Int(duration * rate) / buckets, 1)
        var peaks = [Float](repeating: 0, count: buckets)
        var index = 0
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            let length = CMBlockBufferGetDataLength(block)
            var data = [Int16](repeating: 0, count: length / 2)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &data)
            for sample in data {
                let bucket = min(index / perBucket, buckets - 1)
                peaks[bucket] = max(peaks[bucket], abs(Float(sample)) / 32768)
                index += 1
            }
        }
        return peaks
    }
}

// MARK: - Player

/// Playback confined to the selection, with the editing actions the shortcuts trigger.
@MainActor
final class TrimPlayer: ObservableObject {
    let url: URL
    let hasVideo: Bool
    let player = AVPlayer()

    @Published private(set) var range = TrimRange(duration: 0)
    @Published private(set) var playhead = 0.0
    @Published private(set) var isPlaying = false
    @Published private(set) var ready = false
    @Published private(set) var preparing = true
    @Published private(set) var prepareProgress = 0.0
    @Published private(set) var errorMessage: String?
    @Published private(set) var thumbnails: [CGImage?] = []
    @Published private(set) var waveform: [Float] = []
    @Published private(set) var frameDuration = 1.0 / 30
    @Published var loop = false
    /// Speed of the preview (the Speed tool plays at the chosen factor).
    @Published var playbackRate: Float = 1 {
        didSet { player.defaultRate = playbackRate; if isPlaying { player.rate = playbackRate } }
    }
    /// Keeps the voice natural at other speeds; off gives the tape-speed effect.
    @Published var preservePitch = true { didSet { applyPitch() } }
    @Published var muted = false { didSet { player.isMuted = muted } }
    @Published var volume = 1.0 { didSet { player.volume = Float(volume); if volume > 0 { muted = false } } }

    private var observer: Any?
    private var scrubbing = false
    private var playableURL: URL?
    var onRangeChange: ((TrimRange) -> Void)?
    /// Speed zones edit a range, but their preview still plays the entire sequence.
    var confinesPlaybackToSelection = true
    var playbackRateAtTime: ((Double) -> Double)?

    func refreshPlaybackRate() {
        guard let rate = playbackRateAtTime?(playhead), rate.isFinite, rate > 0 else { return }
        if abs(Double(playbackRate) - rate) > 0.0001 { playbackRate = Float(rate) }
    }

    private var playbackRange: TrimRange {
        confinesPlaybackToSelection ? range : TrimRange(duration: range.duration)
    }

    init(url: URL, hasVideo: Bool) {
        self.url = url
        self.hasVideo = hasVideo
    }

    deinit {
        if let observer { player.removeTimeObserver(observer) }
        if let playableURL, playableURL != url { try? FileManager.default.removeItem(at: playableURL) }
    }

    // MARK: Loading

    func prepare() async {
        preparing = true
        do {
            let playable = try await PreviewProxy.prepare(url, video: hasVideo) { [weak self] p in
                Task { @MainActor in self?.prepareProgress = p }
            }
            playableURL = playable
            let item = AVPlayerItem(url: playable)
            item.audioTimePitchAlgorithm = preservePitch ? .spectral : .varispeed
            let asset = item.asset
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else { throw ConversionError(message: "Unable to read duration: \(url.lastPathComponent)") }
            if let track = try await asset.loadTracks(withMediaType: .video).first {
                let fps = try await track.load(.nominalFrameRate)
                if fps > 0 { frameDuration = 1.0 / Double(fps) }
            }
            player.replaceCurrentItem(with: item)
            applyPitch()
            range = TrimRange(duration: duration)
            installObserver()
            let art = playable
            if hasVideo { thumbnails = await TimelineArt.thumbnails(for: art, count: 24) }
            else { waveform = await TimelineArt.waveform(for: art, buckets: 600) }
            ready = true
            preparing = false
            onRangeChange?(range)
        } catch {
            errorMessage = error.localizedDescription
            preparing = false
        }
    }

    private func applyPitch() {
        player.currentItem?.audioTimePitchAlgorithm = preservePitch ? .spectral : .varispeed
    }

    private func installObserver() {
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1.0 / 30, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
    }

    private func tick(_ t: Double) {
        guard ready, t.isFinite else { return }
        if isPlaying, !scrubbing { playhead = t }
        if isPlaying { refreshPlaybackRate() }
        if isPlaying, t >= playbackRange.end - 0.0005 {
            if loop { seek(to: playbackRange.start, resume: true) }
            else { pause(); seek(to: playbackRange.end) }
        }
    }

    // MARK: Transport

    func play() {
        guard ready else { return }
        let from = playbackRange.playbackStart(from: playhead)
        if abs(from - playhead) > 0.001 { seek(to: from) }
        refreshPlaybackRate()
        player.defaultRate = playbackRate
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func togglePlay() { isPlaying ? pause() : play() }

    func seek(to t: Double, resume: Bool = false) {
        let target = range.clamp(t)
        playhead = target
        refreshPlaybackRate()
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if resume { player.play(); isPlaying = true }
    }

    /// Dragging the playhead or a handle: follow the pointer without resuming playback.
    func scrub(to t: Double) {
        scrubbing = true
        let wasPlaying = isPlaying
        if wasPlaying { pause() }
        seek(to: t)
    }

    func endScrub() { scrubbing = false }

    /// Frame stepping while paused; with Shift the shortcut steps one second.
    func step(by seconds: Double) {
        pause()
        seek(to: playhead + seconds)
    }

    func skip(_ seconds: Double) { seek(to: min(max(playhead + seconds, playbackRange.start), playbackRange.end), resume: isPlaying) }
    func toStart() { seek(to: range.start) }
    func toEnd() { seek(to: range.end) }

    // MARK: Selection

    func setStart(_ t: Double) { var r = range; r.setStart(t); range = r; onRangeChange?(r) }
    func setEnd(_ t: Double) { var r = range; r.setEnd(t); range = r; onRangeChange?(r) }
    func setStartHere() { setStart(playhead) }
    func setEndHere() { setEnd(playhead) }
    func resetSelection() { setStart(0); setEnd(range.duration) }

    /// Typed value in the Start/End fields; false (and no change) when it cannot be parsed.
    @discardableResult
    func commitStart(text: String) -> Bool {
        guard let t = Tools.parseTime(text) else { return false }
        setStart(t); seek(to: range.start); return true
    }

    @discardableResult
    func commitEnd(text: String) -> Bool {
        guard let t = Tools.parseTime(text) else { return false }
        setEnd(t); seek(to: range.end); return true
    }
}
