// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Stillframe",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Stillframe", resources: [.copy("Resources/Welcome.jpg")]),
        .testTarget(name: "StillframeTests", dependencies: ["Stillframe"])
    ]
)
