// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Boxtop",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Boxtop", targets: ["Boxtop"]),
    ],
    targets: [
        // Low-level macOS system access (SMC, HID thermal sensors, IOReport GPU,
        // 64-bit interface counters, process arguments). Ported from btop's src/osx.
        .target(
            name: "CSysInfo",
            path: "Sources/CSysInfo",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .executableTarget(
            name: "Boxtop",
            dependencies: ["CSysInfo"],
            path: "Sources/Boxtop",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
        .testTarget(
            name: "BoxtopTests",
            dependencies: ["Boxtop"],
            path: "Tests/BoxtopTests"
        ),
    ]
)
