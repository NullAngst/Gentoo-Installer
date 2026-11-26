# Monthly maintenance checklist

Once a month I go through this so the installer doesn't quietly rot while Gentoo moves underneath it. Most months nothing changes, and that's a fine result. Don't make changes just to have something to commit.

Last review: 2026-11-26, v1.4.0
Current version: 1.4.0
Changes since the last review:
- none yet

## 1. Start clean

Fresh clone, then reread README.md and changes.md. Easy to forget what the README actually promises, and changes.md is the record of what I already checked.

Then run the checks once before touching anything, so I know the starting point is green:

```
bash build.sh -c
bash build.sh -l
bash tests/run_tests.sh
```

The tests need `sfdisk` (util-linux, the `fdisk` package on Debian and Ubuntu) and ShellCheck. GitHub Actions runs the same three on every push and pull request; if the last run on main is red, start there.

## 2. What changed upstream

Go through the news items (https://www.gentoo.org/support/news-items/, or a clone of github.com/gentoo/gentoo-news) and the AMD64 Handbook (https://wiki.gentoo.org/wiki/Handbook:AMD64) since the last review. The stuff that matters here:

- profile names and version
- stage3 variants
- the binary package host
- where Portage keeps downloaded binary packages (it moved to /var/cache/binhost/<name> in the 2026-05-03 news item and silently broke the disk cleanup, so watch this one)
- installkernel, dracut, kernel-install (dracut 111 stopped guessing the kernel command line, news item 2026-05-08; the installer sets it explicitly, keep it that way)
- GRUB and systemd-boot
- Perl or Python upgrades that need manual steps
- PipeWire
- display managers (Plasma 6.8 drops X11 and switches SDDM to Wayland through the profile, news item 2026-10-15)
- NetworkManager
- OpenRC and systemd service names

## 3. Package moves

Read `profiles/updates/` in gentoo.git for the current and previous quarter (files named like `4Q-2026`). Every `move` line naming a package the scripts use breaks installs, because emerge does not translate old names given on the command line. That's how `x11-misc/sddm` to `gui-apps/sddm` broke every Plasma and LXQt install with a login screen before 1.4.0.

## 4. Live data formats

The installer parses these directly, so if the format shifts, installs break. Pull them and compare against the parsers and paths in src/40_install.sh:

- https://distfiles.gentoo.org/releases/amd64/autobuilds/latest-stage3-amd64-desktop-systemd.txt
- https://distfiles.gentoo.org/releases/amd64/autobuilds/latest-stage3-amd64-openrc.txt
- https://distfiles.gentoo.org/releases/amd64/binpackages/

Make sure the binhost paths the installer writes (23.0/x86-64 and 23.0/x86-64-v3 as of 1.4.0) still exist, and that every profile the installer lets you pick is still there. If those URLs can't be fetched, scripts/copy_buildsync.sh in github.com/gentoo/releng shows how the stage3 index is written; note in changes.md that the live files weren't checked.

## 5. Package atoms and USE flags

Pull every category/package name out of src/ and gentoo_helper.sh and check each one against https://github.com/gentoo/gentoo (master). Each needs to exist, not be masked or last-rited, and have a stable amd64 keyword. Write down anything that moved, got renamed or got removed, and what replaced it. (libva-intel-driver moving from x11-libs to media-libs is the kind of thing this catches.)

A sparse clone makes this quick: `git clone --depth 1 --filter=blob:none --sparse https://github.com/gentoo/gentoo`, then `git sparse-checkout add` the categories in question. Read KEYWORDS from the newest ebuilds.

Also check that the USE flags the scripts set on installkernel, systemd, systemd-utils and PipeWire still exist, and that GRUB still has the efi-32, efi-64 and pc platforms.

Things I dropped, flagged or special-cased because of keywords, check if that's still true:

- OBS Studio is ~amd64 only, so it's Flatpak only. KeePassXC went stable in 1.4.0 and is offered native again.
- net-wireless/broadcom-sta (the Broadcom `wl` driver) and app-laptop/mbpfan are ~amd64 only. The installer accepts the testing keyword for just those two, and only when the user says yes. If either goes stable, drop its line from write_package_files in src/40_install.sh and the "testing version" wording in src/30_questions.sh and gentoo_helper.sh. If either gets last-rited, that's a bigger problem.
- broadcom-sta builds against new kernels only through community patches. Check its ebuild still applies them and isn't masked for the current stable gentoo-kernel.
- gnome-extra/gnome-software is ~amd64 only. The installer only writes a package.use line for it, which is harmless.

## 6. Login shells

The list is bash, zsh, fish, Nushell, dash, ksh, mksh, loksh, yash and tcsh. Check each is still in app-shells with a stable amd64 version, and whether anything new in app-shells went stable. Check whether Nushell's package adds itself to /etc/shells yet, since the installer handles that by hand. If any shell changed its login file or syntax, retest the Sway autostart in it.

## 7. NVIDIA

- nvidia-drivers 595 and newer only support Turing and up. Maxwell, Pascal and Volta get pinned to the 580 branch with `>=x11-drivers/nvidia-drivers-581` masked. Check 580 is still in the tree, still stable, and not last-rited. If it's on its way out, that's a bigger problem than a monthly fix.
- Check whether a newer branch dropped another generation, which would mean a new cutoff.
- Kepler and older go to Nouveau. Still right?
- The licence is still NVIDIA-2025.
- gentoo_helper keeps its version blocks in /etc/portage/package.mask/zz-gentoo-helper, so make sure that still works with the current mask.

## 8. Boot, Macs and other hardware

- GRUB's `--no-nvram` and bootctl's `--no-variables` still exist and still do the same thing.
- EFI/BOOT/BOOTX64.EFI (and BOOTIA32.EFI for 32-bit UEFI) is still the fallback path.
- 32-bit UEFI relies on the distribution kernel having CONFIG_EFI_MIXED (it comes from Fedora's config). If gentoo-kernel ever drops it, 32-bit UEFI installs stop booting.
- The Broadcom device ID table (broadcom_wifi_kind in src/20_detect.sh and broadcom_kind_here in gentoo_helper.sh) must stay the same in both places.
- mbpfan still installs an OpenRC service named mbpfan and a systemd unit mbpfan.service.
- TLP still blocks power-profiles-daemon, and the installer still only installs one of them.

## 9. Live ISO

Check the specs in https://github.com/gentoo/releng:

- dialog still ships (it comes in via mirrorselect)
- /usr/share/zoneinfo and /usr/share/i18n are still emptied
- every tool in LIVE_TOOLS (src/20_detect.sh) is still on the ISO, plus parted, dosfstools, cryptsetup, btrfs-progs and xfsprogs

## 10. Other drift

- tzdata zone list vs BUILTIN_TIMEZONES (the built-in list is from 2026a, 312 zones, and 2026f matched it)
- Flathub app IDs in the catalog (27 at last check, all of them, not a sample). `git ls-remote https://github.com/flathub/<app-id>` answers for each, except Firefox, which Mozilla publishes directly.

## 11. Code pass

While I'm in there, read through for quality problems and bugs. Ones I've already been bitten by:

- tab-separated reads collapse empty fields, so any `IFS=$'\t' read` against data that can have an empty field will shift columns
- the README's download commands. Copy and run them. The `hhttps://` typo sat there for a whole release.
- a question that resets its variable before reading the previous answer as its default always defaults to "no" (an early draft of the 1.4.0 mbpfan question did this; the tests now catch it)
- gentoo_helper runs with `set -e`, so a new command whose failure is fine needs `|| true`, and `cmd; rc=$?` has to be `rc=0; cmd || rc=$?`

The shell standards the scripts follow: printf not echo, `[ ]` except for pattern or regex matches, no eval, no GNU-only options, getopts, `--` before file names, `IFS= read -r`, temp files under one `mktemp -d` directory cleaned up on exit. ShellCheck at style level with no exclusions.

## 12. Fix, build, test

Fix whatever is broken or outdated, then:

```
bash build.sh
bash build.sh -l
bash build.sh -c
bash tests/run_tests.sh
```

Maintenance doesn't change defaults or behaviour. If one of those needs to change, that's its own decision, so write it down and think it through before touching it.

## 13. Release

- Bump the version in src/10_core.sh (SCRIPT_VERSION) and gentoo_helper.sh (VERSION) together, then rebuild. They share one version number, and the tests fail if they differ. New releases bump the minor version (1.4.0 to 1.5.0), not the patch number.
- changes.md entry in its format: a `YYYY.MM.DD - <update type> (<version>)` line, bullets starting with Fixed, Added, Changed, "Checked, no change needed" or "Could not check", then "Reasons for changes:". The checked bullets are how next month knows what was actually verified.
- Update the tested-combinations table in the README. ADD rows, don't rewrite the table. The 1.2.0 README dropped the 2026-09-26 runs and I had to put them back in 1.3.0.
- Fix any README claims that aren't true anymore.
- Update the "Last review" and "Changes since" lines at the top of this file.

## Keeping notes

Sort findings by how bad they are: breaks installs, wrong but harmless, cosmetic. Keep track of what I actually checked, what I assumed, and what I couldn't check at all (site down, fetch blocked, whatever). Future me will want to know which is which.
