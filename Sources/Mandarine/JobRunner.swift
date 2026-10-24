import AppKit
import SwiftUI

/// Outcome of a batch: one failure never stops the other files.
struct JobSummary: Equatable {
    var outputs: [URL] = []
    var failures: [Failure] = []
    var cancelled = false
    var total = 0

    struct Failure: Equatable {
        let file: String
        let message: String
    }

    var succeeded: Int { total - failures.count - (cancelled ? max(total - outputs.count - failures.count, 0) : 0) }
    var hasFailures: Bool { !failures.isEmpty }
}

enum JobState: Equatable {
    case idle
    case running(title: String, done: Int, total: Int, current: String, fraction: Double)
    case finished(title: String, JobSummary)
}

enum Haptics {
    static func tap() {
        guard Settings.shared.hapticEnabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }
}

@MainActor
final class JobRunner: ObservableObject {
    static let shared = JobRunner()

    @Published private(set) var state: JobState = .idle
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private struct Pending {
        let title: String
        let files: [URL]
        let silent: Bool
        let work: (URL, @escaping @Sendable (Double) -> Void) async throws -> [URL]
    }
    private var pending: [Pending] = []
    @Published private(set) var queuedCount = 0

    var isRunning: Bool { if case .running = state { return true }; return false }

    /// Core of a batch run, independent from any UI.
    /// `work` handles one file and may report 0…1 progress; it returns the files it produced.
    nonisolated static func execute(files: [URL],
                                    work: @escaping (URL, @escaping @Sendable (Double) -> Void) async throws -> [URL],
                                    onUpdate: @escaping @Sendable (_ done: Int, _ current: String, _ fraction: Double) -> Void = { _, _, _ in }) async -> JobSummary {
        var summary = JobSummary(total: files.count)
        for (i, file) in files.enumerated() {
            if Task.isCancelled { summary.cancelled = true; break }
            onUpdate(i, file.lastPathComponent, Double(i) / Double(max(files.count, 1)))
            do {
                let outs = try await work(file) { p in
                    onUpdate(i, file.lastPathComponent, (Double(i) + min(max(p, 0), 1)) / Double(max(files.count, 1)))
                }
                summary.outputs += outs
            } catch is CancellationError {
                summary.cancelled = true
                break
            } catch {
                summary.failures.append(.init(file: file.lastPathComponent, message: error.localizedDescription))
            }
        }
        onUpdate(files.count, "", 1)
        return summary
    }

    /// Runs `work` over `files` with the progress HUD.
    func start(title: String, files: [URL], silent: Bool = false,
               work: @escaping (URL, @escaping @Sendable (Double) -> Void) async throws -> [URL]) {
        guard !isRunning else {
            pending.append(Pending(title: title, files: files, silent: silent, work: work))
            queuedCount = pending.count
            return
        }
        let currentGeneration = UUID()
        generation = currentGeneration
        state = .running(title: title, done: 0, total: files.count, current: files.first?.lastPathComponent ?? "", fraction: 0)
        JobHUD.shared.show()
        task = Task { [weak self] in
            let summary = await Self.execute(files: files, work: work) { done, current, fraction in
                Task { @MainActor in
                    guard let self, self.generation == currentGeneration, case .running = self.state else { return }
                    self.state = .running(title: title, done: done, total: files.count, current: current, fraction: fraction)
                }
            }
            await MainActor.run {
                guard let self else { return }
                self.state = .finished(title: title, summary)
                self.finish(summary, silent: silent)
                if !self.pending.isEmpty {
                    let next = self.pending.removeFirst()
                    self.queuedCount = self.pending.count
                    self.start(title: next.title, files: next.files, silent: next.silent, work: next.work)
                }
            }
        }
    }

    private func finish(_ summary: JobSummary, silent: Bool) {
        if summary.hasFailures {
            if Settings.shared.soundEnabled { NSSound(named: "Basso")?.play() }
        } else if !summary.cancelled && !silent {
            if Settings.shared.soundEnabled { NSSound(named: "Glass")?.play() }
            Haptics.tap()
        }
        JobHUD.shared.finished(keepOpen: summary.hasFailures)
    }

    func cancel() { task?.cancel() }

    func dismiss() {
        guard !isRunning else { return }
        generation = UUID()
        state = .idle
        JobHUD.shared.hide()
    }
}

// MARK: - HUD

@MainActor
final class JobHUD {
    static let shared = JobHUD()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show() {
        hideTask?.cancel()
        let width: CGFloat = 380, height: CGFloat = 76
        let p = panel ?? NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        let host = NSHostingView(rootView: JobHUDView(runner: JobRunner.shared))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        p.contentView = host
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let notch = Settings.shared.progressStyle == .notch
        let y = notch ? screen.frame.maxY - height : screen.visibleFrame.maxY - height - 10
        p.setFrame(NSRect(x: screen.frame.midX - width / 2, y: y, width: width, height: height), display: true)
        p.orderFrontRegardless()
        panel = p
    }

    func finished(keepOpen: Bool) {
        hideTask?.cancel()
        guard !keepOpen else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if Task.isCancelled { return }
            await MainActor.run { JobRunner.shared.dismiss(); self?.hide() }
        }
    }

    func hide() { panel?.orderOut(nil) }
}

struct JobHUDView: View {
    @ObservedObject var runner: JobRunner

    private var notch: Bool { Settings.shared.progressStyle == .notch }

    var body: some View {
        content
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(width: 380, height: 76)
            .background(background)
            .foregroundStyle(notch ? Color.white : Color.primary)
    }

    @ViewBuilder private var background: some View {
        let shape = RoundedRectangle(cornerRadius: notch ? 22 : 18, style: .continuous)
        if notch { shape.fill(Color.black) }
        else if Settings.shared.appearance == .glass { shape.fill(.ultraThinMaterial) }
        else { shape.fill(Color(nsColor: .windowBackgroundColor)) }
    }

    @ViewBuilder private var content: some View {
        switch runner.state {
        case .idle:
            EmptyView()
        case .running(let title, let done, let total, let current, let fraction):
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(title).font(.callout.bold())
                        Spacer()
                        Text("\(min(done + 1, total)) of \(total)").font(.caption.monospacedDigit()).opacity(0.7)
                    }
                    ProgressView(value: fraction).tint(.orange)
                    if runner.queuedCount > 0 { Text("\(runner.queuedCount) queued operations").font(.caption2) }
                    Text(current).font(.caption).opacity(0.7).lineLimit(1).truncationMode(.middle)
                }
                Button { runner.cancel() } label: { Image(systemName: "xmark.circle.fill").font(.title3) }
                    .buttonStyle(.plain).help("Cancel")
            }
        case .finished(let title, let summary):
            HStack(spacing: 12) {
                Image(systemName: icon(summary)).font(.title2).foregroundStyle(color(summary))
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline(title, summary)).font(.callout.bold()).lineLimit(1)
                    if let f = summary.failures.first {
                        Text("\(f.file): \(f.message)").font(.caption).opacity(0.7).lineLimit(2)
                    }
                }
                Spacer()
                if summary.hasFailures {
                    Button("Details") { showDetails(summary) }
                } else if !summary.outputs.isEmpty {
                    Button("Show") { NSWorkspace.shared.activateFileViewerSelecting(summary.outputs) }
                }
                Button { runner.dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
        }
    }

    private func icon(_ s: JobSummary) -> String { s.cancelled ? "stop.circle.fill" : s.hasFailures ? "exclamationmark.triangle.fill" : "checkmark.circle.fill" }
    private func color(_ s: JobSummary) -> Color { s.cancelled ? .secondary : s.hasFailures ? .red : .green }

    private func headline(_ title: String, _ s: JobSummary) -> String {
        if s.cancelled { return "Cancelled" }
        if s.hasFailures { return "\(s.failures.count) of \(s.total) failed" }
        return s.total == 1 ? "Done" : "Done · \(s.total) files"
    }

    private func showDetails(_ s: JobSummary) {
        let alert = NSAlert()
        alert.messageText = "Operation failed for \(ShelfCitrus.fileCount(s.failures.count))"
        alert.informativeText = s.failures.map { "\($0.file): \($0.message)" }.joined(separator: "\n")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
