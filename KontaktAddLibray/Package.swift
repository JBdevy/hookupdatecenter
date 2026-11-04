// swift-tools-version: 5.9
import PackageDescription

let package = Package(name: "KontaktAddLibray", platforms: [.macOS(.v12)], products: [
    .executable(name: "KontaktAddLibray", targets: ["KontaktAddLibray"]),
    .executable(name: "KontaktLibraryInstaller", targets: ["KontaktLibraryInstaller"])
], targets: [
    .target(name: "KontaktLibraryCore"),
    .executableTarget(name: "KontaktAddLibray", dependencies: ["KontaktLibraryCore"]),
    .executableTarget(name: "KontaktLibraryInstaller", dependencies: ["KontaktLibraryCore"]),
    .testTarget(name: "KontaktLibraryCoreTests", dependencies: ["KontaktLibraryCore"])
])
