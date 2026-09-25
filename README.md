# Gentoo Installer

A guided, verbose installer for Gentoo Linux on amd64 (x86_64). You boot the official Gentoo live image, download one script, and answer its questions. It explains every option as it asks, then installs a complete system unattended, following the official [Gentoo AMD64 Handbook](https://wiki.gentoo.org/wiki/Handbook:AMD64).

It comes in two versions that ask the same questions and run the same installation:

| Script | Interface |
|---|---|
| `gentoo-install-tui.sh` | Menu version: dialog boxes and a main menu where you can open, change or skip any section in any order. |
| `gentoo-install.sh` | Console version: plain text questions, one after another. Useful when a terminal cannot show dialog boxes (serial console, very small screen). |

It is meant for people who want a Gentoo system without typing the Handbook in by hand, and who still want to see what is happening and why. Every command it runs is printed and logged, and every configuration file it writes is commented.

---

## Contents

- [What it does](#what-it-does)
- [The menu version](#the-menu-version)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [What you are asked](#what-you-are-asked)
- [How it tunes the system to your hardware](#how-it-tunes-the-system-to-your-hardware)
- [Disk layouts](#disk-layouts)
- [Desktops and what gets installed](#desktops-and-what-gets-installed)
- [If something fails: logs and resuming](#if-something-fails-logs-and-resuming)
- [After installing](#after-installing)
- [Design decisions and trade-offs](#design-decisions-and-trade-offs)
- [Limitations](#limitations)
- [Testing in a virtual machine](#testing-in-a-virtual-machine)
- [Files the installer creates](#files-the-installer-creates)
- [Repository layout and building](#repository-layout-and-building)

---

## What it does

1. Checks the live environment, helps you get online (wired, `net-setup`, `nmtui` or `iwctl`, whichever the live image has), and sets the clock.
2. Detects the hardware: CPU model, thread count, RAM, x86-64-v3 support, UEFI or BIOS, Secure Boot, virtual machine, laptop, Wi-Fi, Bluetooth and graphics cards.
3. Asks all of its questions in six parts, each with an explanation and a recommended default. Pressing Enter accepts the default.
4. Shows a summary. You can start over, quit, or confirm by typing `ERASE` (whole disk) or `FORMAT` (manual partitions). **The installer changes nothing on disk before this point.** The one exception is your own doing: in manual mode you can edit partitions in `cfdisk` while answering.
5. Partitions and formats, optionally with LUKS2 encryption.
6. Downloads the newest stage3, checks its PGP signature from Gentoo Release Engineering and its SHA256 checksum, and unpacks it.
7. Writes a hardware-tuned `make.conf`, the binary package host configuration, `fstab`, the kernel command line and the dracut configuration.
8. Enters the new system (chroot) and runs 19 numbered steps: repository sync, profile, binary package keys, CPU flags, locale and timezone, `@world` update, system tools, firmware and microcode, basic configuration, bootloader, kernel, networking, user accounts, desktop, drivers, applications, services, final bootloader check, and final touches.
9. Unmounts and offers to reboot.

## Requirements

- An amd64 (x86_64) computer. UEFI is recommended; legacy BIOS works with GRUB.
- The official Gentoo live image: the [minimal installation CD or the LiveGUI](https://www.gentoo.org/downloads/). Other live systems may work but are untested; the script checks for the tools it needs and stops if one is missing.
- An internet connection.
- At least 20 GiB of disk. 40 GiB or more is strongly recommended for a desktop.
- Secure Boot turned off in the firmware before you boot the installed system (see [Limitations](#limitations)).

## Quick start

Boot the live image, then as root.

Menu version:

```sh
curl -fsSLO https://raw.githubusercontent.com/NullAngst/Gentoo-Installer/refs/heads/main/gentoo-install-tui.sh
bash gentoo-install-tui.sh
```

Console version:

```sh
curl -fsSLO https://raw.githubusercontent.com/NullAngst/Gentoo-Installer/refs/heads/main/gentoo-install.sh
bash gentoo-install.sh
```

On the LiveGUI image, open a terminal and prefix the second command with `sudo`.

Download first, then run. Piping a script straight into bash (`curl ... | bash`) does not work, because it reads your answers from the keyboard; both scripts detect this and print the right commands. Each script is self-contained, so you only need the one you run.

Options:

| Option | Purpose |
|---|---|
| *(none)* | Start a new installation |
| `--resume` | Continue after fixing whatever made a step fail |
| `--help` | Show usage |

## The menu version

`gentoo-install-tui.sh` uses `dialog`, which is on the official Gentoo live images (it comes with `mirrorselect`). If `dialog` is missing it falls back to `whiptail`, and if neither exists it tells you to use the console version.

After the welcome screen, the keyboard, network and hardware checks, you land on the main menu:

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

- **[default]** sections are already filled in with the recommended settings for your hardware, exactly what you would get by pressing Enter through their questions. They keep following your other choices until you open them: for example, choosing *No desktop* in *System* turns the Flatpak default off and the SSH server default on. Once you open a section it shows **[done]** and keeps your answers.
- **[required]** sections (Disk and Accounts) must be done before *Install* is allowed. *Install* also checks the whole configuration for conflicts, such as systemd-networkd selected together with OpenRC, and names the section to fix.
- Reopening a section starts from your previous answers.
- **Esc or Cancel** inside a section offers: continue, go back to the main menu and discard the changes made in that section, or quit. Nothing on disk has been changed at that point.
- The timezone is picked from a region menu and a city menu instead of typed.
- *Review all settings* shows the full summary in a scrollable box.
- *Install Gentoo* shows the summary, asks for a yes, then asks you to type `ERASE` (or `FORMAT` for manual partitioning).

Once the installation starts, the menu version switches to plain scrolling text, the same output as the console version. Emerge output is the useful progress indicator for a multi-hour build, and a progress bar could not estimate it honestly. The final questions (unmount, reboot) are dialog boxes again.

Keys: arrow keys and Tab move, Space ticks a checkbox, Enter confirms, Esc goes back. With the `whiptail` fallback, long scrollable text boxes need Tab to reach the OK button before Enter.

## What you are asked

| Part | Questions |
|---|---|
| 1. System type | Desktop environment, graphical login screen, init system (OpenRC or systemd), binary packages, CPU instruction set tuning, kernel (prebuilt or compiled) |
| 2. Disk | Target disk, whole-disk or manual partitioning, filesystem (ext4, Btrfs, XFS), LUKS2 encryption, swap (zram, partition, none), bootloader (GRUB or systemd-boot) |
| 3. Region | Hostname, timezone (type `list` to browse), locale, console keymap, desktop keyboard layout |
| 4. Accounts | Root password, username, user password, sudo or doas |
| 5. Hardware and network | NVIDIA proprietary or Nouveau (only when an NVIDIA card is present), network manager, Bluetooth, printing, SSH server |
| 6. Software | Download mirror, Flatpak with a choice of Flathub apps, optional native packages |

Both versions ask exactly these questions; the menu version groups them into the six main menu sections.

Before those, it offers to switch the live keyboard layout, so that passwords are typed on the layout you actually use.

Passwords are hashed (SHA-512 crypt) before anything is written to disk. The plain text never leaves the installer's memory, and the hashes are removed from the saved settings file once the accounts exist.

## How it tunes the system to your hardware

| Setting | Value | Why |
|---|---|---|
| `COMMON_FLAGS` | `-march=native -O2 -pipe` | Targets exactly this CPU. `-O2` is Gentoo's recommended system-wide level. |
| `RUSTFLAGS` | `-C target-cpu=native` | The Rust equivalent, as the Handbook now describes. |
| `MAKEOPTS` | `-jN -lT` with N = min(threads, RAM in GiB / 2) and T = threads | The Handbook's rule of about 2 GiB of RAM per compile job, so large C++ builds do not run out of memory. |
| `EMERGE_DEFAULT_OPTS` | `--jobs` from 1 to 3 (threads / 6 and RAM / 12, capped at 3), `--load-average=T` | Parallel package builds multiply memory use, so this is kept conservative. |
| `CPU_FLAGS_X86` | Detected with `cpuid2cpuflags` (optional) | Lets packages use the CPU's exact instruction set extensions. |
| `VIDEO_CARDS` | From the PCI graphics devices: `intel`, `amdgpu radeonsi`, `nvidia` or `nouveau`, and `vmware`, `virgl` or `qxl` in VMs | Pulls in the right Mesa and X drivers. Hybrid laptops get both. |
| Binary package host | x86-64-v3 repository (if the CPU supports it) with baseline x86-64 as fallback, PGP signature required | Most of a desktop can be downloaded instead of compiled. |
| Firmware | `linux-firmware` on real hardware; Intel CPUs also get `intel-microcode` and `sof-firmware` | Wi-Fi, GPU and audio firmware plus CPU microcode. Skipped in VMs. |
| VM guest tools | QEMU guest agent and SPICE agent, open-vm-tools, or VirtualBox guest additions | Detected from DMI data. |
| SSD | Weekly TRIM (cron job on OpenRC, `fstrim.timer` on systemd) | Only when the target disk is non-rotational. |
| `L10N` | Your language, when the locale is not `en_US` | Translations for packages that ship them. |

The generated `/etc/portage/make.conf` explains each of these in comments.

## Disk layouts

**Whole disk (automatic)** always uses a GPT partition table:

| # | Size | Contents | When |
|---|---|---|---|
| 1 | 1 GiB | EFI system partition, FAT32, mounted at `/efi` | UEFI |
| 1 | 1 MiB | BIOS boot partition (GRUB's core image, no filesystem) | BIOS |
| 2 | 1 GiB | `/boot`, ext4 | GRUB with LUKS, or GRUB with XFS |
| 3 | your choice | swap | Swap partition selected (not offered with encryption) |
| last | rest of disk | root filesystem, optionally inside LUKS2 | Always |

With Btrfs, the root partition holds subvolumes `@` (mounted at `/`) and `@home` (mounted at `/home`) with `noatime,compress=zstd:1`.

The separate `/boot` exists because GRUB cannot boot from a LUKS2 root created with default settings, and may fail to read XFS filesystems created with the newest `mkfs.xfs` feature defaults. systemd-boot keeps kernels on the EFI partition, so it never needs one.

**Manual** partitioning is for dual boot or custom layouts. The installer can open `cfdisk` for you, then asks which partition is the EFI partition, `/boot` (when needed), root and swap. An existing EFI partition, for example Windows', can be kept without formatting, and `os-prober` is enabled so GRUB lists the other system. The installer does not resize partitions. To make room next to Windows, shrink its partition from Windows first.

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

Every desktop also gets PipeWire with WirePlumber, Noto fonts including emoji, and `xdg-user-dirs`. On systemd, PipeWire is enabled globally as user services. On OpenRC, full desktops start it through XDG autostart, and the installer adds `gentoo-pipewire-launcher` to the Sway and i3 configurations it copies into your home directory.

The profile follows the choice: `desktop/plasma`, `desktop/gnome`, `desktop` or the base profile, each with `/systemd` when systemd is selected.

## If something fails: logs and resuming

- Live side log: `/tmp/gentoo-install.log`
- Inside the new system: `/var/log/gentoo-install.log`, plus a copy of the live log at `/var/log/gentoo-install-live.log` after a successful install.

Every step inside the new system is recorded as it finishes. When a step fails, the installer prints the failing command, the step number and where the log is, then stops. To continue:

1. Read the end of the log.
2. Fix the cause. If it is inside the new system, `chroot /mnt/gentoo /bin/bash`, then `source /etc/profile`, fix it, and `exit`.
3. Run `bash gentoo-install.sh --resume`.

Finished steps are skipped. If the live system was rebooted in between, `--resume` asks for the root partition (and the passphrase if it is encrypted), mounts it and reads the saved settings from `/root/gentoo-install.conf` on it.

Resuming covers failures inside the new system, which is where nearly all of the time and risk is. If it fails earlier (partitioning, downloading or unpacking the stage3), start over from the beginning.

Optional software is handled differently. If a native package, Flatpak app, Bluetooth tool or VM agent fails, the installer retries it on its own, then skips it and lists it at the end and in the post-install notes. The core system (base, kernel, bootloader, desktop, accounts) stops on error so you can fix it and resume.

## After installing

Log in as your user. A guide is saved as `~/GENTOO-POST-INSTALL-NOTES.txt` and `/root/GENTOO-POST-INSTALL-NOTES.txt`, tailored to your choices. The short version:

```sh
emaint sync -a           # update the package repository
emerge -avuDN @world     # update the system
emerge -a --depclean     # remove packages nothing needs anymore
eselect news read        # read Gentoo news; required manual steps are announced here
dispatch-conf            # merge updated configuration files
eclean-kernel -n 3       # after depclean: keep only the three newest kernels
```

With NetworkManager, connect to Wi-Fi from the desktop or with `nmtui`.

## Design decisions and trade-offs

These are the choices the installer makes on your behalf, with what they cost.

**Questions first, then unattended.** You can walk away during the long part. The cost is that you commit to all answers up front; the summary screen and the "change my answers" option exist for that reason.

**Binary packages on by default, with minimal global USE flags.** Gentoo's binary host only helps when a package's USE flags match yours, so `make.conf` adds nothing globally except `dist-kernel`. Customising USE flags later is normal Gentoo usage; expect more local compiling when you do. The binaries are built for generic x86-64 or x86-64-v3, so they are not `-march=native` optimised. Everything compiled locally is. Gentoo's announcement of the binary host listed its desktop packages as built for the Plasma/systemd and GNOME/systemd profiles, which is why systemd is the default for those two desktops; OpenRC works but will likely compile more.

**CPU_FLAGS_X86 detection versus binary hits.** With detection on (the default), packages that use CPU_FLAGS_X86 (mostly codecs, crypto and maths libraries) get compiled locally whenever your CPU's set differs from what the binaries were built with. The installer asks and explains this rather than choosing silently.

**Distribution kernel.** `gentoo-kernel-bin` by default. It supports nearly all hardware, updates with the rest of the system, and rebuilds external modules such as `nvidia-drivers` automatically. There is no option for a hand-configured kernel; switch to `gentoo-sources` later if you want one. Compiling `gentoo-kernel` locally does not apply your `-march=native` CFLAGS by default, since the kernel build uses its own flags.

**installkernel with dracut, host-only initramfs.** The initramfs only contains drivers for this machine, which keeps it small. Moving the disk to other hardware needs `hostonly="no"` and a kernel reinstall; the notes explain how. The kernel command line is also embedded in the initramfs, which installkernel requires inside a chroot and which keeps the system bootable if the bootloader config is lost.

**zram swap by default.** Compressed swap in RAM sized like Fedora's default (equal to RAM, capped at 8 GiB). It is fast and uses no disk. It cannot hibernate.

**GRUB by default.** It handles every combination the installer offers and dual boot detection. systemd-boot is offered on UEFI and is simpler, but keeps kernels on the EFI partition, so that partition needs room (the automatic layout uses 1 GiB).

**Conservative licenses.** `ACCEPT_LICENSE="-* @FREE @BINARY-REDISTRIBUTABLE"`, with explicit exceptions only for firmware, Intel microcode, the NVIDIA driver and Google Chrome when you pick them. Other proprietary packages you install later need their own `package.license` entry; emerge tells you which.

**One engine, two front ends.** The menu version does not reimplement the questions. It replaces the handful of prompt functions (choose, ask, yes/no, password, checklist) with dialog versions, and everything else, including the chroot stage, is shared code. The cost is a build step for contributors (see [Repository layout and building](#repository-layout-and-building)); the benefit is that a fix to a question or to the installation reaches both scripts at once. To let *Back to the main menu* discard a section, each section runs in a subshell and hands its answers back through a private (mode 600) temporary file in the live system's RAM-backed `/tmp`, which is deleted immediately. For the Accounts and Disk sections that file briefly contains the passwords you typed.

**Signature check fallback.** If the stage3's PGP signature cannot be checked because gpg or Gentoo's key is unavailable on the live system, the installer says so and asks whether to continue with only the SHA256 checksum and HTTPS transport. The default answer is yes, so that an unusual live environment does not dead-end the install. A signature that is present and **bad** always aborts. The Handbook's own verification steps use gpg and the key from the official live image, so this fallback should not normally come up there.

## Limitations

- **Untested on real hardware** at this version (see [Status](#gentoo-installer)).
- **Secure Boot is not supported.** Nothing is signed. Disable Secure Boot in the firmware, or set up signing yourself afterwards (Gentoo wiki: *Secure Boot*).
- **amd64 only.** 32-bit UEFI firmware is refused; boot the live image in BIOS/CSM mode on such machines.
- **No LVM, RAID, ZFS or multi-disk root,** and no separate `/home` partition (Btrfs gets an `@home` subvolume).
- **No hibernation** setup, with any swap choice.
- **Encryption scope.** LUKS2 covers the root filesystem. With GRUB, `/boot` is a separate unencrypted partition; with systemd-boot, kernels sit on the unencrypted EFI partition. Either way the kernel and initramfs are readable and could be tampered with by someone with physical access. There is no TPM unlock or keyfile support. The boot-time passphrase prompt may use the US layout, so the installer advises a passphrase that types the same on US and your layout.
- **Hyprland is not offered.** The Gentoo wiki currently recommends installing it from a dedicated overlay; add it after installing.
- **Older NVIDIA cards.** Newer NVIDIA driver branches are dropping older GPUs (the GTX 10 series and earlier are affected). On such a card you may need to mask newer `nvidia-drivers` or use Nouveau.
- **GNOME on OpenRC** works through elogind, but GNOME is developed against systemd, and some settings panels may be limited. The installer recommends systemd when you pick GNOME.
- **dhcpcd and systemd-networkd options configure wired networking only.** Pick NetworkManager for Wi-Fi.
- **Package names in the optional lists can go stale** as Gentoo moves packages around. A missing one is skipped and reported, not fatal.
- **Not portable between machines** without changes, because of `-march=native` and the host-only initramfs.
- **The menu version shows plain text during the installation itself,** not dialog boxes (see [The menu version](#the-menu-version)).
- **Mirrors.** A mirror chosen with `mirrorselect` is used for the stage3 and source downloads; binary packages always come from Gentoo's own CDN (`distfiles.gentoo.org`).

## Testing in a virtual machine

Test both firmware types before trusting it on real hardware. With QEMU and KVM (paths to the OVMF UEFI firmware differ between distributions; common locations are `/usr/share/qemu/ovmf-x86_64-code.bin` on openSUSE, `/usr/share/OVMF/OVMF_CODE_4M.fd` on Debian and Ubuntu, and `/usr/share/edk2/ovmf/OVMF_CODE.fd` on Fedora):

```sh
qemu-img create -f qcow2 gentoo-test.qcow2 60G

# UEFI (copy the matching VARS file first so it is writable)
cp /usr/share/qemu/ovmf-x86_64-vars.bin ./ovmf-vars.bin
qemu-system-x86_64 -enable-kvm -cpu host -smp 4 -m 8G \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/qemu/ovmf-x86_64-code.bin \
  -drive if=pflash,format=raw,file=./ovmf-vars.bin \
  -drive file=gentoo-test.qcow2,if=virtio \
  -cdrom install-amd64-minimal.iso -boot d \
  -nic user,model=virtio-net-pci

# Legacy BIOS (QEMU's default SeaBIOS): same command without the two pflash lines
```

virt-manager is easier: before starting the install, open *Customize configuration*, set the firmware to UEFI (or leave BIOS), and use a VirtIO disk.

In a VM the installer detects the hypervisor, skips firmware and microcode, and installs the matching guest tools. With `-cpu host`, `-march=native` targets your host CPU, so a disk image built this way may not boot on a VM with a different CPU model.

## Files the installer creates

On the new system (paths relative to its root):

| Path | Purpose |
|---|---|
| `/etc/portage/make.conf` | Tuned build settings; the original is kept as `make.conf.stage3-original` |
| `/etc/portage/binrepos.conf/gentoobinhost.conf` | Binary package sources (when enabled) |
| `/etc/portage/package.use/` | `installkernel`, `00cpu-flags`, `luks`, `flatpak` |
| `/etc/portage/package.license/gentoo-install` | Per-package license exceptions |
| `/etc/fstab` | Mounts by UUID |
| `/etc/kernel/cmdline`, `/etc/dracut.conf.d/10-gentoo-install.conf` | Kernel command line and initramfs settings |
| `/etc/sudoers.d/10-wheel` or `/etc/doas.conf` | Administrator access for the `wheel` group |
| `/usr/local/sbin/zram-swap` and its OpenRC `local.d` hooks or systemd unit | zram swap |
| `/etc/cron.weekly/fstrim` | SSD TRIM on OpenRC |
| `/usr/local/sbin/install-my-flatpaks` | Re-runs the Flathub setup and your app selection |
| `/root/gentoo-install.sh`, `/root/gentoo-install.conf`, `/root/.gentoo-install-progress` | Copy of the installer that was used (either version is saved under this name), saved answers (password hashes removed after use) and step progress, kept for `--resume` and for reference. Safe to delete once the system boots. |
| `~/GENTOO-POST-INSTALL-NOTES.txt` | Next steps, tailored to your choices |

## Repository layout and building

The two installers are single files so each can be downloaded with one `curl` command, but they are generated from shared sources:

```
src/10-core.sh        constants, output and prompt helpers, validators
src/20-detect.sh      live system checks, network, clock, hardware detection
src/30-questions.sh   every question, the summary, derived settings
src/40-install.sh     partitioning, stage3, configuration files, resume
src/50-chroot.sh      the 19 steps that run inside the new system
src/60-tui.sh         dialog/whiptail front end and the main menu (menu version only)
src/90-main-cli.sh    entry point of gentoo-install.sh
src/91-main-tui.sh    entry point of gentoo-install-tui.sh
build.sh              concatenates src/ into the two installers
```

To change anything, edit `src/`, then:

```sh
./build.sh           # rebuild gentoo-install.sh and gentoo-install-tui.sh
./build.sh --lint    # run ShellCheck on both
./build.sh --check   # fail if the committed installers do not match src/
```

Commit the rebuilt installers together with the `src/` change. `--check` is meant for a CI job, so a pull request cannot change `src/` without rebuilding. The one ShellCheck exception is documented in `build.sh`: the menu version replaces the console prompt functions with wrappers, and ShellCheck cannot see that the originals are still called through copies made at load time.
