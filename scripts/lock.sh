#!/usr/bin/env bash
# lock.sh - Controle de execução concorrente via backup.lock
set -euo pipefail

acquire_lock() {
  local lockfile="$1"
  if [[ -e "$lockfile" ]]; then
    echo "Lock já existente em ${lockfile}. Abortando execução." >&2
    return 1
  fi
  echo "$$" > "$lockfile"
  # shellcheck disable=SC2064
  trap "release_lock '${lockfile}'" EXIT INT TERM
  return 0
}

release_lock() {
  local lockfile="$1"
  rm -f "$lockfile"
}
