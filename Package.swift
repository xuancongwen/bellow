// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "BellowFlow", platforms: [.macOS(.v13)], products: [
    .executable(name: "BellowFlow", targets: ["BellowFlow"]),
    .executable(name: "VoxClean", targets: ["VoxClean"])
], targets: [
    .executableTarget(name: "BellowFlow", linkerSettings: [.linkedFramework("Carbon"), .linkedFramework("AVFoundation")]),
    .executableTarget(name: "VoxClean")
])
