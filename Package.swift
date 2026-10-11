// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "TR7Mac", platforms: [.macOS(.v12)],
    products: [.library(name: "TR7Core", targets: ["TR7Core"]),
               .executable(name: "TR7Mac", targets: ["TR7Mac"]),
               .executable(name: "tr7", targets: ["TR7Tool"]),
               .executable(name: "TR7Checks", targets: ["TR7Checks"])],
    targets: [.target(name: "TR7Core"),
              .executableTarget(name: "TR7Mac", dependencies: ["TR7Core"]),
              .executableTarget(name: "TR7Tool", dependencies: ["TR7Core"]),
              .executableTarget(name: "TR7Checks", dependencies: ["TR7Core"])])
