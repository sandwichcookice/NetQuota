// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "NetQuota",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "NetQuotaCore", path: "Sources/NetQuotaCore"),
        .executableTarget(
            name: "NetQuota",
            dependencies: ["NetQuotaCore"],
            path: "Sources/NetQuota"
        ),
        .testTarget(
            name: "NetQuotaTests",
            dependencies: ["NetQuotaCore"],
            path: "Tests/NetQuotaTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
