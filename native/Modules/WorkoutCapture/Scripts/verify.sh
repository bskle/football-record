#!/bin/bash
set -euo pipefail
package="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
build_root="${WORKOUT_BUILD_ROOT:-/tmp/football-record-NATIVE008}"
log_dir="$build_root/logs/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$log_dir"
printf 'WorkoutCapture logs: %s\n' "$log_dir"
swift test --package-path "$package" --scratch-path "$build_root/SwiftPM" 2>&1 | tee "$log_dir/host-tests.log"
xcrun swift build --package-path "$package" --target WorkoutCapture --triple arm64-apple-ios17.0-simulator --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" --scratch-path "$build_root/iOS" 2>&1 | tee "$log_dir/ios17-build.log"
xcrun swift build --package-path "$package" --target WorkoutCapture --triple arm64-apple-watchos10.0-simulator --sdk "$(xcrun --sdk watchsimulator --show-sdk-path)" --scratch-path "$build_root/Watch" 2>&1 | tee "$log_dir/watch10-build.log"
printf 'WorkoutCapture automatic checks passed; real-device gate remains pending.\n'
