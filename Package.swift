// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "DENG-monitor", platforms: [.macOS(.v14)], targets: [
    .target(name: "CIOReport", path: "Support/CIOReport", publicHeadersPath: "include"),
    .executableTarget(name: "DENGMonitor", dependencies: ["CIOReport"], path: "Sources/SiliconMonitor", linkerSettings: [.unsafeFlags(["-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup"])])
])
