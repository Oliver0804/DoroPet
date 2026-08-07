# DoroPet

用 **Godot 4.6 + gd_cubism + Doro Live2D 模型**做的 macOS 桌面寵物。

## 功能
- 透明、無邊框、永遠置頂的桌面浮窗
- **左鍵拖曳** 把 Doro 拉到桌面任意位置
- **左鍵點擊**（未拖曳） 隨機輪流切換 11 個表情（含吐舌、Highlight off 等）
- **右鍵** 開選單：對話 / 表情 / 縮放 / 置頂 / 結束
- **滑鼠滾輪** 放大縮小（自動記住大小）
- **視線跟滑鼠**（頭、眼、身體角度都會跟）
- **跟 Doro 聊天**（按 Enter 或右鍵選單；走 OpenRouter API）
- **進 Discord 語音頻道跟人講話**（多人、per-user 記憶、語音進語音出）
- 內建 Idle 動作 + 物理擺動（頭髮飄）

## 對話功能（OpenRouter）
按 Enter 跳出輸入框，打字後再按 Enter 送出，Doro 回覆會浮在頭上 8 秒。

設定方式（二擇一）：
```bash
# 1) 啟動前直接 export
export OPENROUTER_API_KEY=sk-or-v1-xxxxxxxx
export OPENROUTER_MODEL=bytedance-seed/seed-1.6-flash   # 選填，這是預設

# 2) 寫到 ~/.doropet.env，scripts_sh/03_run.sh 會自動 source
echo 'export OPENROUTER_API_KEY=sk-or-v1-xxxxxxxx' > ~/.doropet.env
```

沒設 API key 時只是按 Enter 沒反應（其他功能照常）。預設 model `bytedance-seed/seed-1.6-flash`，要換模型改 `OPENROUTER_MODEL` 即可（任何 OpenRouter 支援的 chat 模型 ID）。

對話會保留最近 8 對歷史；右鍵選單「清空對話」可重置。

## Discord 語音頻道

讓 Doro 進 Discord 語音頻道，跟頻道裡的人用講的對話。它會記得誰說過什麼
（以 Discord user id 為 key，查詢結果帶日期），並在回話前先查一次。

### 1. 建立你自己的 bot

這個專案**不提供公用 bot**——語音會送到你自己的 STT / LLM 帳號，
所以每個人得跑自己的。三分鐘就好：

1. 到 [Discord Developer Portal](https://discord.com/developers/applications) → **New Application**
2. 左側 **Bot** → **Reset Token**，複製 token
3. 左側 **General Information** → 複製 **Application ID**

不需要開任何 Privileged Intent（用的是 slash command，不讀訊息內容）。

### 2. 邀請進你的伺服器

把下面網址的 `你的APPLICATION_ID` 換成剛複製的那串數字，貼進瀏覽器：

```
https://discord.com/api/oauth2/authorize?client_id=你的APPLICATION_ID&permissions=36700160&scope=bot%20applications.commands
```

`permissions=36700160` = `Connect` + `Speak` + `Use Voice Activity`，剛好夠用不多給。
`scope` 兩個都要，少了 `applications.commands` 的話 `/doro` 指令不會出現。

### 3. 填 token 並啟動

設定 → **🎧 Discord 語音** → 貼上 Bot Token → 儲存。
然後右鍵選單勾 **🎧 Discord 語音**，Doro 會自己把橋接程式拉起來
（第一次會需要 `cd discord_bridge && npm install`）。

最後自己進一個語音頻道，打 `/doro join`。`/doro leave` 讓它離開。

### 怎麼叫它

頻道裡不是每句話都要回應，所以**第一句要叫到名字**（「Doro」或設定裡的熱詞），
之後 40 秒內同一個人講話不用再叫，聊得順就一直延續。
別人插話沒叫名字仍然會被略過——他叫了就換他接手。

### 進頻道時會自動做的事

主人自己通常也在頻道裡、也在同一台電腦前，所以：

| 項目 | 進頻道後 |
|---|---|
| 桌面喇叭 | **完全靜音**（聲音只走 Discord） |
| 本地常駐聽 | 關閉（否則你講一句會被本地麥克風和 Discord 各收一次） |
| 隨機念話 | 跳過 |
| **截圖功能** | **停用**——那是你的螢幕，頻道裡還有別人 |

離開頻道全部自動恢復。

### 需要

`node >= 18`、`ffmpeg`（收音的重採樣要用）。細節與疑難排解見
[`discord_bridge/README.md`](discord_bridge/README.md)。

> Discord 官方並未正式支援「接收」語音，`@discordjs/voice` 的 receive
> 長期可用但不在官方保證範圍。另外錄他人語音在多數地區需要告知參與者，
> bot 進頻道時提一句比較妥當。

## 一鍵安裝

### macOS Apple Silicon
```bash
bash scripts_sh/00_install.sh
```

### Windows x64
1. 去 [GitHub Actions](https://github.com/Oliver0804/DoroPet/actions/workflows/build-windows.yml) 下載最新成功 build 的 `DoroPet-Windows-x86_64` artifact,解壓到任意資料夾
2. 安裝 whisper.cpp + 模型(語音功能用):
   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts_sh\00_install.ps1
   ```
3. 設 API key:`setx OPENROUTER_API_KEY sk-or-v1-xxx`
4. 雙擊 `DoroPet.exe` 啟動

Windows 上 TTS 走系統內建 SAPI(免裝),截圖走 PowerShell `System.Drawing`,中文聲音可在設定面板挑(預設 `Microsoft Hanhan` / `Microsoft Yating` 等,看你系統有哪些)。

會自動:clone gd_cubism + 下載 Cubism SDK 5-r.1 + `brew install scons whisper-cpp` + 下 whisper ggml-base 模型 + 編譯 plugin(首次 10–20 分鐘)。

完成後:
```bash
echo 'export OPENROUTER_API_KEY=sk-or-v1-xxx' > ~/.doropet.env
bash scripts_sh/03_run.sh
```

---

## 手動安裝(分步)

### 1. 下載 Live2D Cubism SDK for Native
> 因 Live2D 授權,SDK 不能放進這個 repo,得自己抓一次。

**⚠️ 版本要求:必須是 `5-r.1`**,別抓最新的 5-r.5 / 5-r.4 / 5-r.3。
這是因為 gd_cubism v0.9.1 (2025-03) 對應的是當時的 5-r.1 API,Live2D 在 5-r.5 改了 Framework / Core 的內部 API(例如 `csmGetDrawableRenderOrders` 改名為 `csmGetRenderOrders`),用新版會編譯失敗。

兩種抓法,二擇一:
- **直接 CDN**(無 click-through 介面):`curl -LO https://cubism.live2d.com/sdk-native/bin/CubismSdkForNative-5-r.1.zip` — 條款仍適用 Live2D 授權,商用前自行確認
- **官方頁**:<https://www.live2d.com/sdk/download/native/> → 拉到 "Previous versions",勾條款,下載 5-r.1

解壓得到 `CubismSdkForNative-5-r.1/`(含 `Core/`、`Framework/`、`Samples/`)

### 2. 套到專案
```bash
bash scripts_sh/01_setup_core.sh /路徑/到/CubismSdkForNative-5-r.4
```
(其實是 symlink,不會搬檔)

### 3. 編譯插件
```bash
bash scripts_sh/02_build_plugin.sh
```
- 第一次會編 `godot-cpp` 子模組,Apple Silicon 上大約 **10–20 分鐘**
- 之後改 GDScript / 場景**不用再編**

腳本會自動 `pip install scons==4.7`(若還沒裝)、`-j<核心數>` 平行編譯。

## 啟動

**第一次啟動前先 import**(只要 GDExtension 或 assets 結構有變,就要重跑這步):
```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --import
```

**直接跑桌寵(無編輯器)**:
```bash
/Applications/Godot.app/Contents/MacOS/Godot --path . res://scenes/main.tscn
```

**或開編輯器 → 按 F5**:
```bash
bash scripts_sh/03_run.sh
```

> macOS 注意:全螢幕 App (例如 LoL、Final Cut) 會佔獨立 Space,**會把桌寵蓋住**——這是 macOS 限制,不是 bug。把遊戲切窗化或 Cmd+Tab 回桌面就會看到 Doro。

## 專案結構

```
DoroPet/
├── project.godot              ← Godot 專案設定（透明視窗、置頂、無邊框）
├── scenes/main.tscn           ← 主場景
├── scripts/pet.gd             ← 桌寵核心邏輯
├── assets/doro/               ← Doro Live2D 模型（model3 / moc3 / 表情 / 物理）
├── vendor/gd_cubism/          ← 插件原始碼（git clone 自 upstream）
├── addons/gd_cubism/          ← (編譯後產生的 symlink) Godot 載入的插件
└── scripts_sh/                ← 安裝/編譯/啟動腳本
```

## 調整外觀 / 行為
打開 `scripts/pet.gd`,有四個 `@export` 變數可調:

| 變數 | 預設 | 說明 |
|------|------|------|
| `model_scale` | 0.18 | 放大縮小整個 Doro |
| `head_follow_strength` | 30.0 | 頭部轉向的最大角度(度) |
| `eye_follow_strength` | 1.0 | 眼球偏移幅度(Cubism 標準 −1~1) |
| `model_path` | `res://assets/doro/Doro.model3.json` | 換成別張 Live2D 皮 |

## 已知小毛病

- **`Doro.model3.json` 的 `EyeBlink` / `LipSync` 群組是空的** → 不會自動眨眼、嘴巴不會張合(無音源)。若想補,要在 Cubism Editor 裡查出對應參數 ID(`ParamEyeLOpen` / `ParamEyeROpen` / `ParamMouthOpenY`)填回 `model3.json` 的 `Groups`。
- 視線跟滑鼠依賴模型有 `ParamAngleX/Y/Z`、`ParamEyeBallX/Y` 這幾個標準參數(Doro 應該都有);若某張皮缺,該參數就無效但程式不會壞。
- 拖曳時用 `DisplayServer.window_get_position()`/`window_set_position`,macOS 上對多螢幕應該 OK,若有 HiDPI 比例問題再回報。

## 升級插件

```bash
cd vendor/gd_cubism && git fetch && git checkout <new_tag> && git submodule update --recursive
bash scripts_sh/02_build_plugin.sh
```

## 授權

- DoroPet 程式碼:你自由處置
- Doro 模型:依該模型作者授權
- Live2D Cubism SDK / Core:依 Live2D 官方授權(個人 / 小規模免費,商用有條款)
- gd_cubism:MIT
