// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "VolumeMixer", platforms: [.macOS("14.4")], products: [.executable(name: "VolumeMixer", targets: ["VolumeMixer"])], targets: [
    .target(name: "AudioDSP", publicHeadersPath: "include", linkerSettings: [.linkedFramework("CoreAudio")]),
    .executableTarget(name: "VolumeMixer", dependencies: ["AudioDSP"], swiftSettings: [.swiftLanguageMode(.v5)], linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("CoreAudio")]),
    .testTarget(name: "AudioDSPTests", dependencies: ["AudioDSP"])
])
