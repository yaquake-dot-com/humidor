// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Swift port of Nicotine+ (https://nicotine-plus.org), a graphical client
// for the Soulseek peer-to-peer network.

import PackageDescription

let package = Package(
    name: "NicotinePlus",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "NicotineCore", targets: ["NicotineCore"]),
        .executable(name: "nicotine", targets: ["nicotine"]),
        .executable(name: "NicotinePlus", targets: ["NicotinePlus"])
    ],
    targets: [
        // Protocol, networking and application logic (no UI)
        .target(
            name: "NicotineCore",
            resources: [
                .process("Localizable.xcstrings"),
                // IP2Location LITE data, licensed under CC BY-SA 4.0
                .copy("Resources/ip_country_data.csv")
            ]
        ),
        // Headless command line client
        .executableTarget(
            name: "nicotine",
            dependencies: ["NicotineCore"]
        ),
        // macOS application (SwiftUI, with AppKit list views)
        .executableTarget(
            name: "NicotinePlus",
            dependencies: ["NicotineCore"],
            resources: [
                .process("Localizable.xcstrings")
            ]
        ),
        .testTarget(
            name: "NicotineCoreTests",
            dependencies: ["NicotineCore"],
            resources: [
                .copy("Fixtures")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
