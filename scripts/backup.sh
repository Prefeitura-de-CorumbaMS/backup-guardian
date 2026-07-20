#!/usr/bin/env bash
# backup.sh - Orquestrador principal do Backup Guardian
# Suporta múltiplas aplicações via arquivos .conf, sem alteração deste código.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./utils.sh
source "$SCRIPT_DIR/utils.sh"
# shellcheck source=./logger.sh
source "$SCRIPT_DIR/logger.sh"
# shellcheck source=./lock.sh
source "$SCRIPT_DIR/lock.sh"
# shellcheck source=./state.sh
source "$SCRIPT_DIR/state.sh"
# shellcheck source=./hash.sh
source "$SCRIPT_DIR/hash.sh"
# shellcheck source=./mail.sh
source "$SCRIPT_DIR/mail.sh"
# shellcheck source=./verify.sh
source "$SCRIPT_DIR/verify.sh"

CONF_DIR="${BACKUP_GUARDIAN_CONF_DIR:-/etc/backup-guardian/conf.d}"

on_error() {
  local app_id="$1"
  local email_to="$2"
  local line="$3"
  local msg="Falha na execução (linha ${line})."
  log_error "$msg"
  if [[ -n "$email_to" ]]; then
    send_error_mail "$email_to" "backup.sh (${app_id})" "$msg"
  fi
}

# ============================================================================
# FUNÇÕES AUXILIARES
# ============================================================================
calculate_backup_size() {
  local items=("$@")
  local total_kb=0
  local path
  
  for item in "${items[@]}"; do
    path="${item%%|*}"
    if [[ -e "$path" ]]; then
      local size_kb
      size_kb=$(du -sk "$path" 2>/dev/null | awk '{print $1}')
      total_kb=$((total_kb + size_kb))
    fi
  done
  
  echo "$((total_kb / 1024))"
}

check_disk_space() {
  local target_dir="$1"
  local items_ref="$2"
  local email_to="$3"
  local app_name="$4"
  
  local available_mb used_mb total_mb
  available_mb=$(df -BM "$target_dir" | awk 'NR==2 {print $4}' | sed 's/M//')
  used_mb=$(df -BM "$target_dir" | awk 'NR==2 {print $3}' | sed 's/M//')
  total_mb=$(df -BM "$target_dir" | awk 'NR==2 {print $2}' | sed 's/M//')
  
  local backup_size_mb
  eval "backup_size_mb=\$(calculate_backup_size \"\${${items_ref}[@]}\")"
  
  local safety_margin_mb="${MIN_FREE_SPACE_MB:-51200}"
  local required_mb=$((backup_size_mb + safety_margin_mb))
  
  log_info "Verificação de espaço: Disponível=${available_mb}MB, Backup=${backup_size_mb}MB, Margem=${safety_margin_mb}MB, Necessário=${required_mb}MB"
  
  if [[ $available_mb -lt $required_mb ]]; then
    log_error "Espaço insuficiente. Disponível: ${available_mb}MB, Necessário: ${required_mb}MB (Backup: ${backup_size_mb}MB + Margem: ${safety_margin_mb}MB)"
    if [[ -n "$email_to" ]]; then
      send_disk_space_alert "$email_to" "$app_name" "$target_dir" "$available_mb" "$required_mb" "$backup_size_mb" "$safety_margin_mb"
    fi
    return 1
  fi
  
  return 0
}

get_previous_month() {
  local year month
  year=$(date +%Y)
  month=$(date +%m)
  month=$((10#$month))
  
  if [[ $month -eq 1 ]]; then
    year=$((year - 1))
    month=12
  else
    month=$((month - 1))
  fi
  
  printf "%04d-%02d" "$year" "$month"
}

retry_with_backoff() {
  local max_attempts=3
  local timeout=1
  local attempt=1
  
  while [[ $attempt -le $max_attempts ]]; do
    if "$@"; then
      return 0
    fi
    
    if [[ $attempt -lt $max_attempts ]]; then
      log_error "Tentativa ${attempt}/${max_attempts} falhou. Aguardando ${timeout}s..."
      sleep "$timeout"
      timeout=$((timeout * 2))
    fi
    
    attempt=$((attempt + 1))
  done
  
  return 1
}

validate_archive() {
  local archive="$1"
  
  if [[ ! -s "$archive" ]]; then
    log_error "Arquivo vazio ou inexistente: $(basename "$archive")"
    return 1
  fi
  
  local file_count
  file_count=$(tar -tzf "$archive" 2>/dev/null | wc -l)
  
  if [[ $? -ne 0 ]]; then
    log_error "Falha ao validar integridade do arquivo: $(basename "$archive")"
    return 1
  fi
  
  if [[ $file_count -eq 0 ]]; then
    log_error "Arquivo não contém nenhum item: $(basename "$archive")"
    return 1
  fi
  
  log_info "Arquivo validado com sucesso: $(basename "$archive") - ${file_count} itens"
  return 0
}

cleanup_temp_files() {
  local app_dir="$1"
  
  find "$app_dir" -name "*.tmp" -type f -mtime +1 2>/dev/null | while read -r tmpfile; do
    log_info "Removendo arquivo temporário órfão: $(basename "$tmpfile")"
    rm -f "$tmpfile"
  done
  
  if [[ -d "${app_dir}/backup_temp" ]]; then
    local temp_age_hours
    temp_age_hours=$(( ($(date +%s) - $(stat -c %Y "${app_dir}/backup_temp" 2>/dev/null || echo 0)) / 3600 ))
    if [[ $temp_age_hours -gt 24 ]]; then
      log_info "Removendo backup_temp/ órfão (${temp_age_hours}h)"
      rm -rf "${app_dir}/backup_temp"
    fi
  fi
}

cleanup_old_archives() {
  local app_dir="$1"
  local app_id="$2"
  local keep_months=12
  
  log_info "Limpando arquivos mensais com mais de ${keep_months} meses..."
  
  local cutoff_date
  cutoff_date=$(date -d "${keep_months} months ago" +%Y-%m)
  
  find "$app_dir" -name "${app_id}_backup_mensal_*.tar.gz" -type f 2>/dev/null | while read -r file; do
    if [[ $(basename "$file") =~ _([0-9]{4}-[0-9]{2})\.tar\.gz$ ]]; then
      local file_date="${BASH_REMATCH[1]}"
      if [[ "$file_date" < "$cutoff_date" ]]; then
        log_info "Removendo backup mensal antigo: $(basename "$file") (${file_date})"
        rm -f "$file"
      fi
    fi
  done
}

# ============================================================================
# PROCESSO PRINCIPAL
# ============================================================================
process_conf() {
  local conf_file="$1"

  local APP_NAME="" APP_ID="" BACKUP_ROOT="/backup-geral"
  local GROUP="projetos" DIR_PERMS="2775" EMAIL_TO=""
  local ITEMS=()

  # shellcheck disable=SC1090
  source "$conf_file"

  if [[ -z "$APP_ID" ]]; then
    echo "Configuração inválida (APP_ID vazio): ${conf_file}" >&2
    return 1
  fi

  if [[ ${#ITEMS[@]} -eq 0 ]]; then
    echo "Configuração inválida (ITEMS vazio): ${conf_file}" >&2
    return 1
  fi

  if [[ ! -d "$BACKUP_ROOT" ]]; then
    echo "Configuração inválida (BACKUP_ROOT não existe): ${BACKUP_ROOT}" >&2
    return 1
  fi

  if [[ ! -w "$BACKUP_ROOT" ]]; then
    echo "Configuração inválida (BACKUP_ROOT não é gravável): ${BACKUP_ROOT}" >&2
    return 1
  fi

  local APP_DIR="${BACKUP_ROOT}/${APP_ID}_arquivos"
  local BACKUP_DIARIO="${APP_DIR}/backup_diario"
  local HASH_FILE="${APP_DIR}/hash.sha256"
  local STATE_FILE="${APP_DIR}/estado.json"
  local LOCK_FILE="${APP_DIR}/backup.lock"

  export BACKUP_LOG="${APP_DIR}/backup.log"

  ensure_dir "$APP_DIR" "$DIR_PERMS" "$GROUP"
  
  cleanup_temp_files "$APP_DIR"

  if ! acquire_lock "$LOCK_FILE"; then
    log_error "Lock ativo em ${LOCK_FILE}. Execução abortada para ${APP_ID}."
    return 1
  fi

  cleanup_on_exit() {
    local exit_code=$?
    trap - ERR EXIT INT TERM
    
    if [[ $exit_code -ne 0 ]]; then
      log_error "Backup interrompido (exit code: ${exit_code})"
      
      local BACKUP_TEMP="${APP_DIR}/backup_temp"
      if [[ -d "$BACKUP_TEMP" && "$BACKUP_TEMP" == *"/backup_temp" && -n "$BACKUP_TEMP" ]]; then
        log_info "Removendo backup incompleto: backup_temp/"
        rm -rf "$BACKUP_TEMP"
      fi
    fi
    
    release_lock "$LOCK_FILE"
  }

  trap 'on_error "$APP_ID" "$EMAIL_TO" "$LINENO"' ERR
  trap 'cleanup_on_exit' EXIT INT TERM

  init_state "$STATE_FILE"

  local old_hash=""
  [[ -f "$HASH_FILE" ]] && old_hash=$(cat "$HASH_FILE")

  local new_hash
  new_hash=$(compute_content_hash "${ITEMS[@]}")
  if [[ -n "$old_hash" && "$old_hash" == "$new_hash" ]]; then
    handle_no_change "$STATE_FILE"
  else
    # ========================================================================
    # VERIFICAÇÃO: Espaço em disco
    # ========================================================================
    if ! check_disk_space "$APP_DIR" "ITEMS" "$EMAIL_TO" "$APP_NAME"; then
      log_error "Backup abortado: espaço insuficiente"
      return 1
    fi
    
    # ========================================================================
    # PASSO 1: VERIFICAR MUDANÇA DE MÊS (ANTES de modificar backup)
    # ========================================================================
    local mes_atual mes_registrado
    mes_atual=$(current_month)
    mes_registrado=$(read_state_field "$STATE_FILE" mesBackup)
    
    local criar_arquivo_mensal=false
    local archive_mensal=""
    
    if [[ -n "$mes_registrado" && "$mes_registrado" != "$mes_atual" ]]; then
      criar_arquivo_mensal=true
      local mes_anterior
      mes_anterior=$(get_previous_month)
      archive_mensal="${APP_DIR}/${APP_ID}_backup_mensal_${mes_anterior}.tar.gz"
      log_info "Mudança de mês: ${mes_registrado} → ${mes_atual}"
    fi
    
    # ========================================================================
    # PASSO 2: CRIAR ARQUIVO MENSAL (tar.gz do Último backup do mês anterior)
    # ========================================================================
    if [[ "$criar_arquivo_mensal" == true ]]; then
      if [[ -d "$BACKUP_DIARIO" ]]; then
        log_info "Mudança de mês detectada: ${mes_registrado} → ${mes_atual}"
        
        # Verificar espaço para ZIP mensal
        local backup_dir_size
        backup_dir_size=$(du -sm "$BACKUP_DIARIO" | cut -f1)
        local estimated_zip_size=$((backup_dir_size / 2))
        local zip_overhead=$((estimated_zip_size + backup_dir_size))
        
        local available_mb
        available_mb=$(df -BM "$APP_DIR" | awk 'NR==2 {print $4}' | sed 's/M//')
        
        if [[ $available_mb -lt $((zip_overhead + MIN_FREE_SPACE_MB)) ]]; then
          log_error "Espaço insuficiente para criar ZIP mensal"
          log_error "Necessário: $((zip_overhead + MIN_FREE_SPACE_MB)) MB"
          log_error "Disponível: ${available_mb} MB"
          log_error "Pulando criação de ZIP mensal. Backup diário continuará."
          
          if [[ -n "$EMAIL_TO" ]]; then
            send_disk_space_alert "$EMAIL_TO" "$APP_NAME" "$APP_DIR" "$available_mb" \
              "$((zip_overhead + MIN_FREE_SPACE_MB))" "$backup_dir_size" "$MIN_FREE_SPACE_MB"
          fi
          
          criar_arquivo_mensal=false
        else
          log_info "Criando ZIP mensal do mês anterior: $(basename "$archive_mensal")"
        fi
      fi
      
      if [[ "$criar_arquivo_mensal" == true && -d "$BACKUP_DIARIO" ]]; then
        local archive_temp="${archive_mensal}.tmp"
        
        if tar -czf "$archive_temp" -C "$BACKUP_DIARIO" . 2>/dev/null; then
          if validate_archive "$archive_temp"; then
            if mv -f "$archive_temp" "$archive_mensal"; then
              local size
              size=$(du -h "$archive_mensal" | cut -f1)
              log_info "ZIP mensal criado com sucesso: $(basename "$archive_mensal") (${size})"
              
              # Cleanup de ZIPs antigos ANTES de deletar backup_diario/
              cleanup_old_archives "$APP_DIR" "$APP_ID"
              
              # DELETAR backup_diario/ APENAS após sucesso completo
              log_info "Deletando backup diário (já preservado no ZIP mensal)"
              rm -rf "$BACKUP_DIARIO"
            else
              log_error "Falha ao mover ZIP temporário para destino final"
              rm -f "$archive_temp"
              return 1
            fi
          else
            log_error "ZIP falhou na validação de integridade"
            rm -f "$archive_temp"
            return 1
          fi
        else
          log_error "Falha ao criar ZIP mensal (tar.gz)"
          rm -f "$archive_temp"
          return 1
        fi
      else
        log_info "Backup diário não existe. Pulando criação de ZIP mensal."
      fi
      
      write_state "$STATE_FILE" "mesBackup:str=${mes_atual}"
    elif [[ -z "$mes_registrado" ]]; then
      log_info "Primeira execução. Mês inicial: ${mes_atual}"
      write_state "$STATE_FILE" "mesBackup:str=${mes_atual}"
    fi
    
    # ========================================================================
    # PASSO 3: BACKUP DIÁRIO (Substitui backup_diario/)
    # ========================================================================
    log_info "Iniciando backup diário..."
    
    local BACKUP_TEMP="${APP_DIR}/backup_temp"
    
    if ! mkdir -p "$BACKUP_TEMP"; then
      log_error "Falha ao criar diretório temporário"
      return 1
    fi
    
    local item origem destino dest_path
    local erros=0
    local total_items=${#ITEMS[@]}
    local items_copiados=0
    
    for item in "${ITEMS[@]}"; do
      if [[ ! "$item" =~ ^[^|]+\|[^|]+$ ]]; then
        log_error "Formato inválido: ${item}"
        ((erros++))
        continue
      fi
      
      origem="${item%%|*}"
      destino="${item##*|}"
      
      if [[ -z "$origem" || -z "$destino" ]]; then
        log_error "Origem ou destino vazio: ${item}"
        ((erros++))
        continue
      fi
      
      if [[ ! -e "$origem" ]]; then
        log_error "Caminho não encontrado: ${origem}"
        ((erros++))
        continue
      fi
      
      dest_path="${BACKUP_TEMP}/${destino}"
      
      if ! mkdir -p "$(dirname "$dest_path")"; then
        log_error "Falha ao criar diretório: $(dirname "$dest_path")"
        ((erros++))
        continue
      fi
      
      if retry_with_backoff cp -a "$origem" "$dest_path"; then
        ((items_copiados++))
      else
        log_error "Falha ao copiar: ${origem}"
        ((erros++))
      fi
    done
    
    if [[ $items_copiados -eq 0 ]]; then
      log_error "CRÍTICO: Nenhum item copiado"
      return 1
    fi
    
    # ========================================================================
    # PASSO 4: ATUALIZAR BACKUP DIÁRIO (Substitui backup_diario/)
    # ========================================================================
    
    # BUG #9 CORRIGIDO: NÃO fazer swap se houver erros
    if [[ $erros -gt 0 ]]; then
      log_error "Backup parcial rejeitado: ${erros} erro(s). ${items_copiados}/${total_items} itens."
      log_error "Backup anterior PRESERVADO (não sobrescrito com backup incompleto)"
      log_info "Hash NÃO atualizado - forçará retry na próxima execução"
      
      rm -rf "$BACKUP_TEMP"
      
      if [[ -n "$EMAIL_TO" ]]; then
        send_partial_backup_mail "$EMAIL_TO" "$APP_NAME" "$items_copiados" "$total_items" "$erros" "$BACKUP_LOG"
      fi
      
      write_state "$STATE_FILE" "ultimoBackup:str=$(timestamp)"
      return 1
    fi
    
    # Backup completo: substituir backup_diario/
    log_info "Backup completo: ${items_copiados}/${total_items} itens copiados"
    
    if [[ -d "$BACKUP_DIARIO" ]]; then
      rm -rf "$BACKUP_DIARIO"
    fi
    
    mv "$BACKUP_TEMP" "$BACKUP_DIARIO" || {
      log_error "Falha ao mover backup_temp para backup_diario"
      return 1
    }
    
    # ========================================================================
    # PASSO 5: ATUALIZAR ESTADO E NOTIFICAR
    # ========================================================================
    log_info "Backup concluído com sucesso: ${items_copiados}/${total_items} itens."
    
    echo "$new_hash" > "$HASH_FILE"
    
    write_state "$STATE_FILE" \
      "ultimoHash:str=${new_hash}" \
      "ultimoBackup:str=$(timestamp)"
    
    if [[ -n "$EMAIL_TO" ]]; then
      send_backup_mail "$EMAIL_TO" "$APP_NAME" "$BACKUP_DIARIO" "$items_copiados" "$total_items"
    fi
  fi
}

main() {
  if [[ ! -d "$CONF_DIR" ]]; then
    echo "Diretório de configuração não encontrado: ${CONF_DIR}" >&2
    exit 1
  fi

  local conf found=0 status=0
  for conf in "$CONF_DIR"/*.conf; do
    [[ -e "$conf" ]] || continue
    found=1
    if ! process_conf "$conf"; then
      status=1
    fi
  done

  if [[ "$found" -eq 0 ]]; then
    echo "Nenhum arquivo .conf encontrado em ${CONF_DIR}" >&2
    exit 1
  fi

  exit "$status"
}

main "$@"
