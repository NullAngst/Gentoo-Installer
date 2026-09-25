
# ----------------------------------------------------------------------------
# Entry point
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
        echo "  curl -fsSLO https://raw.githubusercontent.com/NullAngst/Gentoo-Installer/main/gentoo-install.sh" >&2
        echo "  bash gentoo-install.sh" >&2
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
            log "gentoo-install.sh ${SCRIPT_VERSION} resuming"
            detect_hardware
            resume_install
            ;;
        "")
            fresh_install
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
