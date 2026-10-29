// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "floorplan",
    platforms: [.macOS("27.0")],
    targets: [
        .target(
            name: "FloorPlanCore",
            path: "Sources/FloorPlanCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "fp-fix",
            dependencies: ["FloorPlanCore"],
            path: "Sources/fp-fix",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "Extractor",
            path: "Sources/Extractor",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "fp-extract",
            dependencies: ["Extractor"],
            path: "Sources/fp-extract",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ExtractorTests",
            dependencies: ["Extractor"],
            path: "Tests/ExtractorTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "FloorPlanCoreTests",
            dependencies: ["FloorPlanCore"],
            path: "Tests/FloorPlanCoreTests",
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
