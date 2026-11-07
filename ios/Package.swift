// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "SnoreLogHost", platforms: [.macOS(.v13)], products: [.executable(name: "demo-check", targets: ["DemoCheck"])], dependencies: [.package(path: "../core")], targets: [
    .target(name: "SnoreLog", dependencies: [.product(name: "SnoreCore", package: "core")], path: "SnoreLog", exclude: ["Info.plist", "AlarmService.swift", "CaptureService.swift", "AppState.swift", "Views.swift", "SnoreLogApp.swift"], sources: ["NightStore.swift", "RecordingPipeline.swift", "FileSnoreClassifier.swift", "DemoRunner.swift", "Provisioning.swift", "PCMQueue.swift", "RecoveryController.swift", "DisplayFormat.swift", "ClipAmplifier.swift"]),
    .executableTarget(name: "DemoCheck", dependencies: ["SnoreLog"]),
    .testTarget(name: "SnoreLogTests", dependencies: ["SnoreLog", .product(name: "SnoreCore", package: "core")], path: "SnoreLogTests")
], swiftLanguageModes: [.v5])
