#!/bin/bash
# Drives the update runner against a fake `omarchy update -y` and checks its events.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export PATH="$HERE/fake-bin:$PATH" OMARCHY_AUTO_UPDATE_TEST=1 XDG_CACHE_HOME="$T"
out=$( { sleep 0.5; echo test; } | "$HERE/../bin/omarchy-auto-update-runner" )
pass=0 fail=0
check() { if grep -q "$2" <<<"$out"; then echo "  ok   $1"; pass=$((pass+1)); else echo "  FAIL $1"; fail=$((fail+1)); fi; }
check "asks for the password first" '^{"type": "password", "retry": false}'
check "reports the snapshot step" '"label": "Saving a restore point"'
check "reports the install step" '"label": "Installing updates"'
check "reports package progress" '"done": 3, "total": 3, "label": "Installing pkg3"'
check "reports the settings step" '"label": "Updating your settings"'
check "answers sudo inside the run" 'snapshot ok'
check "finishes ok" '"type": "done", "ok": true'
check "password never in the output" '^' ; grep -q '"test"' <<<"$out" && { echo "  FAIL password leaked"; fail=$((fail+1)); }
check "log written" '"log":'
bad=$( { sleep 0.5; echo wrong; sleep 0.5; echo test; } | "$HERE/../bin/omarchy-auto-update-runner" )
grep -q '"retry": true' <<<"$bad" && { echo "  ok   retries a wrong password"; pass=$((pass+1)); } || { echo "  FAIL retries a wrong password"; fail=$((fail+1)); }
echo "passed $pass, failed $fail"; ((fail == 0))
