# Shared ANSI colors for build/verify scripts (bash; works when invoked from fish).
# Honors NO_COLOR; enabled on TTY or when FORCE_COLOR=1.

_term_ui_init() {
    if [[ -n "${NO_COLOR:-}" ]]; then
        TUI_RESET= TUI_RED= TUI_GREEN= TUI_YELLOW= TUI_CYAN= TUI_BOLD=
        TUI_USE_COLOR=0
        return 0
    fi
    if [[ -t 1 ]] || [[ -n "${FORCE_COLOR:-}" ]]; then
        TUI_RESET=$'\033[0m'
        TUI_RED=$'\033[31m'
        TUI_GREEN=$'\033[32m'
        TUI_YELLOW=$'\033[33m'
        TUI_CYAN=$'\033[36m'
        TUI_BOLD=$'\033[1m'
        TUI_USE_COLOR=1
    else
        TUI_RESET= TUI_RED= TUI_GREEN= TUI_YELLOW= TUI_CYAN= TUI_BOLD=
        TUI_USE_COLOR=0
    fi
}

tui_section() {
    _term_ui_init
    printf '%b\n' "${TUI_BOLD}${TUI_CYAN}$*${TUI_RESET}"
}

tui_step() {
    _term_ui_init
    printf '%b\n' "${TUI_BOLD}==>${TUI_RESET} $*"
}

tui_ok() {
    _term_ui_init
    printf '  %bok%b  %s\n' "${TUI_GREEN}" "${TUI_RESET}" "$*"
}

tui_fail() {
    _term_ui_init
    printf '  %bFAIL%b  %s\n' "${TUI_RED}" "${TUI_RESET}" "$*" >&2
}

tui_skip() {
    _term_ui_init
    printf '  %bskip%b  %s\n' "${TUI_YELLOW}" "${TUI_RESET}" "$*"
}

tui_error() {
    _term_ui_init
    printf '%bERROR:%b %s\n' "${TUI_BOLD}${TUI_RED}" "${TUI_RESET}" "$*" >&2
}

tui_done() {
    _term_ui_init
    printf '%b\n' "${TUI_BOLD}${TUI_GREEN}$*${TUI_RESET}"
}
