#!/bin/bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
build_root="${NATIVE_BUILD_ROOT:-"$repo_root/native/.build"}"
log_dir="$build_root/logs/$(date -u +%Y%m%dT%H%M%SZ)"
project="$repo_root/native/FootballRecord.xcodeproj"
package="$repo_root/native/Packages/MatchCore"
mkdir -p "$log_dir"

printf 'Native verification logs: %s\n' "$log_dir"
swift test --package-path "$package" --scratch-path "$build_root/SwiftPM" \
    2>&1 | tee "$log_dir/swift-test.log"
# Compile service products explicitly for minimum SDKs and run shared presentation regressions.
xcrun swift build --package-path "$package" --target MatchStore \
    --triple arm64-apple-ios17.0-simulator --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    --scratch-path "$build_root/MatchStore-iOS" \
    2>&1 | tee "$log_dir/store-ios-build.log"
xcrun swift build --package-path "$package" --target MatchStore \
    --triple arm64-apple-watchos10.0-simulator --sdk "$(xcrun --sdk watchsimulator --show-sdk-path)" \
    --scratch-path "$build_root/MatchStore-Watch" \
    2>&1 | tee "$log_dir/store-watch-build.log"
xcrun swift build --package-path "$package" --target MatchSession \
    --triple arm64-apple-ios17.0-simulator --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    --scratch-path "$build_root/MatchSession-iOS" \
    2>&1 | tee "$log_dir/session-ios-build.log"
xcrun swift build --package-path "$package" --target MatchSession \
    --triple arm64-apple-watchos10.0-simulator --sdk "$(xcrun --sdk watchsimulator --show-sdk-path)" \
    --scratch-path "$build_root/MatchSession-Watch" \
    2>&1 | tee "$log_dir/session-watch-build.log"
presentation="$repo_root/native/Modules/MatchPresentation"
swift test --package-path "$presentation" --scratch-path "$build_root/PresentationHost" \
    2>&1 | tee "$log_dir/presentation-test.log"
xcrun swift build --package-path "$presentation" --target MatchPresentation \
    --triple arm64-apple-ios17.0-simulator --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    --scratch-path "$build_root/Presentation-iOS" \
    2>&1 | tee "$log_dir/presentation-ios-build.log"
xcrun swift build --package-path "$presentation" --target MatchPresentation \
    --triple arm64-apple-watchos10.0-simulator --sdk "$(xcrun --sdk watchsimulator --show-sdk-path)" \
    --scratch-path "$build_root/Presentation-Watch" \
    2>&1 | tee "$log_dir/presentation-watch-build.log"
xcodebuild -project "$project" -scheme FootballRecord-iOS \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$build_root/DerivedData-iOS" CODE_SIGNING_ALLOWED=NO build \
    2>&1 | tee "$log_dir/ios-build.log"
xcodebuild -project "$project" -scheme FootballRecord-Watch \
    -destination 'generic/platform=watchOS Simulator' \
    -derivedDataPath "$build_root/DerivedData-Watch" CODE_SIGNING_ALLOWED=NO build \
    2>&1 | tee "$log_dir/watch-build.log"
printf 'Native verification passed. Logs: %s\n' "$log_dir"
