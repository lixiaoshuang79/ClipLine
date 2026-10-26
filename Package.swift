// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClipLine",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ClipLine", path: "Sources/ClipLine"),
        .executableTarget(name: "ClipLineOCRHelper", path: "Sources/ClipLineOCRHelper"),
        .testTarget(name: "ClipLineTests", dependencies: ["ClipLine"], path: "Tests/ClipLineTests"),
    ]
)
