// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "WorkoutCapture", platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v14)],
  products: [.library(name: "WorkoutCapture", targets: ["WorkoutCapture"])],
  dependencies: [.package(path: "../../Packages/MatchCore")],
  targets: [.target(name: "WorkoutCapture", dependencies: [.product(name: "MatchCore", package: "MatchCore"), .product(name: "MatchSession", package: "MatchCore")]),
    .testTarget(name: "WorkoutCaptureTests", dependencies: ["WorkoutCapture", .product(name: "MatchCore", package: "MatchCore")])])
