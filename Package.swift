// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Mandarine",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Mandarine", path: "Sources/Mandarine", resources: [.copy("Resources")]),
        .testTarget(name: "MandarineTests", dependencies: ["Mandarine"], path: "Tests/MandarineTests")
    ]
)
