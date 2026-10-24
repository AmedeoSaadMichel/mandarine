import Foundation
import XCTest
@testable import Mandarine

final class BundledFFmpegTests: XCTestCase {
    func testBundledRuntimeWorksWithoutExternalInstallationAndTakesPriority() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Mandarine.app")
        let helper = app.appendingPathComponent("Contents/Helpers/ffmpeg")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        XCTAssertEqual(Converter.findFFmpeg(bundleURL: app, externalPaths: []), helper.path)
        XCTAssertEqual(Converter.findFFmpeg(bundleURL: app, externalPaths: ["/bin/sh"]), helper.path)
        try FileManager.default.removeItem(at: helper)
        XCTAssertEqual(Converter.findFFmpeg(bundleURL: app, externalPaths: ["/bin/sh"]), "/bin/sh")
        XCTAssertNil(Converter.findFFmpeg(bundleURL: app, externalPaths: []))
    }
}
