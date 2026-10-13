// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeshKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MeshKitCore", targets: ["MeshKitCore"]),
        .executable(name: "MeshKit", targets: ["MeshKit"]),
        .executable(name: "esp-sim", targets: ["ESPSim"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.0"),
    ],
    targets: [
        // Generated from Meshtastic's GPL-3.0 protobuf definitions; see Sources/MeshtasticProtobufs/NOTICE.md.
        .target(name: "MeshtasticProtobufs", dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")],
                exclude: ["NOTICE.md", "LICENSE-GPL-3.0"]),
        .target(name: "MeshKitCore", dependencies: ["MeshtasticProtobufs", .product(name: "SwiftProtobuf", package: "swift-protobuf")],
                resources: [.copy("Resources/Stubs")]),
        .executableTarget(name: "MeshKit", dependencies: ["MeshKitCore", "MeshtasticProtobufs"]),
        .executableTarget(name: "ESPSim", dependencies: ["MeshKitCore"]),
        .testTarget(name: "MeshKitCoreTests", dependencies: ["MeshKitCore"]),
    ],
    swiftLanguageModes: [.v5]
)
