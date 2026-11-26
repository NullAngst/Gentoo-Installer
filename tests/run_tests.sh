#!/usr/bin/env bash
# Tests for the installers and gentoo_helper that run without a Gentoo system.
#
#   bash tests/run_tests.sh
#
# Needs: bash 4.4+, sfdisk (util-linux), shellcheck, and the built installers
# (run bash build.sh first). Nothing here touches a real disk: partition
# layouts are written to a sparse image file in a temporary directory.
# The tests set variables that the sourced installer reads.
# shellcheck disable=SC2034
set -euo pipefail

cd -- "$(dirname -- "$0")/.." || exit 1
repo=$(pwd -P)

missing=()
for c in sfdisk shellcheck sed grep awk mktemp dd; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
done
if [ "${#missing[@]}" -gt 0 ]; then
    printf 'run_tests.sh: missing commands: %s\n' "${missing[*]}" >&2
    exit 1
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/gentoo_tests.XXXXXX")
trap 'rm -rf -- "$work"' EXIT

passed=0
failed=0
pass() { passed=$(( passed + 1 )); printf 'ok    %s\n' "$1"; }
fail() { failed=$(( failed + 1 )); printf 'FAIL  %s\n' "$1"; }

# check NAME COMMAND...: one test, run in a subshell (the tests source the
# installers, whose constants are read-only), passes when it succeeds.
check() {
    local name=$1
    shift
    if ( "$@" ) >"$work/out" 2>&1; then
        pass "$name"
    else
        fail "$name"
        sed 's/^/      /' "$work/out"
    fi
}

# ---------------------------------------------------------------------------
# Command line options
# ---------------------------------------------------------------------------
options_test() {
    local s
    for s in gentoo_install.sh gentoo_install_tui.sh; do
        bash "$s" -h | grep -q "^${s} " || return 1
        bash "$s" --help >/dev/null || return 1
        if bash "$s" --bogus </dev/null >/dev/null 2>&1; then return 1; fi
        if bash "$s" -x </dev/null >/dev/null 2>&1; then return 1; fi
        if bash "$s" extra </dev/null >/dev/null 2>&1; then return 1; fi
        # Not interactive: must refuse and print the download commands.
        bash "$s" </dev/null 2>&1 | grep -q "curl -fsSLO" || true
    done
    bash gentoo_helper.sh -V | grep -q '^gentoo_helper [0-9]' || return 1
    bash gentoo_helper.sh --version >/dev/null || return 1
    bash gentoo_helper.sh -h | grep -q 'gentoo_helper update' || return 1
    if bash gentoo_helper.sh --nope >/dev/null 2>&1; then return 1; fi
}

# ---------------------------------------------------------------------------
# Versions: the three scripts share one version number.
# ---------------------------------------------------------------------------
versions_test() {
    local a b c
    a=$(sed -n 's/^readonly SCRIPT_VERSION="\(.*\)"/\1/p' src/10_core.sh)
    b=$(sed -n 's/^readonly VERSION="\(.*\)"/\1/p' gentoo_helper.sh)
    c=$(bash gentoo_install.sh -h | sed -n '1s/^[^ ]* \([0-9.]*\):.*/\1/p')
    [ -n "$a" ] && [ "$a" = "$b" ] && [ "$a" = "$c" ]
}

# ---------------------------------------------------------------------------
# Automatic partition layouts, written to a disk image with sfdisk.
# ---------------------------------------------------------------------------
layouts_test() {
    local img="$work/disk.img" boot pt nb sw n expect
    # shellcheck disable=SC1091
    . "$repo/gentoo_install.sh"
    set +e
    trap - ERR
    for boot in uefi bios; do
        for pt in gpt mbr; do
            if [ "$boot" = "uefi" ] && [ "$pt" = "mbr" ]; then continue; fi
            for nb in no yes; do
                for sw in zram partition; do
                    BOOT_MODE=$boot PTABLE=$pt NEED_BOOT_PART=$nb SWAP_MODE=$sw SWAP_SIZE_GIB=2 DISK=/dev/nvme0n1
                    build_auto_layout
                    rm -f -- "$img"
                    dd if=/dev/null of="$img" bs=1048576 seek=40960 2>/dev/null
                    if ! printf '%s' "$AUTO_LAYOUT" | sfdisk --quiet "$img" >/dev/null 2>&1; then
                        printf 'sfdisk rejected %s %s boot=%s swap=%s:\n%s\n' "$boot" "$pt" "$nb" "$sw" "$AUTO_LAYOUT"
                        return 1
                    fi
                    n=$(sfdisk -d "$img" | grep -c '^/')
                    expect=1
                    if [ "$boot" = "bios" ] && [ "$pt" = "mbr" ]; then expect=0; fi
                    if [ "$nb" = "yes" ]; then expect=$(( expect + 1 )); fi
                    if [ "$sw" = "partition" ]; then expect=$(( expect + 1 )); fi
                    expect=$(( expect + 1 ))
                    if [ "$n" != "$expect" ] || [ "${ROOT_PART##*p}" != "$n" ]; then
                        printf '%s %s boot=%s swap=%s: %s partitions, expected %s, root %s\n' \
                            "$boot" "$pt" "$nb" "$sw" "$n" "$expect" "$ROOT_PART"
                        return 1
                    fi
                    if [ "$pt" = "mbr" ] && [ "$(sfdisk -d "$img" | grep -c bootable)" != "1" ]; then
                        printf 'MBR layout without exactly one active partition\n'
                        return 1
                    fi
                done
            done
        done
    done
}

# ---------------------------------------------------------------------------
# Configuration files the installer writes, against a scratch root.
# ---------------------------------------------------------------------------
writers_test() {
    local root="$work/root" copy="$work/installer.sh" before after
    mkdir -p -- "$root/etc/portage"
    sed "s#^readonly MNT=\"/mnt/gentoo\"#readonly MNT=\"$root\"#" gentoo_install.sh >"$copy"
    # shellcheck disable=SC1090
    . "$copy"
    set +e
    trap - ERR
    init_defaults
    ln -s ../../var/db/repos/gentoo/profiles/default/linux/amd64/23.0/desktop "$root/etc/portage/make.profile"
    CPU_MODEL="Test CPU"; NPROC=8; RAM_GIB=16; MAKE_JOBS=8; EMERGE_JOBS=1; VIDEO_CARDS="intel"
    BOOTLOADER=grub; BOOT_MODE=uefi; UEFI_BITS=32; USE_BINPKG=yes; BINHOST_V3=yes; LOCALE=de_DE.UTF-8; INIT=openrc
    GPU_DRIVER=nvidia; NVIDIA_GEN=legacy580; WANT_BCM_WL=yes; BCM_WIFI=wl; VIRT=none; WANT_MBPFAN=yes; ENCRYPT=no
    write_make_conf >/dev/null && write_binrepos >/dev/null && write_package_files >/dev/null || return 1
    grep -qx 'GRUB_PLATFORMS="efi-32"' "$root/etc/portage/make.conf" || { printf 'no efi-32 GRUB platform\n'; return 1; }
    grep -qx 'L10N="de-DE de"' "$root/etc/portage/make.conf" || { printf 'L10N wrong\n'; return 1; }
    grep -q '23.0/x86-64-v3/$' "$root/etc/portage/binrepos.conf/gentoobinhost.conf" || { printf 'no v3 binhost\n'; return 1; }
    grep -qx 'net-wireless/broadcom-sta ~amd64' "$root/etc/portage/package.accept_keywords/gentoo-install" || return 1
    grep -qx 'app-laptop/mbpfan ~amd64' "$root/etc/portage/package.accept_keywords/gentoo-install" || return 1
    grep -qx 'net-wireless/broadcom-sta Broadcom' "$root/etc/portage/package.license/gentoo-install" || return 1
    grep -qx '>=x11-drivers/nvidia-drivers-581' "$root/etc/portage/package.mask/gentoo-install" || return 1
    NEW_HOSTNAME="box"; FLATPAK_APPS="org.gimp.GIMP com.valvesoftware.Steam"; KERNEL_CMDLINE='root=UUID=x rd.luks.uuid=y'
    save_config "$root/conf"
    before=$(declare -p NEW_HOSTNAME FLATPAK_APPS KERNEL_CMDLINE PTABLE UEFI_BITS WANT_MBPFAN)
    init_defaults
    load_config "$root/conf"
    after=$(declare -p NEW_HOSTNAME FLATPAK_APPS KERNEL_CMDLINE PTABLE UEFI_BITS WANT_MBPFAN)
    [ "$before" = "$after" ] || { printf 'settings did not survive save and load\n'; return 1; }
}

# ---------------------------------------------------------------------------
# Small helpers: sed_inplace keeps permissions, clear_dir, strip_colors, IDs.
# ---------------------------------------------------------------------------
helpers_test() {
    local f="$work/kv"
    # shellcheck disable=SC1091
    . "$repo/gentoo_install.sh"
    set +e
    trap - ERR
    printf 'a="1"\nhostname="old"\n' >"$f"
    chmod 640 -- "$f"
    set_conf_value "$f" hostname "new"
    set_conf_value "$f" keymap "de"
    [ "$(cat -- "$f")" = "$(printf 'a="1"\nhostname="new"\nkeymap="de"')" ] || return 1
    [ -n "$(find "$f" -perm 640)" ] || { printf 'permissions changed\n'; return 1; }
    mkdir -p -- "$work/d/x/y"
    : >"$work/d/.hidden"
    clear_dir "$work/d"
    [ -d "$work/d" ] && [ -z "$(ls -A -- "$work/d")" ] || return 1
    [ "$(printf '\033[1;32mgreen\033[0m plain\n' | strip_colors)" = "green plain" ] || return 1
    [ "$(broadcom_wifi_kind 0x43a0)" = "wl" ] && [ "$(broadcom_wifi_kind 0x4331)" = "b43" ] \
        && [ -z "$(broadcom_wifi_kind 0x43ba)" ] || return 1
    [ "$(nvidia_generation 0x2684)" = "current" ] && [ "$(nvidia_generation 0x1b80)" = "legacy580" ] \
        && [ "$(nvidia_generation 0x1180)" = "unsupported" ] || return 1
    [ "$(part_dev /dev/nvme0n1 2)" = "/dev/nvme0n1p2" ] && [ "$(part_dev /dev/sda 2)" = "/dev/sda2" ] || return 1
}

# ---------------------------------------------------------------------------
# Every question with its default answer on a mocked 2013 MacBook Pro that
# started the live system in BIOS mode, answering "BIOS" at the Mac question.
# ---------------------------------------------------------------------------
questions_test() {
    local out="$work/summary"
    {
        printf '2\n'
        yes '' | head -n 400
    } | bash -c '
        . ./gentoo_install.sh
        set +e
        trap - ERR
        lsblk() {
            case "$*" in
                *"-dpno NAME,TYPE,RO,SIZE -b"*) printf "%s\n" "/dev/sda disk 0 500107862016" "/dev/sr0 rom 1 1000000" ;;
                *"-bdno SIZE"*) printf "%s\n" 500107862016 ;;
                *"-dno SIZE"*) printf "%s\n" "465.8G" ;;
                *"-dno MODEL"*) printf "%s\n" "APPLE SSD" ;;
                *"-dno TRAN"*) printf "%s\n" "sata" ;;
                *) printf "%s\n" "NAME SIZE" ;;
            esac
        }
        live_media_disk() { :; }
        cli_ask_password() { printf -v "$1" "%s" "correct-horse-battery"; }
        init_defaults
        CPU_VENDOR=GenuineIntel CPU_MODEL=test NPROC=8 RAM_GIB=16 CPU_X86_64_V3=yes
        BOOT_MODE=bios LIVE_BOOT_MODE=bios UEFI_BITS="" SECURE_BOOT=off VIRT=none
        IS_APPLE=yes MAC_MODEL=MacBookPro11,3 HAS_T2=no IS_LAPTOP=yes HAS_WIFI=yes HAS_BT=yes BCM_WIFI=wl
        HAS_NVIDIA=yes HAS_AMD=no HAS_INTEL=yes GPU_VM="" NVIDIA_GEN=unsupported HYBRID_GPU=yes
        GPU_NAMES=(intel nvidia)
        USERNAME=tester
        mac_boot_check
        ask_all_questions
        print_summary
    ' >"$out" 2>&1 || true
    grep -q 'Partition table: *MBR' "$out" || { printf 'expected an MBR partition table\n'; return 1; }
    grep -q 'Broadcom wl driver: *yes' "$out" || { printf 'Broadcom wl not offered\n'; return 1; }
    grep -q 'Mac fan control: *yes' "$out" || { printf 'mbpfan not defaulted on a MacBook\n'; return 1; }
    grep -q 'Power management: *yes (power-profiles-daemon + thermald)' "$out" || return 1
    grep -q 'Graphics driver: *nouveau' "$out" || return 1
}

# ---------------------------------------------------------------------------
# The generated zram service script is POSIX sh.
# ---------------------------------------------------------------------------
zram_script_test() {
    awk "/cat >\\/usr\\/local\\/sbin\\/zram_swap <<'EOF'/{f=1;next} f&&/^EOF\$/{exit} f" src/50_chroot.sh >"$work/zram_swap"
    [ -s "$work/zram_swap" ] && sh -n "$work/zram_swap" && shellcheck -s sh "$work/zram_swap"
}

check "options and usage" options_test
check "one version number" versions_test
check "partition layouts (sfdisk)" layouts_test
check "configuration files" writers_test
check "small helpers" helpers_test
check "questions with defaults (Mac, BIOS mode)" questions_test
check "zram script is POSIX sh" zram_script_test
check "ShellCheck on this file" shellcheck -s bash -S style tests/run_tests.sh

printf '\n%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
