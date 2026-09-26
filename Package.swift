// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Limitter",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Limitter", targets: ["Limitter"])],
    targets: [
        .target(name: "LimitterCore"),
        .executableTarget(name: "Limitter", dependencies: ["LimitterCore"]),
        .testTarget(name: "LimitterCoreTests", dependencies: ["LimitterCore"])
    ]
)
