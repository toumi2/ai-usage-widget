// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexUsageWidget",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "CodexUsageWidget", targets: ["CodexUsageWidget"])
    ],
    targets: [
        .executableTarget(name: "CodexUsageWidget"),
        .testTarget(name: "CodexUsageWidgetTests", dependencies: ["CodexUsageWidget"])
    ]
)
