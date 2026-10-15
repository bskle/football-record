// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MatchCore",
    platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v14)],
    products: [.library(name: "MatchCore", targets: ["MatchCore"]), .library(name: "MatchStore", targets: ["MatchStore"])],
    targets: [.target(name: "MatchCore"), .testTarget(name: "MatchCoreTests", dependencies: ["MatchCore"]),
              .target(name: "MatchStore", dependencies: ["MatchCore"], linkerSettings: [.linkedLibrary("sqlite3")]),
              .testTarget(name: "MatchStoreTests", dependencies: ["MatchStore", "MatchCore"])]
)
