// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ChipBar",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "ChipBar", targets: ["ChipBar"])],
    targets: [
        .target(name: "ChipBarCore"),
        .executableTarget(name: "ChipBar", dependencies: ["ChipBarCore"]),
        .testTarget(name: "ChipBarCoreTests", dependencies: ["ChipBarCore"], resources: [.copy("Fixtures")])
    ]
)
