
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
