#!/bin/bash
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
platform="${1:?Usage: ui-test.sh Watch|iOS simulator-UDID}"
device="${2:?Pass an existing simulator UDID}"
case "$platform" in
  Watch) destination="watchOS Simulator" ;;
  iOS) destination="iOS Simulator" ;;
  *) printf 'Expected Watch or iOS\n' >&2; exit 2 ;;
esac
build_root="${NATIVE_UI_BUILD_ROOT:-/tmp/football-record-native-ui}"
run_root="$build_root/$(date -u +%Y%m%dT%H%M%SZ)-$platform"
mkdir -p "$run_root"
printf 'Native UI evidence: %s\n' "$run_root"
test_filter=()
if [[ -n "${NATIVE_UI_TEST_CLASS:-}" ]]; then
  [[ "$NATIVE_UI_TEST_CLASS" =~ ^[A-Za-z0-9_]+$ ]] || { printf 'Invalid UI test class\n' >&2; exit 2; }
  test_filter=("-only-testing:FootballRecord-$platform-UITests/$NATIVE_UI_TEST_CLASS")
fi
xcodebuild test "${test_filter[@]}" -project "$repo_root/native/FootballRecord.xcodeproj" \
  -scheme "FootballRecord-$platform" -destination "platform=$destination,id=$device" \
  -derivedDataPath "$build_root/DerivedData-$platform" \
  -resultBundlePath "$run_root/acceptance.xcresult" CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES \
  2>&1 | tee "$run_root/xcodebuild-test.log"
xcrun xcresulttool export attachments --path "$run_root/acceptance.xcresult" --output-path "$run_root/attachments" \
  2>&1 | tee "$run_root/attachments.log"
printf 'Native UI passed: %s\n' "$run_root"
