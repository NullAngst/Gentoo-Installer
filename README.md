# Gentoo Installer

A guided installer for Gentoo Linux on amd64, for people who want a working Gentoo system without typing the Handbook in by hand.

You boot the official Gentoo live image, download one script and answer its questions. It explains each option as it asks, then installs the whole system unattended, following the [Gentoo AMD64 Handbook](https://wiki.gentoo.org/wiki/Handbook:AMD64). Every command it runs is printed and logged, and every config file it writes is commented, so you can always see what it did and why.

There are two versions. They ask the same questions and run the same install:

- `gentoo-install-tui.sh` is the menu version: dialog boxes, plus a main menu where you can open, change or skip any section in any order.
- `gentoo-install.sh` is the console version: plain text questions, one after another. Use it when a terminal can't show dialog boxes, like a serial console or a tiny screen.

Every installed system also gets `gentoo-helper`, menus for everyday package management. More on that [further down](#gentoo-helper).

## Status

Version 1.3.0, see [CHANGELOG.md](CHANGELOG.md). I've installed three combinations end to end on QEMU/KVM virtual machines, and all three boot to a working desktop:

| Firmware | Bootloader | Init | Desktop | Root filesystem | Encryption | Installer | Machine | Result |
|---|---|---|---|---|---|---|---|---|
| BIOS | GRUB | systemd | KDE Plasma | ext4 | none | menu (TUI) | QEMU/KVM virtual machine | Installed, boots, network works (2026-09-25) |
| BIOS | GRUB | OpenRC | KDE Plasma | XFS | none | console (CLI) | QEMU/KVM virtual machine | Installed, boots, network works (2026-09-26) |
| UEFI | GRUB | OpenRC | MATE | Btrfs | none | menu (TUI) | QEMU/KVM virtual machine | Installed, boots, network works (2026-09-26) |
| UEFI | GRUB | systemd | KDE Plasma | Btrfs | none | menu (TUI) | 2013 Macbook Pro | Installed, boots, network works (2026-09-28) |

Everything else is untested: systemd-boot, LUKS encryption, the GNOME, Cinnamon, Xfce, LXQt, Sway and i3 desktops, manual partitioning, the login shell choice, and real hardware. My one real-hardware attempt, a 2013 MacBook Pro, turned up a Mac boot problem that 1.2.0 fixes (see [Intel Macs](#intel-macs)), but I haven't re-tested on the Mac since. `gentoo-helper` has only been tested in a sandbox against simulated Portage.

Both installers and the helper pass `bash -n` and ShellCheck, and their logic has been run in a sandbox against simulated Portage, service managers and `dialog`. That's not the same as a real install. I beg you to try it in a VM before you point it at a disk you care about (see [Testing in a virtual machine](#testing-in-a-virtual-machine)). If something fails, open an issue with the log.

## What you need

- An amd64 (x86_64) computer. UEFI is recommended; legacy BIOS works with GRUB.
- The official Gentoo live image, either the minimal installation ISO or the LiveGUI, from https://www.gentoo.org/downloads/. Other live systems might work, but I haven't tried them. The script checks for the tools it needs and stops if one is missing.
- A USB stick to boot it from, or a virtual machine.
- An internet connection. Wired is easiest.
- A disk you're fine wiping, or free partitions if you're dual booting. At least 40 GiB for a desktop (60 GiB or more is comfortable) and 20 GiB without one. The installer refuses anything smaller, since running out of space mid-build fails in confusing ways.
- Secure Boot turned off before you boot the installed system. Nothing is signed, so Gentoo won't start with it on.

## Installing

1. Download the minimal ISO (or the LiveGUI) from https://www.gentoo.org/downloads/.
2. Write it to a USB stick. I use Ventoy, so in my case I just copy the ISO onto the stick. It depends on your setup: `dd`, Fedora Media Writer, or whichever writer you prefer. With `dd`, check the stick's name with `lsblk` first, since dd overwrites whatever you point it at: `sudo dd if=install-amd64-minimal-*.iso of=/dev/sdX bs=4M status=progress oflag=sync`
3. Boot from the stick. If the firmware's boot menu lists a UEFI entry for it, pick that one, since UEFI is the better supported setup.

   3.5. On an Intel Mac, hold Option at power-on to get the boot menu. If only the legacy entry boots (Ventoy's EFI mode hangs on some Macs, it did on mine), go ahead anyway. The installer notices and installs for EFI, see [Intel Macs](#intel-macs).

4. Check that you're online: `ping -c 3 www.gentoo.org`. Wired usually just works. For Wi-Fi, run `net-setup` first, or `nmtui` or `iwctl`, whichever the live image has.
5. Download the menu version: `curl -fsSLO https://raw.githubusercontent.com/NullAngst/Gentoo-Installer/refs/heads/main/gentoo-install-tui.sh`. For the console version, use `gentoo-install.sh` in that URL instead.
6. Run it as root: `bash gentoo-install-tui.sh`. On the LiveGUI, open a terminal and run `sudo bash gentoo-install-tui.sh`.
7. Answer the questions. Enter accepts the recommended default, and each question explains its options before asking.
8. Read the summary. Nothing on the disk has changed yet, unless you edited partitions yourself in `cfdisk` along the way.
9. Type `ERASE` to install to the whole disk, or `FORMAT` if you set up the partitions yourself.

   TYPING ERASE WIPES EVERY PARTITION ON THE DISK YOU PICKED. Back up anything on it first, and double-check the disk name in the summary.

10. Wait. The long part runs unattended. How long it takes depends on your CPU and how much of the system comes from binary packages.
11. Reboot when it offers to, and pull the USB stick.
12. Log in as your user and read `~/GENTOO-POST-INSTALL-NOTES.txt`, since it's written for the choices you made.

Now Gentoo is installed and booting into the desktop you picked, and everything is working as it should be. From here, tinker as you see fit.

Piping the script straight into bash (`curl ... | bash`) won't work. Why? Because it reads your answers from the keyboard, and the pipe takes the keyboard away. Both scripts detect it and print the right commands. Each script is self-contained, so you only need the one you run.

Two options exist: `--resume` continues after a failed step (see [When a step fails](#when-a-step-fails)), and `--help` shows usage.

## What happens when you run it

1. It checks the live environment, helps you get online if you aren't, and sets the clock.
2. It detects the hardware: CPU model, thread count, RAM, x86-64-v3 support, UEFI or BIOS, Secure Boot, virtual machine, laptop, Wi-Fi, Bluetooth and graphics cards.
3. It asks everything in six parts, each with an explanation and a recommended default.
4. It shows a summary. You can start over, quit, or confirm. Nothing is written to the disk before this point, unless you edit partitions in `cfdisk` yourself.
5. It looks up the newest stage3 for your choices. This happens first, so a download problem stops it before anything on the disk changes.
6. It partitions and formats the disk, with LUKS2 encryption if you asked for it.
7. It downloads the stage3, checks its PGP signature from Gentoo Release Engineering and its SHA256 checksum, and unpacks it.
8. It writes a hardware-tuned `make.conf`, the binary package host config, `fstab`, the kernel command line and the dracut config.
9. It enters the new system (chroot) and runs 19 numbered steps: repository sync, profile, binary package keys, CPU flags, locale and timezone, `@world` update, system tools, firmware and microcode, basic configuration, bootloader, kernel, networking, user accounts, desktop, drivers, applications, services, a final bootloader check, and final touches.
10. It unmounts everything and offers to reboot.

## The menu version

`gentoo-install-tui.sh` uses `dialog`, which is on the official Gentoo live images (it comes with `mirrorselect`). If `dialog` is missing it falls back to `whiptail`, and if neither exists it tells you to use the console version.

After the welcome screen and the keyboard, network and hardware checks, you land on the main menu:

```
Guided setup: go through every section in order
1. System            [default]   KDE Plasma, systemd, binary packages: yes
2. Disk              [required]  not set yet
3. Region            [default]   gentoo, UTC, en_US.UTF-8
4. Accounts          [required]  not set yet
5. Drivers & network [default]   network: networkmanager, graphics: nvidia, SSH: no
6. Software          [default]   Flatpak: yes (0 apps), 0 native packages
Review all settings
Install Gentoo
Quit without installing
```

- `[default]` sections are already filled in with the recommended settings for your hardware, the same as pressing Enter through their questions. They keep following your other choices until you open them. Pick *No desktop* in *System*, for example, and the Flatpak default turns off while the SSH server default turns on. Once you open a section it shows `[done]` and keeps your answers.
- `[required]` sections (Disk and Accounts) have to be done before *Install* works. *Install* also checks the whole configuration for conflicts, like systemd-networkd together with OpenRC, and names the section to fix.
- Reopening a section starts from your previous answers.
- Esc or Cancel inside a section lets you continue, go back to the main menu and throw away that section's changes, or quit. The disk is untouched at that point.
- The timezone comes from a region menu and a city menu, so you don't have to type it.
- *Review all settings* shows the full summary in a scrollable box.
- *Install Gentoo* shows the summary, asks for a yes, then asks you to type `ERASE` (or `FORMAT` for manual partitioning).

Once the install starts, the menu version switches to plain scrolling text, the same output as the console version. Why no progress bar? Because nothing can honestly estimate a multi-hour build, and the emerge output is the real progress indicator. The last questions (unmount, reboot) are dialog boxes again.

Keys: arrows and Tab move, Space ticks a checkbox, Enter confirms, Esc goes back. With the `whiptail` fallback, long text boxes need Tab to reach the OK button before Enter works.

## What it asks

| Part | Questions |
|---|---|
| 1. System type | Desktop, graphical login screen, init system (OpenRC or systemd), binary packages, CPU instruction set tuning, kernel (prebuilt or compiled) |
| 2. Disk | Target disk, whole disk or manual partitions, filesystem (ext4, Btrfs, XFS), LUKS2 encryption, swap (zram, partition, none), bootloader (GRUB or systemd-boot) |
| 3. Region | Hostname, timezone (type `list` to browse), locale, console keymap, desktop keyboard layout |
| 4. Accounts | Root password, username, user password, login shell, sudo or doas |
| 5. Hardware and network | NVIDIA proprietary or Nouveau (only with an NVIDIA card), network manager, Bluetooth, printing, SSH server |
| 6. Software | Download mirror, Flatpak with a choice of Flathub apps, optional native packages |

Both versions ask exactly these; the menu version groups them into its six sections. Before any of them, it offers to switch the live keyboard layout, so you type your passwords on the layout you actually use.

Passwords are hashed (SHA-512 crypt) before anything touches the disk. The plain text never leaves the installer's memory, and the hashes are deleted from the saved settings file once the accounts exist.

## How it tunes the system to your hardware

It writes these settings into `/etc/portage/make.conf` (and `CPU_FLAGS_X86` into `/etc/portage/package.use/00cpu-flags`), each with a comment explaining it:

| Setting | Value | Why |
|---|---|---|
| `COMMON_FLAGS` | `-march=native -O2 -pipe` | Targets exactly this CPU. `-O2` is Gentoo's recommended system-wide level |
| `RUSTFLAGS` | `-C target-cpu=native` | The Rust equivalent, as the Handbook now describes |
| `MAKEOPTS` | `-jN -lT`, N = min(threads, RAM in GiB / 2), T = threads | The Handbook's rule of about 2 GiB of RAM per compile job, so big C++ builds don't run out of memory |
| `EMERGE_DEFAULT_OPTS` | `--jobs` from 1 to 3 (threads / 6 and RAM / 12, capped at 3), `--load-average=T` | Parallel package builds multiply memory use, so this stays conservative |
| `CPU_FLAGS_X86` | Detected with `cpuid2cpuflags` (optional) | Lets packages use your CPU's exact instruction set extensions |
| `VIDEO_CARDS` | From the PCI graphics devices: `intel`, `amdgpu radeonsi`, `nvidia` or `nouveau`, plus `vmware`, `virgl` or `qxl` in VMs | Pulls in the right Mesa and X drivers. Hybrid laptops get both |
| Binary package host | The x86-64-v3 repository if the CPU supports it, baseline x86-64 as fallback, PGP signatures required | Most of a desktop downloads instead of compiling |
| Firmware | `linux-firmware` on real hardware; Intel CPUs also get `intel-microcode` and `sof-firmware` | Wi-Fi, GPU and audio firmware plus CPU microcode. Skipped in VMs |
| VM guest tools | QEMU guest agent and SPICE agent, open-vm-tools, or VirtualBox guest additions | Detected from DMI data |
| SSD | Weekly TRIM (a cron job on OpenRC, `fstrim.timer` on systemd) | Only when the target disk is an SSD |
| `L10N` | Your language, when the locale isn't `en_US` | Translations for packages that ship them |

## Disk layouts

Whole disk mode always uses a GPT partition table:

| # | Size | Contents | When |
|---|---|---|---|
| 1 | 1 GiB | EFI system partition, FAT32, mounted at `/efi` | UEFI |
| 1 | 1 MiB | BIOS boot partition (GRUB's core image, no filesystem) | BIOS |
| 2 | 1 GiB | `/boot`, ext4 | GRUB with LUKS, or GRUB with XFS |
| 3 | your choice | swap | Swap partition picked (not offered with encryption) |
| last | rest of the disk | root filesystem, inside LUKS2 if encrypted | Always |

With Btrfs, the root partition holds two subvolumes: `@` mounted at `/` and `@home` mounted at `/home`, both with `noatime,compress=zstd:1`.

Why a separate `/boot` for those two cases? Because GRUB can't boot from a LUKS2 root created with default settings, and it can fail to read XFS made with the newest `mkfs.xfs` defaults. systemd-boot keeps kernels on the EFI partition, so it never needs one.

Manual mode is for dual boot or custom layouts. The installer can open `cfdisk` for you, then asks which partition is the EFI partition, `/boot` (when needed), root and swap. An existing EFI partition, like Windows', can be kept without formatting, and `os-prober` is turned on so GRUB lists the other system. The installer doesn't resize partitions. To make room next to Windows, shrink its partition from inside Windows first.

## Intel Macs

I found this one on my 2013 MacBook Pro. Ventoy only booted in legacy BIOS mode there, the install finished fine, and then the Mac showed a flashing folder on reboot.

Why? Because Macs pick legacy or EFI boot from the partition table. They only boot a BIOS-mode install from a disk with an MBR partition table, and this installer uses GPT, so the Mac looked for an EFI bootloader and found none.

Since 1.2.0, the installer spots a Mac that started the live system in BIOS mode, explains this, and recommends installing for EFI anyway. The bootloader then goes to the fallback path `EFI/BOOT/BOOTX64.EFI`, which the Mac finds on its own. If it doesn't, hold Option at power-on and pick "EFI Boot". Macs from 2006 and 2007 have 32-bit EFI, which neither route can boot, so the installer stops on those before touching the disk.

I haven't re-tested this on the Mac yet.

## Login shells

Part 4 asks which login shell your user gets. The choices are the interactive login shells in Gentoo's `app-shells` category with a stable amd64 version:

| Choice | Package | Notes |
|---|---|---|
| bash | `app-shells/bash` | Default, and what nearly every guide assumes |
| zsh | `app-shells/zsh`, `app-shells/gentoo-zsh-completions` | Gets a starter `~/.zshrc` (history, completion, the Gentoo prompt), which also skips zsh's first-run setup wizard |
| fish | `app-shells/fish` | Not POSIX. Written in Rust |
| Nushell | `app-shells/nushell` | Not POSIX. Written in Rust. Added to `/etc/shells`, which doesn't list it by default |
| sh: dash | `app-shells/dash` | Minimal POSIX sh. No command history or line editing |
| ksh | `app-shells/ksh` | The AT&T Korn shell |
| mksh | `app-shells/mksh` | The MirBSD Korn shell |
| loksh | `app-shells/loksh` | The OpenBSD Korn shell; installs as `ksh` |
| yash | `app-shells/yash` | Strict POSIX, with line editing |
| tcsh | `app-shells/tcsh` | C shell syntax |

- Only your user gets the chosen shell. root keeps bash so recovery always works, and `/bin/sh` stays bash so system scripts aren't affected.
- The shell installs as an optional package. If it fails to build, your user keeps bash, the failure shows up at the end of the install and in the post-install notes, and you can switch later with `chsh -s <path>`.
- fish and Nushell don't read `/etc/profile`, so environment settings Gentoo packages put there (extra PATH entries, for example) are missing in their login sessions unless you add them to the shell's own config. Both compile from source if the binary package server doesn't have them, which takes a while.
- With Sway, the start-on-tty1 snippet goes into the login file of the shell you actually end up with: `~/.bash_profile`, `~/.zprofile`, `~/.profile` (dash, ksh, mksh, loksh), `~/.yash_profile`, `~/.login` (tcsh) or `~/.config/fish/conf.d/sway-autostart.fish`. Nushell gets no autostart; type `sway` after logging in.
- Left out on purpose: PowerShell (`pwsh`), `posh` (a strict POSIX shell meant for testing scripts), `sash` (a static rescue shell), and anything without a stable amd64 version.

## Desktops and what gets installed

| Choice | Main packages | Login |
|---|---|---|
| KDE Plasma | `plasma-meta`, Konsole, Dolphin, Kate, Ark, Okular, Gwenview | SDDM |
| GNOME | `gnome-base/gnome` | GDM |
| Cinnamon | `cinnamon`, GNOME Terminal, Xorg | LightDM |
| Xfce | `xfce4-meta`, xfce4-terminal, PulseAudio panel plugin, Xorg | LightDM |
| MATE | `mate`, MATE Terminal, Xorg | LightDM |
| LXQt | `lxqt-meta`, QTerminal, Xorg | SDDM |
| Sway | Sway, foot, wofi, mako, grim, slurp, `xdg-desktop-portal-wlr` | Starts on tty1 after login (optional) |
| i3 | i3, i3status, i3lock, dmenu, Alacritty, Xorg | LightDM |
| No desktop | Console only | Text login |

Every desktop also gets PipeWire with WirePlumber, Noto fonts including emoji, and `xdg-user-dirs`. On systemd, PipeWire runs as global user services. On OpenRC, full desktops start it through XDG autostart, and the installer adds `gentoo-pipewire-launcher` to the Sway and i3 configs it copies into your home directory.

The profile follows the desktop: `desktop/plasma`, `desktop/gnome`, `desktop` or the base profile, each with `/systemd` on the end when you pick systemd.

## When a step fails

The logs:

- Live side: `/tmp/gentoo-install.log`
- Inside the new system: `/var/log/gentoo-install.log`, plus a copy of the live log at `/var/log/gentoo-install-live.log` after a successful install.

Every step inside the new system is recorded as it finishes. When one fails, the installer prints the failing command, the step number and where the log is, then stops. If a package build failed, you also get a *Why it failed* block: the path to that package's build log, its first error lines, its last lines, and the free disk space. If the build log just stops mid-line with no error, it says so. That almost always means the disk filled up or the filesystem went read-only.

Before each step it also checks free space against a rough minimum for that step. If space is short, it deletes Portage's download caches and leftover build directories first, and if that's still not enough, it stops with a clear message instead of dying halfway through a build.

To continue after a failure:

1. Read the end of the log.
2. Fix the cause. If it's inside the new system, run `chroot /mnt/gentoo /bin/bash`, then `source /etc/profile`, fix it, and `exit`.
3. Run the same script again with `--resume`: `bash gentoo-install-tui.sh --resume` (or `gentoo-install.sh`).

Finished steps are skipped. If you rebooted the live system in between, `--resume` asks for the root partition (and the passphrase if it's encrypted), mounts it, and reads the saved settings from `/root/gentoo-install.conf` on it.

Resuming covers failures inside the new system, which is where nearly all the time and risk is. If something fails earlier (partitioning, downloading or unpacking the stage3), start over from the beginning.

Optional software works differently. If a native package, Flatpak app, Bluetooth tool, VM agent or your chosen login shell fails, the installer retries it on its own, then skips it and lists it at the end and in the post-install notes. The core system (base, kernel, bootloader, desktop, accounts) stops on errors so you can fix them and resume.

## After installing

Log in as your user. The post-install notes are saved as `~/GENTOO-POST-INSTALL-NOTES.txt` and `/root/GENTOO-POST-INSTALL-NOTES.txt`, written for your choices. The short version:

```sh
emaint sync -a           # update the package repository
emerge -avuDN @world     # update the system
emerge -a --depclean     # remove packages nothing needs anymore
eselect news read        # read Gentoo news; required manual steps are announced here
dispatch-conf            # merge updated configuration files
eclean-kernel -n 3       # after depclean: keep only the three newest kernels
```

Or skip all of that and use `gentoo-helper`. With NetworkManager, connect to Wi-Fi from the desktop or with `nmtui`.

To move the disk to another computer, change three things first, since the system is built for this CPU and this hardware:

1. In `/etc/portage/make.conf`, change `-march=native` in `COMMON_FLAGS` to a generic value like `-march=x86-64-v2`, and change `-C target-cpu=native` in `RUSTFLAGS` to `-C target-cpu=x86-64-v2`.
2. Rebuild everything with the new flags: `emerge -e @world`
3. In `/etc/dracut.conf.d/10-gentoo-install.conf`, change `hostonly="yes"` to `hostonly="no"`.
4. Rebuild the initramfs: `emerge --config sys-kernel/gentoo-kernel-bin` (or `sys-kernel/gentoo-kernel` if you picked the compiled kernel).

## gentoo-helper

Gentoo's package manager, `emerge`, is powerful and not beginner friendly. `gentoo-helper` puts the everyday jobs behind simple menus. Every action shows what's about to happen in plain words and asks before it changes anything.

```
gentoo-helper                  menus
gentoo-helper update           update the whole system
gentoo-helper install NAME     find and install a package
gentoo-helper remove NAME      remove a package
gentoo-helper clean            remove unneeded packages, free disk space
gentoo-helper news             read Gentoo news
gentoo-helper configs          review configuration file updates
gentoo-helper flatpak          Flatpak apps
gentoo-helper tasks            common tasks: printing, Wi-Fi, drivers, codecs, SSH, ...
```

The installer puts it in `/usr/local/bin/gentoo-helper`. For a system installed before it existed, or installed some other way:

1. Download it: `curl -fsSLO https://raw.githubusercontent.com/NullAngst/Gentoo-Installer/refs/heads/main/gentoo-helper.sh`
2. Install it: `sudo install -m 755 gentoo-helper.sh /usr/local/bin/gentoo-helper`

It asks for your password through `sudo` or `doas` when it needs to. It uses `dialog` menus, offers to install `dialog` if it's missing, and falls back to plain text menus otherwise.

What it covers:

- Updating the whole system. It syncs the package list, offers to show unread Gentoo news, and tells you how many updates are ready-made and how many will compile. After you say yes, it installs them, rebuilds Perl modules if Perl was upgraded, rebuilds programs still using replaced libraries, offers to remove packages nothing needs, walks you through config file updates, updates Flatpak apps, and tells you when a new kernel needs a restart.
- Finding and installing. Search by name or description, see what's already installed, then install the recommended way (ready-made when available, compiled otherwise), ready-made only, or compiled on your machine.
- Settings Portage asks for. When a package needs a USE flag, a license, or a testing version allowed first, the helper explains the change and offers to save it. It only writes to files named `zz-gentoo-helper` under `/etc/portage/`, which you can review, edit or remove from the Maintenance menu. Testing (`~amd64`) versions default to no. Masked packages are never unmasked.
- Removing. It lists the packages you chose to install, removes one only if nothing else needs it, and warns loudly before removing anything that looks essential (kernel, bootloader, drivers, network, login screen, desktop).
- Maintenance. Remove unneeded packages, free disk space (old downloads and failed build leftovers), remove old kernels (keeping the 3 newest), review config updates, read news, rebuild after library or Perl upgrades, and view or undo the settings it saved.
- Common tasks. Guided setup for hardware and features. Each task shows what it found (hardware present, packages installed, services running), lets you tick what to install, then enables the right services for OpenRC or systemd, adds your user to the groups the feature needs, and tells you what to do next:
  - Printing: CUPS, network printer discovery (Avahi), Gutenprint and HP drivers, KDE's printer settings page.
  - Scanners: SANE, driverless scanning (sane-airscan), a scanning app, HP scanner drivers.
  - Wi-Fi: lists the adapters and the driver each one uses, installs firmware, the regulatory database and NetworkManager (offering to switch over from dhcpcd or systemd-networkd), unblocks a soft-blocked radio, and offers the proprietary Broadcom driver when there's a Broadcom card.
  - Bluetooth: BlueZ, the right settings panel or applet for your desktop, and a PipeWire rebuild with Bluetooth support for headphones and speakers when needed.
  - Graphics drivers: shows each GPU and the driver in use. For NVIDIA it installs the proprietary driver, adds it to `VIDEO_CARDS` (backing up `make.conf`), makes sure kernel mode setting is on, and rebuilds the initramfs. For Intel it offers the video decoding drivers. AMD needs nothing extra.
  - Audio and video codecs: FFmpeg and the GStreamer codec plugins, with DVD decryption as an opt-in.
  - SSH server: installs and starts it, shows the address to connect to, opens the firewall if one is on, and can turn it off again.
  - Firewall: ufw blocking unsolicited incoming connections, keeping SSH reachable if the server runs.
  - Fonts, archive formats, virtual machines (virt-manager with QEMU/KVM), and Steam (as a Flatpak).
- Flatpak. Search Flathub, install, remove and update apps, and clean out unused runtimes.
- Failures. It saves a plain report of the actual error from the package's build log to `/var/log/gentoo-helper-last-failure.txt`. Everything it runs goes to `/var/log/gentoo-helper.log`.

Config file updates, in more detail: Portage only holds back a new config file when the current one was changed, by you or by the installer. The helper shows the differences and lets you keep yours, take the new one (your old file is kept as a `.bak-` copy), or decide later. For files the installer customised, it recommends keeping yours.

The riskiest common task is the NVIDIA driver, since the wrong driver branch can leave you with a black screen. The helper picks the branch from the card's generation (see [Limitations](#limitations)) and tells you how to recover if the screen stays black anyway.

What it doesn't do: anything past everyday jobs still needs `emerge` directly. It only touches USE flags when Portage asks for a change, and it doesn't manage overlays. Builds use `--quiet-build`, so compiler output goes to the build logs instead of the screen. It's been tested against simulated Portage output and the real `dialog` program. It hasn't run on a real system yet, so report anything that looks off.

## Why it works this way

Why ask everything up front? So you can walk away during the long part. The cost is committing to all your answers at once, which is why the summary screen and the option to change your answers exist.

Why binary packages on by default, with almost no global USE flags? Because Gentoo's binary host only helps when a package's USE flags match yours, so `make.conf` only adds `dist-kernel` globally. The binaries are built for generic x86-64 or x86-64-v3, so they don't get `-march=native`. That's a fair complaint. But everything compiled locally still gets `-march=native`, and downloading most of a desktop saves hours of compiling. Changing USE flags later is normal Gentoo; just expect more local compiling when you do.

Why systemd by default for Plasma and GNOME? Because Gentoo's announcement of the binary host listed its desktop packages as built for the Plasma/systemd and GNOME/systemd profiles. OpenRC works too, but will probably compile more.

Why ask about CPU_FLAGS_X86 detection? Because it's a real trade-off. With detection on (the default), packages that use those flags, mostly codecs, crypto and maths libraries, compile locally whenever your CPU's set differs from what the binaries were built with. So the installer explains that and lets you pick.

Why the distribution kernel? `gentoo-kernel-bin` by default. It supports nearly all hardware, updates with the rest of the system, and rebuilds external modules like `nvidia-drivers` automatically. There's no option for a hand-configured kernel; switch to `gentoo-sources` later if you want one. If you pick the compiled `gentoo-kernel`, note that it doesn't use your `-march=native` CFLAGS, since the kernel build uses its own flags.

Why a host-only initramfs? Because it only carries drivers for this machine, which keeps it small. The cost is that moving the disk to other hardware needs a change (see [After installing](#after-installing)). The kernel command line is also embedded in the initramfs, which installkernel requires inside a chroot and which keeps the system bootable if the bootloader config gets lost.

Why zram swap by default? It's compressed swap in RAM, sized like Fedora's default: equal to RAM, capped at 8 GiB. It's fast and uses no disk. It can't hibernate.

Why GRUB by default? It handles every combination the installer offers, plus dual boot detection. systemd-boot is offered on UEFI and is simpler, but it keeps kernels on the EFI partition, so that partition needs room (the automatic layout gives it 1 GiB).

Why quiet builds? Because streaming thousands of long compiler lines to a slow virtual machine console made builds die mid-way without an error message. So every build runs with Portage's `--quiet-build`: compiler output goes to each package's build log, and you see one line per package. When a build fails, the useful part of its log is shown automatically. Your own `emerge` runs after installing aren't affected.

Why rebuild Perl modules after the base update? Because that update can bring a new Perl, and modules built for the old one stop loading. That breaks later builds in confusing ways: GRUB fails while generating its manual pages, because `help2man` can't load `Locale::gettext`. The installer runs `perl-cleaner --all` right after the update, which does nothing when no module needs rebuilding.

Why delete download caches along the way? Because Portage keeps every downloaded binary package and source archive by default, and on a small disk that adds up fast. The installer clears the binary packages after the base system update and after the desktop, and all download caches at the end. They're only caches; reinstalling a package later just downloads it again.

Why such conservative licenses? So nothing with a restrictive license goes on your system without a line in a file saying so. `make.conf` sets `ACCEPT_LICENSE="-* @FREE @BINARY-REDISTRIBUTABLE"`, with explicit exceptions only for firmware, Intel microcode, the NVIDIA driver and Google Chrome when you pick them. Other proprietary packages you install later need their own `package.license` entry, and emerge tells you which.

Why one engine with two front ends? So a fix to a question or to the install reaches both scripts at once. The menu version doesn't reimplement the questions. It swaps the handful of prompt functions (choose, ask, yes/no, password, checklist) for dialog versions, and everything else, including the chroot stage, is shared code. The cost is a build step for anyone changing it (see [Building from source](#building-from-source)). To let *Back to the main menu* discard a section, each section runs in a subshell and hands its answers back through a private (mode 600) temporary file in the live system's RAM-backed `/tmp`, deleted immediately. For the Accounts and Disk sections, that file briefly holds the passwords you typed.

Why can you continue without a signature check? If the stage3's PGP signature can't be checked because gpg or Gentoo's key is missing from the live system, the installer says so and asks whether to continue with only the SHA256 checksum and HTTPS. The default is yes, so an unusual live environment doesn't stop the install. A signature that's present and bad always aborts. The official live images have gpg and the key, so this shouldn't come up there.

## Limitations

- No Secure Boot. Nothing is signed. Turn Secure Boot off in the firmware, or set up signing yourself afterwards (Gentoo wiki: *Secure Boot*).
- amd64 only. 32-bit UEFI firmware is refused; boot the live image in BIOS/CSM mode on those machines. Intel Macs are covered in [Intel Macs](#intel-macs).
- No LVM, RAID, ZFS or multi-disk root, and no separate `/home` partition (Btrfs gets an `@home` subvolume).
- No hibernation, with any swap choice.
- Encryption covers the root filesystem only. With GRUB, `/boot` is a separate unencrypted partition; with systemd-boot, kernels sit on the unencrypted EFI partition. Either way, someone with physical access could read or tamper with the kernel and initramfs. There's no TPM unlock or keyfile support. The boot-time passphrase prompt may use the US layout, so the installer advises a passphrase that types the same on US and your layout.
- No Hyprland. The Gentoo wiki currently recommends installing it from a dedicated overlay, so add it after installing.
- Older NVIDIA cards need an older driver. `nvidia-drivers` 595 and newer only support Turing (GeForce GTX 16xx / RTX 20xx) and newer. For Maxwell, Pascal and Volta cards (GTX 750, 900 and 10xx series, Titan V), the installer and `gentoo-helper` keep the driver on the 580 branch, the last one supporting them, by masking `>=x11-drivers/nvidia-drivers-581`. Kepler and older cards get the open source Nouveau driver, because NVIDIA dropped them and Gentoo masks their old driver branches. The card generation comes from its PCI device ID, which is a heuristic, but `nvidia-drivers` checks the card again when it installs and warns if it needs a different branch.
- GNOME on OpenRC works through elogind, but GNOME is developed against systemd and some settings panels may be limited. The installer recommends systemd when you pick GNOME.
- The dhcpcd and systemd-networkd options only set up wired networking. Pick NetworkManager for Wi-Fi.
- The timezone list is built in. The minimal ISO ships an empty `/usr/share/zoneinfo`, so the installer carries its own list of zone names (tzdata 2026a). A zone added to tzdata later isn't in it, but you can still type it and confirm, and the new system's own timezone database checks it during the install (falling back to UTC with a warning if it doesn't exist). On the LiveGUI, which has the full database, that gets used instead.
- Package names in the optional lists can go stale as Gentoo moves packages around. A missing one is skipped and reported, and the install carries on.
- Not portable between machines without the changes in [After installing](#after-installing), because of `-march=native` and the host-only initramfs.
- The menu version switches to plain text during the install itself (see [The menu version](#the-menu-version)).
- A mirror picked with `mirrorselect` is used for the stage3 and source downloads. Binary packages always come from Gentoo's own CDN (`distfiles.gentoo.org`).

## Testing in a virtual machine

Test both firmware types before trusting it on real hardware. I test with QEMU/KVM on openSUSE, so in my case the UEFI firmware is at `/usr/share/qemu/ovmf-x86_64-code.bin`. It depends on your distribution: `/usr/share/OVMF/OVMF_CODE_4M.fd` on Debian and Ubuntu, `/usr/share/edk2/ovmf/OVMF_CODE.fd` on Fedora. Adjust the paths below to match.

1. Create a disk image: `qemu-img create -f qcow2 gentoo-test.qcow2 60G`
2. Copy the matching UEFI variables file, since it has to be writable: `cp /usr/share/qemu/ovmf-x86_64-vars.bin ./ovmf-vars.bin`
3. Start the VM:

   ```sh
   qemu-system-x86_64 -enable-kvm -cpu host -smp 4 -m 8G \
     -drive if=pflash,format=raw,readonly=on,file=/usr/share/qemu/ovmf-x86_64-code.bin \
     -drive if=pflash,format=raw,file=./ovmf-vars.bin \
     -drive file=gentoo-test.qcow2,if=virtio \
     -cdrom install-amd64-minimal-*.iso -boot d \
     -nic user,model=virtio-net-pci
   ```

   3.5. For legacy BIOS, run the same command without the two `pflash` lines, and QEMU uses its default SeaBIOS.

4. Follow [Installing](#installing) from step 4.

virt-manager is easier if you prefer a GUI: before starting the install, open *Customize configuration*, set the firmware to UEFI (or leave it on BIOS), and use a VirtIO disk. GNOME Boxes or whichever VM tool you use works too, as long as you can pick the firmware.

In a VM, the installer detects the hypervisor, skips firmware and microcode, and installs the matching guest tools. With `-cpu host`, `-march=native` targets your host's CPU, so a disk image built this way may not boot on a VM with a different CPU model.

## Files the installer creates

On the new system (paths relative to its root):

| Path | Purpose |
|---|---|
| `/etc/portage/make.conf` | Tuned build settings; the original is kept as `make.conf.stage3-original` |
| `/etc/portage/binrepos.conf/gentoobinhost.conf` | Binary package sources (when enabled) |
| `/etc/portage/package.use/` | `installkernel`, `00cpu-flags`, `luks`, `flatpak` |
| `/etc/portage/package.license/gentoo-install` | Per-package license exceptions |
| `/etc/portage/package.mask/gentoo-install` | Keeps Maxwell, Pascal and Volta NVIDIA cards on the 580 driver branch (only for those cards) |
| `/etc/fstab` | Mounts by UUID |
| `/etc/kernel/cmdline`, `/etc/dracut.conf.d/10-gentoo-install.conf` | Kernel command line and initramfs settings |
| `/etc/sudoers.d/10-wheel` or `/etc/doas.conf` | Administrator access for the `wheel` group |
| `/etc/shells` (one added line, if needed) and `~/.zshrc` (zsh only) | Your login shell, see [Login shells](#login-shells) |
| `/usr/local/sbin/zram-swap` and its OpenRC `local.d` hooks or systemd unit | zram swap |
| `/etc/cron.weekly/fstrim` | SSD TRIM on OpenRC |
| `/usr/local/sbin/install-my-flatpaks` | Re-runs the Flathub setup and your app selection |
| `/root/gentoo-install.sh`, `/root/gentoo-install.conf`, `/root/.gentoo-install-progress` | The installer that was used (either version is saved under this name), your saved answers (password hashes removed after use) and step progress, kept for `--resume` and for reference. Safe to delete once the system boots |
| `~/GENTOO-POST-INSTALL-NOTES.txt` | Next steps, written for your choices |
| `/usr/local/bin/gentoo-helper` | Menus for everyday package management |

## Building from source

The two installers are single files so each one downloads with one `curl` command, but they're generated from shared sources:

```
src/10-core.sh        constants, output and prompt helpers, validators
src/20-detect.sh      live system checks, network, clock, hardware detection
src/30-questions.sh   every question, the summary, derived settings
src/40-install.sh     partitioning, stage3, configuration files, resume
src/50-chroot.sh      the 19 steps that run inside the new system
src/60-tui.sh         dialog/whiptail front end and the main menu (menu version only)
src/90-main-cli.sh    entry point of gentoo-install.sh
src/91-main-tui.sh    entry point of gentoo-install-tui.sh
gentoo-helper.sh      the package management helper (standalone; also embedded in both installers)
build.sh              builds the two installers from src/ and gentoo-helper.sh
```

Don't edit `gentoo-install.sh` or `gentoo-install-tui.sh` directly, since the next build overwrites them. To change anything:

1. Edit the files in `src/`, or `gentoo-helper.sh`.
2. Rebuild both installers: `./build.sh`
3. Run ShellCheck on them: `./build.sh --lint`
4. Commit the rebuilt installers together with your source change.

`./build.sh --check` fails if the committed installers don't match `src/`, which makes it a good CI job. The one ShellCheck exception is explained in `build.sh`: the menu version replaces the console prompt functions with wrappers, and ShellCheck can't see that the originals are still called through copies made at load time.

## License

GPL-3.0. See [LICENSE](LICENSE).
