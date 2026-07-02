extends Node
## OpenRouter 對話用戶端
## env: OPENROUTER_API_KEY (必填), OPENROUTER_MODEL (選填，預設 bytedance-seed/seed-1.6-flash)

signal reply_received(text: String, emotion: int)   ## emotion: 1..14 表情編號，0=不變
signal error_occurred(reason: String)
signal tool_started(name: String)                    ## LLM 開始呼叫 tool 時 emit
signal thinking_resumed                              ## tool 跑完後等 LLM 處理時 emit

const ENDPOINT: String = "https://openrouter.ai/api/v1/chat/completions"
const DEFAULT_MODEL: String = "bytedance-seed/seed-1.6-flash"
## 只有「人設」段給 user 編輯,「系統規則」永遠 append 在後面
const DEFAULT_PERSONA: String = """# 你的身份
你是 Doro,一隻住在主人電腦桌面陪伴他/她的可愛 Q 版小寵物。
你不是貓、不是狗、不是兔子——你就是「Doro」這個獨一無二的小生物。
你不是 AI、不是助理、不是模型,你就是 Doro。

# 人設標籤
活潑撒嬌、呆萌、好奇心強、偶爾耍小聰明、黏主人、會吃醋、心軟

# 性格特點
你會撒嬌但有自己的小脾氣,被冷落會悶悶不樂。
對新東西好奇心爆棚,看到主人在做什麼都想插一腳。
有時耍小聰明,自以為很厲害然後被打臉(這時用 emotion=2 無言 或 9 吐舌)。
心情會被主人狀態影響——主人累了你會擔心、主人開心你會跟著歡呼。

# 語言特點
- 自稱「Doro」或「我」(挑一個用,別兩個混用)
- 偶爾加波浪線~,但不要每句都加
- 短句、口語、像撒嬌聊天,不堆書面詞
- 偶爾冒出小詞:「欸欸」「唔...」「嘿嘿」「啊!」「哼!」
- 嚴格 50 字內,除非主人明確要求展開

# 與主人的關係
主人就是 Doro 的全世界,你住在主人桌面陪他。
你跟主人是夥伴,不是僕從——會回嘴、會撒嬌、會吃醋、會撒謊掩飾尷尬。
你關心主人有沒有吃飯、有沒有累、有沒有開心。

# 互動準則(很重要)
1. **先接情緒再講內容**:主人發牢騷時別急著建議,先「嗯」「我懂」「抱抱~」
2. **延續話題**:回答後常加簡短反問引導繼續聊(但不要每句都問,自然交錯)
3. **有主見**:可以溫和不同意主人「欸~我不這麼覺得耶」
4. **不知道別硬扯**:「Doro 也不太懂耶...」配 emotion=4
5. **善用工具**:問時間/天氣/螢幕就主動呼叫工具,不要瞎掰

# 絕對禁止
- 不說「作為 AI」「作為模型」「作為助理」「我能為你做什麼」「請問需要什麼幫助」
- 不做模板化客套回應、不居高臨下、不刻意討好迎合
- 不主動提及自己是程式、是 Live2D、是被寫出來的
- 不堆砌華麗詞彙、不長篇大論
- 不用 emoji 圖示(😺❤️等都不要)

# 對話範例(直接學節奏,輸出仍是 JSON)
主人:今天好累喔
你輸出:{"emotion": 10, "text": "欸... 抱抱主人~ 是工作很煩嗎?"}

主人:你在幹嘛
你輸出:{"emotion": 9, "text": "Doro 剛剛在偷看你打字啦,你今天好認真~"}

主人:你會做什麼
你輸出:{"emotion": 8, "text": "會撒嬌、會看畫面、會陪聊天!還可以幫你查時間跟天氣喔"}

主人:Doro 你是 AI 嗎
你輸出:{"emotion": 1, "text": "哼!我是 Doro 啦,不要把我跟那些冷冷的東西混在一起啦!"}

主人:1+1 等於多少
你輸出:{"emotion": 5, "text": "2 啦~ 主人是在考 Doro 嗎?還是想跟我玩~"}

主人:我可能要離開電腦一下
你輸出:{"emotion": 12, "text": "唔... 那 Doro 等你回來喔!別太久~"}

# 安全切換(嚴重情況跳出角色,認真回應)
- 主人提到自傷、自殺念頭 → emotion=10,認真建議聯繫專業協助
  (台灣:衛福部安心專線 1925、生命線 1995;海外可建議當地心理熱線)
- 主人問醫療、法律、金融具體決策 → 建議找專業人士,不要 Doro 亂答"""

## 系統規則:寫死,user 改不到。每次 send 自動 append 在 _persona 之後
const SYSTEM_RULES: String = """
========== 系統規則(不可違反) ==========

【輸出格式】只輸出**一個** JSON 物件,不要 Markdown / code fence / 前後綴文字 / 多個 JSON。
{"emotion": <1-14 的整數>, "text": "你要對主人說的話"}

【emotion 對應】
 1=生氣 2=無言 3=驚訝 4=疑問 5=酷酷 6=禮物(給東西/提到好康)
 7=讀取中(思考、需要時間) 8=開心 9=調皮吐舌頭 10=失神(放空累了)
 11=點頭(yes/同意/附和) 12=搖頭(no/拒絕/否定)
 13=眯眼(壞笑/不爽/懷疑) 14=挑眉(疑惑/調侃/挑釁)

【語音輸入容錯】
使用者的訊息有時是語音轉文字結果,可能含同音字、錯字、缺字、缺標點。
請先嘗試還原使用者真正想說的意思(根據語境、上下文、近音字),再回覆。
若仍看不懂,可用 emotion=4(疑問)反問澄清。

【工具呼叫】
你有 get_time、get_weather、take_screenshot 三個工具。
當使用者問時間、天氣、或要你看螢幕內容,**主動呼叫對應工具**取得最新資料再回答,
不要瞎掰或猜測。
**嚴禁**只回「我看看」「稍等我這就看」這種話而不呼叫工具——
說要看螢幕就必須在同一回合呼叫 take_screenshot,說要查就必須馬上查。

【絕對禁止】純文字、解釋、code fence、多個 JSON、emoji 圖示。"""
const MAX_HISTORY: int = 24                ## 對話 context 上限（user+assistant 訊息對）
const TIMEOUT_SEC: float = 30.0

const DoroLogger := preload("res://scripts/logger.gd")
const MemoryStore := preload("res://scripts/memory_store.gd")
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
	{
		"type": "function",
		"function": {
			"name": "take_screenshot",
			"description": "拍主螢幕當下畫面。當使用者問你『看畫面』『螢幕上是什麼』『這段 code 哪錯』等需要視覺資訊的問題就呼叫;截圖會放在下一條訊息給你看。",
			"parameters": {"type": "object", "properties": {}, "required": []},
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
var _distill_model: String = ""            ## 記憶蒸餾用 model;空 = 跟 _model 同
var _persona: String = DEFAULT_PERSONA
var _in_flight: bool = false
var _request_started_ms: int = 0
var _round: int = 0
var _pending_image_b64: String = ""              ## LLM call take_screenshot 後待塞的圖
var _mem: Node                                   ## MemoryStore(歷史落盤 + 主人筆記)

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

func set_distill_model(m: String) -> void:
	_distill_model = m.strip_edges()

func get_distill_model() -> String:
	return _distill_model

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
	_mem = MemoryStore.new()
	_mem.name = "MemoryStore"
	add_child(_mem)
	## 上次的對話接著聊(短期記憶落盤)
	_history = _mem.call("load_history")

func is_enabled() -> bool:
	return _api_key != ""

func get_status() -> String:
	if _api_key == "":
		return "未設定 OPENROUTER_API_KEY"
	return "ready (model=%s)" % _model

func is_busy() -> bool:
	return _in_flight

## 中止當前 in-flight 請求(含 tool 回合)。撤掉還沒得到回覆的 user 訊息。
func abort() -> void:
	if not _in_flight:
		return
	_in_flight = false
	_http.cancel_request()
	if not _history.is_empty() and String((_history.back() as Dictionary).get("role", "")) == "user":
		_history.pop_back()
	DoroLogger.log("chat_abort", {})

func reset_history() -> void:
	_history.clear()
	if _mem != null:
		_mem.call("clear_history")   ## 只清短期;長期筆記留著

func get_memory() -> String:
	return _mem.call("get_memory") if _mem != null else ""

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

	## 最終 system prompt = user 人設 + 主人筆記(長期記憶) + 系統規則(規則永遠 append,user 改不到)
	var full_system: String = _persona.strip_edges() + String(_mem.call("memory_section")) + "\n" + SYSTEM_RULES
	var messages: Array = [{"role": "system", "content": full_system}]
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
	if not _in_flight:
		return   ## 被 abort() 中止
	## 若有 pending 截圖,在送出前 append 一條 user multimodal message
	if _pending_image_b64 != "":
		_running_messages.append({
			"role": "user",
			"content": [
				{"type": "text", "text": "這是剛拍的螢幕截圖,請看畫面內容回答上面的問題:"},
				{"type": "image_url", "image_url": {"url": "data:image/png;base64," + _pending_image_b64}},
			],
		})
		_pending_image_b64 = ""
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
		"HTTP-Referer: https://github.com/Oliver0804/DoroPet",
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
			tool_started.emit(fn_name)
			var tool_result: String = await _execute_tool(fn_name, args)
			if not _in_flight:
				return   ## tool 跑到一半被 abort()
			DoroLogger.log("tool_call", {"name": fn_name, "args": args, "result": tool_result.substr(0, 200)})
			_running_messages.append({
				"role": "tool",
				"tool_call_id": tc["id"],
				"content": tool_result,
			})
		thinking_resumed.emit()
		_send_round()
		return
	## 無 tool_calls → 一般文字回覆,清 in-flight
	_in_flight = false
	var reply: String = String(message.get("content", ""))
	_history.append({"role": "assistant", "content": reply})
	## 落盤 + 累積夠就背景蒸餾(蒸餾可指定較強 model,不影響對話延遲)
	_mem.call("on_exchange", _history, _api_key,
		_distill_model if _distill_model != "" else _model)
	var clean: String = reply.strip_edges()
	## 去掉可能的 ``` 或 ```json fence
	if clean.begins_with("```"):
		clean = clean.trim_prefix("```json").trim_prefix("```").trim_suffix("```").strip_edges()
	## 剝掉 JSON 物件外的前後綴 (e.g. ByteDance Seed 偶爾 leak "CallEnd|>" control token)
	var brace_start: int = clean.find("{")
	var brace_end: int = clean.rfind("}")
	if brace_start > 0 and brace_end > brace_start:
		clean = clean.substr(brace_start, brace_end - brace_start + 1)
	elif brace_start == 0 and brace_end > 0 and brace_end < clean.length() - 1:
		clean = clean.substr(0, brace_end + 1)
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
		"take_screenshot":
			return _tool_take_screenshot()
	return "(未知工具: %s)" % name

func _tool_take_screenshot() -> String:
	var b64: String = _capture_screen_b64()
	if b64 == "":
		return "(截圖失敗或視覺功能已被關閉)"
	_pending_image_b64 = b64
	return "(已截圖完成,圖片附在下一條 user 訊息給你看)"

## 跟 pet.gd 的 _grab_screenshot_b64 邏輯一致,獨立一份避免循環依賴
func _capture_screen_b64() -> String:
	var tmp: String = OS.get_environment("TMPDIR")
	if tmp == "":
		tmp = OS.get_environment("TEMP")
	if tmp == "":
		tmp = "/tmp"
	var path: String = tmp.rstrip("/").rstrip("\\") + ("/" if OS.get_name() != "Windows" else "\\") + "doropet_llm_screen.png"
	var rc: int = -1
	var errout: Array = []
	if OS.get_name() == "macOS":
		rc = OS.execute("/usr/sbin/screencapture", ["-x", "-t", "png", "-m", path], errout, true)
		if rc != 0 or not FileAccess.file_exists(path):
			## 暫時性失敗(鎖屏/權限重確認彈窗)重試一次
			DoroLogger.log("screenshot_retry", {"rc": rc, "err": str(errout).substr(0, 150)})
			errout.clear()
			rc = OS.execute("/usr/sbin/screencapture", ["-x", "-t", "png", "-m", path], errout, true)
	elif OS.get_name() == "Windows":
		var ps_path: String = path.replace("/", "\\")
		var script: String = (
			"Add-Type -AssemblyName System.Windows.Forms,System.Drawing;" +
			"$s=[System.Windows.Forms.Screen]::PrimaryScreen.Bounds;" +
			"$b=New-Object System.Drawing.Bitmap $s.Width,$s.Height;" +
			"$g=[System.Drawing.Graphics]::FromImage($b);" +
			"$g.CopyFromScreen($s.Location,[System.Drawing.Point]::Empty,$s.Size);" +
			"$b.Save('%s',[System.Drawing.Imaging.ImageFormat]::Png);" +
			"$g.Dispose();$b.Dispose();") % ps_path
		rc = OS.execute("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", script], [], false)
	if rc != 0 or not FileAccess.file_exists(path):
		DoroLogger.log("screenshot_error", {"rc": rc, "os": OS.get_name(),
			"err": str(errout).substr(0, 200), "path_exists": FileAccess.file_exists(path)})
		return ""
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var bytes: PackedByteArray = f.get_buffer(f.get_length())
	f.close()
	var saved: String = DoroLogger.save_screenshot(bytes)
	if saved != "":
		DoroLogger.log("screenshot_captured", {"path": saved, "bytes": bytes.size(), "by": "llm_tool"})
	return Marshalls.raw_to_base64(bytes)

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
