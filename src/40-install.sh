
# ----------------------------------------------------------------------------
# Disk preparation
# ----------------------------------------------------------------------------
root_fs_dev() {
    if [[ $ENCRYPT == "yes" ]]; then echo "/dev/mapper/${LUKS_NAME}"; else echo "$ROOT_PART"; fi
}

blk_uuid() {
    blkid -c /dev/null -s UUID -o value "$1" 2>/dev/null || true
}

# Unmount leftovers from an earlier attempt and anything using the target partitions.
release_target() {
    if mountpoint -q "$MNT"; then
        warn "Something is still mounted at ${MNT} (probably an earlier attempt). Unmounting it."
        umount -R "$MNT" 2>/dev/null || umount -lR "$MNT" 2>/dev/null || true
    fi
    if [[ -e /dev/mapper/${LUKS_NAME} ]]; then
        cryptsetup close "$LUKS_NAME" 2>/dev/null || true
    fi
    local -a devs=()
    local p
    if [[ $PART_MODE == "auto" ]]; then
        while read -r p; do devs+=("$p"); done < <(lsblk -lnpo NAME "$DISK" 2>/dev/null | tail -n +2)
    else
        for p in "$ESP_PART" "$BOOT_PART" "$ROOT_PART" "$SWAP_PART"; do
            if [[ -n $p ]]; then devs+=("$p"); fi
        done
    fi
    for p in "${devs[@]}"; do
        swapoff "$p" 2>/dev/null || true
        umount "$p" 2>/dev/null || true
    done
    if [[ $PART_MODE == "auto" ]] && have vgchange; then
        vgchange -an >>"$LOG" 2>&1 || true
    fi
}

# Build the sfdisk script for automatic partitioning (sets AUTO_LAYOUT and the *_PART variables).
build_auto_layout() {
    local layout n=1
    layout="label: gpt"$'\n'
    ESP_PART=""; BIOS_PART=""; BOOT_PART=""; SWAP_PART=""; ROOT_PART=""
    if [[ $BOOT_MODE == "uefi" ]]; then
        layout+="size=${ESP_SIZE_MIB}MiB, type=${GUID_ESP}, name=\"EFI system partition\""$'\n'
        ESP_PART=$(part_dev "$DISK" "$n")
    else
        layout+="size=1MiB, type=${GUID_BIOS}, name=\"BIOS boot\""$'\n'
        BIOS_PART=$(part_dev "$DISK" "$n")
    fi
    n=$(( n + 1 ))
    if [[ $NEED_BOOT_PART == "yes" ]]; then
        layout+="size=${BOOT_SIZE_MIB}MiB, type=${GUID_LINUX}, name=\"Gentoo boot\""$'\n'
        BOOT_PART=$(part_dev "$DISK" "$n")
        n=$(( n + 1 ))
    fi
    if [[ $SWAP_MODE == "partition" ]]; then
        layout+="size=${SWAP_SIZE_GIB}GiB, type=${GUID_SWAP}, name=\"Gentoo swap\""$'\n'
        SWAP_PART=$(part_dev "$DISK" "$n")
        n=$(( n + 1 ))
    fi
    layout+="type=${GUID_LINUX}, name=\"Gentoo root\""$'\n'
    ROOT_PART=$(part_dev "$DISK" "$n")
    AUTO_LAYOUT=$layout
}

auto_partition() {
    build_auto_layout
    info "Removing old filesystem and partition table signatures from ${DISK}."
    local p
    while read -r p; do
        wipefs -af "$p" >>"$LOG" 2>&1 || true
    done < <(lsblk -lnpo NAME,TYPE "$DISK" 2>/dev/null | awk '$2=="part" {print $1}')
    run wipefs -af "$DISK"

    info "Writing the new GPT partition table with sfdisk:"
    printf '%s' "$AUTO_LAYOUT" | sed 's/^/      /'
    printf '%s' "$AUTO_LAYOUT" | run sfdisk --wipe always --wipe-partitions always "$DISK"
    udevadm settle 2>/dev/null || true
    sleep 2

    local tries
    for p in "$ESP_PART" "$BIOS_PART" "$BOOT_PART" "$SWAP_PART" "$ROOT_PART"; do
        [[ -n $p ]] || continue
        tries=0
        while [[ ! -b $p ]]; do
            tries=$(( tries + 1 ))
            if (( tries > 10 )); then die "Partition ${p} did not appear after partitioning."; fi
            partprobe "$DISK" 2>/dev/null || blockdev --rereadpt "$DISK" 2>/dev/null || true
            udevadm settle 2>/dev/null || true
            sleep 1
        done
    done
    ok "Partitions created."
}

format_partitions() {
    if [[ $BOOT_MODE == "uefi" ]]; then
        if [[ $FORMAT_ESP == "yes" ]]; then
            info "Formatting the EFI system partition ${ESP_PART} as FAT32."
            run mkfs.vfat -F 32 -n EFI "$ESP_PART"
        else
            info "Keeping the existing EFI system partition ${ESP_PART} as it is."
        fi
    fi
    if [[ -n $BOOT_PART ]]; then
        info "Formatting ${BOOT_PART} as ext4 for /boot."
        run mkfs.ext4 -F -L gentoo-boot "$BOOT_PART"
    fi
    if [[ -n $SWAP_PART ]]; then
        info "Formatting ${SWAP_PART} as swap."
        run mkswap -L gentoo-swap "$SWAP_PART"
    fi
    if [[ $ENCRYPT == "yes" ]]; then
        info "Encrypting ${ROOT_PART} with LUKS2. The key derivation is slow on purpose (it makes guessing expensive), so this takes a few seconds."
        printf '%s' "$LUKS_PASSWORD" | run cryptsetup luksFormat --type luks2 --batch-mode --key-file=- "$ROOT_PART"
        printf '%s' "$LUKS_PASSWORD" | run cryptsetup open --key-file=- "$ROOT_PART" "$LUKS_NAME"
        LUKS_PASSWORD=""
        ok "Encrypted container opened as /dev/mapper/${LUKS_NAME}."
    fi
    local dev
    dev=$(root_fs_dev)
    info "Creating the ${FS} root filesystem on ${dev}."
    case "$FS" in
        ext4) run mkfs.ext4 -F -L gentoo "$dev" ;;
        xfs) run mkfs.xfs -f -L gentoo "$dev" ;;
        btrfs)
            run mkfs.btrfs -f -L gentoo "$dev"
            mkdir -p "$MNT"
            run mount "$dev" "$MNT"
            run btrfs subvolume create "$MNT/@"
            run btrfs subvolume create "$MNT/@home"
            run umount "$MNT"
            ;;
    esac
}

# Mount the target filesystems (safe to call more than once).
mount_target() {
    mkdir -p "$MNT"
    if [[ $ENCRYPT == "yes" && ! -e /dev/mapper/${LUKS_NAME} ]]; then
        info "Unlocking the encrypted root partition ${ROOT_PART}."
        handoff_screen
        cryptsetup open "$ROOT_PART" "$LUKS_NAME"
    fi
    local dev
    dev=$(root_fs_dev)
    if ! mountpoint -q "$MNT"; then
        if [[ $FS == "btrfs" ]]; then
            run mount -o "${BTRFS_OPTS},subvol=@" "$dev" "$MNT"
        else
            run mount -o noatime "$dev" "$MNT"
        fi
    fi
    if [[ $FS == "btrfs" ]]; then
        mkdir -p "$MNT/home"
        if ! mountpoint -q "$MNT/home"; then run mount -o "${BTRFS_OPTS},subvol=@home" "$dev" "$MNT/home"; fi
    fi
    if [[ -n $BOOT_PART ]]; then
        mkdir -p "$MNT/boot"
        if ! mountpoint -q "$MNT/boot"; then run mount -o noatime "$BOOT_PART" "$MNT/boot"; fi
    fi
    if [[ $BOOT_MODE == "uefi" ]]; then
        mkdir -p "$MNT/efi"
        if ! mountpoint -q "$MNT/efi"; then run mount -o umask=0077 "$ESP_PART" "$MNT/efi"; fi
    fi
    if [[ -n $SWAP_PART ]] && ! grep -q "^${SWAP_PART} " /proc/swaps; then
        swapon "$SWAP_PART" 2>/dev/null || true
    fi
}

prepare_disk() {
    section "Preparing the disk"
    release_target
    if [[ $PART_MODE == "auto" ]]; then
        auto_partition
    fi
    format_partitions
    mount_target
    ok "Filesystems are ready and mounted:"
    lsblk -po NAME,SIZE,FSTYPE,MOUNTPOINT "$DISK" | sed 's/^/    /'
}

# ----------------------------------------------------------------------------
# Stage3
# ----------------------------------------------------------------------------
verify_stage3() {
    local f=$1 sig_ok="no" status gh
    if [[ -s ${f}.asc ]] && have gpg; then
        gh=$(mktemp -d)
        chmod 700 "$gh"
        if [[ -r /usr/share/openpgp-keys/gentoo-release.asc ]]; then
            GNUPGHOME=$gh gpg --batch --quiet --import /usr/share/openpgp-keys/gentoo-release.asc >>"$LOG" 2>&1 || true
        fi
        status=$(GNUPGHOME=$gh gpg --batch --status-fd 1 --verify "${f}.asc" "$f" 2>>"$LOG" || true)
        if ! grep -q '^\[GNUPG:\] VALIDSIG' <<<"$status" && ! grep -q '^\[GNUPG:\] BADSIG' <<<"$status"; then
            info "The signing key is not on this live system; fetching it from gentoo.org (WKD)."
            GNUPGHOME=$gh gpg --batch --auto-key-locate=clear,nodefault,wkd --locate-key releng@gentoo.org >>"$LOG" 2>&1 || true
            status=$(GNUPGHOME=$gh gpg --batch --status-fd 1 --verify "${f}.asc" "$f" 2>>"$LOG" || true)
        fi
        rm -rf "$gh"
        if grep -q '^\[GNUPG:\] BADSIG' <<<"$status"; then
            die "The PGP signature of ${f} is BAD. The file is corrupted or has been tampered with. Aborting."
        fi
        if grep -q '^\[GNUPG:\] VALIDSIG' <<<"$status"; then
            sig_ok="yes"
            ok "PGP signature is valid (signed by Gentoo Release Engineering)."
        fi
    fi

    if [[ -s ${f}.sha256 ]]; then
        local expected actual
        expected=$(grep -Eo '^[0-9a-f]{64}' "${f}.sha256" | head -n1 || true)
        if [[ -n $expected ]]; then
            actual=$(sha256sum "$f" | awk '{print $1}')
            if [[ $expected != "$actual" ]]; then
                die "SHA256 checksum mismatch for ${f}. The download is corrupted. Run the installer again."
            fi
            ok "SHA256 checksum matches."
        else
            warn "Could not read the checksum file; skipping the SHA256 check."
        fi
    fi

    if [[ $sig_ok != "yes" ]]; then
        warn "The PGP signature could not be checked (gpg or the Gentoo signing key is unavailable)."
        say "The file was downloaded over HTTPS from Gentoo's servers, which protects it in transit, but a signature check is the stronger guarantee."
        if ! yesno "Continue without a verified signature?" y; then
            die "Stopped at your request."
        fi
    fi
}

install_stage3() {
    section "Downloading and verifying the Gentoo stage3"
    say "A stage3 is a small but complete Gentoo base system (compiler, Portage, core tools) that everything else is built on. The installer downloads the newest stage3-amd64-${STAGE3_VARIANT}, checks its PGP signature from Gentoo Release Engineering and its SHA256 checksum, then unpacks it onto your new root filesystem."
    local base listing rel url file
    base="${DIST_BASE%/}/releases/amd64/autobuilds"
    listing=$(fetch_text "${base}/latest-stage3-amd64-${STAGE3_VARIANT}.txt") \
        || die "Could not download the stage3 index from ${base}."
    rel=$(grep -Eo '^([0-9]{8}T[0-9]{6}Z/)?stage3-amd64-[a-z0-9-]+\.tar\.xz' <<<"$listing" | head -n1 || true)
    if [[ -z $rel ]]; then
        die "Could not find a stage3 file name in ${base}/latest-stage3-amd64-${STAGE3_VARIANT}.txt. The index format may have changed."
    fi
    if [[ $rel == */* ]]; then
        url="${base}/${rel}"
    else
        url="${base}/current-stage3-amd64-${STAGE3_VARIANT}/${rel}"
    fi
    file=${rel##*/}
    info "Newest stage3: ${file}"
    cd "$MNT"
    fetch "$url" "$file"
    fetch "${url}.asc" "${file}.asc" || warn "Could not download the PGP signature file."
    fetch "${url}.sha256" "${file}.sha256" || warn "Could not download the SHA256 checksum file."
    verify_stage3 "$file"
    info "Unpacking the stage3 into ${MNT}. This takes a minute or two and prints nothing while it works."
    run tar xpf "$file" --xattrs-include='*.*' --numeric-owner -C "$MNT"
    rm -f "$file" "${file}.asc" "${file}.sha256"
    cd /
    ok "Stage3 unpacked."
}

mount_pseudo() {
    info "Mounting /proc, /sys, /dev and /run into the new system."
    if ! mountpoint -q "$MNT/proc"; then run mount --types proc /proc "$MNT/proc"; fi
    if ! mountpoint -q "$MNT/sys"; then
        run mount --rbind /sys "$MNT/sys"
        run mount --make-rslave "$MNT/sys"
    fi
    if ! mountpoint -q "$MNT/dev"; then
        run mount --rbind /dev "$MNT/dev"
        run mount --make-rslave "$MNT/dev"
    fi
    if ! mountpoint -q "$MNT/run"; then
        run mount --bind /run "$MNT/run"
        run mount --make-slave "$MNT/run"
    fi
    cp --dereference /etc/resolv.conf "$MNT/etc/resolv.conf"
}

hash_one_password() {
    if have openssl; then
        printf '%s\n' "$1" | openssl passwd -6 -stdin
    else
        printf '%s\n' "$1" | chroot "$MNT" /usr/bin/openssl passwd -6 -stdin
    fi
}

hash_passwords() {
    info "Hashing the passwords (SHA-512 crypt). The plain text is never written to disk."
    ROOT_HASH=$(hash_one_password "$ROOT_PASSWORD")
    USER_HASH=$(hash_one_password "$USER_PASSWORD")
    # shellcheck disable=SC2016  # '$6$' is the literal SHA-512 crypt prefix
    if [[ $ROOT_HASH != '$6$'* || $USER_HASH != '$6$'* ]]; then
        die "Password hashing failed (openssl did not return a SHA-512 crypt hash)."
    fi
    ROOT_PASSWORD=""
    USER_PASSWORD=""
}

# ----------------------------------------------------------------------------
# Configuration files for the new system (written from the live side)
# ----------------------------------------------------------------------------
profile_version() {
    readlink "$MNT/etc/portage/make.profile" 2>/dev/null | grep -Eo 'amd64/[0-9]+\.[0-9]+' | head -n1 | cut -d/ -f2 || true
}

compute_cmdline() {
    local root_uuid luks_uuid extra=""
    root_uuid=$(blk_uuid "$(root_fs_dev)")
    [[ -n $root_uuid ]] || die "Could not read the UUID of the root filesystem."
    KERNEL_CMDLINE="root=UUID=${root_uuid}"
    if [[ $FS == "btrfs" ]]; then KERNEL_CMDLINE+=" rootflags=subvol=@"; fi
    if [[ $ENCRYPT == "yes" ]]; then
        luks_uuid=$(blk_uuid "$ROOT_PART")
        [[ -n $luks_uuid ]] || die "Could not read the UUID of the LUKS container."
        KERNEL_CMDLINE="rd.luks.uuid=${luks_uuid} ${KERNEL_CMDLINE}"
        extra+=" rd.luks.uuid=${luks_uuid}"
    fi
    if [[ $GPU_DRIVER == "nvidia" ]]; then
        KERNEL_CMDLINE+=" nvidia_drm.modeset=1"
        extra+=" nvidia_drm.modeset=1"
    fi
    GRUB_EXTRA_CMDLINE=$(trim "$extra")
}

write_make_conf() {
    local f="$MNT/etc/portage/make.conf"
    if [[ -f $f && ! -f $f.stage3-original ]]; then cp "$f" "$f.stage3-original"; fi

    local extra=""
    if [[ $BOOTLOADER == "grub" && $BOOT_MODE == "uefi" ]]; then
        extra+=$'\n# GRUB firmware target for this machine.\nGRUB_PLATFORMS="efi-64"\n'
    elif [[ $BOOTLOADER == "grub" ]]; then
        extra+=$'\n# GRUB firmware target for this machine.\nGRUB_PLATFORMS="pc"\n'
    fi
    if [[ $USE_BINPKG == "yes" ]]; then
        extra+=$'\n# Use Gentoo\'s official binary packages when they match this configuration,\n# and require a valid PGP signature on each of them.\n# Remove this line to build everything from source.\nFEATURES="${FEATURES} getbinpkg binpkg-request-signature"\n'
    fi
    if [[ -n $GENTOO_MIRRORS_VALUE ]]; then
        extra+=$'\n# Mirrors chosen with mirrorselect.\nGENTOO_MIRRORS="'"${GENTOO_MIRRORS_VALUE}"$'"\n'
    fi
    local lang region
    lang=${LOCALE%%_*}
    region=${LOCALE#*_}
    region=${region%%.*}
    if [[ ! ( $lang == "en" && $region == "US" ) ]]; then
        extra+=$'\n# Translations to install for packages that offer them (for example LibreOffice, Firefox).\nL10N="'"${lang}-${region} ${lang}"$'"\n'
    fi

    cat >"$f" <<EOF
# /etc/portage/make.conf
# Written by gentoo-install.sh ${SCRIPT_VERSION} on $(date -u '+%Y-%m-%d %H:%M UTC').
# The stage3's original version is saved next to this file as make.conf.stage3-original.
# Reference: man make.conf, https://wiki.gentoo.org/wiki//etc/portage/make.conf

# ---------------------------------------------------------------------------
# Compiler flags
# CPU detected at install time: ${CPU_MODEL}
# -march=native makes GCC target exactly this CPU: every instruction set
# extension it has, plus its tuning model. -O2 is the optimisation level Gentoo
# recommends system wide; -O3 and LTO are not worth the breakage risk globally.
# -pipe keeps temporary compiler files in memory.
# Programs built with these flags may not run on an older or different CPU,
# so do not move this disk to another machine without changing them.
# ---------------------------------------------------------------------------
COMMON_FLAGS="-march=native -O2 -pipe"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
FCFLAGS="\${COMMON_FLAGS}"
FFLAGS="\${COMMON_FLAGS}"
# The Rust compiler's equivalent of -march=native.
RUSTFLAGS="\${RUSTFLAGS} -C target-cpu=native"

# ---------------------------------------------------------------------------
# Parallel builds
# Detected: ${NPROC} CPU threads and about ${RAM_GIB} GiB of RAM.
# Large C++ builds need up to about 2 GiB of RAM per compiler job, so the job
# count is the smaller of the thread count and (RAM in GiB / 2), as the
# Handbook advises. -l stops starting new jobs while the load average is
# already at the thread count.
# ---------------------------------------------------------------------------
MAKEOPTS="-j${MAKE_JOBS} -l${NPROC}"
# How many packages emerge may build or install at the same time. Each one can
# run MAKEOPTS jobs, so this is kept low. If a big build (LLVM, Qt WebEngine,
# Firefox) is killed for lack of memory, set --jobs=1 or lower -j.
EMERGE_DEFAULT_OPTS="--jobs=${EMERGE_JOBS} --load-average=${NPROC}"
# Build at lower CPU priority so the desktop stays responsive during updates.
PORTAGE_NICENESS="10"

# ---------------------------------------------------------------------------
# USE flags
# Almost all USE flags come from the profile (run: eselect profile show).
# Only the minimum is added here, because every global flag that differs from
# the profile means fewer binary packages match and more gets compiled.
# dist-kernel: rebuild kernel modules (such as nvidia-drivers) automatically
# whenever the distribution kernel is updated.
# ---------------------------------------------------------------------------
USE="dist-kernel"

# Graphics drivers for Mesa, Xorg and friends, from the detected hardware.
VIDEO_CARDS="${VIDEO_CARDS}"

# Accept free software licenses plus freely redistributable binaries.
# Exceptions for specific packages are in /etc/portage/package.license/.
ACCEPT_LICENSE="-* @FREE @BINARY-REDISTRIBUTABLE"
${extra}
# Keep build output in English so logs are easy to search and to report.
LC_MESSAGES=C.utf8
EOF
    ok "Wrote /etc/portage/make.conf"
}

write_binrepos() {
    [[ $USE_BINPKG == "yes" ]] || return 0
    local ver dir f
    ver=$(profile_version)
    if [[ -z $ver ]]; then
        warn "Could not determine the profile version from the stage3; assuming 23.0."
        ver="23.0"
    fi
    dir="$MNT/etc/portage/binrepos.conf"
    f="$dir/gentoobinhost.conf"
    mkdir -p "$dir"
    if [[ -f $f && ! -f $dir/gentoobinhost.conf.stage3-original ]]; then
        cp "$f" "$dir/gentoobinhost.conf.stage3-original"
    fi
    {
        echo "# Gentoo's official binary package host."
        echo "# Written by gentoo-install.sh. The higher priority repository is tried first."
        if [[ $BINHOST_V3 == "yes" ]]; then
            echo ""
            echo "# Packages built for x86-64-v3 CPUs (AVX2 generation and newer)."
            echo "[gentoo-x86-64-v3]"
            echo "priority = 9999"
            echo "sync-uri = https://distfiles.gentoo.org/releases/amd64/binpackages/${ver}/x86-64-v3/"
            echo "verify-signature = true"
        fi
        echo ""
        echo "# Packages built for any x86-64 CPU."
        echo "[gentoo]"
        echo "priority = 9959"
        echo "sync-uri = https://distfiles.gentoo.org/releases/amd64/binpackages/${ver}/x86-64/"
        echo "verify-signature = true"
    } >"$f"
    ok "Wrote /etc/portage/binrepos.conf/gentoobinhost.conf"
}

write_package_files() {
    local pu="$MNT/etc/portage/package.use" pl="$MNT/etc/portage/package.license"
    mkdir -p "$pu" "$pl"

    {
        echo "# Written by gentoo-install.sh"
        echo "# installkernel installs new kernels, builds the initramfs with dracut and"
        echo "# updates the bootloader automatically every time a kernel is emerged."
        if [[ $BOOTLOADER == "grub" ]]; then
            echo "sys-kernel/installkernel dracut grub"
        else
            echo "sys-kernel/installkernel dracut systemd systemd-boot"
            if [[ $INIT == "openrc" ]]; then
                echo "# systemd-boot and kernel-install on OpenRC come from systemd-utils."
                echo "sys-apps/systemd-utils boot kernel-install"
            else
                echo "sys-apps/systemd boot"
            fi
        fi
    } >"$pu/installkernel"

    if [[ $ENCRYPT == "yes" && $INIT == "systemd" ]]; then
        printf '%s\n' "# Written by gentoo-install.sh: unlock LUKS in the systemd initramfs." \
            "sys-apps/systemd cryptsetup" >"$pu/luks"
    fi
    if [[ $WANT_FLATPAK == "yes" ]]; then
        printf '%s\n' "# Written by gentoo-install.sh: show Flathub apps in the desktop software centres." \
            "kde-plasma/discover flatpak" \
            "gnome-extra/gnome-software flatpak" >"$pu/flatpak"
    fi

    {
        echo "# Written by gentoo-install.sh: licenses accepted for specific packages."
        echo "sys-kernel/linux-firmware linux-fw-redistributable"
        echo "sys-firmware/intel-microcode intel-ucode"
        if [[ $GPU_DRIVER == "nvidia" ]]; then echo "x11-drivers/nvidia-drivers NVIDIA-r2"; fi
        if [[ " $EXTRA_PKGS " == *" www-client/google-chrome "* ]]; then echo "www-client/google-chrome google-chrome"; fi
    } >"$pl/gentoo-install"
    ok "Wrote package.use and package.license entries"
}

write_fstab() {
    local root_uuid f="$MNT/etc/fstab"
    root_uuid=$(blk_uuid "$(root_fs_dev)")
    [[ -n $root_uuid ]] || die "Could not read the UUID of the root filesystem."
    {
        echo "# /etc/fstab: filesystems mounted at boot. Written by gentoo-install.sh."
        echo "# Devices are referenced by UUID so the entries survive disk renumbering."
        echo "# <filesystem>                             <mountpoint> <type> <options>                       <dump> <pass>"
        case "$FS" in
            ext4) echo "UUID=${root_uuid}  /      ext4   noatime                          0 1" ;;
            xfs) echo "UUID=${root_uuid}  /      xfs    noatime                          0 0" ;;
            btrfs)
                echo "UUID=${root_uuid}  /      btrfs  ${BTRFS_OPTS},subvol=@      0 0"
                echo "UUID=${root_uuid}  /home  btrfs  ${BTRFS_OPTS},subvol=@home  0 0"
                ;;
        esac
        if [[ -n $BOOT_PART ]]; then
            echo "UUID=$(blk_uuid "$BOOT_PART")  /boot  ext4   noatime                          0 2"
        fi
        if [[ $BOOT_MODE == "uefi" ]]; then
            echo "UUID=$(blk_uuid "$ESP_PART")  /efi   vfat   umask=0077,noatime               0 2"
        fi
        if [[ -n $SWAP_PART ]]; then
            echo "UUID=$(blk_uuid "$SWAP_PART")  none   swap   sw                               0 0"
        fi
    } >"$f"
    ok "Wrote /etc/fstab"
    sed 's/^/    /' "$f"
}

write_kernel_config() {
    mkdir -p "$MNT/etc/kernel" "$MNT/etc/dracut.conf.d"
    printf '%s\n' "$KERNEL_CMDLINE" >"$MNT/etc/kernel/cmdline"
    {
        echo "# Written by gentoo-install.sh"
        echo "# Host-only initramfs: contains just the drivers this machine needs (smaller"
        echo "# and faster). If you move this disk to different hardware, set hostonly=\"no\""
        echo "# and run: emerge --config sys-kernel/${KERNEL_PKG}"
        echo 'hostonly="yes"'
        echo "# Kernel command line built into the initramfs. installkernel requires it when"
        echo "# run inside a chroot, and it keeps the system bootable if the bootloader"
        echo "# configuration is ever lost."
        echo "kernel_cmdline=\" ${KERNEL_CMDLINE} \""
        if [[ $ENCRYPT == "yes" ]]; then echo 'add_dracutmodules+=" crypt dm "'; fi
        if [[ $FS == "btrfs" ]]; then echo 'add_dracutmodules+=" btrfs "'; fi
    } >"$MNT/etc/dracut.conf.d/10-gentoo-install.conf"
    ok "Wrote /etc/kernel/cmdline and /etc/dracut.conf.d/10-gentoo-install.conf"
    info "Kernel command line: ${KERNEL_CMDLINE}"
}

save_config() {
    local f=$1 v
    {
        echo "# gentoo-install.sh ${SCRIPT_VERSION} settings, written $(date -u '+%Y-%m-%d %H:%M UTC')."
        echo "# Used by --resume and by the second (chroot) stage."
        for v in "${CONFIG_VARS[@]}"; do
            declare -p "$v" | sed 's/^declare /declare -g /'
        done
    } >"$f"
    chmod 600 "$f"
}

load_config() {
    # shellcheck disable=SC1090
    source "$1"
}

write_target_config() {
    section "Configuring the new system"
    compute_cmdline
    write_make_conf
    write_binrepos
    write_package_files
    write_fstab
    write_kernel_config
    save_config "${MNT}${CONF_PATH}"
    save_config "$LIVE_CONF_COPY"
    install -m 700 "$SELF" "${MNT}${SCRIPT_PATH}"
    : >"${MNT}${PROGRESS_PATH}"
    echo "live_setup" >>"${MNT}${PROGRESS_PATH}"
    ok "The new system is prepared for the chroot stage."
}

# ----------------------------------------------------------------------------
# Chroot stage, finishing, resuming
# ----------------------------------------------------------------------------
run_chroot_stage() {
    section "Entering the new system (chroot)"
    say "From here on the installer runs inside your new Gentoo system (a 'chroot'), exactly like the Handbook's chapter on installing the base system. This is the long part. You can walk away: no more questions are asked." \
        "Output is shown on screen and saved to ${MNT}${TARGET_LOG}."
    if ! chroot "$MNT" /usr/bin/env -i HOME=/root TERM="${TERM:-linux}" /bin/bash "$SCRIPT_PATH" --chroot-stage; then
        echo
        err "The installation stopped inside the new system."
        err "Log: ${MNT}${TARGET_LOG}"
        print_resume_help
        exit 1
    fi
}

unmount_all() {
    sync
    if [[ -n $SWAP_PART ]]; then swapoff "$SWAP_PART" 2>/dev/null || true; fi
    umount -R "$MNT" 2>/dev/null || umount -lR "$MNT" 2>/dev/null || true
    if [[ $ENCRYPT == "yes" && -e /dev/mapper/${LUKS_NAME} ]]; then
        cryptsetup close "$LUKS_NAME" 2>/dev/null || true
    fi
}

finish_install() {
    cp "$LIVE_LOG" "$MNT/var/log/gentoo-install-live.log" 2>/dev/null || true
    if [[ $NET_TOOL == "networkd" ]]; then
        ln -sf ../run/systemd/resolve/stub-resolv.conf "$MNT/etc/resolv.conf"
    fi
    rm -f "$LIVE_CONF_COPY"

    section "Installation complete"
    say "Gentoo is installed. After rebooting, log in as '${USERNAME}'." \
        "A guide with the next steps (updating, reading Gentoo news, managing kernels) was saved as ~/${NOTES_NAME} in your home directory and in /root. Installation logs are in /var/log/gentoo-install.log and /var/log/gentoo-install-live.log."
    if [[ -s "$MNT$FAILED_PATH" ]]; then
        warn "These optional packages could not be installed: $(tr '\n' ' ' <"$MNT$FAILED_PATH")"
        say "The system works without them. Try again after booting with: emerge --ask <package>"
    fi
    if [[ $SECURE_BOOT == "on" ]]; then
        warn "Secure Boot is still enabled. Disable it in the firmware setup, or Gentoo will not boot."
    fi
    if yesno "Unmount the new system now?" y; then
        unmount_all
        ok "Unmounted."
        if yesno "Reboot now? (remove the USB stick or DVD when the screen goes dark)" y; then
            reboot
        fi
    else
        info "Still mounted at ${MNT}. When you are done: umount -R ${MNT}; then reboot."
    fi
}

resume_install() {
    section "Resuming a previous installation"
    local conf="" dev ptype
    if [[ -f ${MNT}${CONF_PATH} ]]; then
        conf="${MNT}${CONF_PATH}"
    elif [[ -f $LIVE_CONF_COPY ]]; then
        conf="$LIVE_CONF_COPY"
    fi
    if [[ -z $conf ]]; then
        say "The new system is not mounted. Choose its root partition so the installer can find its saved settings."
        pick_partition ROOT_PART "Which partition is the root partition of the new Gentoo system?" ""
        ptype=$(blkid -c /dev/null -s TYPE -o value "$ROOT_PART" 2>/dev/null || true)
        dev=$ROOT_PART
        if [[ $ptype == "crypto_LUKS" ]]; then
            if [[ ! -e /dev/mapper/${LUKS_NAME} ]]; then
                info "The partition is encrypted. Enter its passphrase."
                handoff_screen
                cryptsetup open "$ROOT_PART" "$LUKS_NAME"
            fi
            dev="/dev/mapper/${LUKS_NAME}"
        fi
        mkdir -p "$MNT"
        if [[ $(blkid -c /dev/null -s TYPE -o value "$dev" 2>/dev/null || true) == "btrfs" ]]; then
            mount -o "${BTRFS_OPTS},subvol=@" "$dev" "$MNT"
        else
            mount "$dev" "$MNT"
        fi
        conf="${MNT}${CONF_PATH}"
        if [[ ! -f $conf ]]; then
            umount "$MNT" || true
            die "No saved installer settings were found on ${ROOT_PART}. Either it is the wrong partition, or the installation stopped before the new system was prepared; in that case start over with: bash ${SELF}"
        fi
    fi
    load_config "$conf"
    mount_target
    if ! grep -qx "live_setup" "${MNT}${PROGRESS_PATH}" 2>/dev/null; then
        die "The installation stopped before the new system was fully prepared. Please start over with: bash ${SELF}"
    fi
    mount_pseudo
    install -m 700 "$SELF" "${MNT}${SCRIPT_PATH}"
    ok "Settings loaded. Continuing with the steps that have not finished yet."
    ui_install_phase
    run_chroot_stage
    ui_finish_phase
    finish_install
}

fresh_install() {
    live_preflight
    : >"$LOG"
    log "gentoo-install.sh ${SCRIPT_VERSION} started"
    init_defaults
    welcome
    live_keyboard
    network_step
    sync_clock
    detect_hardware
    show_hardware
    while true; do
        ask_all_questions
        print_summary
        if confirm_install; then break; fi
    done
    prepare_disk
    install_stage3
    mount_pseudo
    hash_passwords
    write_target_config
    run_chroot_stage
    finish_install
}
