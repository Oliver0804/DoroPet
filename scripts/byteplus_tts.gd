extends Node
## BytePlus(火山國際版)聲音復刻 TTS 客戶端
## POST /api/v3/tts/unidirectional,回應是 NDJSON 行流,
## 每行 {code,data(base64 音訊塊),message},code 20000000 = 結束。
## 要 pcm 塊自己包 WAV 頭,交給 voice_client 共用播放佇列。

signal chunk_ready(path: String, idx: int)
signal finished_generating(ok_count: int)
signal failed_first(reason: String)

const DoroLogger := preload("res://scripts/logger.gd")
const VoiceboxTTS := preload("res://scripts/voicebox_tts.gd")   ## 借用切句/繁簡/去符號
const SAMPLE_RATE: int = 24000

var endpoint: String = "https://voice.ap-southeast-1.bytepluses.com"
var api_key: String = ""
var resource_id: String = "volc.megatts.default"   ## 聲音復刻 2.0 合成
var speaker: String = ""                            ## S_ 開頭音色 ID

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
	if api_key.strip_edges() == "" or speaker.strip_edges() == "":
		failed_first.emit("BytePlus 未設定(API key / Speaker ID)")
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
		"req_params": {
			"text": _chunks[_idx],
			"speaker": speaker,
			"audio_params": {"format": "pcm", "sample_rate": SAMPLE_RATE},
			"additions": JSON.stringify({"disable_markdown_filter": true}),
		},
	})
	var headers: PackedStringArray = [
		"Content-Type: application/json",
		"X-Api-Key: " + api_key,
		"X-Api-Resource-Id: " + resource_id,
		"X-Api-Request-Id: " + _uuid(),
	]
	var err: int = _http.request(
		endpoint.rstrip("/") + "/api/v3/tts/unidirectional",
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
	## NDJSON 行流 → 串接 base64 音訊塊
	var pcm: PackedByteArray = PackedByteArray()
	for line in text.split("\n"):
		if line.strip_edges() == "":
			continue
		var parsed: Variant = JSON.parse_string(line)
		if typeof(parsed) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = parsed
		## 有些錯誤包在 header 物件裡
		if d.has("header"):
			var hd: Dictionary = d["header"]
			if int(hd.get("code", 0)) != 0 and int(hd.get("code", 0)) != 20000000:
				_fail("BytePlus code %d: %s" % [int(hd.get("code", 0)), String(hd.get("message", ""))])
				return
			continue
		var lc: int = int(d.get("code", 0))
		if lc != 0 and lc != 20000000:
			_fail("BytePlus code %d: %s" % [lc, String(d.get("message", ""))])
			return
		var b64: String = String(d.get("data", ""))
		if b64 != "":
			pcm.append_array(Marshalls.base64_to_raw(b64))
	if pcm.is_empty():
		_fail("BytePlus 沒回音訊資料")
		return
	var path: String = "user://doro_bp_%d_%d.wav" % [_session, _idx]
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_fail("無法寫入音檔")
		return
	f.store_buffer(_wrap_wav(pcm))
	f.close()
	_ok_count += 1
	DoroLogger.log("tts_bp_chunk", {
		"chunk": _idx, "total": _chunks.size(), "bytes": pcm.size(),
		"elapsed_ms": Time.get_ticks_msec() - _started_ms,
	})
	chunk_ready.emit(path, _idx)
	_idx += 1
	if _idx >= _chunks.size():
		_busy = false
		finished_generating.emit(_ok_count)
	else:
		_submit_current()

## raw 16-bit mono pcm → WAV
static func _wrap_wav(pcm: PackedByteArray) -> PackedByteArray:
	var n: int = pcm.size()
	var buf: PackedByteArray = PackedByteArray()
	buf.resize(44)
	buf.encode_u32(0, 0x46464952)            ## "RIFF"
	buf.encode_u32(4, 36 + n)
	buf.encode_u32(8, 0x45564157)            ## "WAVE"
	buf.encode_u32(12, 0x20746d66)           ## "fmt "
	buf.encode_u32(16, 16)
	buf.encode_u16(20, 1)                    ## PCM
	buf.encode_u16(22, 1)                    ## mono
	buf.encode_u32(24, SAMPLE_RATE)
	buf.encode_u32(28, SAMPLE_RATE * 2)
	buf.encode_u16(32, 2)
	buf.encode_u16(34, 16)
	buf.encode_u32(36, 0x61746164)           ## "data"
	buf.encode_u32(40, n)
	buf.append_array(pcm)
	return buf
