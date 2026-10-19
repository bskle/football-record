// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "HealthKitDeletion", platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v14)],
    products: [.library(name: "HealthKitDeletion", targets: ["HealthKitDeletion"])],
    dependencies: [.package(path: "../../Packages/MatchCore")],
    targets: [.target(name: "HealthKitDeletion", linkerSettings: [.linkedLibrary("sqlite3")]),
              .testTarget(name: "HealthKitDeletionTests", dependencies: ["HealthKitDeletion", .product(name: "MatchCore", package: "MatchCore"), .product(name: "MatchSession", package: "MatchCore")])])
