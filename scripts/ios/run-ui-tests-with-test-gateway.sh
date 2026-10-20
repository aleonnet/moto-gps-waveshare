#!/bin/bash
# Run the iOS unit and UI tests against the offline test gateway: recorded AMap
# and Geoapify answers on localhost:8787, no network and no keys.
# Usage: run-ui-tests-with-test-gateway.sh "platform=iOS Simulator,name=iPhone 16,OS=18.6"
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
destination="${1:?usage: $0 \"platform=iOS Simulator,name=<device>,OS=<version>\"}"
port=8787
if lsof -ti "tcp:$port" > /dev/null 2>&1; then
  echo "Port $port is in use; stop that process so the app reaches the offline test gateway." >&2
  exit 1
fi
log="$(mktemp)"
env -u GEOAPIFY_API_KEY -u PROTOMAPS_API_KEY -u AMAP_WEB_SERVICE_KEY \
  MOTO_PROVIDER=fixture MOTO_MAP_PMTILES_URL=disabled PORT="$port" \
  node "$repo_root/backend/src/server.js" > "$log" 2>&1 &
gateway=$!
trap 'kill "$gateway" 2>/dev/null || true; wait "$gateway" 2>/dev/null || true; rm -f "$log"' EXIT
for _ in $(seq 1 50); do
  curl -sf "http://127.0.0.1:$port/healthz" > /dev/null && break
  sleep 0.2
done
if ! curl -sf "http://127.0.0.1:$port/healthz" > /dev/null; then
  cat "$log" >&2
  exit 1
fi
# Route tests plan from the simulated position: grant location up front, so a
# permission left denied on this simulator cannot fail them.
udid="$(xcrun simctl list devices available -j | python3 -I -c '
import json, sys
fields = dict(part.split("=", 1) for part in sys.argv[1].split(","))
runtime = "iOS-" + fields["OS"].replace(".", "-")
for key, devices in json.load(sys.stdin)["devices"].items():
    if key.endswith(runtime):
        for device in devices:
            if device["name"] == fields["name"]:
                print(device["udid"])
' "$destination" | head -1)"
if [ -z "$udid" ]; then
  echo "No available simulator matches $destination" >&2
  exit 1
fi
xcrun simctl bootstatus "$udid" -b > /dev/null
xcrun simctl privacy "$udid" grant location org.example.motogps
xcodegen generate --spec "$repo_root/platforms/ios/project.yml"
xcodebuild test -project "$repo_root/platforms/ios/MotoGPS.xcodeproj" -scheme MotoGPS \
  -destination "$destination"
