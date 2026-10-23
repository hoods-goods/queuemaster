// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "QueueMaster",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "QueueMaster", targets: ["QueueMaster"]),
        .library(name: "CupsKit", targets: ["CupsKit"]),
    ],
    targets: [
        // Everything that talks to CUPS: runs the command-line tools, parses
        // their output and PPD files. No UI code, so it can be unit tested.
        .target(name: "CupsKit"),
        // The SwiftUI app.
        .executableTarget(name: "QueueMaster", dependencies: ["CupsKit"]),
        .testTarget(
            name: "CupsKitTests",
            dependencies: ["CupsKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
