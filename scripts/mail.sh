#!/usr/bin/env bash
# mail.sh - Envio de notificações por e-mail (requer 'mail' configurado com SMTP)
set -euo pipefail

send_backup_mail() {
  local to="$1"
  local app_name="$2"
  local backup_dir="${3:-}"
  local items_copiados="${4:-N/A}"
  local total_items="${5:-N/A}"
  
  local subject="✅ [BACKUP] ${app_name} - Sucesso"
  local body
  body="╔════════════════════════════════════════════════════════════╗
║           BACKUP GUARDIAN - BACKUP CONCLUÍDO              ║
╚════════════════════════════════════════════════════════════╝

📅 Data/Hora: $(date '+%d/%m/%Y às %H:%M:%S')
🖥️  Servidor: $(hostname)
📦 Aplicação: ${app_name}
✅ Status: SUCESSO

📊 Estatísticas:
   • Itens copiados: ${items_copiados}/${total_items}
   • Diretório: ${backup_dir}

💡 Próxima ação: Sincronizar com Google Drive

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Backup Guardian - Sistema Automatizado de Backup
"
  echo "$body" | mail -s "$subject" "$to" || true
}

send_error_mail() {
  local to="$1"
  local etapa="$2"
  local erro="$3"
  
  local subject="❌ [ERRO] Backup Guardian - ${etapa}"
  local body
  body="╔════════════════════════════════════════════════════════════╗
║           BACKUP GUARDIAN - ERRO DETECTADO                ║
╚════════════════════════════════════════════════════════════╝

📅 Data/Hora: $(date '+%d/%m/%Y às %H:%M:%S')
🖥️  Servidor: $(hostname)
❌ Etapa: ${etapa}

🔴 ERRO:
${erro}

⚠️  AÇÃO NECESSÁRIA: Verifique os logs do sistema

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Backup Guardian - Sistema Automatizado de Backup
"
  echo "$body" | mail -s "$subject" "$to" || true
}

send_disk_space_alert() {
  local to="$1"
  local app_name="$2"
  local target_dir="$3"
  local available_mb="$4"
  local required_mb="$5"
  
  local total_mb used_mb percent_used
  total_mb=$(df -BM "$target_dir" | awk 'NR==2 {print $2}' | sed 's/M//')
  used_mb=$(df -BM "$target_dir" | awk 'NR==2 {print $3}' | sed 's/M//')
  percent_used=$(df -BM "$target_dir" | awk 'NR==2 {print $5}')
  
  local subject="⚠️  [ALERTA] Espaço em Disco Insuficiente - ${app_name}"
  local body
  body="╔════════════════════════════════════════════════════════════╗
║      BACKUP GUARDIAN - ALERTA DE ESPAÇO EM DISCO          ║
╚════════════════════════════════════════════════════════════╝

📅 Data/Hora: $(date '+%d/%m/%Y às %H:%M:%S')
🖥️  Servidor: $(hostname)
📦 Aplicação: ${app_name}
⚠️  Status: ESPAÇO INSUFICIENTE

💾 INFORMAÇÕES DO DISCO:
   • Diretório: ${target_dir}
   • Tamanho Total: ${total_mb} MB
   • Espaço Usado: ${used_mb} MB (${percent_used})
   • Espaço Disponível: ${available_mb} MB
   • Espaço Necessário: ${required_mb} MB
   • Faltam: $((required_mb - available_mb)) MB

🔴 AÇÃO URGENTE NECESSÁRIA:
   1. Libere espaço em disco
   2. Remova arquivos desnecessários
   3. Considere expandir o disco
   4. Verifique ZIPs antigos que podem ser removidos

⚠️  O backup foi ABORTADO para evitar falhas.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Backup Guardian - Sistema Automatizado de Backup
"
  echo "$body" | mail -s "$subject" "$to" || true
}

send_partial_backup_mail() {
  local to="$1"
  local app_name="$2"
  local items_copiados="$3"
  local total_items="$4"
  local erros="$5"
  local log_file="${6:-/var/log/backup-guardian/erro.log}"
  
  local subject="⚠️  [AVISO] Backup Parcial - ${app_name}"
  local body
  body="╔════════════════════════════════════════════════════════════╗
║        BACKUP GUARDIAN - BACKUP PARCIAL CONCLUÍDO         ║
╚════════════════════════════════════════════════════════════╝

📅 Data/Hora: $(date '+%d/%m/%Y às %H:%M:%S')
🖥️  Servidor: $(hostname)
📦 Aplicação: ${app_name}
⚠️  Status: PARCIAL (com erros)

📊 Estatísticas:
   • Itens copiados: ${items_copiados}/${total_items}
   • Erros encontrados: ${erros}
   • Taxa de sucesso: $(( (items_copiados * 100) / total_items ))%

⚠️  AÇÃO RECOMENDADA:
   • Verifique o log de erros: ${log_file}
   • Corrija os problemas identificados
   • Execute backup manual se necessário

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Backup Guardian - Sistema Automatizado de Backup
"
  echo "$body" | mail -s "$subject" "$to" || true
}
