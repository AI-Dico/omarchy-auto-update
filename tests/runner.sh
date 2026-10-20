#!/bin/bash
# Drives the update runner against a fake `omarchy update -y` and checks its events.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RUNNER="$HERE/../bin/omarchy-auto-update-runner"
pass=0 fail=0
ok() { echo "  ok   $1"; pass=$((pass + 1)); }
no() { echo "  FAIL $1"; fail=$((fail + 1)); }

# Runs the runner with a password feed; waits for the detached run to finish.
drive() {
  T=$(mktemp -d)
  export PATH="$HERE/fake-bin:$PATH" OMARCHY_AUTO_UPDATE_TEST=1 XDG_CACHE_HOME="$T/cache" XDG_RUNTIME_DIR="$T/run"
  mkdir -p "$T/run"
  FG=$( { sleep 0.3; for p in "$@"; do echo "$p"; sleep 0.3; done; } | "$RUNNER" )
  EV="$T/run/omarchy-auto-update/run.jsonl"
  for _ in $(seq 1 40); do grep -q '"type": "done"' "$EV" 2>/dev/null && break; sleep 0.25; done
  EVENTS=$(cat "$EV" 2>/dev/null); LOGTXT=$(cat "$T/cache/omarchy-auto-update/last-update.log" 2>/dev/null)
}

echo "1. trusted sudo prompt"
OMARCHY_AUTO_UPDATE_TEST_TRUST=1 drive test
grep -q '^{"type": "password", "retry": false}' <<<"$FG" && ok "asks for the password first" || no "asks for the password first"
grep -q '"type": "detached"' <<<"$FG" && ok "hands over to a detached run" || no "hands over to a detached run"
grep -q '"label": "Saving a restore point"' <<<"$EVENTS" && ok "reports the snapshot step" || no "reports the snapshot step"
grep -q '"done": 3, "total": 3, "label": "Installing pkg3"' <<<"$EVENTS" && ok "reports package progress" || no "reports package progress"
grep -q 'snapshot ok' <<<"$EVENTS" && ok "answers the sudo prompt" || no "answers the sudo prompt"
grep -q '"type": "done", "ok": true' <<<"$EVENTS" && ok "finishes ok" || no "finishes ok"
grep -q '"snapshot": true' <<<"$EVENTS" && ok "records the restore point" || no "records the restore point"
grep -qw test <<<"$EVENTS$LOGTXT" && no "password kept out of events and log" || ok "password kept out of events and log"
[[ $(stat -c %a "$T/cache/omarchy-auto-update/last-update.log") == 600 ]] && ok "log is private (0600)" || no "log is private (0600)"
[[ ! -f $T/run/omarchy-auto-update/run.pid ]] && ok "pid file removed when done" || no "pid file removed when done"

echo "2. untrusted prompt"
OMARCHY_AUTO_UPDATE_TEST_TRUST=0 drive test
grep -q 'snapshot ok' <<<"$EVENTS" && no "never types into an untrusted prompt" || ok "never types into an untrusted prompt"
grep -q '"type": "done", "ok": false' <<<"$EVENTS" && ok "reports the failure" || no "reports the failure"

echo "3. wrong password"
OMARCHY_AUTO_UPDATE_TEST_TRUST=1 drive wrong test
grep -q '"retry": true' <<<"$FG" && ok "asks again after a wrong password" || no "asks again after a wrong password"

echo "4. agreed set must match"
T=$(mktemp -d); mkdir -p "$T/cache/omarchy-auto-update" "$T/run"
FAKE_HELPER_DIR="$T/h"; mkdir -p "$FAKE_HELPER_DIR"
FG=$(OMARCHY_AUTO_UPDATE_TEST=1 XDG_CACHE_HOME="$T/cache" XDG_RUNTIME_DIR="$T/run" "$RUNNER" deadbeef </dev/null)
grep -q '"type": "changed"' <<<"$FG" && ok "stops when the set is not the agreed one" || no "stops when the set is not the agreed one"

echo "passed $pass, failed $fail"
((fail == 0))
