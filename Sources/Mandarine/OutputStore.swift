import Foundation
import Darwin

/// Writes into a private directory on the destination volume, then publishes with an atomic,
/// exclusive rename. No converter ever receives the path of a user's existing file.
enum OutputStore {
    static func transaction(source: URL, folder: URL?, work: (URL) async throws -> [URL]) async throws -> [URL] {
        let parent = folder ?? source.deletingLastPathComponent()
        let stage = parent.resolvingSymlinksInPath().appendingPathComponent(".mandarine-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stage) }
        let outputs = try await work(stage)
        try Task.checkCancellation()
        let children = try FileManager.default.contentsOfDirectory(at: stage, includingPropertiesForKeys: nil)
        let relative = try outputs.map { output -> (URL, String) in
            let path = output.standardizedFileURL.path
            guard let child = children.first(where: {
                path == $0.standardizedFileURL.path || path.hasPrefix($0.standardizedFileURL.path + "/")
            }) else { throw ConversionError(message: "Output is outside the working folder.") }
            return (child, String(path.dropFirst(child.standardizedFileURL.path.count)))
        }
        var published: [(URL, URL)] = []
        do {
            for child in children {
                try Task.checkCancellation()
                published.append((child, try publish(child, in: parent)))
            }
        } catch {
            // These names belong exclusively to this transaction.
            for (_, target) in published { try? FileManager.default.removeItem(at: target) }
            throw error
        }
        return relative.map { old, suffix in
            let new = published.first { $0.0 == old }!.1
            return URL(fileURLWithPath: new.path + suffix)
        }
    }

    static func publish(_ source: URL, in parent: URL) throws -> URL {
        let name = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var number = 1
        while true {
            let basename = number == 1 ? source.lastPathComponent : name + " \(number)" + (ext.isEmpty ? "" : "." + ext)
            let target = parent.appendingPathComponent(basename)
            let result = source.path.withCString { src in
                target.path.withCString { dst in renamex_np(src, dst, UInt32(RENAME_EXCL)) }
            }
            if result == 0 { return target }
            let code = errno
            guard code == EEXIST else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
            number += 1
        }
    }
}
