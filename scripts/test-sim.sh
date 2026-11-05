#!/bin/bash
# End-to-end check in the iOS Simulator, with no taps:
#   1. builds iContain and the Probe test app (tests/Probe) for the Simulator,
#   2. installs iContain on a dedicated "iContain Test" simulator,
#   3. imports Probe (--import-inbox) and opens it (--open Probe),
#   4. starts iContain again, which runs Probe, and checks the loader's log.
# Optional: DEVICE=iphone-se APPEARANCE=dark LAT=48.8584 LON=2.2945 to try Test
# mode and the simulated location. Leaves the simulator running for a screenshot.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$root/build/test-sim"
bundle=com.mirazbakis.icontain
runtime="${RUNTIME:-$(xcrun simctl list runtimes -j | python3 -c 'import json,sys; r=[x for x in json.load(sys.stdin)["runtimes"] if x["platform"]=="iOS" and x["isAvailable"]]; print(r[-1]["identifier"])')}"
mkdir -p "$work"

echo "→ Building"
[[ -d "$root/iContainFFI.xcframework" ]] || "$root/scripts/build-rust.sh"
(cd "$root" && xcodegen generate --quiet)
xcodebuild -project "$root/iContain.xcodeproj" -scheme iContain -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$work/dd" \
  CODE_SIGNING_ALLOWED=NO -quiet build
(cd "$root/tests/Probe" && xcodegen generate --quiet)
xcodebuild -project "$root/tests/Probe/Probe.xcodeproj" -scheme Probe -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$work/probe" \
  ONLY_ACTIVE_ARCH=NO -quiet build
(cd "$work/probe/Build/Products/Debug-iphonesimulator" && rm -f "$work/Probe.zip" && zip -qry "$work/Probe.zip" Probe.app)

echo "→ Simulator"
udid=$(xcrun simctl list devices -j | python3 -c 'import json,sys; d=[x["udid"] for v in json.load(sys.stdin)["devices"].values() for x in v if x["name"]=="iContain Test" and x["isAvailable"]]; print(d[0] if d else "")')
[[ -n "$udid" ]] || udid=$(xcrun simctl create "iContain Test" "iPhone 17" "$runtime")
xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" >/dev/null
xcrun simctl uninstall "$udid" "$bundle" 2>/dev/null || true
xcrun simctl install "$udid" "$work/dd/Build/Products/Debug-iphonesimulator/iContain.app"
data=$(xcrun simctl get_app_container "$udid" "$bundle" data)
mkdir -p "$data/Documents" && cp "$work/Probe.zip" "$data/Documents/"

echo "→ Importing Probe"
xcrun simctl launch "$udid" "$bundle" --import-inbox >/dev/null
sleep 8
xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
python3 - "$data" <<PY
import json, os, sys
path = os.path.join(sys.argv[1], "Library/Application Support/iContain/guests.json")
guests = json.load(open(path))
assert guests and guests[0]["name"] == "Probe", "Probe wasn't imported"
g = guests[0]
if "${DEVICE:-}": g["testDevice"] = "${DEVICE:-}"
if "${APPEARANCE:-}": g["testAppearance"] = "${APPEARANCE:-}"
if "${LAT:-}": g["location"] = {"latitude": float("${LAT:-0}"), "longitude": float("${LON:-0}"), "altitude": 0, "label": "test"}
json.dump(guests, open(path, "w"))
print("  imported", g["name"], g.get("testDevice") or "", g.get("testAppearance") or "")
PY

echo "→ Opening Probe"
rm -f "$data/Library/iContain/launch.log"
xcrun simctl launch "$udid" "$bundle" --open Probe >/dev/null
sleep 5
xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
xcrun simctl launch "$udid" "$bundle" >/dev/null
sleep 6
if [[ -f "$data/Library/iContain/launch.log" ]]; then
  echo "✗ The loader failed: $(cat "$data/Library/iContain/launch.log")"
  exit 1
fi
xcrun simctl io "$udid" screenshot "$work/probe.png" >/dev/null 2>&1 || true
echo "✓ Probe is running inside iContain. Screenshot: $work/probe.png"
