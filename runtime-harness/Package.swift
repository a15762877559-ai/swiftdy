// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DouStudioRuntimeAcceptance",
    platforms: [.macOS("27.0")],
    dependencies: [.package(path: "../upstream")],
    targets: [
        .target(
            name: "SafeDownloadSupport",
            dependencies: [.product(name: "DouStudioKit", package: "upstream")],
            path: "safe-streaming-tests/Sources/SafeStreamingTests",
            exclude: ["ControlledTests.swift", "DownloadIntegration.swift"],
            sources: ["SafeStreamingTransport.swift", "StreamFileTools.swift", "IntegrationMedia.swift", "IntegrationPolicy.swift", "SingleVideoDownloadBridge.swift"]
        ),
        .executableTarget(
            name: "RuntimeAcceptance",
            dependencies: [.product(name: "DouStudioKit", package: "upstream"), "SafeDownloadSupport"]
        )
    ]
)
