// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FlowTrace",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FlowTraceCore", targets: ["FlowTraceCore"]),
        .executable(name: "FlowTraceApp", targets: ["FlowTraceApp"]),
        .executable(name: "flowtrace", targets: ["flowtrace"]),
        .executable(name: "flowtrace-tests", targets: ["FlowTraceTests"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "FlowTraceCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "FlowTraceApp",
            dependencies: ["FlowTraceCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "flowtrace",
            dependencies: [
                "FlowTraceCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The suite is an executable, not a testTarget: XCTest ships with Xcode
        // and FlowTrace builds with the Command Line Tools only.
        .executableTarget(
            name: "FlowTraceTests",
            dependencies: ["FlowTraceCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
