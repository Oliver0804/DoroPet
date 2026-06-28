#!/usr/bin/env bash
# DoroPet 一鍵安裝（macOS Apple Silicon）
# 1) clone gd_cubism v0.9.1（+ godot-cpp 子模組）
# 2) 下載 Cubism SDK 5-r.1（可改用本地解壓的版本）
# 3) brew install whisper-cpp + scons
# 4) 下載 ggml-base whisper model
# 5) 編譯 gd_cubism plugin
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

step() { echo -e "\n\033[1;36m▶ $*\033[0m"; }

# ---------- 1) gd_cubism 原始碼 ----------
if [[ ! -d vendor/gd_cubism ]]; then
  step "Clone gd_cubism v0.9.1（含 godot-cpp 子模組）"
  mkdir -p vendor
  git clone --depth 1 --branch v0.9.1 --recurse-submodules \
    https://github.com/MizunagiKB/gd_cubism.git vendor/gd_cubism
else
  echo "✔ vendor/gd_cubism 已存在,跳過"
fi

# ---------- 2) Cubism SDK 5-r.1 ----------
SDK_DIR="vendor/gd_cubism/thirdparty/CubismSdkForNative-5-r.1"
if [[ ! -d "$SDK_DIR" ]]; then
  step "下載 Cubism SDK for Native 5-r.1（v0.9.1 對應版本）"
  TMP_ZIP="$(mktemp -t doro_sdk.XXXXXX).zip"
  curl -L --progress-bar -o "$TMP_ZIP" \
    "https://cubism.live2d.com/sdk-native/bin/CubismSdkForNative-5-r.1.zip"
  unzip -q "$TMP_ZIP" -d vendor/gd_cubism/thirdparty/
  rm "$TMP_ZIP"
else
  echo "✔ Cubism SDK 已就位"
fi

# ---------- 3) brew 工具 ----------
if ! command -v brew >/dev/null 2>&1; then
  echo "❌ 需要 Homebrew,請先 https://brew.sh"
  exit 1
fi
if ! command -v scons >/dev/null 2>&1; then
  step "brew install scons（編譯 gd_cubism 需要）"
  brew install scons
fi
if ! command -v whisper-cli >/dev/null 2>&1; then
  step "brew install whisper-cpp（本地 STT）"
  brew install whisper-cpp
fi

# ---------- 4) whisper ggml model ----------
MDIR="$HOME/.local/share/doropet/whisper-models"
mkdir -p "$MDIR"
if [[ ! -f "$MDIR/ggml-base.bin" ]]; then
  step "下載 whisper ggml-base 模型（~140MB,多語言）"
  curl -L --progress-bar -o "$MDIR/ggml-base.bin" \
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin"
else
  echo "✔ whisper model 已存在"
fi

# ---------- 5) 編譯 plugin ----------
step "編譯 gd_cubism (首次約 10–20 分鐘)"
bash scripts_sh/02_build_plugin.sh

echo ""
echo "✅ 全部完成。執行: bash scripts_sh/03_run.sh"
echo ""
echo "提示: 設定 OpenRouter API key:"
echo "   echo 'export OPENROUTER_API_KEY=sk-or-v1-xxx' > ~/.doropet.env"
