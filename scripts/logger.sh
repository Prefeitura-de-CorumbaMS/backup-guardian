#!/usr/bin/env bash
# logger.sh - Registro de eventos relevantes
# Requer as variáveis de ambiente BACKUP_LOG e ERRO_LOG definidas pelo chamador.
set -euo pipefail

log_info() {
  local msg="$1"
  echo "[$(timestamp)] ${msg}" >> "${BACKUP_LOG:?BACKUP_LOG não definido}"
}

log_error() {
  local msg="$1"
  echo "[$(timestamp)] ERRO: ${msg}" >> "${ERRO_LOG:?ERRO_LOG não definido}"
  echo "[$(timestamp)] ERRO: ${msg}" >> "${BACKUP_LOG:?BACKUP_LOG não definido}"
}
