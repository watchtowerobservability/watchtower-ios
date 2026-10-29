// swift-tools-version:5.9
// Thin Watchtower distribution for iOS (ruling L1): RUM batches, crash/hang/app-start/frame
// metrics and masked screenshot replay over the Watchtower edge. No product logic lives here.
import PackageDescription

let package = Package(
    name: "Watchtower",
    platforms: [.iOS(.v13), .macOS(.v11)],
    products: [.library(name: "Watchtower", targets: ["Watchtower"])],
    targets: [
        .target(name: "Watchtower"),
        .testTarget(name: "WatchtowerTests", dependencies: ["Watchtower"]),
    ]
)
