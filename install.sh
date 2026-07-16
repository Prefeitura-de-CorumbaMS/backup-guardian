#!/usr/bin/env bash
set -euo pipefail

# Backup Guardian - Instalador
# Executar como: sudo ./install.sh

SCRIPT_SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/backup-guardian"
CONF_DIR="/etc/backup-guardian/conf.d"
SYSTEMD_DIR="/etc/systemd/system"
GROUP_NAME="backup-users"

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Este instalador deve ser executado como root: sudo ./install.sh" >&2
    exit 1
  fi
}

check_dependencies() {
  local deps=(bash zip unzip jq sha256sum find systemctl)
  local missing=()
  local dep
  for dep in "${deps[@]}"; do
    if ! command -v "$dep" >/dev/null 2>&1; then
      missing+=("$dep")
    fi
  done
  if ! command -v mail >/dev/null 2>&1; then
    missing+=("mail (mailutils/bsd-mailx)")
  fi
  if [[ "${#missing[@]}" -gt 0 ]]; then
    echo "Dependências ausentes: ${missing[*]}" >&2
    echo "Instale com: apt-get install zip unzip jq mailutils" >&2
    exit 1
  fi
}

main() {
  require_root
  check_dependencies

  echo "== Backup Guardian - Instalação =="

  if ! getent group "$GROUP_NAME" >/dev/null 2>&1; then
    groupadd "$GROUP_NAME"
    echo "Grupo '${GROUP_NAME}' criado."
  fi

  mkdir -p "$INSTALL_DIR/scripts"
  cp -a "$SCRIPT_SOURCE_DIR/scripts/." "$INSTALL_DIR/scripts/"
  chmod 750 "$INSTALL_DIR/scripts"/*.sh

  mkdir -p "$CONF_DIR"
  local conf dest env_src env_dest
  for conf in "$SCRIPT_SOURCE_DIR"/conf/*.conf; do
    [[ -e "$conf" ]] || continue
    dest="$CONF_DIR/$(basename "$conf")"
    if [[ ! -e "$dest" ]]; then
      cp "$conf" "$dest"
      echo "Configuração instalada: $dest"
    else
      echo "Configuração já existente, mantida: $dest"
    fi

    env_src="${conf%.conf}.env"
    if [[ -e "$env_src" ]]; then
      env_dest="$CONF_DIR/$(basename "$env_src")"
      if [[ ! -e "$env_dest" ]]; then
        cp "$env_src" "$env_dest"
        chmod 600 "$env_dest"
        echo "Valores sensíveis instalados: $env_dest"
      else
        echo "Arquivo .env já existente, mantido: $env_dest"
      fi
    fi
  done

  cp "$SCRIPT_SOURCE_DIR/systemd/backup_guardian.service" "$SYSTEMD_DIR/backup_guardian.service"
  cp "$SCRIPT_SOURCE_DIR/systemd/backup_guardian.timer" "$SYSTEMD_DIR/backup_guardian.timer"
  sed -i "s#{{INSTALL_DIR}}#${INSTALL_DIR}#g" "$SYSTEMD_DIR/backup_guardian.service"
  sed -i "s#{{CONF_DIR}}#${CONF_DIR}#g" "$SYSTEMD_DIR/backup_guardian.service"

  systemctl daemon-reload
  systemctl enable backup_guardian.timer
  systemctl start backup_guardian.timer

  echo "Executando backup inicial (cria hash, estado.json e backups mensal/corrente)..."
  if ! BACKUP_GUARDIAN_CONF_DIR="$CONF_DIR" "$INSTALL_DIR/scripts/backup.sh"; then
    echo "Aviso: a execução inicial retornou erro. Verifique erro.log em cada diretório de backup." >&2
  fi

  echo ""
  echo "Instalação concluída com sucesso."
  echo "Próxima execução agendada:"
  systemctl list-timers backup_guardian.timer --no-pager || true
}

main "$@"
