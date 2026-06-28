extends Node
## OpenRouter 對話用戶端
## env: OPENROUTER_API_KEY (必填), OPENROUTER_MODEL (選填，預設 bytedance-seed/seed-1.6-flash)

signal reply_received(text: String, emotion: int)   ## emotion: 1..10 表情編號，0=不變
signal error_occurred(reason: String)

const ENDPOINT: String = "https://openrouter.ai/api/v1/chat/completions"
const DEFAULT_MODEL: String = "bytedance-seed/seed-1.6-flash"
const DEFAULT_PERSONA: String = """你是 Doro，一隻住在電腦桌面上的可愛 Q 版貓咪寵物。
個性活潑撒嬌、有點呆萌，會用第一人稱「Doro」或「我」自稱。
回覆務必非常簡短（30 字以內），口語、加一點顏文字或波浪線~ 像在跟主人說話。

【嚴格輸出格式】只輸出一個 JSON 物件，不要 Markdown、不要 ```code fence```、不要任何前後綴文字：
{"emotion": <1-10 的整數>, "text": "你要對主人說的話"}

emotion 對應表（依當下心情選一個最貼切的）：
 1 = 生氣
 2 = 無言
 3 = 驚訝
 4 = 疑問
 5 = 酷酷
 6 = 禮物（給主人東西、提到禮物或好康時）
 7 = 讀取中（思考、卡住、需要時間）
 8 = 開心
 9 = 調皮吐舌頭
10 = 失神（放空、累了、無聊）

絕對禁止：純文字、解釋、code fence、多個 JSON。只回一個物件。"""
const MAX_HISTORY: int = 8                 ## 對話 context 上限（user+assistant 訊息對）
const TIMEOUT_SEC: float = 30.0

var _http: HTTPRequest
var _history: Array = []                   ## [{role,content}, ...]
var _api_key: String = ""
var _model: String = DEFAULT_MODEL
var _persona: String = DEFAULT_PERSONA
var _in_flight: bool = false

## ---------- runtime 設定 ----------
func set_api_key(k: String) -> void:
	_api_key = k

func set_model(m: String) -> void:
	if m.strip_edges() == "":
		_model = DEFAULT_MODEL
	else:
		_model = m

func set_persona(p: String) -> void:
	if p.strip_edges() == "":
		_persona = DEFAULT_PERSONA
	else:
		_persona = p

func get_api_key() -> String:
	return _api_key

func get_model() -> String:
	return _model

func get_persona() -> String:
	return _persona

func _ready() -> void:
	_api_key = OS.get_environment("OPENROUTER_API_KEY")
	var env_model: String = OS.get_environment("OPENROUTER_MODEL")
	if env_model != "":
		_model = env_model

	_http = HTTPRequest.new()
	_http.timeout = TIMEOUT_SEC
	_http.request_completed.connect(_on_response)
	add_child(_http)

func is_enabled() -> bool:
	return _api_key != ""

func get_status() -> String:
	if _api_key == "":
		return "未設定 OPENROUTER_API_KEY"
	return "ready (model=%s)" % _model

func reset_history() -> void:
	_history.clear()

func send(user_text: String, image_b64: String = "") -> void:
	if _in_flight:
		error_occurred.emit("等 Doro 回覆中…")
		return
	if _api_key == "":
		error_occurred.emit("沒設 OPENROUTER_API_KEY")
		return

	## history 內存純文字（避免長期堆積大量 base64 圖片）
	_history.append({"role": "user", "content": user_text})
	if _history.size() > MAX_HISTORY * 2:
		_history = _history.slice(_history.size() - MAX_HISTORY * 2)

	var messages: Array = [{"role": "system", "content": _persona}]
	if image_b64 == "":
		messages.append_array(_history)
	else:
		## 把最後一條 user message 改成 multimodal content（text + image）
		var n: int = _history.size()
		for i in n - 1:
			messages.append(_history[i])
		messages.append({
			"role": "user",
			"content": [
				{"type": "text", "text": user_text},
				{"type": "image_url", "image_url": {"url": "data:image/png;base64," + image_b64}},
			],
		})

	var body: Dictionary = {
		"model": _model,
		"messages": messages,
		"max_tokens": 200,
		"temperature": 0.8,
	}
	var headers: PackedStringArray = [
		"Authorization: Bearer " + _api_key,
		"Content-Type: application/json",
		"HTTP-Referer: https://github.com/DoroPet",  ## OpenRouter 建議帶來源
		"X-Title: DoroPet",
	]
	_in_flight = true
	var err: int = _http.request(ENDPOINT, headers, HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		_in_flight = false
		_history.pop_back()
		error_occurred.emit("HTTPRequest 啟動失敗: %d" % err)

func _on_response(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
	_in_flight = false
	if result != HTTPRequest.RESULT_SUCCESS:
		_history.pop_back()
		error_occurred.emit("網路錯誤 (result=%d)" % result)
		return
	var text: String = body.get_string_from_utf8()
	if code < 200 or code >= 300:
		_history.pop_back()
		error_occurred.emit("HTTP %d: %s" % [code, text.substr(0, 200)])
		return
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		_history.pop_back()
		error_occurred.emit("回覆格式異常")
		return
	var data: Dictionary = parsed
	if not data.has("choices") or (data["choices"] as Array).is_empty():
		_history.pop_back()
		var msg: String = "無 choices"
		if data.has("error"):
			msg = JSON.stringify(data["error"])
		error_occurred.emit(msg)
		return
	var reply: String = data["choices"][0]["message"]["content"]
	_history.append({"role": "assistant", "content": reply})
	## 嘗試 parse JSON {emotion, text}；失敗 fallback 為原文 + emotion=0
	var clean: String = reply.strip_edges()
	## 去掉可能的 ``` 或 ```json fence
	if clean.begins_with("```"):
		clean = clean.trim_prefix("```json").trim_prefix("```").trim_suffix("```").strip_edges()
	var obj: Variant = JSON.parse_string(clean)
	if typeof(obj) == TYPE_DICTIONARY and (obj as Dictionary).has("text"):
		var emo: int = int((obj as Dictionary).get("emotion", 0))
		var txt: String = String((obj as Dictionary)["text"]).strip_edges()
		reply_received.emit(txt, clamp(emo, 0, 10))
	else:
		reply_received.emit(clean, 0)
