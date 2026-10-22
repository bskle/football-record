#!/bin/bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
build_root="${NATIVE_BUILD_ROOT:-"$repo_root/native/.build"}"
run_stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
log_dir="$build_root/logs/$run_stamp"
run_root="$build_root/runs/$run_stamp"
project="$repo_root/native/FootballRecord.xcodeproj"
mkdir -p "$log_dir" "$run_root"

printf 'Native verification logs: %s\n' "$log_dir"
node_binary="${NATIVE_NODE_BINARY:-node}"
if [[ "$node_binary" == */* ]]; then export PATH="$(dirname -- "$node_binary"):$PATH"; fi

run_logged() {
    local name="$1"
    shift
    local -a pipeline_status
    printf '%q ' "$@" > "$log_dir/$name.command"
    printf '\n' >> "$log_dir/$name.command"
    # Defer errexit only until both real pipeline statuses have been captured.
    set +e
    "$@" 2>&1 | tee "$log_dir/$name.log"
    pipeline_status=("${PIPESTATUS[@]}")
    set -e
    printf 'tool=%s\ntee=%s\n' "${pipeline_status[0]}" "${pipeline_status[1]}" > "$log_dir/$name.status"
    if [[ "${pipeline_status[0]}" != 0 ]]; then return "${pipeline_status[0]}"; fi
    return "${pipeline_status[1]}"
}

# One complete backend run and eight complete Swift package runs.
run_logged host-node "$node_binary" --test "$repo_root"/backend/test/*.test.mjs
while IFS='|' read -r name relative; do
    run_logged "host-$name" swift test --package-path "$repo_root/$relative" \
        --scratch-path "$run_root/host-$name"
done <<'HOST_PACKAGES'
MatchCore|native/Packages/MatchCore
CloudSync|native/Modules/CloudSync
AccountKit|native/Modules/AccountKit
MatchPresentation|native/Modules/MatchPresentation
WorkoutCapture|native/Modules/WorkoutCapture
DeviceSync|native/Modules/DeviceSync
HealthKitDeletion|native/Modules/HealthKitDeletion
AppIntegration|native/Apps/iOS/Integration
HOST_PACKAGES

# Ten products, four minimum simulator/device triples; MatchCore is a dependency.
while IFS='|' read -r target relative; do
    while IFS='|' read -r sdk triple; do
        sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
        run_logged "sdk-$target-$sdk" xcrun swift build \
            --package-path "$repo_root/$relative" --target "$target" \
            --triple "$triple" --sdk "$sdk_path" \
            --scratch-path "$run_root/sdk-$target-$sdk"
    done <<'MINIMUM_SDKS'
iphonesimulator|arm64-apple-ios17.0-simulator
iphoneos|arm64-apple-ios17.0
watchsimulator|arm64-apple-watchos10.0-simulator
watchos|arm64-apple-watchos10.0
MINIMUM_SDKS
done <<'PRODUCTS'
MatchStore|native/Packages/MatchCore
MatchSession|native/Packages/MatchCore
MatchSync|native/Packages/MatchCore
CloudSync|native/Modules/CloudSync
AccountKit|native/Modules/AccountKit
MatchPresentation|native/Modules/MatchPresentation
WorkoutCapture|native/Modules/WorkoutCapture
DeviceSync|native/Modules/DeviceSync
HealthKitDeletion|native/Modules/HealthKitDeletion
AppIntegration|native/Apps/iOS/Integration
PRODUCTS

# Four Debug/Release simulator Apps and two Debug generic-device Apps, unsigned.
while IFS='|' read -r platform configuration destination sdk; do
    name="app-$platform-$configuration-$sdk"
    run_logged "$name" xcodebuild -project "$project" \
        -scheme "FootballRecord-$platform" -configuration "$configuration" \
        -destination "generic/platform=$destination" \
        -derivedDataPath "$run_root/$name" \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
        IPHONEOS_DEPLOYMENT_TARGET=17.0 WATCHOS_DEPLOYMENT_TARGET=10.0 build
done <<'APPS'
iOS|Debug|iOS Simulator|iphonesimulator
iOS|Release|iOS Simulator|iphonesimulator
Watch|Debug|watchOS Simulator|watchsimulator
Watch|Release|watchOS Simulator|watchsimulator
iOS|Debug|iOS|iphoneos
Watch|Debug|watchOS|watchos
APPS

printf 'Native host/SDK/App builds passed. UI/runtime/device acceptance remains separate. Logs: %s\n' "$log_dir"
