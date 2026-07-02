extends Node
## BytePlus 串流 ASR 2.0(sauc)客戶端 — nostream 模式
## 錄完整段後:WebSocket 連線 → 送參數 frame → 整段音訊一包(標最後) → 等最終結果
## 二進位協議:4B header + 4B payload size(big-endian) + payload;不壓縮、JSON 序列化
## 實測含連線 ~1.1s,輸出直接是台灣繁體(output_zh_variant=tw)

signal recognized(text: String)
signal failed(reason: String)

const DoroLogger := preload("res://scripts/logger.gd")
## async 雙通道模式:不送 last flag,音訊後補靜音讓 VAD 斷句,
## definite 結果會在連線存活時以一般訊息送達 → 避開「伺服器回完就關線,
## Godot 輪詢來不及讀」的競態(nostream 模式在 Godot 上必踩)
var url: String = "wss://voice.ap-southeast-1.bytepluses.com/api/v3/sauc/bigmodel_async"
const RESOURCE_ID: String = "volc.seedasr.sauc.duration"
const TIMEOUT_MS: int = 12000

var api_key: String = ""

var _ws: WebSocketPeer
var _wav: PackedByteArray
var _active: bool = false
var _sent_req: bool = false
var _got_ack: bool = false      ## 參數 frame 的 ack 收到後才送音訊
var _send_pos: int = 0          ## 音訊已送到的 offset(分幀節流送)
var _deadline_ms: int = 0

func is_active() -> bool:
	return _active

func cancel() -> void:
	_active = false
	if _ws != null:
		_ws.close()
		_ws = null

func start(wav: PackedByteArray) -> void:
	cancel()
	if api_key.strip_edges() == "":
		failed.emit("未設定 BytePlus API Key")
		return
	_wav = wav
	_sent_req = false
	_got_ack = false
	_send_pos = 0
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
	if not _active or _ws == null:
		return
	_ws.poll()
	if Time.get_ticks_msec() > _deadline_ms:
		_fail("辨識超時")
		return
	match _ws.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			if not _sent_req:
				_sent_req = true
				_send_frames()
			elif _got_ack and _send_pos < _wav.size() + SILENCE_TAIL * 6400:
				_send_audio_step()
			while _ws.get_available_packet_count() > 0:
				_handle_packet(_ws.get_packet())
				if not _active:
					return
		WebSocketPeer.STATE_CLOSING, WebSocketPeer.STATE_CLOSED:
			## 伺服器回完結果就關線;先把殘留封包撈完再判定失敗
			while _ws != null and _ws.get_available_packet_count() > 0:
				_handle_packet(_ws.get_packet())
				if not _active:
					return
			if _ws != null and _ws.get_ready_state() == WebSocketPeer.STATE_CLOSED:
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
	var req: Dictionary = {
		"user": {"uid": "doropet"},
		"audio": {"format": "wav", "codec": "raw", "rate": 16000, "bits": 16, "channel": 1},
		"request": {
			"model_name": "bigmodel",
			"output_zh_variant": "tw",
			"enable_itn": true,
			"enable_punc": true,
			"show_utterances": true,
			"enable_nonstream": true,     ## 雙通道:VAD 斷句後二次辨識,definite=true
			"end_window_size": 800,
			"force_to_speech_time": 1000,
		},
	}
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
		## 第一個 server response = 參數 ack → 之後由 _process 分幀送音訊
		_got_ack = true
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
	if typeof(parsed) == TYPE_DICTIONARY:
		var res: Variant = (parsed as Dictionary).get("result", {})
		if typeof(res) == TYPE_DICTIONARY:
			text = String((res as Dictionary).get("text", ""))
			for u in (res as Dictionary).get("utterances", []):
				if typeof(u) == TYPE_DICTIONARY and bool(u.get("definite", false)):
					definite = true
	## 雙通道:VAD 斷句後的 definite 結果 = 我們要的最終文字
	if definite or (mflags & 0b0010):
		_done(text.strip_edges())
