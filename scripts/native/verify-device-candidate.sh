#!/bin/bash
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
build_root="${NATIVE_DEVICE_BUILD_ROOT:-/tmp/football-record-device-candidate}"
log_dir="$build_root/logs/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$log_dir"
for platform in iOS Watch; do
  if [[ "$platform" == iOS ]]; then destination=iOS; else destination=watchOS; fi
  xcodebuild -project "$repo_root/native/FootballRecord.xcodeproj" -scheme "FootballRecord-$platform" \
    -destination "generic/platform=$destination" -derivedDataPath "$build_root/DerivedData-$platform" \
    CODE_SIGNING_ALLOWED=NO build 2>&1 | tee "$log_dir/$platform-device-build.log"
done
python3 - "$repo_root" "$build_root" "$log_dir" <<'PY'
import sys, pathlib, plistlib, json, hashlib
root, build, logs = map(pathlib.Path, sys.argv[1:])
report={'signed':False,'profileOrInstallVerified':False,'targets':{}}
for platform, sdk, product, minimum in [('iOS','iphoneos','FootballRecord','17.0'),('Watch','watchos','FootballRecordWatch','10.0')]:
    app=build/f'DerivedData-{platform}/Build/Products/Debug-{sdk}/{product}.app'
    info=plistlib.loads((app/'Info.plist').read_bytes())
    ent_path=root/f'native/Configuration/{platform}/FootballRecord.entitlements'
    ent=plistlib.loads(ent_path.read_bytes())
    assert ent=={'com.apple.developer.healthkit':True},ent
    assert info['MinimumOSVersion']==minimum,info.get('MinimumOSVersion')
    for key in ['NSHealthShareUsageDescription','NSHealthUpdateUsageDescription','NSLocationWhenInUseUsageDescription']:
        assert info.get(key),key
    assert 'NSLocationAlwaysUsageDescription' not in info and 'NSLocationAlwaysAndWhenInUseUsageDescription' not in info
    bg='UIBackgroundModes' if platform=='iOS' else 'WKBackgroundModes'
    assert info[bg]==(['location'] if platform=='iOS' else ['workout-processing'])
    assert not (app/'embedded.mobileprovision').exists(),'Unexpected profile in unsigned candidate'
    report['targets'][platform]={'app':str(app),'bundleID':info['CFBundleIdentifier'],'minimumOS':info['MinimumOSVersion'],'background':info[bg],'configuredEntitlements':ent,'entitlementsFileSHA256':hashlib.sha256(ent_path.read_bytes()).hexdigest(),'signedEntitlementsVerified':False}
phone=report['targets']['iOS']['bundleID']; watch=report['targets']['Watch']['bundleID']
wi=plistlib.loads((build/'DerivedData-Watch/Build/Products/Debug-watchos/FootballRecordWatch.app/Info.plist').read_bytes())
assert wi['WKCompanionAppBundleIdentifier']==phone and watch.startswith(phone+'.')
(logs/'candidate-inspection.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(json.dumps(report,ensure_ascii=False,indent=2))
PY
printf 'Unsigned device candidate built and inspected. Signing, profiles and physical acceptance remain pending. Logs: %s\n' "$log_dir"
