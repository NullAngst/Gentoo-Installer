#!/usr/bin/env bash
# =============================================================================
#  gentoo_install.sh / gentoo_install_tui.sh: guided Gentoo Linux installer for amd64
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
#      curl -fsSLO https://raw.githubusercontent.com/NullAngst/Gentoo-Installer/refs/heads/main/gentoo_install_tui.sh
#      bash gentoo_install_tui.sh
#    Console version:
#      curl -fsSLO https://raw.githubusercontent.com/NullAngst/Gentoo-Installer/refs/heads/main/gentoo_install.sh
#      bash gentoo_install.sh
#
#  Do not pipe it into bash (curl ... | bash). The script is interactive and
#  reads your answers from the keyboard.
#
#  Options
#    -r, --resume   Continue an installation that stopped because of an error
#    -h, --help     Show help
#
#  Logs
#    /tmp/gentoo-install.log        (live system)
#    /var/log/gentoo-install.log    (inside the new system)
#
#  Needs bash 4.4 or newer. Built from src/ by build.sh: edit those files,
#  not the generated installers.
# =============================================================================

set -Eeuo pipefail

readonly SCRIPT_VERSION="1.4.0"
readonly MNT="/mnt/gentoo"
readonly LIVE_LOG="/tmp/gentoo-install.log"
readonly LIVE_CONF_COPY="/tmp/gentoo-install.conf"
readonly TARGET_LOG="/var/log/gentoo-install.log"
readonly CONF_PATH="/root/gentoo-install.conf"
readonly PROGRESS_PATH="/root/.gentoo-install-progress"
readonly FAILED_PATH="/root/.gentoo-install-failed-optional"
readonly SCRIPT_PATH="/root/gentoo_install.sh"
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
WORK_DIR=""

# Every answer and detected value that the second (chroot) stage needs.
CONFIG_VARS=(
    DE DM INIT SWAY_AUTOSTART USE_BINPKG BINHOST_V3 TUNE_CPU_FLAGS KERNEL_PKG
    BOOT_MODE UEFI_BITS BOOTLOADER PART_MODE PTABLE DISK ESP_PART FORMAT_ESP BIOS_PART BOOT_PART
    ROOT_PART SWAP_PART GRUB_DISK DUAL_BOOT NEED_BOOT_PART IS_SSD
    FS ENCRYPT SWAP_MODE SWAP_SIZE_GIB
    NEW_HOSTNAME TIMEZONE LOCALE KEYMAP XKB_LAYOUT XKB_VARIANT
    USERNAME PRIV_TOOL ROOT_HASH USER_HASH
    NET_TOOL WANT_BT WANT_CUPS WANT_SSH WANT_FLATPAK FLATPAK_APPS EXTRA_PKGS
    CPU_VENDOR CPU_MODEL NPROC RAM_GIB IS_LAPTOP HAS_WIFI HAS_BT VIRT SECURE_BOOT
    HAS_NVIDIA HAS_AMD HAS_INTEL GPU_VM GPU_DRIVER VIDEO_CARDS NVIDIA_GEN HYBRID_GPU
    IS_APPLE MAC_MODEL LIVE_BOOT_MODE USER_SHELL
    BCM_WIFI WANT_BCM_WL WANT_POWER POWER_TOOL WANT_MBPFAN
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
    USER_SHELL="bash"
    PTABLE="gpt"
    ROOT_PASSWORD=""
    USER_PASSWORD=""
    LUKS_PASSWORD=""
    STAGE3_URL=""
    STAGE3_FILE=""
}

# ----------------------------------------------------------------------------
# Temporary files: everything goes into one private directory that is removed
# when the script exits.
# ----------------------------------------------------------------------------
make_work_dir() {
    if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then return 0; fi
    WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/gentoo_install.XXXXXX")
    chmod 700 -- "$WORK_DIR"
}

remove_work_dir() {
    if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then rm -rf -- "$WORK_DIR"; fi
    WORK_DIR=""
}

# work_file NAME: a new private temporary file (prints its path).
work_file() {
    make_work_dir
    mktemp "${WORK_DIR}/${1:-tmp}.XXXXXX"
}

# self_path: the absolute path of this script, without GNU readlink -f.
self_path() {
    local dir base
    dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || return 1
    base=$(basename -- "${BASH_SOURCE[0]}")
    printf '%s/%s\n' "$dir" "$base"
}

# sed_inplace SCRIPT FILE: edit FILE with sed, portably (no GNU sed -i).
sed_inplace() {
    local script=$1 file=$2 tmp
    tmp=$(mktemp "${file}.XXXXXX")
    if sed "$script" "$file" >"$tmp"; then
        cat -- "$tmp" >"$file"
        rm -f -- "$tmp"
    else
        rm -f -- "$tmp"
        return 1
    fi
}

# strip_colors: remove terminal colour codes from standard input
# (portable: no \x escapes in the sed script).
strip_colors() {
    local esc
    esc=$(printf '\033')
    sed "s/${esc}\[[0-9;]*m//g"
}

# clear_dir DIR: delete everything inside DIR, keeping DIR itself.
clear_dir() {
    if [ -d "$1" ]; then
        find "$1" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null || true
    fi
}

# Login shells offered for the user account. These are the interactive login
# shells in Gentoo's app-shells category with a stable amd64 version.
# Fields: choice|packages (space separated)|command name|menu label
SHELL_CATALOG=(
    "bash|app-shells/bash|bash|bash (Gentoo's default, recommended)"
    "zsh|app-shells/zsh app-shells/gentoo-zsh-completions|zsh|zsh (bash-like, more interactive features)"
    "fish|app-shells/fish|fish|fish (friendly, good defaults; not POSIX)"
    "nushell|app-shells/nushell|nu|Nushell (structured data; not POSIX)"
    "dash|app-shells/dash|dash|sh: dash (minimal POSIX sh)"
    "ksh|app-shells/ksh|ksh|ksh (AT&T Korn shell)"
    "mksh|app-shells/mksh|mksh|mksh (MirBSD Korn shell)"
    "loksh|app-shells/loksh|ksh|loksh (OpenBSD Korn shell)"
    "yash|app-shells/yash|yash|yash (strict POSIX, with line editing)"
    "tcsh|app-shells/tcsh|tcsh|tcsh (C shell syntax)"
)

# shell_field CHOICE N: field N (1-4) of a SHELL_CATALOG entry.
shell_field() {
    local entry
    for entry in "${SHELL_CATALOG[@]}"; do
        if [ "${entry%%|*}" = "$1" ]; then
            cut -d'|' -f"$2" <<<"$entry"
            return 0
        fi
    done
    return 1
}

valid_shell_choice() { shell_field "$1" 1 >/dev/null; }

# ----------------------------------------------------------------------------
# Output helpers
# ----------------------------------------------------------------------------
if [ -t 1 ]; then
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
    w=$(tput cols 2>/dev/null || printf '%s\n' 80)
    [[ $w =~ ^[0-9]+$ ]] || w=80
    if (( w > 100 )); then w=100; fi
    if (( w < 50 )); then w=50; fi
    printf '%s\n' "$w"
}

hr() {
    local w line
    w=$(term_width)
    printf -v line '%*s' "$w" ''
    printf '%s%s%s\n' "$C_BLUE" "${line// /=}" "$C_RESET"
}

cli_section() {
    printf '\n'
    hr
    printf '%s  %s%s\n' "$C_BOLD" "$*" "$C_RESET"
    hr
    log "===== $* ====="
}

cli_subsection() {
    printf '\n'
    printf '%s--- %s ---%s\n' "$C_BOLD$C_CYAN" "$*" "$C_RESET"
    log "--- $* ---"
}

# say "paragraph" ["paragraph" ...]: print wrapped, indented paragraphs.
cli_say() {
    local w p
    w=$(( $(term_width) - 4 ))
    for p in "$@"; do
        printf '%s\n' "$p" | fold -s -w "$w" | sed 's/^/  /'
        printf '\n'
    done
}

# say_pre "text": show preformatted text (tables, lists) without re-wrapping.
cli_say_pre() {
    printf '%s\n\n' "$1"
}

# Front-end hooks: handoff_screen runs before a full-screen program (cfdisk,
# nmtui, a shell) takes over, ui_install_phase when the unattended
# installation starts, ui_finish_phase before the final questions. The console
# front end needs none of them (src/90_main_cli.sh); the TUI defines them.
cli_handoff_screen() { :; }

# yn_default VAR FALLBACK: the y/n default for a question whose previous answer is in VAR.
yn_default() {
    case "${!1:-}" in
        yes) printf '%s\n' "y" ;;
        no) printf '%s\n' "n" ;;
        *) printf '%s\n' "$2" ;;
    esac
}

cli_info() { printf '%s[ INFO ]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; log "INFO: $*"; }
cli_ok() { printf '%s[  OK  ]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; log "OK: $*"; }
cli_warn() { printf '%s[ WARN ]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; log "WARN: $*"; }
err()  { printf '%s[ FAIL ]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; log "FAIL: $*"; }
cli_die() { err "$*"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# run CMD ARGS...: show the command, run it, copy its output into the log.
# RUN_CMD remembers the command, because when it fails the error trap only sees
# the last part of the pipeline (tee).
RUN_CMD=""
cli_run() {
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
    if [ -z "$blog" ] || [ ! -r "$blog" ]; then return 0; fi
    local pattern="\\*\\*\\* \\[|error:|Error [0-9]+|Can't locate|No such file or directory|Illegal instruction|Segmentation fault|Killed|undefined reference|command not found|can't get .--help' info"
    errors=$(grep -nE "$pattern" "$blog" 2>/dev/null \
        | grep -vE "^[0-9]+:(checking|configure:)|-Werror|-Wno-error" || true)
    local first=${errors%%:*} from
    {
        printf '\n'
        printf '%s\n' "---- Why it failed: lines from the package's build log ----"
        printf '%s\n' "Build log: ${blog}"
        printf '%s\n' "(from the live system: ${MNT}${blog})"
        if [[ $first =~ ^[0-9]+$ ]]; then
            from=$(( first > 12 ? first - 12 : 1 ))
            printf '\n'
            printf '%s\n' "Where it first went wrong (lines ${from}-$(( first + 3 )); the cause is usually just above the first '***' or 'error' line):"
            sed -n "${from},$(( first + 3 ))p" "$blog"
        fi
        printf '\n'
        printf '%s\n' "Last lines of the build log:"
        tail -n 25 "$blog"
        printf '\n'
        if grep -q "Can't locate .*\.pm in @INC" "$blog" 2>/dev/null; then
            printf '%s\n' "A Perl module could not be loaded. This usually happens after Perl was"
            printf '%s\n' "upgraded and its modules were not rebuilt. Fix it from the live system with:"
            printf '%s\n' "  chroot ${MNT} /bin/bash -c 'source /etc/profile && perl-cleaner --all -- --quiet-build=y'"
            printf '%s\n' "then resume the installer."
            printf '\n'
        fi
        if [ -z "$errors" ] && [ -n "$(tail -c 1 "$blog")" ]; then
            printf '%s\n' "The build log stops in the middle of a line without any error message:"
            printf '%s\n' "the build lost its output channel before it could report anything."
            printf '%s\n' "Possible causes: Portage could not write the build output to the screen,"
            printf '%s\n' "the disk is full, or the filesystem became read-only (free space below)."
        fi
        printf '%s\n' "Free space on the new system's root filesystem:"
        df -h / 2>/dev/null | sed 's/^/    /' || true
        printf '%s\n' "------------------------------------------------------------"
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
    dirs+=("$(portageq envvar PKGDIR 2>/dev/null || printf '%s\n' /var/cache/binpkgs)")
    dirs+=("/var/cache/binhost")
    # binrepos.conf may be a file or a directory of files; read regular files only.
    for conf in /etc/portage/binrepos.conf /etc/portage/binrepos.conf/*.conf; do
        [ -f "$conf" ] || continue
        while IFS= read -r loc; do
            if [ -n "$loc" ]; then dirs+=("$loc"); fi
        done < <(sed -n 's/^[[:space:]]*location[[:space:]]*=[[:space:]]*//p' "$conf")
    done
    if [ "${1:-}" = "--all" ]; then
        dirs+=("$(portageq envvar DISTDIR 2>/dev/null || printf '%s\n' /var/cache/distfiles)")
        dirs+=("$(portageq envvar PORTAGE_TMPDIR 2>/dev/null || printf '%s\n' /var/tmp)/portage")
    fi
    for dir in "${dirs[@]}"; do
        dir=$(trim "$dir")
        if [ -n "$dir" ] && [ "$dir" != "/" ] && [ -d "$dir" ]; then
            clear_dir "$dir"
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
    if [ -f "${MNT}${CONF_PATH}" ]; then
        printf '\n'
        say "Nothing is lost. Every finished step is recorded, so the installer can continue where it stopped." \
            "What to do: 1) Read the end of the log to see what went wrong. 2) Fix the cause (common ones: a network hiccup, a package that needs a USE flag change, a full disk). 3) Run:  bash ${SELF:-gentoo_install.sh} --resume" \
            "To fix something inside the new system first, run:  chroot ${MNT} /bin/bash  then  source /etc/profile. Type exit when done, then resume."
    fi
}

on_error() {
    local rc=$1 line=$2 cmd=$3
    trap - ERR
    if [ "${TUI_ACTIVE:-no}" = "yes" ]; then clear 2>/dev/null || true; TUI_ACTIVE="no"; fi
    if (( rc == 0 )); then rc=1; fi
    # shellcheck disable=SC2016  # the literal text of run's tee command, as the trap reports it
    if [ "$cmd" = 'tee -a "$LOG"' ] && [ -n "${RUN_CMD:-}" ]; then cmd=$RUN_CMD; fi
    printf '\n'
    err "A command failed (exit code ${rc}, script line ${line}):"
    err "    ${cmd}"
    err "Full log: ${LOG}"
    if [ "$IN_CHROOT" = "yes" ]; then
        err "This happened inside the new system during step ${CURRENT_STEP:-unknown}."
        if [[ $cmd = emerge* ]]; then show_build_log_excerpt; fi
    else
        print_resume_help
    fi
    exit "$rc"
}

on_interrupt() {
    trap - ERR INT
    if [ "${TUI_ACTIVE:-no}" = "yes" ]; then clear 2>/dev/null || true; TUI_ACTIVE="no"; fi
    printf '\n'
    err "Interrupted by user (Ctrl+C)."
    if [ "$IN_CHROOT" != "yes" ]; then
        print_resume_help
    fi
    exit 130
}

# Source a shell file without letting it trip errexit, nounset or the ERR trap.
safe_source() {
    trap - ERR
    set +eu
    # shellcheck disable=SC1090
    . "$1"
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
        printf '\n'
        die "Input ended unexpectedly. Run the script from an interactive terminal."
    fi
    printf -v "$__rl_var" '%s' "$__rl_val"
}

cli_pause() {
    local __p
    read_line __p "  Press Enter to continue... "
}

# ask VAR "Question" "default" [validator_function]
cli_ask() {
    local __var=$1 __q=$2 __def=${3:-} __check=${4:-} __a
    while true; do
        if [ -n "$__def" ]; then
            read_line __a "  ${__q} [${__def}]: "
            __a=$(trim "$__a")
            __a=${__a:-$__def}
        else
            read_line __a "  ${__q}: "
            __a=$(trim "$__a")
        fi
        if [ -z "$__a" ]; then
            warn "An answer is required."
            continue
        fi
        if [ -n "$__check" ] && ! "$__check" "$__a"; then
            continue
        fi
        printf -v "$__var" '%s' "$__a"
        log "ANSWER: ${__q} => ${__a}"
        printf '\n'
        return 0
    done
}

# ask_yn VAR "Question" y|n   (VAR becomes "yes" or "no")
cli_ask_yn() {
    local __var=$1 __q=$2 __def=$3 __a __hint="y/N"
    if [ "$__def" = "y" ]; then __hint="Y/n"; fi
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
    printf '\n'
}

# yesno "Question" y|n   (returns 0 for yes)
yesno() {
    local __yn
    ask_yn __yn "$1" "$2"
    [ "$__yn" = "yes" ]
}

# choose VAR "Question" DEFAULT_VALUE "value|Label" ...
cli_choose() {
    local __var=$1 __q=$2 __def=$3
    shift 3
    local -a __vals=() __labs=()
    local __o __i __a __defi=1
    for __o in "$@"; do
        __vals+=("${__o%%|*}")
        __labs+=("${__o#*|}")
    done
    for __i in "${!__vals[@]}"; do
        if [ "${__vals[__i]}" = "$__def" ]; then __defi=$(( __i + 1 )); fi
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
            printf '\n'
            return 0
        fi
        warn "Please enter a number between 1 and ${#__vals[@]}."
    done
}

# choose_multi VAR "Question" "value|Label" ...   (VAR = space separated values)
cli_choose_multi() {
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
        if [ -z "$__a" ] || [ "${__a,,}" = "none" ]; then break; fi
        if [ "${__a,,}" = "all" ]; then
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
        if [ "$__bad" = "no" ]; then break; fi
    done
    for __p in "${__picked[@]}"; do
        if [[ " $__out " != *" $__p "* ]]; then
            __out+="${__out:+ }${__p}"
        fi
    done
    printf -v "$__var" '%s' "$__out"
    log "ANSWER: ${__q} => ${__out:-none}"
    printf '\n'
}

# ask_password VAR "what" MIN_LENGTH
cli_ask_password() {
    local __var=$1 __what=$2 __min=${3:-1} __p1 __p2
    while true; do
        if ! IFS= read -r -s -p "  Type the ${__what}: " __p1; then printf '\n'; die "Input ended unexpectedly."; fi
        printf '\n'
        if (( ${#__p1} < __min )); then
            if (( __min == 1 )); then warn "It cannot be empty."; else warn "It must be at least ${__min} characters long."; fi
            continue
        fi
        if ! IFS= read -r -s -p "  Type it again to confirm: " __p2; then printf '\n'; die "Input ended unexpectedly."; fi
        printf '\n'
        if [ "$__p1" != "$__p2" ]; then
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

# The rest of the installer calls say, choose, ask, ... without the cli_
# prefix. Those names are defined by each front end: src/90_main_cli.sh maps
# them to the console versions above, src/60_tui.sh to dialog boxes.

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
    if [ -n "$(find /usr/share/keymaps -name 'us.map*' -print 2>/dev/null | head -n1 || true)" ]; then
        if [ -n "$(find /usr/share/keymaps -name "${k}.map*" -print 2>/dev/null | head -n1 || true)" ]; then
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
    if [ -f /usr/share/X11/xkb/symbols/us ] && [ ! -f "/usr/share/X11/xkb/symbols/$1" ]; then
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
    if [ -r /usr/share/i18n/SUPPORTED ] && grep -q '^en_US.UTF-8 ' /usr/share/i18n/SUPPORTED \
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
    [ -r /usr/share/zoneinfo/zone1970.tab ] && [ -f /usr/share/zoneinfo/UTC ]
}

# Print all known timezone names, one per line.
tz_names() {
    if tz_live_usable; then
        { printf '%s\n' "UTC"; grep -v '^#' /usr/share/zoneinfo/zone1970.tab | awk -F'\t' 'NF >= 3 {print $3}'; } | sort -u
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

cli_browse_timezones() {
    local names region cities
    names=$(tz_names)
    printf '\n'
    printf '%s\n' "  Regions:"
    print_columns "$(awk -F/ 'NF > 1 {print $1}' <<<"$names" | sort -u; printf '%s\n' "UTC")"
    read_line region "  Region to list (Enter to go back): "
    region=$(trim "$region")
    if [ -z "$region" ]; then return 0; fi
    if [ "$region" = "UTC" ]; then
        printf '%s\n' "  Type UTC to use it."
        return 0
    fi
    cities=$(awk -v r="${region}/" 'index($0, r) == 1 {print substr($0, length(r) + 1)}' <<<"$names")
    if [ -z "$cities" ]; then
        warn "There is no region called '${region}'. Region names are case sensitive, for example Europe."
        return 0
    fi
    printf '\n'
    print_columns "$cities"
    printf '\n'
    printf '%s\n' "  Now type the full name, for example ${region}/$(head -n1 <<<"$cities")"
}

valid_timezone() {
    local tz=$1
    if [ "$tz" = "list" ]; then
        browse_timezones
        return 1
    fi
    if [[ ! $tz =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ ]]; then
        warn "That does not look like a timezone name. Example: America/New_York. Type 'list' to browse."
        return 1
    fi
    if tz_live_usable; then
        if [ -f "/usr/share/zoneinfo/$tz" ]; then return 0; fi
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
# parse_args ARGS...: sets RUN_MODE to fresh, resume, chroot or help. Long
# options are translated to their short forms, then read with getopts.
RUN_MODE="fresh"
parse_args() {
    local arg opt
    local -a args=()
    for arg in "$@"; do
        case "$arg" in
            --help) args+=(-h) ;;
            --resume) args+=(-r) ;;
            --chroot-stage) args+=(-C) ;;
            --*) usage >&2; printf 'Unknown option: %s\n' "$arg" >&2; exit 1 ;;
            *) args+=("$arg") ;;
        esac
    done
    set -- "${args[@]}"
    OPTIND=1
    while getopts ':hrC' opt; do
        case "$opt" in
            h) RUN_MODE="help" ;;
            r) RUN_MODE="resume" ;;
            C) RUN_MODE="chroot" ;;
            *) usage >&2; printf 'Unknown option: -%s\n' "$OPTARG" >&2; exit 1 ;;
        esac
    done
    shift $(( OPTIND - 1 ))
    if [ "$#" -gt 0 ]; then
        usage >&2
        printf 'Unexpected argument: %s\n' "$1" >&2
        exit 1
    fi
}

# The bash version check runs before anything that needs bash 4.4 features.
check_bash_version() {
    if [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
        printf '%s\n' "This installer needs bash 4.4 or newer (this is bash ${BASH_VERSION})." >&2
        exit 1
    fi
}

# Tools the live side needs. Missing ones are listed together, then the
# installer stops before anything is changed.
LIVE_TOOLS=(
    lsblk blkid wipefs sfdisk partprobe blockdev mkfs.ext4 mkfs.vfat mkswap
    mount umount mountpoint findmnt chroot tar xz sha256sum awk sed grep fold
    cut tr sort head tail od df find mktemp install cat cp rm mkdir chmod
    udevadm timeout date
)

live_preflight() {
    if [ "$(id -u)" -ne 0 ]; then
        die "Please run as root. On the LiveGUI image use: sudo bash ${SELF##*/}"
    fi
    if [ "$(uname -m)" != "x86_64" ]; then
        die "This installer supports amd64 (x86_64) only. This machine reports: $(uname -m)."
    fi
    local -a missing=()
    local t
    for t in "${LIVE_TOOLS[@]}"; do
        have "$t" || missing+=("$t")
    done
    if ! have curl && ! have wget; then missing+=("curl or wget"); fi
    if [ "${#missing[@]}" -gt 0 ]; then
        die "Missing tools on this live system: ${missing[*]}. Please use the official Gentoo minimal or LiveGUI image."
    fi
    mkdir -p -- "$MNT"
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
        [ -e "$n" ] || continue
        n=${n##*/}
        [ "$n" = "lo" ] && continue
        printf '%s\n' "$n"
    done
}

network_step() {
    section "Network connection"
    say "The installer downloads the Gentoo base system and all packages from the internet, so a working connection is required. Wired Ethernet usually works automatically."
    if [ "$BCM_WIFI" = "wl" ]; then
        say "This computer's Broadcom Wi-Fi card needs Broadcom's own 'wl' driver, which the live system does not have, so Wi-Fi cannot work here. Use a wired connection, a USB Ethernet adapter, a USB Wi-Fi adapter, or USB tethering from a phone for the installation. The new system can get the wl driver (Part 5 asks)."
    fi
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
                while IFS= read -r iface; do ifopts+=("${iface}|${iface}"); done < <(list_interfaces)
                if [ "${#ifopts[@]}" -eq 0 ]; then warn "No network interfaces found."; continue; fi
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
    if [ "$synced" = "no" ] && have ntpd; then
        if timeout 60 ntpd -q -g -n -p pool.ntp.org >>"$LOG" 2>&1 || timeout 60 ntpd -q -n -p pool.ntp.org >>"$LOG" 2>&1; then
            synced="yes"
        fi
    fi
    if [ "$synced" = "yes" ]; then
        ok "Clock set: $(date -u '+%Y-%m-%d %H:%M UTC')"
    else
        warn "Could not sync the clock automatically. Current time: $(date -u '+%Y-%m-%d %H:%M UTC')"
    fi
    if [ "$(date +%Y)" -lt 2026 ]; then
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
# nvidia_generation DEVICE_ID (hex, as in /sys/bus/pci/devices/*/device):
#   current      Turing (GeForce GTX 16xx, RTX 20xx) and newer
#   legacy580    Maxwell, Pascal, Volta (GTX 750, 900 and 10xx series, Titan V):
#                the 580 driver branch is the last to support them, because
#                nvidia-drivers 595 and newer only ship the open kernel modules
#   unsupported  Kepler and older: no longer supported by NVIDIA; Gentoo masks
#                the old driver branches
# Decided by PCI device ID ranges (Maxwell starts at 0x1340, Turing at 0x1e00).
# It is a heuristic; nvidia-drivers itself checks the card again when installed
# and warns if it needs a different branch.
nvidia_generation() {
    local id
    if [[ ! $1 =~ ^0x[0-9a-fA-F]+$ ]]; then printf '%s\n' "current"; return 0; fi
    id=$(( $1 ))
    if (( id >= 0x1e00 )); then printf '%s\n' "current"
    elif (( id >= 0x1340 )); then printf '%s\n' "legacy580"
    else printf '%s\n' "unsupported"; fi
}

# broadcom_wifi_kind DEVICE_ID: which driver a Broadcom Wi-Fi chip needs.
#   wl    only Broadcom's proprietary wl driver (net-wireless/broadcom-sta):
#         BCM4360 (most Macs from 2013 on), BCM4352, BCM43142, BCM43228
#   b43   the in-kernel b43 driver plus firmware (sys-firmware/b43-firmware):
#         BCM4311, 4312, 4315, 4318, 4319, 4321, 4322, 4331 (Macs up to 2012)
#   (empty) supported by brcmsmac or brcmfmac with linux-firmware, or unknown
broadcom_wifi_kind() {
    case "$1" in
        0x43a0|0x43b1|0x4365|0x4359) printf '%s\n' "wl" ;;
        0x4311|0x4312|0x4315|0x4318|0x4319|0x4328|0x4329|0x432a|0x432b|0x432c|0x432d|0x4331)
            printf '%s\n' "b43" ;;
        *) ;;
    esac
}

detect_gpus() {
    HAS_NVIDIA="no"; HAS_AMD="no"; HAS_INTEL="no"; GPU_VM=""; NVIDIA_GEN=""; HYBRID_GPU="no"
    GPU_NAMES=()
    local d class vendor slot name gen count=0
    for d in /sys/bus/pci/devices/*; do
        [ -r "$d/class" ] && [ -r "$d/vendor" ] || continue
        class=$(<"$d/class")
        [[ $class = 0x03* ]] || continue
        vendor=$(<"$d/vendor")
        slot=${d##*/}
        case "$vendor" in
            0x10de)
                HAS_NVIDIA="yes"
                count=$(( count + 1 ))
                gen=$(nvidia_generation "$(cat -- "$d/device" 2>/dev/null)")
                # With several NVIDIA cards, the oldest one decides.
                case "${NVIDIA_GEN}:${gen}" in
                    :*|current:legacy580|current:unsupported|legacy580:unsupported) NVIDIA_GEN=$gen ;;
                esac ;;
            0x1002) HAS_AMD="yes"; count=$(( count + 1 )) ;;
            0x8086) HAS_INTEL="yes"; count=$(( count + 1 )) ;;
            0x15ad|0x80ee) [[ $GPU_VM = *vmware* ]] || GPU_VM+=" vmware" ;;
            0x1af4) [[ $GPU_VM = *virgl* ]] || GPU_VM+=" virgl" ;;
            0x1b36) [[ $GPU_VM = *qxl* ]] || GPU_VM+=" qxl" ;;
        esac
        name=""
        if have lspci; then
            name=$(LC_ALL=C lspci -s "$slot" 2>/dev/null | cut -d' ' -f2- || true)
        fi
        GPU_NAMES+=("${name:-PCI ${slot} vendor ${vendor}}")
    done
    GPU_VM=$(trim "$GPU_VM")
    # Two real graphics chips (an integrated one plus a dedicated one, as in
    # many laptops): the desktop can offer to start programs on either.
    if [ "$count" -ge 2 ]; then HYBRID_GPU="yes"; fi
}

# Broadcom Wi-Fi chips that need extra drivers or firmware (sets BCM_WIFI).
detect_broadcom_wifi() {
    local d kind
    BCM_WIFI=""
    for d in /sys/bus/pci/devices/*; do
        [ -r "$d/class" ] && [ -r "$d/vendor" ] || continue
        [[ $(<"$d/class") = 0x0280* ]] || continue
        [ "$(<"$d/vendor")" = "0x14e4" ] || continue
        kind=$(broadcom_wifi_kind "$(cat -- "$d/device" 2>/dev/null)")
        if [ -n "$kind" ]; then BCM_WIFI=$kind; fi
    done
}

# Apple T2 security chip (Macs from 2018 to 2020): PCI 106b:1801 or 106b:1802.
has_apple_t2() {
    local d dev
    for d in /sys/bus/pci/devices/*; do
        [ -r "$d/vendor" ] || continue
        [ "$(<"$d/vendor")" = "0x106b" ] || continue
        dev=$(cat -- "$d/device" 2>/dev/null || true)
        case "$dev" in 0x1801|0x1802) return 0 ;; esac
    done
    return 1
}

# A RAID controller in "RAID" or Intel RST/VMD mode hides the disks behind it.
has_raid_controller() {
    local d
    for d in /sys/bus/pci/devices/*; do
        [ -r "$d/class" ] || continue
        case "$(<"$d/class")" in 0x0104*) return 0 ;; esac
    done
    return 1
}

detect_hardware() {
    CPU_VENDOR=$(awk -F': *' '/^vendor_id/ {print $2; exit}' /proc/cpuinfo)
    CPU_MODEL=$(awk -F': *' '/^model name/ {print $2; exit}' /proc/cpuinfo)
    NPROC=$(getconf _NPROCESSORS_ONLN 2>/dev/null || grep -c '^processor' /proc/cpuinfo)
    local mem_kib
    mem_kib=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
    RAM_GIB=$(( (mem_kib + 524288) / 1048576 ))
    if [ "$RAM_GIB" -lt 1 ]; then RAM_GIB=1; fi

    local flags f
    flags=" $(awk -F': *' '/^flags/ {print $2; exit}' /proc/cpuinfo) "
    CPU_X86_64_V3="yes"
    for f in avx avx2 bmi1 bmi2 f16c fma abm movbe xsave; do
        if [[ $flags != *" $f "* ]]; then CPU_X86_64_V3="no"; fi
    done

    if [ -d /sys/firmware/efi ]; then BOOT_MODE="uefi"; else BOOT_MODE="bios"; fi
    UEFI_BITS=""
    if [ -r /sys/firmware/efi/fw_platform_size ]; then UEFI_BITS=$(</sys/firmware/efi/fw_platform_size); fi
    if [ "$BOOT_MODE" = "uefi" ] && [ -z "$UEFI_BITS" ]; then UEFI_BITS="64"; fi

    SECURE_BOOT="off"
    local sb val
    for sb in /sys/firmware/efi/efivars/SecureBoot-*; do
        [ -r "$sb" ] || continue
        val=$(od -An -t u1 "$sb" 2>/dev/null | awk '{print $NF}')
        if [ "$val" = "1" ]; then SECURE_BOOT="on"; fi
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
    if [ "$VIRT" = "none" ] && [[ $flags = *" hypervisor "* ]]; then VIRT="other"; fi

    IS_APPLE="no"; MAC_MODEL=""; HAS_T2="no"
    if [[ $vendor = *Apple* ]]; then
        IS_APPLE="yes"
        MAC_MODEL=$(trim "$product")
        if has_apple_t2; then HAS_T2="yes"; fi
    fi
    LIVE_BOOT_MODE=$BOOT_MODE

    IS_LAPTOP="no"
    if compgen -G "/sys/class/power_supply/BAT*" >/dev/null; then IS_LAPTOP="yes"; fi
    case "$(cat /sys/class/dmi/id/chassis_type 2>/dev/null || printf '0')" in
        8|9|10|11|14|30|31|32) IS_LAPTOP="yes" ;;
    esac
    if [[ $MAC_MODEL = MacBook* ]]; then IS_LAPTOP="yes"; fi
    if [ "$VIRT" != "none" ]; then IS_LAPTOP="no"; fi

    HAS_WIFI="no"
    local n
    for n in /sys/class/net/*; do
        if [ -d "$n/wireless" ] || [ -e "$n/phy80211" ]; then HAS_WIFI="yes"; fi
    done
    detect_broadcom_wifi
    # A Broadcom card that needs the wl driver has no network interface on the
    # live system, but the new system can drive it.
    if [ -n "$BCM_WIFI" ]; then HAS_WIFI="yes"; fi

    HAS_BT="no"
    if compgen -G "/sys/class/bluetooth/hci*" >/dev/null; then HAS_BT="yes"; fi

    detect_gpus
    if [ "$VIRT" != "none" ]; then HYBRID_GPU="no"; fi
}

show_hardware() {
    section "Detected hardware"
    local b="" g fw vm
    fw="Legacy BIOS"
    if [ "$BOOT_MODE" = "uefi" ]; then fw="UEFI (${UEFI_BITS:-64}-bit)"; fi
    vm="no (real hardware)"
    if [ "$VIRT" != "none" ]; then vm="yes ($VIRT)"; fi
    printf -v b '%s  %-22s %s\n' "$b" "CPU:" "${CPU_MODEL:-unknown} (${CPU_VENDOR:-unknown})"
    printf -v b '%s  %-22s %s\n' "$b" "CPU threads:" "$NPROC"
    printf -v b '%s  %-22s %s\n' "$b" "Memory:" "about ${RAM_GIB} GiB"
    printf -v b '%s  %-22s %s\n' "$b" "x86-64-v3 capable:" "$CPU_X86_64_V3 (AVX2 generation or newer)"
    printf -v b '%s  %-22s %s\n' "$b" "Firmware boot mode:" "$fw"
    if [ "$BOOT_MODE" = "uefi" ]; then
        printf -v b '%s  %-22s %s\n' "$b" "Secure Boot:" "$SECURE_BOOT"
    fi
    printf -v b '%s  %-22s %s\n' "$b" "Virtual machine:" "$vm"
    if [ "$IS_APPLE" = "yes" ]; then
        printf -v b '%s  %-22s %s\n' "$b" "Apple Mac:" "${MAC_MODEL:-yes}"
    fi
    printf -v b '%s  %-22s %s\n' "$b" "Laptop:" "$IS_LAPTOP"
    printf -v b '%s  %-22s %s\n' "$b" "Wi-Fi adapter:" "$HAS_WIFI"
    case "$BCM_WIFI" in
        wl) printf -v b '%s  %-22s %s\n' "$b" "" "(Broadcom, needs the wl driver)" ;;
        b43) printf -v b '%s  %-22s %s\n' "$b" "" "(Broadcom, needs b43 firmware)" ;;
    esac
    printf -v b '%s  %-22s %s\n' "$b" "Bluetooth adapter:" "$HAS_BT"
    if [ "${#GPU_NAMES[@]}" -eq 0 ]; then
        printf -v b '%s  %-22s %s\n' "$b" "Graphics:" "none detected"
    else
        for g in "${GPU_NAMES[@]}"; do
            printf -v b '%s  %-22s %s\n' "$b" "Graphics:" "$g"
        done
    fi
    say_pre "${b%$'\n'}"
    if [ "$BOOT_MODE" = "uefi" ] && [ "$UEFI_BITS" = "32" ]; then
        if [ "$IS_APPLE" = "yes" ]; then
            die "This Mac has 32-bit EFI firmware, which this installer cannot make bootable. Nothing on disk has been changed."
        fi
        say "This computer has 32-bit UEFI firmware with a 64-bit CPU (common on Intel Atom tablets and small laptops from around 2014). The installer uses GRUB's 32-bit EFI version for it, which starts the normal 64-bit Gentoo kernel. systemd-boot is not offered on this firmware."
    fi
    if [ "$SECURE_BOOT" = "on" ]; then
        warn "Secure Boot is enabled in your firmware."
        say "This installer does not sign the kernel or bootloader, so the installed system will not boot while Secure Boot is on. Disable Secure Boot in the firmware setup before rebooting into Gentoo (you can set up signing later; see the Gentoo wiki page 'Secure Boot')."
    fi
    if [ "$HAS_T2" = "yes" ]; then
        warn "This Mac has an Apple T2 chip (most Macs from 2018 to 2020)."
        say "Gentoo's kernel does not support the T2's built-in keyboard, trackpad, Wi-Fi, audio and Touch Bar; those need the patched kernel from the t2linux project. Use a USB keyboard and a wired or USB network connection, and expect those devices to stay off after installing until you set up the t2linux kernel (see wiki.t2linux.org)." \
            "Also allow booting from external media and other operating systems: start the Mac holding Command+R, open Startup Security Utility, and set Secure Boot to 'No Security'."
    fi
    if [ "$BOOT_MODE" = "bios" ] && [ "$IS_APPLE" != "yes" ]; then
        say "The live image was started in legacy BIOS mode. If this computer supports UEFI (almost everything made after 2012 does), consider rebooting the live image in UEFI mode first: it is the more modern and better supported setup. Continuing in BIOS mode works too (GRUB is used)."
    fi
    pause
}

# Intel Macs with 32-bit EFI firmware (2006 and 2007 models). All later Intel
# Macs have 64-bit EFI. Model identifiers as shown in DMI product_name.
mac_has_32bit_efi() {
    case "$1" in
        MacBook1,1|MacBook2,1|MacBookPro1,1|MacBookPro1,2|MacBookPro2,1|MacBookPro2,2|\
        iMac4,1|iMac4,2|iMac5,1|iMac5,2|iMac6,1|Macmini1,1|Macmini2,1|MacPro1,1|MacPro2,1|Xserve1,1)
            return 0 ;;
    esac
    return 1
}

# Intel Macs choose between legacy (BIOS) and EFI boot from the partition table:
# they only boot a disk in legacy mode if it has an MBR (or hybrid MBR)
# partition table with a partition marked bootable. When the live system was
# started in BIOS mode on a Mac (Ventoy's EFI mode does not start on some Macs,
# for example), install for EFI instead. The bootloader then goes to the
# fallback path EFI/BOOT/BOOTX64.EFI, which works without access to the
# firmware's boot menu from the live system. A BIOS-mode install on a Mac gets
# an MBR partition table, which the Mac's legacy boot needs.
mac_boot_check() {
    local target
    if [ "$IS_APPLE" != "yes" ] || [ "$BOOT_MODE" != "bios" ]; then return 0; fi
    section "Apple Mac started in BIOS mode"
    if mac_has_32bit_efi "$MAC_MODEL"; then
        say "This Mac (${MAC_MODEL}) has 32-bit EFI firmware, which this installer cannot boot. It can still install in BIOS mode with an MBR partition table, which these Macs start through their legacy boot support."
        PTABLE="mbr"
        return 0
    fi
    say "This is an Apple Mac${MAC_MODEL:+ (${MAC_MODEL})}, and the live system was started in legacy BIOS mode. That is common with Ventoy, whose EFI mode does not start on some Macs." \
        "Macs only boot a BIOS-mode installation from a disk with an MBR partition table, and the Mac's legacy boot is slow and lacks some features (for example, the screen brightness keys may not work)." \
        "Instead, the installer can set up the new system for EFI, the Mac's native boot mode, even though the live system runs in BIOS mode. The bootloader is then placed at the standard fallback location that the Mac finds by itself. If it does not start automatically, hold the Option key while the Mac starts and choose 'EFI Boot'."
    choose target "How should the new system start?" "uefi" \
        "uefi|Install for EFI, the Mac's native boot mode (recommended)" \
        "bios|Install for BIOS with an MBR partition table (legacy boot)"
    if [ "$target" = "uefi" ]; then
        BOOT_MODE="uefi"
        UEFI_BITS="64"
        ok "The new system will be installed for EFI."
    else
        PTABLE="mbr"
        ok "The new system will be installed for BIOS, on an MBR partition table."
    fi
}

# Print the disk the live image was booted from, so it is never offered.
live_media_disk() {
    local m src pk
    for m in /mnt/cdrom /run/initramfs/live /run/archiso/bootmnt /run/live/medium; do
        src=$(findmnt -no SOURCE "$m" 2>/dev/null || true)
        [ -n "$src" ] && [ -b "$src" ] || continue
        pk=$(lsblk -no PKNAME "$src" 2>/dev/null | head -n1 || true)
        if [ -n "$pk" ]; then printf '/dev/%s\n' "$pk"; else printf '%s\n' "$src"; fi
        return 0
    done
    return 0
}

# Whole disks that can be installed to. Leaves out optical drives, RAM and
# loop devices, eMMC boot and RPMB areas, read-only and empty devices.
list_disks() {
    LC_ALL=C lsblk -dpno NAME,TYPE,RO,SIZE -b 2>/dev/null \
        | awk '$2 == "disk" && $3 == "0" && $4 > 0 {print $1}' \
        | grep -Ev '^/dev/(loop|sr|zram|ram|fd|nbd)|^/dev/mmcblk[0-9]+(boot[0-9]+|rpmb)$' || true
}

# part_dev DISK N -> partition device path (handles nvme0n1p1, mmcblk0p1, sda1)
part_dev() {
    if [[ $1 =~ [0-9]$ ]]; then printf '%sp%s\n' "$1" "$2"; else printf '%s%s\n' "$1" "$2"; fi
}

lsblk_field() {
    # lsblk_field FIELD DEVICE
    LC_ALL=C lsblk -dno "$1" "$2" 2>/dev/null | head -n1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true
}

# ----------------------------------------------------------------------------
# Questionnaire
# ----------------------------------------------------------------------------
de_label() {
    case "$1" in
        plasma) printf '%s\n' "KDE Plasma" ;;
        gnome) printf '%s\n' "GNOME" ;;
        cinnamon) printf '%s\n' "Cinnamon" ;;
        xfce) printf '%s\n' "Xfce" ;;
        mate) printf '%s\n' "MATE" ;;
        lxqt) printf '%s\n' "LXQt" ;;
        sway) printf '%s\n' "Sway" ;;
        i3) printf '%s\n' "i3" ;;
        *) printf '%s\n' "No desktop (console only)" ;;
    esac
}

default_dm_for() {
    case "$1" in
        plasma|lxqt) printf '%s\n' "sddm" ;;
        gnome) printf '%s\n' "gdm" ;;
        xfce|cinnamon|mate|i3) printf '%s\n' "lightdm" ;;
        *) printf '%s\n' "none" ;;
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
    if [ "$DE" = "sway" ]; then
        say "Sway is started from the text console instead of a graphical login screen. The installer can start it automatically when your user logs in on the first console (tty1), which is the usual setup."
        ask_yn SWAY_AUTOSTART "Start Sway automatically after logging in on tty1?" "$def_sway"
    elif [ "$DE" != "none" ]; then
        local def_dm def_yn="y"
        def_dm=$(default_dm_for "$DE")
        if [ "$DE" = "$prev_de" ] && [ "$prev_dm" = "none" ]; then def_yn="n"; fi
        say "A display manager is the graphical login screen shown at boot. For $(de_label "$DE") the installer uses ${def_dm}. Without one, you log in on a text console and start the desktop yourself."
        if yesno "Install the graphical login screen (${def_dm})?" "$def_yn"; then DM=$def_dm; fi
    fi

    subsection "Init system"
    say "The init system is the first program the kernel starts. It boots the machine and starts and supervises all services." \
        "OpenRC is Gentoo's traditional default: simple, script based and lightweight. systemd is what most other distributions use and brings more integrated tooling (journald logs, timers, per-user services). Both are fully supported by Gentoo." \
        "Gentoo announced its binary package host with desktop packages built for the Plasma/systemd and GNOME/systemd profiles, so for those two desktops systemd is likely to get more ready-made binaries and less compiling."
    local def_init="openrc"
    if [ "$DE" = "plasma" ] || [ "$DE" = "gnome" ]; then def_init="systemd"; fi
    if [ "$DE" = "$prev_de" ] && [ -n "$INIT" ]; then def_init=$INIT; fi
    choose INIT "Init system" "$def_init" \
        "openrc|OpenRC: Gentoo's traditional init system" \
        "systemd|systemd: the init system used by most distributions"
    if [ "$DE" = "gnome" ] && [ "$INIT" = "openrc" ]; then
        warn "GNOME is developed against systemd. On OpenRC it runs through elogind and works, but some features (for example parts of the Settings panels) may be limited."
        if yesno "Switch to systemd for GNOME?" y; then INIT="systemd"; fi
    fi

    subsection "Binary packages"
    say "Gentoo compiles software from source by default. That gives full control and CPU-specific optimisation, but a complete desktop can take many hours to build." \
        "Gentoo also publishes official, PGP-signed binary packages. When they are enabled, Portage downloads a ready-made package whenever one exists that matches your USE flags, and compiles everything else locally with the CPU-tuned settings this installer creates. The binaries themselves are built for generic x86-64 (or x86-64-v3) CPUs, not for -march=native." \
        "Recommended: yes. You can switch to building everything from source at any time later."
    ask_yn USE_BINPKG "Use Gentoo's official binary packages?" "$(yn_default USE_BINPKG y)"
    BINHOST_V3="no"
    if [ "$USE_BINPKG" = "yes" ] && [ "$CPU_X86_64_V3" = "yes" ]; then
        BINHOST_V3="yes"
        info "Your CPU supports x86-64-v3 (AVX2 generation), so x86-64-v3 binaries will be preferred, with baseline x86-64 as the fallback."
    fi

    subsection "CPU instruction set flags"
    say "CPU_FLAGS_X86 tells packages which instruction set extensions (SSE4.2, AVX2, AES and so on) they may use. The Handbook recommends detecting the exact set of this CPU with the cpuid2cpuflags tool, and the installer can do that."
    if [ "$USE_BINPKG" = "yes" ]; then
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
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        if [ "$d" = "$live" ]; then
            info "Skipping ${d}: the live image was booted from it."
            continue
        fi
        size=$(lsblk_field SIZE "$d")
        model=$(lsblk_field MODEL "$d")
        tran=$(lsblk_field TRAN "$d")
        opts+=("${d}|${d}   ${size}   ${model:-unknown model}${tran:+   (${tran})}")
    done < <(list_disks)
    if [ "${#opts[@]}" -eq 0 ]; then
        if has_raid_controller; then
            die "No usable disks were found, but this computer has a RAID controller. Many laptops and desktops ship with the disk controller set to 'RAID', 'Intel RST' or 'VMD' mode, which hides the disks from Linux. Switch it to 'AHCI' (and turn VMD off) in the firmware setup. If Windows is installed on this computer, read how to switch it safely first, or Windows may stop booting."
        fi
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
        warn "${DISK} has ${gib} GiB, but this installation needs at least ${need} GiB ($( [ "$DE" = none ] && printf '%s\n' "without a desktop" || printf '%s\n' "with a desktop: the desktop, the package downloads and temporary build files need the room" )). Pick another disk, or quit and give the machine a larger disk."
    done

    say_pre "$(printf '  Current contents of %s:\n' "$DISK"; lsblk -po NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$DISK" 2>/dev/null | sed 's/^/    /')"
    if (( gib < 60 )) && [ "$DE" != "none" ]; then
        info "${DISK} has ${gib} GiB. That is enough to install, but 60 GiB or more leaves comfortable room for updates, which on Gentoo sometimes compile large packages."
    fi
    IS_SSD="no"
    if [ "$(cat "/sys/block/${DISK##*/}/queue/rotational" 2>/dev/null || printf '%s\n' 1)" = "0" ]; then IS_SSD="yes"; fi
}

# Minimum size in GiB for the target disk or root partition.
min_root_gib() {
    if [ "$DE" = "none" ]; then printf '%s\n' "$MIN_DISK_GIB"; else printf '%s\n' "$MIN_DESKTOP_DISK_GIB"; fi
}

# Size in GiB of the disk (automatic layout) or root partition (manual layout).
target_root_gib() {
    local dev=$DISK bytes
    if [ "$PART_MODE" = "manual" ]; then dev=$ROOT_PART; fi
    bytes=$(lsblk -bdno SIZE "$dev" 2>/dev/null || true)
    bytes=${bytes%%$'\n'*}
    printf '%s\n' $(( ${bytes:-0} / 1073741824 ))
}

q_part_mode() {
    say "Erase whole disk: deletes everything on ${DISK} and creates a standard layout automatically. Simple and recommended." \
        "Manual: you create or choose the partitions yourself, for example to keep Windows or another Linux for dual booting. The installer can open the cfdisk partition editor for you and then asks which partition is used for what."
    choose PART_MODE "Partitioning" "${PART_MODE:-auto}" \
        "auto|Erase the whole disk and partition it automatically (recommended)" \
        "manual|Use partitions I choose (dual boot or custom layout)"
}

# Partition table for the automatic layout. UEFI always uses GPT. In BIOS mode
# GPT works on nearly every computer, but some older BIOSes refuse to start
# from a GPT disk, and Macs only start BIOS-mode systems from an MBR disk.
q_partition_table() {
    local gib
    if [ "$BOOT_MODE" = "uefi" ]; then PTABLE="gpt"; return 0; fi
    if [ "$PART_MODE" = "manual" ]; then return 0; fi
    gib=$(target_root_gib)
    if [ "$IS_APPLE" = "yes" ] && [ "$gib" -lt 2048 ]; then
        PTABLE="mbr"
        info "Apple Mac in BIOS mode: the disk gets an MBR partition table, which the Mac's legacy boot needs."
        return 0
    fi
    if [ "$gib" -ge 2048 ]; then
        PTABLE="gpt"
        return 0
    fi
    say "GPT is the modern partition table and works with nearly every BIOS. MBR is the older format: pick it only if this computer's BIOS does not start from a GPT disk (some machines from before about 2010 do not). MBR is limited to disks of 2 TiB."
    choose PTABLE "Partition table" "${PTABLE:-gpt}" \
        "gpt|GPT (recommended)" \
        "mbr|MBR (for old BIOSes that do not boot GPT disks)"
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
    if [ "$ENCRYPT" = "yes" ]; then
        ask_password LUKS_PASSWORD "disk encryption passphrase" 8
    fi
}

q_swap() {
    local ram_cap=$(( RAM_GIB < 8 ? RAM_GIB : 8 ))
    say "Swap is overflow space the kernel uses when RAM runs out." \
        "zram (recommended) creates compressed swap inside RAM. It is fast, uses no disk space, and fits desktops well. Its size will be ${ram_cap} GiB (equal to RAM, capped at 8 GiB, the same rule Fedora uses); it only consumes memory for what is actually swapped." \
        "A swap partition uses disk space. Hibernation needs one, but this installer does not set up hibernation."
    local -a opts=("zram|zram: compressed swap in RAM (recommended)")
    if [ "$ENCRYPT" = "yes" ]; then
        info "A swap partition is not offered with encryption: an unencrypted swap partition could leak the contents of memory to disk."
    else
        opts+=("partition|A swap partition on the disk")
    fi
    opts+=("none|No swap")
    choose SWAP_MODE "Swap" "${SWAP_MODE:-zram}" "${opts[@]}"
    local prev_size=$SWAP_SIZE_GIB
    SWAP_SIZE_GIB=""
    if [ "$SWAP_MODE" = "partition" ] && [ "$PART_MODE" = "auto" ]; then
        ask SWAP_SIZE_GIB "Swap partition size in GiB" "${prev_size:-$ram_cap}" valid_positive_int
    fi
}

q_bootloader() {
    if [ "$BOOT_MODE" = "bios" ]; then
        BOOTLOADER="grub"
        info "Legacy BIOS mode: the GRUB bootloader will be used."
        return 0
    fi
    if [ "$UEFI_BITS" = "32" ]; then
        BOOTLOADER="grub"
        info "32-bit UEFI firmware: the GRUB bootloader (32-bit EFI version) will be used."
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
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        if [[ " $__used " = *" $name "* ]]; then continue; fi
        pk=$(lsblk_field PKNAME "$name")
        if [ -n "$__live" ] && [ "/dev/$pk" = "$__live" ]; then continue; fi
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
    if [ "$BOOT_MODE" = "uefi" ]; then
        req+=("An EFI system partition (FAT32). An existing one, for example from Windows, can be reused without formatting. With systemd-boot it holds the kernels, so 1 GiB is recommended.")
    else
        req+=("On a GPT disk: a 1 MiB partition of type 'BIOS boot' on the disk that holds the root partition (GRUB stores itself there). An MBR disk needs no extra partition, but leave 1 MiB free before the first partition (cfdisk does that by default).")
    fi
    if [ "$NEED_BOOT_PART" = "yes" ]; then
        req+=("A separate /boot partition of at least 512 MiB (1 GiB recommended). It will be formatted as ext4, because GRUB cannot read the root filesystem you chose ($( [ "$ENCRYPT" = yes ] && printf '%s\n' "encrypted" || printf '%s\n' "XFS with current default features" )).")
    fi
    req+=("A root partition of at least ${MIN_DISK_GIB} GiB (40 GiB or more for a desktop). It will be formatted.")
    if [ "$SWAP_MODE" = "partition" ]; then req+=("A swap partition. It will be formatted as swap."); fi

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
    if [ "$BOOT_MODE" = "uefi" ]; then
        pick_partition ESP_PART "Which partition is the EFI system partition?" "$used"
        used+=" $ESP_PART"
        fstype=$(lsblk_field FSTYPE "$ESP_PART")
        if [ "$fstype" = "vfat" ]; then
            say "${ESP_PART} already contains a FAT filesystem. If another operating system boots from it (Windows, another Linux), keep it: Gentoo's boot files are simply added next to the existing ones."
            local def_fmt="n"
            if [ "$FORMAT_ESP" = "yes" ] && [ "$ESP_PART" = "$prev_esp" ]; then def_fmt="y"; fi
            ask_yn FORMAT_ESP "Format ${ESP_PART}? (answer no to keep the existing boot files)" "$def_fmt"
        else
            warn "${ESP_PART} has no FAT filesystem, so it will be formatted as FAT32."
            FORMAT_ESP="yes"
        fi
        bytes=$(lsblk -bdno SIZE "$ESP_PART" 2>/dev/null || true)
        bytes=${bytes%%$'\n'*}
        if (( bytes < 300 * 1048576 )); then
            warn "${ESP_PART} is smaller than 300 MiB. That is too small for kernels and may even be tight for GRUB."
        elif [ "$BOOTLOADER" = "systemd-boot" ] && (( bytes < 900 * 1048576 )); then
            warn "With systemd-boot, kernels and initramfs images live on the EFI partition. ${ESP_PART} holds only room for one or two kernels; consider GRUB instead."
        fi
    fi
    if [ "$NEED_BOOT_PART" = "yes" ]; then
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
    if [ "$SWAP_MODE" = "partition" ]; then
        pick_partition SWAP_PART "Which partition should be used as swap? (it will be formatted)" "$used"
        used+=" $SWAP_PART"
    fi


    DISK="/dev/$(lsblk_field PKNAME "$ROOT_PART")"
    GRUB_DISK=""
    if [ "$BOOT_MODE" = "bios" ]; then
        GRUB_DISK=$DISK
        if [ "$(lsblk_field PTTYPE "$GRUB_DISK")" = "gpt" ]; then
            local ptypes
            ptypes=$(lsblk -lno PARTTYPE "$GRUB_DISK" 2>/dev/null || true)
            if ! grep -qi "${GUID_BIOS}" <<<"$ptypes"; then
                die "${GRUB_DISK} uses GPT but has no 'BIOS boot' partition. GRUB needs one (1 MiB, type 'BIOS boot') to boot in BIOS mode. Create it with cfdisk and run the installer again."
            fi
        fi
    fi
    PTABLE="gpt"
    if [ "$(lsblk_field PTTYPE "$DISK")" = "dos" ]; then PTABLE="mbr"; fi
    DUAL_BOOT="yes"
    IS_SSD="no"
    if [ "$(cat "/sys/block/${DISK##*/}/queue/rotational" 2>/dev/null || printf '%s\n' 1)" = "0" ]; then IS_SSD="yes"; fi
}

show_auto_layout() {
    local n=1 fsdesc b
    fsdesc="$FS"
    if [ "$ENCRYPT" = "yes" ]; then fsdesc="$FS inside LUKS2 encryption"; fi
    if [ "$FS" = "btrfs" ]; then fsdesc+=", subvolumes @ (/) and @home (/home)"; fi
    if [ "$PTABLE" = "mbr" ]; then
        b="  Planned layout for ${DISK} (MBR partition table):"$'\n'
    else
        b="  Planned layout for ${DISK} (GPT partition table):"$'\n'
    fi
    if [ "$BOOT_MODE" = "uefi" ]; then
        printf -v b '%s    %s   %-9s %s\n' "$b" "$(part_dev "$DISK" $n)" "1 GiB" "EFI system partition, FAT32, mounted at /efi"
        n=$(( n + 1 ))
    elif [ "$PTABLE" = "gpt" ]; then
        printf -v b '%s    %s   %-9s %s\n' "$b" "$(part_dev "$DISK" $n)" "1 MiB" "BIOS boot partition (used by GRUB, no filesystem)"
        n=$(( n + 1 ))
    fi
    if [ "$NEED_BOOT_PART" = "yes" ]; then
        printf -v b '%s    %s   %-9s %s\n' "$b" "$(part_dev "$DISK" $n)" "1 GiB" "boot partition, ext4, mounted at /boot"
        n=$(( n + 1 ))
    fi
    if [ "$SWAP_MODE" = "partition" ]; then
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
    q_partition_table
    q_filesystem
    q_encryption
    q_swap
    q_bootloader
    NEED_BOOT_PART="no"
    if [ "$BOOTLOADER" = "grub" ] && { [ "$ENCRYPT" = "yes" ] || [ "$FS" = "xfs" ]; }; then
        NEED_BOOT_PART="yes"
        if [ "$FS" = "xfs" ] && [ "$ENCRYPT" = "no" ]; then
            info "GRUB plus XFS: a separate ext4 /boot partition is used, because GRUB may not read XFS filesystems created with the newest default features."
        fi
    fi
    if [ "$PART_MODE" = "manual" ]; then
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

cli_ask_timezone() {
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

    if [ "$DE" != "none" ]; then
        xkb_from_keymap "$KEYMAP"
        if [ "$KEYMAP" = "$prev_keymap" ] && [ -n "$prev_xkb" ]; then
            XKB_LAYOUT=$prev_xkb
            XKB_VARIANT=$prev_var
        fi
        say "The graphical keyboard layout (XKB) is used by the desktop. It is derived from your console keymap. Plasma and GNOME also let you change it later in their settings."
        local def=$XKB_LAYOUT
        ask XKB_LAYOUT "Desktop keyboard layout (XKB name, for example us, gb, de, fr)" "$def" valid_xkb_layout
        if [ "$XKB_LAYOUT" != "$def" ]; then XKB_VARIANT=""; fi
    fi
}

q_accounts() {
    section "Part 4 of 6: User accounts"
    say "root is the administrator account. You will normally not log in as root; the password is for emergencies and system maintenance."
    ask_password ROOT_PASSWORD "new root password" 1

    say "Now create your everyday user account. It can run administrator commands with sudo or doas."
    ask USERNAME "Username (lowercase)" "${USERNAME:-}" valid_username
    ask_password USER_PASSWORD "password for ${USERNAME}" 1

    local entry
    local -a shell_items=()
    for entry in "${SHELL_CATALOG[@]}"; do
        shell_items+=("${entry%%|*}|${entry##*|}")
    done
    say "The login shell is the command-line shell ${USERNAME} gets in a terminal and on the text console. bash is Gentoo's default and what nearly every guide assumes. Any other choice is installed alongside it: root keeps bash, so recovery always works, and system scripts are unaffected because /bin/sh stays bash."
    valid_shell_choice "${USER_SHELL:-}" || USER_SHELL="bash"
    choose USER_SHELL "Login shell for ${USERNAME}" "$USER_SHELL" "${shell_items[@]}"
    case "$USER_SHELL" in
        fish|nushell)
            say "$(shell_field "$USER_SHELL" 4 | cut -d' ' -f1) is not a POSIX shell: commands copied from guides sometimes need changes. It also does not read /etc/profile, so environment settings that Gentoo packages add there (for example extra PATH entries) are missing in its login sessions unless you add them to its own configuration. It is written in Rust and is compiled from source if no binary package is available, which can take a while."
            if [ "$USER_SHELL" = "nushell" ] && [ "$DE" = "sway" ]; then
                say "Sway is not started automatically after login with Nushell. Type 'sway' after logging in on the first console."
            fi
            ;;
        tcsh) say "tcsh uses C shell syntax, which differs from the sh-style commands in most guides and scripts." ;;
        dash) say "dash is a minimal POSIX sh. It is fast, but has no command history or line editing, so it is awkward as an everyday interactive shell." ;;
    esac

    say "sudo is the standard tool for running a command as administrator. doas is a much smaller alternative from OpenBSD. Either way, your user is added to the 'wheel' group, which is allowed to use it."
    choose PRIV_TOOL "Administrator tool" "${PRIV_TOOL:-sudo}" \
        "sudo|sudo (standard, recommended)" \
        "doas|doas (minimal)"
}

compute_video_cards() {
    local vc=""
    if [ "$HAS_INTEL" = "yes" ]; then vc+=" intel"; fi
    if [ "$HAS_AMD" = "yes" ]; then vc+=" amdgpu radeonsi"; fi
    if [ "$HAS_NVIDIA" = "yes" ]; then
        if [ "$GPU_DRIVER" = "nvidia" ]; then vc+=" nvidia"; else vc+=" nouveau"; fi
    fi
    if [ -n "$GPU_VM" ]; then vc+=" $GPU_VM"; fi
    VIDEO_CARDS=$(trim "$vc")
}

q_hardware_network() {
    section "Part 5 of 6: Drivers, network and services"

    local prev_gpu=$GPU_DRIVER def_gpu="nvidia"
    if [ "$prev_gpu" = "nouveau" ]; then def_gpu="nouveau"; fi
    GPU_DRIVER="mesa"
    if [ "$HAS_NVIDIA" = "yes" ]; then
        case "$NVIDIA_GEN" in
            unsupported)
                say "An older NVIDIA graphics card was detected (Kepler generation or earlier, such as most GeForce GTX 600 and 700 series cards)." \
                    "NVIDIA no longer supports these cards in its proprietary driver, and Gentoo masks the old driver branches because they no longer get security fixes. The open source Nouveau driver is used instead: it works, with lower 3D performance."
                info "Graphics driver: Nouveau (open source)."
                GPU_DRIVER="nouveau"
                ;;
            legacy580)
                say "An NVIDIA graphics card of the Maxwell, Pascal or Volta generation was detected (for example GeForce GTX 750, 900 or 10xx series)." \
                    "NVIDIA drivers 595 and newer no longer support these cards. The 580 branch is the last one that does; Gentoo's driver package treats it as a long-term branch. If you choose the proprietary driver, the installer keeps this system on the 580 branch by adding '>=x11-drivers/nvidia-drivers-581' to /etc/portage/package.mask/gentoo-install." \
                    "Nouveau is the open source driver. It works out of the box but is much slower on most of these cards."
                choose GPU_DRIVER "NVIDIA driver" "$def_gpu" \
                    "nvidia|Proprietary NVIDIA driver, 580 branch (recommended)" \
                    "nouveau|Nouveau open source driver"
                ;;
            *)
                say "An NVIDIA graphics card was detected." \
                    "The proprietary NVIDIA driver gives full performance, CUDA and working power management." \
                    "Nouveau is the open source driver. It works out of the box but is much slower on most cards because it cannot raise their clock speeds."
                choose GPU_DRIVER "NVIDIA driver" "$def_gpu" \
                    "nvidia|Proprietary NVIDIA driver (recommended)" \
                    "nouveau|Nouveau open source driver"
                ;;
        esac
    fi
    compute_video_cards
    if [ -n "$VIDEO_CARDS" ]; then
        info "Graphics drivers (VIDEO_CARDS) set from the detected hardware: ${VIDEO_CARDS}"
    else
        warn "No known graphics hardware was detected, so VIDEO_CARDS is left empty (a basic framebuffer driver will be used)."
    fi
    if [ "$HAS_AMD" = "yes" ]; then
        say "Note: amdgpu/radeonsi covers AMD cards from the GCN generation (Radeon HD 7000, 2012) onward. For older Radeon cards, add 'radeon r600' to VIDEO_CARDS in /etc/portage/make.conf after installing."
    fi

    subsection "Networking"
    local def_net="networkmanager"
    if [ "$DE" = "none" ] && [ "$HAS_WIFI" = "no" ]; then def_net="dhcpcd"; fi
    say "This decides how the installed system connects to the network."
    local -a nopts=("networkmanager|NetworkManager: wired and Wi-Fi, a network icon in desktops, 'nmtui' in a terminal (recommended)"
                    "dhcpcd|dhcpcd: minimal, for wired Ethernet only (no Wi-Fi setup)")
    if [ "$INIT" = "systemd" ]; then
        nopts+=("networkd|systemd-networkd: built into systemd, for wired Ethernet only")
    fi
    choose NET_TOOL "Network manager" "${NET_TOOL:-$def_net}" "${nopts[@]}"
    if [ "$HAS_WIFI" = "yes" ] && [ "$NET_TOOL" != "networkmanager" ]; then
        warn "This machine has Wi-Fi, but ${NET_TOOL} as configured here only handles wired connections. You would have to set up Wi-Fi yourself after installing."
    fi

    subsection "Other hardware and services"
    local def_bt="n"
    if [ "$HAS_BT" = "yes" ]; then def_bt="y"; fi
    say "Bluetooth support installs BlueZ and enables its service$( [ "$HAS_BT" = yes ] && printf '%s\n' " (a Bluetooth adapter was detected)" )."
    ask_yn WANT_BT "Install Bluetooth support?" "$(yn_default WANT_BT "$def_bt")"

    local def_cups
    def_cups=$(yn_default WANT_CUPS n)
    WANT_CUPS="no"
    if [ "$DE" != "none" ]; then
        say "CUPS is the printing system. Only needed if you print from this computer."
        ask_yn WANT_CUPS "Install printer support (CUPS)?" "$def_cups"
    fi

    local def_ssh="n"
    if [ "$DE" = "none" ]; then def_ssh="y"; fi
    say "An SSH server lets you log in to this machine remotely over the network. Useful for servers; not needed on a typical desktop."
    ask_yn WANT_SSH "Enable the SSH server?" "$(yn_default WANT_SSH "$def_ssh")"

    q_special_hardware
}

# Questions that only appear on hardware that needs them: Broadcom Wi-Fi,
# laptop power management and Mac fan control.
q_special_hardware() {
    local def
    def=$(yn_default WANT_BCM_WL y)
    WANT_BCM_WL="no"
    if [ "$BCM_WIFI" = "wl" ] && [ "$VIRT" = "none" ]; then
        subsection "Broadcom Wi-Fi"
        say "This computer's Broadcom Wi-Fi card (BCM4360, BCM4352, BCM43142 or BCM43228, found in most Macs from 2013 on and some PC laptops) only works with Broadcom's own 'wl' driver." \
            "Gentoo packages it as net-wireless/broadcom-sta. It is proprietary, and Gentoo only has a testing (~amd64) version of it, because Broadcom stopped maintaining it years ago and it depends on community patches to build against new kernels. The installer would accept that one package's testing version and its Broadcom licence. It is compiled for the installed kernel and rebuilt automatically when the kernel updates." \
            "Without it this card does not work; a USB Wi-Fi adapter or a wired connection works instead."
        ask_yn WANT_BCM_WL "Install the Broadcom wl Wi-Fi driver?" "$def"
    elif [ "$BCM_WIFI" = "b43" ] && [ "$VIRT" = "none" ]; then
        info "Broadcom Wi-Fi card found that uses the b43 driver: its firmware (sys-firmware/b43-firmware) will be installed."
    fi

    def=$(yn_default WANT_POWER y)
    WANT_POWER="no"
    POWER_TOOL=""
    if [ "$IS_LAPTOP" = "yes" ]; then
        subsection "Laptop power management"
        case "$DE" in
            plasma|gnome)
                POWER_TOOL="ppd"
                say "power-profiles-daemon lets you switch between power saving, balanced and performance modes from $(de_label "$DE")'s battery menu. It is what $(de_label "$DE") is built to use." ;;
            *)
                POWER_TOOL="tlp"
                say "TLP applies power saving settings automatically (CPU, disks, Wi-Fi, USB, PCIe), with separate settings on battery and on mains power. It runs on its own after boot; its settings are in /etc/tlp.conf." ;;
        esac
        if [ "$CPU_VENDOR" = "GenuineIntel" ]; then
            say "On Intel CPUs, thermald is installed too: it keeps the CPU from overheating by managing its power limits before the firmware has to throttle it hard."
        fi
        ask_yn WANT_POWER "Set up laptop power management?" "$def"
    fi

    def="n"
    if [[ $MAC_MODEL = MacBook* ]]; then def="y"; fi
    def=$(yn_default WANT_MBPFAN "$def")
    WANT_MBPFAN="no"
    if [ "$IS_APPLE" = "yes" ] && [ "$VIRT" = "none" ]; then
        subsection "Mac fan control"
        say "Linux does not control the fans of Intel Macs by itself, so they stay slow while the CPU heats up. mbpfan reads the temperature sensors and sets the fan speed (made for MacBook, MacBook Air and MacBook Pro models; it works on many other Intel Macs too)." \
            "Gentoo only has a testing (~amd64) version of app-laptop/mbpfan. The installer would accept that one package's testing version and enable the service."
        ask_yn WANT_MBPFAN "Install mbpfan for fan control?" "$def"
    fi
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
    if [ -n "$GENTOO_MIRRORS_VALUE" ]; then
        mopts+=("keep|Keep the mirrors chosen before: ${GENTOO_MIRRORS_VALUE}")
        def_mirror="keep"
    fi
    if have mirrorselect; then mopts+=("select|Choose mirrors myself (mirrorselect)"); fi
    choose mirror_mode "Download mirror" "$def_mirror" "${mopts[@]}"
    if [ "$mirror_mode" = "cdn" ]; then
        GENTOO_MIRRORS_VALUE=""
        DIST_BASE="https://distfiles.gentoo.org"
    elif [ "$mirror_mode" = "select" ]; then
        GENTOO_MIRRORS_VALUE=""
        DIST_BASE="https://distfiles.gentoo.org"
        say "mirrorselect will show a list. Use the arrow keys and space bar to mark mirrors near you, then confirm with Enter."
        pause
        handoff_screen
        local out
        out=$(mirrorselect -i -o 2>/dev/tty || true)
        GENTOO_MIRRORS_VALUE=$(sed -n 's/^GENTOO_MIRRORS="\(.*\)"$/\1/p' <<<"$out" | head -n1 || true)
        GENTOO_MIRRORS_VALUE=$(trim "$GENTOO_MIRRORS_VALUE")
        if [ -n "$GENTOO_MIRRORS_VALUE" ]; then
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
    if [ "$DE" != "none" ]; then
        subsection "Flatpak"
        say "Flatpak installs desktop applications from Flathub in their own sandboxed containers, independent from Portage. They are prebuilt (no compiling), update separately with 'flatpak update', and use more disk space because they bundle their own libraries. Handy for large or proprietary apps such as Steam, Discord or Spotify."
        ask_yn WANT_FLATPAK "Install Flatpak and add the Flathub repository?" "$def_flatpak"
        if [ "$WANT_FLATPAK" = "yes" ]; then
            choose_multi FLATPAK_APPS "Flatpak apps to install now (you can add more any time later)" "${FLATPAK_CATALOG[@]}"
        fi
    fi
    if [ "$WANT_FLATPAK" != "yes" ]; then FLATPAK_APPS=""; fi

    subsection "Native packages"
    say "These are installed with Portage (emerge), the Gentoo way. Everything is optional and you can install anything else later with 'emerge --ask <package>'. Pick nothing here if you chose the same apps as Flatpaks above."
    local -a catalog=()
    if [ "$DE" != "none" ]; then catalog+=("${NATIVE_GUI_APPS[@]}"); fi
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
    if [ "$INIT" = "systemd" ]; then PROFILE_SUFFIX+="/systemd"; fi
    if [ "$DE" = "none" ]; then STAGE3_VARIANT="$INIT"; else STAGE3_VARIANT="desktop-${INIT}"; fi
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
    if [ "$DE" != "none" ]; then
        if [ "$DE" = "sway" ]; then
            summary_row "Login:" "text console$( [ "$SWAY_AUTOSTART" = yes ] && printf '%s\n' ", Sway starts automatically on tty1" )"
        else
            summary_row "Login screen:" "$( [ "$DM" = none ] && printf '%s\n' "none (text console)" || printf '%s\n' "$DM" )"
        fi
    fi
    summary_row "Init system:" "$INIT"
    summary_row "Profile:" "default/linux/amd64/<current>${PROFILE_SUFFIX}"
    summary_row "Stage3:" "stage3-amd64-${STAGE3_VARIANT}"
    summary_row "Binary packages:" "$USE_BINPKG$( [ "$BINHOST_V3" = yes ] && printf '%s\n' " (x86-64-v3 preferred)" )"
    summary_row "Kernel:" "sys-kernel/${KERNEL_PKG}"
    summary_row "Compiler flags:" "-march=native -O2 -pipe"
    summary_row "MAKEOPTS:" "-j${MAKE_JOBS} -l${NPROC}   (emerge --jobs=${EMERGE_JOBS})"
    summary_row "CPU_FLAGS_X86:" "$( [ "$TUNE_CPU_FLAGS" = yes ] && printf '%s\n' "detected with cpuid2cpuflags" || printf '%s\n' "profile default" )"
    summary_row "VIDEO_CARDS:" "${VIDEO_CARDS:-(none)}"
    printf '\n'
    summary_row "Boot mode / bootloader:" "${BOOT_MODE^^}$( [ "$UEFI_BITS" = 32 ] && printf ' (32-bit)' ) / ${BOOTLOADER}$( [ "$LIVE_BOOT_MODE" = bios ] && [ "$BOOT_MODE" = uefi ] && printf '%s' "   (live system in BIOS mode: bootloader at the EFI fallback path)" )"
    summary_row "Partition table:" "${PTABLE^^}"
    if [ "$PART_MODE" = "auto" ]; then
        summary_row "Disk:" "${DISK}  ${C_RED}(EVERYTHING ON IT WILL BE ERASED)${C_RESET}"
    else
        summary_row "Disk mode:" "manual partitions"
        if [ "$BOOT_MODE" = "uefi" ]; then
            summary_row "EFI partition:" "${ESP_PART} -> /efi $( [ "$FORMAT_ESP" = yes ] && printf '%s\n' "(WILL BE FORMATTED)" || printf '%s\n' "(kept, not formatted)" )"
        fi
        if [ -n "$BOOT_PART" ]; then summary_row "/boot partition:" "${BOOT_PART} (WILL BE FORMATTED)"; fi
        summary_row "Root partition:" "${ROOT_PART} (WILL BE FORMATTED)"
        if [ -n "$SWAP_PART" ]; then summary_row "Swap partition:" "${SWAP_PART} (WILL BE FORMATTED)"; fi
        if [ "$BOOT_MODE" = "bios" ]; then summary_row "GRUB installed to:" "$GRUB_DISK"; fi
    fi
    summary_row "Root filesystem:" "${FS}$( [ "$FS" = btrfs ] && printf '%s\n' " (subvolumes @, @home; zstd compression)" )"
    summary_row "Encryption:" "$( [ "$ENCRYPT" = yes ] && printf '%s\n' "LUKS2" || printf '%s\n' "no" )"
    summary_row "Swap:" "$SWAP_MODE$( [ -n "$SWAP_SIZE_GIB" ] && printf '%s\n' " (${SWAP_SIZE_GIB} GiB)" )"
    printf '\n'
    summary_row "Hostname:" "$NEW_HOSTNAME"
    summary_row "Timezone:" "$TIMEZONE"
    summary_row "Locale:" "$LOCALE"
    summary_row "Console keymap:" "$KEYMAP"
    if [ "$DE" != "none" ]; then summary_row "Desktop keyboard:" "${XKB_LAYOUT}${XKB_VARIANT:+ (${XKB_VARIANT})}"; fi
    summary_row "User:" "$USERNAME (admin tool: ${PRIV_TOOL}, shell: ${USER_SHELL:-bash})"
    printf '\n'
    summary_row "Network:" "$NET_TOOL"
    summary_row "Graphics driver:" "$( [ "$HAS_NVIDIA" = yes ] && printf '%s\n' "${GPU_DRIVER}$( [ "$GPU_DRIVER" = nvidia ] && [ "$NVIDIA_GEN" = legacy580 ] && printf '%s\n' " (580 branch)" )" || printf '%s\n' "Mesa (open source)" )"
    summary_row "Bluetooth / printing / SSH:" "${WANT_BT} / ${WANT_CUPS} / ${WANT_SSH}"
    if [ "$VIRT" != "none" ]; then summary_row "VM guest tools:" "$VIRT"; fi
    if [ "$BCM_WIFI" = "wl" ] && [ "$VIRT" = "none" ]; then summary_row "Broadcom wl driver:" "$WANT_BCM_WL"; fi
    if [ "$BCM_WIFI" = "b43" ] && [ "$VIRT" = "none" ]; then summary_row "Broadcom firmware:" "b43-firmware"; fi
    if [ "$IS_LAPTOP" = "yes" ]; then
        summary_row "Power management:" "${WANT_POWER}$( [ "$WANT_POWER" = yes ] && printf ' (%s%s)' "$( [ "$POWER_TOOL" = ppd ] && printf 'power-profiles-daemon' || printf 'TLP' )" "$( [ "$CPU_VENDOR" = GenuineIntel ] && printf ' + thermald' )" )"
    fi
    if [ "$IS_APPLE" = "yes" ] && [ "$VIRT" = "none" ]; then summary_row "Mac fan control:" "$WANT_MBPFAN"; fi
    summary_row "Mirror:" "${GENTOO_MIRRORS_VALUE:-global CDN (distfiles.gentoo.org)}"
    summary_row "Flatpak:" "${WANT_FLATPAK}${FLATPAK_APPS:+ (apps: ${FLATPAK_APPS})}"
    summary_row "Native packages:" "${EXTRA_PKGS:-none}"
    printf '\n'
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
    printf '\n'
    if [ "$PART_MODE" = "auto" ]; then
        warn "LAST WARNING: every partition and file on ${DISK} will be permanently deleted."
        read_line typed "  Type ERASE in capital letters to continue (anything else goes back): "
        if [ "$(trim "$typed")" != "ERASE" ]; then warn "Not confirmed."; return 1; fi
    else
        warn "LAST WARNING: the partitions marked 'WILL BE FORMATTED' above will be erased."
        read_line typed "  Type FORMAT in capital letters to continue (anything else goes back): "
        if [ "$(trim "$typed")" != "FORMAT" ]; then warn "Not confirmed."; return 1; fi
    fi
    return 0
}

# ----------------------------------------------------------------------------
# Disk preparation
# ----------------------------------------------------------------------------
root_fs_dev() {
    if [ "$ENCRYPT" = "yes" ]; then printf '%s\n' "/dev/mapper/${LUKS_NAME}"; else printf '%s\n' "$ROOT_PART"; fi
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
    if [ -e "/dev/mapper/${LUKS_NAME}" ]; then
        cryptsetup close "$LUKS_NAME" 2>/dev/null || true
    fi
    local -a devs=()
    local p
    if [ "$PART_MODE" = "auto" ]; then
        while IFS= read -r p; do devs+=("$p"); done < <(lsblk -lnpo NAME "$DISK" 2>/dev/null | tail -n +2)
    else
        for p in "$ESP_PART" "$BOOT_PART" "$ROOT_PART" "$SWAP_PART"; do
            if [ -n "$p" ]; then devs+=("$p"); fi
        done
    fi
    for p in "${devs[@]}"; do
        swapoff "$p" 2>/dev/null || true
        umount "$p" 2>/dev/null || true
    done
    if [ "$PART_MODE" = "auto" ] && have vgchange; then
        vgchange -an >>"$LOG" 2>&1 || true
    fi
}

# Build the sfdisk script for automatic partitioning (sets AUTO_LAYOUT and the *_PART variables).
build_auto_layout() {
    local layout n=1
    ESP_PART=""; BIOS_PART=""; BOOT_PART=""; SWAP_PART=""; ROOT_PART=""
    if [ "$PTABLE" = "mbr" ]; then
        # MBR (BIOS mode only): GRUB embeds itself in the gap before the first
        # partition, which sfdisk leaves at 1 MiB. The partition holding /boot
        # is marked bootable (active), which some BIOSes and Macs require.
        layout="label: dos"$'\n'
        if [ "$NEED_BOOT_PART" = "yes" ]; then
            layout+="size=${BOOT_SIZE_MIB}MiB, type=83, bootable"$'\n'
            BOOT_PART=$(part_dev "$DISK" "$n")
            n=$(( n + 1 ))
        fi
        if [ "$SWAP_MODE" = "partition" ]; then
            layout+="size=${SWAP_SIZE_GIB}GiB, type=82"$'\n'
            SWAP_PART=$(part_dev "$DISK" "$n")
            n=$(( n + 1 ))
        fi
        if [ "$NEED_BOOT_PART" = "yes" ]; then
            layout+="type=83"$'\n'
        else
            layout+="type=83, bootable"$'\n'
        fi
        ROOT_PART=$(part_dev "$DISK" "$n")
        AUTO_LAYOUT=$layout
        return 0
    fi
    layout="label: gpt"$'\n'
    if [ "$BOOT_MODE" = "uefi" ]; then
        layout+="size=${ESP_SIZE_MIB}MiB, type=${GUID_ESP}, name=\"EFI system partition\""$'\n'
        ESP_PART=$(part_dev "$DISK" "$n")
    else
        layout+="size=1MiB, type=${GUID_BIOS}, name=\"BIOS boot\""$'\n'
        BIOS_PART=$(part_dev "$DISK" "$n")
    fi
    n=$(( n + 1 ))
    if [ "$NEED_BOOT_PART" = "yes" ]; then
        layout+="size=${BOOT_SIZE_MIB}MiB, type=${GUID_LINUX}, name=\"Gentoo boot\""$'\n'
        BOOT_PART=$(part_dev "$DISK" "$n")
        n=$(( n + 1 ))
    fi
    if [ "$SWAP_MODE" = "partition" ]; then
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
    while IFS= read -r p; do
        wipefs -af "$p" >>"$LOG" 2>&1 || true
    done < <(lsblk -lnpo NAME,TYPE "$DISK" 2>/dev/null | awk '$2=="part" {print $1}')
    run wipefs -af "$DISK"

    info "Writing the new ${PTABLE^^} partition table with sfdisk:"
    printf '%s' "$AUTO_LAYOUT" | sed 's/^/      /'
    printf '%s' "$AUTO_LAYOUT" | run sfdisk --wipe always --wipe-partitions always "$DISK"
    udevadm settle 2>/dev/null || true
    sleep 2

    local tries
    for p in "$ESP_PART" "$BIOS_PART" "$BOOT_PART" "$SWAP_PART" "$ROOT_PART"; do
        [ -n "$p" ] || continue
        tries=0
        while [ ! -b "$p" ]; do
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
    if [ "$BOOT_MODE" = "uefi" ]; then
        if [ "$FORMAT_ESP" = "yes" ]; then
            info "Formatting the EFI system partition ${ESP_PART} as FAT32."
            run mkfs.vfat -F 32 -n EFI "$ESP_PART"
        else
            info "Keeping the existing EFI system partition ${ESP_PART} as it is."
        fi
    fi
    if [ -n "$BOOT_PART" ]; then
        info "Formatting ${BOOT_PART} as ext4 for /boot."
        run mkfs.ext4 -F -L gentoo-boot "$BOOT_PART"
    fi
    if [ -n "$SWAP_PART" ]; then
        info "Formatting ${SWAP_PART} as swap."
        run mkswap -L gentoo-swap "$SWAP_PART"
    fi
    if [ "$ENCRYPT" = "yes" ]; then
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
            mkdir -p -- "$MNT"
            run mount "$dev" "$MNT"
            run btrfs subvolume create "$MNT/@"
            run btrfs subvolume create "$MNT/@home"
            run umount "$MNT"
            ;;
    esac
}

# Mount the target filesystems (safe to call more than once).
mount_target() {
    mkdir -p -- "$MNT"
    if [ "$ENCRYPT" = "yes" ] && [ ! -e "/dev/mapper/${LUKS_NAME}" ]; then
        info "Unlocking the encrypted root partition ${ROOT_PART}."
        handoff_screen
        cryptsetup open "$ROOT_PART" "$LUKS_NAME"
    fi
    local dev
    dev=$(root_fs_dev)
    if ! mountpoint -q "$MNT"; then
        if [ "$FS" = "btrfs" ]; then
            run mount -o "${BTRFS_OPTS},subvol=@" "$dev" "$MNT"
        else
            run mount -o noatime "$dev" "$MNT"
        fi
    fi
    if [ "$FS" = "btrfs" ]; then
        mkdir -p -- "$MNT/home"
        if ! mountpoint -q "$MNT/home"; then run mount -o "${BTRFS_OPTS},subvol=@home" "$dev" "$MNT/home"; fi
    fi
    if [ -n "$BOOT_PART" ]; then
        mkdir -p -- "$MNT/boot"
        if ! mountpoint -q "$MNT/boot"; then run mount -o noatime "$BOOT_PART" "$MNT/boot"; fi
    fi
    if [ "$BOOT_MODE" = "uefi" ]; then
        mkdir -p -- "$MNT/efi"
        if ! mountpoint -q "$MNT/efi"; then run mount -o umask=0077 "$ESP_PART" "$MNT/efi"; fi
    fi
    if [ -n "$SWAP_PART" ] && ! grep -q "^${SWAP_PART} " /proc/swaps; then
        swapon "$SWAP_PART" 2>/dev/null || true
    fi
}

prepare_disk() {
    section "Preparing the disk"
    release_target
    if [ "$PART_MODE" = "auto" ]; then
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
    if [ -s "${f}.asc" ] && have gpg; then
        make_work_dir
        gh=$(mktemp -d "${WORK_DIR}/gnupg.XXXXXX")
        chmod 700 -- "$gh"
        if [ -r /usr/share/openpgp-keys/gentoo-release.asc ]; then
            GNUPGHOME=$gh gpg --batch --quiet --import /usr/share/openpgp-keys/gentoo-release.asc >>"$LOG" 2>&1 || true
        fi
        status=$(GNUPGHOME=$gh gpg --batch --status-fd 1 --verify "${f}.asc" "$f" 2>>"$LOG" || true)
        if ! grep -q '^\[GNUPG:\] VALIDSIG' <<<"$status" && ! grep -q '^\[GNUPG:\] BADSIG' <<<"$status"; then
            info "The signing key is not on this live system; fetching it from gentoo.org (WKD)."
            GNUPGHOME=$gh gpg --batch --auto-key-locate=clear,nodefault,wkd --locate-key releng@gentoo.org >>"$LOG" 2>&1 || true
            status=$(GNUPGHOME=$gh gpg --batch --status-fd 1 --verify "${f}.asc" "$f" 2>>"$LOG" || true)
        fi
        rm -rf -- "$gh"
        if grep -q '^\[GNUPG:\] BADSIG' <<<"$status"; then
            die "The PGP signature of ${f} is BAD. The file is corrupted or has been tampered with. Aborting."
        fi
        if grep -q '^\[GNUPG:\] VALIDSIG' <<<"$status"; then
            sig_ok="yes"
            ok "PGP signature is valid (signed by Gentoo Release Engineering)."
        fi
    fi

    if [ -s "${f}.sha256" ]; then
        local expected actual
        # "<64 hex digits>  <file name>" lines, possibly inside a PGP clearsigned block.
        expected=$(tr -d '\r' <"${f}.sha256" | awk -v f="$f" '
            !found && length($1) == 64 && $1 ~ /^[0-9a-fA-F]+$/ && ($2 == f || $2 == "*" f) { print tolower($1); found = 1 }')
        if [ -n "$expected" ]; then
            actual=$(sha256sum "$f" | awk '{print $1}')
            if [ "$expected" != "$actual" ]; then
                die "SHA256 checksum mismatch for ${f}. The download is corrupted. Run the installer again."
            fi
            ok "SHA256 checksum matches."
        else
            warn "Could not read the checksum file; skipping the SHA256 check."
        fi
    fi

    if [ "$sig_ok" != "yes" ]; then
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
    if [ -z "$rel" ]; then
        log "Stage3 index content: ${listing}"
        die "Could not find a stage3-amd64-${STAGE3_VARIANT} file name in ${index} (its content is in the log). Nothing on disk has been changed."
    fi
    if [[ $rel = */* ]]; then
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
    if [ -z "$STAGE3_URL" ]; then resolve_stage3; fi
    local url=$STAGE3_URL file=$STAGE3_FILE
    cd -- "$MNT" || die "Could not change into ${MNT}."
    fetch "$url" "$file"
    fetch "${url}.asc" "${file}.asc" || warn "Could not download the PGP signature file."
    fetch "${url}.sha256" "${file}.sha256" || warn "Could not download the SHA256 checksum file."
    verify_stage3 "$file"
    info "Unpacking the stage3 into ${MNT}. This takes a minute or two and prints nothing while it works."
    run tar xpf "$file" --xattrs-include='*.*' --numeric-owner -C "$MNT"
    rm -f -- "$file" "${file}.asc" "${file}.sha256"
    cd / || exit 1
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
    cp -L -- /etc/resolv.conf "$MNT/etc/resolv.conf"
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
    [ -n "$root_uuid" ] || die "Could not read the UUID of the root filesystem."
    KERNEL_CMDLINE="root=UUID=${root_uuid}"
    if [ "$FS" = "btrfs" ]; then KERNEL_CMDLINE+=" rootflags=subvol=@"; fi
    if [ "$ENCRYPT" = "yes" ]; then
        luks_uuid=$(blk_uuid "$ROOT_PART")
        [ -n "$luks_uuid" ] || die "Could not read the UUID of the LUKS container."
        KERNEL_CMDLINE="rd.luks.uuid=${luks_uuid} ${KERNEL_CMDLINE}"
        extra+=" rd.luks.uuid=${luks_uuid}"
    fi
    if [ "$GPU_DRIVER" = "nvidia" ]; then
        KERNEL_CMDLINE+=" nvidia_drm.modeset=1"
        extra+=" nvidia_drm.modeset=1"
    fi
    GRUB_EXTRA_CMDLINE=$(trim "$extra")
}

write_make_conf() {
    local f="$MNT/etc/portage/make.conf"
    if [ -f "$f" ] && [ ! -f "$f.stage3-original" ]; then cp -- "$f" "$f.stage3-original"; fi

    local extra=""
    if [ "$BOOTLOADER" = "grub" ] && [ "$BOOT_MODE" = "uefi" ] && [ "$UEFI_BITS" = "32" ]; then
        extra+=$'\n# GRUB firmware target for this machine (32-bit UEFI with a 64-bit CPU).\nGRUB_PLATFORMS="efi-32"\n'
    elif [ "$BOOTLOADER" = "grub" ] && [ "$BOOT_MODE" = "uefi" ]; then
        extra+=$'\n# GRUB firmware target for this machine.\nGRUB_PLATFORMS="efi-64"\n'
    elif [ "$BOOTLOADER" = "grub" ]; then
        extra+=$'\n# GRUB firmware target for this machine.\nGRUB_PLATFORMS="pc"\n'
    fi
    if [ "$USE_BINPKG" = "yes" ]; then
        extra+=$'\n# Use Gentoo\'s official binary packages when they match this configuration,\n# and require a valid PGP signature on each of them (current Portage checks\n# signatures by default; this keeps it explicit).\n# Remove this line to build everything from source.\nFEATURES="${FEATURES} getbinpkg binpkg-request-signature"\n'
    fi
    if [ -n "$GENTOO_MIRRORS_VALUE" ]; then
        extra+=$'\n# Mirrors chosen with mirrorselect.\nGENTOO_MIRRORS="'"${GENTOO_MIRRORS_VALUE}"$'"\n'
    fi
    local lang region
    lang=${LOCALE%%_*}
    region=${LOCALE#*_}
    region=${region%%.*}
    if [ "$lang" != "en" ] || [ "$region" != "US" ]; then
        extra+=$'\n# Translations to install for packages that offer them (for example LibreOffice, Firefox).\nL10N="'"${lang}-${region} ${lang}"$'"\n'
    fi

    cat >"$f" <<EOF
# /etc/portage/make.conf
# Written by gentoo_install.sh ${SCRIPT_VERSION} on $(date -u '+%Y-%m-%d %H:%M UTC').
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
    [ "$USE_BINPKG" = "yes" ] || return 0
    local ver dir f
    ver=$(profile_version)
    if [ -z "$ver" ]; then
        warn "Could not determine the profile version from the stage3; assuming 23.0."
        ver="23.0"
    fi
    dir="$MNT/etc/portage/binrepos.conf"
    f="$dir/gentoobinhost.conf"
    mkdir -p -- "$dir"
    if [ -f "$f" ] && [ ! -f "$dir/gentoobinhost.conf.stage3-original" ]; then
        cp -- "$f" "$dir/gentoobinhost.conf.stage3-original"
    fi
    {
        printf '%s\n' "# Gentoo's official binary package host."
        printf '%s\n' "# Written by gentoo_install.sh. The higher priority repository is tried first."
        if [ "$BINHOST_V3" = "yes" ]; then
            printf '%s\n' ""
            printf '%s\n' "# Packages built for x86-64-v3 CPUs (AVX2 generation and newer)."
            printf '%s\n' "[gentoo-x86-64-v3]"
            printf '%s\n' "priority = 9999"
            printf '%s\n' "sync-uri = https://distfiles.gentoo.org/releases/amd64/binpackages/${ver}/x86-64-v3/"
            printf '%s\n' "verify-signature = true"
        fi
        printf '%s\n' ""
        printf '%s\n' "# Packages built for any x86-64 CPU."
        printf '%s\n' "[gentoo]"
        printf '%s\n' "priority = 9959"
        printf '%s\n' "sync-uri = https://distfiles.gentoo.org/releases/amd64/binpackages/${ver}/x86-64/"
        printf '%s\n' "verify-signature = true"
    } >"$f"
    ok "Wrote /etc/portage/binrepos.conf/gentoobinhost.conf"
}

write_package_files() {
    local pu="$MNT/etc/portage/package.use" pl="$MNT/etc/portage/package.license"
    mkdir -p -- "$pu" "$pl"

    {
        printf '%s\n' "# Written by gentoo_install.sh"
        printf '%s\n' "# installkernel installs new kernels, builds the initramfs with dracut and"
        printf '%s\n' "# updates the bootloader automatically every time a kernel is emerged."
        if [ "$BOOTLOADER" = "grub" ]; then
            printf '%s\n' "sys-kernel/installkernel dracut grub"
        else
            printf '%s\n' "sys-kernel/installkernel dracut systemd systemd-boot"
            if [ "$INIT" = "openrc" ]; then
                printf '%s\n' "# systemd-boot and kernel-install on OpenRC come from systemd-utils."
                printf '%s\n' "sys-apps/systemd-utils boot kernel-install"
            else
                printf '%s\n' "sys-apps/systemd boot"
            fi
        fi
    } >"$pu/installkernel"

    if [ "$ENCRYPT" = "yes" ] && [ "$INIT" = "systemd" ]; then
        printf '%s\n' "# Written by gentoo_install.sh: unlock LUKS in the systemd initramfs." \
            "sys-apps/systemd cryptsetup" >"$pu/luks"
    fi
    if [ "$WANT_FLATPAK" = "yes" ]; then
        printf '%s\n' "# Written by gentoo_install.sh: show Flathub apps in the desktop software centres." \
            "kde-plasma/discover flatpak" \
            "gnome-extra/gnome-software flatpak" >"$pu/flatpak"
    fi

    {
        printf '%s\n' "# Written by gentoo_install.sh: licenses accepted for specific packages."
        printf '%s\n' "sys-kernel/linux-firmware linux-fw-redistributable"
        printf '%s\n' "sys-firmware/intel-microcode intel-ucode"
        if [ "$GPU_DRIVER" = "nvidia" ]; then printf '%s\n' "x11-drivers/nvidia-drivers NVIDIA-2025"; fi
        if [[ " $EXTRA_PKGS " = *" www-client/google-chrome "* ]]; then printf '%s\n' "www-client/google-chrome google-chrome"; fi
        if [ "$WANT_BCM_WL" = "yes" ]; then printf '%s\n' "net-wireless/broadcom-sta Broadcom"; fi
        if [ "$BCM_WIFI" = "b43" ] && [ "$VIRT" = "none" ]; then printf '%s\n' "sys-firmware/b43-firmware Broadcom"; fi
    } >"$pl/gentoo-install"

    # Testing (~amd64) versions accepted for single packages that have no
    # stable version, only when the hardware needs them and the user agreed.
    local -a kw=()
    if [ "$WANT_BCM_WL" = "yes" ]; then kw+=("net-wireless/broadcom-sta ~amd64"); fi
    if [ "$WANT_MBPFAN" = "yes" ]; then kw+=("app-laptop/mbpfan ~amd64"); fi
    if [ "${#kw[@]}" -gt 0 ]; then
        local pk="$MNT/etc/portage/package.accept_keywords"
        if [ ! -f "$pk" ]; then mkdir -p -- "$pk"; pk+="/gentoo-install"; fi
        printf '%s\n' "# Written by gentoo_install.sh: testing versions allowed for hardware support." \
            "${kw[@]}" >>"$pk"
        ok "Allowed testing versions: ${kw[*]}"
    fi

    if [ "$GPU_DRIVER" = "nvidia" ] && [ "$NVIDIA_GEN" = "legacy580" ]; then
        local pm="$MNT/etc/portage/package.mask"
        if [ ! -f "$pm" ]; then mkdir -p -- "$pm"; pm+="/gentoo-install"; fi
        printf '%s\n' "# Written by gentoo_install.sh: this computer's NVIDIA card (Maxwell, Pascal" \
            "# or Volta) is supported up to the 580 driver branch. Newer branches only" \
            "# support Turing (GeForce GTX 16xx / RTX 20xx) and newer cards." \
            ">=x11-drivers/nvidia-drivers-581" >>"$pm"
        ok "Kept NVIDIA drivers on the 580 branch (package.mask)"
    fi
    ok "Wrote package.use and package.license entries"
}

write_fstab() {
    local root_uuid f="$MNT/etc/fstab"
    root_uuid=$(blk_uuid "$(root_fs_dev)")
    [ -n "$root_uuid" ] || die "Could not read the UUID of the root filesystem."
    {
        printf '%s\n' "# /etc/fstab: filesystems mounted at boot. Written by gentoo_install.sh."
        printf '%s\n' "# Devices are referenced by UUID so the entries survive disk renumbering."
        printf '%s\n' "# <filesystem>                             <mountpoint> <type> <options>                       <dump> <pass>"
        case "$FS" in
            ext4) printf '%s\n' "UUID=${root_uuid}  /      ext4   noatime                          0 1" ;;
            xfs) printf '%s\n' "UUID=${root_uuid}  /      xfs    noatime                          0 0" ;;
            btrfs)
                printf '%s\n' "UUID=${root_uuid}  /      btrfs  ${BTRFS_OPTS},subvol=@      0 0"
                printf '%s\n' "UUID=${root_uuid}  /home  btrfs  ${BTRFS_OPTS},subvol=@home  0 0"
                ;;
        esac
        if [ -n "$BOOT_PART" ]; then
            printf '%s\n' "UUID=$(blk_uuid "$BOOT_PART")  /boot  ext4   noatime                          0 2"
        fi
        if [ "$BOOT_MODE" = "uefi" ]; then
            printf '%s\n' "UUID=$(blk_uuid "$ESP_PART")  /efi   vfat   umask=0077,noatime               0 2"
        fi
        if [ -n "$SWAP_PART" ]; then
            printf '%s\n' "UUID=$(blk_uuid "$SWAP_PART")  none   swap   sw                               0 0"
        fi
    } >"$f"
    ok "Wrote /etc/fstab"
    sed 's/^/    /' "$f"
}

write_kernel_config() {
    mkdir -p -- "$MNT/etc/kernel" "$MNT/etc/dracut.conf.d"
    printf '%s\n' "$KERNEL_CMDLINE" >"$MNT/etc/kernel/cmdline"
    {
        printf '%s\n' "# Written by gentoo_install.sh"
        printf '%s\n' "# Host-only initramfs: contains just the drivers this machine needs (smaller"
        printf '%s\n' "# and faster). If you move this disk to different hardware, set hostonly=\"no\""
        printf '%s\n' "# and run: emerge --config sys-kernel/${KERNEL_PKG}"
        printf '%s\n' 'hostonly="yes"'
        printf '%s\n' "# Kernel command line built into the initramfs. The bootloader passes the same"
        printf '%s\n' "# parameters (GRUB_CMDLINE_LINUX or /etc/kernel/cmdline); this copy keeps the"
        printf '%s\n' "# system bootable if the bootloader configuration is ever lost. Dracut 111 and"
        printf '%s\n' "# newer no longer guess it (hostonly_cmdline), so it is set explicitly."
        printf '%s\n' "kernel_cmdline=\" ${KERNEL_CMDLINE} \""
        if [ "$ENCRYPT" = "yes" ]; then printf '%s\n' 'add_dracutmodules+=" crypt dm "'; fi
        if [ "$FS" = "btrfs" ]; then printf '%s\n' 'add_dracutmodules+=" btrfs "'; fi
    } >"$MNT/etc/dracut.conf.d/10-gentoo-install.conf"
    ok "Wrote /etc/kernel/cmdline and /etc/dracut.conf.d/10-gentoo-install.conf"
    info "Kernel command line: ${KERNEL_CMDLINE}"
}

save_config() {
    local f=$1 v
    {
        printf '%s\n' "# gentoo_install.sh ${SCRIPT_VERSION} settings, written $(date -u '+%Y-%m-%d %H:%M UTC')."
        printf '%s\n' "# Used by --resume and by the second (chroot) stage."
        for v in "${CONFIG_VARS[@]}"; do
            declare -p "$v" | sed 's/^declare /declare -g /'
        done
    } >"$f"
    chmod 600 -- "$f"
}

load_config() {
    # shellcheck disable=SC1090
    . "$1"
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
    install -m 700 -- "$SELF" "${MNT}${SCRIPT_PATH}"
    : >"${MNT}${PROGRESS_PATH}"
    printf '%s\n' "live_setup" >>"${MNT}${PROGRESS_PATH}"
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
        printf '\n'
        err "The installation stopped inside the new system."
        err "Log: ${MNT}${TARGET_LOG}"
        print_resume_help
        exit 1
    fi
}

unmount_all() {
    sync
    if [ -n "$SWAP_PART" ]; then swapoff "$SWAP_PART" 2>/dev/null || true; fi
    umount -R "$MNT" 2>/dev/null || umount -lR "$MNT" 2>/dev/null || true
    if [ "$ENCRYPT" = "yes" ] && [ -e "/dev/mapper/${LUKS_NAME}" ]; then
        cryptsetup close "$LUKS_NAME" 2>/dev/null || true
    fi
}

finish_install() {
    cp -- "$LIVE_LOG" "$MNT/var/log/gentoo-install-live.log" 2>/dev/null || true
    if [ "$NET_TOOL" = "networkd" ]; then
        ln -sf ../run/systemd/resolve/stub-resolv.conf "$MNT/etc/resolv.conf"
    fi
    rm -f -- "$LIVE_CONF_COPY"

    section "Installation complete"
    say "Gentoo is installed. After rebooting, log in as '${USERNAME}'." \
        "To install software or update the system, open a terminal and run: gentoo_helper" \
        "A guide with the next steps (updating, reading Gentoo news, managing kernels) was saved as ~/${NOTES_NAME} in your home directory and in /root. Installation logs are in /var/log/gentoo-install.log and /var/log/gentoo-install-live.log."
    if [ -s "$MNT$FAILED_PATH" ]; then
        warn "These optional packages could not be installed: $(tr '\n' ' ' <"$MNT$FAILED_PATH")"
        say "The system works without them. Try again after booting with: emerge --ask <package>"
    fi
    if [ "$SECURE_BOOT" = "on" ]; then
        warn "Secure Boot is still enabled. Disable it in the firmware setup, or Gentoo will not boot."
    fi
    if [ "$IS_APPLE" = "yes" ] && [ "$BOOT_MODE" = "uefi" ]; then
        say "On this Mac: if it shows a flashing folder with a question mark after the restart, hold the Option key while it starts and choose 'EFI Boot'."
    elif [ "$IS_APPLE" = "yes" ]; then
        say "On this Mac: if it does not start Gentoo by itself, hold the Option key while it starts and choose 'Windows' (that is how Macs label any legacy BIOS system)."
    fi
    if [ "$BCM_WIFI" = "wl" ] && [ "$WANT_BCM_WL" = "yes" ]; then
        say "Broadcom Wi-Fi: the wl driver loads after the reboot. If Wi-Fi does not show up, check the end of the install log for a failed net-wireless/broadcom-sta build."
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
    if [ -f "${MNT}${CONF_PATH}" ]; then
        conf="${MNT}${CONF_PATH}"
    elif [ -f "$LIVE_CONF_COPY" ]; then
        conf="$LIVE_CONF_COPY"
    fi
    if [ -z "$conf" ]; then
        say "The new system is not mounted. Choose its root partition so the installer can find its saved settings."
        pick_partition ROOT_PART "Which partition is the root partition of the new Gentoo system?" ""
        ptype=$(blkid -c /dev/null -s TYPE -o value "$ROOT_PART" 2>/dev/null || true)
        dev=$ROOT_PART
        if [ "$ptype" = "crypto_LUKS" ]; then
            if [ ! -e "/dev/mapper/${LUKS_NAME}" ]; then
                info "The partition is encrypted. Enter its passphrase."
                handoff_screen
                cryptsetup open "$ROOT_PART" "$LUKS_NAME"
            fi
            dev="/dev/mapper/${LUKS_NAME}"
        fi
        mkdir -p -- "$MNT"
        if [ "$(blkid -c /dev/null -s TYPE -o value "$dev" 2>/dev/null || true)" = "btrfs" ]; then
            mount -o "${BTRFS_OPTS},subvol=@" "$dev" "$MNT"
        else
            mount "$dev" "$MNT"
        fi
        conf="${MNT}${CONF_PATH}"
        if [ ! -f "$conf" ]; then
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
    install -m 700 -- "$SELF" "${MNT}${SCRIPT_PATH}"
    ok "Settings loaded. Continuing with the steps that have not finished yet."
    ui_install_phase
    run_chroot_stage
    ui_finish_phase
    finish_install
}

fresh_install() {
    live_preflight
    : >"$LOG"
    log "gentoo_install.sh ${SCRIPT_VERSION} started"
    init_defaults
    welcome
    live_keyboard
    detect_hardware
    network_step
    sync_clock
    show_hardware
    mac_boot_check
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

# Install the chosen login shell and make it the user's shell. If it cannot be
# installed, the user keeps bash and the failure is listed at the end.
set_user_shell() {
    local want=${USER_SHELL:-bash} cmd path home="/home/${USERNAME}"
    local -a pkgs=()
    if [ "$want" = "bash" ] || ! valid_shell_choice "$want"; then return 0; fi
    read -ra pkgs <<<"$(shell_field "$want" 2)"
    cmd=$(shell_field "$want" 3)
    info "Installing the ${want} shell for ${USERNAME}."
    emerge_optional "the ${want} shell" "${pkgs[@]}"
    path=$(command -v "$cmd" 2>/dev/null || true)
    if [ -z "$path" ] || [ ! -x "$path" ]; then
        warn "The ${want} shell is not available, so ${USERNAME} keeps bash. Change it later with: chsh -s <path to the shell>"
        return 0
    fi
    # Login screens and chsh only accept shells listed in /etc/shells.
    if ! grep -qxF "$path" /etc/shells 2>/dev/null; then
        printf '%s\n' "$path" >>/etc/shells
    fi
    run usermod -s "$path" "$USERNAME"
    ok "Login shell for ${USERNAME}: ${path}"
    if [ "$want" = "zsh" ] && [ ! -e "$home/.zshrc" ]; then
        # Without a ~/.zshrc, zsh starts an interactive setup wizard on first use.
        printf '%s\n' "# Starter configuration written by gentoo_install.sh. Edit freely." \
            "HISTFILE=~/.zsh_history" "HISTSIZE=10000" "SAVEHIST=10000" \
            "setopt appendhistory sharehistory histignoredups" \
            "bindkey -e" \
            "autoload -Uz compinit && compinit" \
            "zstyle ':completion:*' menu select" \
            "autoload -Uz promptinit && promptinit" \
            "prompt gentoo" >"$home/.zshrc"
        chown -- "${USERNAME}:${USERNAME}" "$home/.zshrc"
        ok "Wrote a starter ~/.zshrc for ${USERNAME}."
    fi
}

# The file a login shell reads at login, and its syntax, for the shell USERNAME
# actually has (the chosen one may have failed to install). Prints
# "syntax file-relative-to-home", or nothing if autostart is not supported.
login_file_for_user() {
    local sh
    sh=$(getent passwd "$USERNAME" | cut -d: -f7)
    case "${sh##*/}" in
        bash) printf '%s\n' "sh .bash_profile" ;;
        zsh) printf '%s\n' "sh .zprofile" ;;
        yash) printf '%s\n' "sh .yash_profile" ;;
        dash|ksh|mksh|sh) printf '%s\n' "sh .profile" ;;
        fish) printf '%s\n' "fish .config/fish/conf.d/sway-autostart.fish" ;;
        tcsh|csh) printf '%s\n' "csh .login" ;;
        *) ;;
    esac
}

# write_sway_autostart HOME FLAG: start Sway after logging in on tty1.
write_sway_autostart() {
    local home=$1 flag=$2 syntax="" file="" target
    read -r syntax file <<<"$(login_file_for_user)"
    if [ -z "$file" ]; then
        warn "Sway is not started automatically for this login shell. Type 'sway' after logging in on the first console."
        return 0
    fi
    target="$home/$file"
    if grep -q "exec sway" "$target" 2>/dev/null; then return 0; fi
    mkdir -p -- "$(dirname "$target")"
    case "$syntax" in
        sh)
            printf '%s\n' "" "# Start Sway after logging in on the first console (tty1)." \
                "# Added by gentoo_install.sh. Delete these lines to turn it off." \
                "if [ -z \"\${WAYLAND_DISPLAY:-}\" ] && [ \"\$(tty)\" = \"/dev/tty1\" ]; then" \
                "    exec sway${flag}" "fi" >>"$target" ;;
        fish)
            printf '%s\n' "# Start Sway after logging in on the first console (tty1)." \
                "# Added by gentoo_install.sh. Delete this file to turn it off." \
                "if status is-login; and test -z \"\$WAYLAND_DISPLAY\"; and test (tty) = /dev/tty1" \
                "    exec sway${flag}" "end" >"$target" ;;
        csh)
            printf '%s\n' "" "# Start Sway after logging in on the first console (tty1)." \
                "# Added by gentoo_install.sh. Delete these lines to turn it off." \
                "if ( ! \$?WAYLAND_DISPLAY ) then" \
                "    if ( \"\`tty\`\" == \"/dev/tty1\" ) exec sway${flag}" "endif" >>"$target" ;;
    esac
    chown -R -- "${USERNAME}:${USERNAME}" "$home/${file%%/*}"
    ok "Sway starts after logging in on tty1 (set up in ~/${file})."
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
            printf '%s\n' "$p" >>"$FAILED_PATH"
        fi
    done
    return 0
}

# enable_service [--boot] NAME [ALTERNATIVE_NAME...]
enable_service() {
    local runlevel="default" s unit first
    if [ "${1:-}" = "--boot" ]; then
        runlevel="boot"
        shift
    fi
    first=${1:-}
    for s in "$@"; do
        if [ "$INIT" = "openrc" ]; then
            if [ -e "/etc/init.d/$s" ]; then
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
            if [ -e "/usr/lib/systemd/system/$unit" ] || [ -e "/etc/systemd/system/$unit" ] || [ -e "/lib/systemd/system/$unit" ]; then
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
    touch -- "$file"
    if grep -q "^${key}=" "$file"; then
        sed_inplace "s|^${key}=.*|${key}=\"${value}\"|" "$file"
    else
        printf '%s="%s"\n' "$key" "$value" >>"$file"
    fi
}

kernel_present() {
    if [ "$BOOTLOADER" = "grub" ]; then
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
    if [ -z "$ver" ]; then
        ver=$(eselect profile list | grep '(stable)' | grep -Eo 'default/linux/amd64/[0-9]+\.[0-9]+' | cut -d/ -f4 | LC_ALL=C sort -t. -k1,1n -k2,2n -u | tail -n1 || true)
    fi
    [ -n "$ver" ] || die "Could not determine the current profile version. Check 'eselect profile list'."
    target="default/linux/amd64/${ver}${PROFILE_SUFFIX}"
    info "Selecting profile: ${target}"
    # Capture the list first: piping eselect straight into 'grep -q' can make
    # eselect die of SIGPIPE, which pipefail reports as "not found".
    local list
    list=$(eselect profile list 2>/dev/null | strip_colors || true)
    if ! grep -Eq "[[:space:]]${target//./\\.}([[:space:]]|\$)" <<<"$list"; then
        if [ -d "/var/db/repos/gentoo/profiles/${target}" ]; then
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
    if [ "$USE_BINPKG" != "yes" ]; then
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
    if [ "$TUNE_CPU_FLAGS" != "yes" ]; then
        info "Keeping the profile's default CPU_FLAGS_X86 (as chosen); skipping detection."
        return 0
    fi
    step_header "Detect this CPU's instruction set flags" \
        "cpuid2cpuflags asks the CPU which instruction set extensions it supports. The result is saved as CPU_FLAGS_X86 so packages can use them."
    run emerge "${EMERGE_OPTS[@]}" --oneshot --noreplace app-portage/cpuid2cpuflags
    local flags
    flags=$(cpuid2cpuflags)
    mkdir -p /etc/portage/package.use
    printf '# Detected by cpuid2cpuflags (gentoo_install.sh)\n*/* %s\n' "$flags" >/etc/portage/package.use/00cpu-flags
    ok "$flags"
}

c_locale_time() {
    step_header "Timezone and language" \
        "Sets the timezone (${TIMEZONE}) and generates the locale (${LOCALE}) so that programs show the right time, language and number formats."
    if [ -f "/usr/share/zoneinfo/$TIMEZONE" ]; then
        run ln -sf -- "../usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
    else
        warn "Timezone '${TIMEZONE}' does not exist; using UTC. Change it later with: ln -sf ../usr/share/zoneinfo/Region/City /etc/localtime"
        run ln -sf ../usr/share/zoneinfo/UTC /etc/localtime
    fi
    local line
    line=$(grep -m1 "^${LOCALE} " /usr/share/i18n/SUPPORTED || true)
    if [ -z "$line" ]; then
        warn "Locale ${LOCALE} is not supported; using en_US.UTF-8."
        LOCALE="en_US.UTF-8"
        line="en_US.UTF-8 UTF-8"
    fi
    {
        printf '%s\n' "# Locales to generate. Written by gentoo_install.sh. Run locale-gen after editing."
        printf '%s\n' "$line"
        if [ "$LOCALE" != "en_US.UTF-8" ]; then printf '%s\n' "en_US.UTF-8 UTF-8"; fi
    } >/etc/locale.gen
    run locale-gen
    if ! run eselect locale set "${LOCALE/.UTF-8/.utf8}"; then
        warn "eselect could not set the locale; set it later with 'eselect locale list' and 'eselect locale set'."
    fi
    if [ "$INIT" = "systemd" ]; then
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
        "Installs the tools a working Gentoo system needs: Portage helpers (gentoolkit, eclean-kernel), hardware listing (lspci, lsusb), filesystem tools for your disks, and $( [ "$INIT" = openrc ] && printf '%s\n' "a system logger, cron and time synchronisation (sysklogd, cronie, chrony)" || printf '%s\n' "shell completion" ). They are installed before the kernel so the initramfs can include what it needs."
    local -a pkgs=(app-portage/gentoolkit app-admin/eclean-kernel sys-apps/pciutils sys-apps/usbutils
                   app-shells/bash-completion sys-apps/plocate app-arch/unzip)
    if [ "$BOOT_MODE" = "uefi" ]; then pkgs+=(sys-fs/dosfstools sys-boot/efibootmgr); fi
    case "$FS" in
        xfs) pkgs+=(sys-fs/xfsprogs) ;;
        btrfs) pkgs+=(sys-fs/btrfs-progs) ;;
    esac
    if [ "$ENCRYPT" = "yes" ]; then pkgs+=(sys-fs/cryptsetup); fi
    if [ "$INIT" = "openrc" ]; then pkgs+=(app-admin/sysklogd sys-process/cronie net-misc/chrony); fi
    if [ "$WANT_SSH" = "yes" ]; then pkgs+=(net-misc/openssh); fi
    if [ "$PRIV_TOOL" = "doas" ]; then pkgs+=(app-admin/doas); else pkgs+=(app-admin/sudo); fi
    emerge_pkgs "${pkgs[@]}"
}

c_firmware() {
    if [ "$VIRT" != "none" ]; then
        info "Virtual machine detected: device firmware and CPU microcode are not needed; skipping."
        return 0
    fi
    step_header "Install firmware and CPU microcode" \
        "Many devices (Wi-Fi, GPUs, Bluetooth, audio) need firmware files loaded by the kernel. linux-firmware provides them. CPU microcode updates fix CPU bugs and security issues; AMD microcode is part of linux-firmware, Intel's is a separate package."
    # sof-firmware: the Sound Open Firmware used by the audio of most laptops
    # from about 2019 on, with Intel and with AMD CPUs.
    local -a pkgs=(sys-kernel/linux-firmware sys-firmware/sof-firmware)
    if [ "$CPU_VENDOR" = "GenuineIntel" ]; then
        pkgs+=(sys-firmware/intel-microcode)
    fi
    emerge_pkgs "${pkgs[@]}"
    if [ "$BCM_WIFI" = "b43" ]; then
        info "Installing the firmware for this computer's Broadcom Wi-Fi card (b43 driver)."
        emerge_optional "the Broadcom b43 firmware" sys-firmware/b43-firmware
    fi
}

c_system_config() {
    step_header "Basic system configuration" \
        "Hostname, keyboard layout and machine ID."
    printf '%s\n' "$NEW_HOSTNAME" >/etc/hostname
    if [ "$INIT" = "openrc" ]; then
        set_conf_value /etc/conf.d/hostname hostname "$NEW_HOSTNAME"
        set_conf_value /etc/conf.d/keymaps keymap "$KEYMAP"
    else
        printf 'KEYMAP=%s\n' "$KEYMAP" >/etc/vconsole.conf
    fi
    if ! grep -qE "[[:space:]]${NEW_HOSTNAME}([[:space:]]|\$)" /etc/hosts; then
        printf '127.0.1.1\t%s\n' "$NEW_HOSTNAME" >>/etc/hosts
    fi
    if [ "$DE" != "none" ] && { [ "$XKB_LAYOUT" != "us" ] || [ -n "$XKB_VARIANT" ]; }; then
        mkdir -p /etc/X11/xorg.conf.d
        {
            printf '%s\n' "# Keyboard layout for X11 sessions. Written by gentoo_install.sh"
            printf '%s\n' 'Section "InputClass"'
            printf '%s\n' '    Identifier "system-keyboard"'
            printf '%s\n' '    MatchIsKeyboard "on"'
            printf '%s\n' "    Option \"XkbLayout\" \"${XKB_LAYOUT}\""
            if [ -n "$XKB_VARIANT" ]; then printf '%s\n' "    Option \"XkbVariant\" \"${XKB_VARIANT}\""; fi
            printf '%s\n' 'EndSection'
        } >/etc/X11/xorg.conf.d/00-keyboard.conf
    fi
    if [ ! -s /etc/machine-id ]; then
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
    if [ "$BOOTLOADER" = "grub" ]; then
        step_header "Install the GRUB bootloader" \
            "GRUB is installed first so that the kernel step can add itself to GRUB's menu automatically."
        local -a pkgs=(sys-boot/grub)
        if [ "$BOOT_MODE" = "uefi" ]; then pkgs+=(sys-boot/efibootmgr); fi
        if [ "$DUAL_BOOT" = "yes" ]; then pkgs+=(sys-boot/os-prober); fi
        emerge_pkgs "${pkgs[@]}"
        if [ "$BOOT_MODE" = "uefi" ]; then
            local nvram_ok="yes" target="x86_64-efi" fallback="BOOTX64.EFI" loader="grubx64.efi"
            if [ "$UEFI_BITS" = "32" ]; then
                # 32-bit UEFI with a 64-bit CPU: GRUB's i386-efi build starts the
                # 64-bit kernel (the distribution kernel supports EFI mixed mode).
                target="i386-efi"; fallback="BOOTIA32.EFI"; loader="grubia32.efi"
            fi
            if [ ! -d /sys/firmware/efi/efivars ]; then
                info "The live system was started in BIOS mode, so the firmware's boot menu cannot be changed from here. GRUB also goes to the fallback path EFI/BOOT/${fallback}, which the firmware finds by itself."
                run grub-install --target="$target" --efi-directory=/efi --bootloader-id=Gentoo --no-nvram
                nvram_ok="no"
            elif ! run grub-install --target="$target" --efi-directory=/efi --bootloader-id=Gentoo; then
                warn "Could not add a boot entry to the firmware's boot menu (NVRAM). Installing GRUB without it."
                run grub-install --target="$target" --efi-directory=/efi --bootloader-id=Gentoo --no-nvram
                nvram_ok="no"
            fi
            if [ "$PART_MODE" = "auto" ] || { [ "$nvram_ok" = "no" ] && [ ! -e "/efi/EFI/BOOT/$fallback" ]; }; then
                info "Also installing GRUB at the fallback path EFI/BOOT/${fallback}, which firmware finds even without a boot menu entry."
                run grub-install --target="$target" --efi-directory=/efi --removable
            elif [ "$nvram_ok" = "no" ]; then
                warn "The firmware boot menu may not list Gentoo. After rebooting, pick EFI/Gentoo/${loader} in the firmware boot menu, or add an entry with efibootmgr."
            fi
        else
            run grub-install --target=i386-pc "$GRUB_DISK"
        fi
        if ! grep -q "gentoo_install.sh" /etc/default/grub; then
            {
                printf '%s\n' ""
                printf '%s\n' "# ---- Added by gentoo_install.sh ----"
                printf '%s\n' "# Extra kernel parameters. root= is added automatically by grub-mkconfig."
                printf '%s\n' "GRUB_CMDLINE_LINUX=\"${GRUB_EXTRA_CMDLINE}\""
                if [ "$DUAL_BOOT" = "yes" ]; then
                    printf '%s\n' "# Look for other operating systems (Windows, other Linux) on every grub-mkconfig run."
                    printf '%s\n' "GRUB_DISABLE_OS_PROBER=false"
                fi
            } >>/etc/default/grub
        fi
    else
        step_header "Install the systemd-boot bootloader" \
            "systemd-boot is installed to the EFI system partition first, so the kernel step can add its boot entries automatically."
        if [ "$INIT" = "openrc" ]; then
            run emerge "${EMERGE_OPTS[@]}" --oneshot --update --newuse sys-apps/systemd-utils
        else
            run emerge "${EMERGE_OPTS[@]}" --oneshot --update --newuse sys-apps/systemd
        fi
        local -a bootctl_opts=()
        if [ ! -d /sys/firmware/efi/efivars ]; then
            info "The live system was started in BIOS mode, so the firmware's boot menu cannot be changed from here. systemd-boot is installed at the fallback path EFI/BOOT/BOOTX64.EFI, which the firmware finds by itself."
            bootctl_opts=(--no-variables)
        fi
        if ! run bootctl install "${bootctl_opts[@]}"; then
            warn "bootctl could not update the firmware boot menu; installing without it (the fallback path still works)."
            run bootctl install --graceful
        fi
        mkdir -p /efi/loader
        printf '%s\n' "# systemd-boot menu settings. Written by gentoo_install.sh" "timeout 3" >/efi/loader/loader.conf
    fi
}

c_kernel() {
    step_header "Install the Linux kernel" \
        "Installs sys-kernel/${KERNEL_PKG}. installkernel then builds the initramfs with dracut (a small early-boot system that loads the drivers needed to mount your root filesystem$( [ "$ENCRYPT" = yes ] && printf '%s\n' " and asks for your encryption passphrase" )) and registers the kernel with ${BOOTLOADER}."
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
            printf '%s\n' "# Wired Ethernet via DHCP. Written by gentoo_install.sh" \
                "[Match]" "Name=en* eth*" "" "[Network]" "DHCP=yes" >/etc/systemd/network/20-wired.network
            ok "Wrote /etc/systemd/network/20-wired.network"
            ;;
    esac
}

c_users() {
    step_header "User accounts" \
        "Sets the root password, creates '${USERNAME}' in the wheel group, and allows the wheel group to use ${PRIV_TOOL}."
    if [ -z "$ROOT_HASH" ] || [ -z "$USER_HASH" ]; then
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
    set_user_shell

    if [ "$PRIV_TOOL" = "sudo" ]; then
        mkdir -p /etc/sudoers.d
        printf '%s\n' "# Members of the wheel group may run any command as root. Written by gentoo_install.sh" \
            "%wheel ALL=(ALL:ALL) ALL" >/etc/sudoers.d/10-wheel
        chmod 440 /etc/sudoers.d/10-wheel
        if have visudo && ! visudo -cf /etc/sudoers.d/10-wheel >>"$LOG" 2>&1; then
            rm -f /etc/sudoers.d/10-wheel
            die "The generated sudoers file failed validation."
        fi
        ok "sudo enabled for the wheel group."
    else
        printf '%s\n' "# Members of the wheel group may run commands as root. Written by gentoo_install.sh" \
            "permit :wheel" >/etc/doas.conf
        chmod 600 /etc/doas.conf
        ok "doas enabled for the wheel group."
    fi

    # The hashes are no longer needed; remove them from the settings file.
    sed_inplace 's/^declare -g -- ROOT_HASH=.*/declare -g -- ROOT_HASH=""/; s/^declare -g -- USER_HASH=.*/declare -g -- USER_HASH=""/' "$CONF_PATH"
    ROOT_HASH=""
    USER_HASH=""
}

c_desktop() {
    if [ "$DE" = "none" ]; then
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
        sddm) pkgs+=(gui-apps/sddm) ;;
        gdm) pkgs+=(gnome-base/gdm) ;;
        lightdm) pkgs+=(x11-misc/lightdm x11-misc/lightdm-gtk-greeter) ;;
    esac
    if [ "$INIT" = "openrc" ] && [ "$DM" != "none" ]; then pkgs+=(gui-libs/display-manager-init); fi
    emerge_pkgs "${pkgs[@]}"

    if [ "$INIT" = "openrc" ] && [ "$DE" = "gnome" ]; then
        emerge_optional "openrc-settingsd (GNOME system settings on OpenRC)" app-admin/openrc-settingsd
    fi
    if [ "$INIT" = "openrc" ] && [ "$DM" != "none" ]; then
        set_conf_value /etc/conf.d/display-manager DISPLAYMANAGER "$DM"
        ok "Display manager for OpenRC set to ${DM} in /etc/conf.d/display-manager."
    fi
    if [ "$DM" = "lightdm" ]; then
        mkdir -p /etc/lightdm/lightdm.conf.d
        printf '%s\n' "# Written by gentoo_install.sh" "[Seat:*]" "greeter-session=lightdm-gtk-greeter" \
            >/etc/lightdm/lightdm.conf.d/50-gentoo-install.conf
    fi
    if [ "$DM" = "sddm" ] && getent passwd sddm >/dev/null; then
        usermod -aG video sddm || true
    fi
    info "Deleting the downloaded binary packages (already installed; they only take up space)."
    free_package_caches
}

setup_zram() {
    mkdir -p /usr/local/sbin
    cat >/usr/local/sbin/zram_swap <<'EOF'
#!/bin/sh
# Compressed swap in RAM (zram). Installed by gentoo_install.sh.
# Size: equal to RAM, capped at 8 GiB. Memory is only used for pages actually swapped.
set -u
case "${1:-}" in
    start)
        modprobe zram 2>/dev/null || true
        if [ ! -e /sys/block/zram0 ]; then
            printf '%s\n' "zram_swap: zram is not available" >&2
            exit 1
        fi
        if grep -q '^/dev/zram0 ' /proc/swaps; then exit 0; fi
        mem_kib=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
        cap_kib=$((8 * 1024 * 1024))
        size_kib=$mem_kib
        if [ "$size_kib" -gt "$cap_kib" ]; then size_kib=$cap_kib; fi
        printf '%s\n' 1 >/sys/block/zram0/reset 2>/dev/null || true
        printf '%s\n' zstd >/sys/block/zram0/comp_algorithm 2>/dev/null || true
        printf '%sK\n' "$size_kib" >/sys/block/zram0/disksize
        mkswap /dev/zram0 >/dev/null
        swapon -p 100 /dev/zram0
        ;;
    stop)
        swapoff /dev/zram0 2>/dev/null || true
        printf '%s\n' 1 >/sys/block/zram0/reset 2>/dev/null || true
        ;;
    *)
        printf '%s\n' "usage: zram_swap start|stop" >&2
        exit 2
        ;;
esac
EOF
    chmod 755 /usr/local/sbin/zram_swap
    if [ "$INIT" = "openrc" ]; then
        mkdir -p /etc/local.d
        printf '#!/bin/sh\n/usr/local/sbin/zram_swap start\n' >/etc/local.d/zram_swap.start
        printf '#!/bin/sh\n/usr/local/sbin/zram_swap stop\n' >/etc/local.d/zram_swap.stop
        chmod 755 /etc/local.d/zram_swap.start /etc/local.d/zram_swap.stop
    else
        cat >/etc/systemd/system/zram_swap.service <<'EOF'
[Unit]
Description=Compressed swap in RAM (zram)
DefaultDependencies=no
Before=swap.target shutdown.target
Conflicts=shutdown.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/zram_swap start
ExecStop=/usr/local/sbin/zram_swap stop

[Install]
WantedBy=swap.target
EOF
    fi
    ok "zram swap configured."
}

c_hardware() {
    step_header "Drivers and hardware support" \
        "Installs graphics, Bluetooth, printing and virtual machine support as selected, and sets up swap and SSD maintenance."
    if [ "$GPU_DRIVER" = "nvidia" ]; then
        info "Installing the proprietary NVIDIA driver. Its kernel module is built for the installed kernel and rebuilt automatically on kernel updates (USE=dist-kernel)."
        emerge_optional "the NVIDIA driver" x11-drivers/nvidia-drivers
    fi
    local -a pkgs=()
    if [ "$WANT_BT" = "yes" ]; then
        pkgs+=(net-wireless/bluez)
        case "$DE" in
            xfce|mate|lxqt|cinnamon|i3|sway) pkgs+=(net-wireless/blueman) ;;
        esac
    fi
    if [ "$WANT_CUPS" = "yes" ]; then pkgs+=(net-print/cups); fi
    if [ "$WANT_POWER" = "yes" ]; then
        if [ "$POWER_TOOL" = "ppd" ]; then pkgs+=(sys-power/power-profiles-daemon); else pkgs+=(sys-power/tlp); fi
        if [ "$CPU_VENDOR" = "GenuineIntel" ]; then pkgs+=(sys-power/thermald); fi
    fi
    if [ "$HYBRID_GPU" = "yes" ]; then
        case "$DE" in
            plasma|gnome) pkgs+=(sys-power/switcheroo-control) ;;
        esac
    fi
    case "$VIRT" in
        kvm)
            pkgs+=(app-emulation/qemu-guest-agent)
            if [ "$DE" != "none" ]; then pkgs+=(app-emulation/spice-vdagent); fi
            ;;
        vmware) pkgs+=(app-emulation/open-vm-tools) ;;
        virtualbox) pkgs+=(app-emulation/virtualbox-guest-additions) ;;
    esac
    emerge_optional "hardware support packages" "${pkgs[@]}"

    if [ "$WANT_MBPFAN" = "yes" ]; then
        info "Installing mbpfan (fan control for Intel Macs)."
        emerge_optional "mbpfan" app-laptop/mbpfan
        # mbpfan reads the Mac's sensors through these two modules. Both
        # usually load by themselves; listing them makes sure.
        mkdir -p /etc/modules-load.d
        printf '%s\n' "# Sensors for mbpfan. Written by gentoo_install.sh" "applesmc" "coretemp" \
            >/etc/modules-load.d/mbpfan.conf
    fi

    if [ "$WANT_BCM_WL" = "yes" ]; then
        info "Installing Broadcom's wl Wi-Fi driver. It is compiled against the installed kernel, so this needs the kernel's build files (the distribution kernel provides them)."
        emerge_optional "the Broadcom wl driver" net-wireless/broadcom-sta
        # The open drivers claim the same cards first and keep wl from working.
        mkdir -p /etc/modprobe.d
        printf '%s\n' "# Written by gentoo_install.sh: this computer's Broadcom Wi-Fi card needs the" \
            "# proprietary wl driver (net-wireless/broadcom-sta). These open drivers would" \
            "# claim the card first. Delete this file if you replace the card." \
            "blacklist b43" "blacklist b43legacy" "blacklist bcma" "blacklist ssb" \
            "blacklist brcmsmac" "blacklist brcmfmac" >/etc/modprobe.d/broadcom-wl-blacklist.conf
        ok "Blocked the open Broadcom drivers in /etc/modprobe.d/broadcom-wl-blacklist.conf."
    fi

    if [ "$SWAP_MODE" = "zram" ]; then setup_zram; fi

    if [ "$IS_SSD" = "yes" ] && [ "$INIT" = "openrc" ]; then
        mkdir -p /etc/cron.weekly
        printf '%s\n' "#!/bin/sh" "# Tell the SSD which blocks are free (TRIM). Written by gentoo_install.sh" \
            "fstrim --all --quiet" >/etc/cron.weekly/fstrim
        chmod 755 /etc/cron.weekly/fstrim
        ok "Weekly SSD TRIM scheduled (cron)."
    fi
}

c_software() {
    if [ -z "$EXTRA_PKGS" ] && [ "$WANT_FLATPAK" != "yes" ]; then
        info "No additional software selected; skipping."
        return 0
    fi
    step_header "Install your selected applications" \
        "Optional software. If a package fails to install, it is skipped and listed at the end; the rest of the system is not affected."
    if [ -n "$EXTRA_PKGS" ]; then
        local -a extra=()
        read -ra extra <<<"$EXTRA_PKGS"
        emerge_optional "the selected native packages" "${extra[@]}"
    fi
    if [ "$WANT_FLATPAK" != "yes" ]; then return 0; fi

    emerge_optional "Flatpak" sys-apps/flatpak
    if ! have flatpak; then
        warn "Flatpak could not be installed; skipping Flathub apps."
        return 0
    fi
    local -a apps=()
    read -ra apps <<<"$FLATPAK_APPS"
    mkdir -p /usr/local/sbin
    {
        printf '%s\n' "#!/bin/sh"
        printf '%s\n' "# Adds Flathub and installs the Flatpak apps chosen during installation."
        printf '%s\n' "# Written by gentoo_install.sh. Safe to run again."
        printf '%s\n' "set -e"
        printf '%s\n' "flatpak remote-add --if-not-exists flathub ${FLATHUB_URL}"
        if (( ${#apps[@]} > 0 )); then printf '%s\n' "flatpak install -y --noninteractive flathub ${apps[*]}"; fi
    } >/usr/local/sbin/install_my_flatpaks
    chmod 755 /usr/local/sbin/install_my_flatpaks

    if ! run flatpak remote-add --if-not-exists flathub "$FLATHUB_URL"; then
        warn "Could not add Flathub inside the installer. Run '${PRIV_TOOL} /usr/local/sbin/install_my_flatpaks' after the first boot."
        touch /root/.gentoo-install-flatpak-pending
        return 0
    fi
    if (( ${#apps[@]} > 0 )); then
        info "Installing Flatpak apps: ${apps[*]} (large downloads; the first app also pulls in its runtime)."
        if ! run flatpak install -y --noninteractive flathub "${apps[@]}"; then
            warn "Some Flatpak apps could not be installed inside the installer. Run '${PRIV_TOOL} /usr/local/sbin/install_my_flatpaks' after the first boot."
            touch /root/.gentoo-install-flatpak-pending
        fi
    fi
}

c_services() {
    step_header "Enable services" \
        "Services are programs that start at boot and run in the background (networking, login screen, logging and so on). This step turns on the ones this system needs."
    if [ "$INIT" = "systemd" ]; then
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

    if [ "$DE" != "none" ] && [ "$INIT" = "openrc" ]; then
        enable_service dbus
        enable_service --boot elogind
        if [ "$DE" = "gnome" ]; then enable_service openrc-settingsd; fi
    fi
    if [ "$DM" != "none" ]; then
        if [ "$INIT" = "openrc" ]; then enable_service display-manager; else enable_service "$DM"; fi
    fi
    if [ "$WANT_BT" = "yes" ]; then enable_service bluetooth; fi
    if [ "$WANT_CUPS" = "yes" ]; then
        if [ "$INIT" = "openrc" ]; then enable_service cupsd; else enable_service cups.socket cups; fi
    fi
    if [ "$WANT_SSH" = "yes" ]; then enable_service sshd; fi
    case "$VIRT" in
        kvm)
            enable_service qemu-guest-agent qemu-ga
            if [ "$DE" != "none" ]; then enable_service spice-vdagentd spice-vdagent; fi
            ;;
        vmware) enable_service vmtoolsd vmware-tools open-vm-tools ;;
        virtualbox) enable_service virtualbox-guest-additions vboxservice ;;
    esac
    if [ "$SWAP_MODE" = "zram" ]; then
        if [ "$INIT" = "openrc" ]; then enable_service local; else enable_service zram_swap; fi
    fi
    if [ "$IS_SSD" = "yes" ] && [ "$INIT" = "systemd" ]; then enable_service fstrim.timer; fi
    if [ "$WANT_POWER" = "yes" ]; then
        if [ "$POWER_TOOL" = "ppd" ]; then
            enable_service power-profiles-daemon
        else
            enable_service tlp
            if [ "$INIT" = "systemd" ] && [ -e /usr/lib/systemd/system/tlp.service ]; then
                # TLP handles the radio switches itself, as its documentation asks.
                run systemctl mask systemd-rfkill.service systemd-rfkill.socket || true
            fi
        fi
        if [ "$CPU_VENDOR" = "GenuineIntel" ]; then enable_service thermald; fi
    fi
    if [ "$HYBRID_GPU" = "yes" ]; then
        case "$DE" in
            plasma|gnome) enable_service switcheroo-control ;;
        esac
    fi
    if [ "$WANT_MBPFAN" = "yes" ]; then enable_service mbpfan; fi

    if [ "$INIT" = "systemd" ] && [ "$DE" != "none" ]; then
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
    if [ "$BOOTLOADER" = "grub" ]; then
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
        local entry
        for entry in /efi/loader/entries/*.conf; do
            if [ -e "$entry" ]; then printf '    %s\n' "${entry##*/}"; fi
        done
    fi
}

setup_user_desktop() {
    local home="/home/${USERNAME}" cfg flag=""
    case "$DE" in
        sway)
            cfg="$home/.config/sway/config"
            if [ ! -f "$cfg" ] && [ -f /etc/sway/config ]; then
                mkdir -p -- "$home/.config/sway"
                cp /etc/sway/config "$cfg"
                # shellcheck disable=SC2016  # $menu is a Sway variable, not a shell one
                sed_inplace 's/^set \$menu .*/set $menu wofi --show drun/' "$cfg"
                {
                    printf '%s\n' ""
                    printf '%s\n' "# ---- Added by gentoo_install.sh ----"
                    if [ "$XKB_LAYOUT" != "us" ] || [ -n "$XKB_VARIANT" ]; then
                        printf '%s\n' "input type:keyboard {"
                        printf '%s\n' "    xkb_layout ${XKB_LAYOUT}"
                        if [ -n "$XKB_VARIANT" ]; then printf '%s\n' "    xkb_variant ${XKB_VARIANT}"; fi
                        printf '%s\n' "}"
                    fi
                    printf '%s\n' "# Notifications"
                    printf '%s\n' "exec mako"
                    if [ "$INIT" = "openrc" ]; then
                        printf '%s\n' "# OpenRC has no per-user service manager, so start PipeWire (audio) here."
                        printf '%s\n' "exec gentoo-pipewire-launcher"
                    fi
                } >>"$cfg"
            fi
            if [ "$SWAY_AUTOSTART" = "yes" ]; then
                if [ "$GPU_DRIVER" = "nvidia" ]; then flag=" --unsupported-gpu"; fi
                write_sway_autostart "$home" "$flag"
            fi
            ;;
        i3)
            cfg="$home/.config/i3/config"
            if [ ! -f "$cfg" ] && [ -f /etc/i3/config ]; then
                mkdir -p -- "$home/.config/i3"
                cp /etc/i3/config "$cfg"
                if [ "$INIT" = "openrc" ]; then
                    {
                        printf '%s\n' ""
                        printf '%s\n' "# ---- Added by gentoo_install.sh ----"
                        printf '%s\n' "# OpenRC has no per-user service manager, so start PipeWire (audio) here."
                        printf '%s\n' "exec --no-startup-id gentoo-pipewire-launcher"
                    } >>"$cfg"
                fi
            fi
            ;;
    esac
    if [ -d "$home" ]; then chown -R -- "${USERNAME}:" "$home"; fi
}

write_notes() {
    local f="/root/${NOTES_NAME}" profile
    profile=$(eselect profile show 2>/dev/null | tail -n1 | sed 's/^[[:space:]]*//' || true)
    {
        cat <<EOF
Gentoo post-install notes
=========================
Written by gentoo_install.sh ${SCRIPT_VERSION} on $(date -u '+%Y-%m-%d').

Your system
-----------
  Desktop:           $(de_label "$DE")
  Init system:       ${INIT}
  Profile:           ${profile}
  Kernel:            sys-kernel/${KERNEL_PKG} (distribution kernel)
  Bootloader:        ${BOOTLOADER} (${BOOT_MODE^^})
  Root filesystem:   ${FS}$( [ "$ENCRYPT" = yes ] && printf '%s' " on LUKS2 encryption" )
  Compiler flags:    -march=native -O2 -pipe
  MAKEOPTS:          -j${MAKE_JOBS} -l${NPROC}
  Binary packages:   ${USE_BINPKG}
  Portage config:    /etc/portage/make.conf (every setting is explained in comments)
  Install logs:      /var/log/gentoo-install.log and /var/log/gentoo-install-live.log

The easy way: gentoo_helper
---------------------------
Open a terminal and run:  gentoo_helper
It gives you menus to update the system, find and install software (ready-made
or compiled), remove packages, clean up, read Gentoo news and review
configuration updates. It shows what it will do and asks before doing it, and
explains problems in plain words. Everything below is what it does for you.

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
        if [ "$NET_TOOL" = "networkmanager" ]; then
            printf '\nNetworking\n----------\nNetworkManager is enabled. Connect to Wi-Fi from the desktop network icon, or\nin a terminal with: nmtui\n'
        fi
        if [ "$WANT_FLATPAK" = "yes" ]; then
            printf '\nFlatpak\n-------\n  flatpak search <name>\n  flatpak install flathub <app-id>\n  flatpak update            # Flatpaks update separately from emerge\n'
            if [ -e /root/.gentoo-install-flatpak-pending ]; then
                printf '\nYour chosen Flatpak apps were not (all) installed during setup. After the first\nboot, connected to the internet, run:  %s /usr/local/sbin/install_my_flatpaks\n' "$PRIV_TOOL"
            fi
        fi
        local login_sh
        login_sh=$(getent passwd "$USERNAME" | cut -d: -f7)
        printf '\nLogin shell\n-----------\n%s uses %s. root uses bash.\nChange it with: chsh -s <path>   (list the allowed ones with: cat /etc/shells)\n' "$USERNAME" "$login_sh"
        case "${login_sh##*/}" in
            fish|nu) printf 'This shell does not read /etc/profile. If a program is missing from PATH or an\nenvironment setting is not applied, add it to the shell'"'"'s own configuration.\n' ;;
            zsh) printf 'A starter ~/.zshrc was written (history, completion, the Gentoo prompt).\n' ;;
        esac
        if [ "$DE" = "sway" ]; then
            printf '\nSway\n----\nSuper+Enter opens a terminal (foot), Super+d the app launcher (wofi),\nSuper+Shift+e exits. Your config: ~/.config/sway/config (man 5 sway).\n'
        fi
        if [ "$DE" = "i3" ]; then
            # shellcheck disable=SC2016  # $mod is an i3 variable, not a shell one
            printf '\ni3\n--\nAlt+Enter opens a terminal, Alt+d the launcher (dmenu), Alt+Shift+e exits.\nYour config: ~/.config/i3/config. Change "set $mod Mod1" to Mod4 for the Super key.\n'
        fi
        if [ "$DE" = "gnome" ] && [ "$INIT" = "openrc" ]; then
            printf '\nGNOME on OpenRC\n---------------\nGNOME is developed against systemd. If a Settings panel does not work, check the\nGentoo wiki page "GNOME" for the OpenRC notes.\n'
        fi
        if [ "$GPU_DRIVER" = "nvidia" ]; then
            printf '\nNVIDIA\n------\nThe proprietary driver is rebuilt automatically when the kernel updates.\nnvidia_drm.modeset=1 is set on the kernel command line (current drivers enable\nit by default; it matters for older branches and Wayland).\n'
            if [ "$NVIDIA_GEN" = "legacy580" ]; then
                printf 'This card is supported up to the 580 driver branch, so newer branches are\nblocked in /etc/portage/package.mask/gentoo-install and updates stay on 580.\n'
            else
                printf 'If the card stops working after a driver update, see the Gentoo wiki page\n"NVIDIA/nvidia-drivers".\n'
            fi
        fi
        if [ "$WANT_BCM_WL" = "yes" ]; then
            printf '\nBroadcom Wi-Fi\n--------------\nThe wl driver (net-wireless/broadcom-sta) is a testing version, allowed in\n/etc/portage/package.accept_keywords/gentoo-install. It is rebuilt when the\nkernel updates. If Wi-Fi stops working after a kernel update, the driver may\nnot support that kernel yet: pick the previous kernel in the boot menu.\nThe open drivers that would claim the card are blocked in\n/etc/modprobe.d/broadcom-wl-blacklist.conf.\n'
        fi
        if [ "$WANT_MBPFAN" = "yes" ]; then
            printf '\nMac fan control\n---------------\nmbpfan runs as a service and sets the fan speed from the CPU temperature.\nIts settings (temperatures, fan speeds) are in /etc/mbpfan.conf.\n'
        fi
        if [ "$WANT_POWER" = "yes" ]; then
            if [ "$POWER_TOOL" = "ppd" ]; then
                printf '\nPower management\n----------------\nSwitch between power saving, balanced and performance in the battery menu,\nor with: powerprofilesctl set power-saver|balanced|performance\n'
            else
                printf '\nPower management\n----------------\nTLP applies power saving settings at boot and when switching between battery\nand mains. Settings: /etc/tlp.conf. Status: tlp-stat -s\n'
            fi
        fi
        if [ "$DUAL_BOOT" = "yes" ]; then
            printf '\nDual boot\n---------\n'
            if [ "$BOOTLOADER" = "grub" ]; then
                printf 'GRUB runs os-prober to add other systems to its menu. If one is missing,\nrun: grub-mkconfig -o /boot/grub/grub.cfg\n'
            else
                printf 'systemd-boot lists Windows automatically if its boot loader is on the same\nEFI system partition. Other systems need a loader entry; see man loader.conf.\n'
            fi
            printf 'Windows keeps the hardware clock in local time, Linux in UTC. If the clock is\nwrong after switching systems, set Windows to use UTC (search "RealTimeIsUniversal").\n'
        fi
        printf '\nMoving this disk to another computer\n------------------------------------\nThe system is built for this CPU (-march=native) with a host-only initramfs.\nBefore moving the disk, change -march=native to a generic value such as\n-march=x86-64-v2 in make.conf, rebuild (emerge -e @world), set hostonly="no" in\n/etc/dracut.conf.d/10-gentoo-install.conf and run: emerge --config sys-kernel/%s\n' "$KERNEL_PKG"
        if [ -s "$FAILED_PATH" ]; then
            printf '\nOptional packages that failed to install\n----------------------------------------\n'
            sed 's/^/  /' "$FAILED_PATH"
            printf 'Try again with: emerge --ask <package> and read the error message.\n'
        fi
    } >"$f"
    if id "$USERNAME" >/dev/null 2>&1 && [ -d "/home/$USERNAME" ]; then
        cp -- "$f" "/home/${USERNAME}/${NOTES_NAME}"
        chown -- "${USERNAME}:" "/home/${USERNAME}/${NOTES_NAME}"
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
    if declare -F install_gentoo_helper >/dev/null; then
        install_gentoo_helper
        ok "Installed gentoo_helper (/usr/local/bin/gentoo_helper): simple menus for installing software and updating the system."
    fi
    write_notes
    local news
    news=$(eselect news count new 2>/dev/null || printf '%s\n' 0)
    if [[ $news =~ ^[0-9]+$ ]] && (( news > 0 )); then
        info "There are ${news} unread Gentoo news items. Read them after booting with: eselect news read"
    fi
}

# Rough minimum free space (GiB) needed before a step starts.
step_min_free_gib() {
    case "$1" in
        c_world) printf '%s\n' 4 ;;
        c_desktop)
            case "$DE" in
                plasma|gnome|cinnamon) printf '%s\n' 8 ;;
                none) printf '%s\n' 1 ;;
                *) printf '%s\n' 4 ;;
            esac ;;
        c_software) printf '%s\n' 3 ;;
        c_kernel|c_firmware|c_bootloader_prep|c_base_tools|c_hardware) printf '%s\n' 2 ;;
        *) printf '%s\n' 1 ;;
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
    du -xsk /usr /var /opt /home /root 2>/dev/null | LC_ALL=C sort -rn \
        | awk '{printf "    %6d MiB  %s\n", $1 / 1024, $2}' || true
    die "Not enough disk space: $(( avail_kib / 1024 )) MiB free, roughly ${need_gib} GiB needed for the next step. The disk (or root partition) is too small for this installation; ${MIN_DESKTOP_DISK_GIB} GiB or more is needed for a desktop. Enlarge it, or start over on a larger disk."
}

chroot_stage() {
    IN_CHROOT="yes"
    LOG="$TARGET_LOG"
    mkdir -p -- "$(dirname "$LOG")"
    touch -- "$LOG"
    [ -f "$CONF_PATH" ] || die "The settings file ${CONF_PATH} is missing."
    safe_source /etc/profile
    init_defaults
    load_config "$CONF_PATH"
    touch -- "$PROGRESS_PATH"
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
        printf '%s\n' "$s" >>"$PROGRESS_PATH"
        ok "Step ${CURRENT_STEP} finished."
    done
}

# ----------------------------------------------------------------------------
# gentoo_helper, embedded by build.sh from gentoo_helper.sh (do not edit here)
# ----------------------------------------------------------------------------
install_gentoo_helper() {
    mkdir -p /usr/local/bin
    cat >/usr/local/bin/gentoo_helper <<'GENTOO_HELPER_SCRIPT_EOF'
#!/usr/bin/env bash
# =============================================================================
#  gentoo_helper - simple menus for everyday Gentoo package management
# =============================================================================
#
#  Install, remove and find software, update the whole system and keep it
#  tidy, without having to remember emerge options. Every action first shows
#  what is going to happen in plain words and asks before changing anything.
#
#  Install it:
#    curl -fsSLO https://raw.githubusercontent.com/NullAngst/Gentoo-Installer/refs/heads/main/gentoo_helper.sh
#    sudo install -m 755 gentoo_helper.sh /usr/local/bin/gentoo_helper
#
#  Use it:
#    gentoo_helper                  menus
#    gentoo_helper update           update the whole system
#    gentoo_helper install NAME     find and install a package
#    gentoo_helper remove NAME      remove a package
#    gentoo_helper clean            remove unneeded packages, free disk space
#    gentoo_helper news             read Gentoo news
#    gentoo_helper configs          review configuration file updates
#    gentoo_helper flatpak          Flatpak apps
#    gentoo_helper tasks            common tasks: printing, Wi-Fi, drivers, SSH, ...
#    gentoo_helper -h               this text
#    gentoo_helper -V               version
#
#  Needs bash 4.4 or newer. Log: /var/log/gentoo-helper.log
# =============================================================================

set -euo pipefail

readonly VERSION="1.4.0"
readonly LOG="/var/log/gentoo-helper.log"
readonly STATE_DIR="/var/lib/gentoo-helper"
readonly LAST_FAILURE="/var/log/gentoo-helper-last-failure.txt"
readonly REPO_DIR="/var/db/repos/gentoo"
readonly WORLD_FILE="/var/lib/portage/world"
readonly USE_FILE="/etc/portage/package.use/zz-gentoo-helper"
readonly LICENSE_FILE="/etc/portage/package.license/zz-gentoo-helper"
readonly KEYWORDS_FILE="/etc/portage/package.accept_keywords/zz-gentoo-helper"
readonly MASK_FILE="/etc/portage/package.mask/zz-gentoo-helper"
readonly FLATHUB_URL="https://dl.flathub.org/repo/flathub.flatpakrepo"

# Real runs: compiler output goes to each package's build log instead of the
# screen (the relevant part is shown if a build fails). Plans are calculated
# without colours so they can be read by this script.
RUN_OPTS=(--color=y --quiet-build=y)
PLAN_OPTS=(--pretend --verbose --color=n --nospinner --autounmask=y --autounmask-keep-masks=y)

UI="text"
TITLE="Gentoo Helper"
OUT=""
CHOICE=""
PLAN_OUT=""
PLAN_RC=0
RUN_TMP=""
UI_MAXH=20
UI_W=74
UI_BACK_LABEL="Back"
WORK_DIR=""
SR_NAME=(); SR_INST=(); SR_LATEST=(); SR_DESC=()

if [ -t 1 ]; then
    C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_GREEN=$'\e[1;32m'; C_YELLOW=$'\e[1;33m'; C_BLUE=$'\e[1;34m'
else
    C_RESET=""; C_BOLD=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
fi

# ----------------------------------------------------------------------------
# Small helpers
# ----------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

log() {
    printf '[%(%Y-%m-%d %H:%M:%S)T] %s\n' -1 "$*" >>"$LOG" 2>/dev/null || true
}

trim() {
    local s=$1
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

term_width() {
    local w
    w=$(tput cols 2>/dev/null || printf '%s\n' 80)
    [[ $w =~ ^[0-9]+$ ]] || w=80
    printf '%s\n' $(( w > 100 ? 100 : (w < 50 ? 50 : w) ))
}

clear_screen() {
    clear 2>/dev/null || printf '\033[H\033[2J'
}

# say "paragraph" ...: wrapped text for the plain text menus
say() {
    local p w
    w=$(( $(term_width) - 4 ))
    for p in "$@"; do
        printf '%s\n' "$p" | fold -s -w "$w" | sed 's/^/  /'
    done
}

pause_text() {
    local _x
    read -r -p "  Press Enter to continue... " _x || true
}

tmpfile() {
    mktemp "${WORK_DIR}/tmp.XXXXXX"
}

# self_path: the absolute path of this script, without GNU readlink -f.
self_path() {
    local dir base
    dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || return 1
    base=$(basename -- "${BASH_SOURCE[0]}")
    printf '%s/%s\n' "$dir" "$base"
}

# file_mtime FILE: modification time in seconds since 1970. stat's options
# differ between GNU, BSD and BusyBox, so this asks Python, which Portage
# always has.
file_mtime() {
    python3 -c 'import os, sys; print(int(os.stat(sys.argv[1]).st_mtime))' "$1" 2>/dev/null
}

# sed_inplace SCRIPT FILE: edit FILE with sed, portably (no GNU sed -i).
sed_inplace() {
    local script=$1 file=$2 tmp
    tmp=$(mktemp "${file}.XXXXXX")
    if sed "$script" "$file" >"$tmp"; then
        cat -- "$tmp" >"$file"
        rm -f -- "$tmp"
    else
        rm -f -- "$tmp"
        return 1
    fi
}

# strip_colors: remove terminal colour codes from standard input
# (portable: no \x escapes in the sed script).
strip_colors() {
    local esc
    esc=$(printf '\033')
    sed "s/${esc}\[[0-9;]*m//g"
}

# clear_dir DIR: delete everything inside DIR, keeping DIR itself.
clear_dir() {
    if [ -d "$1" ]; then
        find "$1" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null || true
    fi
}

cleanup() {
    if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then rm -rf -- "$WORK_DIR"; fi
}

# ----------------------------------------------------------------------------
# Menus: dialog when available, plain text otherwise
# ----------------------------------------------------------------------------
ui_dims() {
    local h w
    h=$(tput lines 2>/dev/null || printf '%s\n' 24)
    w=$(tput cols 2>/dev/null || printf '%s\n' 80)
    [[ $h =~ ^[0-9]+$ ]] || h=24
    [[ $w =~ ^[0-9]+$ ]] || w=80
    UI_MAXH=$(( h - 4 ))
    UI_MAXH=$(( UI_MAXH < 12 ? 12 : UI_MAXH ))
    UI_W=$(( w - 6 ))
    UI_W=$(( UI_W > 100 ? 100 : UI_W ))
    UI_W=$(( UI_W < 50 ? 50 : UI_W ))
}

text_lines() {
    printf '%s\n' "$1" | fold -s -w "$2" | wc -l
}

# dlg WIDGET-ARGS...: run dialog, answer in OUT. Returns 0 (OK), 1 (Cancel/No),
# 255 (Esc), or 99 when dialog itself failed (callers then use text menus).
dlg() {
    local rc=0
    OUT=$(dialog --cr-wrap --no-collapse \
        --backtitle "Gentoo Helper ${VERSION}   |   Arrows: move   Space: tick   Enter: choose   Esc: back" \
        --title " ${TITLE} " "$@" 3>&1 1>&2 2>&3) || rc=$?
    if (( rc != 0 )) && { [ -n "$OUT" ] || (( rc != 1 && rc != 255 )); }; then
        log "dialog failed (rc=${rc}): ${OUT}"
        UI="text"
        clear_screen
        printf '%s\n' "The menu program failed (${OUT:-exit code ${rc}}). Switching to plain text menus."
        return 99
    fi
    return "$rc"
}

text_header() {
    local line
    printf -v line '%*s' "$(term_width)" ''
    printf '\n%s%s%s\n' "$C_BLUE" "${line// /=}" "$C_RESET"
    printf '%s  %s%s\n' "$C_BOLD" "$TITLE" "$C_RESET"
    printf '%s%s%s\n' "$C_BLUE" "${line// /=}" "$C_RESET"
}

# ui_menu "text" DEFAULT_TAG tag "label" ...  ->  CHOICE. Returns 1 for Back/Esc.
ui_menu() {
    local text=$1 def=$2
    shift 2
    local -a items=("$@")
    local n=$(( ${#items[@]} / 2 )) rc i
    if [ "$UI" = "dialog" ]; then
        local maxl=20 lines lh h w
        ui_dims
        for (( i = 1; i < ${#items[@]}; i += 2 )); do
            if (( ${#items[i]} > maxl )); then maxl=${#items[i]}; fi
        done
        w=$(( maxl + 10 ))
        w=$(( w < 60 ? 60 : (w > UI_W ? UI_W : w) ))
        lines=$(text_lines "$text" $(( w - 4 )))
        lh=$(( UI_MAXH - lines - 7 ))
        lh=$(( lh > n ? n : lh ))
        lh=$(( lh < 3 ? 3 : lh ))
        h=$(( lines + lh + 7 ))
        h=$(( h > UI_MAXH ? UI_MAXH : h ))
        rc=0
        dlg --no-tags --cancel-label "$UI_BACK_LABEL" --default-item "$def" \
            --menu "$text" "$h" "$w" "$lh" "${items[@]}" || rc=$?
        if (( rc == 99 )); then ui_menu "$text" "$def" "${items[@]}" && return 0; return 1; fi
        if (( rc == 0 )); then CHOICE=$OUT; return 0; fi
        return 1
    fi
    local num=0 defnum=1 a
    local -a tags=()
    text_header
    say "$text"
    printf '\n'
    for (( i = 0; i < ${#items[@]}; i += 2 )); do
        num=$(( num + 1 ))
        tags+=("${items[i]}")
        if [ "${items[i]}" = "$def" ]; then defnum=$num; fi
        printf '  %2d) %s\n' "$num" "${items[i+1]}"
    done
    printf '   0) %s\n' "$UI_BACK_LABEL"
    while true; do
        if ! read -r -p "  Choose a number [${defnum}]: " a; then printf '\n'; return 1; fi
        a=$(trim "${a:-$defnum}")
        if [ "$a" = "0" ]; then return 1; fi
        if [[ $a =~ ^[0-9]+$ ]] && (( a >= 1 && a <= num )); then
            CHOICE=${tags[a-1]}
            return 0
        fi
        printf '%s\n' "  Please enter a number from the list."
    done
}

# ui_yesno "text" [y|n]  ->  returns 0 for yes
ui_yesno() {
    local text=$1 def=${2:-y} rc a hint="Y/n"
    if [ "$UI" = "dialog" ]; then
        local lines h
        local -a extra=()
        ui_dims
        if [ "$def" = "n" ]; then extra=(--defaultno); fi
        lines=$(text_lines "$text" $(( UI_W - 4 )))
        h=$(( lines + 6 ))
        h=$(( h > UI_MAXH ? UI_MAXH : h ))
        rc=0
        dlg "${extra[@]}" --yesno "$text" "$h" "$UI_W" || rc=$?
        if (( rc == 99 )); then ui_yesno "$text" "$def" && return 0; return 1; fi
        return $(( rc == 0 ? 0 : 1 ))
    fi
    if [ "$def" = "n" ]; then hint="y/N"; fi
    printf '\n'
    say "$text"
    while true; do
        if ! read -r -p "  [${hint}]: " a; then printf '\n'; return 1; fi
        a=$(trim "${a:-$def}")
        case "${a,,}" in
            y|yes) return 0 ;;
            n|no) return 1 ;;
        esac
        printf '%s\n' "  Please answer y or n."
    done
}

# ui_checklist "text" tag "label" on|off ...  ->  CHOICE = the ticked tags,
# separated by spaces. Returns 1 when the user goes back.
ui_checklist() {
    local text=$1 rc i a t
    shift
    local -a items=("$@")
    local n=$(( ${#items[@]} / 3 ))
    if [ "$UI" = "dialog" ]; then
        local maxl=20 lines lh h w
        ui_dims
        for (( i = 1; i < ${#items[@]}; i += 3 )); do
            if (( ${#items[i]} > maxl )); then maxl=${#items[i]}; fi
        done
        w=$(( maxl + 14 ))
        w=$(( w < 60 ? 60 : (w > UI_W ? UI_W : w) ))
        text+=$'\n\n'"Space ticks or unticks, Enter confirms."
        lines=$(text_lines "$text" $(( w - 4 )))
        lh=$(( UI_MAXH - lines - 7 ))
        lh=$(( lh > n ? n : lh ))
        lh=$(( lh < 3 ? 3 : lh ))
        h=$(( lines + lh + 7 ))
        h=$(( h > UI_MAXH ? UI_MAXH : h ))
        rc=0
        dlg --separate-output --no-tags --cancel-label "Back" --checklist "$text" "$h" "$w" "$lh" "${items[@]}" || rc=$?
        if (( rc == 99 )); then ui_checklist "$1" "${items[@]}" && return 0; return 1; fi
        if (( rc != 0 )); then return 1; fi
        CHOICE=$(trim "$(tr '\n' ' ' <<<"$OUT")")
        return 0
    fi
    local -a state=() tags=()
    for (( i = 0; i < ${#items[@]}; i += 3 )); do
        tags+=("${items[i]}")
        state+=("${items[i+2]}")
    done
    while true; do
        text_header
        say "$text"
        printf '\n'
        for (( i = 0; i < n; i++ )); do
            if [ "${state[i]}" = "on" ]; then t="x"; else t=" "; fi
            printf '  %2d) [%s] %s\n' $(( i + 1 )) "$t" "${items[i*3+1]}"
        done
        printf '\n'
        if ! read -r -p "  Numbers to tick/untick (e.g. 2 4), Enter to continue, 0 to go back: " a; then printf '\n'; return 1; fi
        a=$(trim "$a")
        if [ -z "$a" ]; then break; fi
        if [ "$a" = "0" ]; then return 1; fi
        local -a picks=()
        read -ra picks <<<"$a"
        for t in "${picks[@]}"; do
            if [[ $t =~ ^[0-9]+$ ]] && (( t >= 1 && t <= n )); then
                if [ "${state[t-1]}" = "on" ]; then state[t-1]="off"; else state[t-1]="on"; fi
            fi
        done
    done
    CHOICE=""
    for (( i = 0; i < n; i++ )); do
        if [ "${state[i]}" = "on" ]; then CHOICE+="${CHOICE:+ }${tags[i]}"; fi
    done
    return 0
}

# ui_input "text" "default"  ->  CHOICE. Returns 1 when cancelled or left empty.
ui_input() {
    local text=$1 def=${2:-} rc a
    if [ "$UI" = "dialog" ]; then
        local lines h
        ui_dims
        lines=$(text_lines "$text" $(( UI_W - 4 )))
        h=$(( lines + 8 ))
        h=$(( h > UI_MAXH ? UI_MAXH : h ))
        rc=0
        dlg --inputbox "$text" "$h" "$UI_W" "$def" || rc=$?
        if (( rc == 99 )); then ui_input "$text" "$def" && return 0; return 1; fi
        if (( rc != 0 )); then return 1; fi
        CHOICE=$(trim "$OUT")
    else
        printf '\n'
        say "$text" "(Leave empty to go back.)"
        if ! read -r -p "  > " a; then printf '\n'; return 1; fi
        CHOICE=$(trim "${a:-$def}")
    fi
    [ -n "$CHOICE" ]
}

# ui_file FILE: show a (long) text file, scrollable
ui_file() {
    local f=$1 rc
    if [ "$UI" = "dialog" ]; then
        ui_dims
        local wrapped
        wrapped=$(tmpfile)
        fold -s -w $(( UI_W - 4 )) "$f" >"$wrapped"
        rc=0
        dlg --exit-label "OK" --textbox "$wrapped" "$UI_MAXH" "$UI_W" || rc=$?
        if (( rc == 99 )); then ui_file "$f"; fi
        return 0
    fi
    printf '\n'
    if have less && [ "$(wc -l <"$f")" -gt 20 ]; then
        less -R "$f" || true
    else
        sed 's/^/  /' "$f"
        pause_text
    fi
}

# ui_msg "text": a message box (scrollable when long)
ui_msg() {
    local text=$1 rc
    if [ "$UI" = "dialog" ]; then
        local lines
        ui_dims
        lines=$(text_lines "$text" $(( UI_W - 4 )))
        if (( lines + 6 > UI_MAXH )); then
            local f
            f=$(tmpfile)
            printf '%s\n' "$text" >"$f"
            ui_file "$f"
            return 0
        fi
        rc=0
        dlg --msgbox "$text" $(( lines + 6 )) "$UI_W" || rc=$?
        if (( rc == 99 )); then ui_msg "$text"; fi
        return 0
    fi
    printf '\n'
    say "$text"
    pause_text
}

# busy "text": a short "please wait" note while something runs
busy() {
    if [ "$UI" = "dialog" ]; then
        ui_dims
        dialog --backtitle "Gentoo Helper ${VERSION}" --title " ${TITLE} " \
            --infobox "$1" $(( $(text_lines "$1" $(( UI_W - 4 ))) + 4 )) "$UI_W" 2>/dev/null || true
    else
        printf '\n'
        say "$1"
    fi
}

# ----------------------------------------------------------------------------
# Running commands
# ----------------------------------------------------------------------------

# run_visible CMD...: run on the normal screen (output also goes to the log)
run_visible() {
    clear_screen
    printf '%s==>%s %s\n\n' "$C_GREEN" "$C_RESET" "$*"
    log "RUN: $*"
    local rc=0
    "$@" 2>&1 | tee -a "$LOG" || rc=${PIPESTATUS[0]}
    log "EXIT ${rc}: $*"
    printf '\n'
    return "$rc"
}

# run_emerge ARGS...: a real emerge run; explains the failure if it fails
run_emerge() {
    local rc
    RUN_TMP=$(tmpfile)
    clear_screen
    printf '%s==>%s emerge %s\n' "$C_GREEN" "$C_RESET" "$*"
    printf '    Compiler output goes to each package'"'"'s build log; progress is shown here.\n\n'
    log "RUN: emerge ${RUN_OPTS[*]} $*"
    rc=0
    emerge "${RUN_OPTS[@]}" "$@" 2>&1 | tee -a "$LOG" "$RUN_TMP" || rc=${PIPESTATUS[0]}
    log "EXIT ${rc}: emerge $*"
    printf '\n'
    if (( rc == 0 )); then
        printf '%sDone.%s\n' "$C_GREEN" "$C_RESET"
        pause_text
    else
        printf '%semerge stopped with an error (exit code %s).%s\n' "$C_YELLOW" "$rc" "$C_RESET"
        pause_text
        failure_help
    fi
    return "$rc"
}

# Explain a failed emerge run, using its output in RUN_TMP.
failure_help() {
    local blog errors first from
    blog=$(grep -o "The complete build log is located at '[^']*'" "$RUN_TMP" 2>/dev/null | tail -n1 || true)
    blog=${blog#*located at \'}
    blog=${blog%\'}
    {
        printf '%s\n' "WHAT WENT WRONG"
        printf '%s\n' "==============="
        printf '\n'
        if grep -q "No space left on device" "$RUN_TMP" "${blog:-/dev/null}" 2>/dev/null; then
            printf '%s\n' "* The disk is full. Use 'Maintenance > Free disk space', then try again."
            printf '\n'
        fi
        if grep -qE "Couldn't download|Fetch failed|Unable to download|Could not resolve host" "$RUN_TMP" 2>/dev/null; then
            printf '%s\n' "* A download failed. Check the internet connection and try again; mirrors"
            printf '%s\n' "  are sometimes briefly unavailable."
            printf '\n'
        fi
        if [ -n "$blog" ] && [ -r "$blog" ]; then
            if grep -q "Can't locate .*\.pm in @INC" "$blog" 2>/dev/null; then
                printf '%s\n' "* A Perl module could not be loaded, which usually happens after a Perl"
                printf '%s\n' "  upgrade. Use 'Maintenance > Rebuild Perl modules', then try again."
                printf '\n'
            fi
            errors=$(grep -nE "\*\*\* \[|error:|Error [0-9]+|Can't locate|No such file or directory|Illegal instruction|Segmentation fault|Killed|undefined reference|command not found" "$blog" 2>/dev/null \
                | grep -vE "^[0-9]+:(checking|configure:)|-Werror|-Wno-error" || true)
            first=${errors%%:*}
            printf '%s\n' "The package's build log: ${blog}"
            if [[ $first =~ ^[0-9]+$ ]]; then
                from=$(( first > 12 ? first - 12 : 1 ))
                printf '\n'
                printf '%s\n' "Where it first went wrong (the cause is usually just above the first"
                printf '%s\n' "line with '***' or 'error'):"
                printf '\n'
                sed -n "${from},$(( first + 3 ))p" "$blog"
            fi
            printf '\n'
            printf '%s\n' "Last lines of the build log:"
            printf '\n'
            tail -n 25 "$blog"
        else
            printf '%s\n' "Last lines of emerge's output:"
            printf '\n'
            tail -n 40 "$RUN_TMP"
        fi
        printf '\n'
        printf '%s\n' "This report is saved as ${LAST_FAILURE}. If you ask for help (for example"
        printf '%s\n' "on forums.gentoo.org), include it together with the output of: emerge --info"
    } >"$LAST_FAILURE"
    TITLE="What went wrong"
    ui_file "$LAST_FAILURE"
}

# ----------------------------------------------------------------------------
# Plans: what emerge is going to do, in plain words
# ----------------------------------------------------------------------------

# make_plan ARGS...: calculate (without changing anything) into PLAN_OUT/PLAN_RC
make_plan() {
    busy "Working out what needs to be done. This can take a minute..."
    PLAN_RC=0
    PLAN_OUT=$(emerge "${PLAN_OPTS[@]}" "$@" 2>&1) || PLAN_RC=$?
    log "PLAN rc=${PLAN_RC}: emerge $*"
    printf '%s\n' "$PLAN_OUT" >>"$LOG" 2>/dev/null || true
}

# One line per package in the plan: how it is installed, what changes.
plan_list() {
    awk '
        /^\[(binary|ebuild)/ {
            how = ($0 ~ /^\[binary/) ? "ready-made" : "compile"
            close_at = index($0, "]")
            flags = substr($0, 8, close_at - 8)
            rest = substr($0, close_at + 2)
            n = split(rest, f, " ")
            pkg = f[1]; sub(/::.*/, "", pkg); sub(/:.*/, "", pkg)
            what = ""
            if (flags ~ /N/) what = "new"
            else if (flags ~ /U/) what = "update"
            else if (flags ~ /D/) what = "downgrade"
            else if (flags ~ /R/) what = "rebuild"
            old = ""
            if (n >= 2 && f[2] ~ /^\[/) { old = f[2]; gsub(/[\[\]]/, "", old); sub(/::.*/, "", old); sub(/:.*/, "", old) }
            note = (flags ~ /F/) ? "  (needs a manual download)" : ""
            printf "  %-10s  %-9s  %s%s%s\n", how, what, pkg, (old != "" ? "  (was " old ")" : ""), note
        }' <<<"$PLAN_OUT"
}

count_lines() {
    local c
    c=$(grep -c "$1" <<<"$PLAN_OUT" || true)
    printf '%s\n' "${c:-0}"
}

# confirm_plan "what this is": show the plan and ask. Returns 1 when the user
# says no, 3 when there is nothing to do.
confirm_plan() {
    local what=$1 list nbin nsrc total text f
    list=$(plan_list)
    if [ -z "$list" ]; then return 3; fi
    nbin=$(count_lines '^\[binary')
    nsrc=$(count_lines '^\[ebuild')
    total=$(grep -m1 '^Total:' <<<"$PLAN_OUT" || true)
    text="${what}"$'\n\n'"Packages: $(( nbin + nsrc ))"$'\n'
    text+="  ready-made (downloaded, installs quickly): ${nbin}"$'\n'
    text+="  compiled on this computer:                 ${nsrc}"$'\n'
    if [ -n "$total" ]; then text+=$'\n'"Portage's summary: ${total}"$'\n'; fi
    if (( nsrc > 0 )); then
        text+=$'\n'"Compiling takes from under a minute for small packages to hours for big ones (web browsers, office suites, compilers). You can keep using the computer meanwhile."$'\n'
    fi
    if grep -q "binary packages have been ignored due to non matching USE" <<<"$PLAN_OUT"; then
        text+=$'\n'"Some ready-made packages exist but were built with different options (USE flags) than yours, so those are compiled instead. That is normal."$'\n'
    fi
    if grep -q '^\[ebuild[^]]*F' <<<"$PLAN_OUT"; then
        text+=$'\n'"At least one package needs a file you must download yourself (licence restrictions); emerge will say where to get it."$'\n'
    fi
    f=$(tmpfile)
    {
        printf '%s\n' "How      What       Package"
        printf '%s\n' "$list"
    } >"$f"
    while true; do
        if ! ui_menu "$text" "go" go "Start" list "Show the list of packages" cancel "Cancel"; then return 1; fi
        case "$CHOICE" in
            go) return 0 ;;
            list) ui_file "$f" ;;
            *) return 1 ;;
        esac
    done
}

# extract_changes USE|license|keyword|mask: the settings Portage says it needs
extract_changes() {
    awk -v key="The following $1 changes are necessary to proceed:" '
        index($0, key) == 1 { grab = 1; next }
        grab && /^[[:space:]]*$/ { grab = 0; next }
        grab && $0 !~ /^[[:space:]]*(#|\()/ { sub(/^[[:space:]]+/, ""); print }
    ' <<<"$PLAN_OUT"
}

# add_settings FILE "lines" "reason": save settings in the helper's own files
add_settings() {
    local file=$1 lines=$2 reason=$3 dir line existing="" new=""
    dir=${file%/*}
    if [ -f "$dir" ]; then file=$dir; fi
    if [ ! -e "$dir" ]; then mkdir -p -- "$dir"; fi
    if [ -f "$file" ]; then existing=$(<"$file"); fi
    while IFS= read -r line; do
        line=$(trim "$line")
        if [ -z "$line" ]; then continue; fi
        if ! grep -qxF -- "$line" <<<"$existing"; then new+="${line}"$'\n'; fi
    done <<<"$lines"
    if [ -z "$new" ]; then return 0; fi
    printf '\n# Added by gentoo_helper on %s: %s\n%s' "$(date '+%Y-%m-%d')" "$reason" "$new" >>"$file"
    log "Added to ${file}: ${new}"
}

# After a failed plan: offer to apply the settings Portage asks for, or explain.
# Returns 0 when settings were saved and the plan should be tried again.
handle_plan_failure() {
    local reason=$1 use lic kw mask text def="y" f
    use=$(extract_changes "USE")
    lic=$(extract_changes "license")
    kw=$(extract_changes "keyword")
    mask=$(extract_changes "mask")
    if [ -n "$use" ] || [ -n "$lic" ] || [ -n "$kw" ]; then
        text="To go ahead, Portage needs some settings changed first:"$'\n'
        if [ -n "$use" ]; then
            text+=$'\n'"Package options (USE flags) to turn on or off:"$'\n'"${use}"$'\n'"These switch on features that a package needs. Accepting them is normally safe."$'\n'
        fi
        if [ -n "$lic" ]; then
            text+=$'\n'"Licences to accept:"$'\n'"${lic}"$'\n'"These packages are not free software (or use an unusual licence), so their licence must be accepted explicitly."$'\n'
        fi
        if [ -n "$kw" ]; then
            def="n"
            text+=$'\n'"Testing versions to allow:"$'\n'"${kw}"$'\n'"The version needed is still marked as 'testing' (~amd64) on Gentoo. Testing versions usually work but have had less testing than stable ones. Only accept if you really want this."$'\n'
        fi
        text+=$'\n'"Save these settings and try again? They are saved in files named zz-gentoo-helper under /etc/portage, and can be reviewed or removed any time under 'Maintenance > Settings added by this helper'."
        if ui_yesno "$text" "$def"; then
            if [ -n "$use" ]; then add_settings "$USE_FILE" "$use" "$reason"; fi
            if [ -n "$lic" ]; then add_settings "$LICENSE_FILE" "$lic" "$reason"; fi
            if [ -n "$kw" ]; then add_settings "$KEYWORDS_FILE" "$kw" "$reason"; fi
            return 0
        fi
        return 1
    fi
    if grep -q "there are no ebuilds to satisfy" <<<"$PLAN_OUT"; then
        ui_msg "There is no package with that name. Check the spelling, or use 'Find and install' to search for it."
        return 1
    fi
    f=$(tmpfile)
    {
        if [ -n "$mask" ] || grep -q "have been masked" <<<"$PLAN_OUT"; then
            printf '%s\n' "The package (or something it needs) is MASKED: Gentoo has blocked it,"
            printf '%s\n' "usually because it is broken, insecure, or about to be removed. The"
            printf '%s\n' "reason is shown below. This helper does not unmask packages."
        else
            printf '%s\n' "Portage cannot work out how to do this. Its own explanation is below."
            printf '%s\n' "Conflicts like this often go away after the next system update; if not,"
            printf '%s\n' "search forums.gentoo.org for the package names mentioned."
        fi
        printf '\n'
        printf '%s\n' "----------------------------------------------------------------------"
        printf '%s\n' "$PLAN_OUT"
    } >"$f"
    TITLE="Portage could not make a plan"
    ui_file "$f"
    return 1
}

# plan_and_run "description" ARGS...: plan, fix settings if needed, confirm, run.
# Returns 0 on success, 1 when cancelled, 2 when emerge failed, 3 when there
# was nothing to do.
plan_and_run() {
    local what=$1 round rc
    shift
    for round in 1 2 3 4; do
        make_plan "$@"
        if (( PLAN_RC == 0 )); then break; fi
        if (( round == 4 )) || ! handle_plan_failure "$what"; then return 1; fi
    done
    rc=0
    confirm_plan "$what" || rc=$?
    if (( rc == 3 )); then return 3; fi
    if (( rc != 0 )); then return 1; fi
    if run_emerge "$@"; then return 0; fi
    return 2
}

# install_packages "description" PKG...: install whatever is missing (packages
# already installed are left alone). Returns 0 when everything is in place.
install_packages() {
    local what=$1 rc
    shift
    rc=0
    plan_and_run "$what" --noreplace "$@" || rc=$?
    if (( rc == 0 || rc == 3 )); then return 0; fi
    return 1
}

# ----------------------------------------------------------------------------
# Status
# ----------------------------------------------------------------------------
# Days since the package repository was synced (-1 if unknown).
# metadata/timestamp.x starts with the snapshot time in seconds; otherwise the
# file times are used.
sync_age_days() {
    local ts=""
    if [ -r "${REPO_DIR}/metadata/timestamp.x" ]; then
        ts=$(awk 'NR == 1 {print $1}' "${REPO_DIR}/metadata/timestamp.x" 2>/dev/null || true)
    fi
    if [[ ! $ts =~ ^[0-9]+$ ]]; then ts=$(file_mtime "${REPO_DIR}/metadata/timestamp.chk" || true); fi
    if [[ ! $ts =~ ^[0-9]+$ ]]; then ts=$(file_mtime "$REPO_DIR" || true); fi
    if [[ ! $ts =~ ^[0-9]+$ ]]; then printf '%s\n' "-1"; return 0; fi
    printf '%s\n' "$(( ($(date +%s) - ts) / 86400 ))"
}

news_count() {
    local n
    n=$(eselect news count new 2>/dev/null || printf '%s\n' 0)
    [[ $n =~ ^[0-9]+$ ]] || n=0
    printf '%s\n' "$n"
}

pending_configs() {
    local p
    local -a paths=()
    read -ra paths <<<"$(portageq envvar CONFIG_PROTECT 2>/dev/null || printf '%s\n' /etc)"
    for p in "${paths[@]}"; do
        if [ -e "$p" ]; then find "$p" -name '._cfg[0-9][0-9][0-9][0-9]_*' 2>/dev/null || true; fi
    done | LC_ALL=C sort
}

# The newest kernel in /lib/modules, if it is not the running one.
newer_kernel() {
    local newest d
    newest=$(for d in /lib/modules/*/; do
            [ -d "$d" ] || continue
            d=${d%/}
            printf '%s\n' "${d##*/}"
        done | LC_ALL=C sort -t. -k1,1n -k2,2n -k3,3n | tail -n1)
    if [ -n "$newest" ] && [ "$newest" != "$(uname -r)" ]; then printf '%s\n' "$newest"; fi
}

binpkgs_enabled() {
    [[ " $(portageq envvar FEATURES 2>/dev/null) " = *" getbinpkg "* ]]
}

status_text() {
    local age news cfg free kern s
    age=$(sync_age_days)
    news=$(news_count)
    cfg=$(pending_configs | wc -l)
    free=$(df -h / 2>/dev/null | awk 'NR == 2 {print $4}')
    kern=$(newer_kernel)
    if (( age < 0 )); then s="Package list updated: unknown"
    elif (( age == 0 )); then s="Package list updated: today"
    elif (( age == 1 )); then s="Package list updated: yesterday"
    else s="Package list updated: ${age} days ago"; fi
    if (( age > 7 )); then s+="  (time for an update)"; fi
    s+=$'\n'"Free disk space: ${free:-unknown}"
    if binpkgs_enabled; then s+="    Ready-made packages: on"; else s+="    Ready-made packages: off"; fi
    if (( news > 0 )); then s+=$'\n'"Unread Gentoo news: ${news} (Maintenance > Read Gentoo news)"; fi
    if (( cfg > 0 )); then s+=$'\n'"Configuration updates waiting: ${cfg} (Maintenance)"; fi
    if [ -n "$kern" ]; then s+=$'\n'"A newer kernel (${kern}) is installed: restart the computer to use it."; fi
    printf '%s' "$s"
}

# ----------------------------------------------------------------------------
# Install
# ----------------------------------------------------------------------------

# search_packages TERM [name|desc]: fills SR_NAME/SR_INST/SR_LATEST/SR_DESC
search_packages() {
    local term=$1 mode=${2:-name} name inst latest desc
    local -a opts=(--search)
    if [ "$mode" = "desc" ]; then opts=(--searchdesc); fi
    busy "Searching for '${term}'. This takes a few seconds..."
    OUT=$(emerge "${opts[@]}" --color=n --nospinner "$term" 2>&1 || true)
    SR_NAME=(); SR_INST=(); SR_LATEST=(); SR_DESC=()
    # Fields are separated by the ASCII unit separator: with a tab, read would
    # merge consecutive separators and shift fields when one is empty.
    local sep=$'\x1f'
    local -a exact=() other=()
    while IFS=$sep read -r name inst latest desc; do
        [ -n "$name" ] || continue
        if [ "${name##*/}" = "${term,,}" ] || [ "${name##*/}" = "${term,,}-bin" ]; then
            exact+=("${name}${sep}${inst}${sep}${latest}${sep}${desc}")
        else
            other+=("${name}${sep}${inst}${sep}${latest}${sep}${desc}")
        fi
    done < <(awk -v sep="$sep" '
        function flush() { if (name != "") printf "%s%s%s%s%s%s%s\n", name, sep, inst, sep, latest, sep, desc }
        /^\*  [A-Za-z0-9]/ { flush(); name = $2; inst = ""; latest = ""; desc = ""; next }
        /Latest version available:/ { latest = $NF; next }
        /Latest version installed:/ { v = $0; sub(/.*installed:[ \t]*/, "", v); inst = (v ~ /Not Installed/) ? "" : v; next }
        /Description:/ { d = $0; sub(/.*Description:[ \t]*/, "", d); desc = d; next }
        END { flush() }' <<<"$OUT")
    local r
    for r in "${exact[@]}" "${other[@]}"; do
        IFS=$sep read -r name inst latest desc <<<"$r"
        SR_NAME+=("$name"); SR_INST+=("$inst"); SR_LATEST+=("$latest"); SR_DESC+=("$desc")
    done
}

install_flow() {
    local term=${1:-} i label count max=150
    local -a items=()
    TITLE="Find and install"
    if [ -z "$term" ]; then
        ui_input "What are you looking for? Type a program name or part of it, for example: firefox, vlc, gimp, htop." "" || return 0
        term=$CHOICE
    fi
    search_packages "$term" name
    if (( ${#SR_NAME[@]} == 0 )); then
        if ui_yesno "No package name contains '${term}'. Search the package descriptions as well? (slower)" y; then
            search_packages "$term" desc
        fi
    fi
    if (( ${#SR_NAME[@]} == 0 )); then
        if have flatpak && ui_yesno "Nothing found for '${term}' in Gentoo's packages. Search Flathub (Flatpak apps) instead?" y; then
            flatpak_install "$term"
        else
            ui_msg "Nothing found for '${term}'. Try a shorter or different word."
        fi
        return 0
    fi
    count=${#SR_NAME[@]}
    for (( i = 0; i < count && i < max; i++ )); do
        label="${SR_NAME[i]}"
        if [ -n "${SR_INST[i]}" ]; then label+="  [installed]"; fi
        if [ -n "${SR_DESC[i]}" ]; then label+="  ${SR_DESC[i]}"; fi
        items+=("$i" "${label:0:110}")
    done
    local text="Found ${count} package(s) for '${term}'."
    if (( count > max )); then text+=" Showing the first ${max}; type something more specific to narrow it down."; fi
    text+=" Names ending in -bin are ready-made builds published by the program's authors."
    while true; do
        TITLE="Find and install"
        if ! ui_menu "$text" "0" "${items[@]}"; then return 0; fi
        package_actions "$CHOICE"
    done
}

package_actions() {
    local i=$1 name inst latest desc text
    name=${SR_NAME[i]}; inst=${SR_INST[i]}; latest=${SR_LATEST[i]}; desc=${SR_DESC[i]}
    TITLE=$name
    text="${name}"$'\n'"${desc}"$'\n\n'"Newest version available: ${latest:-unknown}"$'\n'
    if [ -n "$inst" ]; then
        text+="Installed version: ${inst}"$'\n\n'"It is already installed. Newer versions arrive with the regular system update."
        if ! ui_menu "$text" "back" reinstall "Reinstall it" remove "Remove it" back "Back"; then return 0; fi
        case "$CHOICE" in
            reinstall) plan_and_run "Reinstall ${name}" --oneshot "$name" || true ;;
            remove) remove_package "$name" ;;
        esac
        return 0
    fi
    text+="Not installed."$'\n\n'"How should it be installed?"
    if ! ui_menu "$text" "normal" \
        normal "Install (ready-made when available, otherwise compiled; recommended)" \
        binary "Install only if a ready-made package is available (fast, no compiling)" \
        source "Compile it on this computer (slower; tuned to your CPU)" \
        back "Back"; then
        return 0
    fi
    local rc=0
    case "$CHOICE" in
        normal) plan_and_run "Install ${name}" "$name" || rc=$? ;;
        binary) plan_and_run "Install ${name} (ready-made packages only)" --getbinpkgonly "$name" || rc=$? ;;
        source) plan_and_run "Install ${name} (compiled on this computer)" --usepkg=n --getbinpkg=n "$name" || rc=$? ;;
        *) return 0 ;;
    esac
    if (( rc == 3 )); then ui_msg "Nothing to do: ${name} and everything it needs are already installed."; fi
    if (( rc == 0 )); then
        TITLE=$name
        ui_msg "${name} is installed. Desktop programs appear in your application menu (you may need to log out and back in). Command-line programs are started by typing their name in a terminal."
    fi
}

# ----------------------------------------------------------------------------
# Remove
# ----------------------------------------------------------------------------
is_critical() {
    case "$1" in
        sys-kernel/*|sys-boot/*|sys-firmware/*|sys-apps/*|app-admin/sudo|app-admin/doas|\
        net-misc/networkmanager|net-misc/dhcpcd|kde-plasma/plasma-meta|gnome-base/gnome|gnome-base/gnome-light|\
        gui-apps/sddm|gnome-base/gdm|x11-misc/lightdm*|gui-libs/display-manager-init|sys-fs/*|\
        x11-drivers/*|app-admin/sysklogd|sys-process/cronie|net-misc/chrony|app-portage/gentoolkit)
            return 0 ;;
    esac
    return 1
}

world_entries() {
    grep -vE '^[[:space:]]*(#|$)' "$WORLD_FILE" 2>/dev/null | LC_ALL=C sort -u || true
}

remove_flow() {
    local term=${1:-} e
    local -a matches=() items=()
    TITLE="Remove a package"
    while IFS= read -r e; do
        if [[ -z $term || $e = *"$term"* ]]; then matches+=("$e"); fi
    done < <(world_entries)
    if (( ${#matches[@]} == 0 )); then
        ui_msg "None of the packages you installed matches '${term}'. (Only packages you installed yourself can be removed here; the rest are dependencies that Portage manages.)"
        return 0
    fi
    if (( ${#matches[@]} == 1 )) && [ -n "$term" ]; then
        remove_package "${matches[0]}"
        return 0
    fi
    for e in "${matches[@]}"; do items+=("$e" "$e"); done
    if ! ui_menu "These are the packages you (or the installer) chose to install. Everything else is a dependency that Portage installs and removes automatically. Which one should be removed?" "" "${items[@]}"; then
        return 0
    fi
    remove_package "$CHOICE"
}

# remove_package ATOM: take it off the list of wanted packages, then remove it
# if nothing else needs it.
remove_package() {
    local pkg=$1 sel count f
    TITLE="Remove ${pkg}"
    if is_critical "$pkg"; then
        if ! ui_yesno "WARNING: ${pkg} looks important for starting or using this system (kernel, bootloader, drivers, network, login screen, desktop or core tools). Removing it can leave the computer unable to boot or log in. Remove it anyway?" n; then
            return 0
        fi
    fi
    busy "Checking what removing ${pkg} would do..."
    emerge --deselect "$pkg" >>"$LOG" 2>&1 || true
    OUT=$(emerge --pretend --depclean --color=n --nospinner "$pkg" 2>&1 || true)
    sel=$(sed -n 's/^All selected packages: //p' <<<"$OUT")
    count=$(awk '/^Number to remove:/ {print $NF}' <<<"$OUT")
    if [ -z "$sel" ] || [ "${count:-0}" = "0" ]; then
        emerge --noreplace --nodeps "$pkg" >>"$LOG" 2>&1 || true
        f=$(tmpfile)
        {
            printf '%s\n' "${pkg} was not removed, because other installed packages need it."
            printf '%s\n' "Portage's explanation:"
            printf '\n'
            printf '%s\n' "$OUT"
        } >"$f"
        ui_file "$f"
        return 0
    fi
    if ! ui_yesno "This will remove:"$'\n'"$(tr ' ' '\n' <<<"$sel" | sed 's/^=/  /')"$'\n\n'"Go ahead?" y; then
        emerge --noreplace --nodeps "$pkg" >>"$LOG" 2>&1 || true
        return 0
    fi
    if run_visible emerge --color=y --depclean "$pkg"; then
        pause_text
        depclean_flow quiet
    else
        pause_text
    fi
}

# ----------------------------------------------------------------------------
# Update
# ----------------------------------------------------------------------------
perl_version() {
    perl -e 'print $^V' 2>/dev/null || true
}

update_flow() {
    local perl_before rc
    TITLE="Update the system"
    if ! ui_yesno "This updates the whole system:"$'\n\n'"1. Download the latest package list (a minute or two)."$'\n'"2. Show what can be updated, and ask before installing anything."$'\n'"3. Afterwards, offer to clean up and handle anything that needs attention."$'\n\n'"Start?" y; then
        return 0
    fi
    if ! run_visible emaint sync -a; then
        pause_text
        ui_msg "Downloading the package list failed. Check the internet connection and try again."
        return 0
    fi
    pause_text
    news_flow quiet
    perl_before=$(perl_version)
    TITLE="Update the system"
    rc=0
    plan_and_run "System update" --update --deep --newuse --keep-going=y @world || rc=$?
    if (( rc == 3 )); then ui_msg "Everything is already up to date."; fi
    after_update "$perl_before"
}

after_update() {
    local perl_before=$1 kern
    TITLE="After the update"
    if [ -n "$perl_before" ] && [ "$(perl_version)" != "$perl_before" ] && have perl-cleaner; then
        ui_msg "Perl was upgraded (${perl_before} to $(perl_version)). Perl modules built for the old version are now rebuilt, otherwise some programs and later builds fail."
        perl_rebuild
    fi
    if portageq list_preserved_libs / >/dev/null 2>&1; then
        ui_msg "Some programs still use old versions of updated libraries. They are rebuilt now so the old libraries can be removed."
        run_emerge @preserved-rebuild || true
    fi
    depclean_flow quiet
    if (( $(pending_configs | wc -l) > 0 )); then
        if ui_yesno "Some updated packages bring new versions of configuration files that you (or the installer) had changed. Review them now?" y; then
            config_flow
        fi
    fi
    if have flatpak && [ -n "$(flatpak list --app --columns=application 2>/dev/null)" ]; then
        if ui_yesno "Update your Flatpak apps too?" y; then
            run_visible flatpak update -y || true
            pause_text
        fi
    fi
    kern=$(newer_kernel)
    TITLE="Update finished"
    if [ -n "$kern" ]; then
        ui_msg "Update finished. A new kernel (${kern}) was installed: restart the computer to start using it. The previous kernel stays in the boot menu as a fallback."
    else
        ui_msg "Update finished."
    fi
}

# ----------------------------------------------------------------------------
# Maintenance
# ----------------------------------------------------------------------------

# depclean_flow [quiet]: remove packages that nothing needs anymore
depclean_flow() {
    local quiet=${1:-} sel count
    TITLE="Remove unneeded packages"
    busy "Looking for packages that nothing needs anymore..."
    OUT=$(emerge --pretend --depclean --color=n --nospinner 2>&1 || true)
    sel=$(sed -n 's/^All selected packages: //p' <<<"$OUT")
    count=$(awk '/^Number to remove:/ {print $NF}' <<<"$OUT")
    if [ -z "$sel" ] || [ "${count:-0}" = "0" ]; then
        if [ -z "$quiet" ]; then ui_msg "Nothing to clean up: every installed package is still needed."; fi
        return 0
    fi
    if ui_yesno "These ${count} package(s) are no longer needed by anything you installed (usually old versions or dependencies of removed programs):"$'\n\n'"$(tr ' ' '\n' <<<"$sel" | sed 's/^=/  /')"$'\n\n'"Remove them?" y; then
        run_visible emerge --color=y --depclean || true
        pause_text
    fi
}

space_flow() {
    local before after leftovers
    TITLE="Free disk space"
    if ! have eclean-dist; then
        if ui_yesno "This needs the gentoolkit package (small). Install it now?" y; then
            install_packages "Install gentoolkit" app-portage/gentoolkit || return 0
        else
            return 0
        fi
    fi
    before=$(df -h / | awk 'NR == 2 {print $4}')
    if ! ui_yesno "This deletes downloaded source archives and ready-made packages that no installed package uses any more. Portage downloads them again if they are ever needed. Continue?" y; then
        return 0
    fi
    clear_screen
    run_visible eclean-dist --deep || true
    if have eclean-pkg; then eclean-pkg --deep 2>&1 | tee -a "$LOG" || true; fi
    pause_text
    leftovers=$(du -sh /var/tmp/portage 2>/dev/null | awk '{print $1}' || true)
    if [ -n "$(find /var/tmp/portage -mindepth 1 -maxdepth 1 2>/dev/null | head -n1 || true)" ]; then
        if ui_yesno "Leftovers from failed or interrupted builds use ${leftovers:-some space} in /var/tmp/portage. Delete them? (Do not do this while another emerge is running.)" y; then
            clear_dir /var/tmp/portage
        fi
    fi
    after=$(df -h / | awk 'NR == 2 {print $4}')
    ui_msg "Free disk space before: ${before}, now: ${after}."
}

kernels_flow() {
    local f
    TITLE="Remove old kernels"
    if ! have eclean-kernel; then
        if ui_yesno "This needs the eclean-kernel package (small). Install it now?" y; then
            install_packages "Install eclean-kernel" app-admin/eclean-kernel || return 0
        else
            return 0
        fi
    fi
    busy "Checking installed kernels..."
    OUT=$(eclean-kernel -p -n 3 2>&1 || true)
    f=$(tmpfile)
    {
        printf '%s\n' "Old kernels are kept after updates as a fallback. This keeps the 3 newest"
        printf '%s\n' "and removes older ones. What eclean-kernel would do:"
        printf '\n'
        printf '%s\n' "$OUT"
    } >"$f"
    ui_file "$f"
    if ui_yesno "Remove the older kernels listed above (keeping the 3 newest and the running one)?" n; then
        run_visible eclean-kernel -n 3 || true
        pause_text
    fi
}

perl_rebuild() {
    local edo
    edo=$(portageq envvar EMERGE_DEFAULT_OPTS 2>/dev/null || true)
    run_visible env EMERGE_DEFAULT_OPTS="${edo} --quiet-build=y --color=y" perl-cleaner --all || true
    pause_text
}

preserved_flow() {
    TITLE="Rebuild after library updates"
    if portageq list_preserved_libs / >/dev/null 2>&1; then
        run_emerge @preserved-rebuild || true
    else
        ui_msg "Nothing to do: no program is using an outdated library."
    fi
}

# news_flow [quiet]: show unread news (quiet: only ask when there is some)
news_flow() {
    local quiet=${1:-} n f
    TITLE="Gentoo news"
    n=$(news_count)
    if (( n == 0 )); then
        if [ -z "$quiet" ]; then ui_msg "No unread news."; fi
        return 0
    fi
    if [ -n "$quiet" ] && ! ui_yesno "There are ${n} unread Gentoo news item(s). They announce changes that sometimes need a manual step, so it is worth reading them before updating. Read them now?" y; then
        return 0
    fi
    f=$(tmpfile)
    eselect news read new 2>&1 | strip_colors >"$f" || true
    ui_file "$f"
}

# Files the installer (or a typical user) customises: keeping them is usually right.
config_note() {
    case "$1" in
        /etc/default/grub|/etc/conf.d/hostname|/etc/conf.d/keymaps|/etc/conf.d/display-manager|/etc/locale.gen|/etc/hosts|/etc/fstab|/etc/sudoers|/etc/doas.conf|/etc/portage/*)
            printf '%s\n' "This file was customised during installation or by you. Keeping your version is usually right; the update's changes are often just comments." ;;
        *)
            printf '%s\n' "If you never changed this file yourself, using the new version is usually right." ;;
    esac
}

# cfg_target PATH/._cfg0000_NAME  ->  PATH/NAME
cfg_target() {
    local base=${1##*/}
    printf '%s/%s' "${1%/*}" "${base#._cfg[0-9][0-9][0-9][0-9]_}"
}

config_flow() {
    local cfg target f diffout
    local -a cfgs=() targets=()
    TITLE="Configuration file updates"
    mapfile -t cfgs < <(pending_configs)
    if (( ${#cfgs[@]} == 0 )); then
        ui_msg "No configuration file updates are waiting."
        return 0
    fi
    for cfg in "${cfgs[@]}"; do
        target=$(cfg_target "$cfg")
        if [[ " ${targets[*]} " != *" ${target} "* ]]; then targets+=("$target"); fi
    done
    for target in "${targets[@]}"; do
        local newest=""
        for cfg in "${cfgs[@]}"; do
            if [ "$(cfg_target "$cfg")" = "$target" ]; then newest=$cfg; fi
        done
        [ -n "$newest" ] || continue
        diffout=$(diff -u "$target" "$newest" 2>&1 || true)
        f=$(tmpfile)
        {
            printf '%s\n' "File: ${target}"
            printf '\n'
            printf '%s\n' "An update brought a new version of this file. Lines starting with - are"
            printf '%s\n' "only in your current file, lines starting with + only in the new one."
            printf '\n'
            printf '%s\n' "$diffout"
        } >"$f"
        TITLE="Update for ${target}"
        ui_file "$f"
        if ! ui_menu "${target}"$'\n\n'"$(config_note "$target")" "keep" \
            keep "Keep my current file (discard the update)" \
            new "Use the new file (my current file is saved as a backup)" \
            later "Decide later" \
            stop "Stop reviewing"; then
            return 0
        fi
        case "$CHOICE" in
            keep)
                rm -f -- "${target%/*}"/._cfg[0-9][0-9][0-9][0-9]_"${target##*/}"
                log "Config: kept ${target}" ;;
            new)
                local bak
                bak="${target}.bak-$(date +%Y%m%d-%H%M%S)"
                cp -p -- "$target" "$bak" 2>/dev/null || true
                if ! mv -f -- "$newest" "$target"; then
                    ui_msg "Could not replace ${target}; it was left as it is."
                    continue
                fi
                rm -f -- "${target%/*}"/._cfg[0-9][0-9][0-9][0-9]_"${target##*/}"
                log "Config: replaced ${target} (backup ${bak})"
                ui_msg "Replaced. Your previous file is saved as ${bak}." ;;
            stop) return 0 ;;
        esac
    done
    TITLE="Configuration file updates"
    ui_msg "Done reviewing configuration updates."
}

settings_flow() {
    local f file
    TITLE="Settings added by this helper"
    while true; do
        f=$(tmpfile)
        {
            printf '%s\n' "Settings this helper saved when Portage asked for them. They live in"
            printf '%s\n' "their own files, so your other settings are never touched."
            for file in "$USE_FILE" "$LICENSE_FILE" "$KEYWORDS_FILE" "$MASK_FILE"; do
                printf '\n'
                printf '%s\n' "== ${file}"
                if [ -s "$file" ]; then cat "$file"; else printf '%s\n' "(none)"; fi
            done
        } >"$f"
        if ! ui_menu "Package options (USE flags), accepted licences, allowed testing versions and blocked versions saved by this helper." "view" \
            view "Show them" \
            edit "Edit them (in \$EDITOR, or nano)" \
            clear "Remove all of them" \
            back "Back"; then
            return 0
        fi
        case "$CHOICE" in
            view) ui_file "$f" ;;
            edit)
                local -a existing=()
                for file in "$USE_FILE" "$LICENSE_FILE" "$KEYWORDS_FILE" "$MASK_FILE"; do
                    if [ -f "$file" ]; then existing+=("$file"); fi
                done
                if (( ${#existing[@]} == 0 )); then ui_msg "There are none yet."; continue; fi
                clear_screen
                "${EDITOR:-nano}" "${existing[@]}" || true
                ;;
            clear)
                if ui_yesno "Remove all settings saved by this helper? Packages that needed them may fail to update until the settings are added again (the helper offers that automatically)." n; then
                    rm -f -- "$USE_FILE" "$LICENSE_FILE" "$KEYWORDS_FILE" "$MASK_FILE"
                    log "Removed all helper settings"
                    ui_msg "Removed. The next system update rebuilds whatever is affected."
                fi
                ;;
            *) return 0 ;;
        esac
    done
}

world_flow() {
    local f
    f=$(tmpfile)
    {
        printf '%s\n' "Packages you (or the installer) chose to install. Their dependencies are"
        printf '%s\n' "not listed; Portage installs, updates and removes those automatically."
        printf '\n'
        world_entries
    } >"$f"
    TITLE="Packages I installed"
    ui_file "$f"
}

maint_menu() {
    local def="depclean" cfg news
    while true; do
        TITLE="Maintenance and cleanup"
        cfg=$(pending_configs | wc -l)
        news=$(news_count)
        local -a items=(
            depclean "Remove packages nothing needs anymore"
            space "Free disk space (old downloads and build leftovers)"
            kernels "Remove old kernels (keeps the 3 newest)"
            configs "Review configuration file updates (${cfg} waiting)"
            news "Read Gentoo news (${news} unread)"
            preserved "Rebuild programs after library updates"
            perl "Rebuild Perl modules (needed after a Perl upgrade)"
            world "Show the packages I installed"
            settings "Settings added by this helper"
        )
        if [ -s "$LAST_FAILURE" ]; then items+=(failure "Show the last failure report"); fi
        if ! ui_menu "Things to do now and then to keep the system tidy. Each one explains itself and asks before changing anything." "$def" "${items[@]}"; then
            return 0
        fi
        def=$CHOICE
        case "$CHOICE" in
            depclean) depclean_flow ;;
            space) space_flow ;;
            kernels) kernels_flow ;;
            configs) config_flow ;;
            news) news_flow ;;
            preserved) preserved_flow ;;
            perl)
                TITLE="Rebuild Perl modules"
                if have perl-cleaner; then
                    if ui_yesno "Rebuild Perl modules that were built for an older Perl version? This does nothing if none are left over." y; then perl_rebuild; fi
                else
                    ui_msg "perl-cleaner is not installed."
                fi ;;
            world) world_flow ;;
            settings) settings_flow ;;
            failure) TITLE="Last failure report"; ui_file "$LAST_FAILURE" ;;
        esac
    done
}

clean_flow() {
    depclean_flow
    space_flow
    kernels_flow
}

# ----------------------------------------------------------------------------
# Flatpak
# ----------------------------------------------------------------------------
flathub_ready() {
    local remotes
    remotes=$(flatpak remotes --columns=name 2>/dev/null || true)
    if grep -qx "flathub" <<<"$remotes"; then return 0; fi
    if ui_yesno "Flathub (the main Flatpak app store) is not set up yet. Add it now?" y; then
        run_visible flatpak remote-add --if-not-exists flathub "$FLATHUB_URL" || true
        pause_text
        remotes=$(flatpak remotes --columns=name 2>/dev/null || true)
        if grep -qx "flathub" <<<"$remotes"; then return 0; fi
    fi
    return 1
}

flatpak_install() {
    local term=${1:-} id name desc line
    local -a items=() ids=()
    TITLE="Install a Flatpak app"
    flathub_ready || return 0
    if [ -z "$term" ]; then
        ui_input "Which app are you looking for? (for example: spotify, discord, steam, obs)" "" || return 0
        term=$CHOICE
    fi
    busy "Searching Flathub for '${term}'..."
    OUT=$(flatpak search --columns=application,name,description "$term" 2>&1 || true)
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        if [[ $line = *$'\t'* ]]; then
            # A non-whitespace separator keeps empty columns in place.
            IFS=$'\x1f' read -r id name desc <<<"${line//$'\t'/$'\x1f'}"
        else
            read -r id name desc <<<"$line"
        fi
        [[ $id = *.*.* ]] || continue
        ids+=("$id")
        items+=("$id" "${name}: ${desc}")
    done <<<"$OUT"
    if (( ${#ids[@]} == 0 )); then
        ui_msg "No Flatpak apps found for '${term}'."
        return 0
    fi
    if ! ui_menu "Flatpak apps for '${term}'. Flatpak apps are ready-made, run in a sandbox, and update separately from the rest of the system." "" "${items[@]:0:120}"; then
        return 0
    fi
    id=$CHOICE
    if ui_yesno "Install ${id} from Flathub?" y; then
        if run_visible flatpak install -y --noninteractive flathub "$id"; then
            pause_text
            ui_msg "Installed. It appears in your application menu (you may need to log out and back in)."
        else
            pause_text
        fi
    fi
}

flatpak_remove() {
    local id name line
    local -a items=()
    TITLE="Remove a Flatpak app"
    while IFS=$'\x1f' read -r id name; do
        [ -n "$id" ] || continue
        items+=("$id" "${name:-$id}  (${id})")
    done < <(flatpak list --app --columns=application,name 2>/dev/null | tr '\t' '\037')
    if (( ${#items[@]} == 0 )); then ui_msg "No Flatpak apps are installed."; return 0; fi
    if ! ui_menu "Which Flatpak app should be removed?" "" "${items[@]}"; then return 0; fi
    if ui_yesno "Remove ${CHOICE}?" y; then
        run_visible flatpak uninstall -y --noninteractive "$CHOICE" || true
        pause_text
    fi
}

flatpak_menu() {
    TITLE="Flatpak apps"
    if ! have flatpak; then
        if ui_yesno "Flatpak installs desktop apps (Spotify, Discord, Steam and many more) from Flathub, ready-made and sandboxed. It is not installed yet. Install it now?" y; then
            install_packages "Install Flatpak" sys-apps/flatpak || return 0
            have flatpak || return 0
            flathub_ready || true
        else
            return 0
        fi
    fi
    while true; do
        TITLE="Flatpak apps"
        if ! ui_menu "Flatpak apps come ready-made from Flathub and update separately from Gentoo's packages." "install" \
            install "Find and install an app" \
            remove "Remove an app" \
            update "Update all apps" \
            unused "Remove unused runtimes (frees disk space)" \
            list "Show installed apps"; then
            return 0
        fi
        case "$CHOICE" in
            install) flatpak_install ;;
            remove) flatpak_remove ;;
            update) run_visible flatpak update -y || true; pause_text ;;
            unused) run_visible flatpak uninstall --unused -y || true; pause_text ;;
            list)
                local f
                f=$(tmpfile)
                flatpak list --app --columns=name,application,version >"$f" 2>&1 || true
                TITLE="Installed Flatpak apps"
                ui_file "$f" ;;
        esac
    done
}

# ----------------------------------------------------------------------------
# Common tasks: hardware and features, set up in one go
# ----------------------------------------------------------------------------
GROUPS_ADDED=""

init_system() {
    if [ -d /run/systemd/system ]; then printf '%s\n' "systemd"; else printf '%s\n' "openrc"; fi
}

# pkg_installed CATEGORY/NAME
pkg_installed() {
    compgen -G "/var/db/pkg/${1}-[0-9]*" >/dev/null
}

# pkg_has_use CATEGORY/NAME FLAG: installed and built with FLAG
pkg_has_use() {
    local d
    for d in /var/db/pkg/"${1}"-[0-9]*; do
        [ -r "$d/USE" ] || continue
        if [[ " $(<"$d/USE") " = *" $2 "* ]]; then return 0; fi
    done
    return 1
}

# svc_unit NAME...: the first of the given service names that exists on this
# system. Give the OpenRC name and the systemd unit (for example: cupsd cups.service).
svc_unit() {
    local n init
    init=$(init_system)
    for n in "$@"; do
        if [ "$init" = "systemd" ]; then
            if [[ $n != *.* ]]; then n="${n}.service"; fi
            if [ -n "$(systemctl list-unit-files --no-legend "$n" 2>/dev/null || true)" ]; then printf '%s\n' "$n"; return 0; fi
        else
            if [[ $n = *.* ]]; then continue; fi
            if [ -x "/etc/init.d/$n" ]; then printf '%s\n' "$n"; return 0; fi
        fi
    done
    return 1
}

svc_active() {
    local u
    u=$(svc_unit "$@") || return 1
    if [ "$(init_system)" = "systemd" ]; then
        systemctl is-active --quiet "$u"
    else
        rc-service "$u" status >/dev/null 2>&1
    fi
}

svc_enabled() {
    local u shown
    u=$(svc_unit "$@") || return 1
    if [ "$(init_system)" = "systemd" ]; then
        systemctl is-enabled --quiet "$u"
    else
        shown=$(rc-update show default 2>/dev/null; rc-update show boot 2>/dev/null)
        grep -Eq "^[[:space:]]*${u}[[:space:]]*\|" <<<"$shown"
    fi
}

# svc_enable_now NAME...: start the service now and at every boot
svc_enable_now() {
    local u rc=0
    u=$(svc_unit "$@") || { log "No service found among: $*"; return 1; }
    if [ "$(init_system)" = "systemd" ]; then
        systemctl enable --now "$u" >>"$LOG" 2>&1 || rc=$?
    else
        rc-update add "$u" default >>"$LOG" 2>&1 || true
        rc-service "$u" start >>"$LOG" 2>&1 || rc=$?
    fi
    log "Enable and start ${u}: exit ${rc}"
    return "$rc"
}

# svc_disable_now NAME...: stop the service and do not start it at boot
svc_disable_now() {
    local u
    u=$(svc_unit "$@") || return 0
    if [ "$(init_system)" = "systemd" ]; then
        systemctl disable --now "$u" >>"$LOG" 2>&1 || true
    else
        rc-service "$u" stop >>"$LOG" 2>&1 || true
        rc-update del "$u" default >>"$LOG" 2>&1 || true
    fi
    log "Disable and stop ${u}"
    return 0
}

# The everyday (non-root) user this helper is working for.
target_user() {
    local u=${SUDO_USER:-${DOAS_USER:-}}
    if [ -n "$u" ] && [ "$u" != "root" ]; then printf '%s\n' "$u"; return 0; fi
    getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 {print $1; exit}'
}

# add_user_groups GROUP...: add the everyday user to these groups (if they exist).
# Sets GROUPS_ADDED to the groups that were actually added.
add_user_groups() {
    local user g current added=""
    user=$(target_user)
    GROUPS_ADDED=""
    if [ -z "$user" ]; then return 0; fi
    current=" $(id -nG "$user" 2>/dev/null) "
    for g in "$@"; do
        if getent group "$g" >/dev/null && [[ $current != *" $g "* ]]; then
            if usermod -aG "$g" "$user" >>"$LOG" 2>&1; then added+="${added:+ }${g}"; fi
        fi
    done
    GROUPS_ADDED=$added
    if [ -n "$added" ]; then log "Added ${user} to groups: ${added}"; fi
}

groups_note() {
    if [ -n "$GROUPS_ADDED" ]; then
        printf '%s' $'\n\n'"Your user was added to the group(s): ${GROUPS_ADDED}. Log out and back in for that to take effect."
    fi
}

# pci_devices CLASS_PREFIX: "slot|vendor|driver in use|name" for matching PCI devices
pci_devices() {
    local d class vendor drv name slot
    for d in /sys/bus/pci/devices/*; do
        [ -r "$d/class" ] || continue
        class=$(<"$d/class")
        [[ $class = "$1"* ]] || continue
        vendor=$(<"$d/vendor")
        slot=${d##*/}
        drv="none"
        if [ -L "$d/driver" ]; then drv=$(basename "$(readlink "$d/driver")"); fi
        name=""
        if have lspci; then name=$(LC_ALL=C lspci -s "$slot" 2>/dev/null | cut -d' ' -f2- || true); fi
        printf '%s|%s|%s|%s\n' "$slot" "$vendor" "$drv" "${name:-PCI device ${slot}}"
    done
}

# broadcom_kind_here: "wl" or "b43" when this computer has a Broadcom Wi-Fi
# chip that needs that driver (same table as broadcom_wifi_kind in the installer).
broadcom_kind_here() {
    local slot vendor drv name dev result=""
    while IFS='|' read -r slot vendor drv name; do
        [ "$vendor" = "0x14e4" ] || continue
        dev=$(cat -- "/sys/bus/pci/devices/${slot}/device" 2>/dev/null || true)
        case "$dev" in
            0x43a0|0x43b1|0x4365|0x4359) result="wl" ;;
            0x4311|0x4312|0x4315|0x4318|0x4319|0x4328|0x4329|0x432a|0x432b|0x432c|0x432d|0x4331)
                [ -n "$result" ] || result="b43" ;;
        esac
    done < <(pci_devices "0x0280")
    printf '%s' "$result"
}

is_apple() {
    [[ $(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true) = *Apple* ]]
}

is_laptop() {
    if compgen -G "/sys/class/power_supply/BAT*" >/dev/null; then return 0; fi
    case "$(cat /sys/class/dmi/id/chassis_type 2>/dev/null || printf '0')" in
        8|9|10|11|14|30|31|32) return 0 ;;
    esac
    return 1
}

# Number of graphics chips (two means a hybrid laptop, for example Intel + NVIDIA).
gpu_count() {
    pci_devices "0x03" | grep -c . || true
}

wifi_ifaces() {
    local n out=""
    for n in /sys/class/net/*; do
        if [ -d "$n/wireless" ] || [ -e "$n/phy80211" ]; then out+="${out:+ }${n##*/}"; fi
    done
    printf '%s' "$out"
}

desktop_kind() {
    if pkg_installed kde-plasma/plasma-workspace; then printf '%s\n' "plasma"
    elif pkg_installed gnome-base/gnome-shell; then printf '%s\n' "gnome"
    else printf '%s\n' "other"; fi
}

task_status() {
    local n
    case "$1" in
        printing)
            if pkg_installed net-print/cups; then
                if svc_enabled cupsd cups.service; then printf '%s\n' "set up"; else printf '%s\n' "installed, not running"; fi
            fi ;;
        scanning) if pkg_installed media-gfx/sane-backends; then printf '%s\n' "installed"; fi ;;
        wifi)
            n=$(wifi_ifaces)
            if [ -n "$n" ]; then printf '%s\n' "adapter: ${n}"; else printf '%s\n' "no adapter found"; fi ;;
        bluetooth)
            if pkg_installed net-wireless/bluez; then
                if svc_enabled bluetooth; then printf '%s\n' "set up"; else printf '%s\n' "installed, off"; fi
            fi ;;
        codecs) if pkg_installed media-plugins/gst-plugins-libav; then printf '%s\n' "installed"; fi ;;
        ssh) if svc_active sshd; then printf '%s\n' "server running"; fi ;;
        firewall)
            if have ufw && [[ $(LC_ALL=C ufw status 2>/dev/null) = *"Status: active"* ]]; then printf '%s\n' "on"; fi ;;
        vms) if pkg_installed app-emulation/virt-manager; then printf '%s\n' "installed"; fi ;;
    esac
}

task_label() {
    local st
    st=$(task_status "$1")
    printf '%s%s' "$2" "${st:+   [${st}]}"
}

task_printing() {
    local sel note=""
    local -a items=(
        net-print/cups "CUPS printing system (required)" on
        net-dns/avahi "Find network printers automatically (Avahi)" on
        net-print/gutenprint "Drivers for many older Canon, Epson and other printers" on
        net-print/hplip "Drivers for HP printers (also HP scanners)" off
    )
    local -a pkgs=()
    TITLE="Printing"
    if [ "$(desktop_kind)" = "plasma" ]; then
        items+=(kde-plasma/print-manager "Printers page in KDE System Settings" on)
    fi
    if ! ui_checklist "Printing on Linux goes through CUPS. Most printers from the last ten years print without any driver (driverless printing, also called IPP Everywhere or AirPrint) as long as they can be found on the network. Older printers need a driver package. Choose what to install:" "${items[@]}"; then
        return 0
    fi
    sel=$CHOICE
    if [[ " $sel " != *" net-print/cups "* ]]; then sel="net-print/cups ${sel}"; fi
    read -ra pkgs <<<"$sel"
    install_packages "Printing support" "${pkgs[@]}" || return 0
    svc_enable_now cupsd cups.service || note+=$'\n'"The CUPS service could not be started; see ${LOG}."
    if pkg_installed net-dns/avahi; then
        svc_enable_now avahi-daemon || note+=$'\n'"The Avahi service could not be started; see ${LOG}."
    fi
    add_user_groups lp lpadmin
    if [[ " $(portageq envvar USE 2>/dev/null) " != *" cups "* ]]; then
        note+=$'\n\n'"Note: the 'cups' USE flag is not enabled globally, so some programs may not offer printing. Desktop profiles normally enable it."
    fi
    TITLE="Printing"
    ui_msg "Printing is set up.${note}"$'\n\n'"To add a printer:"$'\n'"- KDE Plasma: System Settings > Printers"$'\n'"- GNOME: Settings > Printers"$'\n'"- Any desktop: open http://localhost:631 in a web browser, choose Administration > Add Printer, and log in with your user name and password."$'\n\n'"Network printers are often found automatically; for USB printers, plug them in first.$(groups_note)"
}

task_scanning() {
    local sel note=""
    local -a pkgs=()
    local -a items=(
        media-gfx/sane-backends "Scanner drivers (SANE, required)" on
        media-gfx/sane-airscan "Driverless scanning for most network and USB scanners made since about 2015" on
        media-gfx/simple-scan "Document Scanner, a simple scanning app" on
        net-print/hplip "Drivers for HP scanners and all-in-ones" off
    )
    TITLE="Scanners"
    if ! ui_checklist "Scanning uses SANE. Most recent scanners and all-in-one printers work driverless through sane-airscan. Choose what to install:" "${items[@]}"; then
        return 0
    fi
    sel=$CHOICE
    if [[ " $sel " != *" media-gfx/sane-backends "* ]]; then sel="media-gfx/sane-backends ${sel}"; fi
    read -ra pkgs <<<"$sel"
    install_packages "Scanner support" "${pkgs[@]}" || return 0
    if pkg_installed net-dns/avahi; then
        svc_enable_now avahi-daemon || note+=$'\n'"The Avahi service (network scanner discovery) could not be started; see ${LOG}."
    fi
    add_user_groups scanner lp usb plugdev
    TITLE="Scanners"
    ui_msg "Scanner support is installed.${note}"$'\n\n'"Open 'Document Scanner' from the application menu. Network scanners are found automatically; USB scanners should be plugged in first.$(groups_note)"
}

task_wifi() {
    local ifaces dev devs="" slot vendor drv name rf="" sel note="" restart="no" wlan_pci
    local -a pkgs=() items=()
    TITLE="Wi-Fi"
    busy "Looking for Wi-Fi hardware..."
    ifaces=$(wifi_ifaces)
    while IFS='|' read -r slot vendor drv name; do
        [ -n "$slot" ] || continue
        devs+=$'\n'"  ${name}"$'\n'"    driver in use: ${drv}"
    done < <(pci_devices "0x0280")
    if have lsusb; then
        while IFS= read -r dev; do
            devs+=$'\n'"  USB: ${dev#*ID }"
        done < <(lsusb 2>/dev/null | grep -iE "wireless|wlan|wi-fi|802\.11" || true)
    fi
    if have rfkill; then rf=$(LC_ALL=C rfkill list wifi 2>/dev/null || true); fi
    local text="Wi-Fi adapters found:${devs:-$'\n'"  none that the system recognises as Wi-Fi"}"$'\n'"Wi-Fi network interfaces: ${ifaces:-none}"
    if [[ $rf = *"Hard blocked: yes"* ]]; then
        text+=$'\n\n'"Wi-Fi is switched off by a hardware switch or key (for example Fn+F2 or an airplane-mode key). Switch it on there."
    fi
    if [ -z "$devs" ] && [ -z "$ifaces" ]; then
        text+=$'\n\n'"No Wi-Fi adapter was found. On a virtual machine that is normal. On real hardware, a USB adapter may need to be plugged in, or it may need the firmware or driver below."
    elif [ -n "$devs" ] && [ -z "$ifaces" ]; then
        text+=$'\n\n'"An adapter is present but has no network interface: it is most likely missing its firmware or driver. Installing linux-firmware usually fixes this."
    fi
    items+=(sys-kernel/linux-firmware "Firmware for Wi-Fi adapters (most Intel, Realtek, MediaTek and Atheros cards need it)" on)
    items+=(net-wireless/wireless-regdb "Wireless regulatory database (allows the channels permitted in your country)" on)
    items+=(net-misc/networkmanager "NetworkManager: connect from the network icon, or with 'nmtui' in a terminal" on)
    items+=(net-wireless/iw "iw, a Wi-Fi diagnostics tool" off)
    wlan_pci=$(pci_devices "0x0280")
    local bcm
    bcm=$(broadcom_kind_here)
    case "$bcm" in
        wl)
            text+=$'\n\n'"This Broadcom card (BCM4360, BCM4352, BCM43142 or BCM43228, found in most Macs from 2013 on) only works with Broadcom's proprietary 'wl' driver. Gentoo only has a testing (~amd64) version of it; tick it below and accept the testing version when asked."
            items+=(net-wireless/broadcom-sta "Broadcom 'wl' driver (proprietary, testing version; needed for this card)" on) ;;
        b43)
            text+=$'\n\n'"This Broadcom card uses the open b43 driver, which needs Broadcom's firmware (accept its licence when asked)."
            items+=(sys-firmware/b43-firmware "Firmware for this Broadcom card (b43 driver)" on) ;;
        *)
            if [[ $wlan_pci = *"|0x14e4|"* ]]; then
                items+=(net-wireless/broadcom-sta "Broadcom 'wl' driver (proprietary, testing version; only for cards the open drivers do not support)" off)
            fi ;;
    esac
    if ! ui_checklist "${text}"$'\n\n'"Choose what to install:" "${items[@]}"; then return 0; fi
    sel=$CHOICE
    read -ra pkgs <<<"$sel"
    if (( ${#pkgs[@]} > 0 )); then
        if [[ " $sel " = *" sys-kernel/linux-firmware "* ]] && ! pkg_installed sys-kernel/linux-firmware; then restart="yes"; fi
        if [[ " $sel " = *" net-wireless/broadcom-sta "* || " $sel " = *" sys-firmware/b43-firmware "* ]]; then restart="yes"; fi
        install_packages "Wi-Fi support" "${pkgs[@]}" || return 0
    fi
    if [[ " $sel " = *" net-wireless/broadcom-sta "* ]] && pkg_installed net-wireless/broadcom-sta; then
        if mkdir -p /etc/modprobe.d && printf '%s\n' "# Written by gentoo_helper: this computer's Broadcom Wi-Fi card needs the" \
            "# proprietary wl driver (net-wireless/broadcom-sta). These open drivers would" \
            "# claim the card first. Delete this file if you replace the card." \
            "blacklist b43" "blacklist b43legacy" "blacklist bcma" "blacklist ssb" \
            "blacklist brcmsmac" "blacklist brcmfmac" >/etc/modprobe.d/broadcom-wl-blacklist.conf; then
            note+=$'\n'"The open Broadcom drivers are blocked in /etc/modprobe.d/broadcom-wl-blacklist.conf so wl can take the card."
        fi
    fi
    if pkg_installed net-misc/networkmanager && ! svc_enabled NetworkManager; then
        TITLE="Wi-Fi"
        if ui_yesno "NetworkManager is installed but is not managing the network yet. Switch to it? It takes over wired connections too; the connection may drop for a few seconds while it starts." y; then
            svc_disable_now dhcpcd
            svc_disable_now systemd-networkd
            svc_enable_now NetworkManager || note+=$'\n'"NetworkManager could not be started; see ${LOG}."
        fi
    fi
    if [[ $rf = *"Soft blocked: yes"* ]]; then
        rfkill unblock wifi >>"$LOG" 2>&1 && note+=$'\n'"Wi-Fi was switched off in software; it has been switched on."
    fi
    if [ "$restart" = "yes" ]; then note+=$'\n\n'"Restart the computer so the adapter can load its new firmware or driver."; fi
    TITLE="Wi-Fi"
    ui_msg "Done.${note}"$'\n\n'"To connect: click the network icon in your desktop's panel, or run 'nmtui' in a terminal and choose 'Activate a connection'."
}

task_bluetooth() {
    local sel note="" kind hw="no"
    local -a pkgs=() items=()
    TITLE="Bluetooth"
    if compgen -G "/sys/class/bluetooth/hci*" >/dev/null; then hw="yes"; fi
    kind=$(desktop_kind)
    items+=(net-wireless/bluez "Bluetooth system (BlueZ, required)" on)
    case "$kind" in
        plasma) items+=(kde-plasma/bluedevil "Bluetooth in KDE System Settings and the panel" on) ;;
        gnome) items+=(net-wireless/gnome-bluetooth "Bluetooth in GNOME Settings" on) ;;
        *) items+=(net-wireless/blueman "Blueman, a Bluetooth manager with a tray icon" on) ;;
    esac
    if pkg_installed media-video/pipewire && ! pkg_has_use media-video/pipewire bluetooth; then
        items+=(pipewire-bt "Bluetooth headphones and speakers (rebuilds PipeWire with Bluetooth support)" on)
    fi
    local text="Bluetooth adapter found: ${hw}."
    if [ "$hw" = "no" ]; then text+=" (Many adapters only show up once the Bluetooth system is installed and its firmware is present, so installing can still help. On a virtual machine there is usually none.)"; fi
    if ! ui_checklist "${text}"$'\n\n'"Choose what to install:" "${items[@]}"; then return 0; fi
    sel=$CHOICE
    if [[ " $sel " != *" net-wireless/bluez "* ]]; then sel="net-wireless/bluez ${sel}"; fi
    local audio="no"
    if [[ " $sel " = *" pipewire-bt "* ]]; then audio="yes"; sel=${sel//pipewire-bt/}; fi
    read -ra pkgs <<<"$sel"
    install_packages "Bluetooth support" "${pkgs[@]}" || return 0
    if [ "$audio" = "yes" ]; then
        add_settings "$USE_FILE" "media-video/pipewire bluetooth" "Bluetooth audio"
        plan_and_run "Rebuild PipeWire with Bluetooth audio" --oneshot --update --newuse media-video/pipewire || true
    fi
    svc_enable_now bluetooth || note+=$'\n'"The Bluetooth service could not be started; see ${LOG}."
    add_user_groups plugdev
    TITLE="Bluetooth"
    ui_msg "Bluetooth is set up.${note}"$'\n\n'"Pair devices from the Bluetooth icon or your desktop's settings, or with 'bluetoothctl' in a terminal. If audio devices were added, log out and back in once.$(groups_note)"
}

# Kernel package that is installed (needed to rebuild the initramfs).
kernel_package() {
    local k
    for k in sys-kernel/gentoo-kernel-bin sys-kernel/gentoo-kernel; do
        if pkg_installed "$k"; then printf '%s\n' "$k"; return 0; fi
    done
    return 1
}

# Add a value to VIDEO_CARDS in make.conf (a backup is kept).
add_video_card() {
    local card=$1 f=/etc/portage/make.conf cur
    [ -f "$f" ] || return 1
    cur=$(sed -n 's/^VIDEO_CARDS="\(.*\)"/\1/p' "$f" | tail -n1)
    if [[ " $cur " = *" $card "* ]]; then return 0; fi
    cp -p -- "$f" "${f}.bak-$(date +%Y%m%d-%H%M%S)" || return 1
    if grep -q '^VIDEO_CARDS=' "$f"; then
        sed_inplace "s/^VIDEO_CARDS=\".*\"/VIDEO_CARDS=\"$(trim "${cur} ${card}")\"/" "$f"
    else
        printf '\n# Added by gentoo_helper\nVIDEO_CARDS="%s"\n' "$card" >>"$f"
    fi
    log "VIDEO_CARDS: added ${card}"
}

task_graphics() {
    local slot vendor drv name summary="" has_nv="no" has_intel="no" has_amd="no" f
    local -a items=()
    while true; do
        TITLE="Graphics drivers"
        summary=""
        has_nv="no"; has_intel="no"; has_amd="no"
        while IFS='|' read -r slot vendor drv name; do
            [ -n "$slot" ] || continue
            summary+=$'\n'"  ${name}"$'\n'"    driver in use: ${drv}"
            case "$vendor" in
                0x10de) has_nv="yes" ;;
                0x8086) has_intel="yes" ;;
                0x1002) has_amd="yes" ;;
            esac
        done < <(pci_devices "0x03")
        local text="Graphics hardware:${summary:-$'\n'"  none found"}"
        if [ "$has_amd" = "yes" ] || [ "$has_intel" = "yes" ]; then
            text+=$'\n\n'"AMD and Intel graphics use the open-source drivers (Mesa) that are already installed; 3D and video work out of the box."
        fi
        items=()
        if [ "$has_nv" = "yes" ]; then items+=(nvidia "Install the NVIDIA proprietary driver (best performance for NVIDIA cards)"); fi
        if [ "$has_intel" = "yes" ]; then items+=(intelva "Hardware video decoding for Intel graphics (smoother video, less battery use)"); fi
        items+=(info "Show detailed graphics information")
        if ! ui_menu "$text" "${items[0]}" "${items[@]}"; then return 0; fi
        case "$CHOICE" in
            nvidia) task_nvidia ;;
            intelva)
                local sel
                local -a pkgs=()
                if ui_checklist "Intel video decoding drivers (VA-API):" \
                    media-libs/libva-intel-media-driver "Intel graphics from 2014 (Broadwell) and newer" on \
                    media-libs/libva-intel-driver "Older Intel graphics (before 2014)" off \
                    media-video/libva-utils "vainfo, to check that it works" on; then
                    sel=$CHOICE
                    read -ra pkgs <<<"$sel"
                    if (( ${#pkgs[@]} > 0 )) && install_packages "Intel video decoding" "${pkgs[@]}"; then
                        ui_msg "Installed. Video players and browsers that support VA-API use it automatically; run 'vainfo' in a terminal to see what your graphics can decode."
                    fi
                fi ;;
            info)
                f=$(tmpfile)
                {
                    printf '%s\n' "Graphics devices and their drivers (lspci -k):"
                    printf '\n'
                    if have lspci; then LC_ALL=C lspci -k 2>/dev/null | grep -A3 -Ei "vga|3d controller|display controller" || true; else printf '%s\n' "(lspci is not installed)"; fi
                    printf '\n'
                    printf '%s\n' "VIDEO_CARDS in /etc/portage/make.conf:"
                    grep '^VIDEO_CARDS=' /etc/portage/make.conf 2>/dev/null || printf '%s\n' "(not set)"
                    printf '\n'
                    printf '%s\n' "Kernel modules loaded:"
                    grep -E "^(nvidia|nouveau|amdgpu|radeon|i915|xe) " /proc/modules 2>/dev/null | awk '{print "  " $1}' || true
                } >"$f"
                TITLE="Graphics information"
                ui_file "$f" ;;
        esac
    done
}

# nvidia_generation DEVICE_ID (hex, as in /sys/bus/pci/devices/*/device):
#   current      Turing (GeForce GTX 16xx, RTX 20xx) and newer
#   legacy580    Maxwell, Pascal, Volta (GTX 750, 900 and 10xx series, Titan V):
#                the 580 driver branch is the last to support them, because
#                nvidia-drivers 595 and newer only ship the open kernel modules
#   unsupported  Kepler and older: no longer supported by NVIDIA; Gentoo masks
#                the old driver branches
# Decided by PCI device ID ranges (Maxwell starts at 0x1340, Turing at 0x1e00).
# It is a heuristic; nvidia-drivers itself checks the card again when installed.
nvidia_generation() {
    local id
    if [[ ! $1 =~ ^0x[0-9a-fA-F]+$ ]]; then printf '%s\n' "current"; return 0; fi
    id=$(( $1 ))
    if (( id >= 0x1e00 )); then printf '%s\n' "current"
    elif (( id >= 0x1340 )); then printf '%s\n' "legacy580"
    else printf '%s\n' "unsupported"; fi
}

# The generation of the oldest NVIDIA graphics card in this computer (empty if none).
nvidia_gen_here() {
    local d gen result=""
    for d in /sys/bus/pci/devices/*; do
        [ -r "$d/vendor" ] && [ -r "$d/class" ] || continue
        [[ $(<"$d/vendor") = "0x10de" && $(<"$d/class") = 0x03* ]] || continue
        gen=$(nvidia_generation "$(cat "$d/device" 2>/dev/null)")
        case "${result}:${gen}" in
            :*|current:legacy580|current:unsupported|legacy580:unsupported) result=$gen ;;
        esac
    done
    printf '%s' "$result"
}

task_nvidia() {
    local kpkg note="" gen branch_text=""
    TITLE="NVIDIA driver"
    if pkg_installed x11-drivers/nvidia-drivers; then
        ui_msg "The NVIDIA proprietary driver is already installed. It is updated with the regular system update, and rebuilt automatically when the kernel changes."
        return 0
    fi
    gen=$(nvidia_gen_here)
    if [ "$gen" = "unsupported" ]; then
        ui_msg "This NVIDIA card is from the Kepler generation or older (such as most GeForce GTX 600 and 700 series cards). NVIDIA no longer supports it in its proprietary driver, and Gentoo masks the old driver branches because they no longer get security fixes."$'\n\n'"Keep using the open source Nouveau driver, which is already part of the system. 3D performance is lower, but it is maintained."
        return 0
    fi
    if [ "$gen" = "legacy580" ]; then
        branch_text=$'\n\n'"This card is from the Maxwell, Pascal or Volta generation (for example GeForce GTX 750, 900 or 10xx series). NVIDIA drivers 595 and newer no longer support it, so the helper keeps the driver on the 580 branch, the last one that does, by adding '>=x11-drivers/nvidia-drivers-581' to ${MASK_FILE}."
    fi
    if ! ui_yesno "This installs NVIDIA's proprietary driver:"$'\n\n'"1. Installs x11-drivers/nvidia-drivers (if your licence settings require it, you are asked to accept NVIDIA's licence)."$'\n'"2. Adds 'nvidia' to VIDEO_CARDS in /etc/portage/make.conf (a backup is kept)."$'\n'"3. Makes sure kernel mode setting is on (current drivers enable it by default; it matters for older branches and for Wayland)."$'\n'"4. Rebuilds the initramfs so the open-source nouveau driver no longer loads first.${branch_text}"$'\n\n'"A restart is needed afterwards. Continue?" y; then
        return 0
    fi
    if [ "$gen" = "legacy580" ]; then
        add_settings "$MASK_FILE" ">=x11-drivers/nvidia-drivers-581" "NVIDIA card supported up to the 580 driver branch"
    fi
    install_packages "Install the NVIDIA driver" x11-drivers/nvidia-drivers || return 0
    add_video_card nvidia || note+=$'\n'"Could not update VIDEO_CARDS in /etc/portage/make.conf."
    if ! grep -rqsE "nvidia[-_]drm.*modeset=1" /etc/modprobe.d/ && [[ " $(cat /proc/cmdline) " != *"nvidia_drm.modeset=1"* && " $(cat /proc/cmdline) " != *"nvidia-drm.modeset=1"* ]]; then
        if mkdir -p /etc/modprobe.d && printf '# Added by gentoo_helper: kernel mode setting for the NVIDIA driver\n# (default in current drivers; needed for older branches and Wayland)\noptions nvidia_drm modeset=1\n' >/etc/modprobe.d/nvidia-drm-modeset.conf; then
            log "Wrote /etc/modprobe.d/nvidia-drm-modeset.conf"
        else
            note+=$'\n'"Could not write /etc/modprobe.d/nvidia-drm-modeset.conf."
        fi
    fi
    if kpkg=$(kernel_package); then
        run_visible emerge --config "$kpkg" || note+=$'\n'"Rebuilding the initramfs failed; see the output above and ${LOG}."
        pause_text
    else
        note+=$'\n'"No distribution kernel was found, so the initramfs was not rebuilt. If you build your own kernel, rebuild its initramfs yourself."
    fi
    TITLE="NVIDIA driver"
    ui_msg "The NVIDIA driver is installed.${note}"$'\n\n'"Restart the computer now. Afterwards, run 'Update the whole system' once so packages pick up the new VIDEO_CARDS setting."$'\n\n'"If the screen stays black after the restart, choose the previous kernel or boot entry, or switch to a text console with Ctrl+Alt+F2 and run gentoo_helper from there."
}

task_codecs() {
    local sel
    local -a pkgs=()
    TITLE="Audio and video codecs"
    if ! ui_checklist "On Gentoo, the formats a program can play are decided when it is built (USE flags), and desktop profiles already enable the common ones. Players such as VLC and mpv bring their own support. These are the shared codec libraries that other programs use (web browsers, GNOME and KDE apps):" \
        media-video/ffmpeg "FFmpeg: nearly all audio and video formats (used by Firefox, KDE apps and many more)" on \
        media-plugins/gst-plugins-meta "GStreamer codecs, used by GNOME and GTK apps" on \
        media-plugins/gst-plugins-libav "GStreamer plugin for FFmpeg formats (H.264, H.265, AAC, ...)" on \
        media-libs/libdvdcss "Play encrypted video DVDs (check that this is legal where you live)" off; then
        return 0
    fi
    sel=$CHOICE
    read -ra pkgs <<<"$sel"
    if (( ${#pkgs[@]} == 0 )); then return 0; fi
    install_packages "Audio and video codecs" "${pkgs[@]}" || return 0
    TITLE="Audio and video codecs"
    ui_msg "Codecs are installed. Restart programs that were already open."$'\n\n'"Playing almost any format now works. Recording or converting to some formats (for example H.264 with x264) needs extra USE flags on ffmpeg; the plan will tell you if a program needs one."
}

ip_addresses() {
    ip -4 -o addr show scope global 2>/dev/null | awk '{sub(/\/.*/, "", $4); print "  " $4 "  (" $2 ")"}'
}

task_ssh() {
    local user note=""
    TITLE="SSH server"
    user=$(target_user)
    if svc_active sshd; then
        if ! ui_menu "The SSH server is running. From another computer on your network, connect with:"$'\n'"  ssh ${user:-yourname}@ADDRESS"$'\n\n'"This computer's addresses:"$'\n'"$(ip_addresses)" "back" \
            back "Keep it running" \
            off "Turn the SSH server off"; then
            return 0
        fi
        if [ "$CHOICE" = "off" ]; then
            svc_disable_now sshd
            ui_msg "The SSH server is stopped and will not start at boot any more."
        fi
        return 0
    fi
    if ! ui_yesno "An SSH server lets you log in to this computer from another one (a terminal, or file transfer with scp/sftp). It listens on port 22."$'\n\n'"Password logins are allowed, so use a strong password for every account. Logging in directly as root with a password is not allowed by default."$'\n\n'"Install (if needed) and turn on the SSH server?" y; then
        return 0
    fi
    install_packages "SSH server" net-misc/openssh || return 0
    ssh-keygen -A >>"$LOG" 2>&1 || true
    svc_enable_now sshd || note+=$'\n'"The SSH service could not be started; see ${LOG}."
    if have ufw && [[ $(LC_ALL=C ufw status 2>/dev/null) = *"Status: active"* ]]; then
        ufw allow ssh >>"$LOG" 2>&1 && note+=$'\n'"The firewall now allows SSH connections."
    fi
    ui_msg "The SSH server is on and starts at every boot.${note}"$'\n\n'"From another computer on your network, connect with:"$'\n'"  ssh ${user:-yourname}@ADDRESS"$'\n\n'"This computer's addresses:"$'\n'"$(ip_addresses)"$'\n\n'"For more security, set up SSH keys and turn off password logins (Gentoo wiki page 'SSH')."
}

task_firewall() {
    local status allow_ssh="no" f
    TITLE="Firewall"
    if have ufw && [[ $(LC_ALL=C ufw status 2>/dev/null) = *"Status: active"* ]]; then
        if ! ui_menu "The firewall (ufw) is on: incoming connections are blocked unless allowed." "status" \
            status "Show the firewall rules" \
            off "Turn the firewall off"; then
            return 0
        fi
        case "$CHOICE" in
            status)
                f=$(tmpfile)
                ufw status verbose >"$f" 2>&1 || true
                ui_file "$f" ;;
            off)
                if ui_yesno "Turn the firewall off?" n; then
                    ufw disable >>"$LOG" 2>&1 || true
                    svc_disable_now ufw
                    ui_msg "The firewall is off."
                fi ;;
        esac
        return 0
    fi
    if ! ui_yesno "A firewall blocks incoming network connections you did not ask for. Programs on this computer can still connect out normally (web, updates, games); only unexpected incoming connections are refused. This sets up ufw with those rules. Continue?" y; then
        return 0
    fi
    install_packages "Firewall (ufw)" net-firewall/ufw || return 0
    if svc_active sshd; then allow_ssh="yes"; fi
    {
        ufw default deny incoming
        ufw default allow outgoing
        if [ "$allow_ssh" = "yes" ]; then ufw allow ssh; fi
        ufw --force enable
    } >>"$LOG" 2>&1 || true
    svc_enable_now ufw || true
    status=$(LC_ALL=C ufw status 2>/dev/null || true)
    if [[ $status = *"Status: active"* ]]; then
        ui_msg "The firewall is on and starts at every boot.$( [ "$allow_ssh" = yes ] && printf '%s' $'\n\n'"SSH connections are still allowed because the SSH server is running." )"
    else
        ui_msg "ufw is installed, but turning it on failed. The details are in ${LOG}."
    fi
}

task_fonts() {
    local sel
    local -a pkgs=()
    TITLE="Fonts"
    if ! ui_checklist "Extra fonts, mainly so documents and web pages look as intended:" \
        media-fonts/liberation-fonts "Liberation: same sizes as Arial, Times New Roman and Courier New" on \
        media-fonts/corefonts "Microsoft core fonts: Arial, Times New Roman, Verdana, ... (licence must be accepted)" off \
        media-fonts/noto-cjk "Chinese, Japanese and Korean text" off \
        media-fonts/noto-emoji "Colour emoji" on \
        media-fonts/dejavu "DejaVu, a widely used general font family" on; then
        return 0
    fi
    sel=$CHOICE
    read -ra pkgs <<<"$sel"
    if (( ${#pkgs[@]} == 0 )); then return 0; fi
    install_packages "Fonts" "${pkgs[@]}" || return 0
    ui_msg "Fonts are installed. Restart programs that were already open to see them."
}

task_archives() {
    local sel
    local -a pkgs=()
    local -a items=(
        app-arch/zip "Create .zip files" on
        app-arch/unzip "Extract .zip files" on
        app-arch/7zip "7-Zip: .7z and many other formats" on
        app-arch/unrar "Extract .rar files (licence must be accepted)" off
    )
    TITLE="Archive formats"
    case "$(desktop_kind)" in
        plasma) items+=(kde-apps/ark "Ark: open and create archives from the file manager" on) ;;
        gnome) items+=(app-arch/file-roller "File Roller: open and create archives from Files" on) ;;
    esac
    if ! ui_checklist "Tools to open and create compressed archives:" "${items[@]}"; then return 0; fi
    sel=$CHOICE
    read -ra pkgs <<<"$sel"
    if (( ${#pkgs[@]} == 0 )); then return 0; fi
    install_packages "Archive formats" "${pkgs[@]}" || return 0
    ui_msg "Archive tools are installed."
}

task_vms() {
    local virt="no" note=""
    TITLE="Virtual machines"
    if grep -qwE "vmx|svm" /proc/cpuinfo; then virt="yes"; fi
    if [ "$virt" = "no" ]; then
        ui_msg "This CPU does not report hardware virtualization (Intel VT-x or AMD-V). It may be switched off in the firmware (BIOS/UEFI) settings, or this is already a virtual machine without nested virtualization. Virtual machines would run very slowly without it."
        ui_yesno "Install the virtual machine tools anyway?" n || return 0
    fi
    if ! ui_yesno "This installs Virtual Machine Manager with QEMU/KVM and libvirt, to run other operating systems in windows on this computer."$'\n\n'"It is a large install: QEMU may have to be compiled, which can take a while."$'\n\n'"Continue?" y; then
        return 0
    fi
    install_packages "Virtual machines" app-emulation/virt-manager app-emulation/qemu app-emulation/libvirt || return 0
    svc_enable_now libvirtd || note+=$'\n'"The libvirt service could not be started; see ${LOG}."
    virsh net-autostart default >>"$LOG" 2>&1 || true
    virsh net-start default >>"$LOG" 2>&1 || true
    add_user_groups libvirt kvm
    ui_msg "Virtual machine tools are installed.${note}"$'\n\n'"Open 'Virtual Machine Manager' from the application menu and click 'Create a new virtual machine'.$(groups_note)"
}

task_steam() {
    TITLE="Steam"
    if ! ui_yesno "Steam is easiest to run as a Flatpak: it is ready-made, and brings the 32-bit libraries games need without changing the rest of the system. Make sure the graphics driver is set up first (Common tasks > Graphics drivers)."$'\n\n'"Install Steam from Flathub?" y; then
        return 0
    fi
    if ! have flatpak; then
        install_packages "Install Flatpak" sys-apps/flatpak || return 0
    fi
    flathub_ready || return 0
    if run_visible flatpak install -y --noninteractive flathub com.valvesoftware.Steam; then
        pause_text
        ui_msg "Steam is installed. It appears in your application menu (log out and back in if it does not)."
    else
        pause_text
    fi
}

task_laptop() {
    local sel note="" cpu tool kind thermal="off"
    local -a items=() pkgs=()
    TITLE="Laptop and Mac hardware"
    cpu=$(awk -F': *' '/^vendor_id/ {print $2; exit}' /proc/cpuinfo)
    kind=$(desktop_kind)
    if pkg_installed sys-power/tlp; then tool="tlp"
    elif pkg_installed sys-power/power-profiles-daemon; then tool="ppd"
    elif [ "$kind" = "plasma" ] || [ "$kind" = "gnome" ]; then tool="ppd"
    else tool="tlp"; fi
    local text="Power and cooling for laptops and Macs."
    if is_laptop; then
        thermal="on"
        if [ "$tool" = "ppd" ]; then
            items+=(sys-power/power-profiles-daemon "Power profiles: power saving, balanced or performance from the battery menu" on)
        else
            items+=(sys-power/tlp "TLP: automatic power saving on battery (CPU, disks, Wi-Fi, USB)" on)
        fi
        text+=" power-profiles-daemon and TLP do the same job and cannot be installed together, so only one is offered: power-profiles-daemon for KDE Plasma and GNOME, which use it, and TLP otherwise."
    fi
    if [ "$cpu" = "GenuineIntel" ]; then
        items+=(sys-power/thermald "thermald: keeps Intel CPUs from overheating" "$thermal")
    fi
    if is_apple; then
        items+=(app-laptop/mbpfan "mbpfan: fan control for Intel Macs (testing version)" on)
        text+=$'\n\n'"Linux does not control Intel Mac fans by itself. mbpfan does; Gentoo only has a testing (~amd64) version, so accept it when asked."
    fi
    if [ "$(gpu_count)" -ge 2 ]; then
        items+=(sys-power/switcheroo-control "switcheroo-control: lets the desktop start programs on the dedicated graphics chip" on)
    fi
    if [ "${#items[@]}" -eq 0 ]; then
        ui_msg "Nothing to set up: this does not look like a laptop or a Mac, and it has one graphics chip."
        return 0
    fi
    if ! ui_checklist "${text}"$'\n\n'"Choose what to install:" "${items[@]}"; then return 0; fi
    sel=$CHOICE
    read -ra pkgs <<<"$sel"
    if [ "${#pkgs[@]}" -eq 0 ]; then return 0; fi
    install_packages "Laptop and Mac hardware" "${pkgs[@]}" || return 0
    if [[ " $sel " = *" sys-power/power-profiles-daemon "* ]]; then
        svc_enable_now power-profiles-daemon || note+=$'\n'"power-profiles-daemon could not be started; see ${LOG}."
    fi
    if [[ " $sel " = *" sys-power/tlp "* ]]; then
        svc_enable_now tlp || note+=$'\n'"TLP could not be started; see ${LOG}."
    fi
    if [[ " $sel " = *" sys-power/thermald "* ]]; then
        svc_enable_now thermald || note+=$'\n'"thermald could not be started; see ${LOG}."
    fi
    if [[ " $sel " = *" app-laptop/mbpfan "* ]]; then
        mkdir -p /etc/modules-load.d
        printf '%s\n' "# Sensors for mbpfan. Written by gentoo_helper" "applesmc" "coretemp" >/etc/modules-load.d/mbpfan.conf
        modprobe applesmc >>"$LOG" 2>&1 || true
        modprobe coretemp >>"$LOG" 2>&1 || true
        svc_enable_now mbpfan || note+=$'\n'"mbpfan could not be started; see ${LOG}."
    fi
    if [[ " $sel " = *" sys-power/switcheroo-control "* ]]; then
        svc_enable_now switcheroo-control || note+=$'\n'"switcheroo-control could not be started; see ${LOG}."
    fi
    TITLE="Laptop and Mac hardware"
    ui_msg "Done.${note}"
}

task_firmware() {
    TITLE="Firmware updates"
    if ! ui_yesno "fwupd installs firmware updates published by hardware makers through the Linux Vendor Firmware Service (LVFS): system firmware (BIOS/UEFI) for many Dell, Lenovo, HP and Framework computers, plus SSDs, docks, keyboards and more. It never updates anything without asking."$'\n\n'"Install fwupd?" y; then
        return 0
    fi
    install_packages "Firmware updates" sys-apps/fwupd || return 0
    ui_msg "fwupd is installed. To check for and install updates, open a terminal and run:"$'\n\n'"  fwupdmgr refresh"$'\n'"  fwupdmgr get-updates"$'\n'"  fwupdmgr update"$'\n\n'"GNOME Software and KDE Discover also show firmware updates once fwupd is installed. Keep laptops plugged in while firmware updates."
}

tasks_menu() {
    local def="printing"
    while true; do
        TITLE="Common tasks"
        local -a items=(
            printing "$(task_label printing "Printing")"
            scanning "$(task_label scanning "Scanners")"
            wifi "$(task_label wifi "Wi-Fi")"
            bluetooth "$(task_label bluetooth "Bluetooth")"
            graphics "Graphics drivers (NVIDIA, Intel video decoding)"
            laptop "Laptop and Mac hardware (power saving, cooling, Mac fans)"
            firmware "Firmware updates (fwupd)"
            codecs "$(task_label codecs "Audio and video codecs")"
            ssh "$(task_label ssh "SSH server (log in from other computers)")"
            firewall "$(task_label firewall "Firewall")"
            fonts "Extra fonts (Microsoft-compatible, Asian languages, emoji)"
            archives "Archive formats (zip, 7z, rar)"
            vms "$(task_label vms "Virtual machines (virt-manager)")"
            steam "Steam (games)"
        )
        if ! ui_menu "Set up common hardware and features. Each task explains what it installs and asks before changing anything." "$def" "${items[@]}"; then
            return 0
        fi
        def=$CHOICE
        case "$CHOICE" in
            printing) task_printing ;;
            scanning) task_scanning ;;
            wifi) task_wifi ;;
            bluetooth) task_bluetooth ;;
            graphics) task_graphics ;;
            laptop) task_laptop ;;
            firmware) task_firmware ;;
            codecs) task_codecs ;;
            ssh) task_ssh ;;
            firewall) task_firewall ;;
            fonts) task_fonts ;;
            archives) task_archives ;;
            vms) task_vms ;;
            steam) task_steam ;;
        esac
    done
}

# ----------------------------------------------------------------------------
# Help and main menu
# ----------------------------------------------------------------------------
help_text() {
    cat <<'EOF'
HOW GENTOO SOFTWARE WORKS, IN SHORT

Packages and emerge
  Gentoo's package manager is Portage; its command is emerge. This helper
  runs emerge for you and shows what it is about to do before doing it.

Ready-made or compiled?
  Gentoo can build every program from its source code on your computer
  ("compiling"). That takes time, but produces programs tuned to your CPU
  and your chosen options. This system also uses Gentoo's official
  ready-made (binary) packages: when a ready-made package matches your
  settings, emerge downloads it in seconds instead of compiling. Anything
  without a matching ready-made package is compiled automatically.
  Packages whose names end in -bin (firefox-bin, libreoffice-bin) are
  ready-made builds published by the program's own authors.

USE flags (package options)
  Many packages have optional features, switched on or off with USE flags.
  Sometimes a package needs a feature switched on in another package; then
  Portage asks for a settings change first. This helper shows the change,
  explains it, and saves it for you if you agree.

Keeping the system updated
  Gentoo is a "rolling release": there are no big version upgrades, just a
  steady flow of updates. Run 'Update the whole system' every week or two.
  The longer you wait, the bigger and trickier the update becomes.

Gentoo news
  Important changes are announced as news items (eselect news). Read them
  before updating; they sometimes ask for a manual step.

Configuration file updates
  When an update brings a new version of a configuration file you changed,
  Portage keeps your file and saves the new one next to it. Review them
  under Maintenance.

Common tasks
  Ready-made recipes for printing, scanners, Wi-Fi, Bluetooth, graphics
  drivers, laptop and Mac hardware, firmware updates, codecs, the SSH
  server, a firewall, fonts, archive formats, virtual machines and Steam:
  they install what is needed, switch on the right services and add your
  user to the right groups.

Flatpak
  An alternative for desktop apps: ready-made, sandboxed, updated
  separately. Handy for big or proprietary apps (Steam, Discord, Spotify).

Doing it by hand
  emerge --ask <package>           install
  emerge --ask --depclean <pkg>    remove (after: emerge --deselect <pkg>)
  emaint sync -a                   download the latest package list
  emerge -avuDN @world             update everything
  emerge -a --depclean             remove unneeded packages
  eselect news read                read the news
  dispatch-conf                    review configuration updates

This helper logs everything it runs to /var/log/gentoo-helper.log.
EOF
}

usage() {
    cat <<EOF
gentoo_helper ${VERSION}: simple menus for everyday Gentoo package management

  gentoo_helper                  menus
  gentoo_helper update           update the whole system
  gentoo_helper install NAME     find and install a package
  gentoo_helper remove NAME      remove a package
  gentoo_helper clean            remove unneeded packages, free disk space
  gentoo_helper news             read Gentoo news
  gentoo_helper configs          review configuration file updates
  gentoo_helper flatpak          Flatpak apps
  gentoo_helper tasks            common tasks: printing, Wi-Fi, drivers, laptops, SSH, ...
  gentoo_helper -t COMMAND       use plain text menus instead of dialog
  gentoo_helper -h               this text
  gentoo_helper -V               show the version

Setting GENTOO_HELPER_UI=text also selects plain text menus.
EOF
}

main_menu() {
    local def="update" f
    while true; do
        TITLE="Gentoo Helper"
        UI_BACK_LABEL="Quit"
        if ! ui_menu "$(status_text)" "$def" \
            update "Update the whole system (do this every week or two)" \
            install "Find and install a program or package" \
            remove "Remove a package" \
            tasks "Common tasks: printing, Wi-Fi, drivers, codecs, SSH, firewall, ..." \
            flatpak "Flatpak apps (Flathub)" \
            maint "Maintenance and cleanup" \
            help "How this works (ready-made vs. compiled, USE flags, ...)"; then
            UI_BACK_LABEL="Back"
            return 0
        fi
        UI_BACK_LABEL="Back"
        def=$CHOICE
        case "$CHOICE" in
            update) update_flow ;;
            install) install_flow ;;
            remove) remove_flow ;;
            tasks) tasks_menu ;;
            flatpak) flatpak_menu ;;
            maint) maint_menu ;;
            help)
                f=$(tmpfile)
                help_text >"$f"
                TITLE="How this works"
                ui_file "$f" ;;
        esac
    done
}

ensure_gentoo() {
    if [ ! -f /etc/gentoo-release ] || ! have emerge; then
        printf '%s\n' "gentoo_helper only works on Gentoo Linux (emerge was not found)." >&2
        exit 1
    fi
}

# Commands this helper cannot work without. Optional ones (dialog, flatpak,
# lspci, ...) are checked where they are used.
REQUIRED_COMMANDS=(emerge portageq eselect awk sed grep fold sort tr cut head tail wc df du find mktemp date id getent usermod python3)

check_commands() {
    local c
    local -a missing=()
    for c in "${REQUIRED_COMMANDS[@]}"; do
        have "$c" || missing+=("$c")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        printf 'gentoo_helper needs these commands, which were not found: %s\n' "${missing[*]}" >&2
        exit 1
    fi
}

check_bash_version() {
    if [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
        printf 'gentoo_helper needs bash 4.4 or newer (this is bash %s).\n' "$BASH_VERSION" >&2
        exit 1
    fi
}

ensure_root() {
    local self
    if [ "$(id -u)" -eq 0 ]; then return 0; fi
    self=$(self_path)
    printf '%s\n' "Managing packages needs administrator rights; asking for your password."
    if have sudo; then exec sudo -- "$self" "$@"; fi
    if have doas; then exec doas -- "$self" "$@"; fi
    printf '%s\n' "Neither sudo nor doas is available. Run gentoo_helper as root." >&2
    exit 1
}

ui_init() {
    if [ "${GENTOO_HELPER_UI:-}" = "text" ]; then UI="text"; return 0; fi
    if [ ! -t 0 ] || [ ! -t 1 ]; then UI="text"; return 0; fi
    if have dialog; then UI="dialog"; return 0; fi
    UI="text"
    if [ -e "${STATE_DIR}/no-dialog" ]; then return 0; fi
    TITLE="Gentoo Helper"
    if ui_yesno "The menus are easier to use with the small 'dialog' program, which is not installed yet. Install it now? (usually under a minute)" y; then
        run_emerge dev-util/dialog || true
        if have dialog; then UI="dialog"; fi
    else
        touch -- "${STATE_DIR}/no-dialog"
        say "OK, using plain text menus. (Install dev-util/dialog any time to get the other menus.)"
    fi
}

main() {
    local opt arg
    local -a orig=("$@") args=()
    check_bash_version
    # Long options are translated to short ones, then read with getopts.
    for arg in "$@"; do
        case "$arg" in
            --help|help) args+=(-h) ;;
            --version) args+=(-V) ;;
            --text) args+=(-t) ;;
            --*) usage >&2; return 1 ;;
            *) args+=("$arg") ;;
        esac
    done
    set -- "${args[@]}"
    OPTIND=1
    while getopts ':hVt' opt; do
        case "$opt" in
            h) usage; return 0 ;;
            V) printf 'gentoo_helper %s\n' "$VERSION"; return 0 ;;
            t) GENTOO_HELPER_UI="text" ;;
            *) usage >&2; return 1 ;;
        esac
    done
    shift $(( OPTIND - 1 ))
    ensure_gentoo
    check_commands
    ensure_root "${orig[@]}"
    mkdir -p -- "$STATE_DIR"
    touch -- "$LOG"
    WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/gentoo_helper.XXXXXX")
    trap cleanup EXIT
    trap 'cleanup; printf "\n"; exit 130' INT
    log "gentoo_helper ${VERSION} started: $*"
    ui_init
    local cmd=${1:-}
    if (( $# > 0 )); then shift; fi
    case "$cmd" in
        "") main_menu ;;
        update|upgrade) update_flow ;;
        install|search|find) install_flow "$*" ;;
        remove|uninstall) remove_flow "$*" ;;
        clean|cleanup) clean_flow ;;
        news) news_flow ;;
        configs|config) config_flow ;;
        flatpak) flatpak_menu ;;
        tasks) tasks_menu ;;
        *) usage; return 1 ;;
    esac
    if [ "$UI" = "dialog" ]; then clear_screen; fi
}

if [ "${BASH_SOURCE[0]:-}" = "$0" ] || [ -z "${BASH_SOURCE[0]:-}" ]; then
    main "$@"
fi
GENTOO_HELPER_SCRIPT_EOF
    chmod 755 /usr/local/bin/gentoo_helper
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
    [hw]="GPU_DRIVER VIDEO_CARDS NET_TOOL WANT_BT WANT_CUPS WANT_SSH WANT_BCM_WL WANT_POWER POWER_TOOL WANT_MBPFAN"
    [sw]="GENTOO_MIRRORS_VALUE WANT_FLATPAK FLATPAK_APPS EXTRA_PKGS"
)
SEC_ORDER=(sys disk region acct hw sw)

usage() {
    cat <<EOF
gentoo_install_tui.sh ${SCRIPT_VERSION}: guided Gentoo Linux installer for amd64 (menu version)

Usage:
  bash gentoo_install_tui.sh                 Start a new installation
  bash gentoo_install_tui.sh -r, --resume    Continue after fixing a failed step
  bash gentoo_install_tui.sh -h, --help      Show this help

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
        die "The menu version needs 'dialog' or 'whiptail', and neither is installed on this live system. Use the console version instead: curl -fsSLO https://raw.githubusercontent.com/NullAngst/Gentoo-Installer/refs/heads/main/gentoo_install.sh && bash gentoo_install.sh"
    fi
    tui_dims
    log "TUI front end: ${TUI_BIN}"
}

tui_dims() {
    local h w
    h=$(tput lines 2>/dev/null || printf '%s\n' 24)
    w=$(tput cols 2>/dev/null || printf '%s\n' 80)
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
    if (( __tc_rc != 0 )) && { [ -n "$TUI_OUT" ] || (( __tc_rc != 1 && __tc_rc != 255 )); }; then
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
    err "Try a larger terminal window, or use the console installer (gentoo_install.sh), which asks the same questions."
    exit 1
}

tui_buf_add() {
    if [ -n "$TUI_BUF" ]; then TUI_BUF+=$'\n\n'; fi
    TUI_BUF+=$1
}

# tui_fit QUESTION LIST_LENGTH WIDTH: combine the collected text with QUESTION into
# TUI_TEXT. If that would not fit on screen next to the list, the collected text
# is shown on its own first.
tui_fit() {
    local q=$1 n=$2 w=$3 buf=$TUI_BUF text lines min_list
    TUI_BUF=""
    text=$buf
    if [ -n "$text" ]; then text+=$'\n\n'; fi
    text+=$q
    min_list=$(( n < 4 ? n : 4 ))
    lines=$(tui_lines "$text" $(( w - 4 )))
    if (( lines + min_list + 8 > TUI_MAXH )) && [ -n "$buf" ]; then
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
        tmp=$(work_file text)
        printf '%s\n' "$text" | fold -s -w $(( TUI_BOXW - 4 )) >"$tmp"
        tui_call "${TUI_SCROLL[@]}" --textbox "$tmp" "$TUI_MAXH" "$TUI_BOXW" || true
        rm -f -- "$tmp"
    else
        tui_call --msgbox "$text" $(( lines + 6 )) "$TUI_BOXW" || true
    fi
}

tui_quit() {
    if [ "$IN_SECTION" = "yes" ]; then exit 11; fi
    tui_clear
    TUI_ACTIVE="no"
    log "Quit from the TUI"
    if [ "$TUI_PHASE" = "setup" ]; then
        printf '%s\n' "Gentoo installer: quit. Nothing on disk was changed."
    fi
    exit 0
}

# Called when a dialog is cancelled (Esc or the Cancel button).
tui_cancelled() {
    local -a items=(1 "Continue where I was")
    if [ "$IN_SECTION" = "yes" ]; then
        items+=(2 "Back to the main menu (discard the changes made in this section)")
    fi
    if [ "$TUI_PHASE" = "setup" ]; then
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
    if [ "$TUI_AUTO" = "yes" ]; then return 0; fi
    for p in "$@"; do tui_buf_add "$p"; done
}

tui_say_pre() {
    if [ "$TUI_AUTO" = "yes" ]; then return 0; fi
    tui_buf_add "$1"
}

tui_section() {
    log "===== $* ====="
    if [ "$TUI_AUTO" = "yes" ]; then return 0; fi
    TUI_SECTION="$*"
    TUI_TITLE="$*"
    TUI_BUF=""
}

tui_subsection() {
    log "--- $* ---"
    if [ "$TUI_AUTO" = "yes" ]; then return 0; fi
    TUI_TITLE="${TUI_SECTION} > $*"
}

# Short status messages: shown right away in a small box, and kept for the next dialog.
tui_info() {
    log "INFO: $*"
    if [ "$TUI_AUTO" = "yes" ]; then return 0; fi
    tui_buf_add "$*"
    tui_dims
    "$TUI_BIN" "${TUI_COMMON[@]}" --backtitle "$BACKTITLE" --title " ${TUI_TITLE} " \
        --infobox "$*" $(( $(tui_lines "$*" $(( TUI_BOXW - 4 ))) + 4 )) "$TUI_BOXW" 2>/dev/null || true
}

tui_warn() {
    log "WARN: $*"
    if [ "$TUI_AUTO" = "yes" ]; then return 0; fi
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
    if [ "$TUI_AUTO" = "yes" ] || [ -z "$TUI_BUF" ]; then return 0; fi
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
        if [ "${__o%%|*}" = "$__def" ]; then __defi=$__i; fi
        if (( ${#__o} > __maxl )); then __maxl=${#__o}; fi
    done
    if [ "$TUI_AUTO" = "yes" ]; then
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
        if [[ $__cur = *" ${__o%%|*} "* ]]; then
            __st="on"
            __out+="${__out:+ }${__o%%|*}"
        fi
        __items+=("$__i" "${__o#*|}" "$__st")
        if (( ${#__o} > __maxl )); then __maxl=${#__o}; fi
    done
    if [ "$TUI_AUTO" = "yes" ]; then
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
    if [ "$TUI_AUTO" = "yes" ]; then
        if [ -n "$__def" ] && { [ -z "$__check" ] || "$__check" "$__def"; }; then
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
            if [ -z "$__a" ]; then __a=$__def; fi
            if [ -z "$__a" ]; then
                tui_buf_add "An answer is required."
                continue
            fi
            if [ -n "$__check" ] && ! "$__check" "$__a"; then
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
    if [ "$TUI_AUTO" = "yes" ]; then
        if [ "$__def" = "y" ]; then printf -v "$__var" 'yes'; else printf -v "$__var" 'no'; fi
        log "DEFAULT: ${__q} => ${!__var}"
        return 0
    fi
    if [ "$__def" = "n" ]; then __f=(--defaultno); fi
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
                if [ "$TUI_PHASE" = "finish" ]; then
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
    if [ "$TUI_AUTO" = "yes" ]; then
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
        if [ "$__p1" != "$__p2" ]; then
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
    if [ "$TUI_AUTO" = "yes" ]; then
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
                while IFS= read -r region; do
                    items+=("${region}|${region}")
                done < <(awk -F/ 'NF > 1 {print $1}' <<<"$names" | sort -u)
                items+=("UTC|UTC (no time zone offset)")
                choose region "Region" "${cur%%/*}" "${items[@]}"
                if [ "$region" = "UTC" ]; then
                    TIMEZONE="UTC"
                    return 0
                fi
                items=()
                while IFS= read -r city; do
                    items+=("${region}/${city}|${city//_/ }")
                done < <(awk -v r="${region}/" 'index($0, r) == 1 {print substr($0, length(r) + 1)}' <<<"$names")
                choose TIMEZONE "City in ${region}" "$cur" "${items[@]}"
                return 0 ;;
        esac
    done
}

# The console's 'list' answer to the timezone question; in the menu version
# the timezone menu has its own list.
browse_timezones() {
    if [ "$TUI_ACTIVE" = "yes" ]; then
        warn "Browsing is done with the 'Pick from a list' option in the timezone menu."
    else
        cli_browse_timezones
    fi
}

# ----------------------------------------------------------------------------
# Front-end dispatch: dialogs while TUI_ACTIVE=yes, console output otherwise
# (during the unattended installation, which prints its progress as text).
# ----------------------------------------------------------------------------
say()            { if [ "$TUI_ACTIVE" = "yes" ]; then tui_say "$@"; else cli_say "$@"; fi; }
say_pre()        { if [ "$TUI_ACTIVE" = "yes" ]; then tui_say_pre "$@"; else cli_say_pre "$@"; fi; }
section()        { if [ "$TUI_ACTIVE" = "yes" ]; then tui_section "$@"; else cli_section "$@"; fi; }
subsection()     { if [ "$TUI_ACTIVE" = "yes" ]; then tui_subsection "$@"; else cli_subsection "$@"; fi; }
info()           { if [ "$TUI_ACTIVE" = "yes" ]; then tui_info "$@"; else cli_info "$@"; fi; }
ok()             { if [ "$TUI_ACTIVE" = "yes" ]; then tui_info "$@"; else cli_ok "$@"; fi; }
warn()           { if [ "$TUI_ACTIVE" = "yes" ]; then tui_warn "$@"; else cli_warn "$@"; fi; }
die()            { if [ "$TUI_ACTIVE" = "yes" ]; then tui_die "$@"; else cli_die "$@"; fi; }
run()            { if [ "$TUI_ACTIVE" = "yes" ]; then tui_run "$@"; else cli_run "$@"; fi; }
choose()         { if [ "$TUI_ACTIVE" = "yes" ]; then tui_choose "$@"; else cli_choose "$@"; fi; }
choose_multi()   { if [ "$TUI_ACTIVE" = "yes" ]; then tui_choose_multi "$@"; else cli_choose_multi "$@"; fi; }
ask()            { if [ "$TUI_ACTIVE" = "yes" ]; then tui_ask "$@"; else cli_ask "$@"; fi; }
ask_yn()         { if [ "$TUI_ACTIVE" = "yes" ]; then tui_ask_yn "$@"; else cli_ask_yn "$@"; fi; }
ask_password()   { if [ "$TUI_ACTIVE" = "yes" ]; then tui_ask_password "$@"; else cli_ask_password "$@"; fi; }
pause()          { if [ "$TUI_ACTIVE" = "yes" ]; then tui_pause; else cli_pause; fi; }
handoff_screen() { if [ "$TUI_ACTIVE" = "yes" ]; then tui_handoff_screen; else cli_handoff_screen; fi; }
ask_timezone()   { if [ "$TUI_ACTIVE" = "yes" ]; then tui_ask_timezone; else cli_ask_timezone; fi; }

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
        if [ "${SEC_STATE[$key]:-}" != "set" ]; then
            # Unquoted on purpose: SEC_VARS holds space separated variable names.
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
    tmp=$(work_file tui-state)
    chmod 600 -- "$tmp"
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
            rm -f -- "$tmp"
            SEC_STATE[$key]="set"
            tui_refresh_defaults
            return 0 ;;
        10)
            rm -f -- "$tmp"
            log "Section ${key}: changes discarded"
            return 1 ;;
        11)
            rm -f -- "$tmp"
            tui_quit ;;
        *)
            rm -f -- "$tmp"
            exit "$rc" ;;
    esac
}

tui_sec_summary() {
    local n_fp=0 n_pk=0 a
    case "$1" in
        sys) printf '%s\n' "$(de_label "$DE"), ${INIT}, binary packages: ${USE_BINPKG}" ;;
        disk)
            if [ "${SEC_STATE[disk]:-}" != "set" ]; then printf '%s\n' "not set yet"; return 0; fi
            a="whole disk"
            if [ "$PART_MODE" = "manual" ]; then a="manual"; fi
            printf '%s\n' "${DISK} (${a}), ${FS}$( [ "$ENCRYPT" = yes ] && printf '%s\n' " + LUKS" ), ${BOOTLOADER}" ;;
        region) printf '%s\n' "${NEW_HOSTNAME}, ${TIMEZONE}, ${LOCALE}" ;;
        acct)
            if [ "${SEC_STATE[acct]:-}" != "set" ]; then printf '%s\n' "not set yet"; return 0; fi
            printf '%s\n' "${USERNAME} (${PRIV_TOOL}, shell: ${USER_SHELL:-bash})" ;;
        hw) printf '%s\n' "network: ${NET_TOOL}, graphics: ${GPU_DRIVER}, SSH: ${WANT_SSH}" ;;
        sw)
            # Unquoted on purpose: both hold space separated names, split to count them.
            for a in $FLATPAK_APPS; do n_fp=$(( n_fp + 1 )); done
            for a in $EXTRA_PKGS; do n_pk=$(( n_pk + 1 )); done
            printf '%s\n' "Flatpak: ${WANT_FLATPAK} (${n_fp} apps), ${n_pk} native packages" ;;
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
    if [ "${SEC_STATE[disk]:-}" != "set" ]; then
        CFG_ERRORS+=("Disk: choose where to install Gentoo (section 2).")
    fi
    if [ "${SEC_STATE[acct]:-}" != "set" ]; then
        CFG_ERRORS+=("Accounts: set the passwords and create your user (section 4).")
    fi
    if [ "${SEC_STATE[disk]:-}" = "set" ] && (( $(target_root_gib) < $(min_root_gib) )); then
        CFG_ERRORS+=("Disk: $( [ "$PART_MODE" = manual ] && printf '%s\n' "${ROOT_PART}" || printf '%s\n' "${DISK}" ) has $(target_root_gib) GiB, but a desktop installation needs at least ${MIN_DESKTOP_DISK_GIB} GiB (section 2, or choose No desktop in section 1).")
    fi
    if [ "${SEC_STATE[disk]:-}" = "set" ] && [ "$ENCRYPT" = "yes" ] && [ -z "$LUKS_PASSWORD" ]; then
        CFG_ERRORS+=("Disk: encryption is on but no passphrase is set (section 2).")
    fi
    if [ "$NET_TOOL" = "networkd" ] && [ "$INIT" != "systemd" ]; then
        CFG_ERRORS+=("Network: systemd-networkd needs systemd, but OpenRC is selected. Change the network manager (section 5) or the init system (section 1).")
    fi
    if [ "$DE" != "none" ] && [ -z "$XKB_LAYOUT" ]; then
        xkb_from_keymap "$KEYMAP"
        CFG_NOTES+=("The desktop keyboard layout was set to '${XKB_LAYOUT}' from the console keymap. Change it in section 3 if needed.")
    fi
    if [ "$DE" = "none" ]; then
        if [ "$WANT_FLATPAK" = "yes" ]; then
            CFG_NOTES+=("Flatpak is selected although there is no desktop; Flatpak apps are mostly graphical (section 6).")
        fi
        if [ "$WANT_CUPS" = "yes" ]; then
            CFG_NOTES+=("Printing (CUPS) is selected although there is no desktop (section 5).")
        fi
        for e in "${NATIVE_GUI_APPS[@]}"; do
            if [[ " $EXTRA_PKGS " = *" ${e%%|*} "* ]]; then gui=$(( gui + 1 )); fi
        done
        if (( gui > 0 )); then
            CFG_NOTES+=("${gui} graphical application(s) are selected although there is no desktop (section 6).")
        fi
    fi
    if [ "$HAS_WIFI" = "yes" ] && [ "$NET_TOOL" != "networkmanager" ]; then
        CFG_NOTES+=("This machine has Wi-Fi, but ${NET_TOOL} only sets up wired networking (section 5).")
    fi
}

tui_review() {
    local tmp C_RED="" C_RESET="" C_BOLD=""
    tui_validate
    compute_derived
    tmp=$(work_file review)
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
    rm -f -- "$tmp"
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
    if [ "$PART_MODE" = "auto" ]; then
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
    if [ "$(trim "$TUI_OUT")" != "$word" ]; then
        tui_show "Not confirmed. Nothing was changed."
        return 1
    fi
    return 0
}

tui_next_item() {
    case "$1" in
        sys) printf '%s\n' "disk" ;;
        disk) printf '%s\n' "region" ;;
        region) printf '%s\n' "acct" ;;
        acct) printf '%s\n' "hw" ;;
        hw) printf '%s\n' "sw" ;;
        *) printf '%s\n' "review" ;;
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
    : >"$LOG"
    log "gentoo_install_tui.sh ${SCRIPT_VERSION} started"
    init_defaults
    tui_init
    TUI_ACTIVE="yes"
    tui_welcome
    live_keyboard
    detect_hardware
    network_step
    sync_clock
    show_hardware
    mac_boot_check
    tui_refresh_defaults
    tui_hub
    tui_install
}

# ----------------------------------------------------------------------------
# Entry point (menu version)
# ----------------------------------------------------------------------------
main() {
    check_bash_version
    parse_args "$@"
    if [ "$RUN_MODE" = "help" ]; then
        usage
        return 0
    fi
    if [ ! -t 0 ]; then
        printf '%s\n' "This installer is interactive and needs a keyboard on standard input." \
            "Download it first, then run it:" \
            "  curl -fsSLO https://raw.githubusercontent.com/NullAngst/Gentoo-Installer/refs/heads/main/gentoo_install_tui.sh" \
            "  bash gentoo_install_tui.sh" >&2
        exit 1
    fi
    SELF=$(self_path)
    make_work_dir
    trap remove_work_dir EXIT
    trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR
    trap on_interrupt INT
    case "$RUN_MODE" in
        chroot)
            chroot_stage
            ;;
        resume)
            live_preflight
            init_defaults
            log "gentoo_install_tui.sh ${SCRIPT_VERSION} resuming"
            tui_init
            TUI_ACTIVE="yes"
            detect_hardware
            resume_install
            tui_pause
            tui_clear
            TUI_ACTIVE="no"
            ;;
        *)
            tui_fresh_install
            ;;
    esac
}

# Run main unless the file is being sourced (for example by a test harness).
if [ "${BASH_SOURCE[0]:-}" = "$0" ] || [ -z "${BASH_SOURCE[0]:-}" ]; then
    main "$@"
fi
