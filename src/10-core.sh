#!/usr/bin/env bash
# =============================================================================
#  gentoo-install.sh / gentoo-install-tui.sh - guided Gentoo Linux installer for amd64
# =============================================================================
#
#  What it does
#  ------------
#  Performs a complete Gentoo installation following the official Gentoo
#  AMD64 Handbook: disk partitioning, stage3 download with PGP verification,
#  Portage configuration tuned to the detected hardware (CFLAGS, MAKEOPTS,
#  CPU_FLAGS_X86, VIDEO_CARDS, binary package host), distribution kernel,
#  bootloader, users, networking, desktop environment, drivers, and optional
#  software (native packages and/or Flatpak).
#
#  Every question is asked first, with an explanation of each option. After
#  you confirm, the installation runs unattended. If a step fails, fix the
#  cause and run the script again with --resume; finished steps are skipped.
#
#  How to run (from the official Gentoo live image, as root)
#  ---------------------------------------------------------
#    curl -fsSLO https://raw.githubusercontent.com/NullAngst/Gentoo-Installer/main/gentoo-install.sh
#    bash gentoo-install.sh
#
#  Do not pipe it into bash (curl ... | bash). The script is interactive and
#  reads your answers from the keyboard.
#
#  Options
#    --resume   Continue an installation that stopped because of an error
#    --help     Show help
#
#  Logs
#    /tmp/gentoo-install.log        (live system)
#    /var/log/gentoo-install.log    (inside the new system)
# =============================================================================

set -Eeuo pipefail

readonly SCRIPT_VERSION="1.0.0"
readonly MNT="/mnt/gentoo"
readonly LIVE_LOG="/tmp/gentoo-install.log"
readonly LIVE_CONF_COPY="/tmp/gentoo-install.conf"
readonly TARGET_LOG="/var/log/gentoo-install.log"
readonly CONF_PATH="/root/gentoo-install.conf"
readonly PROGRESS_PATH="/root/.gentoo-install-progress"
readonly FAILED_PATH="/root/.gentoo-install-failed-optional"
readonly SCRIPT_PATH="/root/gentoo-install.sh"
readonly NOTES_NAME="GENTOO-POST-INSTALL-NOTES.txt"
readonly LUKS_NAME="cryptroot"
readonly BTRFS_OPTS="noatime,compress=zstd:1"
readonly ESP_SIZE_MIB=1024
readonly BOOT_SIZE_MIB=1024
readonly MIN_DISK_GIB=20
readonly FLATHUB_URL="https://dl.flathub.org/repo/flathub.flatpakrepo"

# GPT partition type GUIDs
readonly GUID_ESP="C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
readonly GUID_BIOS="21686148-6449-6E6F-744E-656564454649"
readonly GUID_SWAP="0657FD6D-A4AB-43C4-84E5-0933C84B4F4F"
readonly GUID_LINUX="0FC63DAF-8483-4772-8E79-3D69D8477DE4"

LOG="$LIVE_LOG"
IN_CHROOT="no"
CURRENT_STEP=""
SELF=""

# Every answer and detected value that the second (chroot) stage needs.
CONFIG_VARS=(
    DE DM INIT SWAY_AUTOSTART USE_BINPKG BINHOST_V3 TUNE_CPU_FLAGS KERNEL_PKG
    BOOT_MODE BOOTLOADER PART_MODE DISK ESP_PART FORMAT_ESP BIOS_PART BOOT_PART
    ROOT_PART SWAP_PART GRUB_DISK DUAL_BOOT NEED_BOOT_PART IS_SSD
    FS ENCRYPT SWAP_MODE SWAP_SIZE_GIB
    NEW_HOSTNAME TIMEZONE LOCALE KEYMAP XKB_LAYOUT XKB_VARIANT
    USERNAME PRIV_TOOL ROOT_HASH USER_HASH
    NET_TOOL WANT_BT WANT_CUPS WANT_SSH WANT_FLATPAK FLATPAK_APPS EXTRA_PKGS
    CPU_VENDOR CPU_MODEL NPROC RAM_GIB IS_LAPTOP HAS_WIFI HAS_BT VIRT SECURE_BOOT
    HAS_NVIDIA HAS_AMD HAS_INTEL GPU_VM GPU_DRIVER VIDEO_CARDS
    PROFILE_SUFFIX STAGE3_VARIANT MAKE_JOBS EMERGE_JOBS
    KERNEL_CMDLINE GRUB_EXTRA_CMDLINE DIST_BASE GENTOO_MIRRORS_VALUE
)

init_defaults() {
    local v
    for v in "${CONFIG_VARS[@]}"; do
        printf -v "$v" '%s' ""
    done
    DIST_BASE="https://distfiles.gentoo.org"
    KEYMAP="us"
    XKB_LAYOUT="us"
    GPU_DRIVER="mesa"
    ROOT_PASSWORD=""
    USER_PASSWORD=""
    LUKS_PASSWORD=""
}

# ----------------------------------------------------------------------------
# Output helpers
# ----------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
    C_RED=$'\e[1;31m'; C_GREEN=$'\e[1;32m'; C_YELLOW=$'\e[1;33m'
    C_BLUE=$'\e[1;34m'; C_CYAN=$'\e[1;36m'
else
    C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""
    C_YELLOW=""; C_BLUE=""; C_CYAN=""
fi

log() {
    printf '[%(%Y-%m-%d %H:%M:%S)T] %s\n' -1 "$*" >>"$LOG" 2>/dev/null || true
}

term_width() {
    local w
    w=$(tput cols 2>/dev/null || echo 80)
    [[ $w =~ ^[0-9]+$ ]] || w=80
    if (( w > 100 )); then w=100; fi
    if (( w < 50 )); then w=50; fi
    echo "$w"
}

hr() {
    local w line
    w=$(term_width)
    printf -v line '%*s' "$w" ''
    printf '%s%s%s\n' "$C_BLUE" "${line// /=}" "$C_RESET"
}

section() {
    echo
    hr
    printf '%s  %s%s\n' "$C_BOLD" "$*" "$C_RESET"
    hr
    log "===== $* ====="
}

subsection() {
    echo
    printf '%s--- %s ---%s\n' "$C_BOLD$C_CYAN" "$*" "$C_RESET"
    log "--- $* ---"
}

# say "paragraph" ["paragraph" ...]: print wrapped, indented paragraphs.
say() {
    local w p
    w=$(( $(term_width) - 4 ))
    for p in "$@"; do
        printf '%s\n' "$p" | fold -s -w "$w" | sed 's/^/  /'
        echo
    done
}

# say_pre "text": show preformatted text (tables, lists) without re-wrapping.
say_pre() {
    printf '%s\n\n' "$1"
}

# Front-end hooks. The console front end needs none of them; the TUI overrides them.
handoff_screen() { :; }     # called before a full-screen program (cfdisk, nmtui, a shell) takes over
ui_install_phase() { :; }   # called when the unattended installation starts
ui_finish_phase() { :; }    # called before the final questions

# yn_default VAR FALLBACK: the y/n default for a question whose previous answer is in VAR.
yn_default() {
    case "${!1:-}" in
        yes) echo "y" ;;
        no) echo "n" ;;
        *) echo "$2" ;;
    esac
}

info() { printf '%s[ INFO ]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; log "INFO: $*"; }
ok()   { printf '%s[  OK  ]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; log "OK: $*"; }
warn() { printf '%s[ WARN ]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; log "WARN: $*"; }
err()  { printf '%s[ FAIL ]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; log "FAIL: $*"; }
die()  { err "$*"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# run CMD ARGS...: show the command, run it, copy its output into the log.
run() {
    printf '%s    $ %s%s\n' "$C_DIM" "$*" "$C_RESET"
    log "RUN: $*"
    "$@" 2>&1 | tee -a "$LOG"
}

trim() {
    local s=$1
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# ----------------------------------------------------------------------------
# Error handling
# ----------------------------------------------------------------------------
print_resume_help() {
    if [[ -f "${MNT}${CONF_PATH}" ]]; then
        echo
        say "Nothing is lost. Every finished step is recorded, so the installer can continue where it stopped." \
            "What to do: 1) Read the end of the log to see what went wrong. 2) Fix the cause (common ones: a network hiccup, a package that needs a USE flag change, a full disk). 3) Run:  bash ${SELF:-gentoo-install.sh} --resume" \
            "To fix something inside the new system first, run:  chroot ${MNT} /bin/bash  then  source /etc/profile. Type exit when done, then resume."
    fi
}

on_error() {
    local rc=$1 line=$2 cmd=$3
    trap - ERR
    if [[ ${TUI_ACTIVE:-no} == "yes" ]]; then clear 2>/dev/null || true; TUI_ACTIVE="no"; fi
    if (( rc == 0 )); then rc=1; fi
    echo
    err "A command failed (exit code ${rc}, script line ${line}):"
    err "    ${cmd}"
    err "Full log: ${LOG}"
    if [[ $IN_CHROOT == "yes" ]]; then
        err "This happened inside the new system during step ${CURRENT_STEP:-unknown}."
    else
        print_resume_help
    fi
    exit "$rc"
}

on_interrupt() {
    trap - ERR INT
    if [[ ${TUI_ACTIVE:-no} == "yes" ]]; then clear 2>/dev/null || true; TUI_ACTIVE="no"; fi
    echo
    err "Interrupted by user (Ctrl+C)."
    if [[ $IN_CHROOT != "yes" ]]; then
        print_resume_help
    fi
    exit 130
}

# Source a shell file without letting it trip errexit, nounset or the ERR trap.
safe_source() {
    trap - ERR
    set +eu
    # shellcheck disable=SC1090
    source "$1"
    set -eu
    trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR
}

# ----------------------------------------------------------------------------
# Question helpers
# ----------------------------------------------------------------------------

# read_line VAR "prompt"
read_line() {
    local __rl_var=$1 __rl_prompt=$2 __rl_val
    if ! IFS= read -r -p "$__rl_prompt" __rl_val; then
        echo
        die "Input ended unexpectedly. Run the script from an interactive terminal."
    fi
    printf -v "$__rl_var" '%s' "$__rl_val"
}

pause() {
    local __p
    read_line __p "  Press Enter to continue... "
}

# ask VAR "Question" "default" [validator_function]
ask() {
    local __var=$1 __q=$2 __def=${3:-} __check=${4:-} __a
    while true; do
        if [[ -n $__def ]]; then
            read_line __a "  ${__q} [${__def}]: "
            __a=$(trim "$__a")
            __a=${__a:-$__def}
        else
            read_line __a "  ${__q}: "
            __a=$(trim "$__a")
        fi
        if [[ -z $__a ]]; then
            warn "An answer is required."
            continue
        fi
        if [[ -n $__check ]] && ! "$__check" "$__a"; then
            continue
        fi
        printf -v "$__var" '%s' "$__a"
        log "ANSWER: ${__q} => ${__a}"
        echo
        return 0
    done
}

# ask_yn VAR "Question" y|n   (VAR becomes "yes" or "no")
ask_yn() {
    local __var=$1 __q=$2 __def=$3 __a __hint="y/N"
    if [[ $__def == "y" ]]; then __hint="Y/n"; fi
    while true; do
        read_line __a "  ${__q} [${__hint}]: "
        __a=$(trim "$__a")
        __a=${__a:-$__def}
        case "${__a,,}" in
            y|yes) printf -v "$__var" 'yes'; break ;;
            n|no)  printf -v "$__var" 'no'; break ;;
            *) warn "Please answer y (yes) or n (no)." ;;
        esac
    done
    log "ANSWER: ${__q} => ${!__var}"
    echo
}

# yesno "Question" y|n   (returns 0 for yes)
yesno() {
    local __yn
    ask_yn __yn "$1" "$2"
    [[ $__yn == "yes" ]]
}

# choose VAR "Question" DEFAULT_VALUE "value|Label" ...
choose() {
    local __var=$1 __q=$2 __def=$3
    shift 3
    local -a __vals=() __labs=()
    local __o __i __a __defi=1
    for __o in "$@"; do
        __vals+=("${__o%%|*}")
        __labs+=("${__o#*|}")
    done
    for __i in "${!__vals[@]}"; do
        if [[ ${__vals[__i]} == "$__def" ]]; then __defi=$(( __i + 1 )); fi
    done
    printf '\n  %s%s%s\n' "$C_BOLD" "$__q" "$C_RESET"
    for __i in "${!__vals[@]}"; do
        if (( __i + 1 == __defi )); then
            printf '    %s%2d) %s   (default)%s\n' "$C_GREEN" $(( __i + 1 )) "${__labs[__i]}" "$C_RESET"
        else
            printf '    %2d) %s\n' $(( __i + 1 )) "${__labs[__i]}"
        fi
    done
    while true; do
        read_line __a "  Enter a number 1-${#__vals[@]} [${__defi}]: "
        __a=$(trim "$__a")
        __a=${__a:-$__defi}
        if [[ $__a =~ ^[0-9]+$ ]] && (( __a >= 1 && __a <= ${#__vals[@]} )); then
            printf -v "$__var" '%s' "${__vals[__a - 1]}"
            log "ANSWER: ${__q} => ${__vals[__a - 1]}"
            echo
            return 0
        fi
        warn "Please enter a number between 1 and ${#__vals[@]}."
    done
}

# choose_multi VAR "Question" "value|Label" ...   (VAR = space separated values)
choose_multi() {
    local __var=$1 __q=$2
    shift 2
    local -a __vals=() __labs=() __picked=() __toks=()
    local __o __i __a __t __bad __out="" __p
    for __o in "$@"; do
        __vals+=("${__o%%|*}")
        __labs+=("${__o#*|}")
    done
    printf '\n  %s%s%s\n' "$C_BOLD" "$__q" "$C_RESET"
    for __i in "${!__vals[@]}"; do
        printf '    %2d) %s\n' $(( __i + 1 )) "${__labs[__i]}"
    done
    while true; do
        read_line __a "  Numbers separated by spaces (example: 1 4 7), 'all', or Enter for none: "
        __a=$(trim "${__a//,/ }")
        __picked=()
        if [[ -z $__a || ${__a,,} == "none" ]]; then break; fi
        if [[ ${__a,,} == "all" ]]; then
            __picked=("${__vals[@]}")
            break
        fi
        read -ra __toks <<<"$__a"
        __bad="no"
        for __t in "${__toks[@]}"; do
            if [[ $__t =~ ^[0-9]+$ ]] && (( __t >= 1 && __t <= ${#__vals[@]} )); then
                __picked+=("${__vals[__t - 1]}")
            else
                warn "'${__t}' is not a number from the list."
                __bad="yes"
            fi
        done
        if [[ $__bad == "no" ]]; then break; fi
    done
    for __p in "${__picked[@]}"; do
        if [[ " $__out " != *" $__p "* ]]; then
            __out+="${__out:+ }${__p}"
        fi
    done
    printf -v "$__var" '%s' "$__out"
    log "ANSWER: ${__q} => ${__out:-none}"
    echo
}

# ask_password VAR "what" MIN_LENGTH
ask_password() {
    local __var=$1 __what=$2 __min=${3:-1} __p1 __p2
    while true; do
        if ! IFS= read -r -s -p "  Type the ${__what}: " __p1; then echo; die "Input ended unexpectedly."; fi
        echo
        if (( ${#__p1} < __min )); then
            if (( __min == 1 )); then warn "It cannot be empty."; else warn "It must be at least ${__min} characters long."; fi
            continue
        fi
        if ! IFS= read -r -s -p "  Type it again to confirm: " __p2; then echo; die "Input ended unexpectedly."; fi
        echo
        if [[ $__p1 != "$__p2" ]]; then
            warn "The two entries did not match. Try again."
            continue
        fi
        if (( ${#__p1} < 8 )); then
            warn "That is shorter than 8 characters, which is easy to guess."
            if ! yesno "Use it anyway?" n; then continue; fi
        fi
        printf -v "$__var" '%s' "$__p1"
        log "ANSWER: ${__what} => (hidden)"
        return 0
    done
}

# ----------------------------------------------------------------------------
# Validators (print a warning and return 1 when the value is not acceptable)
# ----------------------------------------------------------------------------
valid_hostname() {
    if [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]; then return 0; fi
    warn "Use 1-63 letters, digits or hyphens. It cannot start or end with a hyphen."
    return 1
}

valid_username() {
    if [[ ! $1 =~ ^[a-z_][a-z0-9_-]{0,30}$ ]]; then
        warn "Use lowercase letters, digits, '-' or '_', starting with a letter (max 31 characters)."
        return 1
    fi
    case "$1" in
        root|bin|daemon|adm|lp|sync|shutdown|halt|mail|news|uucp|operator|portage|nobody|man|sshd|messagebus|polkitd|sddm|gdm|lightdm|games|ftp|video|audio|wheel|users)
            warn "'$1' is already used by the system. Pick another name."
            return 1 ;;
    esac
    return 0
}

valid_positive_int() {
    if [[ $1 =~ ^[1-9][0-9]*$ ]]; then return 0; fi
    warn "Enter a whole number greater than zero."
    return 1
}

valid_keymap() {
    local k=$1
    if [[ ! $k =~ ^[A-Za-z0-9._-]+$ ]]; then
        warn "That does not look like a keymap name."
        return 1
    fi
    if [[ -d /usr/share/keymaps ]]; then
        if find /usr/share/keymaps -name "${k}.map*" -print -quit 2>/dev/null | grep -q .; then
            return 0
        fi
        warn "Keymap '${k}' was not found. Examples: us, uk, de, de-latin1, fr, es, it, br-abnt2, pl, ru, dvorak."
        return 1
    fi
    return 0
}

valid_xkb_layout() {
    if [[ ! $1 =~ ^[a-z]{2,6}$ ]]; then
        warn "XKB layout names are short lowercase codes such as us, gb, de, fr, es, ch, latam. Console keymap names like 'de-latin1' do not work here."
        return 1
    fi
    if [[ -d /usr/share/X11/xkb/symbols && ! -f /usr/share/X11/xkb/symbols/$1 ]]; then
        warn "XKB layout '$1' was not found in /usr/share/X11/xkb/symbols."
        return 1
    fi
    return 0
}

valid_locale() {
    local l=$1
    if [[ ! $l =~ ^[a-z]{2,3}_[A-Z]{2}\.UTF-8(@[a-z]+)?$ ]]; then
        warn "Use the form language_COUNTRY.UTF-8, for example en_US.UTF-8, en_GB.UTF-8, de_DE.UTF-8."
        return 1
    fi
    if [[ -r /usr/share/i18n/SUPPORTED ]] && ! grep -q "^${l} " /usr/share/i18n/SUPPORTED; then
        warn "Locale '${l}' is not in the list of supported locales (/usr/share/i18n/SUPPORTED)."
        return 1
    fi
    return 0
}

browse_timezones() {
    local region
    if [[ ! -d /usr/share/zoneinfo ]]; then
        warn "This live system has no timezone database to browse. Type a name such as Europe/Berlin or America/Chicago."
        return 0
    fi
    echo
    echo "  Regions:"
    find /usr/share/zoneinfo -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
        | grep -E '^(Africa|America|Antarctica|Arctic|Asia|Atlantic|Australia|Europe|Indian|Pacific)$' \
        | sort | sed 's/^/    /'
    read_line region "  Region to list (Enter to go back): "
    region=$(trim "$region")
    if [[ -n $region && -d /usr/share/zoneinfo/$region ]]; then
        echo
        (cd "/usr/share/zoneinfo/$region" && find . -type f | sed 's|^\./||' | sort | column -c "$(term_width)" 2>/dev/null) \
            || (cd "/usr/share/zoneinfo/$region" && find . -type f | sed 's|^\./||' | sort)
        echo
        echo "  Now type the full name, for example ${region}/$(find "/usr/share/zoneinfo/$region" -maxdepth 1 -type f -printf '%f\n' | sort | head -n1)"
    fi
}

valid_timezone() {
    local tz=$1
    if [[ $tz == "list" ]]; then
        browse_timezones
        return 1
    fi
    if [[ ! $tz =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ ]]; then
        warn "That does not look like a timezone name. Example: America/New_York. Type 'list' to browse."
        return 1
    fi
    if [[ -d /usr/share/zoneinfo ]]; then
        if [[ -f /usr/share/zoneinfo/$tz ]]; then return 0; fi
        warn "Timezone '${tz}' was not found. Type 'list' to browse."
        return 1
    fi
    warn "Cannot verify '${tz}' on this live system. It will be checked during installation (UTC is used if it is invalid)."
    return 0
}
