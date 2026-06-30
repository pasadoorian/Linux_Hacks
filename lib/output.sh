#!/usr/bin/env bash
# Shared, dependency-free terminal-output helpers for the linux_hacks scripts.
#
# Color turns on only when stdout is an interactive TTY and the user has not
# opted out (NO_COLOR set, TERM=dumb, or UPDATE_NO_COLOR=1). Diagnostics
# (warn/err/alert) always go to stderr. Two optional globals tune verbosity:
#   VERBOSE=true  -> run_quiet streams full command output
#   QUIET=true    -> suppress section/step/ok/note (warnings + errors still show)

output_setup_colors() {
    if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" && "${UPDATE_NO_COLOR:-0}" != "1" ]]; then
        OUT_B=$'\033[1m';   OUT_DIM=$'\033[2m'
        OUT_GRN=$'\033[32m'; OUT_YLW=$'\033[33m'; OUT_RED=$'\033[31m'; OUT_CYN=$'\033[36m'
        OUT_NC=$'\033[0m'
    else
        OUT_B='' OUT_DIM='' OUT_GRN='' OUT_YLW='' OUT_RED='' OUT_CYN='' OUT_NC=''
    fi
}
output_setup_colors

# Section header. If the caller has set STEP_TOTAL (> 0), each call auto-numbers
# itself "[n/total]" by incrementing STEP_CUR; otherwise it prints a plain
# header. This lets main() show progress while unit tests that call a function
# directly still get a clean header.
section() {
    [[ "${QUIET:-false}" == true ]] && return 0
    if [[ -n "${STEP_TOTAL:-}" ]] && (( STEP_TOTAL > 0 )); then
        STEP_CUR=$(( ${STEP_CUR:-0} + 1 ))
        printf '\n%s▸ [%s/%s] %s%s\n' "$OUT_B$OUT_CYN" "$STEP_CUR" "$STEP_TOTAL" "$1" "$OUT_NC"
    else
        printf '\n%s▸ %s%s\n' "$OUT_B$OUT_CYN" "$1" "$OUT_NC"
    fi
}

ok()   { [[ "${QUIET:-false}" == true ]] && return 0; printf '  %s✓%s %s\n' "$OUT_GRN" "$OUT_NC" "$1"; }
note() { [[ "${QUIET:-false}" == true ]] && return 0; printf '  %s%s%s\n'   "$OUT_DIM" "$1" "$OUT_NC"; }
warn() { printf '  %s!%s %s\n' "$OUT_YLW" "$OUT_NC" "$1" >&2; }
err()  { printf '  %s✗%s %s\n' "$OUT_RED" "$OUT_NC" "$1" >&2; }

# Loud banner for the most serious findings (still advisory; never aborts).
alert() {
    {
        printf '%s%s  !! %s%s\n' "$OUT_B" "$OUT_RED" "$1" "$OUT_NC"
    } >&2
}

# run_quiet "<success msg>" cmd...
# Run a noisy command showing only a one-line status. On failure (or when
# VERBOSE=true) the full captured output is shown. Returns the command's status.
run_quiet() {
    local msg="$1"; shift
    if [[ "${VERBOSE:-false}" == true ]]; then
        if "$@"; then return 0; else return $?; fi
    fi
    local out rc=0
    if out="$("$@" 2>&1)"; then rc=0; else rc=$?; fi
    if (( rc == 0 )); then
        ok "$msg"
    else
        err "$msg failed (exit $rc):"
        printf '%s\n' "$out" >&2
    fi
    return "$rc"
}

# --- End-of-run summary -------------------------------------------------------
SUMMARY_LINES=()
NEXT_STEPS=()
summary_add() { SUMMARY_LINES+=("$1"); }
next_step()   { NEXT_STEPS+=("$1"); }

print_summary() {
    [[ "${QUIET:-false}" == true ]] && return 0
    printf '\n%s▸ Summary%s\n' "$OUT_B$OUT_CYN" "$OUT_NC"
    if ((${#SUMMARY_LINES[@]})); then
        local l; for l in "${SUMMARY_LINES[@]}"; do
            printf '  %s✓%s %s\n' "$OUT_GRN" "$OUT_NC" "$l"
        done
    else
        printf '  %snothing to report%s\n' "$OUT_DIM" "$OUT_NC"
    fi
    if ((${#NEXT_STEPS[@]})); then
        printf '\n'
        local s; for s in "${NEXT_STEPS[@]}"; do
            printf '  %s→%s %s\n' "$OUT_CYN" "$OUT_NC" "$s"
        done
    fi
}
