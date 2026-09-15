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
        .executable(name: "nicotine", targets: ["nicotine"])
    ],
    targets: [
        // Protocol, networking and application logic (no UI)
        .target(
            name: "NicotineCore",
            resources: [
                .copy("Resources/locale"),
                // IP2Location LITE data, licensed under CC BY-SA 4.0
                .copy("Resources/ip_country_data.csv")
            ]
        ),
        // Headless command line client
        .executableTarget(
            name: "nicotine",
            dependencies: ["NicotineCore"]
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
