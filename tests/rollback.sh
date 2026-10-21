#!/bin/bash
# Trying the restore point before an update: which boot entry, the one-time
# restart, the restore point boot, and the way back. Fake EFI variables, kernel
# command line, results, pkexec and systemctl; nothing restarts.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
H="$HERE/../bin/omarchy-auto-update"
pass=0 fail=0
ok() { echo "  ok   $1"; pass=$((pass + 1)); }
no() { echo "  FAIL $1"; fail=$((fail + 1)); }
GUID=4a67b082-0a4c-41cf-b6c7-440b29bb8c4f

# efivar <dir> <name> <value>...: a UTF-16 list after four attribute bytes.
efivar() {
  local dir=$1 name=$2
  shift 2
  python3 -I - "$dir/$name-$GUID" "$@" <<'PY'
import sys
data = b"\x07\x00\x00\x00" + "".join(v + "\0" for v in sys.argv[2:]).encode("utf-16-le") + b"\0\0"
open(sys.argv[1], "wb").write(data)
PY
}

setup() {
  T=$(mktemp -d)
  mkdir -p "$T/efi" "$T/spool" "$T/home/.config/autostart"
  export HOME="$T/home" XDG_STATE_HOME="$T/state" XDG_CONFIG_HOME="$T/home/.config" XDG_CACHE_HOME="$T/cache"
  export OMARCHY_AUTO_UPDATE_EFIVARS="$T/efi" OMARCHY_AUTO_UPDATE_SPOOL="$T/spool"
  export OMARCHY_AUTO_UPDATE_CMDLINE="$T/cmdline" OMARCHY_AUTO_UPDATE_SYSTEMCTL="$T/systemctl"
  export OMARCHY_AUTO_UPDATE_PKEXEC="$T/pkexec"
  printf '#!/bin/sh\necho "systemctl $*" >>"%s/calls"\n' "$T" >"$T/systemctl"
  # pkexec: records the root command; FAKE_DENY=1 is a cancelled password dialog.
  printf '#!/bin/sh\n[ -n "$FAKE_DENY" ] && exit 126\necho "pkexec $*" >>"%s/calls"\n' "$T" >"$T/pkexec"
  chmod +x "$T/systemctl" "$T/pkexec"
  echo "rootflags=subvol=/@ quiet" >"$T/cmdline"
  # Snapshot 6 taken two seconds after the install started (08:50:37 local).
  local at
  at=$(date -d '2026-10-21 08:50:37' +%s)
  echo "{\"ok\":true,\"state\":\"installed\",\"at\":$at,\"finishedAt\":$((at + 6)),\"count\":3,\"snapshots\":{\"root\":6},\"bootMenu\":true,\"packages\":[]}" >"$T/spool/result.json"
  efivar "$T/efi" LoaderEntries Omarchy.linux-omarchy "Omarchy.Snapshots.16-----2026-10-21-08-50-39.linux-omarchy" \
    "Omarchy.Snapshots.6-----2026-10-21-08-50-39.linux-omarchy" "Omarchy.Snapshots.5-----2026-10-21-08-11-16.linux-omarchy"
  efivar "$T/efi" LoaderEntrySelected Omarchy.linux-omarchy
}
state() { jq -r "$1" "$T/state/omarchy-auto-update/rollback.json" 2>/dev/null; }

echo "1. which restore point"
setup
info=$("$H" rollback-info)
[[ $(jq -r .entry <<<"$info") == "Omarchy.Snapshots.6-----2026-10-21-08-50-39.linux-omarchy" ]] &&
  ok "the entry of this update's snapshot, not 16" || no "the entry of this update's snapshot, not 16 ($info)"
[[ $(jq -r .normal <<<"$info") == Omarchy.linux-omarchy ]] && ok "remembers the normal entry" || no "remembers the normal entry"
jq '.snapshots.root = 7' "$T/spool/result.json" >"$T/r" && mv "$T/r" "$T/spool/result.json"
[[ $("$H" rollback-info | jq -r .reason) == no-boot-entry ]] && ok "no entry, no offer" || no "no entry, no offer"
jq '.snapshots.root = 5' "$T/spool/result.json" >"$T/r" && mv "$T/r" "$T/spool/result.json"
[[ $("$H" rollback-info | jq -r .reason) == no-boot-entry ]] && ok "an entry from another time is not it" || no "an entry from another time is not it"
jq '.bootMenu = false | .snapshots.root = 6' "$T/spool/result.json" >"$T/r" && mv "$T/r" "$T/spool/result.json"
[[ $("$H" rollback-info | jq -r .available) == false ]] && ok "not in the boot menu, no offer" || no "not in the boot menu, no offer"

echo "2. restarting into it once"
setup
"$H" try-restore
grep -qx -- "pkexec /usr/bin/bootctl set-oneshot Omarchy.Snapshots.6-----2026-10-21-08-50-39.linux-omarchy" "$T/calls" &&
  ok "that entry, once" || no "that entry, once"
[[ $(tail -n 1 "$T/calls") == "systemctl reboot" ]] && ok "then a restart" || no "then a restart"
[[ $(state .phase) == requested ]] && ok "the try is remembered" || no "the try is remembered"
grep -q '^Hidden=true' "$T/home/.config/autostart/limine-restore-notify.desktop" &&
  ok "Omarchy's terminal note is hidden for it" || no "Omarchy's terminal note is hidden for it"

echo "3. in the restore point"
echo "rootflags=subvol=/@/.snapshots/6/snapshot quiet" >"$T/cmdline"
st=$("$H" snapshot-state)
[[ $(jq -r '.inSnapshot, .ours' <<<"$st" | tr '\n' ' ') == "6 true " ]] && ok "knows it is our try" || no "knows it is our try ($st)"
[[ $(state .phase) == trying ]] && ok "marked as reached" || no "marked as reached"
[[ $("$H" status | jq -r '.reason, .count' | tr '\n' ' ') == "trying 0 " ]] && ok "no updates offered meanwhile" || no "no updates offered meanwhile"
"$H" try-restore 2>/dev/null && no "no second try from inside" || ok "no second try from inside"
"$H" return-updated
[[ $(tail -n 1 "$T/calls") == "systemctl reboot" ]] && ok "back with a plain restart" || no "back with a plain restart"

echo "4. back in the normal system"
echo "rootflags=subvol=/@ quiet" >"$T/cmdline"
jq '.fromBoot = "earlier"' "$T/state/omarchy-auto-update/rollback.json" >"$T/r" && mv "$T/r" "$T/state/omarchy-auto-update/rollback.json"
[[ $("$H" snapshot-state | jq -r .missed) == false ]] && ok "a finished try is not a miss" || no "a finished try is not a miss"
[[ ! -e $T/state/omarchy-auto-update/rollback.json ]] && ok "the try is cleared" || no "the try is cleared"
[[ ! -e $T/home/.config/autostart/limine-restore-notify.desktop ]] && ok "Omarchy's note is back" || no "Omarchy's note is back"

echo "5. a restart that didn't reach it"
setup
"$H" try-restore
jq '.fromBoot = "earlier"' "$T/state/omarchy-auto-update/rollback.json" >"$T/r" && mv "$T/r" "$T/state/omarchy-auto-update/rollback.json"
[[ $("$H" snapshot-state | jq -r .missed) == true ]] && ok "says it was missed" || no "says it was missed"

echo "6. the user's own autostart file"
setup
printf '[Desktop Entry]\nHidden=false\n' >"$T/home/.config/autostart/limine-restore-notify.desktop"
"$H" try-restore
echo "rootflags=subvol=/@/.snapshots/6/snapshot" >"$T/cmdline"
"$H" snapshot-state >/dev/null
echo "rootflags=subvol=/@" >"$T/cmdline"
jq '.fromBoot = "earlier"' "$T/state/omarchy-auto-update/rollback.json" >"$T/r" && mv "$T/r" "$T/state/omarchy-auto-update/rollback.json"
"$H" snapshot-state >/dev/null
grep -q '^Hidden=false' "$T/home/.config/autostart/limine-restore-notify.desktop" &&
  ok "left as it was" || no "left as it was"

echo "7. a second request keeps the note ours"
setup
"$H" try-restore
"$H" try-restore
[[ $(state .hidNote) == true ]] && ok "still removed after the try" || no "still removed after the try"

echo "8. partly installed"
setup
jq '.ok = false | .state = "partial"' "$T/spool/result.json" >"$T/r" && mv "$T/r" "$T/spool/result.json"
[[ $("$H" rollback-info | jq -r .available) == true ]] && ok "can still go back" || no "can still go back"

echo "9. reached as soon as the shell asks"
setup
"$H" try-restore
echo "rootflags=subvol=/@/.snapshots/6/snapshot" >"$T/cmdline"
"$H" status >/dev/null
[[ $(state .phase) == trying ]] && ok "status marks it" || no "status marks it"

echo "10. that restart came back to the restore point"
"$H" return-updated
"$H" return-updated
[[ $(tail -n 1 "$T/calls") == "systemctl reboot" ]] && ok "pressed again in the same boot: still plain" || no "pressed again in the same boot: still plain"
jq '.returnFrom = "earlier"' "$T/state/omarchy-auto-update/rollback.json" >"$T/r" && mv "$T/r" "$T/state/omarchy-auto-update/rollback.json"
"$H" return-updated
tail -n 2 "$T/calls" | head -n 1 | grep -qx "pkexec /usr/bin/bootctl set-oneshot Omarchy.linux-omarchy" &&
  ok "back again from another boot: the normal entry by name" || no "back again from another boot: the normal entry by name"
jq '.normal = "Gone.linux" | .returnFrom = "earlier"' "$T/state/omarchy-auto-update/rollback.json" >"$T/r" && mv "$T/r" "$T/state/omarchy-auto-update/rollback.json"
"$H" return-updated
tail -n 2 "$T/calls" | head -n 1 | grep -qx "pkexec /usr/bin/bootctl set-oneshot Omarchy.linux-omarchy" &&
  ok "the only entry outside Snapshots" || no "the only entry outside Snapshots"
efivar "$T/efi" LoaderEntries "Omarchy.Snapshots.6-----2026-10-21-08-50-39.linux-omarchy"
jq '.returnFrom = "earlier"' "$T/state/omarchy-auto-update/rollback.json" >"$T/r" && mv "$T/r" "$T/state/omarchy-auto-update/rollback.json"
before=$(wc -l <"$T/calls")
"$H" return-updated 2>/dev/null && no "no blind restart" || ok "no blind restart"
[[ $(wc -l <"$T/calls") == "$before" ]] && ok "nothing restarted" || no "nothing restarted"

echo "11. the password dialog is cancelled"
setup
FAKE_DENY=1 "$H" try-restore 2>/dev/null && no "stops" || ok "stops"
[[ ! -e $T/calls ]] && ok "no restart" || no "no restart"
[[ ! -e $T/state/omarchy-auto-update/rollback.json && ! -e $T/home/.config/autostart/limine-restore-notify.desktop ]] &&
  ok "nothing left behind" || no "nothing left behind"

echo "12. the restart failed and a second try is cancelled"
setup
printf '#!/bin/sh\nexit 1\n' >"$T/systemctl"
"$H" try-restore 2>/dev/null
FAKE_DENY=1 "$H" try-restore 2>/dev/null
[[ $(state .armed) == true ]] && ok "the armed try is kept" || no "the armed try is kept"

echo "13. saving the try fails"
setup
mkdir -p "$T/state/omarchy-auto-update" && chmod 500 "$T/state/omarchy-auto-update"
"$H" try-restore 2>/dev/null && no "stops" || ok "stops"
[[ ! -e $T/calls ]] && ok "no restart" || no "no restart"
[[ ! -e $T/home/.config/autostart/limine-restore-notify.desktop ]] && ok "Omarchy's note untouched" || no "Omarchy's note untouched"
chmod 700 "$T/state/omarchy-auto-update"

echo "14. a restore point started from the boot menu"
setup
echo "rootflags=subvol=/@/.snapshots/5/snapshot" >"$T/cmdline"
[[ $("$H" status | jq -r '.state, .reason' | tr '\n' ' ') == "uptodate snapshot " ]] &&
  ok "nothing to decide, no updates" || no "nothing to decide, no updates"

echo "15. a partly installed update can be shown"
setup
jq '.ok = false | .state = "partial" | .packages = [{"name":"a","from":"1","to":"2"}]' "$T/spool/result.json" >"$T/r" && mv "$T/r" "$T/spool/result.json"
[[ $("$H" last-applied | jq -r .state) == partial ]] && ok "last-applied returns it" || no "last-applied returns it"

echo "passed $pass, failed $fail"
((fail == 0))
