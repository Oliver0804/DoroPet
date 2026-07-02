extends Node
## 阿里雲百炼 Qwen TTS 聲音復刻客戶端（HTTP）
## 流程：切句（沿用 voicebox_tts 的前處理）→ POST generation 拿音檔 URL
##       → 下載 WAV → chunk_ready 交給 voice_client 播放
## 每段兩個 HTTP 往返、無輪詢；一次只跑一個 session，新 start() 取消舊的。

signal chunk_ready(path: String, idx: int)
signal finished_generating(ok_count: int)
signal failed_first(reason: String)

const DoroLogger := preload("res://scripts/logger.gd")
const VoiceboxTTS := preload("res://scripts/voicebox_tts.gd")   ## 借用切句/繁簡/去符號

var endpoint: String = ""        ## https://{WorkspaceId}.{region}.maas.aliyuncs.com
var api_key: String = ""
var model: String = "qwen3-tts-vc-2026-01-22"
var voice: String = ""

var _http: HTTPRequest
var _session: int = 0
var _chunks: PackedStringArray = []
var _idx: int = 0
var _phase: String = ""          ## "generate" | "download"
var _ok_count: int = 0
var _started_ms: int = 0

func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = 30.0
	_http.request_completed.connect(_on_http_completed)
	add_child(_http)

func is_generating() -> bool:
	return _phase != ""

func cancel() -> void:
	_session += 1
	_phase = ""
	_http.cancel_request()
	_http.download_file = ""

func start(text: String) -> void:
	cancel()
	if endpoint.strip_edges() == "" or api_key.strip_edges() == "" or voice.strip_edges() == "":
		failed_first.emit("百炼未設定（endpoint / API key / voice）")
		return
	_chunks = VoiceboxTTS._prepare_chunks(text)
	if _chunks.is_empty():
		failed_first.emit("清完符號後沒有可念的文字")
		return
	_ok_count = 0
	_idx = 0
	_started_ms = Time.get_ticks_msec()
	DoroLogger.log("tts_bl_start", {"chunks": _chunks.size(), "voice": voice})
	_submit_current()

func _fail(reason: String) -> void:
	var first: bool = _ok_count == 0
	DoroLogger.log("tts_bl_error", {"reason": reason, "chunk": _idx, "first": first})
	_phase = ""
	if first:
		failed_first.emit(reason)
	else:
		finished_generating.emit(_ok_count)

func _submit_current() -> void:
	_phase = "generate"
	var s: int = _session
	var body: String = JSON.stringify({
		"model": model,
		"input": {"text": _chunks[_idx], "voice": voice},
	})
	var headers: PackedStringArray = [
		"Authorization: Bearer " + api_key,
		"Content-Type: application/json",
	]
	var err: int = _http.request(
		endpoint.rstrip("/") + "/api/v1/services/aigc/multimodal-generation/generation",
		headers, HTTPClient.METHOD_POST, body)
	if err != OK and s == _session:
		_fail("送出生成請求失敗（err=%d）" % err)

func _on_http_completed(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
	var phase: String = _phase
	if phase == "":
		return
	if result != HTTPRequest.RESULT_SUCCESS:
		_http.download_file = ""
		_fail("百炼沒回應（network result=%d）— 網路正常嗎？" % result)
		return
	if code < 200 or code >= 300:
		_http.download_file = ""
		var msg: String = body.get_string_from_utf8().substr(0, 200)
		_fail("百炼 HTTP %d: %s" % [code, msg])
		return
	if phase == "generate":
		_on_generated(body)
	else:
		_on_downloaded()

func _on_generated(body: PackedByteArray) -> void:
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	var url: String = ""
	if typeof(parsed) == TYPE_DICTIONARY:
		var out: Dictionary = (parsed as Dictionary).get("output", {})
		var audio: Dictionary = out.get("audio", {}) if typeof(out) == TYPE_DICTIONARY else {}
		url = String(audio.get("url", ""))
	if url == "":
		_fail("生成回覆缺 audio.url")
		return
	_phase = "download"
	var s: int = _session
	var path: String = "user://doro_bl_%d_%d.wav" % [_session, _idx]
	_http.download_file = ProjectSettings.globalize_path(path)
	var err: int = _http.request(url)
	if err != OK and s == _session:
		_http.download_file = ""
		_fail("下載音檔失敗（err=%d）" % err)

func _on_downloaded() -> void:
	var path: String = "user://doro_bl_%d_%d.wav" % [_session, _idx]
	_http.download_file = ""
	_ok_count += 1
	DoroLogger.log("tts_bl_chunk", {
		"chunk": _idx, "total": _chunks.size(),
		"elapsed_ms": Time.get_ticks_msec() - _started_ms,
	})
	chunk_ready.emit(path, _idx)
	_idx += 1
	if _idx >= _chunks.size():
		_phase = ""
		finished_generating.emit(_ok_count)
	else:
		_submit_current()
