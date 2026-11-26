
# ----------------------------------------------------------------------------
# Console front end: the prompt and output names used throughout the
# installer map straight to the console versions (src/10_core.sh).
# ----------------------------------------------------------------------------
say()              { cli_say "$@"; }
say_pre()          { cli_say_pre "$@"; }
section()          { cli_section "$@"; }
subsection()       { cli_subsection "$@"; }
info()             { cli_info "$@"; }
ok()               { cli_ok "$@"; }
warn()             { cli_warn "$@"; }
die()              { cli_die "$@"; }
run()              { cli_run "$@"; }
choose()           { cli_choose "$@"; }
choose_multi()     { cli_choose_multi "$@"; }
ask()              { cli_ask "$@"; }
ask_yn()           { cli_ask_yn "$@"; }
ask_password()     { cli_ask_password "$@"; }
pause()            { cli_pause; }
handoff_screen()   { cli_handoff_screen; }
ask_timezone()     { cli_ask_timezone; }
browse_timezones() { cli_browse_timezones; }
ui_install_phase() { :; }
ui_finish_phase()  { :; }

# ----------------------------------------------------------------------------
# Entry point
# ----------------------------------------------------------------------------
usage() {
    cat <<EOF
gentoo_install.sh ${SCRIPT_VERSION}: guided Gentoo Linux installer for amd64

Usage:
  bash gentoo_install.sh                 Start a new installation
  bash gentoo_install.sh -r, --resume    Continue after fixing a failed step
  bash gentoo_install.sh -h, --help      Show this help

Run it as root from the official Gentoo live image (minimal or LiveGUI).
Download it first, then run it. Piping it into bash does not work because
the installer reads your answers from the keyboard.
EOF
}


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
            "  curl -fsSLO https://raw.githubusercontent.com/NullAngst/Gentoo-Installer/refs/heads/main/gentoo_install.sh" \
            "  bash gentoo_install.sh" >&2
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
            log "gentoo_install.sh ${SCRIPT_VERSION} resuming"
            detect_hardware
            resume_install
            ;;
        *)
            fresh_install
            ;;
    esac
}

# Run main unless the file is being sourced (for example by a test harness).
if [ "${BASH_SOURCE[0]:-}" = "$0" ] || [ -z "${BASH_SOURCE[0]:-}" ]; then
    main "$@"
fi
