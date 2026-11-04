// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AceStreamPlayer",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic (link parsing, engine JSON, Mach-O checks) — unit-tested.
        .target(name: "AceCore", path: "Sources/AceCore"),
        // The macOS application itself (AppKit + SwiftUI).
        .executableTarget(
            name: "AceStreamPlayer",
            dependencies: ["AceCore"],
            path: "Sources/AceStreamPlayer"
        ),
        .testTarget(name: "AceCoreTests", dependencies: ["AceCore"], path: "Tests/AceCoreTests"),
    ]
)
