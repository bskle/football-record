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
# The preview Apps consume MatchCore only; explicitly compile the SQLite target for both SDKs.
xcrun swift build --package-path "$package" --target MatchStore \
    --triple arm64-apple-ios17.0-simulator --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    --scratch-path "$build_root/MatchStore-iOS" \
    2>&1 | tee "$log_dir/store-ios-build.log"
xcrun swift build --package-path "$package" --target MatchStore \
    --triple arm64-apple-watchos10.0-simulator --sdk "$(xcrun --sdk watchsimulator --show-sdk-path)" \
    --scratch-path "$build_root/MatchStore-Watch" \
    2>&1 | tee "$log_dir/store-watch-build.log"
xcodebuild -project "$project" -scheme FootballRecord-iOS \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$build_root/DerivedData-iOS" CODE_SIGNING_ALLOWED=NO build \
    2>&1 | tee "$log_dir/ios-build.log"
xcodebuild -project "$project" -scheme FootballRecord-Watch \
    -destination 'generic/platform=watchOS Simulator' \
    -derivedDataPath "$build_root/DerivedData-Watch" CODE_SIGNING_ALLOWED=NO build \
    2>&1 | tee "$log_dir/watch-build.log"
printf 'Native verification passed. Logs: %s\n' "$log_dir"
