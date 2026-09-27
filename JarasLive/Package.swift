// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "JarasLiveApplication", platforms: [.macOS(.v13), .iOS(.v16)], products: [.library(name: "JarasApplication", targets: ["JarasApplication"])], targets: [.target(name: "JarasApplication", path: "Application"), .testTarget(name: "JarasApplicationTests", dependencies: ["JarasApplication"], path: "Tests/Application")])
