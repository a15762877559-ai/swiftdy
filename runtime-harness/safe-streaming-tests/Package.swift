// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "SafeStreamingAcceptance", platforms: [.macOS("27.0")],
    dependencies: [.package(path: "../../upstream")],
    targets: [.executableTarget(name: "SafeStreamingTests", dependencies: [.product(name: "DouStudioKit", package: "upstream")])])
