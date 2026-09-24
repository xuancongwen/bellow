// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Bellow", platforms: [.macOS(.v13)], products: [
    .executable(name: "Bellow", targets: ["Bellow"]),
    .executable(name: "VoxClean", targets: ["VoxClean"])
], targets: [
    .executableTarget(name: "Bellow", linkerSettings: [.linkedFramework("Carbon"), .linkedFramework("AVFoundation")]),
    .executableTarget(name: "VoxClean"),
    .testTarget(name: "BellowTests", dependencies: ["Bellow"], path: "tests/swift")
])
