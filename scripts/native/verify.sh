#!/bin/bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
build_root="${NATIVE_BUILD_ROOT:-"$repo_root/native/.build"}"
log_dir="$build_root/logs/$(date -u +%Y%m%dT%H%M%SZ)"
project="$repo_root/native/FootballRecord.xcodeproj"
package="$repo_root/native/Packages/MatchCore"
mkdir -p "$log_dir"

printf 'Native verification logs: %s\n' "$log_dir"
swift build --package-path "$package" --scratch-path "$build_root/SwiftPM" \
    2>&1 | tee "$log_dir/swift-build.log"
xcodebuild -project "$project" -scheme FootballRecord-iOS \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$build_root/DerivedData-iOS" CODE_SIGNING_ALLOWED=NO build \
    2>&1 | tee "$log_dir/ios-build.log"
xcodebuild -project "$project" -scheme FootballRecord-Watch \
    -destination 'generic/platform=watchOS Simulator' \
    -derivedDataPath "$build_root/DerivedData-Watch" CODE_SIGNING_ALLOWED=NO build \
    2>&1 | tee "$log_dir/watch-build.log"
printf 'Native verification passed. Logs: %s\n' "$log_dir"
