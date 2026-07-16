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
check_disk_space() {
  local target_dir="$1"
  local required_mb="$2"
  local email_to="$3"
  local app_name="$4"
  
  local available_mb
  available_mb=$(df -BM "$target_dir" | awk 'NR==2 {print $4}' | sed 's/M//')
  
  if [[ $available_mb -lt $required_mb ]]; then
    log_error "Espaço insuficiente. Disponível: ${available_mb}MB, Necessário: ${required_mb}MB"
    if [[ -n "$email_to" ]]; then
      send_disk_space_alert "$email_to" "$app_name" "$target_dir" "$available_mb" "$required_mb"
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

cleanup_old_archives() {
  local app_dir="$1"
  local app_id="$2"
  local keep_months=12
  
  log_info "Limpando arquivos mensais com mais de ${keep_months} meses..."
  find "$app_dir" -name "${app_id}_backup_mensal_*.tar.gz" -type f -mtime +$((keep_months * 30)) -delete 2>/dev/null || true
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

  local APP_DIR="${BACKUP_ROOT}/${APP_ID}_arquivos"
  local BACKUP_DIR="${APP_DIR}/backup_atual"
  local MENSAL_ZIP="${APP_DIR}/${APP_ID}_backup_mensal_$(date +%Y-%m).zip"
  local HASH_FILE="${APP_DIR}/hash.sha256"
  local STATE_FILE="${APP_DIR}/estado.json"
  local LOCK_FILE="${APP_DIR}/backup.lock"

  export BACKUP_LOG="${APP_DIR}/backup.log"
  export ERRO_LOG="${APP_DIR}/erro.log"

  ensure_dir "$APP_DIR" "$DIR_PERMS" "$GROUP"

  if ! acquire_lock "$LOCK_FILE"; then
    log_error "Lock ativo em ${LOCK_FILE}. Execução abortada para ${APP_ID}."
    return 1
  fi

  trap 'on_error "$APP_ID" "$EMAIL_TO" "$LINENO"' ERR

  init_state "$STATE_FILE"

  local old_hash=""
  [[ -f "$HASH_FILE" ]] && old_hash=$(cat "$HASH_FILE")

  local new_hash
  new_hash=$(compute_content_hash "${ITEMS[@]}")
  if [[ -n "$old_hash" && "$old_hash" == "$new_hash" ]]; then
    handle_no_change "$STATE_FILE"
  else
    # ========================================================================
    # VERIFICAÇÃO: Idempotência (já rodou hoje?)
    # ========================================================================
    local ultimo_backup
    ultimo_backup=$(read_state_field "$STATE_FILE" ultimoBackup)
    local hoje
    hoje=$(date +%Y-%m-%d)
    
    if [[ "$ultimo_backup" == "$hoje"* ]]; then
      log_info "Backup já executado hoje. Operação idempotente - pulando."
      trap - ERR
      release_lock "$LOCK_FILE"
      return 0
    fi
    
    # ========================================================================
    # VERIFICAÇÃO: Espaço em disco
    # ========================================================================
    if ! check_disk_space "$APP_DIR" 1024 "$EMAIL_TO" "$APP_NAME"; then
      log_error "Backup abortado: espaço insuficiente"
      trap - ERR
      release_lock "$LOCK_FILE"
      return 1
    fi
    
    # ========================================================================
    # PASSO 1: VERIFICAR MUDANÇA DE MÊS (ANTES de modificar backup)
    # ========================================================================
    local mes_atual mes_registrado
    mes_atual=$(current_month)
    mes_registrado=$(read_state_field "$STATE_FILE" mesBackup)
    
    local criar_zip_mensal=false
    local zip_mensal=""
    
    if [[ -n "$mes_registrado" && "$mes_registrado" != "$mes_atual" ]]; then
      criar_zip_mensal=true
      local mes_anterior
      mes_anterior=$(get_previous_month)
      zip_mensal="${APP_DIR}/${APP_ID}_backup_mensal_${mes_anterior}.tar.gz"
      log_info "Mudança de mês: ${mes_registrado} → ${mes_atual}"
    fi
    
    # ========================================================================
    # PASSO 2: CRIAR ZIP MENSAL (com dados do mês anterior)
    # ========================================================================
    local BACKUP_DIR_OLD="${APP_DIR}/backup_atual"
    
    if [[ "$criar_zip_mensal" == true ]]; then
      if [[ -d "$BACKUP_DIR_OLD" ]]; then
        log_info "Criando ZIP mensal: $(basename "$zip_mensal")"
        
        local zip_temp="${zip_mensal}.tmp"
        
        # Criar ZIP usando caminhos absolutos (sem cd)
        # -j: junk paths (não inclui estrutura de diretórios absolutos)
        # Alternativa: usar tar que suporta -C (change directory) de forma segura
        if tar -czf "$zip_temp" -C "$BACKUP_DIR_OLD" . 2>/dev/null; then
          # Validar arquivo criado
          if tar -tzf "$zip_temp" >/dev/null 2>&1; then
            mv -f "$zip_temp" "$zip_mensal"
            log_info "ZIP mensal criado: $(basename "$zip_mensal") ($(du -h "$zip_mensal" | cut -f1))"
          else
            log_error "ZIP falhou na validação de integridade"
            rm -f "$zip_temp"
          fi
        else
          log_error "Falha ao criar ZIP mensal"
          rm -f "$zip_temp"
        fi
        
        cleanup_old_archives "$APP_DIR" "$APP_ID"
      fi
      
      write_state "$STATE_FILE" "mesBackup:str=${mes_atual}"
    elif [[ -z "$mes_registrado" ]]; then
      log_info "Primeira execução. Mês inicial: ${mes_atual}"
      write_state "$STATE_FILE" "mesBackup:str=${mes_atual}"
    fi
    
    # ========================================================================
    # PASSO 3: BACKUP DIÁRIO (Atomic Swap Pattern)
    # ========================================================================
    log_info "Iniciando backup diário..."
    
    local BACKUP_DIR_NEW="${APP_DIR}/backup_novo"
    local BACKUP_DIR_TRASH="${APP_DIR}/backup_antigo"
    
    [[ -d "$BACKUP_DIR_NEW" ]] && rm -rf "$BACKUP_DIR_NEW"
    [[ -d "$BACKUP_DIR_TRASH" ]] && rm -rf "$BACKUP_DIR_TRASH"
    
    if ! mkdir -p "$BACKUP_DIR_NEW"; then
      log_error "Falha ao criar diretório temporário"
      trap - ERR
      release_lock "$LOCK_FILE"
      return 1
    fi
    
    if [[ ${#ITEMS[@]} -eq 0 ]]; then
      log_error "Array ITEMS vazio"
      trap - ERR
      release_lock "$LOCK_FILE"
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
      
      dest_path="${BACKUP_DIR_NEW}/${destino}"
      
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
      rm -rf "$BACKUP_DIR_NEW"
      trap - ERR
      release_lock "$LOCK_FILE"
      return 1
    fi
    
    # ========================================================================
    # PASSO 4: SWAP ATÔMICO
    # ========================================================================
    if [[ -d "$BACKUP_DIR_OLD" ]]; then
      mv "$BACKUP_DIR_OLD" "$BACKUP_DIR_TRASH" || {
        log_error "Falha no swap atômico"
        rm -rf "$BACKUP_DIR_NEW"
        trap - ERR
        release_lock "$LOCK_FILE"
        return 1
      }
    fi
    
    mv "$BACKUP_DIR_NEW" "$BACKUP_DIR_OLD" || {
      log_error "Falha no swap atômico"
      [[ -d "$BACKUP_DIR_TRASH" ]] && mv "$BACKUP_DIR_TRASH" "$BACKUP_DIR_OLD"
      trap - ERR
      release_lock "$LOCK_FILE"
      return 1
    }
    
    [[ -d "$BACKUP_DIR_TRASH" ]] && rm -rf "$BACKUP_DIR_TRASH"
    
    # ========================================================================
    # PASSO 5: ATUALIZAR ESTADO E NOTIFICAR
    # ========================================================================
    if [[ $erros -gt 0 ]]; then
      log_error "Backup parcial: ${erros} erro(s). ${items_copiados}/${total_items} itens."
      if [[ -n "$EMAIL_TO" ]]; then
        send_partial_backup_mail "$EMAIL_TO" "$APP_NAME" "$items_copiados" "$total_items" "$erros" "$ERRO_LOG"
      fi
    else
      log_info "Backup concluído: ${items_copiados}/${total_items} itens."
    fi
    
    echo "$new_hash" > "$HASH_FILE"
    
    write_state "$STATE_FILE" \
      "ultimoHash:str=${new_hash}" \
      "ultimoBackup:str=$(timestamp)" \
      "contadorSemMudanca:num=0" \
      "aguardando:bool=false"
    
    if [[ -n "$EMAIL_TO" && $erros -eq 0 ]]; then
      send_backup_mail "$EMAIL_TO" "$APP_NAME" "$BACKUP_DIR_OLD" "$items_copiados" "$total_items"
    fi
  fi

  trap - ERR
  release_lock "$LOCK_FILE"
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
    if ! ( process_conf "$conf" ); then
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
