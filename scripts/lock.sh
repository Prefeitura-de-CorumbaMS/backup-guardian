#!/usr/bin/env bash
# lock.sh - Controle de execução concorrente via backup.lock
set -euo pipefail

acquire_lock() {
  local lockfile="$1"
  local max_age_hours=24
  
  if [[ -d "$lockfile" ]]; then
    # Verifica idade do lock
    local lock_age_hours=0
    if [[ -e "$lockfile" ]]; then
      lock_age_hours=$(( ($(date +%s) - $(stat -c %Y "$lockfile" 2>/dev/null || echo $(date +%s))) / 3600 ))
    fi
    
    if [[ $lock_age_hours -gt $max_age_hours ]]; then
      echo "Lock órfão detectado (${lock_age_hours}h). Removendo..." >&2
      rmdir "$lockfile" 2>/dev/null || rm -rf "$lockfile"
    else
      echo "Lock ativo (${lock_age_hours}h). Backup em execução ou travado." >&2
      return 1
    fi
  fi
  
  if ! mkdir "$lockfile" 2>/dev/null; then
    echo "Falha ao criar lock em ${lockfile}." >&2
    return 1
  fi
  
  return 0
}

release_lock() {
  local lockfile="$1"
  rmdir "$lockfile" 2>/dev/null || true
}
