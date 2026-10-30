// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TrackpadPreview",
    platforms: [.macOS(.v14)],
    products: [.library(name: "TrackpadCore", targets: ["TrackpadCore"])],
    targets: [
        .target(name: "TrackpadCore"),
        .testTarget(name: "TrackpadCoreTests", dependencies: ["TrackpadCore"])
    ]
)
