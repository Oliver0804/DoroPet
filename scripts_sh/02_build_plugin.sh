#!/usr/bin/env bash
# 編譯 gd_cubism (macOS arm64) 並把 addons/ 連結到 Godot 專案根目錄
set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$PROJ_ROOT/vendor/gd_cubism"
ADDON_SRC="$SRC/demo/addons/gd_cubism"
ADDON_DST="$PROJ_ROOT/addons/gd_cubism"

# 1) 確認 SDK 已就位
if ! ls -d "$SRC/thirdparty/CubismSdkForNative-"* >/dev/null 2>&1; then
  echo "❌ 找不到 thirdparty/CubismSdkForNative-*/，請先跑 01_setup_core.sh" >&2
  exit 1
fi

# 2) 確認 scons 在
if ! command -v scons >/dev/null 2>&1; then
  echo "→ 安裝 scons (pip install --user scons==4.7)"
  python3 -m pip install --user "scons==4.7"
  export PATH="$HOME/Library/Python/$(python3 -c 'import sys;print(f\"{sys.version_info.major}.{sys.version_info.minor}\")')/bin:$PATH"
fi

# 3) 編譯 debug + release（首次會編 godot-cpp，預計 10-20 分鐘）
cd "$SRC"
JOBS="$(sysctl -n hw.ncpu)"
echo "→ scons template_debug  (jobs=$JOBS)"
scons platform=macos arch=arm64 target=template_debug -j"$JOBS"
echo "→ scons template_release (jobs=$JOBS)"
scons platform=macos arch=arm64 target=template_release -j"$JOBS"

# 4) 把整個 addon 連結進專案
mkdir -p "$PROJ_ROOT/addons"
if [[ -L "$ADDON_DST" || -e "$ADDON_DST" ]]; then
  rm -rf "$ADDON_DST"
fi
ln -s "$ADDON_SRC" "$ADDON_DST"

echo ""
echo "✅ 建置完成。產物："
ls -la "$ADDON_SRC/bin"
echo ""
echo "Addon 連結：$ADDON_DST → $ADDON_SRC"
echo "下一步：scripts_sh/03_run.sh"
