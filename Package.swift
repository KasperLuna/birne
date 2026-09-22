
// swift-tools-version: 6.0
import PackageDescription
 
let package = Package(
    name: "birne",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "birne",
            path: "."
        ),
    ]
)
