// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Tazzina",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "TazzinaShared", path: "Sources/TazzinaShared"),
        .executableTarget(name: "Tazzina", dependencies: ["TazzinaShared"], path: "Sources/Tazzina"),
        .executableTarget(name: "TazzinaHelper", dependencies: ["TazzinaShared"], path: "Sources/TazzinaHelper")
    ]
)
