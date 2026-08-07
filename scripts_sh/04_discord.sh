#!/usr/bin/env bash
# 啟動 Discord 語音橋 sidecar
#
# 平常不用跑這支 —— Doro 勾了「🎧 Discord 語音」會自己把 sidecar 拉起來。
# 這支是給你想盯即時輸出、或要 --debug 存收音 wav 的時候用的。
# 手動跑的話 Doro 會直接接上去,不會重複啟動。
#
# 需要的環境變數(放 ~/.doropet.env):
#   DISCORD_BOT_TOKEN=xxx   (選用 —— 也可以改從 Doro 設定視窗填)
#
# Bot 怎麼建:
#   1. https://discord.com/developers/applications → New Application
#   2. Bot 頁籤 → Reset Token 拿 token
#   3. OAuth2 → URL Generator → scopes 勾 bot + applications.commands
#      → Bot Permissions 勾 Connect / Speak / Use Voice Activity
#      → 用產生的網址把 bot 邀進伺服器
#   4. 跑這支腳本,然後在 Discord 語音頻道裡打 /doro join
#
# 選項:
#   --debug   把收到的每句話存成 wav 到 discord_bridge/debug/
#             (不用開 Doro 就能單獨驗收音通不通)

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BRIDGE_DIR="$PROJ_ROOT/discord_bridge"

[[ -f "$HOME/.doropet.env" ]] && source "$HOME/.doropet.env"

# token 兩種來源:這裡的環境變數,或 Doro 設定視窗(連上後由 Godot 送過來)。
# 兩個都沒有的話 sidecar 照樣起來等,只是還不能進頻道。
if [[ -z "${DISCORD_BOT_TOKEN:-}" ]]; then
  echo "ℹ️  沒設 DISCORD_BOT_TOKEN —— 改從 Doro 設定視窗填(設定 → 🎧 Discord 語音 → Bot Token)"
  echo "   要用環境變數的話:echo 'export DISCORD_BOT_TOKEN=你的token' >> ~/.doropet.env"
fi

if ! command -v node >/dev/null 2>&1; then
  echo "❌ 找不到 node(需要 18 以上)" >&2
  exit 1
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "❌ 找不到 ffmpeg(收音要靠它做 48k stereo → 16k mono 重採樣)" >&2
  echo "   brew install ffmpeg" >&2
  exit 1
fi

if [[ ! -d "$BRIDGE_DIR/node_modules" ]]; then
  echo "首次執行,安裝依賴中…"
  (cd "$BRIDGE_DIR" && npm install)
fi

export DISCORD_BOT_TOKEN="${DISCORD_BOT_TOKEN:-}"
export DORO_BRIDGE_PORT="${DORO_BRIDGE_PORT:-8765}"
if [[ "${1:-}" == "--debug" ]]; then
  export DORO_BRIDGE_DEBUG=1
  echo "DEBUG 模式:收到的每句話會存進 discord_bridge/debug/"
fi

cd "$BRIDGE_DIR"
exec node index.js
