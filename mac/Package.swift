// swift-tools-version:5.9
import PackageDescription

// NeedsTay: the macOS reader for the needs-tay hub (see docs/PLAN.md, "Mac app design").
//
// Targets:
//   NeedsTayCore      Model, hub client, demo source, merge/count logic, link policy,
//                     panel geometry. Foundation only, so it is unit-testable.
//   NeedsTay          The app (AppKit NSPanel + SwiftUI). `scripts/bundle.sh` wraps it
//                     into dist/NeedsTay.app.
//   MiniXCTest        A tiny XCTest stand-in so the same test files can run on a Mac
//                     with only the Command Line Tools (no XCTest there).
//   needstay-selftest Runs Tests/NeedsTayCoreTests through MiniXCTest (`swift run needstay-selftest`).
//   NeedsTayCoreTests The XCTest target (`swift test`, needs Xcode's XCTest).
let package = Package(
    name: "NeedsTay",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NeedsTay", targets: ["NeedsTay"]),
    ],
    targets: [
        .target(name: "NeedsTayCore"),
        .executableTarget(
            name: "NeedsTay",
            dependencies: ["NeedsTayCore"],
            linkerSettings: [.linkedFramework("Carbon")]
        ),
        .target(name: "MiniXCTest"),
        .executableTarget(
            name: "needstay-selftest",
            dependencies: ["NeedsTayCore", "MiniXCTest"],
            path: "Sources/NeedsTaySelfTest",
            swiftSettings: [.define("NEEDSTAY_SELFTEST")]
        ),
        .testTarget(name: "NeedsTayCoreTests", dependencies: ["NeedsTayCore"]),
    ]
)
