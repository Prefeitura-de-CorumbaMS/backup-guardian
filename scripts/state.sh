#!/usr/bin/env bash
# state.sh - Leitura/escrita do estado.json (via jq)
set -euo pipefail

init_state() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    jq -n '{ultimoHash:"", ultimoBackup:"", mesBackup:"", contadorSemMudanca:0, aguardando:false}' > "$file"
  fi
}

read_state_field() {
  local file="$1"
  local field="$2"
  jq -r --arg f "$field" '.[$f]' "$file"
}

# write_state <arquivo> "campo:tipo=valor" ...
# tipos suportados: str (padrão), num, bool
write_state() {
  local file="$1"
  shift
  local tmp
  tmp=$(mktemp)
  local filter="."
  local args=()
  local i=0
  local pair keytype value field type varname

  for pair in "$@"; do
    keytype="${pair%%=*}"
    value="${pair#*=}"
    field="${keytype%%:*}"
    type="${keytype##*:}"
    varname="v${i}"
    case "$type" in
      num)
        filter+=" | .${field} = (\$${varname} | tonumber)"
        ;;
      bool)
        filter+=" | .${field} = (\$${varname} == \"true\")"
        ;;
      *)
        filter+=" | .${field} = \$${varname}"
        ;;
    esac
    args+=(--arg "$varname" "$value")
    i=$((i + 1))
  done

  jq "${args[@]}" "$filter" "$file" > "$tmp"
  mv -f "$tmp" "$file"
}
