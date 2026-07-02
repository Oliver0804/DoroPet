extends Node
## BytePlus 串流 ASR 2.0(sauc)客戶端 — nostream 模式
## 錄完整段後:WebSocket 連線 → 送參數 frame → 整段音訊一包(標最後) → 等最終結果
## 二進位協議:4B header + 4B payload size(big-endian) + payload;不壓縮、JSON 序列化
## 實測含連線 ~1.1s,輸出直接是台灣繁體(output_zh_variant=tw)

signal recognized(text: String)
signal failed(reason: String)
signal utterance(text: String)      ## 常駐 session 模式:每句 definite 斷句結果
signal session_changed(up: bool)    ## 常駐連線建立/斷開

const DoroLogger := preload("res://scripts/logger.gd")
## async 雙通道模式:不送 last flag,音訊後補靜音讓 VAD 斷句,
## definite 結果會在連線存活時以一般訊息送達 → 避開「伺服器回完就關線,
## Godot 輪詢來不及讀」的競態(nostream 模式在 Godot 上必踩)
var url: String = "wss://voice.ap-southeast-1.bytepluses.com/api/v3/sauc/bigmodel_async"
const RESOURCE_ID: String = "volc.seedasr.sauc.duration"
const TIMEOUT_MS: int = 12000

var api_key: String = ""
var hotwords: PackedStringArray = []   ## 常聽錯的專有名詞(洛狗、人名等)

var _ws: WebSocketPeer
var _wav: PackedByteArray
var _active: bool = false
var _sent_req: bool = false
var _got_ack: bool = false      ## 參數 frame 的 ack 收到後才送音訊
var _send_pos: int = 0          ## 音訊已送到的 offset(分幀節流送)
var _deadline_ms: int = 0
var _drain_deadline_ms: int = 0 ## 靜音送完後的等待上限(空白錄音時 VAD 不會斷句)

## --- 常駐 session(連線保持,音訊持續推送,伺服器 VAD 斷句) ---
var _session_mode: bool = false
var _reconnect_at_ms: int = 0   ## 斷線重連的排程時間(0=不重連)

func is_active() -> bool:
	return _active

func cancel() -> void:
	_active = false
	_session_mode = false
	_reconnect_at_ms = 0
	if _ws != null:
		_ws.close()
		_ws = null

static func _uuid() -> String:
	return "%08x-%04x-%04x-%04x-%012x" % [
		randi(), randi() & 0xffff, randi() & 0xffff, randi() & 0xffff,
		(randi() << 16) | (randi() & 0xffff)]

## ---------- 常駐 session ----------
func session_start() -> void:
	cancel()
	if api_key.strip_edges() == "":
		failed.emit("未設定 BytePlus API Key")
		return
	_session_mode = true
	_open_session_ws()

func _open_session_ws() -> void:
	_sent_req = false
	_got_ack = false
	_ws = WebSocketPeer.new()
	_ws.outbound_buffer_size = 4 << 20
	_ws.inbound_buffer_size = 1 << 20
	_ws.handshake_headers = PackedStringArray([
		"X-Api-Key: " + api_key,
		"X-Api-Resource-Id: " + RESOURCE_ID,
		"X-Api-Connect-Id: " + _uuid(),
	])
	if _ws.connect_to_url(url) != OK:
		_ws = null
		_schedule_reconnect()
		return
	_active = true

func session_stop() -> void:
	cancel()
	session_changed.emit(false)

func is_session_up() -> bool:
	return _session_mode and _got_ack and _ws != null \
		and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN

## 持續推 16k s16 mono 的 raw pcm(呼叫端已 resample)
func session_push(pcm: PackedByteArray) -> void:
	if not is_session_up() or pcm.is_empty():
		return
	_ws.send(_frame(0b0010, 0b0000, 0b0000, pcm), WebSocketPeer.WRITE_MODE_BINARY)

func _schedule_reconnect() -> void:
	if _session_mode:
		_reconnect_at_ms = Time.get_ticks_msec() + 1200
		session_changed.emit(false)

func start(wav: PackedByteArray) -> void:
	cancel()
	if api_key.strip_edges() == "":
		failed.emit("未設定 BytePlus API Key")
		return
	_wav = wav
	_sent_req = false
	_got_ack = false
	_send_pos = 0
	_drain_deadline_ms = 0
	_deadline_ms = Time.get_ticks_msec() + TIMEOUT_MS
	_ws = WebSocketPeer.new()
	## 預設 outbound buffer 只有 64KB,長錄音一包會塞不下 → 加大 + 分塊送
	_ws.outbound_buffer_size = 4 << 20
	_ws.inbound_buffer_size = 1 << 20
	_ws.handshake_headers = PackedStringArray([
		"X-Api-Key: " + api_key,
		"X-Api-Resource-Id: " + RESOURCE_ID,
		"X-Api-Connect-Id: %08x-%04x-%04x-%04x-%012x" % [
			randi(), randi() & 0xffff, randi() & 0xffff, randi() & 0xffff,
			(randi() << 16) | (randi() & 0xffff)],
	])
	var err: int = _ws.connect_to_url(url)
	if err != OK:
		_ws = null
		failed.emit("WebSocket 連線失敗 (err=%d)" % err)
		return
	_active = true

func _process(_dt: float) -> void:
	## session 斷線重連排程
	if _session_mode and _ws == null and _reconnect_at_ms > 0 \
			and Time.get_ticks_msec() >= _reconnect_at_ms:
		_reconnect_at_ms = 0
		_open_session_ws()
	if not _active or _ws == null:
		return
	_ws.poll()
	if not _session_mode and Time.get_ticks_msec() > _deadline_ms:
		_fail("辨識超時")
		return
	match _ws.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			if not _sent_req:
				_sent_req = true
				_send_frames()
			elif not _session_mode and _got_ack and _send_pos < _wav.size() + SILENCE_TAIL * 6400:
				_send_audio_step()
			elif not _session_mode and _drain_deadline_ms > 0 and Time.get_ticks_msec() > _drain_deadline_ms:
				_fail("沒辨識到內容")   ## 靜音送完仍無 definite → 大概是空白錄音
				return
			while _ws.get_available_packet_count() > 0:
				_handle_packet(_ws.get_packet())
				if not _active:
					return
		WebSocketPeer.STATE_CLOSING, WebSocketPeer.STATE_CLOSED:
			## 先把殘留封包撈完
			while _ws != null and _ws.get_available_packet_count() > 0:
				_handle_packet(_ws.get_packet())
				if not _active:
					return
			if _ws != null and _ws.get_ready_state() == WebSocketPeer.STATE_CLOSED:
				if _session_mode:
					## 常駐模式:斷線自動重連
					_active = false
					_ws = null
					_schedule_reconnect()
				else:
					_fail("連線被關閉 (code=%d)" % _ws.get_close_code())

func _fail(reason: String) -> void:
	if not _active:
		return
	_active = false
	if _ws != null:
		_ws.close()
		_ws = null
	failed.emit(reason)

func _done(text: String) -> void:
	_active = false
	if _ws != null:
		_ws.close()
		_ws = null
	recognized.emit(text)

## ---------- 協議封裝 ----------
## header: [0x11, type<<4|flags, serialization<<4|compression, 0x00] + u32be size + payload
static func _frame(msg_type: int, flags: int, serialization: int, payload: PackedByteArray) -> PackedByteArray:
	var buf: PackedByteArray = PackedByteArray([
		0x11, (msg_type << 4) | flags, (serialization << 4) | 0x0, 0x00])
	var n: int = payload.size()
	buf.append_array(PackedByteArray([(n >> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff]))
	buf.append_array(payload)
	return buf

func _send_frames() -> void:
	## session 模式推的是 raw pcm(無 wav 頭);一次性模式送整個 wav 檔
	var req: Dictionary = {
		"user": {"uid": "doropet"},
		"audio": {"format": "pcm" if _session_mode else "wav",
			"codec": "raw", "rate": 16000, "bits": 16, "channel": 1},
		"request": {
			"model_name": "bigmodel",
			"output_zh_variant": "tw",
			"enable_itn": true,
			"enable_punc": true,
			"show_utterances": true,
			"enable_nonstream": true,     ## 雙通道:VAD 斷句後二次辨識,definite=true
			"end_window_size": 800,
			"force_to_speech_time": 1000,
			"result_type": "single" if _session_mode else "full",   ## 常駐模式取增量,避免舊句累積
		},
	}
	if hotwords.size() > 0:
		var hw: Array = []
		for w in hotwords:
			if String(w).strip_edges() != "":
				hw.append({"word": String(w).strip_edges()})
		if not hw.is_empty():
			req["request"]["corpus"] = {"context": JSON.stringify({"hotwords": hw})}
	## full client request(type 0b0001, JSON);等 ack 後才送音訊(見 _send_audio)
	var err: int = _ws.send(_frame(0b0001, 0b0000, 0b0001, JSON.stringify(req).to_utf8_buffer()))
	if err != OK:
		_fail("送參數失敗 (err=%d)" % err)

const SILENCE_TAIL: int = 20      ## 音訊送完後補 20 包 × 200ms 靜音(給 VAD 斷句用)

## 每個 _process tick 送 2 包(200ms 音訊/包);全部不標 last,
## 音訊送完接著送靜音,等 definite 結果來了自己關線
func _send_audio_step() -> void:
	for _i in 2:
		if _send_pos >= _wav.size() + SILENCE_TAIL * 6400:
			return
		var chunk: PackedByteArray
		if _send_pos < _wav.size():
			chunk = _wav.slice(_send_pos, mini(_send_pos + 6400, _wav.size()))
		else:
			chunk = PackedByteArray()
			chunk.resize(6400)   ## 全零 = 靜音
		var err: int = _ws.send(_frame(0b0010, 0b0000, 0b0000, chunk), WebSocketPeer.WRITE_MODE_BINARY)
		if err != OK:
			_fail("送音訊失敗 (err=%d, offset=%d)" % [err, _send_pos])
			return
		_send_pos += chunk.size()
		if _send_pos >= _wav.size() + SILENCE_TAIL * 6400:
			_drain_deadline_ms = Time.get_ticks_msec() + 2500

func _handle_packet(msg: PackedByteArray) -> void:
	if msg.size() < 8:
		return
	var mtype: int = msg[1] >> 4
	var mflags: int = msg[1] & 0xf
	if OS.get_environment("DORO_WS_DEBUG") != "":
		print("[ws pkt] size=", msg.size(), " type=", mtype, " flags=", mflags,
			" b2=", msg[2], " full=", msg.slice(12 if (mflags & 1) else 8).get_string_from_utf8())
	if mtype == 0b1111:
		var ecode: int = (msg[4] << 24) | (msg[5] << 16) | (msg[6] << 8) | msg[7]
		var emsg: String = msg.slice(12).get_string_from_utf8().substr(0, 150)
		_fail("ASR 錯誤 code=%d %s" % [ecode, emsg])
		return
	if mtype != 0b1001:
		return
	if not _got_ack:
		## 第一個 server response = 參數 ack
		_got_ack = true
		if _session_mode:
			session_changed.emit(true)
		return
	var off: int = 4
	if mflags & 0b0001:
		off += 4   ## sequence
	if msg.size() < off + 4:
		return
	var psize: int = (msg[off] << 24) | (msg[off + 1] << 16) | (msg[off + 2] << 8) | msg[off + 3]
	var payload: PackedByteArray = msg.slice(off + 4, off + 4 + psize)
	var parsed: Variant = JSON.parse_string(payload.get_string_from_utf8())
	var text: String = ""
	var definite: bool = false
	var def_text: String = ""    ## 本包內 definite 斷句的文字(session 用)
	if typeof(parsed) == TYPE_DICTIONARY:
		var res: Variant = (parsed as Dictionary).get("result", {})
		if typeof(res) == TYPE_DICTIONARY:
			text = String((res as Dictionary).get("text", ""))
			for u in (res as Dictionary).get("utterances", []):
				if typeof(u) == TYPE_DICTIONARY and bool(u.get("definite", false)):
					definite = true
					def_text += String(u.get("text", ""))
	## 雙通道:VAD 斷句後的 definite 結果 = 我們要的最終文字
	if _session_mode:
		if def_text.strip_edges() != "":
			utterance.emit(def_text.strip_edges())
		return   ## 常駐模式不關線,繼續收下一句
	if definite or (mflags & 0b0010):
		_done(text.strip_edges())
