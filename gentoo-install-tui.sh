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
free_package_caches() {
    local dir
    local -a dirs=()
    dirs+=("$(portageq envvar PKGDIR 2>/dev/null || echo /var/cache/binpkgs)")
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
    local bytes gib need
    need=$(min_root_gib)
    while true; do
        choose DISK "Target disk" "${DISK:-${opts[0]%%|*}}" "${opts[@]}"
        bytes=$(lsblk -bdno SIZE "$DISK" 2>/dev/null || true)
        bytes=${bytes%%$'\n'*}
        gib=$(( ${bytes:-0} / 1073741824 ))
        if (( gib >= need )); then break; fi
        warn "${DISK} has ${gib} GiB, but this installation needs at least ${need} GiB ($( [[ $DE == none ]] && echo "without a desktop" || echo "with a desktop: the desktop, the package downloads and temporary build files need the room" )). Pick another disk, or quit and give the machine a larger disk."
    done

    say_pre "$(printf '  Current contents of %s:\n' "$DISK"; lsblk -po NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$DISK" 2>/dev/null | sed 's/^/    /')"
    if (( gib < 60 )) && [[ $DE != "none" ]]; then
        info "${DISK} has ${gib} GiB. That is enough to install, but 60 GiB or more leaves comfortable room for updates, which on Gentoo sometimes compile large packages."
    fi
    IS_SSD="no"
    if [[ $(cat "/sys/block/${DISK##*/}/queue/rotational" 2>/dev/null || echo 1) == "0" ]]; then IS_SSD="yes"; fi
}

# Minimum size in GiB for the target disk or root partition.
min_root_gib() {
    if [[ $DE == "none" ]]; then echo "$MIN_DISK_GIB"; else echo "$MIN_DESKTOP_DISK_GIB"; fi
}

# Size in GiB of the disk (automatic layout) or root partition (manual layout).
target_root_gib() {
    local dev=$DISK bytes
    if [[ $PART_MODE == "manual" ]]; then dev=$ROOT_PART; fi
    bytes=$(lsblk -bdno SIZE "$dev" 2>/dev/null || true)
    bytes=${bytes%%$'\n'*}
    echo $(( ${bytes:-0} / 1073741824 ))
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
        bytes=$(lsblk -bdno SIZE "$ESP_PART" 2>/dev/null || true)
        bytes=${bytes%%$'\n'*}
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
    local need
    need=$(min_root_gib)
    while true; do
        pick_partition ROOT_PART "Which partition should become the root filesystem / ? (it will be formatted)" "$used"
        bytes=$(lsblk -bdno SIZE "$ROOT_PART" 2>/dev/null || true)
        bytes=${bytes%%$'\n'*}
        if (( ${bytes:-0} / 1073741824 >= need )); then break; fi
        warn "${ROOT_PART} has $(( ${bytes:-0} / 1073741824 )) GiB; this installation needs at least ${need} GiB for the root filesystem. Pick a larger partition (or enlarge it with cfdisk and run the installer again)."
    done
    used+=" $ROOT_PART"
    if [[ $SWAP_MODE == "partition" ]]; then
        pick_partition SWAP_PART "Which partition should be used as swap? (it will be formatted)" "$used"
        used+=" $SWAP_PART"
    fi


    DISK="/dev/$(lsblk_field PKNAME "$ROOT_PART")"
    GRUB_DISK=""
    if [[ $BOOT_MODE == "bios" ]]; then
        GRUB_DISK=$DISK
        if [[ $(lsblk_field PTTYPE "$GRUB_DISK") == "gpt" ]]; then
            local ptypes
            ptypes=$(lsblk -lno PARTTYPE "$GRUB_DISK" 2>/dev/null || true)
            if ! grep -qi "${GUID_BIOS}" <<<"$ptypes"; then
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
        # "<64 hex digits>  <file name>" lines, possibly inside a PGP clearsigned block.
        expected=$(tr -d '\r' <"${f}.sha256" | awk -v f="$f" '
            !found && length($1) == 64 && $1 ~ /^[0-9a-fA-F]+$/ && ($2 == f || $2 == "*" f) { print tolower($1); found = 1 }')
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

# Find the newest stage3 for STAGE3_VARIANT (sets STAGE3_URL and STAGE3_FILE).
# Runs before the disk is touched, so a download problem stops the installer
# while nothing has been changed yet.
#
# The index file is PGP clearsigned and contains a line like:
#   20260913T163055Z/stage3-amd64-desktop-systemd-20260913T163055Z.tar.xz 753542880
resolve_stage3() {
    local base index listing rel
    base="${DIST_BASE%/}/releases/amd64/autobuilds"
    index="${base}/latest-stage3-amd64-${STAGE3_VARIANT}.txt"
    info "Looking up the newest stage3-amd64-${STAGE3_VARIANT}."
    listing=$(fetch_text "$index") \
        || die "Could not download ${index}. Check the network connection and try again. Nothing on disk has been changed."
    rel=$(printf '%s\n' "$listing" | tr -d '\r' | awk -v v="stage3-amd64-${STAGE3_VARIANT}-" '
        !found && $1 !~ /^#/ && $1 ~ /\.tar\.xz$/ && index($1, v) { print $1; found = 1 }')
    if [[ -z $rel ]]; then
        log "Stage3 index content: ${listing}"
        die "Could not find a stage3-amd64-${STAGE3_VARIANT} file name in ${index} (its content is in the log). Nothing on disk has been changed."
    fi
    if [[ $rel == */* ]]; then
        STAGE3_URL="${base}/${rel}"
    else
        STAGE3_URL="${base}/current-stage3-amd64-${STAGE3_VARIANT}/${rel}"
    fi
    STAGE3_FILE=${rel##*/}
    ok "Newest stage3: ${STAGE3_FILE}"
}

install_stage3() {
    section "Downloading and verifying the Gentoo stage3"
    say "A stage3 is a small but complete Gentoo base system (compiler, Portage, core tools) that everything else is built on. The installer downloads the newest stage3-amd64-${STAGE3_VARIANT}, checks its PGP signature from Gentoo Release Engineering and its SHA256 checksum, then unpacks it onto your new root filesystem."
    if [[ -z $STAGE3_URL ]]; then resolve_stage3; fi
    local url=$STAGE3_URL file=$STAGE3_FILE
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
    resolve_stage3
    prepare_disk
    install_stage3
    mount_pseudo
    hash_passwords
    write_target_config
    run_chroot_stage
    finish_install
}

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

# Compiler output goes only to each package's build log (--quiet-build), not to
# the screen. Streaming thousands of long compiler lines to a slow console can
# make Portage abort a build mid-way; the build log keeps everything, and the
# relevant part is shown automatically when a build fails.
EMERGE_OPTS=(--verbose --quiet-build=y)

emerge_pkgs() {
    run emerge "${EMERGE_OPTS[@]}" --noreplace "$@"
}

# emerge_optional "label" PKG...: failures are recorded but do not stop the install.
emerge_optional() {
    local label=$1
    shift
    if (( $# == 0 )); then return 0; fi
    if run emerge "${EMERGE_OPTS[@]}" --noreplace "$@"; then return 0; fi
    warn "Installing ${label} in one go failed. Trying the packages one at a time."
    local p
    for p in "$@"; do
        if ! run emerge "${EMERGE_OPTS[@]}" --noreplace "$p"; then
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
                local shown
                shown=$(rc-update show "$runlevel" 2>/dev/null || true)
                if grep -Eq "^[[:space:]]*${s}[[:space:]]*\|" <<<"$shown"; then
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
    # Capture the list first: piping eselect straight into 'grep -q' can make
    # eselect die of SIGPIPE, which pipefail reports as "not found".
    local list
    list=$(eselect profile list 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' || true)
    if ! grep -Eq "[[:space:]]${target//./\\.}([[:space:]]|\$)" <<<"$list"; then
        if [[ -d /var/db/repos/gentoo/profiles/${target} ]]; then
            warn "eselect did not list ${target}, but it exists in the repository. Trying it anyway."
        else
            log "eselect profile list output:"$'\n'"${list}"
            die "Profile ${target} does not exist in this repository snapshot. Run 'eselect profile list' in the chroot to see the available ones."
        fi
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
    run emerge "${EMERGE_OPTS[@]}" --oneshot --noreplace app-portage/cpuid2cpuflags
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
    run emerge "${EMERGE_OPTS[@]}" --update --deep --newuse @world
    # When the update brings a new Perl version, Perl modules built for the old
    # one (for example Locale::gettext, which help2man needs to build GRUB's
    # manual pages) stop loading until they are rebuilt. perl-cleaner does that,
    # and does nothing when there is nothing to rebuild.
    if have perl-cleaner; then
        info "Rebuilding Perl modules left over from an older Perl version, if any (perl-cleaner)."
        local edo
        edo=$(portageq envvar EMERGE_DEFAULT_OPTS 2>/dev/null || true)
        run env EMERGE_DEFAULT_OPTS="${edo} --quiet-build=y" perl-cleaner --all
    fi
    info "Deleting the downloaded binary packages (already installed; they only take up space)."
    free_package_caches
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
            run emerge "${EMERGE_OPTS[@]}" --oneshot --update --newuse sys-apps/systemd-utils
        else
            run emerge "${EMERGE_OPTS[@]}" --oneshot --update --newuse sys-apps/systemd
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
    info "Deleting the downloaded binary packages (already installed; they only take up space)."
    free_package_caches
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
    info "Deleting Portage's download caches (binary packages and source archives) to free disk space."
    free_package_caches --all
    ok "Free space on /: $(df -h / | awk 'NR == 2 {print $4}')"
    setup_user_desktop
    write_notes
    local news
    news=$(eselect news count new 2>/dev/null || echo 0)
    if [[ $news =~ ^[0-9]+$ ]] && (( news > 0 )); then
        info "There are ${news} unread Gentoo news items. Read them after booting with: eselect news read"
    fi
}

# Rough minimum free space (GiB) needed before a step starts.
step_min_free_gib() {
    case "$1" in
        c_world) echo 4 ;;
        c_desktop)
            case "$DE" in
                plasma|gnome|cinnamon) echo 8 ;;
                none) echo 1 ;;
                *) echo 4 ;;
            esac ;;
        c_software) echo 3 ;;
        c_kernel|c_firmware|c_bootloader_prep|c_base_tools|c_hardware) echo 2 ;;
        *) echo 1 ;;
    esac
}

# Stop before a step when the disk is nearly full, instead of failing in the
# middle of a build with a cut-off log. Clears Portage's caches first.
check_disk_space() {
    local need_gib avail_kib
    need_gib=$(step_min_free_gib "$1")
    avail_kib=$(disk_free_kib /)
    [[ $avail_kib =~ ^[0-9]+$ ]] || return 0
    if (( avail_kib >= need_gib * 1048576 )); then return 0; fi
    warn "Only $(( avail_kib / 1024 )) MiB free on the new system; this step needs roughly ${need_gib} GiB. Clearing Portage's download caches and leftover build directories."
    free_package_caches --all
    avail_kib=$(disk_free_kib /)
    if (( avail_kib >= need_gib * 1048576 )); then
        ok "Now $(( avail_kib / 1024 )) MiB free."
        return 0
    fi
    say "Space used by the largest directories:"
    du -xsh /usr /var /opt /home /root 2>/dev/null | sort -rh | sed 's/^/    /' || true
    die "Not enough disk space: $(( avail_kib / 1024 )) MiB free, roughly ${need_gib} GiB needed for the next step. The disk (or root partition) is too small for this installation; ${MIN_DESKTOP_DISK_GIB} GiB or more is needed for a desktop. Enlarge it, or start over on a larger disk."
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
    info "While packages build, their compiler output goes to Portage's build logs instead of the screen; you will see one line per package. If a build fails, the relevant part of its log is shown."
    local total=${#CHROOT_STEPS[@]} i=0 s
    for s in "${CHROOT_STEPS[@]}"; do
        i=$(( i + 1 ))
        CURRENT_STEP="${i}/${total}"
        if grep -qx "$s" "$PROGRESS_PATH"; then
            info "Step ${CURRENT_STEP} (${s}) was already completed; skipping."
            continue
        fi
        check_disk_space "$s"
        ensure_blocking_stdio
        "$s"
        echo "$s" >>"$PROGRESS_PATH"
        ok "Step ${CURRENT_STEP} finished."
    done
}

# ============================================================================
# TUI front end (dialog, or whiptail as a fallback)
#
# The questions and the installation engine are shared with the console
# installer. This layer renders the shared prompt helpers (choose, ask,
# yesno, ...) as dialog boxes, and adds a main menu from which each section
# can be opened, changed or discarded on its own.
#
# Explanations printed with say/info/warn are collected and shown in the next
# dialog box, so every question keeps its explanation.
# ============================================================================

TUI_ACTIVE="no"       # yes while dialogs are used (setup and the final questions)
TUI_AUTO="no"         # yes while a section is silently filled in with its defaults
TUI_PHASE="setup"     # setup, then finish after the installation
TUI_BIN=""
TUI_BUF=""            # text collected for the next dialog box
TUI_SECTION="Gentoo Installer"
TUI_TITLE="Gentoo Installer"
TUI_OUT=""
TUI_TEXT=""
TUI_TEXTLINES=0
TUI_MAXH=20; TUI_BOXW=74
TUI_COMMON=(); TUI_NOTAGS=(); TUI_PWOPT=(); TUI_SCROLL=()
IN_SECTION="no"
CFG_ERRORS=(); CFG_NOTES=()
BACKTITLE="Gentoo Linux installer ${SCRIPT_VERSION}   |   Arrows/Tab: move   Space: tick   Enter: OK   Esc: back"

declare -A SEC_STATE=()
declare -A SEC_FN=([sys]=q_system_type [disk]=q_disk_layout [region]=q_region
                   [acct]=q_accounts [hw]=q_hardware_network [sw]=q_software)
declare -A SEC_VARS=(
    [sys]="DE DM SWAY_AUTOSTART INIT USE_BINPKG BINHOST_V3 TUNE_CPU_FLAGS KERNEL_PKG"
    [region]="NEW_HOSTNAME TIMEZONE LOCALE XKB_LAYOUT XKB_VARIANT"
    [hw]="GPU_DRIVER VIDEO_CARDS NET_TOOL WANT_BT WANT_CUPS WANT_SSH"
    [sw]="GENTOO_MIRRORS_VALUE WANT_FLATPAK FLATPAK_APPS EXTRA_PKGS"
)
SEC_ORDER=(sys disk region acct hw sw)

# Keep the console versions of the front-end functions as cli_<name>.
for __fn in say say_pre section subsection info ok warn die run choose choose_multi ask ask_yn ask_password pause handoff_screen ask_timezone; do
    eval "$(declare -f "$__fn" | sed "1s/^${__fn} /cli_${__fn} /")"
done
unset __fn

usage() {
    cat <<EOF
gentoo-install-tui.sh ${SCRIPT_VERSION}: guided Gentoo Linux installer for amd64 (menu version)

Usage:
  bash gentoo-install-tui.sh            Start a new installation
  bash gentoo-install-tui.sh --resume   Continue after fixing a failed step
  bash gentoo-install-tui.sh --help     Show this help

Needs 'dialog' (included on the official Gentoo live images) or 'whiptail'.
Run it as root. Download it first, then run it; piping it into bash does not
work because the installer reads your answers from the keyboard.
EOF
}

# ----------------------------------------------------------------------------
# Low-level dialog helpers
# ----------------------------------------------------------------------------
tui_init() {
    if have dialog; then
        TUI_BIN="dialog"
        TUI_COMMON=(--cr-wrap --no-collapse)
        TUI_NOTAGS=(--no-tags)
        TUI_PWOPT=(--insecure)
        TUI_SCROLL=(--exit-label "OK")
    elif have whiptail; then
        TUI_BIN="whiptail"
        TUI_COMMON=()
        TUI_NOTAGS=(--notags)
        TUI_PWOPT=()
        TUI_SCROLL=(--scrolltext)
    else
        die "The menu version needs 'dialog' or 'whiptail', and neither is installed on this live system. Use the console version instead: curl -fsSLO https://raw.githubusercontent.com/NullAngst/Gentoo-Installer/main/gentoo-install.sh && bash gentoo-install.sh"
    fi
    tui_dims
    log "TUI front end: ${TUI_BIN}"
}

tui_dims() {
    local h w
    h=$(tput lines 2>/dev/null || echo 24)
    w=$(tput cols 2>/dev/null || echo 80)
    [[ $h =~ ^[0-9]+$ ]] || h=24
    [[ $w =~ ^[0-9]+$ ]] || w=80
    TUI_MAXH=$(( h - 4 ))
    TUI_MAXH=$(( TUI_MAXH < 12 ? 12 : TUI_MAXH ))
    TUI_BOXW=$(( w - 6 ))
    TUI_BOXW=$(( TUI_BOXW > 100 ? 100 : TUI_BOXW ))
    TUI_BOXW=$(( TUI_BOXW < 50 ? 50 : TUI_BOXW ))
}

# tui_lines TEXT WIDTH: number of lines TEXT takes when wrapped at WIDTH.
tui_clear() {
    clear 2>/dev/null || printf '\033[H\033[2J' || true
}

tui_lines() {
    printf '%s\n' "$1" | fold -s -w "$2" | wc -l
}

# tui_call WIDGET-ARGS...: run dialog/whiptail. The selection ends up in TUI_OUT.
tui_call() {
    local __tc_rc=0
    TUI_OUT=$("$TUI_BIN" "${TUI_COMMON[@]}" --backtitle "$BACKTITLE" --title " ${TUI_TITLE} " "$@" 3>&1 1>&2 2>&3) || __tc_rc=$?
    # Cancel (1) and Esc (255) produce no output. Any other failure, or a failure
    # that printed a message, means dialog itself broke (for example a box that
    # cannot fit the terminal); stop instead of looping on a dialog that keeps failing.
    if (( __tc_rc != 0 )) && { [[ -n $TUI_OUT ]] || (( __tc_rc != 1 && __tc_rc != 255 )); }; then
        tui_fatal "${TUI_BIN} failed (exit code ${__tc_rc}): ${TUI_OUT:-no message}"
    fi
    return "$__tc_rc"
}

# Stop without using dialog, which is the thing that failed.
tui_fatal() {
    tui_clear
    TUI_ACTIVE="no"
    log "FAIL: $*"
    err "$*"
    err "Try a larger terminal window, or use the console installer (gentoo-install.sh), which asks the same questions."
    exit 1
}

tui_buf_add() {
    if [[ -n $TUI_BUF ]]; then TUI_BUF+=$'\n\n'; fi
    TUI_BUF+=$1
}

# tui_fit QUESTION LIST_LENGTH WIDTH: combine the collected text with QUESTION into
# TUI_TEXT. If that would not fit on screen next to the list, the collected text
# is shown on its own first.
tui_fit() {
    local q=$1 n=$2 w=$3 buf=$TUI_BUF text lines min_list
    TUI_BUF=""
    text=$buf
    if [[ -n $text ]]; then text+=$'\n\n'; fi
    text+=$q
    min_list=$(( n < 4 ? n : 4 ))
    lines=$(tui_lines "$text" $(( w - 4 )))
    if (( lines + min_list + 8 > TUI_MAXH )) && [[ -n $buf ]]; then
        tui_show "$buf"
        text=$q
        lines=$(tui_lines "$text" $(( w - 4 )))
    fi
    TUI_TEXT=$text
    TUI_TEXTLINES=$lines
}

# tui_show TEXT: a message box, or a scrollable text box when TEXT is long.
tui_show() {
    local text=$1 lines tmp
    tui_dims
    lines=$(tui_lines "$text" $(( TUI_BOXW - 4 )))
    if (( lines + 6 > TUI_MAXH )); then
        tmp=$(mktemp)
        printf '%s\n' "$text" | fold -s -w $(( TUI_BOXW - 4 )) >"$tmp"
        tui_call "${TUI_SCROLL[@]}" --textbox "$tmp" "$TUI_MAXH" "$TUI_BOXW" || true
        rm -f "$tmp"
    else
        tui_call --msgbox "$text" $(( lines + 6 )) "$TUI_BOXW" || true
    fi
}

tui_quit() {
    if [[ $IN_SECTION == "yes" ]]; then exit 11; fi
    tui_clear
    TUI_ACTIVE="no"
    log "Quit from the TUI"
    if [[ $TUI_PHASE == "setup" ]]; then
        echo "Gentoo installer: quit. Nothing on disk was changed."
    fi
    exit 0
}

# Called when a dialog is cancelled (Esc or the Cancel button).
tui_cancelled() {
    local -a items=(1 "Continue where I was")
    if [[ $IN_SECTION == "yes" ]]; then
        items+=(2 "Back to the main menu (discard the changes made in this section)")
    fi
    if [[ $TUI_PHASE == "setup" ]]; then
        items+=(3 "Quit the installer (nothing on disk has been changed)")
    else
        items+=(3 "Quit the installer")
    fi
    tui_dims
    if ! tui_call "${TUI_NOTAGS[@]}" --menu "You pressed Esc or Cancel. What would you like to do?" 12 "$TUI_BOXW" 3 "${items[@]}"; then
        return 0
    fi
    case "$TUI_OUT" in
        2) exit 10 ;;
        3) tui_quit ;;
    esac
    return 0
}

# ----------------------------------------------------------------------------
# Dialog versions of the shared prompt helpers
# ----------------------------------------------------------------------------
tui_say() {
    local p
    if [[ $TUI_AUTO == "yes" ]]; then return 0; fi
    for p in "$@"; do tui_buf_add "$p"; done
}

tui_say_pre() {
    if [[ $TUI_AUTO == "yes" ]]; then return 0; fi
    tui_buf_add "$1"
}

tui_section() {
    log "===== $* ====="
    if [[ $TUI_AUTO == "yes" ]]; then return 0; fi
    TUI_SECTION="$*"
    TUI_TITLE="$*"
    TUI_BUF=""
}

tui_subsection() {
    log "--- $* ---"
    if [[ $TUI_AUTO == "yes" ]]; then return 0; fi
    TUI_TITLE="${TUI_SECTION} > $*"
}

# Short status messages: shown right away in a small box, and kept for the next dialog.
tui_info() {
    log "INFO: $*"
    if [[ $TUI_AUTO == "yes" ]]; then return 0; fi
    tui_buf_add "$*"
    tui_dims
    "$TUI_BIN" "${TUI_COMMON[@]}" --backtitle "$BACKTITLE" --title " ${TUI_TITLE} " \
        --infobox "$*" $(( $(tui_lines "$*" $(( TUI_BOXW - 4 ))) + 4 )) "$TUI_BOXW" 2>/dev/null || true
}

tui_warn() {
    log "WARN: $*"
    if [[ $TUI_AUTO == "yes" ]]; then return 0; fi
    tui_buf_add "WARNING: $*"
}

tui_die() {
    log "FAIL: $*"
    TUI_BUF=""
    tui_show "Error: $*"$'\n\n'"The log is in ${LOG}."
    tui_clear
    TUI_ACTIVE="no"
    err "$*"
    exit 1
}

tui_run() {
    log "RUN: $*"
    "$@" >>"$LOG" 2>&1
}

tui_pause() {
    local t
    if [[ $TUI_AUTO == "yes" || -z $TUI_BUF ]]; then return 0; fi
    t=$TUI_BUF
    TUI_BUF=""
    tui_show "$t"
}

tui_handoff_screen() {
    tui_clear
}

# tui_choose VAR "Question" DEFAULT "value|Label" ...
tui_choose() {
    local __var=$1 __q=$2 __def=$3
    shift 3
    local -a __vals=() __items=()
    local __o __i=0 __defi=1 __maxl=20 __w __lh __h __text
    for __o in "$@"; do
        __i=$(( __i + 1 ))
        __vals+=("${__o%%|*}")
        __items+=("$__i" "${__o#*|}")
        if [[ ${__o%%|*} == "$__def" ]]; then __defi=$__i; fi
        if (( ${#__o} > __maxl )); then __maxl=${#__o}; fi
    done
    if [[ $TUI_AUTO == "yes" ]]; then
        printf -v "$__var" '%s' "${__vals[__defi - 1]}"
        log "DEFAULT: ${__q} => ${__vals[__defi - 1]}"
        return 0
    fi
    tui_dims
    __w=$(( __maxl + 14 ))
    __w=$(( __w < 60 ? 60 : __w ))
    __w=$(( __w > TUI_BOXW ? TUI_BOXW : __w ))
    tui_fit "$__q" "${#__vals[@]}" "$__w"
    __text=$TUI_TEXT
    __lh=$(( TUI_MAXH - TUI_TEXTLINES - 8 ))
    __lh=$(( __lh > ${#__vals[@]} ? ${#__vals[@]} : __lh ))
    __lh=$(( __lh < 2 ? 2 : __lh ))
    __h=$(( TUI_TEXTLINES + __lh + 8 ))
    __h=$(( __h > TUI_MAXH ? TUI_MAXH : __h ))
    while true; do
        if tui_call "${TUI_NOTAGS[@]}" --default-item "$__defi" --menu "$__text" "$__h" "$__w" "$__lh" "${__items[@]}"; then
            if [[ $TUI_OUT =~ ^[0-9]+$ ]] && (( TUI_OUT >= 1 && TUI_OUT <= ${#__vals[@]} )); then
                printf -v "$__var" '%s' "${__vals[TUI_OUT - 1]}"
                log "ANSWER: ${__q} => ${__vals[TUI_OUT - 1]}"
                return 0
            fi
        else
            tui_cancelled
        fi
    done
}

# tui_choose_multi VAR "Question" "value|Label" ...  (entries already in VAR start ticked)
tui_choose_multi() {
    local __var=$1 __q=$2
    shift 2
    local __cur=" ${!__var:-} " __o __i=0 __st __out="" __t __w __maxl=20 __lh __h __text
    local -a __vals=() __items=()
    for __o in "$@"; do
        __i=$(( __i + 1 ))
        __vals+=("${__o%%|*}")
        __st="off"
        if [[ $__cur == *" ${__o%%|*} "* ]]; then
            __st="on"
            __out+="${__out:+ }${__o%%|*}"
        fi
        __items+=("$__i" "${__o#*|}" "$__st")
        if (( ${#__o} > __maxl )); then __maxl=${#__o}; fi
    done
    if [[ $TUI_AUTO == "yes" ]]; then
        printf -v "$__var" '%s' "$__out"
        log "DEFAULT: ${__q} => ${__out:-none}"
        return 0
    fi
    tui_dims
    __w=$(( __maxl + 18 ))
    __w=$(( __w < 60 ? 60 : __w ))
    __w=$(( __w > TUI_BOXW ? TUI_BOXW : __w ))
    tui_fit "${__q}"$'\n'"Space ticks or unticks an entry, Enter confirms. Leave all unticked for none." "${#__vals[@]}" "$__w"
    __text=$TUI_TEXT
    __lh=$(( TUI_MAXH - TUI_TEXTLINES - 8 ))
    __lh=$(( __lh > ${#__vals[@]} ? ${#__vals[@]} : __lh ))
    __lh=$(( __lh < 2 ? 2 : __lh ))
    __h=$(( TUI_TEXTLINES + __lh + 8 ))
    __h=$(( __h > TUI_MAXH ? TUI_MAXH : __h ))
    while true; do
        if tui_call --separate-output "${TUI_NOTAGS[@]}" --checklist "$__text" "$__h" "$__w" "$__lh" "${__items[@]}"; then
            __out=""
            while IFS= read -r __t; do
                __t=${__t//\"/}
                if [[ $__t =~ ^[0-9]+$ ]] && (( __t >= 1 && __t <= ${#__vals[@]} )); then
                    __out+="${__out:+ }${__vals[__t - 1]}"
                fi
            done <<<"$TUI_OUT"
            printf -v "$__var" '%s' "$__out"
            log "ANSWER: ${__q} => ${__out:-none}"
            return 0
        fi
        tui_cancelled
    done
}

# tui_ask VAR "Question" "default" [validator]
tui_ask() {
    local __var=$1 __q=$2 __def=${3:-} __check=${4:-} __a __cur __h
    if [[ $TUI_AUTO == "yes" ]]; then
        if [[ -n $__def ]] && { [[ -z $__check ]] || "$__check" "$__def"; }; then
            printf -v "$__var" '%s' "$__def"
            log "DEFAULT: ${__q} => ${__def}"
            return 0
        fi
        die "Internal error: no usable default for '${__q}'."
    fi
    __cur=$__def
    while true; do
        tui_dims
        tui_fit "$__q" 1 "$TUI_BOXW"
        __h=$(( TUI_TEXTLINES + 8 ))
        __h=$(( __h > TUI_MAXH ? TUI_MAXH : __h ))
        if tui_call --inputbox "$TUI_TEXT" "$__h" "$TUI_BOXW" "$__cur"; then
            __a=$(trim "$TUI_OUT")
            __cur=$__a
            if [[ -z $__a ]]; then __a=$__def; fi
            if [[ -z $__a ]]; then
                tui_buf_add "An answer is required."
                continue
            fi
            if [[ -n $__check ]] && ! "$__check" "$__a"; then
                continue
            fi
            printf -v "$__var" '%s' "$__a"
            log "ANSWER: ${__q} => ${__a}"
            return 0
        fi
        tui_cancelled
    done
}

# tui_ask_yn VAR "Question" y|n
tui_ask_yn() {
    local __var=$1 __q=$2 __def=$3 __h __rc __text
    local -a __f=()
    if [[ $TUI_AUTO == "yes" ]]; then
        if [[ $__def == "y" ]]; then printf -v "$__var" 'yes'; else printf -v "$__var" 'no'; fi
        log "DEFAULT: ${__q} => ${!__var}"
        return 0
    fi
    if [[ $__def == "n" ]]; then __f=(--defaultno); fi
    tui_dims
    tui_fit "$__q" 0 "$TUI_BOXW"
    __text=$TUI_TEXT
    __h=$(( TUI_TEXTLINES + 6 ))
    __h=$(( __h > TUI_MAXH ? TUI_MAXH : __h ))
    while true; do
        __rc=0
        tui_call "${__f[@]}" --yesno "$__text" "$__h" "$TUI_BOXW" || __rc=$?
        case "$__rc" in
            0) printf -v "$__var" 'yes'; break ;;
            1) printf -v "$__var" 'no'; break ;;
            *)
                if [[ $TUI_PHASE == "finish" ]]; then
                    printf -v "$__var" 'no'
                    break
                fi
                tui_cancelled
                ;;
        esac
    done
    log "ANSWER: ${__q} => ${!__var}"
}

# tui_ask_password VAR "what" MIN_LENGTH
tui_ask_password() {
    local __var=$1 __what=$2 __min=${3:-1} __p1 __p2 __h
    if [[ $TUI_AUTO == "yes" ]]; then
        die "Internal error: a password cannot be filled in automatically."
    fi
    while true; do
        tui_dims
        tui_fit "Type the ${__what}:" 0 "$TUI_BOXW"
        __h=$(( TUI_TEXTLINES + 8 ))
        __h=$(( __h > TUI_MAXH ? TUI_MAXH : __h ))
        if ! tui_call "${TUI_PWOPT[@]}" --passwordbox "$TUI_TEXT" "$__h" "$TUI_BOXW"; then
            tui_cancelled
            continue
        fi
        __p1=$TUI_OUT
        if (( ${#__p1} < __min )); then
            if (( __min == 1 )); then tui_buf_add "It cannot be empty."; else tui_buf_add "It must be at least ${__min} characters long."; fi
            continue
        fi
        if ! tui_call "${TUI_PWOPT[@]}" --passwordbox "Type the ${__what} again to confirm:" 9 "$TUI_BOXW"; then
            tui_cancelled
            continue
        fi
        __p2=$TUI_OUT
        TUI_OUT=""
        if [[ $__p1 != "$__p2" ]]; then
            tui_buf_add "The two entries did not match. Try again."
            continue
        fi
        if (( ${#__p1} < 8 )); then
            tui_buf_add "That is shorter than 8 characters, which is easy to guess."
            if ! yesno "Use it anyway?" n; then continue; fi
        fi
        printf -v "$__var" '%s' "$__p1"
        log "ANSWER: ${__what} => (hidden)"
        return 0
    done
}

# Timezone: a region menu and a city menu instead of typing.
tui_ask_timezone() {
    local how cur=${TIMEZONE:-UTC} region city names
    local -a items=()
    if [[ $TUI_AUTO == "yes" ]]; then
        TIMEZONE=$cur
        return 0
    fi
    while true; do
        say "The timezone sets your local time. It is currently set to ${cur}."
        choose how "Timezone" "keep" \
            "keep|Keep ${cur}" \
            "browse|Pick from a list (region, then city)" \
            "type|Type it (for example America/New_York)"
        case "$how" in
            keep)
                TIMEZONE=$cur
                return 0 ;;
            type)
                ask TIMEZONE "Timezone (Region/City)" "$cur" valid_timezone
                return 0 ;;
            browse)
                names=$(tz_names)
                items=()
                while read -r region; do
                    items+=("${region}|${region}")
                done < <(awk -F/ 'NF > 1 {print $1}' <<<"$names" | sort -u)
                items+=("UTC|UTC (no time zone offset)")
                choose region "Region" "${cur%%/*}" "${items[@]}"
                if [[ $region == "UTC" ]]; then
                    TIMEZONE="UTC"
                    return 0
                fi
                items=()
                while read -r city; do
                    items+=("${region}/${city}|${city//_/ }")
                done < <(awk -v r="${region}/" 'index($0, r) == 1 {print substr($0, length(r) + 1)}' <<<"$names")
                choose TIMEZONE "City in ${region}" "$cur" "${items[@]}"
                return 0 ;;
        esac
    done
}

browse_timezones() {
    warn "Browsing is done with the 'Pick from a list' option in the timezone menu."
}

# ----------------------------------------------------------------------------
# Front-end dispatch: dialogs while TUI_ACTIVE=yes, console output otherwise
# (during the unattended installation, which prints its progress as text).
# ----------------------------------------------------------------------------
say()            { if [[ $TUI_ACTIVE == "yes" ]]; then tui_say "$@"; else cli_say "$@"; fi; }
say_pre()        { if [[ $TUI_ACTIVE == "yes" ]]; then tui_say_pre "$@"; else cli_say_pre "$@"; fi; }
section()        { if [[ $TUI_ACTIVE == "yes" ]]; then tui_section "$@"; else cli_section "$@"; fi; }
subsection()     { if [[ $TUI_ACTIVE == "yes" ]]; then tui_subsection "$@"; else cli_subsection "$@"; fi; }
info()           { if [[ $TUI_ACTIVE == "yes" ]]; then tui_info "$@"; else cli_info "$@"; fi; }
ok()             { if [[ $TUI_ACTIVE == "yes" ]]; then tui_info "$@"; else cli_ok "$@"; fi; }
warn()           { if [[ $TUI_ACTIVE == "yes" ]]; then tui_warn "$@"; else cli_warn "$@"; fi; }
die()            { if [[ $TUI_ACTIVE == "yes" ]]; then tui_die "$@"; else cli_die "$@"; fi; }
run()            { if [[ $TUI_ACTIVE == "yes" ]]; then tui_run "$@"; else cli_run "$@"; fi; }
choose()         { if [[ $TUI_ACTIVE == "yes" ]]; then tui_choose "$@"; else cli_choose "$@"; fi; }
choose_multi()   { if [[ $TUI_ACTIVE == "yes" ]]; then tui_choose_multi "$@"; else cli_choose_multi "$@"; fi; }
ask()            { if [[ $TUI_ACTIVE == "yes" ]]; then tui_ask "$@"; else cli_ask "$@"; fi; }
ask_yn()         { if [[ $TUI_ACTIVE == "yes" ]]; then tui_ask_yn "$@"; else cli_ask_yn "$@"; fi; }
ask_password()   { if [[ $TUI_ACTIVE == "yes" ]]; then tui_ask_password "$@"; else cli_ask_password "$@"; fi; }
pause()          { if [[ $TUI_ACTIVE == "yes" ]]; then tui_pause; else cli_pause; fi; }
handoff_screen() { if [[ $TUI_ACTIVE == "yes" ]]; then tui_handoff_screen; else cli_handoff_screen; fi; }
ask_timezone()   { if [[ $TUI_ACTIVE == "yes" ]]; then tui_ask_timezone; else cli_ask_timezone; fi; }

ui_install_phase() {
    TUI_BUF=""
    TUI_ACTIVE="no"
    tui_clear
}

ui_finish_phase() {
    TUI_ACTIVE="yes"
    TUI_PHASE="finish"
    TUI_BUF=""
}

# ----------------------------------------------------------------------------
# Sections, defaults and the main menu
# ----------------------------------------------------------------------------
tui_dump_state() {
    local v
    for v in "${CONFIG_VARS[@]}" ROOT_PASSWORD USER_PASSWORD LUKS_PASSWORD; do
        declare -p "$v"
    done | sed 's/^declare /declare -g /'
}

# Fill every section the user has not opened yet with its recommended settings,
# by running its questions silently. Re-run after each change, so that these
# defaults follow earlier choices (for example the desktop decides the init system).
tui_refresh_defaults() {
    local key v
    TUI_AUTO="yes"
    for key in sys region hw sw; do
        if [[ ${SEC_STATE[$key]:-} != "set" ]]; then
            for v in ${SEC_VARS[$key]}; do printf -v "$v" '%s' ""; done
            "${SEC_FN[$key]}"
            SEC_STATE[$key]="default"
        fi
    done
    TUI_AUTO="no"
}

# Run one section's questions in a subshell, so that "Back to the main menu"
# can discard its changes. Answers are handed back through a private temporary
# file on the live system's RAM-backed /tmp, which is deleted right after.
tui_run_section() {
    local key=$1 fn=${SEC_FN[$1]} tmp rc
    tmp=$(mktemp /tmp/.gentoo-tui-state.XXXXXX)
    chmod 600 "$tmp"
    trap - ERR
    set +e
    (
        set -e
        trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR
        IN_SECTION="yes"
        "$fn"
        tui_pause
        tui_dump_state >"$tmp"
    )
    rc=$?
    set -e
    trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR
    case "$rc" in
        0)
            load_config "$tmp"
            rm -f "$tmp"
            SEC_STATE[$key]="set"
            tui_refresh_defaults
            return 0 ;;
        10)
            rm -f "$tmp"
            log "Section ${key}: changes discarded"
            return 1 ;;
        11)
            rm -f "$tmp"
            tui_quit ;;
        *)
            rm -f "$tmp"
            exit "$rc" ;;
    esac
}

tui_sec_summary() {
    local n_fp=0 n_pk=0 a
    case "$1" in
        sys) echo "$(de_label "$DE"), ${INIT}, binary packages: ${USE_BINPKG}" ;;
        disk)
            if [[ ${SEC_STATE[disk]:-} != "set" ]]; then echo "not set yet"; return 0; fi
            a="whole disk"
            if [[ $PART_MODE == "manual" ]]; then a="manual"; fi
            echo "${DISK} (${a}), ${FS}$( [[ $ENCRYPT == yes ]] && echo " + LUKS" ), ${BOOTLOADER}" ;;
        region) echo "${NEW_HOSTNAME}, ${TIMEZONE}, ${LOCALE}" ;;
        acct)
            if [[ ${SEC_STATE[acct]:-} != "set" ]]; then echo "not set yet"; return 0; fi
            echo "${USERNAME} (${PRIV_TOOL})" ;;
        hw) echo "network: ${NET_TOOL}, graphics: ${GPU_DRIVER}, SSH: ${WANT_SSH}" ;;
        sw)
            for a in $FLATPAK_APPS; do n_fp=$(( n_fp + 1 )); done
            for a in $EXTRA_PKGS; do n_pk=$(( n_pk + 1 )); done
            echo "Flatpak: ${WANT_FLATPAK} (${n_fp} apps), ${n_pk} native packages" ;;
    esac
}

tui_hub_line() {
    local key=$1 label=$2 mark summary max
    case "${SEC_STATE[$key]:-}" in
        set) mark="[done]" ;;
        default) mark="[default]" ;;
        *) mark="[required]" ;;
    esac
    summary=$(tui_sec_summary "$key")
    max=$(( TUI_BOXW - 44 ))
    if (( max > 5 && ${#summary} > max )); then summary="${summary:0:max-3}..."; fi
    printf '%-20s %-10s %s' "$label" "$mark" "$summary"
}

tui_validate() {
    local e gui=0
    CFG_ERRORS=()
    CFG_NOTES=()
    if [[ ${SEC_STATE[disk]:-} != "set" ]]; then
        CFG_ERRORS+=("Disk: choose where to install Gentoo (section 2).")
    fi
    if [[ ${SEC_STATE[acct]:-} != "set" ]]; then
        CFG_ERRORS+=("Accounts: set the passwords and create your user (section 4).")
    fi
    if [[ ${SEC_STATE[disk]:-} == "set" ]] && (( $(target_root_gib) < $(min_root_gib) )); then
        CFG_ERRORS+=("Disk: $( [[ $PART_MODE == manual ]] && echo "${ROOT_PART}" || echo "${DISK}" ) has $(target_root_gib) GiB, but a desktop installation needs at least ${MIN_DESKTOP_DISK_GIB} GiB (section 2, or choose No desktop in section 1).")
    fi
    if [[ ${SEC_STATE[disk]:-} == "set" && $ENCRYPT == "yes" && -z $LUKS_PASSWORD ]]; then
        CFG_ERRORS+=("Disk: encryption is on but no passphrase is set (section 2).")
    fi
    if [[ $NET_TOOL == "networkd" && $INIT != "systemd" ]]; then
        CFG_ERRORS+=("Network: systemd-networkd needs systemd, but OpenRC is selected. Change the network manager (section 5) or the init system (section 1).")
    fi
    if [[ $DE != "none" && -z $XKB_LAYOUT ]]; then
        xkb_from_keymap "$KEYMAP"
        CFG_NOTES+=("The desktop keyboard layout was set to '${XKB_LAYOUT}' from the console keymap. Change it in section 3 if needed.")
    fi
    if [[ $DE == "none" ]]; then
        if [[ $WANT_FLATPAK == "yes" ]]; then
            CFG_NOTES+=("Flatpak is selected although there is no desktop; Flatpak apps are mostly graphical (section 6).")
        fi
        if [[ $WANT_CUPS == "yes" ]]; then
            CFG_NOTES+=("Printing (CUPS) is selected although there is no desktop (section 5).")
        fi
        for e in "${NATIVE_GUI_APPS[@]}"; do
            if [[ " $EXTRA_PKGS " == *" ${e%%|*} "* ]]; then gui=$(( gui + 1 )); fi
        done
        if (( gui > 0 )); then
            CFG_NOTES+=("${gui} graphical application(s) are selected although there is no desktop (section 6).")
        fi
    fi
    if [[ $HAS_WIFI == "yes" && $NET_TOOL != "networkmanager" ]]; then
        CFG_NOTES+=("This machine has Wi-Fi, but ${NET_TOOL} only sets up wired networking (section 5).")
    fi
}

tui_review() {
    local tmp C_RED="" C_RESET="" C_BOLD=""
    tui_validate
    compute_derived
    tmp=$(mktemp)
    {
        print_summary
        if (( ${#CFG_ERRORS[@]} > 0 )); then
            printf '\n  Must be fixed before installing:\n'
            printf -- '    - %s\n' "${CFG_ERRORS[@]}"
        fi
        if (( ${#CFG_NOTES[@]} > 0 )); then
            printf '\n  Notes:\n'
            printf -- '    - %s\n' "${CFG_NOTES[@]}"
        fi
    } | fold -s -w $(( TUI_BOXW - 4 )) >"$tmp"
    TUI_TITLE="Review all settings"
    tui_dims
    tui_call "${TUI_SCROLL[@]}" --textbox "$tmp" "$TUI_MAXH" "$TUI_BOXW" || true
    rm -f "$tmp"
}

tui_install_confirm() {
    local word="ERASE" what
    tui_validate
    if (( ${#CFG_ERRORS[@]} > 0 )); then
        TUI_TITLE="Not ready yet"
        tui_show "These must be done before installing:"$'\n\n'"$(printf -- '- %s\n' "${CFG_ERRORS[@]}")"
        return 1
    fi
    tui_review
    if [[ $PART_MODE == "auto" ]]; then
        what="EVERY partition and file on ${DISK} will be permanently deleted."
    else
        word="FORMAT"
        what="The partitions marked WILL BE FORMATTED in the summary will be erased."
    fi
    TUI_TITLE="Start the installation"
    if ! yesno "Install Gentoo with these settings now? ${what}" n; then
        return 1
    fi
    tui_dims
    if ! tui_call --inputbox "Last check. ${what}"$'\n\n'"Type ${word} in capital letters to start:" 11 "$TUI_BOXW" ""; then
        return 1
    fi
    if [[ $(trim "$TUI_OUT") != "$word" ]]; then
        tui_show "Not confirmed. Nothing was changed."
        return 1
    fi
    return 0
}

tui_next_item() {
    case "$1" in
        sys) echo "disk" ;;
        disk) echo "region" ;;
        region) echo "acct" ;;
        acct) echo "hw" ;;
        hw) echo "sw" ;;
        *) echo "review" ;;
    esac
}

tui_hub() {
    local def="guided" key choice text lh h
    local -a items=()
    while true; do
        TUI_TITLE="Main menu"
        TUI_BUF=""
        tui_dims
        items=(
            guided  "Guided setup: go through every section in order"
            sys     "$(tui_hub_line sys "1. System")"
            disk    "$(tui_hub_line disk "2. Disk")"
            region  "$(tui_hub_line region "3. Region")"
            acct    "$(tui_hub_line acct "4. Accounts")"
            hw      "$(tui_hub_line hw "5. Drivers & network")"
            sw      "$(tui_hub_line sw "6. Software")"
            review  "Review all settings"
            install "Install Gentoo"
            quit    "Quit without installing"
        )
        text="Pick a section to set up or change. [default] sections already hold the recommended settings; [required] ones must be done before installing. Nothing on disk changes until you choose Install and confirm."
        lh=10
        h=$(( $(tui_lines "$text" $(( TUI_BOXW - 4 ))) + lh + 8 ))
        h=$(( h > TUI_MAXH ? TUI_MAXH : h ))
        lh=$(( h - $(tui_lines "$text" $(( TUI_BOXW - 4 ))) - 8 ))
        lh=$(( lh < 3 ? 3 : lh ))
        if ! tui_call "${TUI_NOTAGS[@]}" --default-item "$def" --menu "$text" "$h" "$TUI_BOXW" "$lh" "${items[@]}"; then
            if yesno "Quit the installer? Nothing on disk has been changed." n; then tui_quit; fi
            continue
        fi
        choice=$TUI_OUT
        case "$choice" in
            guided)
                for key in "${SEC_ORDER[@]}"; do
                    if ! tui_run_section "$key"; then break; fi
                done
                def="review" ;;
            sys|disk|region|acct|hw|sw)
                if tui_run_section "$choice"; then def=$(tui_next_item "$choice"); else def=$choice; fi ;;
            review)
                tui_review
                def="install" ;;
            install)
                if tui_install_confirm; then return 0; fi
                def="install" ;;
            quit)
                if yesno "Quit without installing? Nothing on disk has been changed." n; then tui_quit; fi ;;
        esac
    done
}

tui_welcome() {
    TUI_TITLE="Welcome"
    tui_show "This installs Gentoo Linux on this computer, following the official Gentoo AMD64 Handbook.

How it works:
  1. It checks your network connection and detects your hardware.
  2. A main menu lets you set up each part of the system. Most parts start out filled in with recommended settings; only the disk and your user account have to be set by you.
  3. Nothing on disk is changed until you pick Install and type a confirmation word. (In manual partitioning mode you can edit partitions yourself with cfdisk along the way.)
  4. The installation then runs on its own and shows its progress as text. It can take from under an hour to many hours, depending on your hardware and choices.

Keys: arrow keys and Tab move, Space ticks a checkbox, Enter confirms, Esc goes back or offers to quit.

Log file: ${LOG}"
}

tui_install() {
    compute_derived
    ui_install_phase
    resolve_stage3
    prepare_disk
    install_stage3
    mount_pseudo
    hash_passwords
    write_target_config
    run_chroot_stage
    ui_finish_phase
    finish_install
    tui_pause
    tui_clear
    TUI_ACTIVE="no"
}

tui_fresh_install() {
    live_preflight
    rm -f /tmp/.gentoo-tui-state.* 2>/dev/null || true
    : >"$LOG"
    log "gentoo-install-tui.sh ${SCRIPT_VERSION} started"
    init_defaults
    tui_init
    TUI_ACTIVE="yes"
    tui_welcome
    live_keyboard
    network_step
    sync_clock
    detect_hardware
    show_hardware
    tui_refresh_defaults
    tui_hub
    tui_install
}

# ----------------------------------------------------------------------------
# Entry point (menu version)
# ----------------------------------------------------------------------------
main() {
    case "${1:-}" in
        -h|--help)
            usage
            return 0
            ;;
    esac
    if [[ ! -t 0 ]]; then
        echo "This installer is interactive and needs a keyboard on standard input." >&2
        echo "Download it first, then run it:" >&2
        echo "  curl -fsSLO https://raw.githubusercontent.com/NullAngst/Gentoo-Installer/main/gentoo-install-tui.sh" >&2
        echo "  bash gentoo-install-tui.sh" >&2
        exit 1
    fi
    SELF=$(readlink -f "${BASH_SOURCE[0]}")
    trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR
    trap on_interrupt INT
    case "${1:-}" in
        --chroot-stage)
            chroot_stage
            ;;
        --resume)
            live_preflight
            init_defaults
            log "gentoo-install-tui.sh ${SCRIPT_VERSION} resuming"
            tui_init
            TUI_ACTIVE="yes"
            detect_hardware
            resume_install
            tui_pause
            tui_clear
            TUI_ACTIVE="no"
            ;;
        "")
            tui_fresh_install
            ;;
        *)
            usage
            die "Unknown option: $1"
            ;;
    esac
}

# Run main unless the file is being sourced (for example by a test harness).
if [[ "${BASH_SOURCE[0]:-}" == "$0" || -z "${BASH_SOURCE[0]:-}" ]]; then
    main "$@"
fi
