#!/usr/bin/env bash
# 啟動 DoroPet
#
# 對話功能環境變數（選填，沒設就只是不能聊天，其他功能照常）：
#   OPENROUTER_API_KEY=sk-or-v1-xxxxxxxx
#   OPENROUTER_MODEL=bytedance-seed/seed-1.6-flash   # 預設值，可改
#
# 可在啟動前 export，或放在 ~/.doropet.env：
#   echo 'export OPENROUTER_API_KEY=sk-or-v1-xxx' > ~/.doropet.env

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

[[ -f "$HOME/.doropet.env" ]] && source "$HOME/.doropet.env"

GODOT_BIN="/Applications/Godot.app/Contents/MacOS/Godot"
if [[ ! -x "$GODOT_BIN" ]]; then
  echo "找不到 $GODOT_BIN，請改路徑或安裝 Godot 4.6+" >&2
  exit 1
fi

if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
  echo "⚠️  沒設 OPENROUTER_API_KEY，對話功能會停用（其他照常）" >&2
fi

export OPENROUTER_API_KEY OPENROUTER_MODEL
exec "$GODOT_BIN" --path "$PROJ_ROOT" res://scenes/main.tscn
