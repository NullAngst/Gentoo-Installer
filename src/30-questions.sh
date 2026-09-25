
# ----------------------------------------------------------------------------
# Questionnaire
# ----------------------------------------------------------------------------
de_label() {
    case "$1" in
        plasma) echo "KDE Plasma" ;;
        gnome) echo "GNOME" ;;
        cinnamon) echo "Cinnamon" ;;
        xfce) echo "Xfce" ;;
        mate) echo "MATE" ;;
        lxqt) echo "LXQt" ;;
        sway) echo "Sway" ;;
        i3) echo "i3" ;;
        *) echo "No desktop (console only)" ;;
    esac
}

default_dm_for() {
    case "$1" in
        plasma|lxqt) echo "sddm" ;;
        gnome) echo "gdm" ;;
        xfce|cinnamon|mate|i3) echo "lightdm" ;;
        *) echo "none" ;;
    esac
}

q_system_type() {
    section "Part 1 of 6: What kind of system"

    say "Choose your graphical desktop. Full desktops (Plasma, GNOME, Cinnamon, Xfce, MATE, LXQt) give you a normal point-and-click environment with a panel, file manager, settings and a login screen. Sway and i3 are tiling window managers: fast and keyboard driven, but you configure them yourself. 'No desktop' is for servers or for building your own setup later." \
        "Hyprland is not offered: the Gentoo wiki currently recommends installing it from a separate overlay, which is outside what this installer sets up. You can add it after installation."
    local prev_de=$DE
    choose DE "Desktop environment" "${DE:-plasma}" \
        "plasma|KDE Plasma: full featured, very configurable, Wayland by default" \
        "gnome|GNOME: clean and modern, few settings, Wayland by default" \
        "cinnamon|Cinnamon: traditional layout (Linux Mint's desktop)" \
        "xfce|Xfce: lightweight and traditional" \
        "mate|MATE: classic GNOME 2 style, very light" \
        "lxqt|LXQt: very lightweight Qt desktop" \
        "sway|Sway: tiling Wayland window manager (keyboard driven, for experienced users)" \
        "i3|i3: tiling X11 window manager (keyboard driven, for experienced users)" \
        "none|No desktop: console only"

    local prev_dm=$DM def_sway
    def_sway=$(yn_default SWAY_AUTOSTART y)
    DM="none"
    SWAY_AUTOSTART="no"
    if [[ $DE == "sway" ]]; then
        say "Sway is started from the text console instead of a graphical login screen. The installer can start it automatically when your user logs in on the first console (tty1), which is the usual setup."
        ask_yn SWAY_AUTOSTART "Start Sway automatically after logging in on tty1?" "$def_sway"
    elif [[ $DE != "none" ]]; then
        local def_dm def_yn="y"
        def_dm=$(default_dm_for "$DE")
        if [[ $DE == "$prev_de" && $prev_dm == "none" ]]; then def_yn="n"; fi
        say "A display manager is the graphical login screen shown at boot. For $(de_label "$DE") the installer uses ${def_dm}. Without one, you log in on a text console and start the desktop yourself."
        if yesno "Install the graphical login screen (${def_dm})?" "$def_yn"; then DM=$def_dm; fi
    fi

    subsection "Init system"
    say "The init system is the first program the kernel starts. It boots the machine and starts and supervises all services." \
        "OpenRC is Gentoo's traditional default: simple, script based and lightweight. systemd is what most other distributions use and brings more integrated tooling (journald logs, timers, per-user services). Both are fully supported by Gentoo." \
        "Gentoo announced its binary package host with desktop packages built for the Plasma/systemd and GNOME/systemd profiles, so for those two desktops systemd is likely to get more ready-made binaries and less compiling."
    local def_init="openrc"
    if [[ $DE == "plasma" || $DE == "gnome" ]]; then def_init="systemd"; fi
    if [[ $DE == "$prev_de" && -n $INIT ]]; then def_init=$INIT; fi
    choose INIT "Init system" "$def_init" \
        "openrc|OpenRC: Gentoo's traditional init system" \
        "systemd|systemd: the init system used by most distributions"
    if [[ $DE == "gnome" && $INIT == "openrc" ]]; then
        warn "GNOME is developed against systemd. On OpenRC it runs through elogind and works, but some features (for example parts of the Settings panels) may be limited."
        if yesno "Switch to systemd for GNOME?" y; then INIT="systemd"; fi
    fi

    subsection "Binary packages"
    say "Gentoo compiles software from source by default. That gives full control and CPU-specific optimisation, but a complete desktop can take many hours to build." \
        "Gentoo also publishes official, PGP-signed binary packages. When they are enabled, Portage downloads a ready-made package whenever one exists that matches your USE flags, and compiles everything else locally with the CPU-tuned settings this installer creates. The binaries themselves are built for generic x86-64 (or x86-64-v3) CPUs, not for -march=native." \
        "Recommended: yes. You can switch to building everything from source at any time later."
    ask_yn USE_BINPKG "Use Gentoo's official binary packages?" "$(yn_default USE_BINPKG y)"
    BINHOST_V3="no"
    if [[ $USE_BINPKG == "yes" && $CPU_X86_64_V3 == "yes" ]]; then
        BINHOST_V3="yes"
        info "Your CPU supports x86-64-v3 (AVX2 generation), so x86-64-v3 binaries will be preferred, with baseline x86-64 as the fallback."
    fi

    subsection "CPU instruction set flags"
    say "CPU_FLAGS_X86 tells packages which instruction set extensions (SSE4.2, AVX2, AES and so on) they may use. The Handbook recommends detecting the exact set of this CPU with the cpuid2cpuflags tool, and the installer can do that."
    if [[ $USE_BINPKG == "yes" ]]; then
        say "Trade-off with binary packages: Portage only uses a binary when its flags match yours. Packages that use CPU_FLAGS_X86 (mostly media codecs, crypto and maths libraries) will therefore be compiled locally when this CPU's set differs from what the binaries were built with. You get code tuned to this CPU at the cost of extra compile time."
    fi
    ask_yn TUNE_CPU_FLAGS "Detect and use this CPU's exact instruction set flags?" "$(yn_default TUNE_CPU_FLAGS y)"

    subsection "Kernel"
    say "Both options are Gentoo's distribution kernel: a well tested configuration that supports nearly all hardware and is updated automatically together with the rest of the system." \
        "gentoo-kernel-bin is prebuilt and installs in minutes. gentoo-kernel is the same kernel compiled on this machine, which often takes 30 to 90 minutes or more. The kernel uses its own compiler flags, so compiling it locally does not turn it into a -march=native kernel by default. It is mainly useful if you plan to customise the kernel configuration later."
    choose KERNEL_PKG "Kernel" "${KERNEL_PKG:-gentoo-kernel-bin}" \
        "gentoo-kernel-bin|gentoo-kernel-bin: prebuilt distribution kernel (recommended)" \
        "gentoo-kernel|gentoo-kernel: the same kernel, compiled locally"
}

q_disk() {
    local live d size model tran
    local -a opts=()
    live=$(live_media_disk)
    while read -r d; do
        [[ -n $d ]] || continue
        if [[ $d == "$live" ]]; then
            info "Skipping ${d}: the live image was booted from it."
            continue
        fi
        size=$(lsblk_field SIZE "$d")
        model=$(lsblk_field MODEL "$d")
        tran=$(lsblk_field TRAN "$d")
        opts+=("${d}|${d}   ${size}   ${model:-unknown model}${tran:+   (${tran})}")
    done < <(list_disks)
    if (( ${#opts[@]} == 0 )); then
        die "No usable disks were found. Check that the disk is connected and visible in 'lsblk'."
    fi
    say "Pick the disk to install Gentoo on. Double check the size and model: the wrong choice can destroy data on another disk."
    choose DISK "Target disk" "${DISK:-${opts[0]%%|*}}" "${opts[@]}"

    say_pre "$(printf '  Current contents of %s:\n' "$DISK"; lsblk -po NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$DISK" 2>/dev/null | sed 's/^/    /')"

    local bytes gib
    bytes=$(lsblk -bdno SIZE "$DISK" | head -n1)
    gib=$(( bytes / 1073741824 ))
    if (( gib < MIN_DISK_GIB )); then
        die "${DISK} has only ${gib} GiB. At least ${MIN_DISK_GIB} GiB is required (40 GiB or more for a desktop)."
    fi
    if (( gib < 40 )) && [[ $DE != "none" ]]; then
        warn "${DISK} has ${gib} GiB. A desktop install with room for updates really wants 40 GiB or more."
    fi
    IS_SSD="no"
    if [[ $(cat "/sys/block/${DISK##*/}/queue/rotational" 2>/dev/null || echo 1) == "0" ]]; then IS_SSD="yes"; fi
}

q_part_mode() {
    say "Erase whole disk: deletes everything on ${DISK} and creates a standard layout automatically. Simple and recommended." \
        "Manual: you create or choose the partitions yourself, for example to keep Windows or another Linux for dual booting. The installer can open the cfdisk partition editor for you and then asks which partition is used for what."
    choose PART_MODE "Partitioning" "${PART_MODE:-auto}" \
        "auto|Erase the whole disk and partition it automatically (recommended)" \
        "manual|Use partitions I choose (dual boot or custom layout)"
}

q_filesystem() {
    local -a opts=("ext4|ext4: the most widely used Linux filesystem, very reliable (recommended)")
    if have mkfs.btrfs; then opts+=("btrfs|Btrfs: snapshots and transparent zstd compression; / and /home become subvolumes"); fi
    if have mkfs.xfs; then opts+=("xfs|XFS: fast with large files and heavy parallel I/O; cannot be shrunk later"); fi
    say "The filesystem organises files on the root partition. If you are unsure, ext4 is the safe choice."
    choose FS "Root filesystem" "${FS:-ext4}" "${opts[@]}"
}

q_encryption() {
    local def
    def=$(yn_default ENCRYPT n)
    ENCRYPT="no"
    LUKS_PASSWORD=""
    if ! have cryptsetup; then
        info "cryptsetup is not available on this live system, so disk encryption is not offered."
        return 0
    fi
    say "Full disk encryption (LUKS2) protects your files if the computer or disk is lost or stolen. You type a passphrase at every boot, before the system starts. It costs a little CPU time, which modern CPUs with AES instructions barely notice." \
        "If you forget the passphrase, the data is gone for good. Nobody can recover it." \
        "Keyboard note: the passphrase prompt at boot may use the US layout. A passphrase made of letters, digits and spaces that sit in the same place on a US keyboard is the safest choice if your layout is different."
    ask_yn ENCRYPT "Encrypt the root partition?" "$def"
    if [[ $ENCRYPT == "yes" ]]; then
        ask_password LUKS_PASSWORD "disk encryption passphrase" 8
    fi
}

q_swap() {
    local ram_cap=$(( RAM_GIB < 8 ? RAM_GIB : 8 ))
    say "Swap is overflow space the kernel uses when RAM runs out." \
        "zram (recommended) creates compressed swap inside RAM. It is fast, uses no disk space, and fits desktops well. Its size will be ${ram_cap} GiB (equal to RAM, capped at 8 GiB, the same rule Fedora uses); it only consumes memory for what is actually swapped." \
        "A swap partition uses disk space. Hibernation needs one, but this installer does not set up hibernation."
    local -a opts=("zram|zram: compressed swap in RAM (recommended)")
    if [[ $ENCRYPT == "yes" ]]; then
        info "A swap partition is not offered with encryption: an unencrypted swap partition could leak the contents of memory to disk."
    else
        opts+=("partition|A swap partition on the disk")
    fi
    opts+=("none|No swap")
    choose SWAP_MODE "Swap" "${SWAP_MODE:-zram}" "${opts[@]}"
    local prev_size=$SWAP_SIZE_GIB
    SWAP_SIZE_GIB=""
    if [[ $SWAP_MODE == "partition" && $PART_MODE == "auto" ]]; then
        ask SWAP_SIZE_GIB "Swap partition size in GiB" "${prev_size:-$ram_cap}" valid_positive_int
    fi
}

q_bootloader() {
    if [[ $BOOT_MODE == "bios" ]]; then
        BOOTLOADER="grub"
        info "Legacy BIOS mode: the GRUB bootloader will be used."
        return 0
    fi
    say "The bootloader shows the boot menu and starts the kernel." \
        "GRUB is the most common Linux bootloader. It works with every option in this installer and can detect other operating systems such as Windows for dual booting." \
        "systemd-boot is a small, fast UEFI boot menu. Kernels are stored on the EFI system partition. It works with both OpenRC and systemd."
    choose BOOTLOADER "Bootloader" "${BOOTLOADER:-grub}" \
        "grub|GRUB (recommended, best for dual boot)" \
        "systemd-boot|systemd-boot (simple and fast, UEFI only)"
}

# pick_partition VAR "Question" "partitions already used"
pick_partition() {
    local __var=$1 __q=$2 __used=${3:-}
    local __live name size fstype ptype label pk
    local -a __opts=()
    __live=$(live_media_disk)
    while read -r name; do
        [[ -n $name ]] || continue
        if [[ " $__used " == *" $name "* ]]; then continue; fi
        pk=$(lsblk_field PKNAME "$name")
        if [[ -n $__live && "/dev/$pk" == "$__live" ]]; then continue; fi
        size=$(lsblk_field SIZE "$name")
        fstype=$(lsblk_field FSTYPE "$name")
        ptype=$(lsblk_field PARTTYPENAME "$name")
        label=$(lsblk_field LABEL "$name")
        __opts+=("${name}|${name}   ${size}   ${fstype:-no filesystem}   ${ptype}${label:+   label: ${label}}")
    done < <(lsblk -lnpo NAME,TYPE 2>/dev/null | awk '$2=="part" {print $1}')
    if (( ${#__opts[@]} == 0 )); then
        die "No free partitions are available. Create them first (for example with cfdisk) and run the installer again."
    fi
    choose "$__var" "$__q" "${__opts[0]%%|*}" "${__opts[@]}"
    local picked=${!__var}
    if findmnt -rn --source "$picked" >/dev/null 2>&1 || grep -q "^${picked} " /proc/swaps; then
        warn "${picked} is currently in use (mounted or active swap). It will be unmounted before installing."
    fi
}

q_manual_partitions() {
    local -a req=()
    if [[ $BOOT_MODE == "uefi" ]]; then
        req+=("An EFI system partition (FAT32). An existing one, for example from Windows, can be reused without formatting. With systemd-boot it holds the kernels, so 1 GiB is recommended.")
    else
        req+=("On a GPT disk: a 1 MiB partition of type 'BIOS boot' on the disk that holds the root partition (GRUB stores itself there).")
    fi
    if [[ $NEED_BOOT_PART == "yes" ]]; then
        req+=("A separate /boot partition of at least 512 MiB (1 GiB recommended). It will be formatted as ext4, because GRUB cannot read the root filesystem you chose ($( [[ $ENCRYPT == yes ]] && echo "encrypted" || echo "XFS with current default features" )).")
    fi
    req+=("A root partition of at least ${MIN_DISK_GIB} GiB (40 GiB or more for a desktop). It will be formatted.")
    if [[ $SWAP_MODE == "partition" ]]; then req+=("A swap partition. It will be formatted as swap."); fi

    say "Manual partitioning. You need:"
    local r
    for r in "${req[@]}"; do say "- $r"; done
    if yesno "Open cfdisk on ${DISK} now to create or change partitions?" y; then
        say "In cfdisk: select free space, choose [ New ], set the size, then [ Type ] to set the partition type (EFI System, BIOS boot, Linux swap, Linux filesystem). Finish with [ Write ] (type 'yes') and [ Quit ]."
        pause
        handoff_screen
        cfdisk "$DISK" || true
        udevadm settle 2>/dev/null || true
        sleep 1
    fi
    say_pre "$(lsblk -po NAME,SIZE,FSTYPE,PARTTYPENAME,LABEL,MOUNTPOINT 2>/dev/null | sed 's/^/    /')"

    local used="" fstype bytes prev_esp=$ESP_PART
    ESP_PART=""; BOOT_PART=""; SWAP_PART=""; BIOS_PART=""; FORMAT_ESP="no"
    if [[ $BOOT_MODE == "uefi" ]]; then
        pick_partition ESP_PART "Which partition is the EFI system partition?" "$used"
        used+=" $ESP_PART"
        fstype=$(lsblk_field FSTYPE "$ESP_PART")
        if [[ $fstype == "vfat" ]]; then
            say "${ESP_PART} already contains a FAT filesystem. If another operating system boots from it (Windows, another Linux), keep it: Gentoo's boot files are simply added next to the existing ones."
            local def_fmt="n"
            if [[ $FORMAT_ESP == "yes" && $ESP_PART == "$prev_esp" ]]; then def_fmt="y"; fi
            ask_yn FORMAT_ESP "Format ${ESP_PART}? (answer no to keep the existing boot files)" "$def_fmt"
        else
            warn "${ESP_PART} has no FAT filesystem, so it will be formatted as FAT32."
            FORMAT_ESP="yes"
        fi
        bytes=$(lsblk -bdno SIZE "$ESP_PART" | head -n1)
        if (( bytes < 300 * 1048576 )); then
            warn "${ESP_PART} is smaller than 300 MiB. That is too small for kernels and may even be tight for GRUB."
        elif [[ $BOOTLOADER == "systemd-boot" ]] && (( bytes < 900 * 1048576 )); then
            warn "With systemd-boot, kernels and initramfs images live on the EFI partition. ${ESP_PART} holds only room for one or two kernels; consider GRUB instead."
        fi
    fi
    if [[ $NEED_BOOT_PART == "yes" ]]; then
        pick_partition BOOT_PART "Which partition should become /boot? (it will be formatted as ext4)" "$used"
        used+=" $BOOT_PART"
    fi
    pick_partition ROOT_PART "Which partition should become the root filesystem / ? (it will be formatted)" "$used"
    used+=" $ROOT_PART"
    if [[ $SWAP_MODE == "partition" ]]; then
        pick_partition SWAP_PART "Which partition should be used as swap? (it will be formatted)" "$used"
        used+=" $SWAP_PART"
    fi

    bytes=$(lsblk -bdno SIZE "$ROOT_PART" | head -n1)
    if (( bytes / 1073741824 < MIN_DISK_GIB )); then
        die "${ROOT_PART} is smaller than ${MIN_DISK_GIB} GiB. Make it larger and run the installer again."
    fi

    DISK="/dev/$(lsblk_field PKNAME "$ROOT_PART")"
    GRUB_DISK=""
    if [[ $BOOT_MODE == "bios" ]]; then
        GRUB_DISK=$DISK
        if [[ $(lsblk_field PTTYPE "$GRUB_DISK") == "gpt" ]]; then
            if ! lsblk -lno PARTTYPE "$GRUB_DISK" 2>/dev/null | grep -qi "${GUID_BIOS}"; then
                die "${GRUB_DISK} uses GPT but has no 'BIOS boot' partition. GRUB needs one (1 MiB, type 'BIOS boot') to boot in BIOS mode. Create it with cfdisk and run the installer again."
            fi
        fi
    fi
    DUAL_BOOT="yes"
    IS_SSD="no"
    if [[ $(cat "/sys/block/${DISK##*/}/queue/rotational" 2>/dev/null || echo 1) == "0" ]]; then IS_SSD="yes"; fi
}

show_auto_layout() {
    local n=1 fsdesc b
    fsdesc="$FS"
    if [[ $ENCRYPT == "yes" ]]; then fsdesc="$FS inside LUKS2 encryption"; fi
    if [[ $FS == "btrfs" ]]; then fsdesc+=", subvolumes @ (/) and @home (/home)"; fi
    b="  Planned layout for ${DISK} (GPT partition table):"$'\n'
    if [[ $BOOT_MODE == "uefi" ]]; then
        printf -v b '%s    %s   %-9s %s\n' "$b" "$(part_dev "$DISK" $n)" "1 GiB" "EFI system partition, FAT32, mounted at /efi"
    else
        printf -v b '%s    %s   %-9s %s\n' "$b" "$(part_dev "$DISK" $n)" "1 MiB" "BIOS boot partition (used by GRUB, no filesystem)"
    fi
    n=$(( n + 1 ))
    if [[ $NEED_BOOT_PART == "yes" ]]; then
        printf -v b '%s    %s   %-9s %s\n' "$b" "$(part_dev "$DISK" $n)" "1 GiB" "boot partition, ext4, mounted at /boot"
        n=$(( n + 1 ))
    fi
    if [[ $SWAP_MODE == "partition" ]]; then
        printf -v b '%s    %s   %-9s %s\n' "$b" "$(part_dev "$DISK" $n)" "${SWAP_SIZE_GIB} GiB" "swap"
        n=$(( n + 1 ))
    fi
    printf -v b '%s    %s   %-9s %s' "$b" "$(part_dev "$DISK" $n)" "the rest" "root filesystem: ${fsdesc}"
    say_pre "$b"
    DUAL_BOOT="no"
    FORMAT_ESP="yes"
    GRUB_DISK="$DISK"
}

q_disk_layout() {
    section "Part 2 of 6: Disk and filesystems"
    q_disk
    q_part_mode
    q_filesystem
    q_encryption
    q_swap
    q_bootloader
    NEED_BOOT_PART="no"
    if [[ $BOOTLOADER == "grub" ]] && [[ $ENCRYPT == "yes" || $FS == "xfs" ]]; then
        NEED_BOOT_PART="yes"
        if [[ $FS == "xfs" && $ENCRYPT == "no" ]]; then
            info "GRUB plus XFS: a separate ext4 /boot partition is used, because GRUB may not read XFS filesystems created with the newest default features."
        fi
    fi
    if [[ $PART_MODE == "manual" ]]; then
        q_manual_partitions
    else
        show_auto_layout
    fi
}

xkb_from_keymap() {
    XKB_VARIANT=""
    case "$1" in
        us|us-*) XKB_LAYOUT="us" ;;
        dvorak) XKB_LAYOUT="us"; XKB_VARIANT="dvorak" ;;
        uk|gb*) XKB_LAYOUT="gb" ;;
        sg*|fr_CH*|de_CH*|ch*) XKB_LAYOUT="ch" ;;
        de*) XKB_LAYOUT="de" ;;
        fr*) XKB_LAYOUT="fr" ;;
        es*) XKB_LAYOUT="es" ;;
        it*) XKB_LAYOUT="it" ;;
        br*) XKB_LAYOUT="br" ;;
        pt*) XKB_LAYOUT="pt" ;;
        pl*) XKB_LAYOUT="pl" ;;
        ru*) XKB_LAYOUT="ru" ;;
        se*|sv*) XKB_LAYOUT="se" ;;
        no*) XKB_LAYOUT="no" ;;
        dk*) XKB_LAYOUT="dk" ;;
        fi*) XKB_LAYOUT="fi" ;;
        be*) XKB_LAYOUT="be" ;;
        nl*) XKB_LAYOUT="nl" ;;
        cz*) XKB_LAYOUT="cz" ;;
        hu*) XKB_LAYOUT="hu" ;;
        jp*) XKB_LAYOUT="jp" ;;
        *) XKB_LAYOUT="$1" ;;
    esac
}

ask_timezone() {
    say "The timezone sets your local time. Use the Region/City form, for example America/New_York, Europe/London or Asia/Tokyo. Type 'list' to browse."
    ask TIMEZONE "Timezone" "${TIMEZONE:-UTC}" valid_timezone
}

q_region() {
    section "Part 3 of 6: Name, region and language"

    say "The hostname is this computer's name on your network."
    ask NEW_HOSTNAME "Hostname" "${NEW_HOSTNAME:-gentoo}" valid_hostname

    ask_timezone

    say "The locale sets the system language and formats (dates, numbers). en_US.UTF-8 is also always generated as a fallback."
    ask LOCALE "Locale" "${LOCALE:-en_US.UTF-8}" valid_locale

    say "The console keymap is the keyboard layout for text consoles (and for the encryption passphrase prompt, where supported)."
    local prev_keymap=$KEYMAP prev_xkb=$XKB_LAYOUT prev_var=$XKB_VARIANT
    ask KEYMAP "Console keymap" "${KEYMAP:-us}" valid_keymap

    if [[ $DE != "none" ]]; then
        xkb_from_keymap "$KEYMAP"
        if [[ $KEYMAP == "$prev_keymap" && -n $prev_xkb ]]; then
            XKB_LAYOUT=$prev_xkb
            XKB_VARIANT=$prev_var
        fi
        say "The graphical keyboard layout (XKB) is used by the desktop. It is derived from your console keymap. Plasma and GNOME also let you change it later in their settings."
        local def=$XKB_LAYOUT
        ask XKB_LAYOUT "Desktop keyboard layout (XKB name, for example us, gb, de, fr)" "$def" valid_xkb_layout
        if [[ $XKB_LAYOUT != "$def" ]]; then XKB_VARIANT=""; fi
    fi
}

q_accounts() {
    section "Part 4 of 6: User accounts"
    say "root is the administrator account. You will normally not log in as root; the password is for emergencies and system maintenance."
    ask_password ROOT_PASSWORD "new root password" 1

    say "Now create your everyday user account. It can run administrator commands with sudo or doas."
    ask USERNAME "Username (lowercase)" "${USERNAME:-}" valid_username
    ask_password USER_PASSWORD "password for ${USERNAME}" 1

    say "sudo is the standard tool for running a command as administrator. doas is a much smaller alternative from OpenBSD. Either way, your user is added to the 'wheel' group, which is allowed to use it."
    choose PRIV_TOOL "Administrator tool" "${PRIV_TOOL:-sudo}" \
        "sudo|sudo (standard, recommended)" \
        "doas|doas (minimal)"
}

compute_video_cards() {
    local vc=""
    if [[ $HAS_INTEL == "yes" ]]; then vc+=" intel"; fi
    if [[ $HAS_AMD == "yes" ]]; then vc+=" amdgpu radeonsi"; fi
    if [[ $HAS_NVIDIA == "yes" ]]; then
        if [[ $GPU_DRIVER == "nvidia" ]]; then vc+=" nvidia"; else vc+=" nouveau"; fi
    fi
    if [[ -n $GPU_VM ]]; then vc+=" $GPU_VM"; fi
    VIDEO_CARDS=$(trim "$vc")
}

q_hardware_network() {
    section "Part 5 of 6: Drivers, network and services"

    local prev_gpu=$GPU_DRIVER def_gpu="nvidia"
    if [[ $prev_gpu == "nouveau" ]]; then def_gpu="nouveau"; fi
    GPU_DRIVER="mesa"
    if [[ $HAS_NVIDIA == "yes" ]]; then
        say "An NVIDIA graphics card was detected." \
            "The proprietary NVIDIA driver gives full performance, CUDA and working power management, and is the right choice for GeForce GTX 16xx, RTX and newer cards. Very old cards (GTX 10xx and earlier) are being phased out by newer NVIDIA driver branches; if you have one, check the Gentoo wiki page 'NVIDIA/nvidia-drivers' after installing." \
            "Nouveau is the open source driver. It works out of the box but is much slower on most cards because it cannot raise their clock speeds."
        choose GPU_DRIVER "NVIDIA driver" "$def_gpu" \
            "nvidia|Proprietary NVIDIA driver (recommended for modern cards)" \
            "nouveau|Nouveau open source driver"
    fi
    compute_video_cards
    if [[ -n $VIDEO_CARDS ]]; then
        info "Graphics drivers (VIDEO_CARDS) set from the detected hardware: ${VIDEO_CARDS}"
    else
        warn "No known graphics hardware was detected, so VIDEO_CARDS is left empty (a basic framebuffer driver will be used)."
    fi
    if [[ $HAS_AMD == "yes" ]]; then
        say "Note: amdgpu/radeonsi covers AMD cards from the GCN generation (Radeon HD 7000, 2012) onward. For older Radeon cards, add 'radeon r600' to VIDEO_CARDS in /etc/portage/make.conf after installing."
    fi

    subsection "Networking"
    local def_net="networkmanager"
    if [[ $DE == "none" && $HAS_WIFI == "no" ]]; then def_net="dhcpcd"; fi
    say "This decides how the installed system connects to the network."
    local -a nopts=("networkmanager|NetworkManager: wired and Wi-Fi, a network icon in desktops, 'nmtui' in a terminal (recommended)"
                    "dhcpcd|dhcpcd: minimal, for wired Ethernet only (no Wi-Fi setup)")
    if [[ $INIT == "systemd" ]]; then
        nopts+=("networkd|systemd-networkd: built into systemd, for wired Ethernet only")
    fi
    choose NET_TOOL "Network manager" "${NET_TOOL:-$def_net}" "${nopts[@]}"
    if [[ $HAS_WIFI == "yes" && $NET_TOOL != "networkmanager" ]]; then
        warn "This machine has Wi-Fi, but ${NET_TOOL} as configured here only handles wired connections. You would have to set up Wi-Fi yourself after installing."
    fi

    subsection "Other hardware and services"
    local def_bt="n"
    if [[ $HAS_BT == "yes" ]]; then def_bt="y"; fi
    say "Bluetooth support installs BlueZ and enables its service$( [[ $HAS_BT == yes ]] && echo " (a Bluetooth adapter was detected)" )."
    ask_yn WANT_BT "Install Bluetooth support?" "$(yn_default WANT_BT "$def_bt")"

    local def_cups
    def_cups=$(yn_default WANT_CUPS n)
    WANT_CUPS="no"
    if [[ $DE != "none" ]]; then
        say "CUPS is the printing system. Only needed if you print from this computer."
        ask_yn WANT_CUPS "Install printer support (CUPS)?" "$def_cups"
    fi

    local def_ssh="n"
    if [[ $DE == "none" ]]; then def_ssh="y"; fi
    say "An SSH server lets you log in to this machine remotely over the network. Useful for servers; not needed on a typical desktop."
    ask_yn WANT_SSH "Enable the SSH server?" "$(yn_default WANT_SSH "$def_ssh")"
}

NATIVE_GUI_APPS=(
    "www-client/firefox-bin|Firefox web browser (prebuilt by Mozilla, no compiling)"
    "www-client/google-chrome|Google Chrome web browser (proprietary)"
    "mail-client/thunderbird-bin|Thunderbird email client (prebuilt)"
    "app-office/libreoffice-bin|LibreOffice office suite (prebuilt; the source build takes hours)"
    "media-video/vlc|VLC media player"
    "media-video/mpv|mpv media player (minimal, keyboard driven)"
    "media-gfx/gimp|GIMP image editor"
    "media-gfx/inkscape|Inkscape vector graphics editor"
    "media-video/obs-studio|OBS Studio (screen recording and streaming)"
    "media-sound/audacity|Audacity audio editor"
    "app-admin/keepassxc|KeePassXC password manager"
    "net-p2p/qbittorrent|qBittorrent BitTorrent client"
)
NATIVE_CLI_APPS=(
    "dev-vcs/git|Git version control"
    "app-editors/neovim|Neovim text editor"
    "app-editors/vim|Vim text editor"
    "sys-process/htop|htop process viewer"
    "sys-process/btop|btop resource monitor"
    "app-misc/fastfetch|fastfetch system information"
    "app-misc/tmux|tmux terminal multiplexer"
    "app-shells/zsh|Zsh shell"
    "app-arch/7zip|7-Zip archiver"
    "net-misc/yt-dlp|yt-dlp video downloader"
)
FLATPAK_CATALOG=(
    "org.mozilla.firefox|Firefox"
    "com.brave.Browser|Brave browser"
    "com.google.Chrome|Google Chrome"
    "org.chromium.Chromium|Chromium"
    "org.mozilla.Thunderbird|Thunderbird"
    "org.libreoffice.LibreOffice|LibreOffice"
    "org.onlyoffice.desktopeditors|ONLYOFFICE Desktop Editors"
    "org.videolan.VLC|VLC"
    "io.mpv.Mpv|mpv"
    "org.gimp.GIMP|GIMP"
    "org.inkscape.Inkscape|Inkscape"
    "org.kde.krita|Krita"
    "org.kde.kdenlive|Kdenlive video editor"
    "com.obsproject.Studio|OBS Studio"
    "org.audacityteam.Audacity|Audacity"
    "com.valvesoftware.Steam|Steam"
    "net.lutris.Lutris|Lutris"
    "com.heroicgameslauncher.hgl|Heroic Games Launcher"
    "com.discordapp.Discord|Discord"
    "com.spotify.Client|Spotify"
    "org.signal.Signal|Signal"
    "org.telegram.desktop|Telegram"
    "com.visualstudio.code|Visual Studio Code"
    "org.keepassxc.KeePassXC|KeePassXC"
    "com.bitwarden.desktop|Bitwarden"
    "org.qbittorrent.qBittorrent|qBittorrent"
    "com.github.tchx84.Flatseal|Flatseal (manage Flatpak app permissions)"
)

q_software() {
    section "Part 6 of 6: Software"

    say "Packages are downloaded from Gentoo's global mirror network (a CDN), which is fast almost everywhere. You can instead pick specific mirrors with mirrorselect." 
    local -a mopts=("cdn|Gentoo's global CDN (recommended)")
    local mirror_mode def_mirror="cdn"
    if [[ -n $GENTOO_MIRRORS_VALUE ]]; then
        mopts+=("keep|Keep the mirrors chosen before: ${GENTOO_MIRRORS_VALUE}")
        def_mirror="keep"
    fi
    if have mirrorselect; then mopts+=("select|Choose mirrors myself (mirrorselect)"); fi
    choose mirror_mode "Download mirror" "$def_mirror" "${mopts[@]}"
    if [[ $mirror_mode == "cdn" ]]; then
        GENTOO_MIRRORS_VALUE=""
        DIST_BASE="https://distfiles.gentoo.org"
    elif [[ $mirror_mode == "select" ]]; then
        GENTOO_MIRRORS_VALUE=""
        DIST_BASE="https://distfiles.gentoo.org"
        say "mirrorselect will show a list. Use the arrow keys and space bar to mark mirrors near you, then confirm with Enter."
        pause
        handoff_screen
        local out
        out=$(mirrorselect -i -o 2>/dev/tty || true)
        GENTOO_MIRRORS_VALUE=$(sed -n 's/^GENTOO_MIRRORS="\(.*\)"$/\1/p' <<<"$out" | head -n1 || true)
        GENTOO_MIRRORS_VALUE=$(trim "$GENTOO_MIRRORS_VALUE")
        if [[ -n $GENTOO_MIRRORS_VALUE ]]; then
            DIST_BASE="${GENTOO_MIRRORS_VALUE%% *}"
            DIST_BASE="${DIST_BASE%/}"
            ok "Using mirrors: ${GENTOO_MIRRORS_VALUE}"
        else
            warn "No mirror was selected; using the global CDN."
        fi
    fi

    local def_flatpak
    def_flatpak=$(yn_default WANT_FLATPAK y)
    WANT_FLATPAK="no"
    if [[ $DE != "none" ]]; then
        subsection "Flatpak"
        say "Flatpak installs desktop applications from Flathub in their own sandboxed containers, independent from Portage. They are prebuilt (no compiling), update separately with 'flatpak update', and use more disk space because they bundle their own libraries. Handy for large or proprietary apps such as Steam, Discord or Spotify."
        ask_yn WANT_FLATPAK "Install Flatpak and add the Flathub repository?" "$def_flatpak"
        if [[ $WANT_FLATPAK == "yes" ]]; then
            choose_multi FLATPAK_APPS "Flatpak apps to install now (you can add more any time later)" "${FLATPAK_CATALOG[@]}"
        fi
    fi
    if [[ $WANT_FLATPAK != "yes" ]]; then FLATPAK_APPS=""; fi

    subsection "Native packages"
    say "These are installed with Portage (emerge), the Gentoo way. Everything is optional and you can install anything else later with 'emerge --ask <package>'. Pick nothing here if you chose the same apps as Flatpaks above."
    local -a catalog=()
    if [[ $DE != "none" ]]; then catalog+=("${NATIVE_GUI_APPS[@]}"); fi
    catalog+=("${NATIVE_CLI_APPS[@]}")
    choose_multi EXTRA_PKGS "Native packages to install" "${catalog[@]}"
}

compute_build_params() {
    local by_ram=$(( RAM_GIB / 2 ))
    by_ram=$(( by_ram < 1 ? 1 : by_ram ))
    MAKE_JOBS=$(( NPROC < by_ram ? NPROC : by_ram ))
    MAKE_JOBS=$(( MAKE_JOBS < 1 ? 1 : MAKE_JOBS ))
    # Parallel package builds multiply memory use (each one runs MAKEOPTS jobs), and
    # the load-average limit reacts with a delay, so stay conservative.
    local e=3
    local by_cpu=$(( NPROC / 6 ))
    local by_mem=$(( RAM_GIB / 12 ))
    e=$(( by_cpu < e ? by_cpu : e ))
    e=$(( by_mem < e ? by_mem : e ))
    EMERGE_JOBS=$(( e < 1 ? 1 : e ))
}

compute_derived() {
    compute_video_cards
    compute_build_params
    case "$DE" in
        none) PROFILE_SUFFIX="" ;;
        plasma) PROFILE_SUFFIX="/desktop/plasma" ;;
        gnome) PROFILE_SUFFIX="/desktop/gnome" ;;
        *) PROFILE_SUFFIX="/desktop" ;;
    esac
    if [[ $INIT == "systemd" ]]; then PROFILE_SUFFIX+="/systemd"; fi
    if [[ $DE == "none" ]]; then STAGE3_VARIANT="$INIT"; else STAGE3_VARIANT="desktop-${INIT}"; fi
}

ask_all_questions() {
    q_system_type
    q_disk_layout
    q_region
    q_accounts
    q_hardware_network
    q_software
    compute_derived
}

summary_row() {
    printf '  %-28s %s\n' "$1" "$2"
}

print_summary() {
    section "Summary: please check everything"
    summary_row "Desktop:" "$(de_label "$DE")"
    if [[ $DE != "none" ]]; then
        if [[ $DE == "sway" ]]; then
            summary_row "Login:" "text console$( [[ $SWAY_AUTOSTART == yes ]] && echo ", Sway starts automatically on tty1" )"
        else
            summary_row "Login screen:" "$( [[ $DM == none ]] && echo "none (text console)" || echo "$DM" )"
        fi
    fi
    summary_row "Init system:" "$INIT"
    summary_row "Profile:" "default/linux/amd64/<current>${PROFILE_SUFFIX}"
    summary_row "Stage3:" "stage3-amd64-${STAGE3_VARIANT}"
    summary_row "Binary packages:" "$USE_BINPKG$( [[ $BINHOST_V3 == yes ]] && echo " (x86-64-v3 preferred)" )"
    summary_row "Kernel:" "sys-kernel/${KERNEL_PKG}"
    summary_row "Compiler flags:" "-march=native -O2 -pipe"
    summary_row "MAKEOPTS:" "-j${MAKE_JOBS} -l${NPROC}   (emerge --jobs=${EMERGE_JOBS})"
    summary_row "CPU_FLAGS_X86:" "$( [[ $TUNE_CPU_FLAGS == yes ]] && echo "detected with cpuid2cpuflags" || echo "profile default" )"
    summary_row "VIDEO_CARDS:" "${VIDEO_CARDS:-(none)}"
    echo
    summary_row "Boot mode / bootloader:" "${BOOT_MODE^^} / ${BOOTLOADER}"
    if [[ $PART_MODE == "auto" ]]; then
        summary_row "Disk:" "${DISK}  ${C_RED}(EVERYTHING ON IT WILL BE ERASED)${C_RESET}"
    else
        summary_row "Disk mode:" "manual partitions"
        if [[ $BOOT_MODE == "uefi" ]]; then
            summary_row "EFI partition:" "${ESP_PART} -> /efi $( [[ $FORMAT_ESP == yes ]] && echo "(WILL BE FORMATTED)" || echo "(kept, not formatted)" )"
        fi
        if [[ -n $BOOT_PART ]]; then summary_row "/boot partition:" "${BOOT_PART} (WILL BE FORMATTED)"; fi
        summary_row "Root partition:" "${ROOT_PART} (WILL BE FORMATTED)"
        if [[ -n $SWAP_PART ]]; then summary_row "Swap partition:" "${SWAP_PART} (WILL BE FORMATTED)"; fi
        if [[ $BOOT_MODE == "bios" ]]; then summary_row "GRUB installed to:" "$GRUB_DISK"; fi
    fi
    summary_row "Root filesystem:" "${FS}$( [[ $FS == btrfs ]] && echo " (subvolumes @, @home; zstd compression)" )"
    summary_row "Encryption:" "$( [[ $ENCRYPT == yes ]] && echo "LUKS2" || echo "no" )"
    summary_row "Swap:" "$SWAP_MODE$( [[ -n $SWAP_SIZE_GIB ]] && echo " (${SWAP_SIZE_GIB} GiB)" )"
    echo
    summary_row "Hostname:" "$NEW_HOSTNAME"
    summary_row "Timezone:" "$TIMEZONE"
    summary_row "Locale:" "$LOCALE"
    summary_row "Console keymap:" "$KEYMAP"
    if [[ $DE != "none" ]]; then summary_row "Desktop keyboard:" "${XKB_LAYOUT}${XKB_VARIANT:+ (${XKB_VARIANT})}"; fi
    summary_row "User:" "$USERNAME (admin tool: ${PRIV_TOOL})"
    echo
    summary_row "Network:" "$NET_TOOL"
    summary_row "Graphics driver:" "$( [[ $HAS_NVIDIA == yes ]] && echo "$GPU_DRIVER" || echo "Mesa (open source)" )"
    summary_row "Bluetooth / printing / SSH:" "${WANT_BT} / ${WANT_CUPS} / ${WANT_SSH}"
    if [[ $VIRT != "none" ]]; then summary_row "VM guest tools:" "$VIRT"; fi
    summary_row "Mirror:" "${GENTOO_MIRRORS_VALUE:-global CDN (distfiles.gentoo.org)}"
    summary_row "Flatpak:" "${WANT_FLATPAK}${FLATPAK_APPS:+ (apps: ${FLATPAK_APPS})}"
    summary_row "Native packages:" "${EXTRA_PKGS:-none}"
    echo
}

confirm_install() {
    local next typed
    choose next "What next?" "install" \
        "install|Start the installation with these settings" \
        "redo|Change my answers (go through the questions again)" \
        "quit|Quit without changing anything"
    case "$next" in
        quit) info "Nothing was changed. Bye."; exit 0 ;;
        redo) return 1 ;;
    esac
    echo
    if [[ $PART_MODE == "auto" ]]; then
        warn "LAST WARNING: every partition and file on ${DISK} will be permanently deleted."
        read_line typed "  Type ERASE in capital letters to continue (anything else goes back): "
        if [[ $(trim "$typed") != "ERASE" ]]; then warn "Not confirmed."; return 1; fi
    else
        warn "LAST WARNING: the partitions marked 'WILL BE FORMATTED' above will be erased."
        read_line typed "  Type FORMAT in capital letters to continue (anything else goes back): "
        if [[ $(trim "$typed") != "FORMAT" ]]; then warn "Not confirmed."; return 1; fi
    fi
    return 0
}
