#!/usr/bin/env bash
# logger.sh - Registro de eventos relevantes
# Requer a variável de ambiente BACKUP_LOG definida pelo chamador.
set -euo pipefail

log_info() {
  local msg="$1"
  echo "[$(timestamp)] ${msg}" | tee -a "${BACKUP_LOG:?BACKUP_LOG não definido}"
}

log_error() {
  local msg="$1"
  echo "[$(timestamp)] ERRO: ${msg}" | tee -a "${BACKUP_LOG:?BACKUP_LOG não definido}" >&2
}
