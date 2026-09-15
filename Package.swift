// swift-tools-version:5.10
import PackageDescription

// `swift run` opens the window, and Xcode opens this file as a project.
let package = Package(
    name: "MangaworldDownloader",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(name: "MangaworldDownloader", path: "Sources"),
        .testTarget(name: "Tests", dependencies: ["MangaworldDownloader"], path: "Tests"),
    ]
)
