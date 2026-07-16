#!/usr/bin/env bash
# lock.sh - Controle de execução concorrente via backup.lock
set -euo pipefail

acquire_lock() {
  local lockfile="$1"
  if ! mkdir "$lockfile" 2>/dev/null; then
    echo "Lock já existente em ${lockfile}. Abortando execução." >&2
    return 1
  fi
  # shellcheck disable=SC2064
  trap "release_lock '${lockfile}'" EXIT INT TERM
  return 0
}

release_lock() {
  local lockfile="$1"
  rmdir "$lockfile" 2>/dev/null || true
}
