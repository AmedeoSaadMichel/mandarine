import Foundation
import Darwin

struct ProcessOutput {
    let status: Int32
    let stdout: Data
    let stderr: Data
}

/// The lock covers both launch and cancellation: a cancelled process cannot start afterwards.
final class ProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var stopped = false
    private var expired = false

    func start(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { throw CancellationError() }
        self.process = process
        try process.run()
    }

    func stop(timeout: Bool = false) {
        lock.lock()
        stopped = true
        expired = expired || timeout
        if let process, process.isRunning { process.terminate() }
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
            lock.lock(); defer { lock.unlock() }
            if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    func check() throws {
        lock.lock(); defer { lock.unlock() }
        if expired { throw ConversionError(message: "The operation timed out.") }
        if stopped { throw CancellationError() }
    }
}

private final class CapturedBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var exceeded = false
    func append(_ data: Data, limit: Int) {
        lock.lock(); defer { lock.unlock() }
        if data.count > limit - bytes.count { exceeded = true }
        bytes.append(data.prefix(max(0, limit - bytes.count)))
    }
    var result: (Data, Bool) { lock.lock(); defer { lock.unlock() }; return (bytes, exceeded) }
}

enum ProcessRunner {
    static func blocking(_ executable: String, _ arguments: [String], directory: URL? = nil,
                         timeout: TimeInterval = 30, outputLimit: Int = 2 * 1024 * 1024,
                         rejectOverflow: Bool = true, control: ProcessControl = ProcessControl(),
                         onOutput: (@Sendable (Data) -> Void)? = nil) throws -> ProcessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out; process.standardError = err
        try control.start(process)
        let deadline = DispatchWorkItem { control.stop(timeout: true) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        defer { deadline.cancel() }
        let stdout = CapturedBytes(), stderr = CapturedBytes(), readers = DispatchGroup()
        for (pipe, buffer, callback) in [(out, stdout, onOutput), (err, stderr, nil)] {
            readers.enter()
            DispatchQueue.global().async {
                defer { readers.leave(); try? pipe.fileHandleForReading.close() }
                while let data = try? pipe.fileHandleForReading.read(upToCount: 65_536), !data.isEmpty {
                    buffer.append(data, limit: outputLimit)
                    callback?(data)
                    if rejectOverflow && buffer.result.1 { control.stop(); break }
                }
            }
        }
        process.waitUntilExit()
        readers.wait()
        if rejectOverflow && (stdout.result.1 || stderr.result.1) {
            throw ConversionError(message: "Process output exceeded the allowed limit.")
        }
        try control.check()
        return ProcessOutput(status: process.terminationStatus, stdout: stdout.result.0, stderr: stderr.result.0)
    }

    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 3600,
                    onOutput: (@Sendable (Data) -> Void)? = nil) async throws -> ProcessOutput {
        let control = ProcessControl()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: try blocking(executable, arguments, timeout: timeout,
                                                                   rejectOverflow: false, control: control, onOutput: onOutput))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { control.stop() }
    }
}
