// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MatchCore",
    platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v14)],
    products: [.library(name: "MatchCore", targets: ["MatchCore"]), .library(name: "MatchStore", targets: ["MatchStore"]), .library(name: "MatchSession", targets: ["MatchSession"])],
    targets: [.target(name: "MatchCore"), .testTarget(name: "MatchCoreTests", dependencies: ["MatchCore"]),
              .target(name: "MatchStore", dependencies: ["MatchCore"], linkerSettings: [.linkedLibrary("sqlite3")]),
              .target(name: "MatchSession", dependencies: ["MatchCore", "MatchStore"]),
              .testTarget(name: "MatchSessionTests", dependencies: ["MatchSession", "MatchStore", "MatchCore"]),
              .testTarget(name: "MatchStoreTests", dependencies: ["MatchStore", "MatchCore"], resources: [.copy("Fixtures")])]
)
