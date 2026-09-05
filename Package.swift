// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Horizon",
    platforms: [.macOS("27.0"), .iOS("27.0")],
    products: [
        .library(name: "IngestKit", targets: ["IngestKit"]),
        .executable(name: "horizon-parse", targets: ["HorizonParse"]),
    ],
    targets: [
        .target(name: "IngestKit"),
        .executableTarget(name: "HorizonParse", dependencies: ["IngestKit"]),
        .testTarget(name: "IngestKitTests", dependencies: ["IngestKit"]),
        .testTarget(name: "IngestEvals", dependencies: ["IngestKit"]),
    ],
    swiftLanguageModes: [.v6]
)
