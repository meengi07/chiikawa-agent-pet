// swift-tools-version: 6.0
import PackageDescription
import Foundation

let package = Package(
    name: "ChiikawaPet",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ChiikawaPet", targets: ["ChiikawaPet"])],
    targets: [
        .executableTarget(
            name: "ChiikawaPet",
            path: ".",
            exclude: [
                "build", "mac/Tests", "mac/Resources", "mac/README.md", "mac/README.ko.md",
                "windows", "scripts", "docs",
                "README.md", "README.ko.md", "CHANGELOG.md", "LICENSE", "VERSION", "Launch.command",
                "assets/NOTICE.md"
            ].filter {
                FileManager.default.fileExists(atPath: URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent().appendingPathComponent($0).path)
            },
            sources: ["mac/Sources/ChiikawaPet"],
            resources: [.process("assets")]
        ),
        .testTarget(
            name: "ChiikawaPetTests", dependencies: ["ChiikawaPet"],
            path: "mac/Tests/ChiikawaPetTests"
        )
    ]
)
