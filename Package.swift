// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Shurufa",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Shurufa", targets: ["Shurufa"])],
    targets: [
        .target(name: "TranslationCore", resources: [.copy("Resources/AGENTS.md"), .copy("Resources/AGENTS-v1.md")]),
        .executableTarget(name: "Shurufa", dependencies: ["TranslationCore"]),
        .executableTarget(name: "AgentFixture", path: "Tests/AgentFixture"),
        .testTarget(name: "TranslationCoreTests", dependencies: ["TranslationCore", "AgentFixture"])
    ]
)
