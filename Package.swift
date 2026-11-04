// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeccanoidLink",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MeccanoidCore", targets: ["MeccanoidCore"]),
        .library(name: "MeccanoidBluetooth", targets: ["MeccanoidBluetooth"])
    ],
    targets: [
        .target(name: "MeccanoidCore"),
        .target(name: "MeccanoidBluetooth", dependencies: ["MeccanoidCore"]),
        .testTarget(name: "MeccanoidCoreTests", dependencies: ["MeccanoidCore"]),
        .testTarget(name: "MeccanoidBluetoothTests", dependencies: ["MeccanoidBluetooth", "MeccanoidCore"])
    ],
    swiftLanguageModes: [.v5]
)
