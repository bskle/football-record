#!/bin/bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
build_root="${NATIVE_BUILD_ROOT:-"$repo_root/native/.build"}"
log_dir="$build_root/logs/$(date -u +%Y%m%dT%H%M%SZ)"
project="$repo_root/native/FootballRecord.xcodeproj"
package="$repo_root/native/Packages/MatchCore"
mkdir -p "$log_dir"

printf 'Native verification logs: %s\n' "$log_dir"
node_binary="${NATIVE_NODE_BINARY:-node}"
if [[ "$node_binary" == */* ]]; then export PATH="$(dirname -- "$node_binary"):$PATH"; fi
"$node_binary" --test "$repo_root"/backend/test/*.test.mjs \
    2>&1 | tee "$log_dir/authority-node-test.log"
swift test --package-path "$package" --scratch-path "$build_root/SwiftPM" \
    2>&1 | tee "$log_dir/swift-test.log"
cloud="$repo_root/native/Modules/CloudSync"
account="$repo_root/native/Modules/AccountKit"
swift test --package-path "$cloud" --scratch-path "$build_root/CloudHost" \
    2>&1 | tee "$log_dir/cloud-test.log"
swift test --package-path "$account" --scratch-path "$build_root/AccountHost" \
    2>&1 | tee "$log_dir/account-test.log"
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
xcrun swift build --package-path "$package" --target MatchSync \
    --triple arm64-apple-ios17.0-simulator --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    --scratch-path "$build_root/MatchSync-iOS" \
    2>&1 | tee "$log_dir/sync-ios-build.log"
xcrun swift build --package-path "$package" --target MatchSync \
    --triple arm64-apple-watchos10.0-simulator --sdk "$(xcrun --sdk watchsimulator --show-sdk-path)" \
    --scratch-path "$build_root/MatchSync-Watch" \
    2>&1 | tee "$log_dir/sync-watch-build.log"
xcrun swift build --package-path "$cloud" --target CloudSync \
    --triple arm64-apple-ios17.0-simulator --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    --scratch-path "$build_root/Cloud-iOS" \
    2>&1 | tee "$log_dir/cloud-ios-build.log"
xcrun swift build --package-path "$cloud" --target CloudSync \
    --triple arm64-apple-watchos10.0-simulator --sdk "$(xcrun --sdk watchsimulator --show-sdk-path)" \
    --scratch-path "$build_root/Cloud-Watch" \
    2>&1 | tee "$log_dir/cloud-watch-build.log"
xcrun swift build --package-path "$account" --target AccountKit \
    --triple arm64-apple-ios17.0-simulator --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    --scratch-path "$build_root/Account-iOS" \
    2>&1 | tee "$log_dir/account-ios-build.log"
xcrun swift build --package-path "$account" --target AccountKit \
    --triple arm64-apple-watchos10.0-simulator --sdk "$(xcrun --sdk watchsimulator --show-sdk-path)" \
    --scratch-path "$build_root/Account-Watch" \
    2>&1 | tee "$log_dir/account-watch-build.log"
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
# The device candidate links these real modules; validate their host boundaries and deployment SDKs.
for module in WorkoutCapture DeviceSync AppIntegration; do
    if [[ "$module" == AppIntegration ]]; then module_path="$repo_root/native/Apps/iOS/Integration"; else module_path="$repo_root/native/Modules/$module"; fi
    swift test --package-path "$module_path" --scratch-path "$build_root/$module-Host" 2>&1 | tee "$log_dir/$module-tests.log"
    xcrun swift build --package-path "$module_path" --target "$module" --triple arm64-apple-ios17.0-simulator --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" --scratch-path "$build_root/$module-iOS" 2>&1 | tee "$log_dir/$module-ios-build.log"
    xcrun swift build --package-path "$module_path" --target "$module" --triple arm64-apple-watchos10.0-simulator --sdk "$(xcrun --sdk watchsimulator --show-sdk-path)" --scratch-path "$build_root/$module-Watch" 2>&1 | tee "$log_dir/$module-watch-build.log"
done
printf 'Native verification passed. Logs: %s\n' "$log_dir"
