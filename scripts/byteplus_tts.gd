extends Node
## BytePlus(火山國際版)聲音復刻 TTS 客戶端
## 走 v1 經典 API:POST /api/v1/tts,APP ID + Access Token 認證,
## cluster=volcano_icl(即時克隆音色),回應 JSON {code:3000, data:base64 WAV}。

signal chunk_ready(path: String, idx: int)
signal finished_generating(ok_count: int)
signal failed_first(reason: String)

const DoroLogger := preload("res://scripts/logger.gd")
const VoiceboxTTS := preload("res://scripts/voicebox_tts.gd")   ## 借用切句/繁簡/去符號

var endpoint: String = "https://voice.ap-southeast-1.bytepluses.com"
var app_id: String = ""
var access_token: String = ""
var cluster: String = "volcano_icl"   ## 即時克隆;訂閱制大模型克隆用 volcano_mega
var speaker: String = ""              ## S_ 開頭音色 ID

var _http: HTTPRequest
var _session: int = 0
var _chunks: PackedStringArray = []
var _idx: int = 0
var _ok_count: int = 0
var _busy: bool = false
var _started_ms: int = 0

func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = 30.0
	_http.request_completed.connect(_on_http_completed)
	add_child(_http)

func is_generating() -> bool:
	return _busy

func cancel() -> void:
	_session += 1
	_busy = false
	_http.cancel_request()

func start(text: String) -> void:
	cancel()
	if app_id.strip_edges() == "" or access_token.strip_edges() == "" or speaker.strip_edges() == "":
		failed_first.emit("BytePlus 未設定(APP ID / Access Token / Speaker ID)")
		return
	## 雲端快,整句一次送;超長才切句(同 bailian 策略)
	var clean: String = VoiceboxTTS.to_simplified(VoiceboxTTS.sanitize(text))
	if clean.length() <= 120:
		_chunks = PackedStringArray([clean]) if clean.strip_edges() != "" else PackedStringArray()
	else:
		_chunks = VoiceboxTTS._prepare_chunks(text)
	if _chunks.is_empty():
		failed_first.emit("清完符號後沒有可念的文字")
		return
	_ok_count = 0
	_idx = 0
	_busy = true
	_started_ms = Time.get_ticks_msec()
	DoroLogger.log("tts_bp_start", {"chunks": _chunks.size(), "speaker": speaker})
	_submit_current()

func _fail(reason: String) -> void:
	var first: bool = _ok_count == 0
	DoroLogger.log("tts_bp_error", {"reason": reason, "chunk": _idx, "first": first})
	_busy = false
	if first:
		failed_first.emit(reason)
	else:
		finished_generating.emit(_ok_count)

static func _uuid() -> String:
	return "%08x-%04x-%04x-%04x-%012x" % [
		randi(), randi() & 0xffff, randi() & 0xffff, randi() & 0xffff,
		(randi() << 16) | (randi() & 0xffff)]

func _submit_current() -> void:
	var s: int = _session
	var body: String = JSON.stringify({
		"app": {"appid": app_id, "token": access_token, "cluster": cluster},
		"user": {"uid": "doropet"},
		"audio": {"voice_type": speaker, "encoding": "wav"},
		"request": {"reqid": _uuid(), "text": _chunks[_idx], "operation": "query"},
	})
	var headers: PackedStringArray = [
		"Content-Type: application/json",
		"Authorization: Bearer;" + access_token,
	]
	var err: int = _http.request(
		endpoint.rstrip("/") + "/api/v1/tts",
		headers, HTTPClient.METHOD_POST, body)
	if err != OK and s == _session:
		_fail("送出生成請求失敗(err=%d)" % err)

func _on_http_completed(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
	if not _busy:
		return
	if result != HTTPRequest.RESULT_SUCCESS:
		_fail("BytePlus 沒回應(network result=%d)" % result)
		return
	var text: String = body.get_string_from_utf8()
	if code < 200 or code >= 300:
		_fail("BytePlus HTTP %d: %s" % [code, text.substr(0, 200)])
		return
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		_fail("BytePlus 回覆格式異常")
		return
	var d: Dictionary = parsed
	if int(d.get("code", 0)) != 3000:
		_fail("BytePlus code %d: %s" % [int(d.get("code", 0)), String(d.get("message", ""))])
		return
	var b64: String = String(d.get("data", ""))
	if b64 == "":
		_fail("BytePlus 沒回音訊資料")
		return
	var wav: PackedByteArray = Marshalls.base64_to_raw(b64)   ## encoding=wav → 直接是 WAV 檔
	var path: String = "user://doro_bp_%d_%d.wav" % [_session, _idx]
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_fail("無法寫入音檔")
		return
	f.store_buffer(wav)
	f.close()
	_ok_count += 1
	DoroLogger.log("tts_bp_chunk", {
		"chunk": _idx, "total": _chunks.size(), "bytes": wav.size(),
		"elapsed_ms": Time.get_ticks_msec() - _started_ms,
	})
	chunk_ready.emit(path, _idx)
	_idx += 1
	if _idx >= _chunks.size():
		_busy = false
		finished_generating.emit(_ok_count)
	else:
		_submit_current()
