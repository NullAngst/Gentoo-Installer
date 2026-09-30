# Monthly maintenance checklist

Once a month I go through this so the installer doesn't quietly rot while Gentoo moves underneath it. Most months nothing changes, and that's a fine result. Don't make changes just to have something to commit.

Last review: 2026-09-26, v1.1.0
Current version: 1.3.0
Changes since the last review:
- 1.2.0: Intel Macs started in BIOS mode now get offered an EFI install, bootloaders go straight to the EFI fallback path when the live system isn't in EFI mode, 32-bit EFI Macs are refused
- 1.3.0: login shell choice for the user account, Sway autostart written to the right login file per shell

## 1. Start clean

Fresh clone, then reread README.md and CHANGELOG.md. Easy to forget what the README actually promises, and the changelog is the record of what I already checked.

## 2. What changed upstream

Go through the news items (https://www.gentoo.org/support/news-items/) and the AMD64 Handbook (https://wiki.gentoo.org/wiki/Handbook:AMD64) since the last review. The stuff that matters here:

- profile names and version
- stage3 variants
- the binary package host
- where Portage keeps downloaded binary packages (it moved to /var/cache/binhost/<name> in the 2026-05-03 news item and silently broke the disk cleanup, so watch this one)
- installkernel, dracut, kernel-install
- GRUB and systemd-boot
- Perl or Python upgrades that need manual steps
- PipeWire
- display managers
- NetworkManager
- OpenRC and systemd service names

## 3. Live data formats

The installer parses these directly, so if the format shifts, installs break. Pull them and compare against the parsers and paths in src/40-install.sh:

- https://distfiles.gentoo.org/releases/amd64/autobuilds/latest-stage3-amd64-desktop-systemd.txt
- https://distfiles.gentoo.org/releases/amd64/autobuilds/latest-stage3-amd64-openrc.txt
- https://distfiles.gentoo.org/releases/amd64/binpackages/

Make sure the binhost paths the installer writes (23.0/x86-64 and 23.0/x86-64-v3 as of 1.1.0) still exist, and that every profile the installer lets you pick is still there.

## 4. Package atoms and USE flags

Pull every category/package name out of src/ and gentoo-helper.sh and check each one against https://github.com/gentoo/gentoo (master). Each needs to exist, not be masked or last-rited, and have a stable amd64 keyword. Write down anything that moved, got renamed or got removed, and what replaced it. (libva-intel-driver moving from x11-libs to media-libs is the kind of thing this catches.)

Also check that the USE flags the scripts set on installkernel, systemd, systemd-utils and PipeWire still exist.

Things I dropped or flagged because of keywords, check if that's still true:

- KeePassXC and OBS Studio were ~amd64 only, so they're Flatpak only for now. If they go stable, offering them native again changes behaviour.
- The Broadcom wl driver is marked as a testing version in gentoo-helper.

## 5. Login shells

The list is bash, zsh, fish, Nushell, dash, ksh, mksh, loksh, yash and tcsh. Check each is still in app-shells with a stable amd64 version, and whether anything new in app-shells went stable. Check whether Nushell's package adds itself to /etc/shells yet, since the installer handles that by hand. If any shell changed its login file or syntax, retest the Sway autostart in it.

## 6. NVIDIA

- nvidia-drivers 595 and newer only support Turing and up. Maxwell, Pascal and Volta get pinned to the 580 branch with `>=x11-drivers/nvidia-drivers-581` masked. Check 580 is still in the tree, still stable, and not last-rited. If it's on its way out, that's a bigger problem than a monthly fix.
- Check whether a newer branch dropped another generation, which would mean a new cutoff.
- Kepler and older go to Nouveau. Still right?
- The licence is still NVIDIA-2025.
- gentoo-helper keeps its version blocks in /etc/portage/package.mask/zz-gentoo-helper, so make sure that still works with the current mask.

## 7. Boot and Macs

- GRUB's `--no-nvram` and bootctl's `--no-variables` still exist and still do the same thing.
- EFI/BOOT/BOOTX64.EFI is still the fallback path both use.

## 8. Live ISO

Check the specs in https://github.com/gentoo/releng:

- dialog still ships (it comes in via mirrorselect)
- /usr/share/zoneinfo and /usr/share/i18n are still emptied
- every tool the installer needs is still on the ISO

## 9. Other drift

- tzdata zone list vs BUILTIN_TIMEZONES (the built-in list is from 2026a, 312 zones, and 2026d matched it)
- Flathub app IDs in the catalog (27 at last check, all of them, not a sample)

## 10. Code pass

While I'm in there, read through for quality problems and bugs. Two I've already been bitten by:

- tab-separated reads collapse empty fields, so any `IFS=$'\t' read` against data that can have an empty field will shift columns
- the README's download commands. Copy and run them. The `hhttps://` typo sat there for a whole release.

## 11. Fix, build, test

Fix whatever is broken or outdated, then:

```
./build.sh
./build.sh --lint
./build.sh --check
```

Plus anything in tests/ if it exists.

Maintenance doesn't change defaults or behaviour. If one of those needs to change, that's its own decision, so write it down and think it through before touching it.

## 12. Release

- Bump the version in gentoo-install.sh, gentoo-install-tui.sh and gentoo-helper.sh together. They share one version number.
- CHANGELOG.md entry with Fixed, Changed, and a "Checked, no change needed" section, so next month I know what was actually verified.
- Update the tested-combinations table in the README. ADD rows, don't rewrite the table. The 1.2.0 README dropped the 2026-09-26 runs and I had to put them back in 1.3.0.
- Fix any README claims that aren't true anymore.
- Update the "Last review" and "Changes since" lines at the top of this file.

## Keeping notes

Sort findings by how bad they are: breaks installs, wrong but harmless, cosmetic. Keep track of what I actually checked, what I assumed, and what I couldn't check at all (site down, fetch blocked, whatever). Future me will want to know which is which.
