#!/usr/bin/env bash
# Builds the two single-file installers from the shared sources in src/.
#
#   gentoo-install.sh       console front end
#   gentoo-install-tui.sh   dialog/whiptail front end (same questions and engine)
#
# Both embed gentoo-helper.sh, which is also published on its own.
#
# Edit files in src/, then run ./build.sh and commit the results. Both installers
# must stay single files so they can be downloaded with one curl command.
#
#   ./build.sh           build both files
#   ./build.sh --check   fail if the committed files differ from a fresh build
#   ./build.sh --lint    run ShellCheck on both built files
set -euo pipefail
cd "$(dirname "$0")"

# gentoo-helper.sh (the package manager helper) is embedded into both installers,
# which write it to /usr/local/bin/gentoo-helper on the new system.
readonly HELPER_EOF="GENTOO_HELPER_SCRIPT_EOF"
embed=$(mktemp)
trap 'rm -f "$embed"' EXIT
if grep -qx "$HELPER_EOF" gentoo-helper.sh; then
    echo "gentoo-helper.sh contains the line ${HELPER_EOF}; cannot embed it." >&2
    exit 1
fi
{
    echo ""
    echo "# ----------------------------------------------------------------------------"
    echo "# gentoo-helper, embedded by build.sh from gentoo-helper.sh (do not edit here)"
    echo "# ----------------------------------------------------------------------------"
    echo "install_gentoo_helper() {"
    echo "    mkdir -p /usr/local/bin"
    echo "    cat >/usr/local/bin/gentoo-helper <<'${HELPER_EOF}'"
    cat gentoo-helper.sh
    echo "${HELPER_EOF}"
    echo "    chmod 755 /usr/local/bin/gentoo-helper"
    echo "}"
} >"$embed"

shared=(src/10-core.sh src/20-detect.sh src/30-questions.sh src/40-install.sh src/50-chroot.sh "$embed")
cli=("${shared[@]}" src/90-main-cli.sh)
tui=("${shared[@]}" src/60-tui.sh src/91-main-tui.sh)

build() {
    local out=$1
    shift
    cat "$@" >"$out.tmp"
    bash -n "$out.tmp"
    chmod 755 "$out.tmp"
    mv "$out.tmp" "$out"
}

if [[ ${1:-} == "--lint" ]]; then
    # SC2329 is excluded for the TUI build only: the TUI replaces the console
    # prompt functions with wrappers, and ShellCheck cannot see that the
    # originals are still called through their cli_* copies (made with eval).
    shellcheck -s bash -S style gentoo-install.sh
    shellcheck -s bash -S style -e SC2329 gentoo-install-tui.sh
    shellcheck -s bash -S style gentoo-helper.sh
    echo "ShellCheck: no findings."
    exit 0
fi

if [[ ${1:-} == "--check" ]]; then
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp" "$embed"' EXIT
    cat "${cli[@]}" >"$tmp/cli"
    cat "${tui[@]}" >"$tmp/tui"
    cmp -s "$tmp/cli" gentoo-install.sh || { echo "gentoo-install.sh is out of date: run ./build.sh" >&2; exit 1; }
    cmp -s "$tmp/tui" gentoo-install-tui.sh || { echo "gentoo-install-tui.sh is out of date: run ./build.sh" >&2; exit 1; }
    echo "Both installers match src/."
    exit 0
fi

build gentoo-install.sh "${cli[@]}"
build gentoo-install-tui.sh "${tui[@]}"
echo "Built gentoo-install.sh ($(wc -l <gentoo-install.sh) lines) and gentoo-install-tui.sh ($(wc -l <gentoo-install-tui.sh) lines)."
