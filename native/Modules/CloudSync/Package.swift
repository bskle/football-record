// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "CloudSync", platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v14)],
 products: [.library(name: "CloudSync", targets: ["CloudSync"])],
 dependencies: [.package(path: "../../Packages/MatchCore")],
 targets: [.target(name: "CloudSync", dependencies: [.product(name: "MatchCore", package: "MatchCore")], linkerSettings: [.linkedLibrary("sqlite3")]),
 .testTarget(name: "CloudSyncTests", dependencies: ["CloudSync", .product(name: "MatchStore", package: "MatchCore")])])
