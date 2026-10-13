// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CommuteCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "CommuteCore", targets: ["CommuteCore"])],
    targets: [
        .target(name: "CommuteCore"),
        .testTarget(name: "CommuteCoreTests", dependencies: ["CommuteCore"])
    ]
)
