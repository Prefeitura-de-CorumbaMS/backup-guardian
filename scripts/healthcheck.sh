#!/usr/bin/env bash
# healthcheck.sh - Verifica saúde do sistema de backup
# Uso: ./healthcheck.sh [--email destinatario@example.com]
set -euo pipefail

CONF_DIR="${BACKUP_GUARDIAN_CONF_DIR:-/etc/backup-guardian/conf.d}"
MAX_DAYS_WITHOUT_BACKUP=2
CRITICAL_DISK_USAGE=90

check_timer_status() {
  echo "=== Status do Timer ==="
  if systemctl is-enabled backup_guardian.timer &>/dev/null; then
    echo "✅ Timer habilitado"
  else
    echo "❌ Timer DESABILITADO - backups não executarão após reboot!"
    return 1
  fi
  
  if systemctl is-active backup_guardian.timer &>/dev/null; then
    echo "✅ Timer ativo"
  else
    echo "❌ Timer INATIVO - backups não estão agendados!"
    return 1
  fi
  
  echo ""
  echo "Próxima execução:"
  systemctl list-timers backup_guardian.timer --no-pager | grep backup_guardian || true
  echo ""
}

check_recent_backups() {
  echo "=== Backups Recentes ==="
  local found_issue=0
  
  for conf in "$CONF_DIR"/*.conf; do
    [[ -e "$conf" ]] || continue
    
    # Sourcear .conf para obter APP_ID (que vem do .env)
    local app_id=""
    app_id=$(
      set +e  # Não abortar se source falhar
      source "$conf" 2>/dev/null
      echo "${APP_ID:-}"
    )
    
    if [[ -z "$app_id" ]]; then
      echo "⚠️  $(basename "$conf"): Não foi possível obter APP_ID"
      found_issue=1
      continue
    fi
    
    # Busca diretório de backup
    local backup_dir="/backups/${app_id}_arquivos"
    
    if [[ ! -d "$backup_dir" ]]; then
      echo "⚠️  $app_id: Diretório de backup não encontrado: $backup_dir"
      found_issue=1
      continue
    fi
    
    # Verifica último backup
    local state_file="${backup_dir}/estado.json"
    if [[ -f "$state_file" ]]; then
      local last_backup
      last_backup=$(grep -oP '"ultimoBackup":\s*"\K[^"]+' "$state_file" 2>/dev/null || echo "")
      
      if [[ -n "$last_backup" ]]; then
        local last_date="${last_backup%% *}"
        local days_ago
        days_ago=$(( ($(date +%s) - $(date -d "$last_date" +%s)) / 86400 ))
        
        if [[ $days_ago -gt $MAX_DAYS_WITHOUT_BACKUP ]]; then
          echo "❌ $app_id: Último backup há ${days_ago} dias (${last_backup})"
          found_issue=1
        else
          echo "✅ $app_id: Último backup há ${days_ago} dias (${last_backup})"
        fi
      else
        echo "⚠️  $app_id: Data de backup não encontrada"
        found_issue=1
      fi
    else
      echo "⚠️  $app_id: Arquivo de estado não encontrado"
      found_issue=1
    fi
  done
  
  echo ""
  return $found_issue
}

check_disk_space() {
  echo "=== Espaço em Disco ==="
  local found_issue=0
  
  df -h /backups 2>/dev/null | tail -1 | while read -r filesystem size used avail percent mountpoint; do
    local usage_num="${percent%\%}"
    
    if [[ $usage_num -ge $CRITICAL_DISK_USAGE ]]; then
      echo "❌ Disco crítico: ${percent} usado (${used}/${size})"
      found_issue=1
    elif [[ $usage_num -ge 80 ]]; then
      echo "⚠️  Disco alto: ${percent} usado (${used}/${size})"
    else
      echo "✅ Disco OK: ${percent} usado (${used}/${size})"
    fi
  done
  
  echo ""
  return $found_issue
}

check_smtp() {
  echo "=== Configuração SMTP ==="
  
  if [[ -f /etc/msmtprc ]]; then
    echo "✅ /etc/msmtprc existe"
    
    if [[ -r /etc/msmtprc ]]; then
      echo "✅ /etc/msmtprc é legível"
    else
      echo "⚠️  /etc/msmtprc não é legível"
    fi
  else
    echo "❌ /etc/msmtprc NÃO EXISTE - notificações não funcionarão!"
    return 1
  fi
  
  echo ""
}

check_logs() {
  echo "=== Logs Recentes ==="
  
  local error_count
  error_count=$(journalctl -u backup_guardian.service --since "24 hours ago" --no-pager 2>/dev/null | grep -c "ERRO:" || echo 0)
  
  if [[ $error_count -gt 0 ]]; then
    echo "⚠️  $error_count erros nas últimas 24h"
    echo ""
    echo "Últimos erros:"
    journalctl -u backup_guardian.service --since "24 hours ago" --no-pager 2>/dev/null | grep "ERRO:" | tail -5
  else
    echo "✅ Nenhum erro nas últimas 24h"
  fi
  
  echo ""
}

main() {
  local email=""
  
  if [[ "${1:-}" == "--email" && -n "${2:-}" ]]; then
    email="$2"
  fi
  
  echo "╔════════════════════════════════════════════════════════════╗"
  echo "║        BACKUP GUARDIAN - VERIFICAÇÃO DE SAÚDE             ║"
  echo "╚════════════════════════════════════════════════════════════╝"
  echo ""
  echo "Data: $(date '+%d/%m/%Y às %H:%M:%S')"
  echo "Servidor: $(hostname)"
  echo ""
  
  local status=0
  
  check_timer_status || status=1
  check_recent_backups || status=1
  check_disk_space || status=1
  check_smtp || status=1
  check_logs
  
  echo "════════════════════════════════════════════════════════════"
  
  if [[ $status -eq 0 ]]; then
    echo "✅ SISTEMA SAUDÁVEL"
  else
    echo "❌ PROBLEMAS DETECTADOS - AÇÃO NECESSÁRIA"
  fi
  
  echo ""
  
  # Enviar e-mail se solicitado
  if [[ -n "$email" && $status -ne 0 ]]; then
    echo "Enviando alerta para $email..."
    echo "Backup Guardian detectou problemas. Execute: sudo /opt/backup-guardian/scripts/healthcheck.sh" | \
      mail -s "⚠️ [ALERTA] Backup Guardian - Problemas Detectados" "$email" || \
      echo "Falha ao enviar e-mail"
  fi
  
  exit $status
}

main "$@"
