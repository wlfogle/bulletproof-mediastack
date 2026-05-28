#!/usr/bin/env bash
# update-habridge-token.sh
# Usage: ./scripts/update-habridge-token.sh <HA_LONG_LIVED_TOKEN>
# Updates the Authorization header on all habridge devices to use your real HA token.
#
# Get token: http://192.168.12.123:8123/profile → Long-Lived Access Tokens → Create Token

set -Eeuo pipefail

HABRIDGE="http://192.168.12.251"
HA="http://192.168.12.123:8123"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <HA_LONG_LIVED_TOKEN>" >&2
  exit 1
fi
TOKEN="$1"

# Validate token against HA API
echo "Validating token against HA at ${HA}..."
HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer ${TOKEN}" \
  "${HA}/api/")
if [[ "$HTTP" != "200" ]]; then
  echo "ERROR: HA returned HTTP ${HTTP} — token appears invalid. Aborting." >&2
  exit 1
fi
echo "Token valid (HTTP 200 from HA)."

# Fetch all devices
DEVICES=$(curl -s "${HABRIDGE}/api/devices")
COUNT=$(python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d))" <<< "$DEVICES")
echo "Found ${COUNT} devices in habridge."

# Update each device — replace old token string in httpHeaders
python3 << PYEOF
import json, urllib.request, urllib.error, sys

habridge = "${HABRIDGE}"
new_token = "${TOKEN}"

devices = json.loads("""${DEVICES}""")

updated = 0
for dev in devices:
    dev_id = dev["id"]
    on_url = dev.get("onUrl", "")
    if not on_url:
        continue
    # Parse onUrl JSON array, update httpHeaders token
    try:
        items = json.loads(on_url)
    except Exception:
        print(f"SKIP id={dev_id} {dev['name']}: onUrl not JSON array")
        continue

    changed = False
    for item in items:
        hdr = item.get("httpHeaders", "")
        if "Bearer" in hdr:
            # Replace whatever token is there
            import re
            new_hdr = re.sub(r"Bearer\s+\S+", f"Bearer {new_token}", hdr)
            if new_hdr != hdr:
                item["httpHeaders"] = new_hdr
                changed = True

    if not changed:
        print(f"SKIP id={dev_id} {dev['name']}: no Bearer token found in httpHeaders")
        continue

    dev["onUrl"] = json.dumps(items)
    payload = json.dumps(dev).encode()
    req = urllib.request.Request(
        f"{habridge}/api/devices/{dev_id}",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="PUT"
    )
    try:
        with urllib.request.urlopen(req) as r:
            print(f"OK  id={dev_id:>4}  {dev['name']}")
            updated += 1
    except urllib.error.HTTPError as e:
        print(f"ERR id={dev_id} {dev['name']}: {e.read().decode()[:80]}")

print(f"\nDone. {updated}/{len(devices)} devices updated.")
PYEOF

echo ""
echo "Next: say 'Alexa, discover my devices' on your Fire TV."
