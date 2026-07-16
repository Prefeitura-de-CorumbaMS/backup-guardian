#!/usr/bin/env bash
set -euo pipefail

# Backup Guardian - Desinstalador
# Executar como: sudo ./uninstall.sh
# Não remove /backup-geral (dados de backup) nem /etc/backup-guardian/conf.d (configurações).

INSTALL_DIR="/opt/backup-guardian"
SYSTEMD_DIR="/etc/systemd/system"

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Este script deve ser executado como root: sudo ./uninstall.sh" >&2
    exit 1
  fi
}

main() {
  require_root

  systemctl stop backup_guardian.timer 2>/dev/null || true
  systemctl disable backup_guardian.timer 2>/dev/null || true
  rm -f "$SYSTEMD_DIR/backup_guardian.service" "$SYSTEMD_DIR/backup_guardian.timer"
  systemctl daemon-reload

  rm -rf "$INSTALL_DIR"

  echo "Backup Guardian removido."
  echo "Diretórios de backup em /backup-geral e configurações em /etc/backup-guardian/conf.d foram preservados."
}

main "$@"
