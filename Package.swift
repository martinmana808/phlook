// swift-tools-version: 5.10
import PackageDescription

// NOTE (CLT-only): On Command Line Tools-only machines (no full Xcode), the
// Testing framework requires an extra framework search path to compile and
// link. Use `make test` instead of bare `swift test` in that environment.

let package = Package(
    name: "Phlook",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.29.0")
    ],
    targets: [
        .target(
            name: "PhlookCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .executableTarget(
            name: "Phlook",
            dependencies: ["PhlookCore"]
        ),
        .executableTarget(
            name: "phlook-ingest",
            dependencies: ["PhlookCore"]
        ),
        .testTarget(
            name: "PhlookCoreTests",
            dependencies: ["PhlookCore"],
            // CLT-only workaround: Testing.framework lives outside the SDK
            // and requires an explicit -F search path for both compile and link.
            swiftSettings: [
                .unsafeFlags(
                    ["-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"],
                    .when(platforms: [.macOS])
                )
            ],
            linkerSettings: [
                .unsafeFlags(
                    ["-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                     "-framework", "Testing",
                     "-Xlinker", "-rpath",
                     "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                     "-L", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
                     "-Xlinker", "-rpath",
                     "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"],
                    .when(platforms: [.macOS])
                )
            ]
        ),
    ]
)
