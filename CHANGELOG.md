# Changelog

## 1.1.0 (2026-09-26)

Versions apply to `gentoo-install.sh`, `gentoo-install-tui.sh` and `gentoo-helper.sh` together.

### Fixed
- Disk space cleanup did not delete downloaded binary packages any more. Current Portage stores them in `/var/cache/binhost/<name>` instead of `PKGDIR` (Gentoo news item 2026-05-03). The installer now clears that location too, including any custom `location` set in `binrepos.conf`. This affects the free space check before each step and the cleanups after the base update, the desktop and the final step.
- NVIDIA driver on Maxwell, Pascal and Volta cards (GTX 750, 900 and 10xx series, Titan V): `nvidia-drivers` 595 and newer, now the stable default, only support Turing and newer cards, so both the installer and `gentoo-helper` installed a driver that could not drive these cards. They now detect the card generation and keep the driver on the 580 branch (`>=x11-drivers/nvidia-drivers-581` masked). Kepler and older cards get Nouveau with an explanation.
- `gentoo-helper`: the "older Intel graphics" video decoding option used `x11-libs/libva-intel-driver`, which moved to `media-libs/libva-intel-driver`.
- `gentoo-helper`: Flatpak search and app lists could shift columns when a field was empty (tab-separated reads collapse empty fields).
- README: the console installer's download command started with `hhttps://`.

### Changed
- The installer no longer offers KeePassXC and OBS Studio as native packages: Gentoo currently has only testing (`~amd64`) versions of them, so installing them on a stable system failed. Both remain available as Flatpaks in the installer and `gentoo-helper`.
- The NVIDIA licence exception written by the installer now names `NVIDIA-2025`, the licence the driver uses today (it is also covered by `@BINARY-REDISTRIBUTABLE`).
- `gentoo-helper` NVIDIA wording: kernel mode setting is on by default in current drivers, and a licence prompt only appears if your licence settings require one. Its Wi-Fi task marks the Broadcom `wl` driver as a testing version.
- `gentoo-helper` saves version blocks in `/etc/portage/package.mask/zz-gentoo-helper`, shown and removable under Maintenance > Settings added by this helper.
- Download URLs use the `refs/heads/main` form throughout.
- README: tested-combinations table, updated status, older-NVIDIA notes, licence section.

### Checked, no change needed
- No Gentoo news items since the last review. Stage3 index format, binary package host paths (`23.0/x86-64`, `23.0/x86-64-v3`) and all selectable 23.0 profiles are current.
- installkernel, systemd, systemd-utils and PipeWire still have every USE flag the scripts set.
- Live ISO: `dialog` still ships (via `mirrorselect`), `zoneinfo` and `i18n` are still emptied.
- tzdata 2026d has the same 312 zones as the built-in list (2026a).
- All 27 Flathub app IDs exist.

## 1.0.0 (2026-09-25)

First release: console and menu (TUI) installers, `gentoo-helper` with common tasks, README.
