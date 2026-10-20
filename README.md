# Auto Update for Omarchy

Updating Omarchy means watching a terminal: Arch packages, AUR, firmware, settings migrations, then "reboot now?". Most people aren't developers, and a terminal or a red screen reads as "something broke".

Auto Update does the waiting for you:

- **Checks, downloads and verifies in the background**, with no password, into a private cache. Nothing on the system changes until you say so.
- **Tells you in plain words** what is ready, and whether it finishes with a restart (kernel, Qt, Hyprland, drivers, Omarchy itself).
- **Shows Arch news you should read first.**
- **Installs without a terminal**: enter your password once, watch a progress window, restart when it says so. Under the hood it runs Omarchy's own `omarchy update -y`, so nothing in Omarchy's update is skipped.

Status: early. Restart-time installs and one-click undo are next. Design notes in `docs/`.

## Install

```bash
omarchy plugin add https://github.com/AI-Dico/omarchy-auto-update --enable
```

## How it decides

Arch doesn't support partial upgrades, so Auto Update always fetches and judges the whole pending set. A set that touches the kernel, boot chain, core libraries, graphics, Qt, Quickshell, Hyprland or Omarchy is marked "finishes with a restart"; otherwise it is a small update.

## Privacy and safety

- Downloads use a separate copy of the package databases (`fakeroot pacman --dbpath`), never the system's.
- Your password goes from the password field to the updater over a pipe, is typed into sudo prompts of that one run, and is never written to disk or logs.
- The update log is kept at `~/.cache/omarchy-auto-update/last-update.log`.

## License

MIT
