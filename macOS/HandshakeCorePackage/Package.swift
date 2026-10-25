// swift-tools-version: 6.2

import Foundation
import PackageDescription

let artifactName = "HandshakeCore.xcframework"
let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let artifactURL = packageDirectory.appendingPathComponent(artifactName)

guard FileManager.default.fileExists(atPath: artifactURL.path) else {
    fatalError(
        """
        HandshakeCore.xcframework is missing. From the repository root, run \
        'make debug' for Debug builds or \
        'make release' for Release builds.
        """
    )
}

let package = Package(
    name: "HandshakeCorePackage",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "HandshakeCore", targets: ["HandshakeCore"])
    ],
    targets: [
        .binaryTarget(name: "HandshakeCore", path: artifactName)
    ]
)
