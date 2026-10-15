// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "StockWidget",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "StockWidget",
            path: "Sources/StockWidget"
        )
    ]
)
