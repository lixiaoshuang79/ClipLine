// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClipLine",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ClipLine", path: "Sources/ClipLine")
    ]
)
