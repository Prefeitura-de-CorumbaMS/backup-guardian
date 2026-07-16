#!/usr/bin/env bash
# utils.sh - Funções utilitárias compartilhadas pelo Backup Guardian
set -euo pipefail

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Este script deve ser executado como root." >&2
    exit 1
  fi
}

timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

current_month() {
  date '+%Y-%m'
}

atomic_move() {
  local src="$1"
  local dest="$2"
  mv -f "$src" "$dest"
}

ensure_dir() {
  local dir="$1"
  local perms="${2:-2775}"
  local group="${3:-}"
  mkdir -p "$dir"
  chmod "$perms" "$dir"
  if [[ -n "$group" ]] && getent group "$group" >/dev/null 2>&1; then
    chgrp "$group" "$dir"
  fi
}
