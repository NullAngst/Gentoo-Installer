#!/usr/bin/env bash
# =============================================================================
#  gentoo-helper - simple menus for everyday Gentoo package management
# =============================================================================
#
#  Install, remove and find software, update the whole system and keep it
#  tidy, without having to remember emerge options. Every action first shows
#  what is going to happen in plain words and asks before changing anything.
#
#  Install it:
#    curl -fsSLO https://raw.githubusercontent.com/NullAngst/Gentoo-Installer/refs/heads/main/gentoo-helper.sh
#    sudo install -m 755 gentoo-helper.sh /usr/local/bin/gentoo-helper
#
#  Use it:
#    gentoo-helper                  menus
#    gentoo-helper update           update the whole system
#    gentoo-helper install NAME     find and install a package
#    gentoo-helper remove NAME      remove a package
#    gentoo-helper clean            remove unneeded packages, free disk space
#    gentoo-helper news             read Gentoo news
#    gentoo-helper configs          review configuration file updates
#    gentoo-helper flatpak          Flatpak apps
#    gentoo-helper tasks            common tasks: printing, Wi-Fi, drivers, SSH, ...
#    gentoo-helper help             this text
#
#  Log: /var/log/gentoo-helper.log
# =============================================================================

set -uo pipefail

readonly VERSION="1.0.0"
readonly LOG="/var/log/gentoo-helper.log"
readonly STATE_DIR="/var/lib/gentoo-helper"
readonly LAST_FAILURE="/var/log/gentoo-helper-last-failure.txt"
readonly REPO_DIR="/var/db/repos/gentoo"
readonly WORLD_FILE="/var/lib/portage/world"
readonly USE_FILE="/etc/portage/package.use/zz-gentoo-helper"
readonly LICENSE_FILE="/etc/portage/package.license/zz-gentoo-helper"
readonly KEYWORDS_FILE="/etc/portage/package.accept_keywords/zz-gentoo-helper"
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

if [[ -t 1 ]]; then
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
    w=$(tput cols 2>/dev/null || echo 80)
    [[ $w =~ ^[0-9]+$ ]] || w=80
    echo $(( w > 100 ? 100 : (w < 50 ? 50 : w) ))
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
    mktemp "${WORK_DIR}/XXXXXX"
}

cleanup() {
    if [[ -n $WORK_DIR && -d $WORK_DIR ]]; then rm -rf "$WORK_DIR"; fi
}

# ----------------------------------------------------------------------------
# Menus: dialog when available, plain text otherwise
# ----------------------------------------------------------------------------
ui_dims() {
    local h w
    h=$(tput lines 2>/dev/null || echo 24)
    w=$(tput cols 2>/dev/null || echo 80)
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
    if (( rc != 0 )) && { [[ -n $OUT ]] || (( rc != 1 && rc != 255 )); }; then
        log "dialog failed (rc=${rc}): ${OUT}"
        UI="text"
        clear_screen
        echo "The menu program failed (${OUT:-exit code ${rc}}). Switching to plain text menus."
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
    if [[ $UI == "dialog" ]]; then
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
        dlg --no-tags --cancel-label "$UI_BACK_LABEL" --default-item "$def" \
            --menu "$text" "$h" "$w" "$lh" "${items[@]}"
        rc=$?
        if (( rc == 99 )); then ui_menu "$text" "$def" "${items[@]}"; return $?; fi
        if (( rc == 0 )); then CHOICE=$OUT; return 0; fi
        return 1
    fi
    local num=0 defnum=1 a
    local -a tags=()
    text_header
    say "$text"
    echo
    for (( i = 0; i < ${#items[@]}; i += 2 )); do
        num=$(( num + 1 ))
        tags+=("${items[i]}")
        if [[ ${items[i]} == "$def" ]]; then defnum=$num; fi
        printf '  %2d) %s\n' "$num" "${items[i+1]}"
    done
    printf '   0) %s\n' "$UI_BACK_LABEL"
    while true; do
        if ! read -r -p "  Choose a number [${defnum}]: " a; then echo; return 1; fi
        a=$(trim "${a:-$defnum}")
        if [[ $a == "0" ]]; then return 1; fi
        if [[ $a =~ ^[0-9]+$ ]] && (( a >= 1 && a <= num )); then
            CHOICE=${tags[a-1]}
            return 0
        fi
        echo "  Please enter a number from the list."
    done
}

# ui_yesno "text" [y|n]  ->  returns 0 for yes
ui_yesno() {
    local text=$1 def=${2:-y} rc a hint="Y/n"
    if [[ $UI == "dialog" ]]; then
        local lines h
        local -a extra=()
        ui_dims
        if [[ $def == "n" ]]; then extra=(--defaultno); fi
        lines=$(text_lines "$text" $(( UI_W - 4 )))
        h=$(( lines + 6 ))
        h=$(( h > UI_MAXH ? UI_MAXH : h ))
        dlg "${extra[@]}" --yesno "$text" "$h" "$UI_W"
        rc=$?
        if (( rc == 99 )); then ui_yesno "$text" "$def"; return $?; fi
        return $(( rc == 0 ? 0 : 1 ))
    fi
    if [[ $def == "n" ]]; then hint="y/N"; fi
    echo
    say "$text"
    while true; do
        if ! read -r -p "  [${hint}]: " a; then echo; return 1; fi
        a=$(trim "${a:-$def}")
        case "${a,,}" in
            y|yes) return 0 ;;
            n|no) return 1 ;;
        esac
        echo "  Please answer y or n."
    done
}

# ui_checklist "text" tag "label" on|off ...  ->  CHOICE = the ticked tags,
# separated by spaces. Returns 1 when the user goes back.
ui_checklist() {
    local text=$1 rc i a t
    shift
    local -a items=("$@")
    local n=$(( ${#items[@]} / 3 ))
    if [[ $UI == "dialog" ]]; then
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
        dlg --separate-output --no-tags --cancel-label "Back" --checklist "$text" "$h" "$w" "$lh" "${items[@]}"
        rc=$?
        if (( rc == 99 )); then ui_checklist "$1" "${items[@]}"; return $?; fi
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
        echo
        for (( i = 0; i < n; i++ )); do
            if [[ ${state[i]} == "on" ]]; then t="x"; else t=" "; fi
            printf '  %2d) [%s] %s\n' $(( i + 1 )) "$t" "${items[i*3+1]}"
        done
        echo
        if ! read -r -p "  Numbers to tick/untick (e.g. 2 4), Enter to continue, 0 to go back: " a; then echo; return 1; fi
        a=$(trim "$a")
        if [[ -z $a ]]; then break; fi
        if [[ $a == "0" ]]; then return 1; fi
        local -a picks=()
        read -ra picks <<<"$a"
        for t in "${picks[@]}"; do
            if [[ $t =~ ^[0-9]+$ ]] && (( t >= 1 && t <= n )); then
                if [[ ${state[t-1]} == "on" ]]; then state[t-1]="off"; else state[t-1]="on"; fi
            fi
        done
    done
    CHOICE=""
    for (( i = 0; i < n; i++ )); do
        if [[ ${state[i]} == "on" ]]; then CHOICE+="${CHOICE:+ }${tags[i]}"; fi
    done
    return 0
}

# ui_input "text" "default"  ->  CHOICE. Returns 1 when cancelled or left empty.
ui_input() {
    local text=$1 def=${2:-} rc a
    if [[ $UI == "dialog" ]]; then
        local lines h
        ui_dims
        lines=$(text_lines "$text" $(( UI_W - 4 )))
        h=$(( lines + 8 ))
        h=$(( h > UI_MAXH ? UI_MAXH : h ))
        dlg --inputbox "$text" "$h" "$UI_W" "$def"
        rc=$?
        if (( rc == 99 )); then ui_input "$text" "$def"; return $?; fi
        if (( rc != 0 )); then return 1; fi
        CHOICE=$(trim "$OUT")
    else
        echo
        say "$text" "(Leave empty to go back.)"
        if ! read -r -p "  > " a; then echo; return 1; fi
        CHOICE=$(trim "${a:-$def}")
    fi
    [[ -n $CHOICE ]]
}

# ui_file FILE: show a (long) text file, scrollable
ui_file() {
    local f=$1 rc
    if [[ $UI == "dialog" ]]; then
        ui_dims
        local wrapped
        wrapped=$(tmpfile)
        fold -s -w $(( UI_W - 4 )) "$f" >"$wrapped"
        dlg --exit-label "OK" --textbox "$wrapped" "$UI_MAXH" "$UI_W"
        rc=$?
        if (( rc == 99 )); then ui_file "$f"; fi
        return 0
    fi
    echo
    if have less && (( $(wc -l <"$f") > 20 )); then
        less -R "$f"
    else
        sed 's/^/  /' "$f"
        pause_text
    fi
}

# ui_msg "text": a message box (scrollable when long)
ui_msg() {
    local text=$1 rc
    if [[ $UI == "dialog" ]]; then
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
        dlg --msgbox "$text" $(( lines + 6 )) "$UI_W"
        rc=$?
        if (( rc == 99 )); then ui_msg "$text"; fi
        return 0
    fi
    echo
    say "$text"
    pause_text
}

# busy "text": a short "please wait" note while something runs
busy() {
    if [[ $UI == "dialog" ]]; then
        ui_dims
        dialog --backtitle "Gentoo Helper ${VERSION}" --title " ${TITLE} " \
            --infobox "$1" $(( $(text_lines "$1" $(( UI_W - 4 ))) + 4 )) "$UI_W" 2>/dev/null || true
    else
        echo
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
    "$@" 2>&1 | tee -a "$LOG"
    local rc=${PIPESTATUS[0]}
    log "EXIT ${rc}: $*"
    echo
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
    emerge "${RUN_OPTS[@]}" "$@" 2>&1 | tee -a "$LOG" "$RUN_TMP"
    rc=${PIPESTATUS[0]}
    log "EXIT ${rc}: emerge $*"
    echo
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
        echo "WHAT WENT WRONG"
        echo "==============="
        echo
        if grep -q "No space left on device" "$RUN_TMP" "${blog:-/dev/null}" 2>/dev/null; then
            echo "* The disk is full. Use 'Maintenance > Free disk space', then try again."
            echo
        fi
        if grep -qE "Couldn't download|Fetch failed|Unable to download|Could not resolve host" "$RUN_TMP" 2>/dev/null; then
            echo "* A download failed. Check the internet connection and try again; mirrors"
            echo "  are sometimes briefly unavailable."
            echo
        fi
        if [[ -n $blog && -r $blog ]]; then
            if grep -q "Can't locate .*\.pm in @INC" "$blog" 2>/dev/null; then
                echo "* A Perl module could not be loaded, which usually happens after a Perl"
                echo "  upgrade. Use 'Maintenance > Rebuild Perl modules', then try again."
                echo
            fi
            errors=$(grep -nE "\*\*\* \[|error:|Error [0-9]+|Can't locate|No such file or directory|Illegal instruction|Segmentation fault|Killed|undefined reference|command not found" "$blog" 2>/dev/null \
                | grep -vE "^[0-9]+:(checking|configure:)|-Werror|-Wno-error" || true)
            first=${errors%%:*}
            echo "The package's build log: ${blog}"
            if [[ $first =~ ^[0-9]+$ ]]; then
                from=$(( first > 12 ? first - 12 : 1 ))
                echo
                echo "Where it first went wrong (the cause is usually just above the first"
                echo "line with '***' or 'error'):"
                echo
                sed -n "${from},$(( first + 3 ))p" "$blog"
            fi
            echo
            echo "Last lines of the build log:"
            echo
            tail -n 25 "$blog"
        else
            echo "Last lines of emerge's output:"
            echo
            tail -n 40 "$RUN_TMP"
        fi
        echo
        echo "This report is saved as ${LAST_FAILURE}. If you ask for help (for example"
        echo "on forums.gentoo.org), include it together with the output of: emerge --info"
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
    PLAN_OUT=$(emerge "${PLAN_OPTS[@]}" "$@" 2>&1)
    PLAN_RC=$?
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
    echo "${c:-0}"
}

# confirm_plan "what this is": show the plan and ask. Returns 1 when the user
# says no, 3 when there is nothing to do.
confirm_plan() {
    local what=$1 list nbin nsrc total text f
    list=$(plan_list)
    if [[ -z $list ]]; then return 3; fi
    nbin=$(count_lines '^\[binary')
    nsrc=$(count_lines '^\[ebuild')
    total=$(grep -m1 '^Total:' <<<"$PLAN_OUT" || true)
    text="${what}"$'\n\n'"Packages: $(( nbin + nsrc ))"$'\n'
    text+="  ready-made (downloaded, installs quickly): ${nbin}"$'\n'
    text+="  compiled on this computer:                 ${nsrc}"$'\n'
    if [[ -n $total ]]; then text+=$'\n'"Portage's summary: ${total}"$'\n'; fi
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
        echo "How      What       Package"
        echo "$list"
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
    if [[ -f $dir ]]; then file=$dir; fi
    if [[ ! -e $dir ]]; then mkdir -p "$dir"; fi
    if [[ -f $file ]]; then existing=$(<"$file"); fi
    while IFS= read -r line; do
        line=$(trim "$line")
        if [[ -z $line ]]; then continue; fi
        if ! grep -qxF -- "$line" <<<"$existing"; then new+="${line}"$'\n'; fi
    done <<<"$lines"
    if [[ -z $new ]]; then return 0; fi
    printf '\n# Added by gentoo-helper on %s: %s\n%s' "$(date '+%Y-%m-%d')" "$reason" "$new" >>"$file"
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
    if [[ -n $use || -n $lic || -n $kw ]]; then
        text="To go ahead, Portage needs some settings changed first:"$'\n'
        if [[ -n $use ]]; then
            text+=$'\n'"Package options (USE flags) to turn on or off:"$'\n'"${use}"$'\n'"These switch on features that a package needs. Accepting them is normally safe."$'\n'
        fi
        if [[ -n $lic ]]; then
            text+=$'\n'"Licences to accept:"$'\n'"${lic}"$'\n'"These packages are not free software (or use an unusual licence), so their licence must be accepted explicitly."$'\n'
        fi
        if [[ -n $kw ]]; then
            def="n"
            text+=$'\n'"Testing versions to allow:"$'\n'"${kw}"$'\n'"The version needed is still marked as 'testing' (~amd64) on Gentoo. Testing versions usually work but have had less testing than stable ones. Only accept if you really want this."$'\n'
        fi
        text+=$'\n'"Save these settings and try again? They are saved in files named zz-gentoo-helper under /etc/portage, and can be reviewed or removed any time under 'Maintenance > Settings added by this helper'."
        if ui_yesno "$text" "$def"; then
            if [[ -n $use ]]; then add_settings "$USE_FILE" "$use" "$reason"; fi
            if [[ -n $lic ]]; then add_settings "$LICENSE_FILE" "$lic" "$reason"; fi
            if [[ -n $kw ]]; then add_settings "$KEYWORDS_FILE" "$kw" "$reason"; fi
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
        if [[ -n $mask ]] || grep -q "have been masked" <<<"$PLAN_OUT"; then
            echo "The package (or something it needs) is MASKED: Gentoo has blocked it,"
            echo "usually because it is broken, insecure, or about to be removed. The"
            echo "reason is shown below. This helper does not unmask packages."
        else
            echo "Portage cannot work out how to do this. Its own explanation is below."
            echo "Conflicts like this often go away after the next system update; if not,"
            echo "search forums.gentoo.org for the package names mentioned."
        fi
        echo
        echo "----------------------------------------------------------------------"
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
    confirm_plan "$what"
    rc=$?
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
    plan_and_run "$what" --noreplace "$@"
    rc=$?
    if (( rc == 0 || rc == 3 )); then return 0; fi
    return 1
}

# ----------------------------------------------------------------------------
# Status
# ----------------------------------------------------------------------------
sync_age_days() {
    local f="${REPO_DIR}/metadata/timestamp.chk" ts=""
    if [[ -r $f ]]; then ts=$(date -d "$(head -n1 "$f")" +%s 2>/dev/null || stat -c %Y "$f" 2>/dev/null || true); fi
    if [[ -z $ts ]]; then ts=$(stat -c %Y "$REPO_DIR" 2>/dev/null || true); fi
    if [[ ! $ts =~ ^[0-9]+$ ]]; then echo "-1"; return 0; fi
    echo $(( ($(date +%s) - ts) / 86400 ))
}

news_count() {
    local n
    n=$(eselect news count new 2>/dev/null || echo 0)
    [[ $n =~ ^[0-9]+$ ]] || n=0
    echo "$n"
}

pending_configs() {
    local p
    local -a paths=()
    read -ra paths <<<"$(portageq envvar CONFIG_PROTECT 2>/dev/null || echo /etc)"
    for p in "${paths[@]}"; do
        if [[ -e $p ]]; then find "$p" -name '._cfg[0-9][0-9][0-9][0-9]_*' 2>/dev/null; fi
    done | sort
}

newer_kernel() {
    local newest
    newest=$(find /lib/modules -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort -V | tail -n1)
    if [[ -n $newest && $newest != "$(uname -r)" ]]; then echo "$newest"; fi
}

binpkgs_enabled() {
    [[ " $(portageq envvar FEATURES 2>/dev/null) " == *" getbinpkg "* ]]
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
    if [[ -n $kern ]]; then s+=$'\n'"A newer kernel (${kern}) is installed: restart the computer to use it."; fi
    printf '%s' "$s"
}

# ----------------------------------------------------------------------------
# Install
# ----------------------------------------------------------------------------

# search_packages TERM [name|desc]: fills SR_NAME/SR_INST/SR_LATEST/SR_DESC
search_packages() {
    local term=$1 mode=${2:-name} name inst latest desc
    local -a opts=(--search)
    if [[ $mode == "desc" ]]; then opts=(--searchdesc); fi
    busy "Searching for '${term}'. This takes a few seconds..."
    OUT=$(emerge "${opts[@]}" --color=n --nospinner "$term" 2>&1)
    SR_NAME=(); SR_INST=(); SR_LATEST=(); SR_DESC=()
    # Fields are separated by the ASCII unit separator: with a tab, read would
    # merge consecutive separators and shift fields when one is empty.
    local sep=$'\x1f'
    local -a exact=() other=()
    while IFS=$sep read -r name inst latest desc; do
        [[ -n $name ]] || continue
        if [[ ${name##*/} == "${term,,}" || ${name##*/} == "${term,,}-bin" ]]; then
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
    if [[ -z $term ]]; then
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
        if [[ -n ${SR_INST[i]} ]]; then label+="  [installed]"; fi
        if [[ -n ${SR_DESC[i]} ]]; then label+="  ${SR_DESC[i]}"; fi
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
    if [[ -n $inst ]]; then
        text+="Installed version: ${inst}"$'\n\n'"It is already installed. Newer versions arrive with the regular system update."
        if ! ui_menu "$text" "back" reinstall "Reinstall it" remove "Remove it" back "Back"; then return 0; fi
        case "$CHOICE" in
            reinstall) plan_and_run "Reinstall ${name}" --oneshot "$name" ;;
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
        normal) plan_and_run "Install ${name}" "$name"; rc=$? ;;
        binary) plan_and_run "Install ${name} (ready-made packages only)" --getbinpkgonly "$name"; rc=$? ;;
        source) plan_and_run "Install ${name} (compiled on this computer)" --usepkg=n --getbinpkg=n "$name"; rc=$? ;;
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
        x11-misc/sddm|gnome-base/gdm|x11-misc/lightdm*|gui-libs/display-manager-init|sys-fs/*|\
        x11-drivers/*|app-admin/sysklogd|sys-process/cronie|net-misc/chrony|app-portage/gentoolkit)
            return 0 ;;
    esac
    return 1
}

world_entries() {
    grep -vE '^[[:space:]]*(#|$)' "$WORLD_FILE" 2>/dev/null | sort -u
}

remove_flow() {
    local term=${1:-} e
    local -a matches=() items=()
    TITLE="Remove a package"
    while IFS= read -r e; do
        if [[ -z $term || $e == *"$term"* ]]; then matches+=("$e"); fi
    done < <(world_entries)
    if (( ${#matches[@]} == 0 )); then
        ui_msg "None of the packages you installed matches '${term}'. (Only packages you installed yourself can be removed here; the rest are dependencies that Portage manages.)"
        return 0
    fi
    if (( ${#matches[@]} == 1 )) && [[ -n $term ]]; then
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
    emerge --deselect "$pkg" >>"$LOG" 2>&1
    OUT=$(emerge --pretend --depclean --color=n --nospinner "$pkg" 2>&1)
    sel=$(sed -n 's/^All selected packages: //p' <<<"$OUT")
    count=$(awk '/^Number to remove:/ {print $NF}' <<<"$OUT")
    if [[ -z $sel || ${count:-0} == "0" ]]; then
        emerge --noreplace --nodeps "$pkg" >>"$LOG" 2>&1
        f=$(tmpfile)
        {
            echo "${pkg} was not removed, because other installed packages need it."
            echo "Portage's explanation:"
            echo
            printf '%s\n' "$OUT"
        } >"$f"
        ui_file "$f"
        return 0
    fi
    if ! ui_yesno "This will remove:"$'\n'"$(tr ' ' '\n' <<<"$sel" | sed 's/^=/  /')"$'\n\n'"Go ahead?" y; then
        emerge --noreplace --nodeps "$pkg" >>"$LOG" 2>&1
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
    plan_and_run "System update" --update --deep --newuse --keep-going=y @world
    rc=$?
    if (( rc == 3 )); then ui_msg "Everything is already up to date."; fi
    after_update "$perl_before"
}

after_update() {
    local perl_before=$1 kern
    TITLE="After the update"
    if [[ -n $perl_before && $(perl_version) != "$perl_before" ]] && have perl-cleaner; then
        ui_msg "Perl was upgraded (${perl_before} to $(perl_version)). Perl modules built for the old version are now rebuilt, otherwise some programs and later builds fail."
        perl_rebuild
    fi
    if portageq list_preserved_libs / >/dev/null 2>&1; then
        ui_msg "Some programs still use old versions of updated libraries. They are rebuilt now so the old libraries can be removed."
        run_emerge @preserved-rebuild
    fi
    depclean_flow quiet
    if (( $(pending_configs | wc -l) > 0 )); then
        if ui_yesno "Some updated packages bring new versions of configuration files that you (or the installer) had changed. Review them now?" y; then
            config_flow
        fi
    fi
    if have flatpak && [[ -n $(flatpak list --app --columns=application 2>/dev/null) ]]; then
        if ui_yesno "Update your Flatpak apps too?" y; then
            run_visible flatpak update -y
            pause_text
        fi
    fi
    kern=$(newer_kernel)
    TITLE="Update finished"
    if [[ -n $kern ]]; then
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
    OUT=$(emerge --pretend --depclean --color=n --nospinner 2>&1)
    sel=$(sed -n 's/^All selected packages: //p' <<<"$OUT")
    count=$(awk '/^Number to remove:/ {print $NF}' <<<"$OUT")
    if [[ -z $sel || ${count:-0} == "0" ]]; then
        if [[ -z $quiet ]]; then ui_msg "Nothing to clean up: every installed package is still needed."; fi
        return 0
    fi
    if ui_yesno "These ${count} package(s) are no longer needed by anything you installed (usually old versions or dependencies of removed programs):"$'\n\n'"$(tr ' ' '\n' <<<"$sel" | sed 's/^=/  /')"$'\n\n'"Remove them?" y; then
        run_visible emerge --color=y --depclean
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
    run_visible eclean-dist --deep
    if have eclean-pkg; then eclean-pkg --deep 2>&1 | tee -a "$LOG"; fi
    pause_text
    leftovers=$(du -sh /var/tmp/portage 2>/dev/null | awk '{print $1}')
    if [[ -n $(find /var/tmp/portage -mindepth 1 -maxdepth 1 2>/dev/null | head -n1) ]]; then
        if ui_yesno "Leftovers from failed or interrupted builds use ${leftovers:-some space} in /var/tmp/portage. Delete them? (Do not do this while another emerge is running.)" y; then
            find /var/tmp/portage -mindepth 1 -delete 2>/dev/null
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
    OUT=$(eclean-kernel -p -n 3 2>&1)
    f=$(tmpfile)
    {
        echo "Old kernels are kept after updates as a fallback. This keeps the 3 newest"
        echo "and removes older ones. What eclean-kernel would do:"
        echo
        printf '%s\n' "$OUT"
    } >"$f"
    ui_file "$f"
    if ui_yesno "Remove the older kernels listed above (keeping the 3 newest and the running one)?" n; then
        run_visible eclean-kernel -n 3
        pause_text
    fi
}

perl_rebuild() {
    local edo
    edo=$(portageq envvar EMERGE_DEFAULT_OPTS 2>/dev/null || true)
    run_visible env EMERGE_DEFAULT_OPTS="${edo} --quiet-build=y --color=y" perl-cleaner --all
    pause_text
}

preserved_flow() {
    TITLE="Rebuild after library updates"
    if portageq list_preserved_libs / >/dev/null 2>&1; then
        run_emerge @preserved-rebuild
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
        if [[ -z $quiet ]]; then ui_msg "No unread news."; fi
        return 0
    fi
    if [[ -n $quiet ]] && ! ui_yesno "There are ${n} unread Gentoo news item(s). They announce changes that sometimes need a manual step, so it is worth reading them before updating. Read them now?" y; then
        return 0
    fi
    f=$(tmpfile)
    eselect news read new 2>&1 | sed 's/\x1b\[[0-9;]*m//g' >"$f"
    ui_file "$f"
}

# Files the installer (or a typical user) customises: keeping them is usually right.
config_note() {
    case "$1" in
        /etc/default/grub|/etc/conf.d/hostname|/etc/conf.d/keymaps|/etc/conf.d/display-manager|/etc/locale.gen|/etc/hosts|/etc/fstab|/etc/sudoers|/etc/doas.conf|/etc/portage/*)
            echo "This file was customised during installation or by you. Keeping your version is usually right; the update's changes are often just comments." ;;
        *)
            echo "If you never changed this file yourself, using the new version is usually right." ;;
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
            if [[ $(cfg_target "$cfg") == "$target" ]]; then newest=$cfg; fi
        done
        [[ -n $newest ]] || continue
        diffout=$(diff -u "$target" "$newest" 2>&1 || true)
        f=$(tmpfile)
        {
            echo "File: ${target}"
            echo
            echo "An update brought a new version of this file. Lines starting with - are"
            echo "only in your current file, lines starting with + only in the new one."
            echo
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
                rm -f "${target%/*}"/._cfg[0-9][0-9][0-9][0-9]_"${target##*/}"
                log "Config: kept ${target}" ;;
            new)
                local bak
                bak="${target}.bak-$(date +%Y%m%d-%H%M%S)"
                cp -p "$target" "$bak" 2>/dev/null || true
                mv -f "$newest" "$target"
                rm -f "${target%/*}"/._cfg[0-9][0-9][0-9][0-9]_"${target##*/}"
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
            echo "Settings this helper saved when Portage asked for them. They live in"
            echo "their own files, so your other settings are never touched."
            for file in "$USE_FILE" "$LICENSE_FILE" "$KEYWORDS_FILE"; do
                echo
                echo "== ${file}"
                if [[ -s $file ]]; then cat "$file"; else echo "(none)"; fi
            done
        } >"$f"
        if ! ui_menu "Package options (USE flags), accepted licences and allowed testing versions saved by this helper." "view" \
            view "Show them" \
            edit "Edit them (nano text editor)" \
            clear "Remove all of them" \
            back "Back"; then
            return 0
        fi
        case "$CHOICE" in
            view) ui_file "$f" ;;
            edit)
                local -a existing=()
                for file in "$USE_FILE" "$LICENSE_FILE" "$KEYWORDS_FILE"; do
                    if [[ -f $file ]]; then existing+=("$file"); fi
                done
                if (( ${#existing[@]} == 0 )); then ui_msg "There are none yet."; continue; fi
                clear_screen
                nano "${existing[@]}"
                ;;
            clear)
                if ui_yesno "Remove all settings saved by this helper? Packages that needed them may fail to update until the settings are added again (the helper offers that automatically)." n; then
                    rm -f "$USE_FILE" "$LICENSE_FILE" "$KEYWORDS_FILE"
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
        echo "Packages you (or the installer) chose to install. Their dependencies are"
        echo "not listed; Portage installs, updates and removes those automatically."
        echo
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
        if [[ -s $LAST_FAILURE ]]; then items+=(failure "Show the last failure report"); fi
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
        run_visible flatpak remote-add --if-not-exists flathub "$FLATHUB_URL"
        pause_text
        remotes=$(flatpak remotes --columns=name 2>/dev/null || true)
        grep -qx "flathub" <<<"$remotes"
        return $?
    fi
    return 1
}

flatpak_install() {
    local term=${1:-} id name desc line
    local -a items=() ids=()
    TITLE="Install a Flatpak app"
    flathub_ready || return 0
    if [[ -z $term ]]; then
        ui_input "Which app are you looking for? (for example: spotify, discord, steam, obs)" "" || return 0
        term=$CHOICE
    fi
    busy "Searching Flathub for '${term}'..."
    OUT=$(flatpak search --columns=application,name,description "$term" 2>&1)
    while IFS= read -r line; do
        [[ -n $line ]] || continue
        if [[ $line == *$'\t'* ]]; then
            IFS=$'\t' read -r id name desc <<<"$line"
        else
            read -r id name desc <<<"$line"
        fi
        [[ $id == *.*.* ]] || continue
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
    while IFS=$'\t' read -r id name; do
        [[ -n $id ]] || continue
        items+=("$id" "${name:-$id}  (${id})")
    done < <(flatpak list --app --columns=application,name 2>/dev/null)
    if (( ${#items[@]} == 0 )); then ui_msg "No Flatpak apps are installed."; return 0; fi
    if ! ui_menu "Which Flatpak app should be removed?" "" "${items[@]}"; then return 0; fi
    if ui_yesno "Remove ${CHOICE}?" y; then
        run_visible flatpak uninstall -y --noninteractive "$CHOICE"
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
            update) run_visible flatpak update -y; pause_text ;;
            unused) run_visible flatpak uninstall --unused -y; pause_text ;;
            list)
                local f
                f=$(tmpfile)
                flatpak list --app --columns=name,application,version >"$f" 2>&1
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
    if [[ -d /run/systemd/system ]]; then echo "systemd"; else echo "openrc"; fi
}

# pkg_installed CATEGORY/NAME
pkg_installed() {
    compgen -G "/var/db/pkg/${1}-[0-9]*" >/dev/null
}

# pkg_has_use CATEGORY/NAME FLAG: installed and built with FLAG
pkg_has_use() {
    local d
    for d in /var/db/pkg/"${1}"-[0-9]*; do
        [[ -r $d/USE ]] || continue
        if [[ " $(<"$d/USE") " == *" $2 "* ]]; then return 0; fi
    done
    return 1
}

# svc_unit NAME...: the first of the given service names that exists on this
# system. Give the OpenRC name and the systemd unit (for example: cupsd cups.service).
svc_unit() {
    local n init
    init=$(init_system)
    for n in "$@"; do
        if [[ $init == "systemd" ]]; then
            if [[ $n != *.* ]]; then n="${n}.service"; fi
            if [[ -n $(systemctl list-unit-files --no-legend "$n" 2>/dev/null) ]]; then echo "$n"; return 0; fi
        else
            if [[ $n == *.* ]]; then continue; fi
            if [[ -x /etc/init.d/$n ]]; then echo "$n"; return 0; fi
        fi
    done
    return 1
}

svc_active() {
    local u
    u=$(svc_unit "$@") || return 1
    if [[ $(init_system) == "systemd" ]]; then
        systemctl is-active --quiet "$u"
    else
        rc-service "$u" status >/dev/null 2>&1
    fi
}

svc_enabled() {
    local u shown
    u=$(svc_unit "$@") || return 1
    if [[ $(init_system) == "systemd" ]]; then
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
    if [[ $(init_system) == "systemd" ]]; then
        systemctl enable --now "$u" >>"$LOG" 2>&1 || rc=$?
    else
        rc-update add "$u" default >>"$LOG" 2>&1
        rc-service "$u" start >>"$LOG" 2>&1 || rc=$?
    fi
    log "Enable and start ${u}: exit ${rc}"
    return "$rc"
}

# svc_disable_now NAME...: stop the service and do not start it at boot
svc_disable_now() {
    local u
    u=$(svc_unit "$@") || return 0
    if [[ $(init_system) == "systemd" ]]; then
        systemctl disable --now "$u" >>"$LOG" 2>&1
    else
        rc-service "$u" stop >>"$LOG" 2>&1
        rc-update del "$u" default >>"$LOG" 2>&1
    fi
    log "Disable and stop ${u}"
    return 0
}

# The everyday (non-root) user this helper is working for.
target_user() {
    local u=${SUDO_USER:-${DOAS_USER:-}}
    if [[ -n $u && $u != "root" ]]; then echo "$u"; return 0; fi
    getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 {print $1; exit}'
}

# add_user_groups GROUP...: add the everyday user to these groups (if they exist).
# Sets GROUPS_ADDED to the groups that were actually added.
add_user_groups() {
    local user g current added=""
    user=$(target_user)
    GROUPS_ADDED=""
    if [[ -z $user ]]; then return 0; fi
    current=" $(id -nG "$user" 2>/dev/null) "
    for g in "$@"; do
        if getent group "$g" >/dev/null && [[ $current != *" $g "* ]]; then
            if usermod -aG "$g" "$user" >>"$LOG" 2>&1; then added+="${added:+ }${g}"; fi
        fi
    done
    GROUPS_ADDED=$added
    if [[ -n $added ]]; then log "Added ${user} to groups: ${added}"; fi
}

groups_note() {
    if [[ -n $GROUPS_ADDED ]]; then
        printf '%s' $'\n\n'"Your user was added to the group(s): ${GROUPS_ADDED}. Log out and back in for that to take effect."
    fi
}

# pci_devices CLASS_PREFIX: "slot|vendor|driver in use|name" for matching PCI devices
pci_devices() {
    local d class vendor drv name slot
    for d in /sys/bus/pci/devices/*; do
        [[ -r $d/class ]] || continue
        class=$(<"$d/class")
        [[ $class == "$1"* ]] || continue
        vendor=$(<"$d/vendor")
        slot=${d##*/}
        drv="none"
        if [[ -L $d/driver ]]; then drv=$(basename "$(readlink "$d/driver")"); fi
        name=""
        if have lspci; then name=$(lspci -s "$slot" 2>/dev/null | cut -d' ' -f2-); fi
        printf '%s|%s|%s|%s\n' "$slot" "$vendor" "$drv" "${name:-PCI device ${slot}}"
    done
}

wifi_ifaces() {
    local n out=""
    for n in /sys/class/net/*; do
        if [[ -d $n/wireless || -e $n/phy80211 ]]; then out+="${out:+ }${n##*/}"; fi
    done
    printf '%s' "$out"
}

desktop_kind() {
    if pkg_installed kde-plasma/plasma-workspace; then echo "plasma"
    elif pkg_installed gnome-base/gnome-shell; then echo "gnome"
    else echo "other"; fi
}

task_status() {
    local n
    case "$1" in
        printing)
            if pkg_installed net-print/cups; then
                if svc_enabled cupsd cups.service; then echo "set up"; else echo "installed, not running"; fi
            fi ;;
        scanning) if pkg_installed media-gfx/sane-backends; then echo "installed"; fi ;;
        wifi)
            n=$(wifi_ifaces)
            if [[ -n $n ]]; then echo "adapter: ${n}"; else echo "no adapter found"; fi ;;
        bluetooth)
            if pkg_installed net-wireless/bluez; then
                if svc_enabled bluetooth; then echo "set up"; else echo "installed, off"; fi
            fi ;;
        codecs) if pkg_installed media-plugins/gst-plugins-libav; then echo "installed"; fi ;;
        ssh) if svc_active sshd; then echo "server running"; fi ;;
        firewall)
            if have ufw && [[ $(ufw status 2>/dev/null) == *"Status: active"* ]]; then echo "on"; fi ;;
        vms) if pkg_installed app-emulation/virt-manager; then echo "installed"; fi ;;
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
    if [[ $(desktop_kind) == "plasma" ]]; then
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
        [[ -n $slot ]] || continue
        devs+=$'\n'"  ${name}"$'\n'"    driver in use: ${drv}"
    done < <(pci_devices "0x0280")
    if have lsusb; then
        while IFS= read -r dev; do
            devs+=$'\n'"  USB: ${dev#*ID }"
        done < <(lsusb 2>/dev/null | grep -iE "wireless|wlan|wi-fi|802\.11" || true)
    fi
    if have rfkill; then rf=$(rfkill list wifi 2>/dev/null || true); fi
    local text="Wi-Fi adapters found:${devs:-$'\n'"  none that the system recognises as Wi-Fi"}"$'\n'"Wi-Fi network interfaces: ${ifaces:-none}"
    if [[ $rf == *"Hard blocked: yes"* ]]; then
        text+=$'\n\n'"Wi-Fi is switched off by a hardware switch or key (for example Fn+F2 or an airplane-mode key). Switch it on there."
    fi
    if [[ -z $devs && -z $ifaces ]]; then
        text+=$'\n\n'"No Wi-Fi adapter was found. On a virtual machine that is normal. On real hardware, a USB adapter may need to be plugged in, or it may need the firmware or driver below."
    elif [[ -n $devs && -z $ifaces ]]; then
        text+=$'\n\n'"An adapter is present but has no network interface: it is most likely missing its firmware or driver. Installing linux-firmware usually fixes this."
    fi
    items+=(sys-kernel/linux-firmware "Firmware for Wi-Fi adapters (most Intel, Realtek, MediaTek and Atheros cards need it)" on)
    items+=(net-wireless/wireless-regdb "Wireless regulatory database (allows the channels permitted in your country)" on)
    items+=(net-misc/networkmanager "NetworkManager: connect from the network icon, or with 'nmtui' in a terminal" on)
    items+=(net-wireless/iw "iw, a Wi-Fi diagnostics tool" off)
    wlan_pci=$(pci_devices "0x0280")
    if [[ $wlan_pci == *"|0x14e4|"* ]]; then
        items+=(net-wireless/broadcom-sta "Broadcom 'wl' driver (proprietary; only for Broadcom cards the open drivers do not support)" off)
    fi
    if ! ui_checklist "${text}"$'\n\n'"Choose what to install:" "${items[@]}"; then return 0; fi
    sel=$CHOICE
    read -ra pkgs <<<"$sel"
    if (( ${#pkgs[@]} > 0 )); then
        if [[ " $sel " == *" sys-kernel/linux-firmware "* ]] && ! pkg_installed sys-kernel/linux-firmware; then restart="yes"; fi
        if [[ " $sel " == *" net-wireless/broadcom-sta "* ]]; then restart="yes"; fi
        install_packages "Wi-Fi support" "${pkgs[@]}" || return 0
    fi
    if pkg_installed net-misc/networkmanager && ! svc_enabled NetworkManager; then
        TITLE="Wi-Fi"
        if ui_yesno "NetworkManager is installed but is not managing the network yet. Switch to it? It takes over wired connections too; the connection may drop for a few seconds while it starts." y; then
            svc_disable_now dhcpcd
            svc_disable_now systemd-networkd
            svc_enable_now NetworkManager || note+=$'\n'"NetworkManager could not be started; see ${LOG}."
        fi
    fi
    if [[ $rf == *"Soft blocked: yes"* ]]; then
        rfkill unblock wifi >>"$LOG" 2>&1 && note+=$'\n'"Wi-Fi was switched off in software; it has been switched on."
    fi
    if [[ $restart == "yes" ]]; then note+=$'\n\n'"Restart the computer so the adapter can load its new firmware or driver."; fi
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
    if [[ $hw == "no" ]]; then text+=" (Many adapters only show up once the Bluetooth system is installed and its firmware is present, so installing can still help. On a virtual machine there is usually none.)"; fi
    if ! ui_checklist "${text}"$'\n\n'"Choose what to install:" "${items[@]}"; then return 0; fi
    sel=$CHOICE
    if [[ " $sel " != *" net-wireless/bluez "* ]]; then sel="net-wireless/bluez ${sel}"; fi
    local audio="no"
    if [[ " $sel " == *" pipewire-bt "* ]]; then audio="yes"; sel=${sel//pipewire-bt/}; fi
    read -ra pkgs <<<"$sel"
    install_packages "Bluetooth support" "${pkgs[@]}" || return 0
    if [[ $audio == "yes" ]]; then
        add_settings "$USE_FILE" "media-video/pipewire bluetooth" "Bluetooth audio"
        plan_and_run "Rebuild PipeWire with Bluetooth audio" --oneshot --update --newuse media-video/pipewire
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
        if pkg_installed "$k"; then echo "$k"; return 0; fi
    done
    return 1
}

# Add a value to VIDEO_CARDS in make.conf (a backup is kept).
add_video_card() {
    local card=$1 f=/etc/portage/make.conf cur
    [[ -f $f ]] || return 1
    cur=$(sed -n 's/^VIDEO_CARDS="\(.*\)"/\1/p' "$f" | tail -n1)
    if [[ " $cur " == *" $card "* ]]; then return 0; fi
    cp -p "$f" "${f}.bak-$(date +%Y%m%d-%H%M%S)"
    if grep -q '^VIDEO_CARDS=' "$f"; then
        sed -i "s/^VIDEO_CARDS=\".*\"/VIDEO_CARDS=\"$(trim "${cur} ${card}")\"/" "$f"
    else
        printf '\n# Added by gentoo-helper\nVIDEO_CARDS="%s"\n' "$card" >>"$f"
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
            [[ -n $slot ]] || continue
            summary+=$'\n'"  ${name}"$'\n'"    driver in use: ${drv}"
            case "$vendor" in
                0x10de) has_nv="yes" ;;
                0x8086) has_intel="yes" ;;
                0x1002) has_amd="yes" ;;
            esac
        done < <(pci_devices "0x03")
        local text="Graphics hardware:${summary:-$'\n'"  none found"}"
        if [[ $has_amd == "yes" || $has_intel == "yes" ]]; then
            text+=$'\n\n'"AMD and Intel graphics use the open-source drivers (Mesa) that are already installed; 3D and video work out of the box."
        fi
        items=()
        if [[ $has_nv == "yes" ]]; then items+=(nvidia "Install the NVIDIA proprietary driver (best performance for NVIDIA cards)"); fi
        if [[ $has_intel == "yes" ]]; then items+=(intelva "Hardware video decoding for Intel graphics (smoother video, less battery use)"); fi
        items+=(info "Show detailed graphics information")
        if ! ui_menu "$text" "${items[0]}" "${items[@]}"; then return 0; fi
        case "$CHOICE" in
            nvidia) task_nvidia ;;
            intelva)
                local sel
                local -a pkgs=()
                if ui_checklist "Intel video decoding drivers (VA-API):" \
                    media-libs/libva-intel-media-driver "Intel graphics from 2014 (Broadwell) and newer" on \
                    x11-libs/libva-intel-driver "Older Intel graphics (before 2014)" off \
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
                    echo "Graphics devices and their drivers (lspci -k):"
                    echo
                    if have lspci; then lspci -k 2>/dev/null | grep -A3 -Ei "vga|3d controller|display controller"; else echo "(lspci is not installed)"; fi
                    echo
                    echo "VIDEO_CARDS in /etc/portage/make.conf:"
                    grep '^VIDEO_CARDS=' /etc/portage/make.conf 2>/dev/null || echo "(not set)"
                    echo
                    echo "Kernel modules loaded:"
                    grep -E "^(nvidia|nouveau|amdgpu|radeon|i915|xe) " /proc/modules 2>/dev/null | awk '{print "  " $1}'
                } >"$f"
                TITLE="Graphics information"
                ui_file "$f" ;;
        esac
    done
}

task_nvidia() {
    local kpkg note=""
    TITLE="NVIDIA driver"
    if pkg_installed x11-drivers/nvidia-drivers; then
        ui_msg "The NVIDIA proprietary driver is already installed. It is updated with the regular system update, and rebuilt automatically when the kernel changes."
        return 0
    fi
    if ! ui_yesno "This installs NVIDIA's proprietary driver:"$'\n\n'"1. Installs x11-drivers/nvidia-drivers (you will be asked to accept NVIDIA's licence)."$'\n'"2. Adds 'nvidia' to VIDEO_CARDS in /etc/portage/make.conf (a backup is kept)."$'\n'"3. Turns on kernel mode setting for it (needed for Wayland desktops) in /etc/modprobe.d/."$'\n'"4. Rebuilds the initramfs so the open-source nouveau driver no longer loads first."$'\n\n'"Current driver branches support GeForce GTX 16xx, RTX and newer best. For GTX 10xx and older cards, check the Gentoo wiki page 'NVIDIA/nvidia-drivers' first: newer branches are dropping older cards."$'\n\n'"A restart is needed afterwards. Continue?" y; then
        return 0
    fi
    install_packages "Install the NVIDIA driver" x11-drivers/nvidia-drivers || return 0
    add_video_card nvidia || note+=$'\n'"Could not update VIDEO_CARDS in /etc/portage/make.conf."
    if ! grep -rqsE "nvidia[-_]drm.*modeset=1" /etc/modprobe.d/ && [[ " $(cat /proc/cmdline) " != *"nvidia_drm.modeset=1"* && " $(cat /proc/cmdline) " != *"nvidia-drm.modeset=1"* ]]; then
        if mkdir -p /etc/modprobe.d && printf '# Added by gentoo-helper: kernel mode setting for the NVIDIA driver (needed for Wayland)\noptions nvidia_drm modeset=1\n' >/etc/modprobe.d/nvidia-drm-modeset.conf; then
            log "Wrote /etc/modprobe.d/nvidia-drm-modeset.conf"
        else
            note+=$'\n'"Could not write /etc/modprobe.d/nvidia-drm-modeset.conf (needed for Wayland desktops)."
        fi
    fi
    if kpkg=$(kernel_package); then
        run_visible emerge --config "$kpkg" || note+=$'\n'"Rebuilding the initramfs failed; see the output above and ${LOG}."
        pause_text
    else
        note+=$'\n'"No distribution kernel was found, so the initramfs was not rebuilt. If you build your own kernel, rebuild its initramfs yourself."
    fi
    TITLE="NVIDIA driver"
    ui_msg "The NVIDIA driver is installed.${note}"$'\n\n'"Restart the computer now. Afterwards, run 'Update the whole system' once so packages pick up the new VIDEO_CARDS setting."$'\n\n'"If the screen stays black after the restart, choose the previous kernel or boot entry, or switch to a text console with Ctrl+Alt+F2 and run gentoo-helper from there."
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
        if [[ $CHOICE == "off" ]]; then
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
    if have ufw && [[ $(ufw status 2>/dev/null) == *"Status: active"* ]]; then
        ufw allow ssh >>"$LOG" 2>&1 && note+=$'\n'"The firewall now allows SSH connections."
    fi
    ui_msg "The SSH server is on and starts at every boot.${note}"$'\n\n'"From another computer on your network, connect with:"$'\n'"  ssh ${user:-yourname}@ADDRESS"$'\n\n'"This computer's addresses:"$'\n'"$(ip_addresses)"$'\n\n'"For more security, set up SSH keys and turn off password logins (Gentoo wiki page 'SSH')."
}

task_firewall() {
    local status allow_ssh="no" f
    TITLE="Firewall"
    if have ufw && [[ $(ufw status 2>/dev/null) == *"Status: active"* ]]; then
        if ! ui_menu "The firewall (ufw) is on: incoming connections are blocked unless allowed." "status" \
            status "Show the firewall rules" \
            off "Turn the firewall off"; then
            return 0
        fi
        case "$CHOICE" in
            status)
                f=$(tmpfile)
                ufw status verbose >"$f" 2>&1
                ui_file "$f" ;;
            off)
                if ui_yesno "Turn the firewall off?" n; then
                    ufw disable >>"$LOG" 2>&1
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
        if [[ $allow_ssh == "yes" ]]; then ufw allow ssh; fi
        ufw --force enable
    } >>"$LOG" 2>&1
    svc_enable_now ufw || true
    status=$(ufw status 2>/dev/null || true)
    if [[ $status == *"Status: active"* ]]; then
        ui_msg "The firewall is on and starts at every boot.$( [[ $allow_ssh == yes ]] && printf '%s' $'\n\n'"SSH connections are still allowed because the SSH server is running." )"
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
    if [[ $virt == "no" ]]; then
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
  drivers, codecs, the SSH server, a firewall, fonts, archive formats,
  virtual machines and Steam: they install what is needed, switch on the
  right services and add your user to the right groups.

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
gentoo-helper ${VERSION}: simple menus for everyday Gentoo package management

  gentoo-helper                  menus
  gentoo-helper update           update the whole system
  gentoo-helper install NAME     find and install a package
  gentoo-helper remove NAME      remove a package
  gentoo-helper clean            remove unneeded packages, free disk space
  gentoo-helper news             read Gentoo news
  gentoo-helper configs          review configuration file updates
  gentoo-helper flatpak          Flatpak apps
  gentoo-helper tasks            common tasks: printing, Wi-Fi, drivers, codecs, SSH, ...
  gentoo-helper help             this text

Set GENTOO_HELPER_UI=text to use plain text menus instead of dialog.
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
    if [[ ! -f /etc/gentoo-release ]] || ! have emerge; then
        echo "gentoo-helper only works on Gentoo Linux (emerge was not found)." >&2
        exit 1
    fi
}

ensure_root() {
    local self
    if [[ $EUID -eq 0 ]]; then return 0; fi
    self=$(readlink -f "${BASH_SOURCE[0]}")
    echo "Managing packages needs administrator rights; asking for your password."
    if have sudo; then exec sudo -- "$self" "$@"; fi
    if have doas; then exec doas -- "$self" "$@"; fi
    echo "Neither sudo nor doas is available. Run gentoo-helper as root." >&2
    exit 1
}

ui_init() {
    if [[ ${GENTOO_HELPER_UI:-} == "text" ]]; then UI="text"; return 0; fi
    if [[ ! -t 0 || ! -t 1 ]]; then UI="text"; return 0; fi
    if have dialog; then UI="dialog"; return 0; fi
    UI="text"
    if [[ -e ${STATE_DIR}/no-dialog ]]; then return 0; fi
    TITLE="Gentoo Helper"
    if ui_yesno "The menus are easier to use with the small 'dialog' program, which is not installed yet. Install it now? (usually under a minute)" y; then
        run_emerge dev-util/dialog
        if have dialog; then UI="dialog"; fi
    else
        touch "${STATE_DIR}/no-dialog"
        say "OK, using plain text menus. (Install dev-util/dialog any time to get the other menus.)"
    fi
}

main() {
    case "${1:-}" in
        -h|--help|help) usage; return 0 ;;
        --version) echo "gentoo-helper ${VERSION}"; return 0 ;;
    esac
    ensure_gentoo
    ensure_root "$@"
    mkdir -p "$STATE_DIR"
    touch "$LOG"
    WORK_DIR=$(mktemp -d /tmp/gentoo-helper.XXXXXX)
    trap cleanup EXIT
    trap 'cleanup; echo; exit 130' INT
    log "gentoo-helper ${VERSION} started: $*"
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
    if [[ $UI == "dialog" ]]; then clear_screen; fi
}

if [[ "${BASH_SOURCE[0]:-}" == "$0" || -z "${BASH_SOURCE[0]:-}" ]]; then
    main "$@"
fi
