// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SnoreCore",
    platforms: [.macOS(.v13), .iOS(.v26)],
    products: [.library(name: "SnoreCore", targets: ["SnoreCore"]),
               .executable(name: "snore-analyze", targets: ["snore-analyze"])],
    targets: [.target(name: "SnoreCore"),
              .executableTarget(name: "snore-analyze", dependencies: ["SnoreCore"]),
              .testTarget(name: "SnoreCoreTests", dependencies: ["SnoreCore"])])
