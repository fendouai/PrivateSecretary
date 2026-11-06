// swift-tools-version: 6.0
import PackageDescription
import Foundation

// Some Command Line Tools installations ship Swift Testing but do not add its
// framework module path to SwiftPM's default search paths. The matching
// `make test` / scripts/test.sh setup creates the module symlink; linker settings
// here only apply when the frameworks actually exist.
let testingFrameworkCandidates = [
    "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
    "/Applications/Xcode.app/Contents/Developer/Library/Developer/Frameworks"
]
let testingFrameworkDirectory = testingFrameworkCandidates.first {
    FileManager.default.fileExists(atPath: $0 + "/Testing.framework")
}
let testSwiftSettings: [SwiftSetting] = []
let testLinkerSettings: [LinkerSetting]
if let testingFrameworkDirectory {
    testLinkerSettings = [
        .linkedFramework("Testing"),
        .unsafeFlags([
            "-F", testingFrameworkDirectory,
            "-Xlinker", "-rpath", "-Xlinker", testingFrameworkDirectory
        ])
    ]
} else {
    testLinkerSettings = []
}

let package = Package(
    name: "PrivateSecretary",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "SecretaryKit", targets: ["SecretaryKit"]),
        .executable(name: "secretary", targets: ["secretary"]),
        .executable(name: "secretary-mcp", targets: ["secretary-mcp"]),
        .executable(name: "secretaryd", targets: ["secretaryd"])
    ],
    targets: [
        .target(
            name: "SecretaryKit",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(name: "secretary", dependencies: ["SecretaryKit"]),
        .executableTarget(name: "secretary-mcp", dependencies: ["SecretaryKit"]),
        .executableTarget(name: "secretaryd", dependencies: ["SecretaryKit"]),
        .testTarget(
            name: "SecretaryKitTests",
            dependencies: ["SecretaryKit"],
            exclude: ["Fixtures"],
            swiftSettings: testSwiftSettings,
            linkerSettings: testLinkerSettings
        )
    ],
    swiftLanguageModes: [.v5]
)
