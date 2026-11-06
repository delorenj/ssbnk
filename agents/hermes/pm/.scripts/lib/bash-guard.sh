# shellcheck shell=bash
# Bash >= 4.4 guard for every provisioning entrypoint.
#
# The scaffold needs bash 4.4: named file descriptors (`exec {fd}>`), namerefs
# (`local -n`), associative arrays, `mapfile -d ''` (lib/fleet-env.sh) and
# `${x,,}`. macOS ships /bin/bash 3.2, where those fail at RUN time with
# misleading errors (`exec: {FD}: not found`, `local: -n: invalid option`)
# after the script has already done part of its work.
#
# Source this file at TOP LEVEL, before any side effect and before an
# entrypoint captures/unsets invocation-only inputs (30-telegram.sh,
# 31-slack.sh): under an old bash it re-execs the calling script, with its
# original arguments, under the first bash >= 4.4 it finds, so nothing done
# before this point may be lost. When none exists it exits with instructions.
#
# Search order: $HERMES_TEMPLATE_BASH, `bash` on PATH, Homebrew
# (/opt/homebrew/bin/bash, /usr/local/bin/bash), MacPorts (/opt/local/bin/bash).
#
# Deliberately written in bash-3.2 syntax: this is the one file that must run
# under the bash it is guarding against.
if [ -z "${BASH_VERSINFO:-}" ] \
  || [ "${BASH_VERSINFO[0]}" -lt 4 ] \
  || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
  __hat_modern_bash=""
  # A re-exec'd child that is somehow still old must not loop.
  if [ "${HERMES_TEMPLATE_BASH_REEXEC:-}" != "$$" ]; then
    for __hat_candidate in "${HERMES_TEMPLATE_BASH:-}" "$(command -v bash 2>/dev/null || true)" \
        /opt/homebrew/bin/bash /usr/local/bin/bash /opt/local/bin/bash; do
      [ -n "$__hat_candidate" ] && [ -f "$__hat_candidate" ] && [ -x "$__hat_candidate" ] || continue
      # The probe child is a separate process: give it nothing but PATH and
      # HOME, so an invocation credential still exported by the caller (the
      # channel steps unset theirs only after this guard) never reaches it.
      # shellcheck disable=SC2016  # expanded by the candidate, not here
      if (
        for __hat_exported in $(compgen -e); do
          case "$__hat_exported" in PATH|HOME) ;; *) export -n "$__hat_exported" ;; esac
        done
        "$__hat_candidate" -c '[ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 4 ]; }'
      ) >/dev/null 2>&1; then
        __hat_modern_bash="$__hat_candidate"
        break
      fi
    done
  fi
  if [ -n "$__hat_modern_bash" ] && [ -f "$0" ]; then
    HERMES_TEMPLATE_BASH_REEXEC=$$
    export HERMES_TEMPLATE_BASH_REEXEC
    exec "$__hat_modern_bash" "$0" "$@"
  fi
  printf '%s: bash >= 4.4 is required; this is bash %s (%s).\n' \
    "${0##*/}" "${BASH_VERSION:-unknown}" "${BASH:-sh}" >&2
  printf '%s\n' \
    '  macOS ships bash 3.2 at /bin/bash. Install a current bash (brew install bash), then either' \
    '  put /opt/homebrew/bin ahead of /bin on PATH, or set HERMES_TEMPLATE_BASH=/opt/homebrew/bin/bash.' >&2
  exit 1
fi
unset HERMES_TEMPLATE_BASH_REEXEC
