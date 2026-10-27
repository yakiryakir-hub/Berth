// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "Berth",
    platforms: [
        .macOS(.v26)
    ],
    targets: [
        // Thin C shim over Apple's IOUSBLib (IOUSBInterfaceInterface), the
        // user-space USB API libusb uses on macOS.
        .target(
            name: "CBerthUSB",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        // MTP/PTP protocol over IOUSBLib. No UI, no server.
        .target(
            name: "MTPKit",
            dependencies: ["CBerthUSB"],
            linkerSettings: [
                .linkedFramework("IOKit"),
            ]
        ),
        // Local WebDAV server: how the device tree becomes a mounted volume,
        // via macOS's built-in mount_webdav. No MTP dependency; any DavBackend.
        .target(
            name: "DavKit"
        ),
        // Menu bar app: device watching, WebDAV serving, mounting.
        .executableTarget(
            name: "Berth",
            dependencies: ["MTPKit", "DavKit"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
                // Only for removing stale domains left by the abandoned
                // File Provider build.
                .linkedFramework("FileProvider"),
            ]
        ),
        // Terminal test harness: MTP codec + WebDAV server tests, no device.
        .executableTarget(
            name: "BerthSelfCheck",
            dependencies: ["MTPKit", "DavKit"]
        ),
        // Renders the app icon in code, per size. No image assets.
        .executableTarget(
            name: "IconGenerator"
        ),
    ],
    swiftLanguageModes: [.v6]
)
