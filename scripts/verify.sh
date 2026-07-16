#!/usr/bin/env bash
# verify.sh - Lógica de decisão quando não há alteração de conteúdo
set -euo pipefail

# handle_no_change <estado.json>
# Incrementa o contador de verificações sem mudança. A partir da 3ª verificação
# consecutiva sem mudança, registra "Aguardando novas alterações." apenas uma vez.
handle_no_change() {
  local state_file="$1"
  local counter aguardando

  counter=$(read_state_field "$state_file" contadorSemMudanca)
  aguardando=$(read_state_field "$state_file" aguardando)
  counter=$((counter + 1))

  if [[ "$counter" -ge 3 ]]; then
    if [[ "$aguardando" != "true" ]]; then
      log_info "Aguardando novas alterações."
    fi
    write_state "$state_file" "contadorSemMudanca:num=${counter}" "aguardando:bool=true"
  else
    log_info "Nenhuma alteração."
    write_state "$state_file" "contadorSemMudanca:num=${counter}" "aguardando:bool=false"
  fi
}
