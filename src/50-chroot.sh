
# ----------------------------------------------------------------------------
# Second stage: runs inside the new system (chroot)
# ----------------------------------------------------------------------------
CHROOT_STEPS=(
    c_sync c_profile c_binhost c_cpuflags c_locale_time c_world c_base_tools
    c_firmware c_system_config c_bootloader_prep c_kernel c_network c_users
    c_desktop c_hardware c_software c_services c_bootloader_final c_finish
)

step_header() {
    local title=$1
    shift
    section "Step ${CURRENT_STEP}: ${title}"
    if (( $# > 0 )); then say "$@"; fi
}

emerge_pkgs() {
    run emerge --verbose --noreplace "$@"
}

# emerge_optional "label" PKG...: failures are recorded but do not stop the install.
emerge_optional() {
    local label=$1
    shift
    if (( $# == 0 )); then return 0; fi
    if run emerge --verbose --noreplace "$@"; then return 0; fi
    warn "Installing ${label} in one go failed. Trying the packages one at a time."
    local p
    for p in "$@"; do
        if ! run emerge --verbose --noreplace "$p"; then
            warn "Could not install ${p}; skipping it. Details are in ${LOG}."
            echo "$p" >>"$FAILED_PATH"
        fi
    done
    return 0
}

# enable_service [--boot] NAME [ALTERNATIVE_NAME...]
enable_service() {
    local runlevel="default" s unit first
    if [[ ${1:-} == "--boot" ]]; then
        runlevel="boot"
        shift
    fi
    first=${1:-}
    for s in "$@"; do
        if [[ $INIT == "openrc" ]]; then
            if [[ -e /etc/init.d/$s ]]; then
                if rc-update show "$runlevel" 2>/dev/null | grep -Eq "^[[:space:]]*${s}[[:space:]]*\|"; then
                    ok "${s} is already enabled (runlevel ${runlevel})."
                else
                    run rc-update add "$s" "$runlevel"
                fi
                return 0
            fi
        else
            unit=$s
            if [[ $unit != *.* ]]; then unit="${unit}.service"; fi
            if [[ -e /usr/lib/systemd/system/$unit || -e /etc/systemd/system/$unit || -e /lib/systemd/system/$unit ]]; then
                run systemctl enable "$unit"
                return 0
            fi
        fi
    done
    warn "Service '${first}' was not found, so it was not enabled. Check it after the first boot."
    return 0
}

# Set KEY="VALUE" in a simple shell-style config file, adding the line if missing.
set_conf_value() {
    local file=$1 key=$2 value=$3
    touch "$file"
    if grep -q "^${key}=" "$file"; then
        sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$file"
    else
        printf '%s="%s"\n' "$key" "$value" >>"$file"
    fi
}

kernel_present() {
    if [[ $BOOTLOADER == "grub" ]]; then
        compgen -G "/boot/vmlinuz-*" >/dev/null || compgen -G "/boot/kernel-*" >/dev/null
    else
        compgen -G "/efi/loader/entries/*.conf" >/dev/null
    fi
}

c_sync() {
    step_header "Download the Gentoo package repository" \
        "Portage needs a local copy of the Gentoo ebuild repository: the build recipes for every package. emerge-webrsync downloads the latest daily snapshot and verifies its PGP signature before unpacking it into /var/db/repos/gentoo." \
        "A warning that /var/db/repos/gentoo is missing or empty is normal on a fresh system."
    mkdir -p /var/db/repos/gentoo
    run emerge-webrsync
}

c_profile() {
    step_header "Select the system profile" \
        "A profile provides sensible default USE flags and settings for a type of system (desktop, a specific desktop environment, systemd or OpenRC). Using the matching profile is what lets Gentoo's binary packages fit your system."
    local cur ver target
    cur=$(readlink /etc/portage/make.profile 2>/dev/null || true)
    ver=$(grep -Eo 'amd64/[0-9]+\.[0-9]+' <<<"$cur" | head -n1 | cut -d/ -f2 || true)
    if [[ -z $ver ]]; then
        ver=$(eselect profile list | grep '(stable)' | grep -Eo 'default/linux/amd64/[0-9]+\.[0-9]+' | sort -Vu | tail -n1 | cut -d/ -f4 || true)
    fi
    [[ -n $ver ]] || die "Could not determine the current profile version. Check 'eselect profile list'."
    target="default/linux/amd64/${ver}${PROFILE_SUFFIX}"
    info "Selecting profile: ${target}"
    if ! eselect profile list | grep -Eq "[[:space:]]${target//./\\.}([[:space:]]|\$)"; then
        die "Profile ${target} does not exist in this repository snapshot. Run 'eselect profile list' in the chroot to see the available ones."
    fi
    run eselect profile set "$target"
    run eselect profile show
}

c_binhost() {
    if [[ $USE_BINPKG != "yes" ]]; then
        info "Binary packages are disabled; skipping."
        return 0
    fi
    step_header "Set up Gentoo's binary package host" \
        "getuto creates the keyring Portage uses to check the PGP signature of every binary package before installing it. Unsigned or tampered packages are refused."
    run getuto
    info "Binary package sources:"
    sed 's/^/    /' /etc/portage/binrepos.conf/gentoobinhost.conf
}

c_cpuflags() {
    if [[ $TUNE_CPU_FLAGS != "yes" ]]; then
        info "Keeping the profile's default CPU_FLAGS_X86 (as chosen); skipping detection."
        return 0
    fi
    step_header "Detect this CPU's instruction set flags" \
        "cpuid2cpuflags asks the CPU which instruction set extensions it supports. The result is saved as CPU_FLAGS_X86 so packages can use them."
    run emerge --verbose --oneshot --noreplace app-portage/cpuid2cpuflags
    local flags
    flags=$(cpuid2cpuflags)
    mkdir -p /etc/portage/package.use
    printf '# Detected by cpuid2cpuflags (gentoo-install.sh)\n*/* %s\n' "$flags" >/etc/portage/package.use/00cpu-flags
    ok "$flags"
}

c_locale_time() {
    step_header "Timezone and language" \
        "Sets the timezone (${TIMEZONE}) and generates the locale (${LOCALE}) so that programs show the right time, language and number formats."
    if [[ -f /usr/share/zoneinfo/$TIMEZONE ]]; then
        run ln -sf "../usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
    else
        warn "Timezone '${TIMEZONE}' does not exist; using UTC. Change it later with: ln -sf ../usr/share/zoneinfo/Region/City /etc/localtime"
        run ln -sf ../usr/share/zoneinfo/UTC /etc/localtime
    fi
    local line
    line=$(grep -m1 "^${LOCALE} " /usr/share/i18n/SUPPORTED || true)
    if [[ -z $line ]]; then
        warn "Locale ${LOCALE} is not supported; using en_US.UTF-8."
        LOCALE="en_US.UTF-8"
        line="en_US.UTF-8 UTF-8"
    fi
    {
        echo "# Locales to generate. Written by gentoo-install.sh. Run locale-gen after editing."
        echo "$line"
        if [[ $LOCALE != "en_US.UTF-8" ]]; then echo "en_US.UTF-8 UTF-8"; fi
    } >/etc/locale.gen
    run locale-gen
    if ! run eselect locale set "${LOCALE/.UTF-8/.utf8}"; then
        warn "eselect could not set the locale; set it later with 'eselect locale list' and 'eselect locale set'."
    fi
    if [[ $INIT == "systemd" ]]; then
        printf 'LANG=%s\n' "$LOCALE" >/etc/locale.conf
    fi
    run env-update
    safe_source /etc/profile
}

c_world() {
    step_header "Update the base system" \
        "emerge now brings every installed package in line with the selected profile, USE flags and compiler settings (emerge --update --deep --newuse @world). With binary packages much of this is downloading; anything without a matching binary is compiled. This can take from a few minutes to over an hour."
    run emerge --verbose --update --deep --newuse @world
}

c_base_tools() {
    step_header "Install system tools" \
        "Installs the tools a working Gentoo system needs: Portage helpers (gentoolkit, eclean-kernel), hardware listing (lspci, lsusb), filesystem tools for your disks, and $( [[ $INIT == openrc ]] && echo "a system logger, cron and time synchronisation (sysklogd, cronie, chrony)" || echo "shell completion" ). They are installed before the kernel so the initramfs can include what it needs."
    local -a pkgs=(app-portage/gentoolkit app-admin/eclean-kernel sys-apps/pciutils sys-apps/usbutils
                   app-shells/bash-completion sys-apps/plocate app-arch/unzip)
    if [[ $BOOT_MODE == "uefi" ]]; then pkgs+=(sys-fs/dosfstools sys-boot/efibootmgr); fi
    case "$FS" in
        xfs) pkgs+=(sys-fs/xfsprogs) ;;
        btrfs) pkgs+=(sys-fs/btrfs-progs) ;;
    esac
    if [[ $ENCRYPT == "yes" ]]; then pkgs+=(sys-fs/cryptsetup); fi
    if [[ $INIT == "openrc" ]]; then pkgs+=(app-admin/sysklogd sys-process/cronie net-misc/chrony); fi
    if [[ $WANT_SSH == "yes" ]]; then pkgs+=(net-misc/openssh); fi
    if [[ $PRIV_TOOL == "doas" ]]; then pkgs+=(app-admin/doas); else pkgs+=(app-admin/sudo); fi
    emerge_pkgs "${pkgs[@]}"
}

c_firmware() {
    if [[ $VIRT != "none" ]]; then
        info "Virtual machine detected: device firmware and CPU microcode are not needed; skipping."
        return 0
    fi
    step_header "Install firmware and CPU microcode" \
        "Many devices (Wi-Fi, GPUs, Bluetooth, audio) need firmware files loaded by the kernel. linux-firmware provides them. CPU microcode updates fix CPU bugs and security issues; AMD microcode is part of linux-firmware, Intel's is a separate package."
    local -a pkgs=(sys-kernel/linux-firmware)
    if [[ $CPU_VENDOR == "GenuineIntel" ]]; then
        pkgs+=(sys-firmware/intel-microcode sys-firmware/sof-firmware)
    fi
    emerge_pkgs "${pkgs[@]}"
}

c_system_config() {
    step_header "Basic system configuration" \
        "Hostname, keyboard layout and machine ID."
    echo "$NEW_HOSTNAME" >/etc/hostname
    if [[ $INIT == "openrc" ]]; then
        set_conf_value /etc/conf.d/hostname hostname "$NEW_HOSTNAME"
        set_conf_value /etc/conf.d/keymaps keymap "$KEYMAP"
    else
        printf 'KEYMAP=%s\n' "$KEYMAP" >/etc/vconsole.conf
    fi
    if ! grep -qE "[[:space:]]${NEW_HOSTNAME}([[:space:]]|\$)" /etc/hosts; then
        printf '127.0.1.1\t%s\n' "$NEW_HOSTNAME" >>/etc/hosts
    fi
    if [[ $DE != "none" && ( $XKB_LAYOUT != "us" || -n $XKB_VARIANT ) ]]; then
        mkdir -p /etc/X11/xorg.conf.d
        {
            echo "# Keyboard layout for X11 sessions. Written by gentoo-install.sh"
            echo 'Section "InputClass"'
            echo '    Identifier "system-keyboard"'
            echo '    MatchIsKeyboard "on"'
            echo "    Option \"XkbLayout\" \"${XKB_LAYOUT}\""
            if [[ -n $XKB_VARIANT ]]; then echo "    Option \"XkbVariant\" \"${XKB_VARIANT}\""; fi
            echo 'EndSection'
        } >/etc/X11/xorg.conf.d/00-keyboard.conf
    fi
    if [[ ! -s /etc/machine-id ]]; then
        if have systemd-machine-id-setup; then
            run systemd-machine-id-setup
        elif have dbus-uuidgen; then
            run dbus-uuidgen --ensure=/etc/machine-id
        else
            tr -d '-' </proc/sys/kernel/random/uuid >/etc/machine-id
        fi
    fi
    ok "Hostname ${NEW_HOSTNAME}, console keymap ${KEYMAP}."
}

c_bootloader_prep() {
    if [[ $BOOTLOADER == "grub" ]]; then
        step_header "Install the GRUB bootloader" \
            "GRUB is installed first so that the kernel step can add itself to GRUB's menu automatically."
        local -a pkgs=(sys-boot/grub)
        if [[ $BOOT_MODE == "uefi" ]]; then pkgs+=(sys-boot/efibootmgr); fi
        if [[ $DUAL_BOOT == "yes" ]]; then pkgs+=(sys-boot/os-prober); fi
        emerge_pkgs "${pkgs[@]}"
        if [[ $BOOT_MODE == "uefi" ]]; then
            local nvram_ok="yes"
            if ! run grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=Gentoo; then
                warn "Could not add a boot entry to the firmware's boot menu (NVRAM). Installing GRUB without it."
                run grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=Gentoo --no-nvram
                nvram_ok="no"
            fi
            if [[ $PART_MODE == "auto" ]] || [[ $nvram_ok == "no" && ! -e /efi/EFI/BOOT/BOOTX64.EFI ]]; then
                info "Also installing GRUB at the fallback path EFI/BOOT/BOOTX64.EFI, which firmware finds even without a boot menu entry."
                run grub-install --target=x86_64-efi --efi-directory=/efi --removable
            elif [[ $nvram_ok == "no" ]]; then
                warn "The firmware boot menu may not list Gentoo. After rebooting, pick EFI/Gentoo/grubx64.efi in the firmware boot menu, or add an entry with efibootmgr."
            fi
        else
            run grub-install --target=i386-pc "$GRUB_DISK"
        fi
        if ! grep -q "gentoo-install.sh" /etc/default/grub; then
            {
                echo ""
                echo "# ---- Added by gentoo-install.sh ----"
                echo "# Extra kernel parameters. root= is added automatically by grub-mkconfig."
                echo "GRUB_CMDLINE_LINUX=\"${GRUB_EXTRA_CMDLINE}\""
                if [[ $DUAL_BOOT == "yes" ]]; then
                    echo "# Look for other operating systems (Windows, other Linux) on every grub-mkconfig run."
                    echo "GRUB_DISABLE_OS_PROBER=false"
                fi
            } >>/etc/default/grub
        fi
    else
        step_header "Install the systemd-boot bootloader" \
            "systemd-boot is installed to the EFI system partition first, so the kernel step can add its boot entries automatically."
        if [[ $INIT == "openrc" ]]; then
            run emerge --verbose --oneshot --update --newuse sys-apps/systemd-utils
        else
            run emerge --verbose --oneshot --update --newuse sys-apps/systemd
        fi
        if ! run bootctl install; then
            warn "bootctl could not update the firmware boot menu; installing without it (the fallback path still works)."
            run bootctl install --graceful
        fi
        mkdir -p /efi/loader
        printf '%s\n' "# systemd-boot menu settings. Written by gentoo-install.sh" "timeout 3" >/efi/loader/loader.conf
    fi
}

c_kernel() {
    step_header "Install the Linux kernel" \
        "Installs sys-kernel/${KERNEL_PKG}. installkernel then builds the initramfs with dracut (a small early-boot system that loads the drivers needed to mount your root filesystem$( [[ $ENCRYPT == yes ]] && echo " and asks for your encryption passphrase" )) and registers the kernel with ${BOOTLOADER}."
    emerge_pkgs sys-kernel/installkernel
    emerge_pkgs "sys-kernel/${KERNEL_PKG}"
    if kernel_present; then
        ok "Kernel installed."
    else
        warn "The kernel was emerged, but no kernel image was found where ${BOOTLOADER} expects it yet. This is checked again at the end."
    fi
}

c_network() {
    step_header "Networking" \
        "Installs ${NET_TOOL} so the new system can connect to the network on its own."
    case "$NET_TOOL" in
        networkmanager) emerge_pkgs net-misc/networkmanager ;;
        dhcpcd) emerge_pkgs net-misc/dhcpcd ;;
        networkd)
            mkdir -p /etc/systemd/network
            printf '%s\n' "# Wired Ethernet via DHCP. Written by gentoo-install.sh" \
                "[Match]" "Name=en* eth*" "" "[Network]" "DHCP=yes" >/etc/systemd/network/20-wired.network
            ok "Wrote /etc/systemd/network/20-wired.network"
            ;;
    esac
}

c_users() {
    step_header "User accounts" \
        "Sets the root password, creates '${USERNAME}' in the wheel group, and allows the wheel group to use ${PRIV_TOOL}."
    if [[ -z $ROOT_HASH || -z $USER_HASH ]]; then
        if id "$USERNAME" >/dev/null 2>&1; then
            info "Accounts were already configured."
            return 0
        fi
        die "The password hashes are missing from ${CONF_PATH}."
    fi
    usermod -p "$ROOT_HASH" root
    ok "root password set."
    if ! id "$USERNAME" >/dev/null 2>&1; then
        run useradd -m -G users,wheel -s /bin/bash "$USERNAME"
    fi
    usermod -p "$USER_HASH" "$USERNAME"
    ok "User ${USERNAME} created and password set."

    if [[ $PRIV_TOOL == "sudo" ]]; then
        mkdir -p /etc/sudoers.d
        printf '%s\n' "# Members of the wheel group may run any command as root. Written by gentoo-install.sh" \
            "%wheel ALL=(ALL:ALL) ALL" >/etc/sudoers.d/10-wheel
        chmod 440 /etc/sudoers.d/10-wheel
        if have visudo && ! visudo -cf /etc/sudoers.d/10-wheel >>"$LOG" 2>&1; then
            rm -f /etc/sudoers.d/10-wheel
            die "The generated sudoers file failed validation."
        fi
        ok "sudo enabled for the wheel group."
    else
        printf '%s\n' "# Members of the wheel group may run commands as root. Written by gentoo-install.sh" \
            "permit :wheel" >/etc/doas.conf
        chmod 600 /etc/doas.conf
        ok "doas enabled for the wheel group."
    fi

    # The hashes are no longer needed; remove them from the settings file.
    sed -i -e 's/^declare -g -- ROOT_HASH=.*/declare -g -- ROOT_HASH=""/' \
           -e 's/^declare -g -- USER_HASH=.*/declare -g -- USER_HASH=""/' "$CONF_PATH"
    ROOT_HASH=""
    USER_HASH=""
}

c_desktop() {
    if [[ $DE == "none" ]]; then
        info "No desktop selected; skipping."
        return 0
    fi
    step_header "Install the desktop: $(de_label "$DE")" \
        "This is usually the longest step. Portage resolves several hundred packages; each one is downloaded as a binary when a matching one exists and compiled otherwise. On a slow machine without binary packages this can take many hours."
    local -a pkgs=()
    case "$DE" in
        plasma) pkgs=(kde-plasma/plasma-meta kde-apps/konsole kde-apps/dolphin kde-apps/kate
                      kde-apps/ark kde-apps/okular kde-apps/gwenview) ;;
        gnome) pkgs=(gnome-base/gnome) ;;
        cinnamon) pkgs=(x11-base/xorg-server gnome-extra/cinnamon x11-terms/gnome-terminal) ;;
        xfce) pkgs=(x11-base/xorg-server xfce-base/xfce4-meta x11-terms/xfce4-terminal
                    xfce-extra/xfce4-pulseaudio-plugin) ;;
        mate) pkgs=(x11-base/xorg-server mate-base/mate x11-terms/mate-terminal) ;;
        lxqt) pkgs=(x11-base/xorg-server lxqt-base/lxqt-meta x11-terms/qterminal) ;;
        sway) pkgs=(gui-wm/sway gui-apps/foot gui-apps/wofi gui-apps/mako gui-apps/grim
                    gui-apps/slurp gui-libs/xdg-desktop-portal-wlr) ;;
        i3) pkgs=(x11-base/xorg-server x11-wm/i3 x11-misc/i3status x11-misc/i3lock
                  x11-misc/dmenu x11-terms/alacritty) ;;
    esac
    pkgs+=(media-video/pipewire media-video/wireplumber media-fonts/noto media-fonts/noto-emoji x11-misc/xdg-user-dirs)
    case "$DM" in
        sddm) pkgs+=(x11-misc/sddm) ;;
        gdm) pkgs+=(gnome-base/gdm) ;;
        lightdm) pkgs+=(x11-misc/lightdm x11-misc/lightdm-gtk-greeter) ;;
    esac
    if [[ $INIT == "openrc" && $DM != "none" ]]; then pkgs+=(gui-libs/display-manager-init); fi
    emerge_pkgs "${pkgs[@]}"

    if [[ $INIT == "openrc" && $DE == "gnome" ]]; then
        emerge_optional "openrc-settingsd (GNOME system settings on OpenRC)" app-admin/openrc-settingsd
    fi
    if [[ $INIT == "openrc" && $DM != "none" ]]; then
        set_conf_value /etc/conf.d/display-manager DISPLAYMANAGER "$DM"
        ok "Display manager for OpenRC set to ${DM} in /etc/conf.d/display-manager."
    fi
    if [[ $DM == "lightdm" ]]; then
        mkdir -p /etc/lightdm/lightdm.conf.d
        printf '%s\n' "# Written by gentoo-install.sh" "[Seat:*]" "greeter-session=lightdm-gtk-greeter" \
            >/etc/lightdm/lightdm.conf.d/50-gentoo-install.conf
    fi
    if [[ $DM == "sddm" ]] && getent passwd sddm >/dev/null; then
        usermod -aG video sddm || true
    fi
}

setup_zram() {
    mkdir -p /usr/local/sbin
    cat >/usr/local/sbin/zram-swap <<'EOF'
#!/bin/sh
# Compressed swap in RAM (zram). Installed by gentoo-install.sh.
# Size: equal to RAM, capped at 8 GiB. Memory is only used for pages actually swapped.
case "$1" in
    start)
        modprobe zram 2>/dev/null || true
        [ -e /sys/block/zram0 ] || { echo "zram-swap: zram is not available" >&2; exit 1; }
        grep -q '^/dev/zram0 ' /proc/swaps && exit 0
        mem_kib=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
        cap_kib=$((8 * 1024 * 1024))
        size_kib=$mem_kib
        [ "$size_kib" -gt "$cap_kib" ] && size_kib=$cap_kib
        echo 1 > /sys/block/zram0/reset 2>/dev/null || true
        echo zstd > /sys/block/zram0/comp_algorithm 2>/dev/null || true
        echo "${size_kib}K" > /sys/block/zram0/disksize
        mkswap /dev/zram0 >/dev/null
        swapon -p 100 /dev/zram0
        ;;
    stop)
        swapoff /dev/zram0 2>/dev/null || true
        echo 1 > /sys/block/zram0/reset 2>/dev/null || true
        ;;
    *)
        echo "usage: zram-swap start|stop" >&2
        exit 2
        ;;
esac
EOF
    chmod 755 /usr/local/sbin/zram-swap
    if [[ $INIT == "openrc" ]]; then
        mkdir -p /etc/local.d
        printf '#!/bin/sh\n/usr/local/sbin/zram-swap start\n' >/etc/local.d/zram-swap.start
        printf '#!/bin/sh\n/usr/local/sbin/zram-swap stop\n' >/etc/local.d/zram-swap.stop
        chmod 755 /etc/local.d/zram-swap.start /etc/local.d/zram-swap.stop
    else
        cat >/etc/systemd/system/zram-swap.service <<'EOF'
[Unit]
Description=Compressed swap in RAM (zram)
DefaultDependencies=no
Before=swap.target shutdown.target
Conflicts=shutdown.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/zram-swap start
ExecStop=/usr/local/sbin/zram-swap stop

[Install]
WantedBy=swap.target
EOF
    fi
    ok "zram swap configured."
}

c_hardware() {
    step_header "Drivers and hardware support" \
        "Installs graphics, Bluetooth, printing and virtual machine support as selected, and sets up swap and SSD maintenance."
    if [[ $GPU_DRIVER == "nvidia" ]]; then
        info "Installing the proprietary NVIDIA driver. Its kernel module is built for the installed kernel and rebuilt automatically on kernel updates (USE=dist-kernel)."
        emerge_optional "the NVIDIA driver" x11-drivers/nvidia-drivers
    fi
    local -a pkgs=()
    if [[ $WANT_BT == "yes" ]]; then
        pkgs+=(net-wireless/bluez)
        case "$DE" in
            xfce|mate|lxqt|cinnamon|i3|sway) pkgs+=(net-wireless/blueman) ;;
        esac
    fi
    if [[ $WANT_CUPS == "yes" ]]; then pkgs+=(net-print/cups); fi
    case "$VIRT" in
        kvm)
            pkgs+=(app-emulation/qemu-guest-agent)
            if [[ $DE != "none" ]]; then pkgs+=(app-emulation/spice-vdagent); fi
            ;;
        vmware) pkgs+=(app-emulation/open-vm-tools) ;;
        virtualbox) pkgs+=(app-emulation/virtualbox-guest-additions) ;;
    esac
    emerge_optional "hardware support packages" "${pkgs[@]}"

    if [[ $SWAP_MODE == "zram" ]]; then setup_zram; fi

    if [[ $IS_SSD == "yes" && $INIT == "openrc" ]]; then
        mkdir -p /etc/cron.weekly
        printf '%s\n' "#!/bin/sh" "# Tell the SSD which blocks are free (TRIM). Written by gentoo-install.sh" \
            "fstrim --all --quiet" >/etc/cron.weekly/fstrim
        chmod 755 /etc/cron.weekly/fstrim
        ok "Weekly SSD TRIM scheduled (cron)."
    fi
}

c_software() {
    if [[ -z $EXTRA_PKGS && $WANT_FLATPAK != "yes" ]]; then
        info "No additional software selected; skipping."
        return 0
    fi
    step_header "Install your selected applications" \
        "Optional software. If a package fails to install, it is skipped and listed at the end; the rest of the system is not affected."
    if [[ -n $EXTRA_PKGS ]]; then
        local -a extra=()
        read -ra extra <<<"$EXTRA_PKGS"
        emerge_optional "the selected native packages" "${extra[@]}"
    fi
    if [[ $WANT_FLATPAK != "yes" ]]; then return 0; fi

    emerge_optional "Flatpak" sys-apps/flatpak
    if ! have flatpak; then
        warn "Flatpak could not be installed; skipping Flathub apps."
        return 0
    fi
    local -a apps=()
    read -ra apps <<<"$FLATPAK_APPS"
    mkdir -p /usr/local/sbin
    {
        echo "#!/bin/sh"
        echo "# Adds Flathub and installs the Flatpak apps chosen during installation."
        echo "# Written by gentoo-install.sh. Safe to run again."
        echo "set -e"
        echo "flatpak remote-add --if-not-exists flathub ${FLATHUB_URL}"
        if (( ${#apps[@]} > 0 )); then echo "flatpak install -y --noninteractive flathub ${apps[*]}"; fi
    } >/usr/local/sbin/install-my-flatpaks
    chmod 755 /usr/local/sbin/install-my-flatpaks

    if ! run flatpak remote-add --if-not-exists flathub "$FLATHUB_URL"; then
        warn "Could not add Flathub inside the installer. Run '${PRIV_TOOL} /usr/local/sbin/install-my-flatpaks' after the first boot."
        touch /root/.gentoo-install-flatpak-pending
        return 0
    fi
    if (( ${#apps[@]} > 0 )); then
        info "Installing Flatpak apps: ${apps[*]} (large downloads; the first app also pulls in its runtime)."
        if ! run flatpak install -y --noninteractive flathub "${apps[@]}"; then
            warn "Some Flatpak apps could not be installed inside the installer. Run '${PRIV_TOOL} /usr/local/sbin/install-my-flatpaks' after the first boot."
            touch /root/.gentoo-install-flatpak-pending
        fi
    fi
}

c_services() {
    step_header "Enable services" \
        "Services are programs that start at boot and run in the background (networking, login screen, logging and so on). This step turns on the ones this system needs."
    if [[ $INIT == "systemd" ]]; then
        run systemctl preset-all --preset-mode=enable-only
        enable_service systemd-timesyncd
    else
        enable_service sysklogd
        enable_service cronie
        enable_service chronyd
    fi

    case "$NET_TOOL" in
        networkmanager) enable_service NetworkManager ;;
        dhcpcd) enable_service dhcpcd ;;
        networkd)
            enable_service systemd-networkd
            enable_service systemd-resolved
            ;;
    esac

    if [[ $DE != "none" && $INIT == "openrc" ]]; then
        enable_service dbus
        enable_service --boot elogind
        if [[ $DE == "gnome" ]]; then enable_service openrc-settingsd; fi
    fi
    if [[ $DM != "none" ]]; then
        if [[ $INIT == "openrc" ]]; then enable_service display-manager; else enable_service "$DM"; fi
    fi
    if [[ $WANT_BT == "yes" ]]; then enable_service bluetooth; fi
    if [[ $WANT_CUPS == "yes" ]]; then
        if [[ $INIT == "openrc" ]]; then enable_service cupsd; else enable_service cups.socket cups; fi
    fi
    if [[ $WANT_SSH == "yes" ]]; then enable_service sshd; fi
    case "$VIRT" in
        kvm)
            enable_service qemu-guest-agent qemu-ga
            if [[ $DE != "none" ]]; then enable_service spice-vdagentd spice-vdagent; fi
            ;;
        vmware) enable_service vmtoolsd vmware-tools open-vm-tools ;;
        virtualbox) enable_service virtualbox-guest-additions vboxservice ;;
    esac
    if [[ $SWAP_MODE == "zram" ]]; then
        if [[ $INIT == "openrc" ]]; then enable_service local; else enable_service zram-swap; fi
    fi
    if [[ $IS_SSD == "yes" && $INIT == "systemd" ]]; then enable_service fstrim.timer; fi

    if [[ $INIT == "systemd" && $DE != "none" ]]; then
        info "Enabling PipeWire audio for all users (systemd user services)."
        if ! run systemctl --global enable pipewire.socket pipewire-pulse.socket; then
            warn "Could not enable the PipeWire sockets globally."
        fi
        if ! run systemctl --global --force enable wireplumber.service; then
            warn "Could not enable WirePlumber globally."
        fi
    fi
}

c_bootloader_final() {
    step_header "Finish the bootloader configuration" \
        "Regenerates the boot menu now that everything is installed and checks that the kernel is in it."
    if [[ $BOOTLOADER == "grub" ]]; then
        run grub-mkconfig -o /boot/grub/grub.cfg
        if ! grep -Eq '^[[:space:]]*linux[[:space:]]' /boot/grub/grub.cfg; then
            warn "The GRUB menu has no Linux entry. Reinstalling the kernel and trying again."
            run emerge --config "sys-kernel/${KERNEL_PKG}"
            run grub-mkconfig -o /boot/grub/grub.cfg
            if ! grep -Eq '^[[:space:]]*linux[[:space:]]' /boot/grub/grub.cfg; then
                die "GRUB still has no kernel entry. The system would not boot; see ${LOG}."
            fi
        fi
        ok "GRUB menu written to /boot/grub/grub.cfg."
    else
        if ! compgen -G "/efi/loader/entries/*.conf" >/dev/null; then
            warn "No systemd-boot entry exists yet. Reinstalling the kernel to create one."
            run emerge --config "sys-kernel/${KERNEL_PKG}"
            if ! compgen -G "/efi/loader/entries/*.conf" >/dev/null; then
                die "No systemd-boot entries were created. The system would not boot; see ${LOG}."
            fi
        fi
        ok "systemd-boot entries:"
        find /efi/loader/entries -name '*.conf' -printf '    %f\n'
    fi
}

setup_user_desktop() {
    local home="/home/${USERNAME}" cfg flag=""
    case "$DE" in
        sway)
            cfg="$home/.config/sway/config"
            if [[ ! -f $cfg && -f /etc/sway/config ]]; then
                mkdir -p "$home/.config/sway"
                cp /etc/sway/config "$cfg"
                # shellcheck disable=SC2016  # $menu is a Sway variable, not a shell one
                sed -i 's/^set \$menu .*/set $menu wofi --show drun/' "$cfg"
                {
                    echo ""
                    echo "# ---- Added by gentoo-install.sh ----"
                    if [[ $XKB_LAYOUT != "us" || -n $XKB_VARIANT ]]; then
                        echo "input type:keyboard {"
                        echo "    xkb_layout ${XKB_LAYOUT}"
                        if [[ -n $XKB_VARIANT ]]; then echo "    xkb_variant ${XKB_VARIANT}"; fi
                        echo "}"
                    fi
                    echo "# Notifications"
                    echo "exec mako"
                    if [[ $INIT == "openrc" ]]; then
                        echo "# OpenRC has no per-user service manager, so start PipeWire (audio) here."
                        echo "exec gentoo-pipewire-launcher"
                    fi
                } >>"$cfg"
            fi
            if [[ $SWAY_AUTOSTART == "yes" ]] && ! grep -q "exec sway" "$home/.bash_profile" 2>/dev/null; then
                if [[ $GPU_DRIVER == "nvidia" ]]; then flag=" --unsupported-gpu"; fi
                {
                    echo ""
                    echo "# Start Sway after logging in on the first console (tty1)."
                    echo "# Added by gentoo-install.sh. Delete these lines to turn it off."
                    echo "if [ -z \"\${WAYLAND_DISPLAY:-}\" ] && [ \"\$(tty)\" = \"/dev/tty1\" ]; then"
                    echo "    exec sway${flag}"
                    echo "fi"
                } >>"$home/.bash_profile"
            fi
            ;;
        i3)
            cfg="$home/.config/i3/config"
            if [[ ! -f $cfg && -f /etc/i3/config ]]; then
                mkdir -p "$home/.config/i3"
                cp /etc/i3/config "$cfg"
                if [[ $INIT == "openrc" ]]; then
                    {
                        echo ""
                        echo "# ---- Added by gentoo-install.sh ----"
                        echo "# OpenRC has no per-user service manager, so start PipeWire (audio) here."
                        echo "exec --no-startup-id gentoo-pipewire-launcher"
                    } >>"$cfg"
                fi
            fi
            ;;
    esac
    if [[ -d $home ]]; then chown -R "${USERNAME}:" "$home"; fi
}

write_notes() {
    local f="/root/${NOTES_NAME}" profile
    profile=$(eselect profile show 2>/dev/null | tail -n1 | sed 's/^[[:space:]]*//' || true)
    {
        cat <<EOF
Gentoo post-install notes
=========================
Written by gentoo-install.sh ${SCRIPT_VERSION} on $(date -u '+%Y-%m-%d').

Your system
-----------
  Desktop:           $(de_label "$DE")
  Init system:       ${INIT}
  Profile:           ${profile}
  Kernel:            sys-kernel/${KERNEL_PKG} (distribution kernel)
  Bootloader:        ${BOOTLOADER} (${BOOT_MODE^^})
  Root filesystem:   ${FS}$( [[ $ENCRYPT == yes ]] && echo " on LUKS2 encryption" )
  Compiler flags:    -march=native -O2 -pipe
  MAKEOPTS:          -j${MAKE_JOBS} -l${NPROC}
  Binary packages:   ${USE_BINPKG}
  Portage config:    /etc/portage/make.conf (every setting is explained in comments)
  Install logs:      /var/log/gentoo-install.log and /var/log/gentoo-install-live.log

Updating
--------
Gentoo is a rolling release. Updating every week or two keeps each update small.

  emaint sync -a            # fetch the latest package repository
  emerge -avuDN @world      # update everything; review the list, then answer y
  emerge -a --depclean      # remove packages that nothing needs anymore
  eselect news read         # Gentoo announces required manual steps here
  dispatch-conf             # merge updated configuration files when emerge asks

If emerge stops because of a USE flag or keyword conflict, read its message
carefully: it usually names the exact line to add under /etc/portage/.
The Gentoo wiki (wiki.gentoo.org) and forums (forums.gentoo.org) cover most cases.

Kernels
-------
New kernels arrive with normal world updates and are installed and added to the
boot menu automatically (installkernel + dracut). Old kernels stay until you run
'emerge -a --depclean'; after that, 'eclean-kernel -n 3' keeps the three newest.

Installing software
-------------------
  emerge --search <name>          # search packages
  emerge -av <category/package>   # install one
  equery uses <package>           # show a package's USE flags (gentoolkit)
EOF
        if [[ $NET_TOOL == "networkmanager" ]]; then
            printf '\nNetworking\n----------\nNetworkManager is enabled. Connect to Wi-Fi from the desktop network icon, or\nin a terminal with: nmtui\n'
        fi
        if [[ $WANT_FLATPAK == "yes" ]]; then
            printf '\nFlatpak\n-------\n  flatpak search <name>\n  flatpak install flathub <app-id>\n  flatpak update            # Flatpaks update separately from emerge\n'
            if [[ -e /root/.gentoo-install-flatpak-pending ]]; then
                printf '\nYour chosen Flatpak apps were not (all) installed during setup. After the first\nboot, connected to the internet, run:  %s /usr/local/sbin/install-my-flatpaks\n' "$PRIV_TOOL"
            fi
        fi
        if [[ $DE == "sway" ]]; then
            printf '\nSway\n----\nSuper+Enter opens a terminal (foot), Super+d the app launcher (wofi),\nSuper+Shift+e exits. Your config: ~/.config/sway/config (man 5 sway).\n'
        fi
        if [[ $DE == "i3" ]]; then
            # shellcheck disable=SC2016  # $mod is an i3 variable, not a shell one
            printf '\ni3\n--\nAlt+Enter opens a terminal, Alt+d the launcher (dmenu), Alt+Shift+e exits.\nYour config: ~/.config/i3/config. Change "set $mod Mod1" to Mod4 for the Super key.\n'
        fi
        if [[ $DE == "gnome" && $INIT == "openrc" ]]; then
            printf '\nGNOME on OpenRC\n---------------\nGNOME is developed against systemd. If a Settings panel does not work, check the\nGentoo wiki page "GNOME" for the OpenRC notes.\n'
        fi
        if [[ $GPU_DRIVER == "nvidia" ]]; then
            printf '\nNVIDIA\n------\nThe proprietary driver is rebuilt automatically when the kernel updates.\nnvidia_drm.modeset=1 is set on the kernel command line (needed for Wayland).\nCards from the GTX 10 series and older may need an older driver branch; see the\nGentoo wiki page "NVIDIA/nvidia-drivers".\n'
        fi
        if [[ $DUAL_BOOT == "yes" ]]; then
            printf '\nDual boot\n---------\n'
            if [[ $BOOTLOADER == "grub" ]]; then
                printf 'GRUB runs os-prober to add other systems to its menu. If one is missing,\nrun: grub-mkconfig -o /boot/grub/grub.cfg\n'
            else
                printf 'systemd-boot lists Windows automatically if its boot loader is on the same\nEFI system partition. Other systems need a loader entry; see man loader.conf.\n'
            fi
            printf 'Windows keeps the hardware clock in local time, Linux in UTC. If the clock is\nwrong after switching systems, set Windows to use UTC (search "RealTimeIsUniversal").\n'
        fi
        printf '\nMoving this disk to another computer\n------------------------------------\nThe system is built for this CPU (-march=native) with a host-only initramfs.\nBefore moving the disk, change -march=native to a generic value such as\n-march=x86-64-v2 in make.conf, rebuild (emerge -e @world), set hostonly="no" in\n/etc/dracut.conf.d/10-gentoo-install.conf and run: emerge --config sys-kernel/%s\n' "$KERNEL_PKG"
        if [[ -s $FAILED_PATH ]]; then
            printf '\nOptional packages that failed to install\n----------------------------------------\n'
            sed 's/^/  /' "$FAILED_PATH"
            printf 'Try again with: emerge --ask <package> and read the error message.\n'
        fi
    } >"$f"
    if id "$USERNAME" >/dev/null 2>&1 && [[ -d /home/$USERNAME ]]; then
        cp "$f" "/home/${USERNAME}/${NOTES_NAME}"
        chown "${USERNAME}:" "/home/${USERNAME}/${NOTES_NAME}"
    fi
    ok "Wrote ${f}"
}

c_finish() {
    step_header "Final touches" \
        "Adds your user to the groups that give access to audio, video, input devices and printers, writes per-user desktop settings, and saves a guide with next steps."
    local g
    for g in wheel users audio video input usb plugdev pipewire lp lpadmin; do
        if getent group "$g" >/dev/null; then usermod -aG "$g" "$USERNAME"; fi
    done
    ok "${USERNAME} is in groups: $(id -nG "$USERNAME")"
    setup_user_desktop
    write_notes
    local news
    news=$(eselect news count new 2>/dev/null || echo 0)
    if [[ $news =~ ^[0-9]+$ ]] && (( news > 0 )); then
        info "There are ${news} unread Gentoo news items. Read them after booting with: eselect news read"
    fi
}

chroot_stage() {
    IN_CHROOT="yes"
    LOG="$TARGET_LOG"
    mkdir -p "$(dirname "$LOG")"
    touch "$LOG"
    [[ -f $CONF_PATH ]] || die "The settings file ${CONF_PATH} is missing."
    safe_source /etc/profile
    init_defaults
    load_config "$CONF_PATH"
    touch "$PROGRESS_PATH"
    log "chroot stage started"
    local total=${#CHROOT_STEPS[@]} i=0 s
    for s in "${CHROOT_STEPS[@]}"; do
        i=$(( i + 1 ))
        CURRENT_STEP="${i}/${total}"
        if grep -qx "$s" "$PROGRESS_PATH"; then
            info "Step ${CURRENT_STEP} (${s}) was already completed; skipping."
            continue
        fi
        "$s"
        echo "$s" >>"$PROGRESS_PATH"
        ok "Step ${CURRENT_STEP} finished."
    done
}
