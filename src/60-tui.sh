
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
    local how cur=${TIMEZONE:-UTC} region city
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
                if [[ ! -d /usr/share/zoneinfo ]]; then
                    warn "This live system has no timezone database to browse. Choose 'Type it' instead."
                    continue
                fi
                items=()
                while read -r region; do
                    items+=("${region}|${region}")
                done < <(find /usr/share/zoneinfo -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
                    | grep -E '^(Africa|America|Antarctica|Arctic|Asia|Atlantic|Australia|Europe|Indian|Pacific)$' | sort)
                items+=("UTC|UTC (no time zone offset)")
                choose region "Region" "${cur%%/*}" "${items[@]}"
                if [[ $region == "UTC" ]]; then
                    TIMEZONE="UTC"
                    return 0
                fi
                items=()
                while read -r city; do
                    items+=("${region}/${city}|${city//_/ }")
                done < <(cd "/usr/share/zoneinfo/${region}" && find . -type f | sed 's|^\./||' | sort)
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
