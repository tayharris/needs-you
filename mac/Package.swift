// swift-tools-version:5.9
import PackageDescription

// NeedsYou: the macOS reader for the needs-you hub (see docs/PLAN.md, "Mac app design").
//
// Targets:
//   NeedsYouCore      Model, hub client, demo source, merge/count logic, link policy,
//                     panel geometry. Foundation only, so it is unit-testable.
//   NeedsYou          The app (AppKit NSPanel + SwiftUI). `scripts/bundle.sh` wraps it
//                     into dist/NeedsYou.app.
//   MiniXCTest        A tiny XCTest stand-in so the same test files can run on a Mac
//                     with only the Command Line Tools (no XCTest there).
//   needsyou-selftest Runs Tests/NeedsYouCoreTests through MiniXCTest (`swift run needsyou-selftest`).
//   NeedsYouCoreTests The XCTest target (`swift test`, needs Xcode's XCTest).
let package = Package(
    name: "NeedsYou",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NeedsYou", targets: ["NeedsYou"]),
    ],
    targets: [
        .target(name: "NeedsYouCore"),
        .executableTarget(
            name: "NeedsYou",
            dependencies: ["NeedsYouCore"],
            linkerSettings: [.linkedFramework("Carbon")]
        ),
        .target(name: "MiniXCTest"),
        .executableTarget(
            name: "needsyou-selftest",
            dependencies: ["NeedsYouCore", "MiniXCTest"],
            path: "Sources/NeedsYouSelfTest",
            swiftSettings: [.define("NEEDSYOU_SELFTEST")]
        ),
        .testTarget(name: "NeedsYouCoreTests", dependencies: ["NeedsYouCore"]),
    ]
)
