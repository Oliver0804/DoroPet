#!/usr/bin/env bash
# 把使用者下載的 Cubism SDK for Native 套到正確位置
# 用法：
#   bash scripts_sh/01_setup_core.sh /path/to/CubismSdkForNative-5-r.4
# （資料夾路徑 = 你解壓 SDK 後最外層那個含 Core/ Framework/ Samples/ 的資料夾）

set -euo pipefail
SDK_SRC="${1:-}"
if [[ -z "$SDK_SRC" || ! -d "$SDK_SRC" ]]; then
  echo "用法：$0 <CubismSdkForNative-?-r.?_路徑>" >&2
  echo "（從 https://www.live2d.com/sdk/download/native/ 下載並解壓）" >&2
  exit 1
fi
if [[ ! -d "$SDK_SRC/Core" || ! -d "$SDK_SRC/Framework" ]]; then
  echo "目錄 $SDK_SRC 內找不到 Core/ 與 Framework/，請確認路徑指到解壓後的 SDK 根目錄" >&2
  exit 1
fi

PROJ_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
THIRDPARTY="$PROJ_ROOT/vendor/gd_cubism/thirdparty"
mkdir -p "$THIRDPARTY"

# 偵測 SDK 版本，沿用 gd_cubism 預期的命名（CubismSdkForNative-X-r.Y）
SDK_NAME="$(basename "$SDK_SRC")"
DEST="$THIRDPARTY/$SDK_NAME"

if [[ -e "$DEST" ]]; then
  echo "已存在：$DEST"
  echo "若要重灌請先刪除。"
  exit 0
fi

echo "→ 連結 SDK 到 $DEST"
ln -s "$SDK_SRC" "$DEST"
echo "✅ Core 安裝完成。接著執行 scripts_sh/02_build_plugin.sh"
