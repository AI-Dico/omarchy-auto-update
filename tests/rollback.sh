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
  # Limine's restore (through script) runs for real, as the stand-in in $T/lss.
  printf '#!/bin/sh\n[ -n "$FAKE_DENY" ] && exit 126\necho "pkexec $*" >>"%s/calls"\n[ "${1##*/}" = script ] && exec "$@"\nexit 0\n' "$T" >"$T/pkexec"
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

# A stand-in for Limine's restore: asks what the real one asks, records the answers.
make_lss() {
  cat >"$T/lss" <<EOF
#!/bin/bash
echo "Snapshot ID     : \${FAKE_SNAP:-6}"
echo " Restore snapshot \${FAKE_SNAP:-6} (method: replace)?"
echo " [r] restore | [l] list | [c] cancel"
printf 'Choice [r/l/c]: '; read -r a; echo "choice=\$a" >>"$T/answers"
[[ \$a == r ]] || exit 0
printf 'Description for backup subvolume @: '; read -r d; echo "describe=\$d" >>"$T/answers"
echo "Mounting Btrfs..."
[[ -n \${FAKE_HOOK:-} ]] && { printf 'Continue? [Y/n]: '; read -r h; echo "hook=\$h" >>"$T/answers"; printf 'Also this? [y/N]: '; read -r h; echo "hook2=\$h" >>"$T/answers"; }
printf '\nRestore complete. Reboot now? [Y/n]: '; read -r b; echo "reboot=\$b" >>"$T/answers"
EOF
  chmod +x "$T/lss"
  export OMARCHY_AUTO_UPDATE_LSS="$T/lss"
}
reboots() { grep -c '^systemctl reboot' "$T/calls"; }

echo "16. keeping the restore point"
setup
make_lss
jq '.packages = [{"name":"a","from":"1","to":"2"}]' "$T/spool/result.json" >"$T/r" && mv "$T/r" "$T/spool/result.json"
"$H" try-restore
echo "rootflags=subvol=/@/.snapshots/6/snapshot" >"$T/cmdline"
"$H" keep-restore && ok "kept" || no "kept ($(cat "$T/cache/omarchy-auto-update/restore.log" 2>/dev/null | tail -3))"
[[ $(tr '\n' ' ' <"$T/answers") == "choice=r describe=The updated version, kept by Auto Update reboot=n " ]] &&
  ok "answered once each" || no "answered once each ($(tr '\n' ' ' <"$T/answers"))"
[[ $(tail -n 1 "$T/calls") == "systemctl reboot" ]] && ok "then a restart" || no "then a restart"
[[ $(jq -r '.packages[0].to' "$T/state/omarchy-auto-update/held.json") == 2 ]] && ok "the update is held" || no "the update is held"
[[ $(state .phase) == kept ]] && ok "the try says kept" || no "the try says kept"

echo "17. after the restart"
echo "rootflags=subvol=/@" >"$T/cmdline"
jq '.fromBoot = "earlier"' "$T/state/omarchy-auto-update/rollback.json" >"$T/r" && mv "$T/r" "$T/state/omarchy-auto-update/rollback.json"
[[ $("$H" snapshot-state | jq -r '.kept | type') == object ]] && ok "says it was kept" || no "says it was kept"
[[ ! -e $T/state/omarchy-auto-update/rollback.json ]] && ok "once" || no "once"
mkdir -p "$T/cache/omarchy-auto-update"
echo '{"state":"ready","count":1,"packages":[{"name":"a","from":"1","to":"2"}],"fingerprint":"x"}' >"$T/cache/omarchy-auto-update/state.json"
[[ $("$H" status | jq -r .state) == held ]] && ok "the same set waits" || no "the same set waits"
echo '{"state":"ready","count":1,"packages":[{"name":"a","from":"1","to":"3"}],"fingerprint":"y"}' >"$T/cache/omarchy-auto-update/state.json"
[[ $("$H" status | jq -r .state) == ready ]] && ok "a newer one is offered" || no "a newer one is offered"
[[ ! -e $T/state/omarchy-auto-update/held.json ]] && ok "and ends the hold" || no "and ends the hold"

echo "18. a restore point that isn't the one asked about"
setup
make_lss
"$H" try-restore
echo "rootflags=subvol=/@/.snapshots/6/snapshot" >"$T/cmdline"
FAKE_SNAP=5 "$H" keep-restore 2>/dev/null && no "stops" || ok "stops"
[[ $(cat "$T/answers") == "choice=c" ]] && ok "cancelled at the question" || no "cancelled at the question"
[[ $(reboots) == 1 && ! -e $T/state/omarchy-auto-update/held.json ]] && ok "no restart, nothing held" || no "no restart, nothing held"

echo "19. the password dialog is cancelled when keeping"
setup
make_lss
"$H" try-restore
echo "rootflags=subvol=/@/.snapshots/6/snapshot" >"$T/cmdline"
FAKE_DENY=1 "$H" keep-restore 2>"$T/err" && no "stops" || ok "stops"
grep -q "password wasn't given" "$T/err" && ok "says why" || no "says why ($(cat "$T/err"))"
[[ ! -e $T/answers && $(state .phase) == requested && ! -e $T/state/omarchy-auto-update/held.json ]] && ok "still trying" || no "still trying"

echo "20. not from the normal system"
setup
make_lss
"$H" keep-restore 2>/dev/null && no "refused" || ok "refused"

echo "21. a hook asks something after the restore started"
setup
make_lss
"$H" try-restore
echo "rootflags=subvol=/@/.snapshots/6/snapshot" >"$T/cmdline"
FAKE_HOOK=1 "$H" keep-restore && ok "still kept" || no "still kept"
grep -qx "hook=n" "$T/answers" && grep -qx "hook2=n" "$T/answers" && ok "answered no" || no "answered no ($(tr '\n' ' ' <"$T/answers"))"

echo "22. the hold can't be saved"
setup
make_lss
"$H" try-restore
echo "rootflags=subvol=/@/.snapshots/6/snapshot" >"$T/cmdline"
chmod 500 "$T/state/omarchy-auto-update"
"$H" keep-restore 2>/dev/null && no "stops" || ok "stops"
[[ ! -e $T/answers ]] && ok "before restoring" || no "before restoring"
chmod 700 "$T/state/omarchy-auto-update"

# A keep cut off (the power went): its records written, never renamed.
cut_keep() {
  setup
  make_lss
  jq '.packages = [{"name":"a","from":"1","to":"2"}]' "$T/spool/result.json" >"$T/r" && mv "$T/r" "$T/spool/result.json"
  "$H" try-restore
  echo "rootflags=subvol=/@/.snapshots/6/snapshot" >"$T/cmdline"
  "$H" snapshot-state >/dev/null
  jq -c '{at: 1, from: .at, packages}' "$T/state/omarchy-auto-update/rollback.json" >"$T/state/omarchy-auto-update/held.json.next"
  jq -c '.phase = "kept" | .keptAt = 2' "$T/state/omarchy-auto-update/rollback.json" >"$T/state/omarchy-auto-update/rollback.json.next"
  echo "rootflags=subvol=/@" >"$T/cmdline"
  jq '.fromBoot = "earlier"' "$T/state/omarchy-auto-update/rollback.json" >"$T/r" && mv "$T/r" "$T/state/omarchy-auto-update/rollback.json"
  printf '#!/bin/sh\necho "a %s"\n' "$1" >"$T/pacman" && chmod +x "$T/pacman"
  export OMARCHY_AUTO_UPDATE_PACMAN="$T/pacman"
}

echo "23. keeping was cut off before it changed anything"
cut_keep 2
st=$("$H" snapshot-state)
[[ $(jq -r '.interrupted, (.kept | type)' <<<"$st" | tr '\n' ' ') == "updated null " ]] && ok "says the updates are still there" || no "says the updates are still there ($st)"
[[ -z $(ls "$T/state/omarchy-auto-update/") ]] && ok "leaves nothing behind" || no "leaves nothing behind ($(ls "$T/state/omarchy-auto-update/"))"
[[ ! -e $T/home/.config/autostart/limine-restore-notify.desktop ]] && ok "Omarchy's note is back" || no "Omarchy's note is back"

echo "24. cut off after the restore itself was done"
cut_keep 1
st=$("$H" snapshot-state)
[[ $(jq -r '.interrupted, (.kept | type)' <<<"$st" | tr '\n' ' ') == "null object " ]] && ok "it was kept after all" || no "it was kept after all ($st)"
[[ -e $T/state/omarchy-auto-update/held.json ]] && ok "the update is held" || no "the update is held"

echo "25. cut off, and the versions don't tell"
cut_keep 9
[[ $("$H" snapshot-state | jq -r .interrupted) == unknown ]] && ok "says it can't tell" || no "says it can't tell"
unset OMARCHY_AUTO_UPDATE_PACMAN

echo "26. cut off after the restore, with a new package in the update"
cut_keep 1
jq -c '.packages += [{"name":"b","from":"","to":"5"}]' "$T/state/omarchy-auto-update/rollback.json.next" >"$T/r" && mv "$T/r" "$T/state/omarchy-auto-update/rollback.json.next"
printf '#!/bin/sh\n[ "$3" = a ] && echo "a 1"\nexit 0\n' >"$T/pacman"
[[ $("$H" snapshot-state | jq -r '.kept | type') == object ]] && ok "still kept" || no "still kept"
unset OMARCHY_AUTO_UPDATE_PACMAN

echo "passed $pass, failed $fail"
((fail == 0))
