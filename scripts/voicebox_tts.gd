extends Node
## Voicebox 本機 TTS 客戶端（預設 http://127.0.0.1:17493）
## 流程：切句 → 繁轉簡+去符號 → POST /generate → 輪詢 /history/{id}
##       → 下載 WAV → chunk_ready 交給 voice_client 播放
## 一次只跑一個生成 session；新的 start() 會取消舊的。

signal chunk_ready(path: String, idx: int)
signal finished_generating(ok_count: int)
signal failed_first(reason: String)

const CLIENT_HEADERS: PackedStringArray = [
	"X-Voicebox-Client-Id: doropet",
	"Content-Type: application/json",
]
const POLL_INTERVAL: float = 0.4
const GEN_TIMEOUT_MS: int = 90000
const T2S_PATH: String = "res://assets/t2s.txt"
const DoroLogger := preload("res://scripts/logger.gd")

var endpoint: String = "http://127.0.0.1:17493"
var profile_name: String = ""
var model_size: String = "0.6B"

var _http: HTTPRequest
var _poll_timer: Timer
var _session: int = 0
var _chunks: PackedStringArray = []
var _idx: int = 0
var _gen_id: String = ""
var _profile_id: String = ""
var _profile_id_for: String = ""    ## _profile_id 是哪個 name+endpoint 解析的
var _phase: String = ""             ## "profile" | "submit" | "poll" | "download"
var _deadline_ms: int = 0
var _ok_count: int = 0
var _started_ms: int = 0

static var _t2s: Dictionary = {}
static var _t2s_loaded: bool = false

func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = 30.0
	_http.request_completed.connect(_on_http_completed)
	add_child(_http)
	_poll_timer = Timer.new()
	_poll_timer.one_shot = true
	_poll_timer.wait_time = POLL_INTERVAL
	_poll_timer.timeout.connect(_do_poll)
	add_child(_poll_timer)

func is_generating() -> bool:
	return _phase != ""

func cancel() -> void:
	_session += 1
	_phase = ""
	_poll_timer.stop()
	_http.cancel_request()
	_http.download_file = ""

## ---------- 對外入口 ----------
func start(text: String) -> void:
	cancel()
	_chunks = _prepare_chunks(text)
	if _chunks.is_empty():
		failed_first.emit("清完符號後沒有可念的文字")
		return
	_ok_count = 0
	_idx = 0
	_started_ms = Time.get_ticks_msec()
	DoroLogger.log("tts_vb_start", {"chunks": _chunks.size(), "profile": profile_name})
	## profile id 只在 name/endpoint 變了才重新解析
	if _profile_id != "" and _profile_id_for == profile_name + "@" + endpoint:
		_submit_current()
	else:
		_resolve_profile()

func _fail(reason: String) -> void:
	var first: bool = _ok_count == 0
	DoroLogger.log("tts_vb_error", {"reason": reason, "chunk": _idx, "first": first})
	_phase = ""
	_poll_timer.stop()
	if first:
		failed_first.emit(reason)
	else:
		finished_generating.emit(_ok_count)

## ---------- HTTP 流程 ----------
func _resolve_profile() -> void:
	_phase = "profile"
	var s: int = _session
	var err: int = _http.request(endpoint + "/profiles", CLIENT_HEADERS)
	if err != OK and s == _session:
		_fail("連不上 Voicebox（HTTPRequest err=%d）" % err)

func _submit_current() -> void:
	_phase = "submit"
	var s: int = _session
	var body: String = JSON.stringify({
		"profile_id": _profile_id,
		"text": _chunks[_idx],
		"language": "zh",
		"engine": "qwen",
		"model_size": model_size,
		"personality": false,
		"normalize": true,
	})
	var err: int = _http.request(endpoint + "/generate", CLIENT_HEADERS, HTTPClient.METHOD_POST, body)
	if err != OK and s == _session:
		_fail("送出生成請求失敗（err=%d）" % err)

func _do_poll() -> void:
	if _phase != "poll":
		return
	if Time.get_ticks_msec() > _deadline_ms:
		_fail("生成超時")
		return
	var s: int = _session
	var err: int = _http.request(endpoint + "/history/" + _gen_id, CLIENT_HEADERS)
	if err != OK and s == _session:
		_fail("輪詢失敗（err=%d）" % err)

func _download_current() -> void:
	_phase = "download"
	var s: int = _session
	var path: String = "user://doro_vb_%d_%d.wav" % [_session, _idx]
	_http.download_file = ProjectSettings.globalize_path(path)
	var err: int = _http.request(endpoint + "/history/" + _gen_id + "/export-audio", CLIENT_HEADERS)
	if err != OK and s == _session:
		_http.download_file = ""
		_fail("下載音檔失敗（err=%d）" % err)

func _on_http_completed(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
	var phase: String = _phase
	if phase == "":
		return
	if result != HTTPRequest.RESULT_SUCCESS:
		_http.download_file = ""
		_fail("Voicebox 沒回應（network result=%d）— 服務有開嗎？" % result)
		return
	if code < 200 or code >= 300:
		_http.download_file = ""
		_fail("Voicebox HTTP %d" % code)
		return
	match phase:
		"profile":
			_on_profiles(body)
		"submit":
			_on_submitted(body)
		"poll":
			_on_polled(body)
		"download":
			_on_downloaded()

func _on_profiles(body: PackedByteArray) -> void:
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	var items: Array = []
	if typeof(parsed) == TYPE_ARRAY:
		items = parsed
	elif typeof(parsed) == TYPE_DICTIONARY and (parsed as Dictionary).has("profiles"):
		items = (parsed as Dictionary)["profiles"]
	var names: PackedStringArray = []
	for p in items:
		if typeof(p) != TYPE_DICTIONARY:
			continue
		names.append(String(p.get("name", "")))
		## 沒指定 profile 就拿第一個
		if p.get("name", "") == profile_name or (profile_name == "" and _profile_id == ""):
			_profile_id = String(p.get("id", ""))
			_profile_id_for = profile_name + "@" + endpoint
	if _profile_id == "":
		_fail("Voicebox 找不到 profile「%s」（現有：%s）" % [profile_name, "、".join(names)])
		return
	_submit_current()

func _on_submitted(body: PackedByteArray) -> void:
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		_fail("生成回覆格式異常")
		return
	var d: Dictionary = parsed
	_gen_id = String(d.get("id", d.get("generation_id", "")))
	if _gen_id == "":
		_fail("生成回覆缺 id")
		return
	_phase = "poll"
	_deadline_ms = Time.get_ticks_msec() + GEN_TIMEOUT_MS
	_poll_timer.start()

func _on_polled(body: PackedByteArray) -> void:
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	var status: String = ""
	if typeof(parsed) == TYPE_DICTIONARY:
		status = String((parsed as Dictionary).get("status", ""))
	match status:
		"completed":
			_download_current()
		"failed", "cancelled":
			var err_msg: String = ""
			if typeof(parsed) == TYPE_DICTIONARY:
				err_msg = String((parsed as Dictionary).get("error", ""))
			_fail("生成%s：%s" % [status, err_msg])
		_:
			_poll_timer.start()   ## generating / pending → 再等一輪

func _on_downloaded() -> void:
	var path: String = "user://doro_vb_%d_%d.wav" % [_session, _idx]
	_http.download_file = ""
	_ok_count += 1
	DoroLogger.log("tts_vb_chunk", {
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

## ---------- 文字前處理 ----------
## 切句：先按結尾標點切，太短的併回前句（減少 HTTP 往返），太長的再按逗號切
static func _prepare_chunks(text: String) -> PackedStringArray:
	var raw: PackedStringArray = []
	var cur: String = ""
	for ch in text:
		cur += ch
		## ~ / ～ 也算句尾（Doro 的口癖），反正 sanitize 會把它拿掉
		if "。！？!?；;\n…~～".contains(ch):
			raw.append(cur)
			cur = ""
	if cur != "":
		raw.append(cur)
	## 併短句（< 10 字併進前句）減少 HTTP 往返；但第一段永遠不併，
	## 讓它越短越好 → 首音延遲最低
	var merged: PackedStringArray = []
	for s in raw:
		if merged.size() > 1 and merged[merged.size() - 1].length() < 10:
			merged[merged.size() - 1] += s
		else:
			merged.append(s)
	## 清理 + 繁轉簡；清完是空的段落丟掉
	var out: PackedStringArray = []
	for s in merged:
		var clean: String = to_simplified(sanitize(s))
		if clean.strip_edges() != "":
			out.append(clean)
	return out

## 去掉 TTS 會念出來的符號（括號、markdown、emoji、顏文字素材）
const DROP_CHARS: String = "()（）[]【】《》〈〉「」『』<>*#_`~\"“”'‘’|＊＃"

static func sanitize(text: String) -> String:
	var out: String = ""
	for ch in text:
		var cp: int = ch.unicode_at(0)
		if DROP_CHARS.contains(ch):
			continue
		## emoji / 符號區塊
		if cp >= 0x1F000 or (cp >= 0x2190 and cp <= 0x2BFF) \
				or (cp >= 0xFE00 and cp <= 0xFE0F) or cp == 0x200D:
			continue
		out += ch
	out = out.replace("——", "，").replace("--", "，").replace("…", "。")
	return out.strip_edges()

## 繁 → 簡（Qwen TTS 對繁體會念錯）；表在 assets/t2s.txt，一行「繁簡」兩字
static func to_simplified(text: String) -> String:
	if not _t2s_loaded:
		_t2s_loaded = true
		var f: FileAccess = FileAccess.open(T2S_PATH, FileAccess.READ)
		if f != null:
			for line in f.get_as_text().split("\n"):
				if line.length() >= 2:
					_t2s[line[0]] = line[1]
			f.close()
	if _t2s.is_empty():
		return text
	var out: String = ""
	for ch in text:
		out += _t2s.get(ch, ch)
	return out
