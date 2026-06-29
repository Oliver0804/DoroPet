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
11 = 點頭(回答 yes、同意、附和時用)
12 = 搖頭(回答 no、拒絕、否定時用)
13 = 眯眼(壞笑、不爽、懷疑時用)
14 = 挑眉(疑惑、調侃、挑釁時用)

絕對禁止：純文字、解釋、code fence、多個 JSON。只回一個物件。"""
const MAX_HISTORY: int = 8                 ## 對話 context 上限（user+assistant 訊息對）
const TIMEOUT_SEC: float = 30.0

const DoroLogger := preload("res://scripts/logger.gd")
const TOOLS_SCHEMA: Array = [
	{
		"type": "function",
		"function": {
			"name": "get_time",
			"description": "拿到使用者當下的本地時間(含星期、日期)。當使用者問『現在幾點』『今天星期幾』之類就呼叫。",
			"parameters": {"type": "object", "properties": {}, "required": []},
		},
	},
	{
		"type": "function",
		"function": {
			"name": "get_weather",
			"description": "查指定城市目前的天氣與溫度。當使用者問天氣、要不要帶傘、外面冷不冷之類就呼叫。",
			"parameters": {
				"type": "object",
				"properties": {
					"city": {"type": "string", "description": "城市英文名,例:Taipei、Tokyo、New York。"}
				},
				"required": ["city"],
			},
		},
	},
]
const MAX_TOOL_ROUNDS: int = 3              ## 防 LLM 無限呼叫

var _http: HTTPRequest
var _tool_http: HTTPRequest                ## 給 weather 等 tool 用
var _history: Array = []                   ## [{role,content}, ...]
var _running_messages: Array = []          ## 當前 in-flight 的 messages(可含 tool_calls)
var _api_key: String = ""
var _model: String = DEFAULT_MODEL
var _persona: String = DEFAULT_PERSONA
var _in_flight: bool = false
var _request_started_ms: int = 0
var _round: int = 0

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
	_tool_http = HTTPRequest.new()
	_tool_http.timeout = 10.0
	add_child(_tool_http)

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

	_running_messages = messages
	_round = 0
	_in_flight = true
	_request_started_ms = Time.get_ticks_msec()
	DoroLogger.log("chat_request", {
		"text": user_text,
		"model": _model,
		"has_image": image_b64 != "",
		"history_size": _history.size(),
	})
	_send_round()

## 真正送 round (可含 tool result),共用 in-flight state
func _send_round() -> void:
	var body: Dictionary = {
		"model": _model,
		"messages": _running_messages,
		"max_tokens": 400,
		"temperature": 0.8,
		"tools": TOOLS_SCHEMA,
		"tool_choice": "auto",
	}
	var headers: PackedStringArray = [
		"Authorization: Bearer " + _api_key,
		"Content-Type: application/json",
		"HTTP-Referer: https://github.com/DoroPet",
		"X-Title: DoroPet",
	]
	var err: int = _http.request(ENDPOINT, headers, HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		_in_flight = false
		_history.pop_back()
		DoroLogger.log("chat_error", {"reason": "HTTPRequest start fail %d" % err})
		error_occurred.emit("HTTPRequest 啟動失敗: %d" % err)

func _on_response(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
	var latency_ms: int = Time.get_ticks_msec() - _request_started_ms
	if result != HTTPRequest.RESULT_SUCCESS:
		_in_flight = false
		_history.pop_back()
		DoroLogger.log("chat_error", {"reason": "network result=%d" % result, "latency_ms": latency_ms})
		error_occurred.emit("網路錯誤 (result=%d)" % result)
		return
	var text: String = body.get_string_from_utf8()
	if code < 200 or code >= 300:
		_in_flight = false
		_history.pop_back()
		DoroLogger.log("chat_error", {"reason": "HTTP %d" % code, "body": text.substr(0, 500), "latency_ms": latency_ms})
		error_occurred.emit("HTTP %d: %s" % [code, text.substr(0, 200)])
		return
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		_in_flight = false
		_history.pop_back()
		error_occurred.emit("回覆格式異常")
		return
	var data: Dictionary = parsed
	if not data.has("choices") or (data["choices"] as Array).is_empty():
		_in_flight = false
		_history.pop_back()
		var msg: String = "無 choices"
		if data.has("error"):
			msg = JSON.stringify(data["error"])
		error_occurred.emit(msg)
		return
	var message: Dictionary = data["choices"][0]["message"]
	## 若 LLM 要求呼叫 tool → 跑 + 把結果塞回 messages 再 round
	if message.has("tool_calls") and (message["tool_calls"] as Array).size() > 0 and _round < MAX_TOOL_ROUNDS:
		_round += 1
		_running_messages.append(message)   ## assistant turn 含 tool_calls
		var tool_calls: Array = message["tool_calls"]
		for tc in tool_calls:
			var fn_name: String = tc["function"]["name"]
			var fn_args_str: String = String(tc["function"].get("arguments", "{}"))
			var args_parser: JSON = JSON.new()
			var args: Dictionary = {}
			if args_parser.parse(fn_args_str) == OK and typeof(args_parser.data) == TYPE_DICTIONARY:
				args = args_parser.data
			var tool_result: String = await _execute_tool(fn_name, args)
			DoroLogger.log("tool_call", {"name": fn_name, "args": args, "result": tool_result.substr(0, 200)})
			_running_messages.append({
				"role": "tool",
				"tool_call_id": tc["id"],
				"content": tool_result,
			})
		_send_round()
		return
	## 無 tool_calls → 一般文字回覆,清 in-flight
	_in_flight = false
	var reply: String = String(message.get("content", ""))
	_history.append({"role": "assistant", "content": reply})
	var clean: String = reply.strip_edges()
	## 去掉可能的 ``` 或 ```json fence
	if clean.begins_with("```"):
		clean = clean.trim_prefix("```json").trim_prefix("```").trim_suffix("```").strip_edges()
	## 用 JSON instance silent parse（避免 LLM 回非 JSON 時印 ERROR）
	var parser: JSON = JSON.new()
	var obj: Variant = null
	if parser.parse(clean) == OK:
		obj = parser.data
	if typeof(obj) == TYPE_DICTIONARY and (obj as Dictionary).has("text"):
		var emo: int = int((obj as Dictionary).get("emotion", 0))
		var txt: String = String((obj as Dictionary)["text"]).strip_edges()
		DoroLogger.log("chat_response", {"text": txt, "emotion": emo, "model": _model, "latency_ms": latency_ms})
		reply_received.emit(txt, clamp(emo, 0, 14))
	else:
		DoroLogger.log("chat_response", {"text": clean, "raw": true, "model": _model, "latency_ms": latency_ms})
		reply_received.emit(clean, 0)

## ---------- Tools 實作 ----------
func _execute_tool(name: String, args: Dictionary) -> String:
	match name:
		"get_time":
			return _tool_get_time()
		"get_weather":
			var city: String = String(args.get("city", "Taipei"))
			return await _tool_get_weather(city)
	return "(未知工具: %s)" % name

func _tool_get_time() -> String:
	var dt: Dictionary = Time.get_datetime_dict_from_system()
	var weekdays: PackedStringArray = ["週日","週一","週二","週三","週四","週五","週六"]
	return "%04d-%02d-%02d %02d:%02d:%02d (%s)" % [
		dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second, weekdays[dt.weekday]
	]

## wttr.in 免費 API,format=3 回單行(location, condition, temp, wind)
func _tool_get_weather(city: String) -> String:
	var url: String = "https://wttr.in/%s?format=3" % city.uri_encode()
	var headers: PackedStringArray = ["User-Agent: curl/7", "Accept-Language: zh-TW,en"]
	var err: int = _tool_http.request(url, headers)
	if err != OK:
		return "(取天氣失敗 err=%d)" % err
	var result: Array = await _tool_http.request_completed
	var code: int = result[1]
	var body: PackedByteArray = result[3]
	if code < 200 or code >= 300:
		return "(天氣 API HTTP %d)" % code
	var text: String = body.get_string_from_utf8().strip_edges()
	if text == "":
		return "(沒拿到天氣資料)"
	return text
