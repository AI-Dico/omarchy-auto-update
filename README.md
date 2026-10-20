# Auto Update for Omarchy

Updating Omarchy means watching a terminal: Arch packages, AUR, firmware, settings migrations, then "reboot now?". Most people aren't developers, and a terminal or a red screen reads as "something broke".

Auto Update does the waiting for you:

- **Checks, downloads and verifies in the background**, with no password, into a private cache. Nothing on the system changes until you say so.
- **Tells you in plain words** what is ready, and whether it finishes with a restart (kernel, Qt, Hyprland, drivers, Omarchy itself).
- **Shows Arch news you should read first.**
- **Installs while you restart**, like macOS and Windows: for sets that touch the system's core, choose *Restart to update*, enter your password once, and restart now or later. The computer saves a restore point, installs exactly the set you agreed to, and starts again. Omarchy's own settings steps finish on their own after you log in.
- **Or installs now without a terminal**: enter your password once and watch a progress window. Under the hood it runs Omarchy's own `omarchy update -y`, so nothing in Omarchy's update is skipped.

Status: early. One-click undo and quiet installs are next. Design notes in `docs/`.

## Install

```bash
omarchy plugin add https://github.com/AI-Dico/omarchy-auto-update --enable
```

## Bar icon
The rocket sits next to Omarchy's own update icon and shows only when there is something to say; warnings and Arch news use a warning sign instead. In the update window, **Bar icon** picks *Shown* (default), *Only when important* (hides a set that is simply downloaded and ready, but still shows restarts, warnings, news and a running update) or *Hidden*. While the icon is hidden you get one notification for each new set, warning or Arch news item, and *Update › Auto Update* in the Omarchy menu always opens the window. The choice is kept in `~/.config/omarchy-auto-update/config.json` (`omarchy-auto-update config set icon-mode shown|important|hidden`). The menu entry lives in a marked block of `~/.config/omarchy/extensions/omarchy-menu.jsonc`; `omarchy-auto-update menu-remove` takes it out and it stays out.

## How it decides

Arch doesn't support partial upgrades, so Auto Update always fetches and judges the whole pending set. A set that touches the kernel, boot chain, core libraries, graphics, Qt, Quickshell, Hyprland or Omarchy is marked "finishes with a restart"; otherwise it is a small update.

## Privacy and safety

- Downloads use a separate copy of the package databases (`fakeroot pacman --dbpath`), never the system's.
- Your password goes from the password field to the updater over a pipe, is typed into sudo prompts of that one run, and is never written to disk or logs.
- *Restart to update* installs a small root-owned script and a systemd offline-update unit the first time you use it (`/usr/local/libexec/omarchy-auto-update/offline`, `/etc/systemd/system/omarchy-auto-update-offline.service`). As root it fetches its own copy of the package lists, requires package signatures, re-plans the update and stops if the plan isn't the one you agreed to; from your cache it takes only the package files, which must be regular files you own with exactly the expected size. At boot it removes its trigger first, so a failure always ends in a normal boot.
- The update log is kept at `~/.cache/omarchy-auto-update/last-update.log`; the restart install writes `/var/lib/omarchy-auto-update/apply.log`.

## License

MIT
