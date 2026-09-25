
# ----------------------------------------------------------------------------
# Downloads
# ----------------------------------------------------------------------------

# fetch URL OUTFILE (shows a progress bar)
fetch() {
    log "FETCH: $1 -> $2"
    if have curl; then
        curl -fL --retry 3 --retry-delay 3 --connect-timeout 20 --progress-bar -o "$2" "$1"
    else
        wget --tries=3 --timeout=20 -q --show-progress -O "$2" "$1"
    fi
}

# fetch_text URL (prints the body)
fetch_text() {
    if have curl; then
        curl -fsSL --retry 2 --connect-timeout 15 "$1"
    else
        wget -qO- --tries=2 --timeout=15 "$1"
    fi
}

have_internet() {
    fetch_text "${DIST_BASE%/}/releases/amd64/autobuilds/latest-stage3-amd64-openrc.txt" >/dev/null 2>&1
}

# ----------------------------------------------------------------------------
# Live environment checks
# ----------------------------------------------------------------------------
usage() {
    cat <<EOF
gentoo-install.sh ${SCRIPT_VERSION}: guided Gentoo Linux installer for amd64

Usage:
  bash gentoo-install.sh            Start a new installation
  bash gentoo-install.sh --resume   Continue after fixing a failed step
  bash gentoo-install.sh --help     Show this help

Run it as root from the official Gentoo live image (minimal or LiveGUI).
Download it first, then run it. Piping it into bash does not work because
the installer reads your answers from the keyboard.
EOF
}

live_preflight() {
    if [[ $EUID -ne 0 ]]; then
        die "Please run as root. On the LiveGUI image use: sudo bash gentoo-install.sh"
    fi
    if [[ $(uname -m) != "x86_64" ]]; then
        die "This installer supports amd64 (x86_64) only. This machine reports: $(uname -m)."
    fi
    if (( BASH_VERSINFO[0] < 5 )); then
        die "Bash 5 or newer is required."
    fi
    local -a missing=()
    local t
    for t in lsblk blkid wipefs sfdisk mkfs.ext4 mkswap mount umount mountpoint findmnt chroot tar xz sha256sum awk sed grep fold udevadm; do
        have "$t" || missing+=("$t")
    done
    if ! have curl && ! have wget; then missing+=("curl or wget"); fi
    if (( ${#missing[@]} > 0 )); then
        die "Missing tools on this live system: ${missing[*]}. Please use the official Gentoo minimal or LiveGUI image."
    fi
    mkdir -p "$MNT"
}

welcome() {
    clear 2>/dev/null || true
    section "Gentoo Linux installer ${SCRIPT_VERSION}"
    say "This script installs Gentoo Linux on this computer, following the official Gentoo AMD64 Handbook. It explains every choice as it goes." \
        "How it works: first it checks your network and hardware, then it asks all of its questions (about 5 minutes). The installer changes nothing on your disks until you have reviewed a summary and typed a confirmation word (in manual mode you can edit partitions yourself along the way). After that it runs on its own." \
        "How long it takes depends on your CPU, your internet connection and your choices. With Gentoo's binary packages a full desktop usually finishes in well under two hours on a modern machine; compiling everything from source can take many hours. Keep the computer plugged in." \
        "Everything is logged to ${LIVE_LOG}. You can stop at any question with Ctrl+C."
    pause
}

live_keyboard() {
    section "Keyboard layout"
    say "The live system uses a US keyboard layout. If your keyboard is different, switch now so that the passwords you type later are entered correctly."
    if yesno "Is your keyboard a US layout?" y; then
        KEYMAP="us"
        return 0
    fi
    ask KEYMAP "Console keymap name (examples: uk, de, de-latin1, fr, es, it, br-abnt2, pl, ru, dvorak)" "" valid_keymap
    if have loadkeys; then
        run loadkeys "$KEYMAP" || warn "Could not switch the live keyboard layout; continuing with US."
    fi
}

list_interfaces() {
    local n
    for n in /sys/class/net/*; do
        [[ -e $n ]] || continue
        n=${n##*/}
        [[ $n == "lo" ]] && continue
        echo "$n"
    done
}

network_step() {
    section "Network connection"
    say "The installer downloads the Gentoo base system and all packages from the internet, so a working connection is required. Wired Ethernet usually works automatically."
    local action iface
    while ! have_internet; do
        warn "No working internet connection was detected (could not reach ${DIST_BASE})."
        local -a opts=("retry|Check again")
        if have net-setup; then opts+=("netsetup|Run Gentoo's net-setup wizard (wired or Wi-Fi)"); fi
        if have nmtui; then opts+=("nmtui|Run nmtui (NetworkManager, wired or Wi-Fi)"); fi
        if have iwctl; then opts+=("iwctl|Run iwctl (Wi-Fi with iwd)"); fi
        if have dhcpcd; then opts+=("dhcpcd|Run dhcpcd on all interfaces (wired DHCP)"); fi
        opts+=("shell|Open a shell and fix it myself (type 'exit' to come back)" "quit|Quit the installer")
        choose action "How do you want to connect?" "retry" "${opts[@]}"
        case "$action" in
            netsetup)
                local -a ifopts=()
                while read -r iface; do ifopts+=("${iface}|${iface}"); done < <(list_interfaces)
                if (( ${#ifopts[@]} == 0 )); then warn "No network interfaces found."; continue; fi
                choose iface "Which network interface?" "${ifopts[0]%%|*}" "${ifopts[@]}"
                handoff_screen
                net-setup "$iface" || true ;;
            nmtui) handoff_screen; nmtui || true ;;
            iwctl)
                say "In iwctl: 'device list', then 'station <device> scan', 'station <device> get-networks', 'station <device> connect <network name>'. Type 'exit' when connected."
                pause
                handoff_screen
                iwctl || true ;;
            dhcpcd) handoff_screen; dhcpcd || true; sleep 5 ;;
            shell) handoff_screen; bash || true ;;
            quit) exit 0 ;;
        esac
    done
    ok "Internet connection works."
}

sync_clock() {
    info "Setting the clock from the internet (TLS downloads and PGP checks need a correct date)."
    local synced="no"
    if have chronyd; then
        if timeout 60 chronyd -q >>"$LOG" 2>&1 || timeout 60 chronyd -q 'server pool.ntp.org iburst' >>"$LOG" 2>&1; then
            synced="yes"
        fi
    fi
    if [[ $synced == "no" ]] && have ntpd; then
        if timeout 60 ntpd -q -g -n -p pool.ntp.org >>"$LOG" 2>&1 || timeout 60 ntpd -q -n -p pool.ntp.org >>"$LOG" 2>&1; then
            synced="yes"
        fi
    fi
    if [[ $synced == "yes" ]]; then
        ok "Clock set: $(date -u '+%Y-%m-%d %H:%M UTC')"
    else
        warn "Could not sync the clock automatically. Current time: $(date -u '+%Y-%m-%d %H:%M UTC')"
    fi
    if (( $(date +%Y) < 2026 )); then
        warn "The system date looks wrong. Downloads and signature checks can fail."
        local d
        ask d "Enter the current UTC date and time as MMDDhhmmYYYY (example: 092514302026)" "" 
        if [[ $d =~ ^[0-9]{12}$ ]]; then
            run date -u "$d" || warn "Could not set the date."
        else
            warn "Unrecognised format; leaving the clock unchanged."
        fi
    fi
}

# ----------------------------------------------------------------------------
# Hardware detection
# ----------------------------------------------------------------------------
detect_gpus() {
    HAS_NVIDIA="no"; HAS_AMD="no"; HAS_INTEL="no"; GPU_VM=""
    GPU_NAMES=()
    local d class vendor slot name
    for d in /sys/bus/pci/devices/*; do
        [[ -r $d/class && -r $d/vendor ]] || continue
        class=$(<"$d/class")
        [[ $class == 0x03* ]] || continue
        vendor=$(<"$d/vendor")
        slot=${d##*/}
        case "$vendor" in
            0x10de) HAS_NVIDIA="yes" ;;
            0x1002) HAS_AMD="yes" ;;
            0x8086) HAS_INTEL="yes" ;;
            0x15ad|0x80ee) [[ $GPU_VM == *vmware* ]] || GPU_VM+=" vmware" ;;
            0x1af4) [[ $GPU_VM == *virgl* ]] || GPU_VM+=" virgl" ;;
            0x1b36) [[ $GPU_VM == *qxl* ]] || GPU_VM+=" qxl" ;;
        esac
        name=""
        if have lspci; then
            name=$(lspci -s "$slot" 2>/dev/null | cut -d' ' -f2- || true)
        fi
        GPU_NAMES+=("${name:-PCI ${slot} vendor ${vendor}}")
    done
    GPU_VM=$(trim "$GPU_VM")
}

detect_hardware() {
    CPU_VENDOR=$(awk -F': *' '/^vendor_id/ {print $2; exit}' /proc/cpuinfo)
    CPU_MODEL=$(awk -F': *' '/^model name/ {print $2; exit}' /proc/cpuinfo)
    NPROC=$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo)
    local mem_kib
    mem_kib=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
    RAM_GIB=$(( (mem_kib + 524288) / 1048576 ))
    if (( RAM_GIB < 1 )); then RAM_GIB=1; fi

    local flags f
    flags=" $(awk -F': *' '/^flags/ {print $2; exit}' /proc/cpuinfo) "
    CPU_X86_64_V3="yes"
    for f in avx avx2 bmi1 bmi2 f16c fma abm movbe xsave; do
        if [[ $flags != *" $f "* ]]; then CPU_X86_64_V3="no"; fi
    done

    if [[ -d /sys/firmware/efi ]]; then BOOT_MODE="uefi"; else BOOT_MODE="bios"; fi
    UEFI_BITS=""
    if [[ -r /sys/firmware/efi/fw_platform_size ]]; then UEFI_BITS=$(</sys/firmware/efi/fw_platform_size); fi

    SECURE_BOOT="off"
    local sb val
    for sb in /sys/firmware/efi/efivars/SecureBoot-*; do
        [[ -r $sb ]] || continue
        val=$(od -An -t u1 "$sb" 2>/dev/null | awk '{print $NF}')
        if [[ $val == "1" ]]; then SECURE_BOOT="on"; fi
    done

    VIRT="none"
    local vendor product
    vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true)
    product=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)
    case "$vendor $product" in
        *QEMU*|*KVM*|*"Red Hat"*) VIRT="kvm" ;;
        *VMware*) VIRT="vmware" ;;
        *innotek*|*VirtualBox*) VIRT="virtualbox" ;;
        *Microsoft*"Virtual Machine"*) VIRT="hyperv" ;;
        *Xen*) VIRT="xen" ;;
    esac
    if [[ $VIRT == "none" && $flags == *" hypervisor "* ]]; then VIRT="other"; fi

    IS_LAPTOP="no"
    if compgen -G "/sys/class/power_supply/BAT*" >/dev/null; then IS_LAPTOP="yes"; fi
    case "$(cat /sys/class/dmi/id/chassis_type 2>/dev/null || echo 0)" in
        8|9|10|11|14|30|31|32) IS_LAPTOP="yes" ;;
    esac

    HAS_WIFI="no"
    local n
    for n in /sys/class/net/*; do
        if [[ -d $n/wireless || -e $n/phy80211 ]]; then HAS_WIFI="yes"; fi
    done

    HAS_BT="no"
    if compgen -G "/sys/class/bluetooth/hci*" >/dev/null; then HAS_BT="yes"; fi

    detect_gpus
}

show_hardware() {
    section "Detected hardware"
    local b="" g fw vm
    fw="Legacy BIOS"
    if [[ $BOOT_MODE == "uefi" ]]; then fw="UEFI (${UEFI_BITS:-64}-bit)"; fi
    vm="no (real hardware)"
    if [[ $VIRT != "none" ]]; then vm="yes ($VIRT)"; fi
    printf -v b '%s  %-22s %s\n' "$b" "CPU:" "${CPU_MODEL:-unknown} (${CPU_VENDOR:-unknown})"
    printf -v b '%s  %-22s %s\n' "$b" "CPU threads:" "$NPROC"
    printf -v b '%s  %-22s %s\n' "$b" "Memory:" "about ${RAM_GIB} GiB"
    printf -v b '%s  %-22s %s\n' "$b" "x86-64-v3 capable:" "$CPU_X86_64_V3 (AVX2 generation or newer)"
    printf -v b '%s  %-22s %s\n' "$b" "Firmware boot mode:" "$fw"
    if [[ $BOOT_MODE == "uefi" ]]; then
        printf -v b '%s  %-22s %s\n' "$b" "Secure Boot:" "$SECURE_BOOT"
    fi
    printf -v b '%s  %-22s %s\n' "$b" "Virtual machine:" "$vm"
    printf -v b '%s  %-22s %s\n' "$b" "Laptop:" "$IS_LAPTOP"
    printf -v b '%s  %-22s %s\n' "$b" "Wi-Fi adapter:" "$HAS_WIFI"
    printf -v b '%s  %-22s %s\n' "$b" "Bluetooth adapter:" "$HAS_BT"
    if (( ${#GPU_NAMES[@]} == 0 )); then
        printf -v b '%s  %-22s %s\n' "$b" "Graphics:" "none detected"
    else
        for g in "${GPU_NAMES[@]}"; do
            printf -v b '%s  %-22s %s\n' "$b" "Graphics:" "$g"
        done
    fi
    say_pre "${b%$'\n'}"
    if [[ $BOOT_MODE == "uefi" && $UEFI_BITS == "32" ]]; then
        die "This machine has 32-bit UEFI firmware, which this installer does not support. Boot the live image in legacy BIOS (CSM) mode instead, if the firmware allows it."
    fi
    if [[ $SECURE_BOOT == "on" ]]; then
        warn "Secure Boot is enabled in your firmware."
        say "This installer does not sign the kernel or bootloader, so the installed system will not boot while Secure Boot is on. Disable Secure Boot in the firmware setup before rebooting into Gentoo (you can set up signing later; see the Gentoo wiki page 'Secure Boot')."
    fi
    if [[ $BOOT_MODE == "bios" ]]; then
        say "The live image was started in legacy BIOS mode. If this computer supports UEFI (almost everything made after 2012 does), consider rebooting the live image in UEFI mode first: it is the more modern and better supported setup. Continuing in BIOS mode works too (GRUB is used)."
    fi
    pause
}

# Print the disk the live image was booted from, so it is never offered.
live_media_disk() {
    local m src pk
    for m in /mnt/cdrom /run/initramfs/live /run/archiso/bootmnt /run/live/medium; do
        src=$(findmnt -no SOURCE "$m" 2>/dev/null || true)
        [[ -n $src && -b $src ]] || continue
        pk=$(lsblk -no PKNAME "$src" 2>/dev/null | head -n1 || true)
        if [[ -n $pk ]]; then echo "/dev/$pk"; else echo "$src"; fi
        return 0
    done
    return 0
}

list_disks() {
    lsblk -dpno NAME,TYPE 2>/dev/null | awk '$2=="disk" {print $1}' \
        | grep -Ev '^/dev/(loop|sr|zram|ram|fd)' || true
}

# part_dev DISK N -> partition device path (handles nvme0n1p1, mmcblk0p1, sda1)
part_dev() {
    if [[ $1 =~ [0-9]$ ]]; then echo "${1}p${2}"; else echo "${1}${2}"; fi
}

lsblk_field() {
    # lsblk_field FIELD DEVICE
    lsblk -dno "$1" "$2" 2>/dev/null | head -n1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true
}
