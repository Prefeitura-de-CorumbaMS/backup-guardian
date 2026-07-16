#!/usr/bin/env bash
# hash.sh - Cálculo de hash SHA256 baseado em conteúdo (não em timestamp/tamanho)
set -euo pipefail

# compute_content_hash "src|dest" "src|dest" ...
compute_content_hash() {
  local items=("$@")
  local tmp
  tmp=$(mktemp)
  local item path

  for item in "${items[@]}"; do
    path="${item%%|*}"
    if [[ -d "$path" ]]; then
      find "$path" -type f -print0 2>/dev/null | sort -z | xargs -0 -r sha256sum
    elif [[ -f "$path" ]]; then
      sha256sum "$path"
    else
      echo "MISSING:${path}"
    fi
  done >> "$tmp"

  sort -o "$tmp" "$tmp"
  local hash
  hash=$(sha256sum "$tmp" | awk '{print $1}')
  rm -f "$tmp"
  printf '%s' "$hash"
}
