#!/usr/bin/env bash
# verify.sh - Lógica de decisão quando não há alteração de conteúdo
set -euo pipefail

# handle_no_change <estado.json>
# Registra que não houve alterações e mantém backup congelado
handle_no_change() {
  local state_file="$1"
  local ultimo_backup
  ultimo_backup=$(read_state_field "$state_file" ultimoBackup)
  
  if [[ -n "$ultimo_backup" ]]; then
    log_info "Sem alterações detectadas. Backup não necessário."
    log_info "Último backup permanece congelado: ${ultimo_backup}"
  else
    log_info "Sem alterações detectadas (primeira execução sem mudanças)."
  fi
}
