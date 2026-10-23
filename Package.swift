// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Horizon",
    platforms: [.macOS("27.0"), .iOS("27.0")],
    products: [
        .library(name: "IngestKit", targets: ["IngestKit"]),
        .library(name: "HorizonCore", targets: ["HorizonCore"]),
        .executable(name: "horizon-parse", targets: ["HorizonParse"]),
    ],
    targets: [
        .target(name: "IngestKit"),
        .target(name: "HorizonCore", dependencies: ["IngestKit"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "HorizonParse", dependencies: ["IngestKit"]),
        .testTarget(name: "IngestKitTests", dependencies: ["IngestKit"]),
        .testTarget(name: "HorizonCoreTests", dependencies: ["HorizonCore"]),
        .testTarget(name: "IngestEvals", dependencies: ["IngestKit"]),
    ],
    swiftLanguageModes: [.v6]
)
