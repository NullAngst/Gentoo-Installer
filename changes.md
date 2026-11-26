# Changes

Every update, newest first. The version applies to `gentoo_install.sh`, `gentoo_install_tui.sh` and `gentoo_helper.sh` together.

2026.11.26 - Monthly maintenance / Standards overhaul / Hardware support (1.4.0)

* Fixed (broke installs): KDE Plasma and LXQt installs with a login screen failed, because `x11-misc/sddm` moved to `gui-apps/sddm` (profiles/updates/4Q-2026) and emerge does not translate old names given on the command line. The installer and gentoo_helper's list of essential packages use the new name.
* Fixed: eMMC boot areas (`mmcblk0boot0`, `mmcblk0boot1`, `rpmb`), read-only devices and empty devices were offered as install targets.
* Fixed: on a Mac, answering "BIOS" at the Mac boot question produced a GPT disk the Mac could not start. It now gets an MBR partition table with an active partition, which the Mac's legacy boot starts.
* Fixed: hardware was detected after the network step, so the network step could not know about Wi-Fi cards the live system cannot drive. Detection now runs first.
* Fixed: when a RAID, Intel RST or VMD controller hides the disks, the installer only said no disks were found. It now says to switch the controller to AHCI, with a warning for computers that also run Windows.
* Added: MBR partition table option in BIOS mode, for old BIOSes that do not start from GPT disks (disks under 2 TiB only). Picked automatically for Macs in BIOS mode.
* Added: 32-bit UEFI with a 64-bit CPU (Intel Atom tablets and small laptops from around 2014). GRUB's i386-efi build starts the 64-bit kernel through EFI mixed mode, with the fallback path `EFI/BOOT/BOOTIA32.EFI`. Macs with 32-bit EFI go to BIOS mode with MBR instead of being refused.
* Added: Broadcom Wi-Fi. Cards that only work with the `wl` driver (BCM4360, BCM4352, BCM43142, BCM43228; most Macs from 2013 on) get an offer for `net-wireless/broadcom-sta`, with its testing keyword and Broadcom licence accepted for that one package and the open drivers blacklisted. Cards on the b43 driver (BCM4311 to BCM4331) get `sys-firmware/b43-firmware`. The network step explains that the live system cannot use a `wl` card.
* Added: Mac fan control with `app-laptop/mbpfan` (testing keyword for that one package, sensor modules listed in `/etc/modules-load.d/mbpfan.conf`, service enabled). Offered on every Mac, yes by default on MacBooks.
* Added: laptop power management: `power-profiles-daemon` with Plasma or GNOME, TLP with everything else (systemd-rfkill masked as TLP asks), plus `thermald` on Intel CPUs.
* Added: `switcheroo-control` with Plasma or GNOME when there are two graphics chips.
* Added: `sof-firmware` on all real hardware, since AMD laptops use Sound Open Firmware too (it was Intel only).
* Added: warning for Apple T2 Macs (2018 to 2020), whose keyboard, trackpad, Wi-Fi and audio need the t2linux kernel.
* Added: KeePassXC as a native package again, since `app-admin/keepassxc` 2.8.0 is now stable.
* Added: gentoo_helper tasks "Laptop and Mac hardware" (power profiles or TLP, thermald, mbpfan, switcheroo-control) and "Firmware updates" (fwupd). The Wi-Fi task recognises Broadcom cards that need `wl` or `b43-firmware` and blacklists the open drivers after installing `wl`.
* Added: `tests/run_tests.sh` (options, every automatic partition layout written to a disk image with sfdisk, the config files the installer writes, every question with default answers on simulated Mac hardware, the zram script as POSIX sh) and a GitHub Actions workflow that runs the build check, ShellCheck and the tests on pushes to main and on pull requests.
* Changed: script names use underscores: `gentoo_install.sh`, `gentoo_install_tui.sh`, `gentoo_helper.sh`, `src/10_core.sh` and so on. The download URLs change with them. The installed helper is now `/usr/local/bin/gentoo_helper`, and the scripts the installer writes are `/usr/local/sbin/zram_swap` and `/usr/local/sbin/install_my_flatpaks`. Log files and gentoo_helper's `zz-gentoo-helper` settings files keep their names.
* Changed: shell standards across all scripts: `printf` instead of `echo`, `[ ]` instead of `[[ ]]` except for pattern and regex matches, `=` instead of `==`, `.` instead of `source`, `IFS= read -r`, `--` before file names, `cd ... || exit`.
* Changed: no `eval`. The menu version used `eval` to copy the console prompt functions; the console functions are now named `cli_*` and each front end maps the shared names to its own versions. The one ShellCheck exception is gone: all scripts pass ShellCheck at style level with no exclusions.
* Changed: no GNU-only options: `sed -i`, `readlink -f`, `find -printf`, `find -delete`, `find -quit`, `date -d`, `stat -c`, `sort -V`, `sort -h`, `cp --dereference` and `\x` escapes in sed are replaced with portable forms.
* Changed: temporary files live in one private directory made with `mktemp -d "${TMPDIR:-/tmp}/..."` and removed on exit.
* Changed: options are read with getopts. Short forms `-r` and `-h` added; `--resume` and `--help` still work. gentoo_helper gets `-h`, `-V` and `-t` (text menus).
* Changed: bash 4.4 or newer is enough (was 5), checked first.
* Changed: both installers and gentoo_helper check for every command they need up front and list all missing ones.
* Changed: command output that is parsed is read with `LC_ALL=C` (lsblk, lspci, ufw, rfkill, sort).
* Changed: gentoo_helper runs with `set -euo pipefail`; every command whose failure it handles is guarded.
* Changed: `build.sh` uses getopts (`-c` check, `-l` lint, `-h` help) and also lints itself.
* Changed: the dracut config comment follows Gentoo news item 2026-05-08 (dracut 111 no longer guesses the kernel command line); the binary package comment follows 2026-05-03 (signatures checked by default).
* Changed: CHANGELOG.md became this file, in this format.
* Changed: README VM instructions use Kubuntu's OVMF paths, with openSUSE and Fedora as alternatives.
* Checked, no change needed: news item 2026-10-15 (Plasma 6.8 retires X11). The Plasma profile switches SDDM to Wayland by itself and nothing here installs `kwin-x11`. Plasma 6.8 is still testing only.
* Checked, no change needed: all eight selectable 23.0 profiles are stable. Stage3 index format (`<date>/<file> <size>`, from releng's copy_buildsync.sh) and the variant names are unchanged.
* Checked, no change needed: every package atom in src/ and gentoo_helper.sh against gentoo.git: all exist with a stable amd64 version, except `gnome-extra/gnome-software` (testing only, used only for a package.use line, harmless) and the two testing packages above, which get keywords.
* Checked, no change needed: installkernel (dracut, grub, systemd, systemd-boot), systemd (boot, cryptsetup), systemd-utils (boot, kernel-install) and PipeWire (bluetooth) still have every USE flag the scripts set. GRUB still has the efi-32, efi-64 and pc platforms.
* Checked, no change needed: nvidia-drivers 580.196.07 and 595.112.07 stable, 620 testing, 470 and 390 masked, licence NVIDIA-2025.
* Checked, no change needed: every login shell still has a stable amd64 version; Nushell still does not add itself to /etc/shells.
* Checked, no change needed: live ISO (releng, 2026-11-01): dialog comes with mirrorselect, zoneinfo and i18n are still emptied, parted, dosfstools, cryptsetup, btrfs-progs and xfsprogs ship.
* Checked, no change needed: tzdata 2026f has the same 312 zones as the built-in list.
* Checked, no change needed: Flathub app IDs: 26 of 27 have their Flathub repository. Firefox is published by Mozilla directly and has none, which is normal.
* Could not check: distfiles.gentoo.org was blocked from the machine I worked on, so the live stage3 index and the binary package host directories (23.0/x86-64, 23.0/x86-64-v3) were not fetched. The Handbook was only checked through search results. EFI mixed mode in the distribution kernel is based on Fedora's config enabling CONFIG_EFI_MIXED since 2015, not on reading the current config.

Reasons for changes: monthly maintenance found the SDDM move, which broke every Plasma and LXQt install with a login screen. The scripts were brought up to the current shell standards (underscore names, printf, POSIX tests, no eval, no GNU-only options, getopts, up-front command checks). Hardware support was widened for the machines this is actually used on, starting with the 2013 MacBook Pro, which needed mbpfan by hand and a Broadcom driver for its Wi-Fi.

2026.09.28 - Feature update (1.3.0)

* Added: login shell choice for the user account (Part 4, Accounts): bash, zsh, fish, Nushell, dash (sh), ksh, mksh, loksh, yash or tcsh, the interactive login shells in Gentoo's `app-shells` with a stable amd64 version. root keeps bash and `/bin/sh` is unchanged. The shell is installed as an optional package; if it fails, the user keeps bash and the failure is reported. Its path is added to `/etc/shells` when missing (Nushell is not listed by default). zsh gets a starter `~/.zshrc`, which also avoids its first-run wizard.
* Added: the post-install notes have a Login shell section.
* Changed: Sway's start-on-tty1 snippet is written to the login file of the user's actual shell, in that shell's syntax (sh-family, fish or tcsh), instead of always `~/.bash_profile`. Tested in bash, zsh, dash, ksh, mksh, yash, fish and tcsh. With Nushell there is no autostart.
* Changed: README: tested combinations merged into one table with the two runs from 2026-09-26 (those rows were dropped by the 1.2.0 README); new Login shells section; files table lists the NVIDIA package mask and the shell files.

Reasons for changes: requested login shell choice, and the README had lost test results.

2026.09.28 - Bug fix (1.2.0)

* Fixed: Intel Macs: when the live system was started in BIOS mode (for example with Ventoy, whose EFI mode does not start on some Macs), the installation did not boot. Macs only boot a BIOS-mode installation from an MBR disk, and the installer creates GPT, so the Mac showed a flashing folder. The installer now detects Apple hardware and offers (recommended) to install for EFI anyway. Reported on a 2013 MacBook Pro.
* Fixed: when the live system is not started in EFI mode, GRUB and systemd-boot are installed straight to the fallback path `EFI/BOOT/BOOTX64.EFI` (`--no-nvram` / `--no-variables`) instead of first failing to write a firmware boot entry.
* Changed: Macs with 32-bit EFI firmware (2006 and 2007 models) are refused with an explanation before any disk is touched, since this installer cannot make them boot.
* Changed: the hardware summary shows the Mac model, the install summary notes when the bootloader goes to the EFI fallback path, and the final screen tells Mac users how to pick the boot entry if needed.

Reasons for changes: the first real-hardware install, on a 2013 MacBook Pro, did not boot.

2026.09.26 - Monthly maintenance (1.1.0)

* Fixed: disk space cleanup did not delete downloaded binary packages any more. Current Portage stores them in `/var/cache/binhost/<name>` instead of `PKGDIR` (Gentoo news item 2026-05-03). The installer now clears that location too, including any custom `location` set in `binrepos.conf`. This affects the free space check before each step and the cleanups after the base update, the desktop and the final step.
* Fixed: NVIDIA driver on Maxwell, Pascal and Volta cards (GTX 750, 900 and 10xx series, Titan V): `nvidia-drivers` 595 and newer, now the stable default, only support Turing and newer cards, so both the installer and the helper installed a driver that could not drive these cards. They now detect the card generation and keep the driver on the 580 branch (`>=x11-drivers/nvidia-drivers-581` masked). Kepler and older cards get Nouveau with an explanation.
* Fixed: helper: the "older Intel graphics" video decoding option used `x11-libs/libva-intel-driver`, which moved to `media-libs/libva-intel-driver`.
* Fixed: helper: Flatpak search and app lists could shift columns when a field was empty (tab-separated reads collapse empty fields).
* Fixed: README: the console installer's download command started with `hhttps://`.
* Changed: the installer no longer offers KeePassXC and OBS Studio as native packages: Gentoo had only testing (`~amd64`) versions of them, so installing them on a stable system failed. Both remain available as Flatpaks in the installer and the helper.
* Changed: the NVIDIA licence exception written by the installer names `NVIDIA-2025`, the licence the driver uses today (it is also covered by `@BINARY-REDISTRIBUTABLE`).
* Changed: helper NVIDIA wording: kernel mode setting is on by default in current drivers, and a licence prompt only appears if your licence settings require one. Its Wi-Fi task marks the Broadcom `wl` driver as a testing version.
* Changed: the helper saves version blocks in `/etc/portage/package.mask/zz-gentoo-helper`, shown and removable under Maintenance > Settings added by this helper.
* Changed: download URLs use the `refs/heads/main` form throughout.
* Changed: README: tested-combinations table, updated status, older-NVIDIA notes, licence section.
* Checked, no change needed: no Gentoo news items since the last review. Stage3 index format, binary package host paths (`23.0/x86-64`, `23.0/x86-64-v3`) and all selectable 23.0 profiles are current.
* Checked, no change needed: installkernel, systemd, systemd-utils and PipeWire still have every USE flag the scripts set.
* Checked, no change needed: live ISO: `dialog` still ships (via `mirrorselect`), `zoneinfo` and `i18n` are still emptied.
* Checked, no change needed: tzdata 2026d has the same 312 zones as the built-in list (2026a).
* Checked, no change needed: all 27 Flathub app IDs exist.

Reasons for changes: first monthly maintenance review.

2026.09.25 - First release (1.0.0)

* Console and menu (TUI) installers, the package management helper with common tasks, README.

Reasons for changes: first release.
