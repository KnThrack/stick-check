// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StickCheck",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure measurement logic: value types only, no IOKit, no UI.
        .target(name: "StickCore"),
        // Reads the joystick through IOKit HID. Read-only: never writes to the device.
        .target(name: "StickHID", dependencies: ["StickCore"]),
        .executableTarget(name: "StickCheck", dependencies: ["StickCore", "StickHID"]),
        .testTarget(name: "StickCoreTests", dependencies: ["StickCore"]),
    ]
)
