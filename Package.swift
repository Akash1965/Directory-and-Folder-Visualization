// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "ChangeLink",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ChangeLinkCore", targets: ["ChangeLinkCore"]),
        .executable(name: "ChangeLinkApp", targets: ["ChangeLinkApp"]),
        .executable(name: "ChangeLinkSelfTest", targets: ["ChangeLinkSelfTest"])
    ],
    targets: [
        .target(name: "ChangeLinkCore"),
        .executableTarget(name: "ChangeLinkApp", dependencies: ["ChangeLinkCore"]),
        .executableTarget(name: "ChangeLinkSelfTest", dependencies: ["ChangeLinkCore"]),
        .testTarget(name: "ChangeLinkCoreTests", dependencies: ["ChangeLinkCore"])
    ]
)
