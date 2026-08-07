# Discord 語音橋

把 Doro 接進 Discord 語音頻道,跟頻道裡的人講話。

## 為什麼是獨立的 Node 程式

Discord 語音需要 voice gateway WebSocket + UDP + Opus 編解碼 + 加密,GDScript 這幾樣都沒有,
硬做等於自己寫一個 GDExtension。所以 Discord 那一側交給 Node,跟 Godot 之間走 localhost
WebSocket 傳 base64 wav。

```
Discord 語音頻道
   ↕ opus / UDP
discord_bridge (Node)          ← 這個目錄
   per-user 收音 → 16k mono wav
   TTS wav → 播回頻道
   ↕ ws://127.0.0.1:8765
DoroPet (Godot)
   STT → 回音檢查 → 熱詞閘門 → LLM → TTS
```

順帶一提:DC 模式下**不會有回音問題**。Doro 的聲音是以 bot 身分推進頻道,
Discord 不會把 bot 自己的聲音回傳給它,本地那套 filler 回音防護在這裡用不上。
(但頻道裡有人開喇叭的話,Doro 的聲音會從那個人的麥克風繞回來 —— 這個由
`discord_client.gd` 的回音檢查擋,見下面「已知狀況」。)

## 設定

### 1. 建 bot

1. https://discord.com/developers/applications → New Application
2. **Bot** 頁籤 → Reset Token,複製 token
3. **OAuth2 → URL Generator**
   - scopes:`bot` + `applications.commands`
   - Bot Permissions:`Connect`、`Speak`、`Use Voice Activity`
4. 用產生的網址把 bot 邀進你的伺服器

不需要開任何 Privileged Intent —— 用的是 slash command,不讀訊息內容。

### 2. 放 token

兩種方式,擇一:

- **Doro 設定視窗**(建議):設定 → 🎧 Discord 語音 → Bot Token。
  sidecar 是獨立進程讀不到 Godot 的設定檔,所以 Doro 連上之後會把 token 送過去讓它登入。
- **環境變數**:`echo 'export DISCORD_BOT_TOKEN=你的token' >> ~/.doropet.env`

兩個都沒填的話 sidecar 照樣會啟動等著,只是還不能進頻道。

⚠️ 從設定視窗填的話 token 會明文存在 `doropet.cfg`(跟其他金鑰一樣)。外洩等於 bot 被接管。

### 3. 跑起來

```bash
./scripts_sh/04_discord.sh           # 啟動 sidecar
./scripts_sh/04_discord.sh --debug   # 順便把收到的每句話存成 wav
```

然後開 DoroPet,右鍵選單勾 **🎧 Discord 語音**。

最後在 Discord 語音頻道裡打 `/doro join`(要先自己在語音頻道裡)。
`/doro leave` 讓牠出去。

## 怎麼觸發 Doro

語音頻道是多人閒聊,不是每句都在跟 Doro 講話。所以:**每句話都做 STT,但只有講到熱詞才送 LLM**。
STT 便宜,LLM 貴一個量級,閘門放在中間。

熱詞用的是設定裡那份 `stt_hotwords`(預設 `洛狗、格洛、佐羅、咕咕嘎嘎、Doro`)——
它本來就是「Doro」的常見誤聽變體清單,正好拿來當召喚詞。清空的話就變成每句都回。

## 測試

不需要 bot token 就能跑:

```bash
node test-audio.js     # 音訊管線:48k stereo → 16k mono wav
node test-bridge.js    # 假 sidecar,配合 Godot 端驗 WebSocket 協定
```

## 已知狀況

- **Discord 官方沒有正式支援接收語音**。`@discordjs/voice` 的 receive 實務上長期可用,
  但不在官方保證範圍內,改版可能壞掉。
- **錄他人語音有合規問題**。Discord ToS 和多數地區法律要求告知參與者,bot 進頻道時該說一聲。
- **跨網路回音**:頻道裡有人開喇叭(不是耳機)的話,Doro 的聲音會被那個人的麥克風收回來,
  變成「那個人說的話」。而 Doro 幾乎每句都自稱 Doro → 必過熱詞閘門 → 自問自答。
  `discord_client.gd` 在熱詞閘門**之前**先跑一次回音比對擋這個,順序不能顛倒。
- **v1 沒有 barge-in**。Doro 講到一半被人蓋過去,牠會講完。
- **`speaking_finished` 會比實際播完早**:Godot 那邊生成完就當講完,但 sidecar 還在排隊播。

## 疑難排解

| 症狀 | 多半是 |
|---|---|
| bot 進頻道了但收不到任何聲音 | `joinVoiceChannel` 的 `selfDeaf` 沒設 `false`(預設 true,而且不會報錯) |
| `/doro` 指令沒出現 | 邀請時沒勾 `applications.commands` scope,重邀一次 |
| sidecar 起不來說缺依賴 | `npm install`;`npm run deps` 看四類依賴(加密/DAVE/Opus/FFmpeg)是不是都齊 |
| 收到的 wav 是靜音 | ffmpeg 重採樣參數錯,跑 `node test-audio.js` 對一下 |
| Godot 連不上 sidecar | 確認 sidecar 先啟動;埠預設 8765,可用 `DORO_BRIDGE_PORT` 改 |
