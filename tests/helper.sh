# Sourced by tests/runner.sh, which defines ok/no and the helpers used here.
[[ $(type -t ok) == function ]] || { echo "run tests/runner.sh instead" >&2; return 1 2>/dev/null || exit 1; }
# Sourced by runner.sh (uses its ok/no counters): the helper's settings, menu
# entry and notifications, each in a throwaway home.
# The helper's settings, menu entry and notifications, in a throwaway home.
HELPER="$HERE/../bin/omarchy-auto-update"
helper_env() {
  T=$(mktemp -d)
  export HOME="$T/home" XDG_CONFIG_HOME="$T/config" XDG_CACHE_HOME="$T/cache" XDG_RUNTIME_DIR="$T/run" \
    OMARCHY_AUTO_UPDATE_SPOOL="$T/spool" OMARCHY_AUTO_UPDATE_TRIGGER="$T/trigger" \
    FAKE_NOTIFY_LOG="$T/notify.log" FAKE_SHELL_LOG="$T/shell.log" PATH="$HERE/fake-bin:$ORIG_PATH"
  mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$XDG_CACHE_HOME/omarchy-auto-update"
  MENU="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
  CONF="$XDG_CONFIG_HOME/omarchy-auto-update/config.json"
}
ORIG_PATH=$PATH
set_state() { echo "$1" >"$XDG_CACHE_HOME/omarchy-auto-update/state.json"; }
# notify hands the notification to a detached process; wait for it to land.
lines() { if [[ -f $1 ]]; then wc -l <"$1"; else echo 0; fi; }
wait_lines() { for _ in $(seq 1 20); do (($(lines "$1") >= $2)) && return; sleep 0.1; done; }

echo "5. settings"
helper_env
[[ $("$HELPER" config get) == '{"iconMode":"shown"}' ]] && ok "icon mode defaults to shown" || no "icon mode defaults to shown"
"$HELPER" config set icon-mode important >/dev/null
[[ $(jq -r .iconMode "$CONF") == important ]] && ok "config set writes the file" || no "config set writes the file"
[[ $("$HELPER" config get) == '{"iconMode":"important"}' ]] && ok "config get reads it back" || no "config get reads it back"
"$HELPER" config set icon-mode sometimes 2>/dev/null && no "rejects an unknown mode" || ok "rejects an unknown mode"
"$HELPER" config set colour red 2>/dev/null && no "rejects an unknown setting" || ok "rejects an unknown setting"
[[ $(jq -r .iconMode "$CONF") == important ]] && ok "a rejected value leaves the file alone" || no "a rejected value leaves the file alone"
echo '{"later": 1, "iconMode": "shown"}' >"$CONF"
"$HELPER" config set icon-mode hidden >/dev/null
[[ $(jq -c . "$CONF") == '{"later":1,"iconMode":"hidden"}' ]] && ok "keeps settings it doesn't know" || no "keeps settings it doesn't know"
[[ -z $(find "$XDG_CONFIG_HOME/omarchy-auto-update" -name '.config.*') ]] && ok "no temp file left behind" || no "no temp file left behind"
echo 'not json' >"$CONF"
[[ $("$HELPER" config get) == '{"iconMode":"shown"}' ]] && ok "a damaged file reads as the default" || no "a damaged file reads as the default"
"$HELPER" config set icon-mode hidden >/dev/null
set_state '{"state":"ready","fingerprint":"aaa","count":2,"tier":"small","packages":[]}'
[[ $("$HELPER" status | jq -r .iconMode) == hidden ]] && ok "status carries the icon mode" || no "status carries the icon mode"
[[ $("$HELPER" status | jq -r .notifyKey) == ready:aaa ]] && ok "status carries the notify key" || no "status carries the notify key"

echo "6. menu entry"
helper_env
"$HELPER" menu-install
[[ -f $MENU ]] && jq -e . >/dev/null 2>&1 < <(grep -v '^[[:space:]]*//' "$MENU" | sed -z 's/,\n}/\n}/') &&
  ok "creates the extension file" || no "creates the extension file"
grep -q '"update.auto-update": {.*"action":"omarchy-shell shell summon io.github.ai-dico.auto-update {}"' "$MENU" &&
  ok "adds Update > Auto Update" || no "adds Update > Auto Update"
before=$(md5sum <"$MENU"); "$HELPER" menu-install; "$HELPER" menu-install --auto
[[ $(md5sum <"$MENU") == "$before" && $(grep -c '>>> omarchy-auto-update' "$MENU") == 1 ]] &&
  ok "installing again changes nothing" || no "installing again changes nothing"
cat >"$MENU" <<'JSONC'
// my own notes
{
  // >>> omarchy-hwp (managed by io.github.ai-dico.hwp, edit outside this block)
  "hwp": {"icon":"x","label":"HWP"},
  // <<< omarchy-hwp
  "personal": {"icon":"","label":"Personal"},
}
JSONC
cp "$MENU" "$T/menu.orig"
"$HELPER" menu-install
[[ $(sed -n 3p "$MENU") == '  // >>> omarchy-auto-update (managed by io.github.ai-dico.auto-update, edit outside this block)' ]] &&
  ok "block goes right after the opening brace" || no "block goes right after the opening brace"
grep -q '"personal"' "$MENU" && grep -q '"hwp"' "$MENU" && ok "keeps the user's and other plugins' entries" || no "keeps the user's and other plugins' entries"
"$HELPER" menu-remove
cmp -s "$MENU" "$T/menu.orig" && ok "menu-remove restores everything outside the block" || no "menu-remove restores everything outside the block"
"$HELPER" menu-remove && cmp -s "$MENU" "$T/menu.orig" && ok "menu-remove again is a no-op" || no "menu-remove again is a no-op"
"$HELPER" menu-install --auto
cmp -s "$MENU" "$T/menu.orig" && ok "--auto leaves a removed entry out" || no "--auto leaves a removed entry out"
"$HELPER" menu-install
grep -q '"update.auto-update"' "$MENU" && ok "an explicit install brings it back" || no "an explicit install brings it back"
printf '{\n  // >>> omarchy-auto-update (managed by io.github.ai-dico.auto-update, edit outside this block)\n}\n' >"$MENU"
cp "$MENU" "$T/menu.broken"
"$HELPER" menu-install 2>/dev/null && no "refuses a damaged block" || ok "refuses a damaged block"
cmp -s "$MENU" "$T/menu.broken" && ok "leaves a damaged file untouched" || no "leaves a damaged file untouched"
helper_env
"$HELPER" menu-install --auto
grep -q '"update.auto-update"' "$MENU" && ok "--auto adds it the first time" || no "--auto adds it the first time"

echo "7. notifications"
helper_env
set_state '{"state":"ready","fingerprint":"aaa","count":2,"tier":"small","packages":[]}'
"$HELPER" notify; sleep 0.5
(($(lines "$FAKE_NOTIFY_LOG") == 0)) && ok "no notification while the icon shows it" || no "no notification while the icon shows it"
[[ $(cat "$XDG_CACHE_HOME/omarchy-auto-update/notified") == ready:aaa ]] && ok "records what the icon showed" || no "records what the icon showed"
"$HELPER" config set icon-mode hidden >/dev/null
"$HELPER" notify; sleep 0.5
(($(lines "$FAKE_NOTIFY_LOG") == 0)) && ok "hiding the icon doesn't repeat a seen set" || no "hiding the icon doesn't repeat a seen set"
set_state '{"state":"ready","fingerprint":"bbb","count":1,"tier":"restart","packages":[]}'
"$HELPER" notify; wait_lines "$FAKE_NOTIFY_LOG" 1
grep -q -- '-p -a Auto Update .*-- 1 update ready · restart to finish' "$FAKE_NOTIFY_LOG" && ok "tells about a new set when hidden" || no "tells about a new set when hidden"
"$HELPER" notify; "$HELPER" notify; sleep 0.5
(($(lines "$FAKE_NOTIFY_LOG") == 1)) && ok "tells once per set" || no "tells once per set"
"$HELPER" config set icon-mode important >/dev/null
set_state '{"state":"attention","message":"Not enough free space","count":0,"packages":[]}'
"$HELPER" notify; sleep 0.5
(($(lines "$FAKE_NOTIFY_LOG") == 1)) && ok "important mode shows attention itself" || no "important mode shows attention itself"
set_state '{"state":"ready","fingerprint":"ccc","count":4,"tier":"small","packages":[]}'
FAKE_NOTIFY_ACTION=default "$HELPER" notify; wait_lines "$FAKE_NOTIFY_LOG" 2; wait_lines "$FAKE_SHELL_LOG" 1
(($(lines "$FAKE_NOTIFY_LOG") == 2)) && ok "important mode tells about a plain ready set" || no "important mode tells about a plain ready set"
[[ $(cat "$FAKE_SHELL_LOG" 2>/dev/null) == 'shell summon io.github.ai-dico.auto-update {}' ]] && ok "clicking it opens Auto Update" || no "clicking it opens Auto Update"
set_state '{"state":"ready","fingerprint":"ddd","count":4,"tier":"small","packages":[]}'
mkdir -p "$XDG_RUNTIME_DIR/omarchy-auto-update" &&
  echo '{"type": "phase", "label": "x"}' >"$XDG_RUNTIME_DIR/omarchy-auto-update/run.jsonl"
"$HELPER" notify; sleep 0.5
(($(lines "$FAKE_NOTIFY_LOG") == 2)) && ok "quiet while an update runs" || no "quiet while an update runs"

# Waits for the detached notify-wait to finish (it clears the pending note).
settled() { for _ in $(seq 1 30); do [[ -z $(ls -A "$XDG_CACHE_HOME/omarchy-auto-update/notify-pending.d" 2>/dev/null) ]] && return; sleep 0.1; done; }
told() { lines "$FAKE_NOTIFY_LOG"; }

echo "8. review fixes"
helper_env
for v in 'shown important' 'important hidden' ' shown' 'Shown'; do
  "$HELPER" config set icon-mode "$v" 2>/dev/null && no "rejects '$v'" || ok "rejects '$v'"
done
mkdir -p "${CONF%/*}"; echo '{"iconMode": "shown important"}' >"$CONF"
[[ $("$HELPER" config get) == '{"iconMode":"shown"}' ]] && ok "a compound value on disk reads as shown" || no "a compound value on disk reads as shown"

helper_env
P="$T/my plugin/bin"; mkdir -p "$P"; cp "$HELPER" "$P/"
"$P/omarchy-auto-update" menu-install
python3 -I -c '
import json, re, sys
raw = open(sys.argv[1]).read()
raw = re.sub(r"^\s*//[^\n]*(\n|$)", "", raw, flags=re.M)
raw = re.sub(r",(\s*[}\]])", r"\1", raw)
print(json.loads(raw)["update.auto-update"]["when"])' "$MENU" >"$T/when" 2>/dev/null
[[ $(cat "$T/when") == "test -x $T/my\\ plugin/bin/omarchy-auto-update" ]] &&
  ok "a helper path with a space keeps the menu file valid" || no "a helper path with a space keeps the menu file valid"
printf '{\n  "a": ,\n}\n' >"$MENU"; cp "$MENU" "$T/menu.bad"
"$HELPER" menu-install 2>/dev/null && no "won't write a menu that doesn't parse" || ok "won't write a menu that doesn't parse"
cmp -s "$MENU" "$T/menu.bad" && ok "keeps the original when it wouldn't parse" || no "keeps the original when it wouldn't parse"
printf '{\n  "mine": {"label":"Mine"},\n}\n' >"$MENU"
OMARCHY_AUTO_UPDATE_TEST=1 OMARCHY_AUTO_UPDATE_TEST_MENU_RACE='  // edited meanwhile' "$HELPER" menu-install 2>/dev/null &&
  no "gives up when the file changes meanwhile" || ok "gives up when the file changes meanwhile"
grep -q 'edited meanwhile' "$MENU" && ! grep -q 'update.auto-update' "$MENU" &&
  ok "the other writer's change survives" || no "the other writer's change survives"
"$HELPER" menu-install && grep -q 'edited meanwhile' "$MENU" && grep -q 'update.auto-update' "$MENU" &&
  ok "the next try adds the entry" || no "the next try adds the entry"
OMARCHY_AUTO_UPDATE_TEST=1 OMARCHY_AUTO_UPDATE_TEST_MENU_RACE='  // again' "$HELPER" menu-remove 2>/dev/null
grep -q 'update.auto-update' "$MENU" && grep -q '// again' "$MENU" && ok "menu-remove also gives up on a race" || no "menu-remove also gives up on a race"

helper_env
"$HELPER" config set icon-mode hidden >/dev/null
set_state '{"state":"ready","fingerprint":"aaa","count":1,"tier":"small","packages":[]}'
FAKE_NOTIFY_HOLD=5 "$HELPER" notify; wait_lines "$FAKE_NOTIFY_LOG" 1
set_state '{"state":"attention","message":"Not enough free space","count":0,"packages":[]}'
start=$(date +%s%N); "$HELPER" notify; took=$((($(date +%s%N) - start) / 1000000))
((took < 3000)) && ok "an open notification doesn't hold the lock (${took} ms)" || no "an open notification doesn't hold the lock (${took} ms)"
wait_lines "$FAKE_NOTIFY_LOG" 2; settled
(($(told) == 2)) && ok "the next notification goes out meanwhile" || no "the next notification goes out meanwhile"
set_state '{"state":"ready","fingerprint":"aaa","count":1,"tier":"small","packages":[]}'
"$HELPER" notify; sleep 0.5; settled
(($(told) == 2)) && ok "ready:A, attention, ready:A tells A once" || no "ready:A, attention, ready:A tells A once"
set_state '{"state":"attention","message":"Download or verification failed","count":0,"packages":[]}'
"$HELPER" notify; wait_lines "$FAKE_NOTIFY_LOG" 3; settled
(($(told) == 3)) && ok "a different warning is told again" || no "a different warning is told again"
set_state '{"state":"ready","fingerprint":"aaa","count":1,"tier":"small","packages":[],"news":{"at":100,"title":"Manual step","link":"https://archlinux.org/news/x/"}}'
"$HELPER" notify; wait_lines "$FAKE_NOTIFY_LOG" 4; settled
(($(told) == 4)) && grep -q 'Manual step' "$FAKE_NOTIFY_LOG" && ok "new Arch news is told when hidden" || no "new Arch news is told when hidden"
set_state '{"state":"ready","fingerprint":"eee","count":1,"tier":"small","packages":[]}'
FAKE_NOTIFY_FAIL=1 "$HELPER" notify; sleep 0.5; settled
! grep -qx 'ready:eee' "$XDG_CACHE_HOME/omarchy-auto-update/notified" && ok "a failed delivery isn't remembered" || no "a failed delivery isn't remembered"
"$HELPER" notify; wait_lines "$FAKE_NOTIFY_LOG" 5; settled
(($(told) == 5)) && ok "it goes out on the next try" || no "it goes out on the next try"
for i in $(seq 1 30); do echo "old:$i"; done >>"$XDG_CACHE_HOME/omarchy-auto-update/notified"
set_state '{"state":"ready","fingerprint":"fff","count":1,"tier":"small","packages":[]}'
"$HELPER" notify; wait_lines "$FAKE_NOTIFY_LOG" 6; settled
(($(wc -l <"$XDG_CACHE_HOME/omarchy-auto-update/notified") == 20)) && grep -qx 'ready:fff' "$XDG_CACHE_HOME/omarchy-auto-update/notified" &&
  ok "keeps the last 20 keys" || no "keeps the last 20 keys"

echo "9. review fixes, round 2"
helper_env
"$HELPER" config set icon-mode hidden >/dev/null
set_state '{"state":"ready","fingerprint":"zzz","count":1,"tier":"small","packages":[]}'
FAKE_NOTIFY_FAIL=1 "$HELPER" notify; sleep 0.5; settled
! grep -qx 'ready:zzz' "$XDG_CACHE_HOME/omarchy-auto-update/notified" 2>/dev/null && ok "id 0 from notify-send counts as not sent" || no "id 0 from notify-send counts as not sent"
"$HELPER" notify; wait_lines "$FAKE_NOTIFY_LOG" 1; settled
grep -qx 'ready:zzz' "$XDG_CACHE_HOME/omarchy-auto-update/notified" && ok "a real id records it" || no "a real id records it"
set_state '{"state":"attention","message":"Low space","count":0,"packages":[],"news":{"at":200,"title":"Keyring step","link":"https://archlinux.org/news/k/"}}'
"$HELPER" notify; wait_lines "$FAKE_NOTIFY_LOG" 2; settled
tail -1 "$FAKE_NOTIFY_LOG" | grep -q 'Low space Arch news to read first: Keyring step' &&
  ok "a warning that records news also says it" || no "a warning that records news also says it"
helper_env
"$HELPER" config set icon-mode hidden >/dev/null
# Each waiter confirms only after a while (STALL seconds): A first, B later.
mkdir -p "$T/stall"; cat >"$T/stall/notify-send" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$FAKE_NOTIFY_LOG"; sleep "${STALL:-1}"; echo 9
EOF
chmod +x "$T/stall/notify-send"
set_state '{"state":"ready","fingerprint":"p1","count":1,"tier":"small","packages":[]}'
STALL=1.5 PATH="$T/stall:$PATH" "$HELPER" notify; wait_lines "$FAKE_NOTIFY_LOG" 1
set_state '{"state":"attention","message":"slow one","count":0,"packages":[]}'
STALL=4 PATH="$T/stall:$PATH" "$HELPER" notify; wait_lines "$FAKE_NOTIFY_LOG" 2
sleep 2   # A has confirmed; B still waits
(($(ls "$XDG_CACHE_HOME/omarchy-auto-update/notify-pending.d" | wc -l) == 1)) && ok "a waiter clears only its own request" || no "a waiter clears only its own request"
"$HELPER" notify; sleep 0.3
(($(told) == 2)) && ok "B isn't sent twice while it is pending" || no "B isn't sent twice while it is pending"
settled
helper_env
mkdir -p "${MENU%/*}"
printf '{\n  "mine": {"label":"Mine"},\n}\n' >"$MENU"
OMARCHY_AUTO_UPDATE_TEST=1 OMARCHY_AUTO_UPDATE_TEST_MENU_RACE_LATE='  // written after the check' "$HELPER" menu-install 2>/dev/null &&
  no "notices a write after the check" || ok "notices a write after the check"
grep -q 'written after the check' "$MENU" && ! grep -q 'update.auto-update' "$MENU" &&
  ok "the late write is kept" || no "the late write is kept"
[[ -z $(find "${MENU%/*}" -name '.omarchy-auto-update.*') ]] && ok "no swap file left behind" || no "no swap file left behind"
"$HELPER" menu-install && grep -q 'written after the check' "$MENU" && grep -q 'update.auto-update' "$MENU" &&
  ok "the next try adds the entry over it" || no "the next try adds the entry over it"
