#!/usr/bin/env bash
# Builds the two single-file installers from the shared sources in src/.
#
#   gentoo_install.sh       console front end
#   gentoo_install_tui.sh   dialog/whiptail front end (same questions and engine)
#
# Both embed gentoo_helper.sh, which is also published on its own.
#
# Edit files in src/, then run this and commit the results. Both installers
# must stay single files so they can be downloaded with one curl command.
#
#   bash build.sh        build both files
#   bash build.sh -c     check: fail if the committed files differ from a fresh build
#   bash build.sh -l     lint: run ShellCheck on both built files and the helper
#   bash build.sh -h     this help
set -euo pipefail

usage() {
    printf '%s\n' "Usage: bash build.sh [-c | -l | -h]" \
        "  (no option)  build gentoo_install.sh and gentoo_install_tui.sh from src/" \
        "  -c           check that the committed installers match a fresh build" \
        "  -l           run ShellCheck on the installers and gentoo_helper.sh" \
        "  -h           show this help"
}

mode="build"
while getopts ':clh' opt; do
    case "$opt" in
        c) mode="check" ;;
        l) mode="lint" ;;
        h) usage; exit 0 ;;
        *) usage >&2; exit 1 ;;
    esac
done
shift $(( OPTIND - 1 ))

required=(cat grep mktemp cmp wc chmod mv rm)
if [ "$mode" = "lint" ]; then required+=(shellcheck); fi
missing=()
for c in "${required[@]}"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
done
if [ "${#missing[@]}" -gt 0 ]; then
    printf 'build.sh: missing commands: %s\n' "${missing[*]}" >&2
    exit 1
fi

cd -- "$(dirname -- "$0")" || exit 1

if [ "$mode" = "lint" ]; then
    shellcheck -s bash -S style gentoo_install.sh
    shellcheck -s bash -S style gentoo_install_tui.sh
    shellcheck -s bash -S style gentoo_helper.sh
    shellcheck -s bash -S style build.sh
    printf '%s\n' "ShellCheck: no findings."
    exit 0
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/gentoo_build.XXXXXX")
trap 'rm -rf -- "$work"' EXIT

# gentoo_helper.sh (the package manager helper) is embedded into both
# installers, which write it to /usr/local/bin/gentoo_helper on the new system.
readonly HELPER_EOF="GENTOO_HELPER_SCRIPT_EOF"
embed="$work/embed.sh"
if grep -qx "$HELPER_EOF" gentoo_helper.sh; then
    printf 'gentoo_helper.sh contains the line %s; cannot embed it.\n' "$HELPER_EOF" >&2
    exit 1
fi
{
    printf '\n'
    printf '%s\n' "# ----------------------------------------------------------------------------" \
        "# gentoo_helper, embedded by build.sh from gentoo_helper.sh (do not edit here)" \
        "# ----------------------------------------------------------------------------" \
        "install_gentoo_helper() {" \
        "    mkdir -p /usr/local/bin" \
        "    cat >/usr/local/bin/gentoo_helper <<'${HELPER_EOF}'"
    cat gentoo_helper.sh
    printf '%s\n' "${HELPER_EOF}" \
        "    chmod 755 /usr/local/bin/gentoo_helper" \
        "}"
} >"$embed"

shared=(src/10_core.sh src/20_detect.sh src/30_questions.sh src/40_install.sh src/50_chroot.sh "$embed")
cli=("${shared[@]}" src/90_main_cli.sh)
tui=("${shared[@]}" src/60_tui.sh src/91_main_tui.sh)

# build OUTPUT PART...: concatenate the parts, syntax check, then replace OUTPUT.
build() {
    local out=$1
    shift
    cat -- "$@" >"$work/out"
    bash -n "$work/out"
    chmod 755 -- "$work/out"
    mv -f -- "$work/out" "$out"
}

if [ "$mode" = "check" ]; then
    cat -- "${cli[@]}" >"$work/cli"
    cat -- "${tui[@]}" >"$work/tui"
    if ! cmp -s "$work/cli" gentoo_install.sh; then
        printf '%s\n' "gentoo_install.sh is out of date: run bash build.sh" >&2
        exit 1
    fi
    if ! cmp -s "$work/tui" gentoo_install_tui.sh; then
        printf '%s\n' "gentoo_install_tui.sh is out of date: run bash build.sh" >&2
        exit 1
    fi
    printf '%s\n' "Both installers match src/."
    exit 0
fi

build gentoo_install.sh "${cli[@]}"
build gentoo_install_tui.sh "${tui[@]}"
printf 'Built gentoo_install.sh (%s lines) and gentoo_install_tui.sh (%s lines).\n' \
    "$(wc -l <gentoo_install.sh)" "$(wc -l <gentoo_install_tui.sh)"
