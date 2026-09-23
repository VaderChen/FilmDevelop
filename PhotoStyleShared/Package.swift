// swift-tools-version: 6.0

import PackageDescription
import Foundation

// Tests remain local and are absent from the public checkout.
var sharedTargets: [Target] = [.target(name: "PhotoStyleShared")]
let localTests = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Tests/PhotoStyleSharedTests")
if FileManager.default.fileExists(atPath: localTests.path) {
    sharedTargets.append(.testTarget(
        name: "PhotoStyleSharedTests",
        dependencies: ["PhotoStyleShared"]
    ))
}

let package = Package(
    name: "PhotoStyleShared",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "PhotoStyleShared",
            targets: ["PhotoStyleShared"]
        )
    ],
    targets: sharedTargets
)
