#!/usr/bin/env bash
# hash.sh - Cálculo de hash SHA256 baseado em conteúdo (não em timestamp/tamanho)
set -euo pipefail

# compute_content_hash "src|dest" "src|dest" ...
compute_content_hash() {
  local items=("$@")
  local tmp
  tmp=$(mktemp)
  local item path
  local errors=0

  for item in "${items[@]}"; do
    path="${item%%|*}"
    
    if [[ -d "$path" ]]; then
      if [[ ! -r "$path" ]]; then
        echo "UNREADABLE_DIR:${path}" >> "$tmp"
        ((errors++))
        continue
      fi
      find "$path" -type f -print0 2>/dev/null | sort -z | while IFS= read -r -d '' file; do
        if [[ -r "$file" ]]; then
          sha256sum "$file" 2>/dev/null || echo "UNREADABLE:${file}"
        else
          echo "UNREADABLE:${file}"
        fi
      done >> "$tmp"
    elif [[ -f "$path" ]]; then
      if [[ -r "$path" ]]; then
        sha256sum "$path" 2>/dev/null >> "$tmp" || echo "UNREADABLE:${path}" >> "$tmp"
      else
        echo "UNREADABLE:${path}" >> "$tmp"
        ((errors++))
      fi
    else
      echo "MISSING:${path}" >> "$tmp"
      ((errors++))
    fi
  done

  if [[ $errors -gt 0 ]]; then
    # Hash inclui marcadores de erro, garantindo que hash mude se permissões mudarem
    >&2 echo "Aviso: ${errors} item(ns) inacessível(is) durante cálculo de hash"
  fi

  sort -o "$tmp" "$tmp"
  local hash
  hash=$(sha256sum "$tmp" | awk '{print $1}')
  rm -f "$tmp"
  printf '%s' "$hash"
}
