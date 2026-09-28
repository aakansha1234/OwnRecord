// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "OwnRecord",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "OwnRecord",
            path: "Sources/OwnRecord",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "OwnRecordTests",
            dependencies: ["OwnRecord"],
            path: "Tests/OwnRecordTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
