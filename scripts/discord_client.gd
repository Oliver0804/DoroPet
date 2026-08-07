extends Node
## Discord 語音橋的 Godot 端
##
## 對面是 discord_bridge/index.js(Node sidecar)。它負責 Discord 那一側,
## 這邊只做三件事:收 wav → STT → 過閘門 → 丟給 chat_client;以及把 TTS wav 送回去。
##
## sidecar 由這邊自動拉起(連不上就 spawn),你手動跑的話會直接接上去不重複啟動。
##
## 設計取捨:
## - STT 序列化排隊。byteplus_stt.start() 開頭就 cancel(),同時跑會互相取消,
##   而語音頻道多人同時講話是常態。
## - 回音檢查放在熱詞閘門「之前」。Doro 人設自稱「Doro」,幾乎每句都含熱詞,
##   別人的喇叭把牠的聲音收回頻道時會必過閘門 → 自問自答,而且是跨網路的。

signal speech_recognized(text: String, user_name: String, user_id: String)  ## 已過回音+熱詞閘門
signal bridge_connected(up: bool)
signal login_result(ok: bool, detail: String)
signal channel_state(in_channel: bool, invoker_name: String)

const DoroLogger := preload("res://scripts/logger.gd")
const ByteplusSTT := preload("res://scripts/byteplus_stt.gd")

const DEFAULT_URL: String = "ws://127.0.0.1:8765"
const RECONNECT_SEC: float = 3.0
## 一句 10 秒的 16k mono wav ≈ 320KB,base64 後 ~430KB;預設 64KB 直接爆
const WS_BUF_SIZE: int = 4 << 20
const MAX_QUEUE: int = 8            ## STT 待辨識上限,滿了丟最舊的(寧可漏一句也不要積壓)

var _ws: WebSocketPeer = null
var _url: String = DEFAULT_URL
var _token: String = ""       ## bot token,連上 sidecar 後轉交給它登入
var _enabled: bool = false
var _in_channel: bool = false
var _invoker: String = ""     ## 打 /doro join 把 Doro 叫進來的人 = 主人
var _reconnect_at_ms: int = 0
var _was_open: bool = false
var _sidecar_pid: int = -1        ## 我們自己啟動的 sidecar(手動啟動的不歸我們管)
var _spawn_tried: bool = false    ## 一輪 enable 只嘗試自動啟動一次,免得連不上就狂 spawn

var _stt: Node = null
var _queue: Array = []              ## [{wav: PackedByteArray, user_name: String}]
var _stt_busy: bool = false
var _cur_user: String = ""
var _cur_uid: String = ""      ## 記憶庫以 id 為 key(顯示名稱會改,id 不會)

var _hotwords: PackedStringArray = []
## 對話延續窗:叫過一次名字後,同一個人在窗內講話不用再叫。
## 沒這個的話,連續對話每句都得喊「Doro」,講到一半沒喊就被當閒聊丟掉,
## 從使用者角度看就是「Doro 突然不理人」
const CONTINUE_SEC: float = 40.0
var _talker: String = ""            ## 正在跟 Doro 對話的人
var _talk_until_ms: int = 0         ## 這個窗什麼時候過期
var _voice: Node = null             ## 借它的 _match_recent_spoken 擋跨網路回音

func _exit_tree() -> void:
	_kill_sidecar()

func _ready() -> void:
	## 跟著 _enabled 走,不要硬關:節點加到「還沒 ready 的父節點」時 _ready 會延後,
	## 可能排在 set_enabled(true) 之後跑,硬關會把已經開好的 process 蓋掉,
	## WS 就永遠停在 CONNECTING(poll 沒人呼叫)
	set_process(_enabled)

func setup(voice_client: Node, api_key: String, hotwords: String) -> void:
	_voice = voice_client
	_stt = ByteplusSTT.new()
	_stt.name = "DiscordSTT"
	_stt.api_key = api_key
	_stt.recognized.connect(_on_stt_ok)
	_stt.failed.connect(_on_stt_fail)
	add_child(_stt)
	set_hotwords(hotwords)

func set_api_key(k: String) -> void:
	if _stt != null:
		_stt.api_key = k

## 熱詞閘門用的觸發詞。沿用設定裡那份 stt_hotwords——
## 它本來就是「Doro」的常見誤聽變體清單(洛狗、格洛、佐羅…),正好拿來當召喚詞
func set_hotwords(s: String) -> void:
	_hotwords = PackedStringArray()
	for w in s.replace("、", ",").replace("，", ",").split(","):
		var t: String = w.strip_edges()
		if t != "":
			_hotwords.append(t.to_lower())
	if _stt != null:
		_stt.hotwords = _hotwords

func set_url(u: String) -> void:
	_url = u.strip_edges() if u.strip_edges() != "" else DEFAULT_URL

func get_url() -> String:
	return _url

## Bot token 存在這邊、用在 sidecar。sidecar 是獨立進程,讀不到 Godot 的設定,
## 所以連上之後由我們把 token 送過去讓它登入。
## 留空的話 sidecar 會退回讀自己的 DISCORD_BOT_TOKEN 環境變數。
func set_token(t: String) -> void:
	_token = t.strip_edges()

func get_token() -> String:
	return _token

func is_enabled() -> bool:
	return _enabled

func is_in_channel() -> bool:
	return _enabled and _in_channel

## 誰把 Doro 叫進頻道的(視為主人)
func get_invoker() -> String:
	return _invoker

## 開:開始連 sidecar。關:斷線並清空待辨識佇列
func set_enabled(on: bool) -> void:
	if _enabled == on:
		return
	_enabled = on
	if on:
		_reconnect_at_ms = 0
		_spawn_tried = false
		set_process(true)
		_connect_now()
	else:
		_close()
		_kill_sidecar()
		set_process(false)
		_queue.clear()
		_stt_busy = false
		_in_channel = false
		_invoker = ""
		channel_state.emit(false, "")
	DoroLogger.log("discord_enabled", {"on": on, "url": _url})

## ---------- 自動啟動 sidecar ----------
## 連不上就自己把 sidecar 拉起來,省得每次都要開終端機跑腳本。
## 已經有人在跑(你手動啟動的)就直接接上去,不會重複啟動。
const NODE_CANDIDATES: PackedStringArray = [
	"/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node",
	"/opt/homebrew/opt/node/bin/node",
]

func _find_node() -> String:
	for p in NODE_CANDIDATES:
		if FileAccess.file_exists(p):
			return p
	## 不在常見位置 → 問 shell(login shell 才吃得到 nvm/homebrew 的 PATH)
	var out: Array = []
	if OS.execute("/bin/bash", ["-lc", "command -v node"], out, false) == 0 and out.size() > 0:
		var p2: String = String(out[0]).strip_edges()
		if p2 != "" and FileAccess.file_exists(p2):
			return p2
	return ""

## 回傳 sidecar 的 index.js 絕對路徑;找不到回 ""(export 版不含 discord_bridge/)
func _sidecar_script() -> String:
	var p: String = ProjectSettings.globalize_path("res://discord_bridge/index.js")
	return p if FileAccess.file_exists(p) else ""

func _spawn_sidecar() -> bool:
	if _spawn_tried:
		return false
	_spawn_tried = true
	var script: String = _sidecar_script()
	if script == "":
		DoroLogger.log("discord_spawn_skip", {"reason": "找不到 discord_bridge/index.js"})
		return false
	var node_bin: String = _find_node()
	if node_bin == "":
		DoroLogger.log("discord_spawn_skip", {"reason": "找不到 node"})
		return false
	var dir: String = script.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir.path_join("node_modules")):
		DoroLogger.log("discord_spawn_skip", {"reason": "沒裝依賴,先跑 npm install"})
		return false
	var log_path: String = ProjectSettings.globalize_path("user://logs/discord_bridge.log")
	## 走 bash 是為了設環境變數 + 把 sidecar 的輸出留下來(出事才查得到)。
	## 結尾一定要 exec:不然 bash 會 fork 出 node 自己在旁邊等,
	## OS.kill 拿到的是 bash 的 pid,殺了 bash 但 node 活著變孤兒
	var cmd: String = "cd %s && export DORO_BRIDGE_AUTO=1 DORO_BRIDGE_PORT=%s && exec %s index.js >> %s 2>&1" % [
		_sh_quote(dir), _sh_quote(_port_of(_url)), _sh_quote(node_bin), _sh_quote(log_path)]
	var pid: int = OS.create_process("/bin/bash", ["-c", cmd])
	if pid <= 0:
		DoroLogger.log("discord_spawn_fail", {"node": node_bin})
		return false
	_sidecar_pid = pid
	DoroLogger.log("discord_spawn", {"pid": pid, "node": node_bin, "log": log_path})
	return true

func _kill_sidecar() -> void:
	if _sidecar_pid <= 0:
		return
	OS.kill(_sidecar_pid)
	DoroLogger.log("discord_spawn_kill", {"pid": _sidecar_pid})
	_sidecar_pid = -1

static func _sh_quote(s: String) -> String:
	return "'" + s.replace("'", "'\\''") + "'"

static func _port_of(u: String) -> String:
	var parts: PackedStringArray = u.split(":")
	return parts[parts.size() - 1].strip_edges() if parts.size() >= 3 else "8765"

func _connect_now() -> void:
	_ws = WebSocketPeer.new()
	_ws.inbound_buffer_size = WS_BUF_SIZE
	_ws.outbound_buffer_size = WS_BUF_SIZE
	var err: int = _ws.connect_to_url(_url)
	if err != OK:
		DoroLogger.log("discord_ws_error", {"stage": "connect", "err": err})
		_ws = null
		_spawn_sidecar()      ## 多半是沒人在 listen → 自己把它拉起來
		_schedule_reconnect()

func _close() -> void:
	if _ws != null:
		_ws.close()
		_ws = null
	if _was_open:
		_was_open = false
		bridge_connected.emit(false)

func _schedule_reconnect() -> void:
	_reconnect_at_ms = Time.get_ticks_msec() + int(RECONNECT_SEC * 1000.0)

func _process(_dt: float) -> void:
	if not _enabled:
		return
	if _ws == null:
		if _reconnect_at_ms > 0 and Time.get_ticks_msec() >= _reconnect_at_ms:
			_reconnect_at_ms = 0
			_connect_now()
		return
	_ws.poll()
	var st: int = _ws.get_ready_state()
	if st == WebSocketPeer.STATE_OPEN:
		if not _was_open:
			_was_open = true
			bridge_connected.emit(true)
			DoroLogger.log("discord_bridge_up", {"url": _url, "has_token": _token != ""})
			if _token != "":
				_ws.send_text(JSON.stringify({"type": "login", "token": _token}))
		while _ws.get_available_packet_count() > 0:
			_handle_packet(_ws.get_packet())
	elif st == WebSocketPeer.STATE_CLOSED:
		DoroLogger.log("discord_bridge_down", {
			"code": _ws.get_close_code(), "reason": _ws.get_close_reason()})
		## 從沒連上過就斷 = sidecar 根本沒跑 → 自動啟動一次
		if not _was_open:
			_spawn_sidecar()
		_close()
		_in_channel = false
		_invoker = ""
		channel_state.emit(false, "")
		_schedule_reconnect()

func _handle_packet(raw: PackedByteArray) -> void:
	var parser: JSON = JSON.new()
	if parser.parse(raw.get_string_from_utf8()) != OK:
		return
	var msg: Variant = parser.data
	if typeof(msg) != TYPE_DICTIONARY:
		return
	var d: Dictionary = msg
	match String(d.get("type", "")):
		"ready":
			DoroLogger.log("discord_sidecar_ready", {
				"logged_in": bool(d.get("logged_in", false))})
		"login_result":
			var ok: bool = bool(d.get("ok", false))
			DoroLogger.log("discord_login", {
				"ok": ok, "bot": String(d.get("bot", "")),
				"error": String(d.get("error", ""))})
			login_result.emit(ok, String(d.get("bot", "")) if ok else String(d.get("error", "")))
		"joined":
			_in_channel = true
			_invoker = String(d.get("invoker_name", ""))
			channel_state.emit(true, _invoker)
			DoroLogger.log("discord_joined", {
				"channel": String(d.get("channel_id", "")), "invoker": _invoker})
		"left":
			_in_channel = false
			_invoker = ""
			_talker = ""
			_talk_until_ms = 0
			_queue.clear()
			channel_state.emit(false, "")
			DoroLogger.log("discord_left", {})
		"speech":
			_enqueue_speech(d)

func _enqueue_speech(d: Dictionary) -> void:
	var b64: String = String(d.get("wav_b64", ""))
	if b64 == "":
		return
	var wav: PackedByteArray = Marshalls.base64_to_raw(b64)
	if wav.size() < 44:
		return
	_queue.append({"wav": wav, "user_name": String(d.get("user_name", "?")),
		"user_id": String(d.get("user_id", ""))})
	if _queue.size() > MAX_QUEUE:
		var dropped: Dictionary = _queue.pop_front()
		DoroLogger.log("discord_speech_dropped", {
			"reason": "queue full", "user": String(dropped.get("user_name", "?"))})
	_pump_queue()

## STT 一次只能跑一個(start() 開頭會 cancel 掉前一個),所以排隊逐一送
func _pump_queue() -> void:
	if _stt_busy or _queue.is_empty() or _stt == null:
		return
	var item: Dictionary = _queue.pop_front()
	_cur_user = String(item.get("user_name", "?"))
	_cur_uid = String(item.get("user_id", ""))
	_stt_busy = true
	_stt.call("start", item["wav"])

func _on_stt_fail(reason: String) -> void:
	DoroLogger.log("discord_stt_error", {"reason": reason, "user": _cur_user})
	_stt_busy = false
	_pump_queue()

func _on_stt_ok(text: String) -> void:
	var user: String = _cur_user
	var uid: String = _cur_uid
	_stt_busy = false
	var t: String = text.strip_edges()
	if t != "":
		_consider(t, user, uid)
	_pump_queue()

## 收到的話要不要送 LLM。兩道關卡,順序不能顛倒。
func _consider(text: String, user: String, uid: String = "") -> void:
	## 1. 回音:頻道裡有人開喇叭的話,Doro 自己的聲音會被那個人的麥克風收回來,
	##    變成「那個人說的話」送回來。而 Doro 幾乎每句都自稱 Doro → 必過熱詞閘門,
	##    不先擋就會無限自問自答
	if _voice != null and _voice.has_method("_match_recent_spoken"):
		var matched: String = String(_voice.call("_match_recent_spoken", text))
		if matched != "":
			DoroLogger.log("discord_echo_dropped", {
				"text": text.substr(0, 60), "matched": matched.substr(0, 40), "user": user})
			return
	## 2. 熱詞閘門:語音頻道是多人閒聊,不是每句都在跟 Doro 講話。
	##    沒叫到牠就只做 STT 不送 LLM(STT 便宜,LLM 貴一個量級)。
	##    但對話進行中的接續不該被擋 —— 那是同一段對話,不是新的搭話
	var by_hotword: bool = _has_hotword(text)
	var continuing: bool = user == _talker and Time.get_ticks_msec() < _talk_until_ms
	if not by_hotword and not continuing:
		DoroLogger.log("discord_no_hotword", {"text": text.substr(0, 60), "user": user})
		return
	_talker = user
	_extend_talk_window()
	DoroLogger.log("discord_speech", {
		"user": user, "text": text, "by": "hotword" if by_hotword else "continuing"})
	speech_recognized.emit(text, user, uid)

## 每次對話往來都把窗往後推,聊得順就一直有效;安靜下來才收掉
func _extend_talk_window() -> void:
	_talk_until_ms = Time.get_ticks_msec() + int(CONTINUE_SEC * 1000.0)

## STT 常把英文名字逐字母吐出來(實測「Doro」→「D O R O」),
## 直接比對就對不上,使用者明明喊了名字卻被當閒聊擋掉。
## 比對前把空白與標點清掉,兩邊都正規化
const HOTWORD_STRIP: String = " \t\n\r，,。.、!！?？~〜-_·・:：;；\"\'「」()（）"

static func _norm_hotword(s: String) -> String:
	var out: String = ""
	for i in range(s.length()):
		var ch: String = s[i]
		if not HOTWORD_STRIP.contains(ch):
			out += ch
	return out.to_lower()

func _has_hotword(text: String) -> bool:
	if _hotwords.is_empty():
		return true          ## 沒設熱詞 = 不過濾
	var low: String = _norm_hotword(text)
	for w in _hotwords:
		if low.contains(_norm_hotword(w)):
			return true
	return false

## Doro 講的話 → 送進頻道
func send_tts_wav(wav: PackedByteArray) -> void:
	if not is_in_channel() or _ws == null or _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	if wav.is_empty():
		return
	_extend_talk_window()   ## 牠回話花的時間不該吃掉主人接話的窗
	_ws.send_text(JSON.stringify({
		"type": "speak", "wav_b64": Marshalls.raw_to_base64(wav)}))

## 打斷:清掉頻道那端還沒播的
func stop_speaking() -> void:
	if _ws != null and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_ws.send_text(JSON.stringify({"type": "stop"}))
