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
#    Menu version:
#      curl -fsSLO https://raw.githubusercontent.com/NullAngst/Gentoo-Installer/refs/heads/main/gentoo-install-tui.sh
#      bash gentoo-install-tui.sh
#    Console version:
#      curl -fsSLO https://raw.githubusercontent.com/NullAngst/Gentoo-Installer/refs/heads/main/gentoo-install.sh
#      bash gentoo-install.sh
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

readonly SCRIPT_VERSION="1.2.0"
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
readonly MIN_DESKTOP_DISK_GIB=40
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
    HAS_NVIDIA HAS_AMD HAS_INTEL GPU_VM GPU_DRIVER VIDEO_CARDS NVIDIA_GEN
    IS_APPLE MAC_MODEL LIVE_BOOT_MODE
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
    STAGE3_URL=""
    STAGE3_FILE=""
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
# RUN_CMD remembers the command, because when it fails the error trap only sees
# the last part of the pipeline (tee).
RUN_CMD=""
run() {
    printf '%s    $ %s%s\n' "$C_DIM" "$*" "$C_RESET"
    log "RUN: $*"
    RUN_CMD="$*"
    "$@" 2>&1 | tee -a "$LOG"
}

# After a failed emerge: show where Portage kept the package's own build log,
# and the lines of it that usually explain the failure.
show_build_log_excerpt() {
    local blog errors
    blog=$(grep -o "The complete build log is located at '[^']*'" "$LOG" 2>/dev/null | tail -n1 || true)
    blog=${blog#*located at \'}
    blog=${blog%\'}
    if [[ -z $blog || ! -r $blog ]]; then return 0; fi
    local pattern="\\*\\*\\* \\[|error:|Error [0-9]+|Can't locate|No such file or directory|Illegal instruction|Segmentation fault|Killed|undefined reference|command not found|can't get .--help' info"
    errors=$(grep -nE "$pattern" "$blog" 2>/dev/null \
        | grep -vE "^[0-9]+:(checking|configure:)|-Werror|-Wno-error" || true)
    local first=${errors%%:*} from
    {
        echo
        echo "---- Why it failed: lines from the package's build log ----"
        echo "Build log: ${blog}"
        echo "(from the live system: ${MNT}${blog})"
        if [[ $first =~ ^[0-9]+$ ]]; then
            from=$(( first > 12 ? first - 12 : 1 ))
            echo
            echo "Where it first went wrong (lines ${from}-$(( first + 3 )); the cause is usually just above the first '***' or 'error' line):"
            sed -n "${from},$(( first + 3 ))p" "$blog"
        fi
        echo
        echo "Last lines of the build log:"
        tail -n 25 "$blog"
        echo
        if grep -q "Can't locate .*\.pm in @INC" "$blog" 2>/dev/null; then
            echo "A Perl module could not be loaded. This usually happens after Perl was"
            echo "upgraded and its modules were not rebuilt. Fix it from the live system with:"
            echo "  chroot ${MNT} /bin/bash -c 'source /etc/profile && perl-cleaner --all -- --quiet-build=y'"
            echo "then resume the installer."
            echo
        fi
        if [[ -z $errors && -n $(tail -c 1 "$blog") ]]; then
            echo "The build log stops in the middle of a line without any error message:"
            echo "the build lost its output channel before it could report anything."
            echo "Possible causes: Portage could not write the build output to the screen,"
            echo "the disk is full, or the filesystem became read-only (free space below)."
        fi
        echo "Free space on the new system's root filesystem:"
        df -h / 2>/dev/null | sed 's/^/    /' || true
        echo "------------------------------------------------------------"
    } | tee -a "$LOG"
}

# Put standard input/output back into blocking mode. A terminal left in
# non-blocking mode makes large bursts of output fail with "Resource temporarily
# unavailable", which can abort a running build. Harmless when already blocking.
ensure_blocking_stdio() {
    if have python3; then
        python3 -c 'import os
for fd in (0, 1, 2):
    try:
        os.set_blocking(fd, True)
    except OSError:
        pass' 2>/dev/null || true
    fi
}

# Free KiB on the filesystem holding PATH (empty if unknown).
disk_free_kib() {
    df -Pk "$1" 2>/dev/null | awk 'NR == 2 {print $4}' || true
}

# Delete Portage's download caches: binary packages (and with --all also source
# archives and leftover build directories). They are only caches; Portage downloads
# again whatever it needs later.
#
# Downloaded binary packages: current Portage keeps them per binary repository,
# by default in /var/cache/binhost/<name>, or in a "location" set in
# binrepos.conf (Gentoo news item 2026-05-03-portage-binpkg-changes). Older
# Portage kept them in PKGDIR, which now only holds locally built packages.
free_package_caches() {
    local dir loc conf
    local -a dirs=()
    dirs+=("$(portageq envvar PKGDIR 2>/dev/null || echo /var/cache/binpkgs)")
    dirs+=("/var/cache/binhost")
    # binrepos.conf may be a file or a directory of files; read regular files only.
    for conf in /etc/portage/binrepos.conf /etc/portage/binrepos.conf/*.conf; do
        [[ -f $conf ]] || continue
        while IFS= read -r loc; do
            if [[ -n $loc ]]; then dirs+=("$loc"); fi
        done < <(sed -n 's/^[[:space:]]*location[[:space:]]*=[[:space:]]*//p' "$conf")
    done
    if [[ ${1:-} == "--all" ]]; then
        dirs+=("$(portageq envvar DISTDIR 2>/dev/null || echo /var/cache/distfiles)")
        dirs+=("$(portageq envvar PORTAGE_TMPDIR 2>/dev/null || echo /var/tmp)/portage")
    fi
    for dir in "${dirs[@]}"; do
        dir=$(trim "$dir")
        if [[ -n $dir && $dir != "/" && -d $dir ]]; then
            find "$dir" -mindepth 1 -delete 2>/dev/null || true
            log "Cleared ${dir}"
        fi
    done
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
    # shellcheck disable=SC2016  # the literal text of run's tee command, as the trap reports it
    if [[ $cmd == 'tee -a "$LOG"' && -n ${RUN_CMD:-} ]]; then cmd=$RUN_CMD; fi
    echo
    err "A command failed (exit code ${rc}, script line ${line}):"
    err "    ${cmd}"
    err "Full log: ${LOG}"
    if [[ $IN_CHROOT == "yes" ]]; then
        err "This happened inside the new system during step ${CURRENT_STEP:-unknown}."
        if [[ $cmd == emerge* ]]; then show_build_log_excerpt; fi
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

# Validators only trust live-system data after checking it is really there:
# the Gentoo minimal ISO keeps some directories but empties them to save space
# (for example /usr/share/zoneinfo and /usr/share/i18n).

valid_keymap() {
    local k=$1
    if [[ ! $k =~ ^[A-Za-z0-9._-]+$ ]]; then
        warn "That does not look like a keymap name."
        return 1
    fi
    if [[ -n $(find /usr/share/keymaps -name 'us.map*' -print -quit 2>/dev/null || true) ]]; then
        if [[ -n $(find /usr/share/keymaps -name "${k}.map*" -print -quit 2>/dev/null || true) ]]; then
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
    if [[ -f /usr/share/X11/xkb/symbols/us && ! -f /usr/share/X11/xkb/symbols/$1 ]]; then
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
    if [[ -r /usr/share/i18n/SUPPORTED ]] && grep -q '^en_US.UTF-8 ' /usr/share/i18n/SUPPORTED \
        && ! grep -q "^${l} " /usr/share/i18n/SUPPORTED; then
        warn "Locale '${l}' is not in the list of supported locales (/usr/share/i18n/SUPPORTED)."
        return 1
    fi
    return 0
}

# Canonical timezone names (tzdata 2026a, zone1970.tab, plus UTC). Used for
# browsing and checking when the live system has no timezone database, which is
# the case on the Gentoo minimal ISO. The new system's own database is checked
# again during installation.
BUILTIN_TIMEZONES=(
    UTC Africa/Abidjan Africa/Algiers Africa/Bissau Africa/Cairo Africa/Casablanca Africa/Ceuta
    Africa/El_Aaiun Africa/Johannesburg Africa/Juba Africa/Khartoum Africa/Lagos Africa/Maputo
    Africa/Monrovia Africa/Nairobi Africa/Ndjamena Africa/Sao_Tome Africa/Tripoli Africa/Tunis
    Africa/Windhoek America/Adak America/Anchorage America/Araguaina
    America/Argentina/Buenos_Aires America/Argentina/Catamarca America/Argentina/Cordoba
    America/Argentina/Jujuy America/Argentina/La_Rioja America/Argentina/Mendoza
    America/Argentina/Rio_Gallegos America/Argentina/Salta America/Argentina/San_Juan
    America/Argentina/San_Luis America/Argentina/Tucuman America/Argentina/Ushuaia
    America/Asuncion America/Bahia America/Bahia_Banderas America/Barbados America/Belem
    America/Belize America/Boa_Vista America/Bogota America/Boise America/Cambridge_Bay
    America/Campo_Grande America/Cancun America/Caracas America/Cayenne America/Chicago
    America/Chihuahua America/Ciudad_Juarez America/Costa_Rica America/Coyhaique America/Cuiaba
    America/Danmarkshavn America/Dawson America/Dawson_Creek America/Denver America/Detroit
    America/Edmonton America/Eirunepe America/El_Salvador America/Fort_Nelson America/Fortaleza
    America/Glace_Bay America/Goose_Bay America/Grand_Turk America/Guatemala America/Guayaquil
    America/Guyana America/Halifax America/Havana America/Hermosillo
    America/Indiana/Indianapolis America/Indiana/Knox America/Indiana/Marengo
    America/Indiana/Petersburg America/Indiana/Tell_City America/Indiana/Vevay
    America/Indiana/Vincennes America/Indiana/Winamac America/Inuvik America/Iqaluit
    America/Jamaica America/Juneau America/Kentucky/Louisville America/Kentucky/Monticello
    America/La_Paz America/Lima America/Los_Angeles America/Maceio America/Managua
    America/Manaus America/Martinique America/Matamoros America/Mazatlan America/Menominee
    America/Merida America/Metlakatla America/Mexico_City America/Miquelon America/Moncton
    America/Monterrey America/Montevideo America/New_York America/Nome America/Noronha
    America/North_Dakota/Beulah America/North_Dakota/Center America/North_Dakota/New_Salem
    America/Nuuk America/Ojinaga America/Panama America/Paramaribo America/Phoenix
    America/Port-au-Prince America/Porto_Velho America/Puerto_Rico America/Punta_Arenas
    America/Rankin_Inlet America/Recife America/Regina America/Resolute America/Rio_Branco
    America/Santarem America/Santiago America/Santo_Domingo America/Sao_Paulo
    America/Scoresbysund America/Sitka America/St_Johns America/Swift_Current
    America/Tegucigalpa America/Thule America/Tijuana America/Toronto America/Vancouver
    America/Whitehorse America/Winnipeg America/Yakutat Antarctica/Casey Antarctica/Davis
    Antarctica/Macquarie Antarctica/Mawson Antarctica/Palmer Antarctica/Rothera Antarctica/Troll
    Antarctica/Vostok Asia/Almaty Asia/Amman Asia/Anadyr Asia/Aqtau Asia/Aqtobe Asia/Ashgabat
    Asia/Atyrau Asia/Baghdad Asia/Baku Asia/Bangkok Asia/Barnaul Asia/Beirut Asia/Bishkek
    Asia/Chita Asia/Colombo Asia/Damascus Asia/Dhaka Asia/Dili Asia/Dubai Asia/Dushanbe
    Asia/Famagusta Asia/Gaza Asia/Hebron Asia/Ho_Chi_Minh Asia/Hong_Kong Asia/Hovd Asia/Irkutsk
    Asia/Jakarta Asia/Jayapura Asia/Jerusalem Asia/Kabul Asia/Kamchatka Asia/Karachi
    Asia/Kathmandu Asia/Khandyga Asia/Kolkata Asia/Krasnoyarsk Asia/Kuching Asia/Macau
    Asia/Magadan Asia/Makassar Asia/Manila Asia/Nicosia Asia/Novokuznetsk Asia/Novosibirsk
    Asia/Omsk Asia/Oral Asia/Pontianak Asia/Pyongyang Asia/Qatar Asia/Qostanay Asia/Qyzylorda
    Asia/Riyadh Asia/Sakhalin Asia/Samarkand Asia/Seoul Asia/Shanghai Asia/Singapore
    Asia/Srednekolymsk Asia/Taipei Asia/Tashkent Asia/Tbilisi Asia/Tehran Asia/Thimphu
    Asia/Tokyo Asia/Tomsk Asia/Ulaanbaatar Asia/Urumqi Asia/Ust-Nera Asia/Vladivostok
    Asia/Yakutsk Asia/Yangon Asia/Yekaterinburg Asia/Yerevan Atlantic/Azores Atlantic/Bermuda
    Atlantic/Canary Atlantic/Cape_Verde Atlantic/Faroe Atlantic/Madeira Atlantic/South_Georgia
    Atlantic/Stanley Australia/Adelaide Australia/Brisbane Australia/Broken_Hill
    Australia/Darwin Australia/Eucla Australia/Hobart Australia/Lindeman Australia/Lord_Howe
    Australia/Melbourne Australia/Perth Australia/Sydney Europe/Andorra Europe/Astrakhan
    Europe/Athens Europe/Belgrade Europe/Berlin Europe/Brussels Europe/Bucharest Europe/Budapest
    Europe/Chisinau Europe/Dublin Europe/Gibraltar Europe/Helsinki Europe/Istanbul
    Europe/Kaliningrad Europe/Kirov Europe/Kyiv Europe/Lisbon Europe/London Europe/Madrid
    Europe/Malta Europe/Minsk Europe/Moscow Europe/Paris Europe/Prague Europe/Riga Europe/Rome
    Europe/Samara Europe/Saratov Europe/Simferopol Europe/Sofia Europe/Tallinn Europe/Tirane
    Europe/Ulyanovsk Europe/Vienna Europe/Vilnius Europe/Volgograd Europe/Warsaw Europe/Zurich
    Indian/Chagos Indian/Maldives Indian/Mauritius Pacific/Apia Pacific/Auckland
    Pacific/Bougainville Pacific/Chatham Pacific/Easter Pacific/Efate Pacific/Fakaofo
    Pacific/Fiji Pacific/Galapagos Pacific/Gambier Pacific/Guadalcanal Pacific/Guam
    Pacific/Honolulu Pacific/Kanton Pacific/Kiritimati Pacific/Kosrae Pacific/Kwajalein
    Pacific/Marquesas Pacific/Nauru Pacific/Niue Pacific/Norfolk Pacific/Noumea
    Pacific/Pago_Pago Pacific/Palau Pacific/Pitcairn Pacific/Port_Moresby Pacific/Rarotonga
    Pacific/Tahiti Pacific/Tarawa Pacific/Tongatapu
)

# True when the live system has a real timezone database (the LiveGUI does).
tz_live_usable() {
    [[ -r /usr/share/zoneinfo/zone1970.tab && -f /usr/share/zoneinfo/UTC ]]
}

# Print all known timezone names, one per line.
tz_names() {
    if tz_live_usable; then
        { echo "UTC"; grep -v '^#' /usr/share/zoneinfo/zone1970.tab | awk -F'\t' 'NF >= 3 {print $3}'; } | sort -u
    else
        printf '%s\n' "${BUILTIN_TIMEZONES[@]}"
    fi
}

# print_columns "lines": show a list in as many columns as fit the terminal.
print_columns() {
    awk -v width="$(term_width)" '
        { item[NR] = $0; if (length($0) > max) max = length($0) }
        END {
            colw = max + 2
            cols = int((width - 4) / colw); if (cols < 1) cols = 1
            rows = int((NR + cols - 1) / cols)
            for (r = 1; r <= rows; r++) {
                line = "    "
                for (c = 0; c < cols; c++) {
                    i = r + c * rows
                    if (i <= NR) line = line sprintf("%-" colw "s", item[i])
                }
                sub(/ +$/, "", line)
                print line
            }
        }' <<<"$1"
}

browse_timezones() {
    local names region cities
    names=$(tz_names)
    echo
    echo "  Regions:"
    print_columns "$(awk -F/ 'NF > 1 {print $1}' <<<"$names" | sort -u; echo "UTC")"
    read_line region "  Region to list (Enter to go back): "
    region=$(trim "$region")
    if [[ -z $region ]]; then return 0; fi
    if [[ $region == "UTC" ]]; then
        echo "  Type UTC to use it."
        return 0
    fi
    cities=$(awk -v r="${region}/" 'index($0, r) == 1 {print substr($0, length(r) + 1)}' <<<"$names")
    if [[ -z $cities ]]; then
        warn "There is no region called '${region}'. Region names are case sensitive, for example Europe."
        return 0
    fi
    echo
    print_columns "$cities"
    echo
    echo "  Now type the full name, for example ${region}/$(head -n1 <<<"$cities")"
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
    if tz_live_usable; then
        if [[ -f /usr/share/zoneinfo/$tz ]]; then return 0; fi
        warn "Timezone '${tz}' was not found. Names are case sensitive. Type 'list' to browse."
        return 1
    fi
    if grep -qxF -- "$tz" <<<"$(tz_names)"; then
        return 0
    fi
    warn "'${tz}' is not in the installer's list of timezones (names are case sensitive; type 'list' to browse). Older alias names such as US/Eastern are not in the list but still exist."
    if yesno "Use '${tz}' anyway? It is checked again during installation, and UTC is used if it does not exist." n; then
        return 0
    fi
    return 1
}
