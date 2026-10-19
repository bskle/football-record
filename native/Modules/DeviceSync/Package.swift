// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "DeviceSync", platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v14)], products: [.library(name: "DeviceSync", targets: ["DeviceSync"])], dependencies: [.package(path: "../../Packages/MatchCore")], targets: [.systemLibrary(name: "CSQLite"), .target(name: "DeviceSync", dependencies: ["CSQLite", .product(name: "MatchSync", package: "MatchCore")]), .testTarget(name: "DeviceSyncTests", dependencies: ["DeviceSync"])])
