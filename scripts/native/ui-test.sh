#!/bin/bash
set -euo pipefail
umask 077
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
derived="${NATIVE_UI_DERIVED_DATA:-$build_root/DerivedData-$platform}"
test_args=(test)
broker_pid=""
cleanup() {
  if [[ -n "$broker_pid" ]]; then
    touch "$run_root/stop"
    for _ in {1..50}; do kill -0 "$broker_pid" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$broker_pid" 2>/dev/null; then kill "$broker_pid"; fi
    wait "$broker_pid" || true
  fi
}
trap cleanup EXIT
if [[ "${NATIVE_M4_UI:-0}" == 1 ]]; then
  # Mac owns the fixture process. Only private per-installation files cross into Apps.
  xcodebuild build-for-testing -project "$repo_root/native/FootballRecord.xcodeproj" \
    -scheme FootballRecord-iOS -destination "platform=iOS Simulator,id=${NATIVE_M4_PHONE_DEVICE:-$device}" \
    -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
    > "$run_root/build-for-testing-phone.log" 2>&1
  if [[ "$platform" == Watch ]]; then
    xcodebuild build-for-testing -project "$repo_root/native/FootballRecord.xcodeproj" \
      -scheme FootballRecord-Watch -destination "platform=$destination,id=$device" \
      -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
      > "$run_root/build-for-testing-watch.log" 2>&1
  fi
  python3 - "$repo_root" "$run_root" "$platform" "$device" "${NATIVE_M4_PHONE_DEVICE:-$device}" "$derived" > "$run_root/broker.log" 2>&1 <<'PY' &
# coding: utf-8
import base64,hashlib,json,os,pathlib,signal,subprocess,sys,time,uuid
repo,run,platform,device,phone_device,derived=sys.argv[1:]
run=pathlib.Path(run);os.umask(0o077)
def interrupted(*_):raise KeyboardInterrupt()
signal.signal(signal.SIGTERM,interrupted)
def write(path,data):
 path.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
 temporary=path.with_name(path.name+'.'+uuid.uuid4().hex+'.tmp')
 temporary.write_bytes(data);os.chmod(temporary,0o600);os.replace(temporary,path)
def encode(value):return json.dumps(value,separators=(',',':')).encode()
def sim(*args):return subprocess.check_output(['xcrun','simctl',*args],stderr=subprocess.DEVNULL).decode().strip()
node=None;roots=[];bindings=[]
try:
 node=subprocess.Popen(['node',repo+'/native/Modules/AccountKit/Tests/AccountKitTests/Support/authority-fixture.mjs',repo],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,bufsize=1)
 def command(value):
  node.stdin.write(json.dumps(value)+'\n');node.stdin.flush();line=node.stdout.readline()
  if not line:raise RuntimeError('fixtureClosed')
  value=json.loads(line)
  if 'error' in value:raise RuntimeError('fixtureCommandUnavailable')
  return value
 metadata=json.loads(node.stdout.readline()) # Private memory only; never print metadata.
 command({'op':'clock','now':int(time.time())});command({'op':'revoker'})
 dataset='ui-'+uuid.uuid4().hex[:20]
 subject='m4-'+uuid.uuid4().hex
 def install(which,udid,bundle,role):
  sim('install',udid,str(pathlib.Path(derived)/'Build/Products'/which))
  container=pathlib.Path(sim('get_app_container',udid,bundle,'data'))
  root=container/'Library/Application Support/football-record';root.mkdir(parents=True,exist_ok=True,mode=0o700)
  config={'dataset':dataset,'namespace':'m4-ui-'+dataset+'-'+role,'baseURL':metadata['baseURL'],'keyID':metadata['keyID'],'publicKey':metadata['publicKey'],'cloudSpaceID':'fixture-cloud','subject':subject,'role':role}
  write(root/'development/m4-fixture.json',encode(config));roots.append(root);bindings.append((udid,bundle,config));return root
 phone=install('Debug-iphonesimulator/FootballRecord.app',phone_device,'com.example.footballrecord','phone')
 if platform=='Watch':watch=install('Debug-watchsimulator/FootballRecordWatch.app',device,'com.example.footballrecord.watchapp','watch')
 write(run/'bridge-locations.json',encode([str(root) for root in roots]))
 cloud=run/'private-cloud';cloud.mkdir(mode=0o700)
 def stable(scope):return tuple(scope[k] for k in ['accountID','cloudSpaceID','zoneID'])
 def handle(op,payload):
  command({'op':'clock','now':int(time.time())})
  if op=='apple':return encode(command({'op':'apple','subject':subject,'nonce':json.loads(payload)['nonce']}))
  if op=='cloud-save':
   upload=json.loads(payload);filename=hashlib.sha256(upload['record']['recordID'].encode()).hexdigest()+'.json'
   write(cloud/filename,payload);return (cloud/filename).read_bytes()
  if op=='cloud-fetch':
   scope=json.loads(payload);records=[]
   for file in cloud.glob('*.json'):
    upload=json.loads(file.read_bytes())
    if stable(upload['scope'])==stable(scope):records.append(upload['record'])
   return encode(records)
  if op=='cloud-delete':
   scope=json.loads(payload)
   for file in cloud.glob('*.json'):
    if stable(json.loads(file.read_bytes())['scope'])==stable(scope):file.unlink()
   return b''
  if op in ['phone-context','phone-register','phone-migration']:
   ident=str(uuid.uuid4());request=phone/'development/mailbox/incoming'/f'{ident}.json';response=phone/'development/mailbox/incoming-responses'/f'{ident}.json'
   try:
    write(request,encode({'id':ident,'operation':op,'dataset':dataset,'payload':base64.b64encode(payload).decode()}))
    deadline=time.monotonic()+8
    while time.monotonic()<deadline and not (run/'stop').exists():
     if response.exists():
      reply=json.loads(response.read_bytes())
      if reply.get('issue') or 'payload' not in reply:raise RuntimeError('phoneUnavailable')
      return base64.b64decode(reply['payload'],validate=True)
     time.sleep(.02)
    raise RuntimeError('phoneTimeout')
   finally:request.unlink(missing_ok=True);response.unlink(missing_ok=True)
  raise RuntimeError('unsupportedOperation')
 if platform=='Watch':
  subprocess.run(['xcrun','simctl','terminate',phone_device,'com.example.footballrecord'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
  sim('launch',phone_device,'com.example.footballrecord','--m4-development','--m4-auto-signin')
 if platform!='Watch':(run/'ready').touch(mode=0o600)
 startup_deadline=time.monotonic()+20
 next_resolution=0.0
 next_clock=0.0
 while not (run/'stop').exists():
  if time.monotonic()>=next_clock:
   wall=int(time.time());command({'op':'clock','now':wall})
   write(run/'bridge-wallclock.json',encode({'wallSeconds':wall}))
   next_clock=time.monotonic()+1
  if time.monotonic()>=next_resolution:
   # Xcode test installation can relocate the data container while preserving its
   # contents. Follow only the actual installation with our exact private pin.
   for index,(udid,bundle,expected) in enumerate(bindings):
    current=pathlib.Path(sim('get_app_container',udid,bundle,'data'))/'Library/Application Support/football-record'
    if current!=roots[index]:
     control=current/'development/m4-fixture.json'
     if control.stat().st_mode & 0o777 != 0o600 or json.loads(control.read_bytes())!=expected:raise RuntimeError('changedPrivateFixture')
     roots[index]=current
   phone=roots[0]
   write(run/'bridge-current-locations.json',encode([str(root) for root in roots]))
   next_resolution=time.monotonic()+.5
  if node.poll() is not None:raise RuntimeError('fixtureDied') # Never replace pin/process against existing data.
  if platform=='Watch' and not (run/'ready').exists():
   if (phone/'development/phone-ready.json').exists():(run/'ready').touch(mode=0o600)
   elif time.monotonic()>startup_deadline:raise RuntimeError('phoneAdmissionTimeout')
  for root in roots:
   for file in (root/'development/mailbox/outgoing').glob('*.json'):
    try:raw=file.read_bytes()
    except FileNotFoundError:continue # Already consumed by App after a prior response.
    if len(raw)>24*1024*1024:raise RuntimeError('oversizedMailbox')
    request=json.loads(raw);ident=request['id'];uuid.UUID(ident)
    write(run/'bridge-last-operation.json',encode({'operation':request.get('operation')}))
    if request['dataset']!=dataset:raise RuntimeError('wrongDataset')
    response=root/'development/mailbox/responses'/f'{ident}.json'
    if response.exists():continue
    try:reply={'payload':base64.b64encode(handle(request['operation'],base64.b64decode(request['payload'],validate=True))).decode()}
    except Exception:reply={'issue':'unavailable'}
    write(response,encode(reply))
  time.sleep(.02)
except BaseException as error:
 # Finite diagnostic only; errors may contain tokens/URLs, so never stringify them.
 write(run/'broker-failed',type(error).__name__.encode());sys.exit(1)
finally:
 for root in roots:(root/'development/m4-fixture.json').unlink(missing_ok=True)
 if node and node.poll() is None:
  try:
   node.stdin.write('{"op":"close"}\n');node.stdin.flush();node.wait(timeout=2)
  except Exception:node.terminate();node.wait(timeout=2)
PY
  broker_pid=$!
  for _ in {1..300}; do
    [[ ! -f "$run_root/broker-failed" ]] || { printf 'Private fixture startup failed\n' >&2; exit 1; }
    [[ ! -f "$run_root/ready" ]] || break
    kill -0 "$broker_pid" 2>/dev/null || { printf 'Private fixture exited\n' >&2; exit 1; }
    sleep 0.1
  done
  [[ -f "$run_root/ready" ]] || { printf 'Private fixture readiness timeout\n' >&2; exit 1; }
  test_args=(test-without-building)
fi
if [[ -n "${NATIVE_UI_TEST_FILTER:-}" ]]; then
  test_args+=("-only-testing:$NATIVE_UI_TEST_FILTER")
elif [[ -n "${NATIVE_UI_TEST_CLASS:-}" ]]; then
  [[ "$NATIVE_UI_TEST_CLASS" =~ ^[A-Za-z0-9_]+$ ]] || { printf 'Invalid UI test class\n' >&2; exit 2; }
  test_args+=("-only-testing:FootballRecord-$platform-UITests/$NATIVE_UI_TEST_CLASS")
fi
set +e
xcodebuild "${test_args[@]}" -collect-test-diagnostics never -test-timeouts-enabled YES -maximum-test-execution-time-allowance 180 -project "$repo_root/native/FootballRecord.xcodeproj" \
  -scheme "FootballRecord-$platform" -destination "platform=$destination,id=$device" \
  -derivedDataPath "$derived" \
  -resultBundlePath "$run_root/acceptance.xcresult" CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  2>&1 | tee "$run_root/xcodebuild-test.log"
test_status=${PIPESTATUS[0]}
set -e
export_status=0
xcrun xcresulttool export attachments --path "$run_root/acceptance.xcresult" --output-path "$run_root/attachments" \
  2>&1 | tee "$run_root/attachments.log" || export_status=$?
printf 'Test command exit: %s; attachment export exit: %s\n' "$test_status" "$export_status"
[[ "$test_status" == 0 ]] || exit "$test_status"
[[ "$export_status" == 0 ]] || exit "$export_status"
[[ ! -f "$run_root/broker-failed" ]] || { printf 'Private fixture failed\n' >&2; exit 1; }
printf 'Native UI passed: %s\n' "$run_root"
