extends Node
## 三層輕量記憶
## 1. 短期:對話歷史落盤 user://doro_history.json,重啟不斷片
## 2. 長期:「主人筆記」user://doro_memory.txt(≤500 字),每次對話注入 system prompt
## 3. 蒸餾:每累積 DISTILL_EVERY 條新訊息,背景丟 LLM 把新事實合併進筆記
## 不做 RAG——單一使用者的事實壓縮後直接整包進 context 就夠。

signal distilled(note: String)

const HISTORY_PATH: String = "user://doro_history.json"
const MEMORY_PATH: String = "user://doro_memory.txt"
const DISTILL_EVERY: int = 6        ## 每 6 條訊息(3 輪)蒸餾一次
const DISTILL_TAIL: int = 12        ## 蒸餾時最多帶最近 12 條對話
const NOTE_MAX_CHARS: int = 600     ## 筆記硬上限(LLM 目標 500,超了截斷保險)
const ENDPOINT: String = "https://openrouter.ai/api/v1/chat/completions"
const DoroLogger := preload("res://scripts/logger.gd")

const DISTILL_PROMPT: String = """你是 Doro(桌面寵物)的記憶整理器。
下面有「既有筆記」和「最近對話」。把最近對話中值得長期記住的事實,合併進筆記:
- 主人的名字/稱呼、喜好、討厭的東西、習慣
- 工作/專案/正在忙的事
- 重要事件(帶上日期)
- 主人對 Doro 的偏好與要求
規則:
- 繁體中文、條列式(- 開頭)
- 合併同類、去重;過時的事實用新的覆蓋
- 總長不超過 500 字,超過就淘汰最不重要的
- 沒有新事實就原樣輸出既有筆記
- 只輸出筆記內容本身,不要任何解釋、標題、code fence"""

var _memory: String = ""
var _since_distill: int = 0
var _distilling: bool = false
var _http: HTTPRequest

func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = 45.0
	add_child(_http)
	_memory = _load_text(MEMORY_PATH)

## ---------- 長期筆記 ----------
func get_memory() -> String:
	return _memory

## 給 system prompt 用的段落;沒筆記時回空字串
func memory_section() -> String:
	if _memory.strip_edges() == "":
		return ""
	return "\n\n# 關於主人的記憶(你之前累積的筆記,自然運用,別逐條背誦)\n" + _memory.strip_edges() + "\n"

## ---------- 短期歷史落盤 ----------
func load_history() -> Array:
	var raw: String = _load_text(HISTORY_PATH)
	if raw == "":
		return []
	var parsed: Variant = JSON.parse_string(raw)
	return parsed if typeof(parsed) == TYPE_ARRAY else []

func save_history(history: Array) -> void:
	_save_text(HISTORY_PATH, JSON.stringify(history))

func clear_history() -> void:
	save_history([])

## ---------- 蒸餾 ----------
## 每輪對話結束後呼叫;累積夠了就背景蒸餾(不擋對話)
func on_exchange(history: Array, api_key: String, model: String) -> void:
	save_history(history)
	_since_distill += 2          ## user + assistant
	if _since_distill >= DISTILL_EVERY and not _distilling and api_key != "":
		distill_now(history, api_key, model)

func distill_now(history: Array, api_key: String, model: String) -> void:
	if _distilling:
		return
	_distilling = true
	var tail: Array = history.slice(maxi(0, history.size() - DISTILL_TAIL))
	var convo: String = ""
	for m in tail:
		convo += "%s: %s\n" % ["主人" if m.get("role") == "user" else "Doro", String(m.get("content", ""))]
	var dt: Dictionary = Time.get_datetime_dict_from_system()
	var user_msg: String = "今天日期:%04d-%02d-%02d\n\n【既有筆記】\n%s\n\n【最近對話】\n%s" % [
		dt.year, dt.month, dt.day,
		_memory if _memory != "" else "(還沒有筆記)", convo]
	var body: Dictionary = {
		"model": model,
		"messages": [
			{"role": "system", "content": DISTILL_PROMPT},
			{"role": "user", "content": user_msg},
		],
		"max_tokens": 700,
		"temperature": 0.2,
	}
	var headers: PackedStringArray = [
		"Authorization: Bearer " + api_key,
		"Content-Type: application/json",
		"HTTP-Referer: https://github.com/Oliver0804/DoroPet",
		"X-Title: DoroPet",
	]
	var err: int = _http.request(ENDPOINT, headers, HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		_distilling = false
		DoroLogger.log("memory_distill_error", {"reason": "HTTPRequest err=%d" % err})
		return
	_finish_distill()

func _finish_distill() -> void:
	var result: Array = await _http.request_completed
	_distilling = false
	var code: int = result[1]
	var body: PackedByteArray = result[3]
	if int(result[0]) != HTTPRequest.RESULT_SUCCESS or code < 200 or code >= 300:
		DoroLogger.log("memory_distill_error", {"reason": "HTTP %d" % code})
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY or not (parsed as Dictionary).has("choices"):
		DoroLogger.log("memory_distill_error", {"reason": "bad json"})
		return
	var note: String = String(parsed["choices"][0]["message"].get("content", "")).strip_edges()
	if note.begins_with("```"):
		note = note.trim_prefix("```").trim_suffix("```").strip_edges()
	if note == "":
		return
	if note.length() > NOTE_MAX_CHARS:
		note = note.substr(0, NOTE_MAX_CHARS)
	_memory = note
	_save_text(MEMORY_PATH, note)
	_since_distill = 0
	DoroLogger.log("memory_distilled", {"chars": note.length()})
	distilled.emit(note)

## ---------- 檔案 IO ----------
func _load_text(path: String) -> String:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var t: String = f.get_as_text()
	f.close()
	return t

func _save_text(path: String, text: String) -> void:
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(text)
	f.close()
