extends Node
## OpenRouter 對話用戶端
## env: OPENROUTER_API_KEY (必填), OPENROUTER_MODEL (選填，預設 bytedance-seed/seed-1.6-flash)

signal reply_received(text: String, emotion: int)   ## emotion: 1..14 表情編號，0=不變
signal error_occurred(reason: String)
signal tool_started(name: String)                    ## LLM 開始呼叫 tool 時 emit
signal thinking_resumed                              ## tool 跑完後等 LLM 處理時 emit
## 串流輸出:LLM 邊生成邊 emit 一句一句;pet.gd 接住第一句立刻送 TTS
signal sentence_stream(sentence: String, is_first: bool, emotion: int)

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
- 一般 60-100 字內;主人問細節/How/Why/需要解釋時可展開到 200 字

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

【回覆長度】
一般 60-100 字撒嬌聊天;主人問細節/How/Why/教學/需要解釋時可展開到 200 字。
別為湊字數硬堆廢話,展開的內容要有實質資訊。

【記憶時間的口語化】
記憶帳本可能含精確時分秒(例「2026-07-13 01:23 主人 X」),但**回覆時別主動報**,
用「剛剛/今天下午/昨晚/前幾天/上次」這種口語即可。
只有主人明問「什麼時候」「幾點」才用精確時間回答。

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
你有 5 個工具:get_time、get_weather、take_screenshot、recall_memory、web_search。
- **現在時間已寫在上面「你當下的時間感」段,直接用,不要呼叫 get_time**
  (只有主人明確要精確到秒的時間才呼叫)
- 問天氣 → get_weather;要你看畫面 → take_screenshot
- 主人問起更早以前的事、或你記憶裡沒有的舊話題 → recall_memory 翻舊帳
- 問**新聞、當前事件、你不知道的人事物、統計數據、產品資訊、比賽結果**等
  需要即時網路資料的問題 → web_search 查了再答,不要憑印象亂講
**嚴禁**只回「我看看」「稍等我這就看」「Doro 不太清楚耶」這種話而不呼叫工具——
說要看螢幕就必須在同一回合呼叫 take_screenshot,說要查就必須馬上查,
不知道就先 web_search 再說「不確定」。

【絕對禁止】純文字、解釋、code fence、多個 JSON、emoji 圖示。"""
const MAX_HISTORY: int = 24                ## 對話 context 上限（user+assistant 訊息對）
const TIMEOUT_SEC: float = 30.0

const DoroLogger := preload("res://scripts/logger.gd")
const MemoryStore := preload("res://scripts/memory_store.gd")
const MoodState := preload("res://scripts/mood_state.gd")
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
			"name": "recall_memory",
			"description": "搜尋 Doro 的長期記憶歸檔與更早的對話記錄。當主人問起以前說過的話、更早發生的事、或你目前記憶裡沒有但主人堅稱提過的事,就用關鍵字呼叫。",
			"parameters": {
				"type": "object",
				"properties": {
					"keyword": {"type": "string", "description": "要搜尋的關鍵字(人名、事物、話題),用最有代表性的短詞"}
				},
				"required": ["keyword"],
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
	{
		"type": "function",
		"function": {
			"name": "web_search",
			"description": "上網搜尋最新資訊。主人問到你不知道的新聞、當前事件、產品規格、比賽比分、匯率、演唱會/上映資訊、統計數據等需要即時網路資料時呼叫。回傳前 3 筆搜尋結果標題+摘要。",
			"parameters": {
				"type": "object",
				"properties": {
					"query": {"type": "string", "description": "搜尋關鍵字,簡潔短句或詞組(3-8 字最佳),用主人問句裡最關鍵的名詞"}
				},
				"required": ["query"],
			},
		},
	},
]
const MAX_TOOL_ROUNDS: int = 3              ## 防 LLM 無限呼叫

var _http: HTTPRequest
var _tool_http: HTTPRequest                ## 給 weather 等 tool 用
var _history: Array = []                   ## [{role,content,ts,meta?}, ...] ts=Unix秒,meta="proactive"標記系統注入
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
var _mood: Node                                  ## MoodState(愉悅/活力兩軸,持久化)
## in-flight 期間主人又講話的排隊(避免「等 Doro 回覆中」把後續話吃掉)
var _pending_texts: PackedStringArray = []
var _pending_metas: PackedStringArray = []
## 天氣投機預取:send 偵測到「天氣」字眼就先抓上次城市的天氣進 cache,
## LLM 稍後呼叫 get_weather 時直接命中,省一次 tool 往返的網路時間
var _weather_cache: Dictionary = {}          ## city_lower -> {text, ts}
var _last_weather_city: String = "Taipei"
var _prefetch_http: HTTPRequest
const WEATHER_TTL_SEC: int = 600
## ---------- LLM 串流 (Phase A) ----------
enum {STREAM_IDLE, STREAM_CONNECTING, STREAM_REQUESTING, STREAM_READING}
var _stream_enabled: bool = true
var _stream_client: HTTPClient
var _stream_timer: Timer
var _stream_state: int = STREAM_IDLE
var _stream_headers: PackedStringArray = []
var _stream_body_json: String = ""
var _stream_path: String = "/api/v1/chat/completions"
var _stream_buf: PackedByteArray = PackedByteArray()   ## SSE 尚未 line-complete 的 raw
var _stream_full_raw: PackedByteArray = PackedByteArray()  ## body 完整原始資料(SSE 沒抽到時 fallback JSON parse)
var _stream_content_acc: String = ""     ## 累積的所有 delta.content(通常是 JSON 字串)
var _stream_emitted_len: int = 0         ## 已 emit 給 TTS 的 text 字元數
var _stream_emo: int = 0
var _stream_emo_parsed: bool = false
var _stream_first_emitted: bool = false
var _stream_tool_calls: Array = []       ## partial tool_calls 累積(若有)
var _stream_started_ms: int = 0
const STREAM_TIMEOUT_MS: int = 90000     ## 90 秒 stream 都沒完 → 強制 fail 走 fallback
## Debug 檢視用:每次 send / reply 更新的快照(不影響對話邏輯)
var _dbg_system_prompt: String = ""
var _dbg_messages: Array = []
var _dbg_reply_raw: String = ""
var _dbg_reply_text: String = ""
var _dbg_reply_emotion: int = 0
var _dbg_latency_ms: int = 0
var _dbg_last_meta: String = ""

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
	_stream_timer = Timer.new()
	_stream_timer.wait_time = 0.05
	_stream_timer.one_shot = false
	_stream_timer.timeout.connect(_on_stream_poll)
	add_child(_stream_timer)
	_prefetch_http = HTTPRequest.new()
	_prefetch_http.timeout = 10.0
	add_child(_prefetch_http)
	_mem = MemoryStore.new()
	_mem.name = "MemoryStore"
	add_child(_mem)
	_mood = MoodState.new()
	_mood.name = "MoodState"
	add_child(_mood)
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
	## 使用者主動 ESC:排隊也一起放棄(不想再繼續了)
	_pending_texts.clear()
	_pending_metas.clear()
	_in_flight = false      ## 不走 _clear_flight,免得排 flush
	_http.cancel_request()
	## 停止 stream
	if _stream_client != null:
		_stream_client.close()
		_stream_client = null
	_stream_timer.stop()
	_stream_state = STREAM_IDLE
	if not _history.is_empty() and String((_history.back() as Dictionary).get("role", "")) == "user":
		_history.pop_back()
	if _mood != null:
		_mood.call("on_user_abort")
	DoroLogger.log("chat_abort", {})

func reset_history() -> void:
	_history.clear()
	_pending_texts.clear()
	_pending_metas.clear()
	if _mem != null:
		_mem.call("clear_history")   ## 只清短期;長期筆記留著

func get_memory() -> String:
	return _mem.call("get_memory") if _mem != null else ""

func get_mood() -> Node:
	return _mood

## 最近一次「主人真的講話」的 Unix 秒(不含 proactive);0 = 沒紀錄
func last_user_ts() -> int:
	return _last_user_ts()

## Barge-in 對齊:主人打斷時把 history 尾巴 assistant 訊息的 text 截到已播位置,
## 免下輪 LLM 以為自己完整講完。chars 是估算已播字元數。
func truncate_last_reply(chars: int) -> void:
	if _history.is_empty() or chars < 0:
		return
	var last: Dictionary = _history.back()
	if String(last.get("role", "")) != "assistant":
		return
	var raw: String = String(last.get("content", ""))
	var re: RegEx = RegEx.new()
	re.compile('"text":"([^"]*)"')
	var m: RegExMatch = re.search(raw)
	if m == null:
		return
	var full_text: String = m.get_string(1)
	if chars >= full_text.length():
		return   ## 已全部播完,不用截
	var truncated: String = full_text.substr(0, chars) + "…(被主人打斷)"
	var new_raw: String = raw.replace('"text":"' + full_text + '"',
		'"text":"' + truncated + '"')
	last["content"] = new_raw
	DoroLogger.log("reply_truncated", {"chars_played": chars,
		"full_len": full_text.length(), "truncated_to": truncated.substr(0, 60)})

## Debug 視窗用:回傳最近一次 LLM 呼叫的完整快照
func get_debug_snapshot() -> Dictionary:
	return {
		"system_prompt": _dbg_system_prompt,
		"messages": _dbg_messages,
		"last_reply_raw": _dbg_reply_raw,
		"last_reply_text": _dbg_reply_text,
		"last_reply_emotion": _dbg_reply_emotion,
		"last_latency_ms": _dbg_latency_ms,
		"last_meta": _dbg_last_meta,
		"model": _model,
		"history_size": _history.size(),
	}

func send(user_text: String, image_b64: String = "", meta: String = "") -> void:
	if _in_flight:
		## 排隊,回覆完自動送(帶圖的不進 queue,避免圖被延遲失效)
		if image_b64 == "":
			## 上限 3 條:超過丟最舊的(混太多舊話題送 LLM 反而答非所問)
			while _pending_texts.size() >= 3:
				DoroLogger.log("chat_queue_dropped",
					{"text": _pending_texts[0].substr(0, 40)})
				_pending_texts.remove_at(0)
				_pending_metas.remove_at(0)
			_pending_texts.append(user_text)
			_pending_metas.append(meta)
			DoroLogger.log("chat_queued", {"text": user_text.substr(0, 60),
				"queue_size": _pending_texts.size(), "meta": meta})
		else:
			error_occurred.emit("Doro 忙著回上一句,附圖的訊息請稍後再送")
		return
	if _api_key == "":
		error_occurred.emit("沒設 OPENROUTER_API_KEY")
		return

	var now_ts: int = int(Time.get_unix_time_from_system())
	var last_user_ts: int = _last_user_ts()

	## history 內存純文字（避免長期堆積大量 base64 圖片）
	## ts 讓 Doro 感知時間流逝;meta="proactive" 標記系統自動觸發的搭話提示
	var entry: Dictionary = {"role": "user", "content": user_text, "ts": now_ts}
	if meta != "":
		entry["meta"] = meta
	_history.append(entry)
	if _history.size() > MAX_HISTORY * 2:
		_history = _history.slice(_history.size() - MAX_HISTORY * 2)

	## 最終 system prompt = 人設 + 時間感 + 主人筆記(長期記憶) + 系統規則
	## 只有真的是主人講的話才更新「被陪伴」計數;proactive 系統提示不算
	if meta != "proactive" and _mood != null:
		_mood.call("on_user_message")
	## 投機預取:句子提到天氣 → LLM 思考的同時先抓上次城市的天氣
	if user_text.contains("天氣") or user_text.contains("天气") \
			or user_text.to_lower().contains("weather"):
		_prefetch_weather(_last_weather_city)
	var time_ctx: String = _build_time_context(now_ts, last_user_ts)
	var mood_ctx: String = String(_mood.call("prompt_line")) if _mood != null else ""
	var style_ctx: String = _build_style_context(3)
	var summary_ctx: String = String(_mem.call("summary_section"))
	var full_system: String = _persona.strip_edges() + time_ctx + mood_ctx + style_ctx \
		+ summary_ctx + String(_mem.call("memory_section")) + "\n" + SYSTEM_RULES
	var messages: Array = [{"role": "system", "content": full_system}]
	## 送 API 前 strip 掉自加的 ts/meta(OpenAI 兼容 API 只吃 role/content/tool_*)
	if image_b64 == "":
		for m in _history:
			messages.append(_strip_meta(m))
	else:
		## 把最後一條 user message 改成 multimodal content（text + image）
		var n: int = _history.size()
		for i in n - 1:
			messages.append(_strip_meta(_history[i]))
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
	## Debug snapshot
	_dbg_system_prompt = full_system
	_dbg_messages = messages.duplicate(true)
	_dbg_last_meta = meta
	DoroLogger.log("chat_request", {
		"text": user_text,
		"model": _model,
		"has_image": image_b64 != "",
		"history_size": _history.size(),
		"meta": meta,
	})
	## 完整 prompt 分開 log(可能很大,獨立事件方便 debug 篩選)
	DoroLogger.log("chat_prompt", {
		"system_prompt": full_system,
		"messages_count": messages.size(),
	})
	_send_round()
	## 背景觸發歷史摘要(不 await,LLM 回完後結果會影響「下一輪」的 history)
	call_deferred("_bg_summarize_history_if_needed")

func _bg_summarize_history_if_needed() -> void:
	if _mem == null or _api_key == "":
		return
	var distill: String = _distill_model if _distill_model != "" else _model
	var new_hist: Array = await _mem.call("maybe_summarize_history",
		_history, _api_key, distill)
	if new_hist.size() < _history.size():
		## 摘要成功 → 舊訊息已入 summary,history 縮短
		_history = new_hist
		if _mem != null:
			_mem.call("save_history", _history)

## 把 _in_flight 收乾淨並排程 flush 排隊訊息(defer 一次,讓當前 emit 先跑完)
func _clear_flight() -> void:
	_in_flight = false
	call_deferred("_flush_pending")

## 收工後檢查有沒有排隊訊息;有就合併成一條再送
## 合併理由:LLM tokens 貴,多條連續碎片語意上就是一輪思考
func _flush_pending() -> void:
	if _pending_texts.is_empty() or _in_flight:
		return
	var combined: String
	if _pending_texts.size() == 1:
		combined = _pending_texts[0]
	else:
		combined = "(主人剛剛接連說了幾句)\n" + "\n".join(_pending_texts)
	var meta: String = _pending_metas[0] if _pending_metas.size() > 0 else ""
	## 若排隊有真人講的話,整批視為 user 訊息(meta="")而非 proactive
	for m in _pending_metas:
		if String(m) != "proactive":
			meta = ""
			break
	_pending_texts.clear()
	_pending_metas.clear()
	DoroLogger.log("chat_flush_pending", {"combined_text": combined.substr(0, 100)})
	call_deferred("send", combined, "", meta)

## API 只吃 role/content/tool_*;剝掉我們自加的 ts/meta
func _strip_meta(m: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for k in ["role", "content", "tool_calls", "tool_call_id", "name"]:
		if m.has(k):
			out[k] = m[k]
	return out

## 最近一次「真的是主人講的話」的 ts;跳過 proactive 系統提示
func _last_user_ts() -> int:
	for i in range(_history.size() - 1, -1, -1):
		var m: Dictionary = _history[i]
		if String(m.get("role", "")) != "user":
			continue
		if String(m.get("meta", "")) == "proactive":
			continue
		if m.has("ts"):
			return int(m["ts"])
	return 0

func _build_time_context(now: int, last_user: int) -> String:
	var dt: Dictionary = Time.get_datetime_dict_from_system()
	var weekdays: PackedStringArray = ["週日","週一","週二","週三","週四","週五","週六"]
	var hour: int = int(dt.hour)
	var period: String = "深夜"
	if hour >= 5 and hour < 9:      period = "清晨"
	elif hour >= 9 and hour < 12:   period = "上午"
	elif hour >= 12 and hour < 14:  period = "中午"
	elif hour >= 14 and hour < 18:  period = "下午"
	elif hour >= 18 and hour < 20:  period = "傍晚"
	elif hour >= 20 and hour < 24:  period = "晚上"
	var out: String = "\n\n# 你當下的時間感(自然運用,別逐字背)\n"
	out += "- 現在:%04d-%02d-%02d %s %02d:%02d(%s)\n" % [
		dt.year, dt.month, dt.day, weekdays[dt.weekday], dt.hour, dt.minute, period]
	if last_user > 0:
		out += "- 距離上一次跟主人講話:%s\n" % _format_gap(now - last_user)
		if now - last_user >= 21600:
			out += "  (隔了這麼久才見面,自然表達想念/好奇他去哪了,別當作剛剛才聊完)\n"
	if hour < 5 or hour >= 23:
		out += "- 這麼晚了,語氣可以帶點想睡/勸主人休息的關心\n"
	return out

## 撿最近 n 條 Doro 自己的回覆(去 JSON),提醒 LLM 別重複開頭句式
func _build_style_context(n: int) -> String:
	var recent: PackedStringArray = []
	for i in range(_history.size() - 1, -1, -1):
		if recent.size() >= n:
			break
		var m: Dictionary = _history[i]
		if String(m.get("role", "")) != "assistant":
			continue
		var raw: String = String(m.get("content", "")).strip_edges()
		## 剝 JSON:只留 text 欄
		var parser: JSON = JSON.new()
		var txt: String = raw
		if parser.parse(raw) == OK and typeof(parser.data) == TYPE_DICTIONARY:
			txt = String((parser.data as Dictionary).get("text", raw))
		txt = txt.strip_edges()
		if txt != "":
			recent.append(txt.substr(0, 60))
	if recent.is_empty():
		return ""
	var out: String = "\n# 你最近幾次說過的話(避免用同樣開頭/句式)\n"
	for r in recent:
		out += "- 「%s」\n" % r
	return out

func _format_gap(sec: int) -> String:
	if sec < 60:
		return "剛剛(%d 秒前)" % sec
	if sec < 3600:
		return "%d 分鐘前" % (sec / 60)
	if sec < 86400:
		return "%.1f 小時前" % (float(sec) / 3600.0)
	return "%d 天前" % (sec / 86400)

## 真正送 round (可含 tool result),共用 in-flight state
func _send_round() -> void:
	if not _in_flight:
		return   ## 被 abort() 中止
	var has_image: bool = _pending_image_b64 != ""
	## 若有 pending 截圖(來自 LLM tool_call take_screenshot),在送出前 append multimodal message
	if has_image:
		_running_messages.append({
			"role": "user",
			"content": [
				{"type": "text", "text": "這是剛拍的螢幕截圖,請看畫面內容回答上面的問題:"},
				{"type": "image_url", "image_url": {"url": "data:image/png;base64," + _pending_image_b64}},
			],
		})
		_pending_image_b64 = ""
	## 使用者送 send() 時直接帶的 image_b64 已經在 send() 內塞進 _running_messages 最後一條,
	## 這裡也要偵測 → 否則 stream 帶 multimodal 會卡住
	if not has_image and _running_messages.size() > 0:
		var last_msg: Dictionary = _running_messages.back()
		if typeof(last_msg.get("content")) == TYPE_ARRAY:
			has_image = true
	var body: Dictionary = {
		"model": _model,
		"messages": _running_messages,
		"max_tokens": 800,
		"temperature": 0.8,
		"tools": TOOLS_SCHEMA,
		"tool_choice": "auto",
		## 關閉 reasoning:seed-2.0-mini 等思考型模型會先吐幾千字元 reasoning
		## 才開始回答(實測 13.4s→1.2s,10 倍差)。桌寵短回覆不需要深思。
		"reasoning": {"enabled": false},
	}
	var headers: PackedStringArray = [
		"Authorization: Bearer " + _api_key,
		"Content-Type: application/json",
		"HTTP-Referer: https://github.com/Oliver0804/DoroPet",
		"X-Title: DoroPet",
	]
	## Stream 條件:enabled + 首輪 + 無圖(multimodal 不好 stream 解析 partial JSON)
	if _stream_enabled and _round == 0 and not has_image:
		body["stream"] = true
		_start_stream(body, headers)
		return
	var err: int = _http.request(ENDPOINT, headers, HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		_clear_flight()
		_history.pop_back()
		DoroLogger.log("chat_error", {"reason": "HTTPRequest start fail %d" % err})
		error_occurred.emit("HTTPRequest 啟動失敗: %d" % err)

## ---------- Streaming 實作 ----------
func _start_stream(body: Dictionary, headers: PackedStringArray) -> void:
	_stream_client = HTTPClient.new()
	var err: int = _stream_client.connect_to_host("openrouter.ai", 443, TLSOptions.client())
	if err != OK:
		DoroLogger.log("stream_error", {"stage": "connect", "err": err})
		_fallback_to_non_stream(body, headers)
		return
	## 明確要 SSE(不加也通常 work,但保險)
	var full_headers: PackedStringArray = headers.duplicate()
	full_headers.append("Accept: text/event-stream")
	_stream_state = STREAM_CONNECTING
	_stream_path = "/api/v1/chat/completions"
	_stream_headers = full_headers
	_stream_body_json = JSON.stringify(body)
	DoroLogger.log("stream_start", {"model": _model, "body_size": _stream_body_json.length()})
	_stream_buf = PackedByteArray()
	_stream_full_raw = PackedByteArray()
	_stream_content_acc = ""
	_stream_emitted_len = 0
	_stream_emo = 0
	_stream_emo_parsed = false
	_stream_first_emitted = false
	_stream_tool_calls = []
	_stream_started_ms = Time.get_ticks_msec()
	_stream_timer.start()

func _fallback_to_non_stream(body: Dictionary, headers: PackedStringArray) -> void:
	body.erase("stream")
	var err: int = _http.request(ENDPOINT, headers, HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		_clear_flight()
		if not _history.is_empty():
			_history.pop_back()
		error_occurred.emit("HTTP fallback fail: %d" % err)

func _on_stream_poll() -> void:
	if _stream_client == null:
		_stream_timer.stop()
		return
	## Timeout 保險:stream 卡 body 太久不回,強制 fail 讓 fallback 接手
	if Time.get_ticks_msec() - _stream_started_ms > STREAM_TIMEOUT_MS:
		_stream_fail("timeout %dms" % STREAM_TIMEOUT_MS)
		return
	_stream_client.poll()
	var st: int = _stream_client.get_status()
	match _stream_state:
		STREAM_CONNECTING:
			if st == HTTPClient.STATUS_CONNECTED:
				var err: int = _stream_client.request(HTTPClient.METHOD_POST,
					_stream_path, _stream_headers, _stream_body_json)
				if err == OK:
					_stream_state = STREAM_REQUESTING
				else:
					_stream_fail("request start fail %d" % err)
			elif st == HTTPClient.STATUS_CANT_CONNECT or st == HTTPClient.STATUS_CANT_RESOLVE:
				_stream_fail("connect fail st=%d" % st)
		STREAM_REQUESTING:
			if st == HTTPClient.STATUS_BODY:
				_stream_state = STREAM_READING
				var code: int = _stream_client.get_response_code()
				DoroLogger.log("stream_body_ready", {"http_code": code})
				if code < 200 or code >= 300:
					## 讀完 body 再 fail 出去(裡面通常有 error 訊息)
					var err_buf: PackedByteArray = PackedByteArray()
					while _stream_client.get_status() == HTTPClient.STATUS_BODY:
						_stream_client.poll()
						var c: PackedByteArray = _stream_client.read_response_body_chunk()
						if c.size() > 0:
							err_buf.append_array(c)
					_stream_fail("HTTP %d: %s" % [code,
						err_buf.get_string_from_utf8().substr(0, 200)])
					return
			elif st == HTTPClient.STATUS_DISCONNECTED or st == HTTPClient.STATUS_CONNECTION_ERROR:
				_stream_fail("disconnect during request st=%d" % st)
			elif st == HTTPClient.STATUS_CONNECTED:
				## request 送完立刻回 CONNECTED = 空 body
				_stream_fail("empty response")
		STREAM_READING:
			var chunk: PackedByteArray = _stream_client.read_response_body_chunk()
			if chunk.size() > 0:
				_stream_buf.append_array(chunk)
				_stream_full_raw.append_array(chunk)
				_process_sse_lines()
			elif st == HTTPClient.STATUS_DISCONNECTED or st == HTTPClient.STATUS_CONNECTION_ERROR \
					or st == HTTPClient.STATUS_CONNECTED:
				## body 讀完
				_stream_finish_success()

func _process_sse_lines() -> void:
	## 用 byte 找 \n(0x0A) 而非轉 UTF-8 string;chunk 常在中文字節中間切斷,
	## 直接 get_string_from_utf8() 會壞掉,line 級處理才安全
	var last_nl: int = -1
	for i in range(_stream_buf.size() - 1, -1, -1):
		if _stream_buf[i] == 0x0A:
			last_nl = i
			break
	if last_nl < 0:
		return
	var to_process_bytes: PackedByteArray = _stream_buf.slice(0, last_nl + 1)
	_stream_buf = _stream_buf.slice(last_nl + 1)
	var to_process: String = to_process_bytes.get_string_from_utf8()
	for line in to_process.split("\n"):
		var s: String = line.strip_edges()
		if s == "" or s.begins_with(":"):
			continue   ## SSE keep-alive comment (: OPENROUTER PROCESSING 等)
		if not s.begins_with("data:"):
			continue
		var data: String = s.substr(5).strip_edges()
		if data == "[DONE]":
			continue
		var parsed: Variant = JSON.parse_string(data)
		if typeof(parsed) != TYPE_DICTIONARY:
			continue
		_handle_stream_delta(parsed)

func _handle_stream_delta(chunk: Dictionary) -> void:
	var choices: Array = chunk.get("choices", [])
	if choices.is_empty():
		return
	var delta: Dictionary = (choices[0] as Dictionary).get("delta", {})
	if delta.has("tool_calls"):
		_merge_tool_calls(delta["tool_calls"])
	if delta.has("content"):
		var c: String = String(delta["content"])
		if c != "":
			_stream_content_acc += c
			if not _stream_emo_parsed:
				_try_parse_emo()
			_try_emit_sentence()

func _merge_tool_calls(deltas: Array) -> void:
	for d in deltas:
		if typeof(d) != TYPE_DICTIONARY:
			continue
		var idx: int = int(d.get("index", 0))
		while _stream_tool_calls.size() <= idx:
			_stream_tool_calls.append({"id": "", "type": "function",
				"function": {"name": "", "arguments": ""}})
		var slot: Dictionary = _stream_tool_calls[idx]
		var old_name: String = String(slot["function"].get("name", ""))
		if d.has("id"): slot["id"] = String(d["id"])
		var fn: Dictionary = d.get("function", {})
		if fn.has("name"):
			slot["function"]["name"] = String(slot["function"].get("name", "")) + String(fn["name"])
		if fn.has("arguments"):
			slot["function"]["arguments"] = String(slot["function"].get("arguments", "")) + String(fn["arguments"])
		var new_name: String = String(slot["function"].get("name", ""))
		## 首次偵測到 tool 名字 → 立刻通知 UI(不用等 stream 收完)
		if old_name == "" and new_name != "":
			DoroLogger.log("tool_detected_in_stream", {"name": new_name,
				"latency_ms": Time.get_ticks_msec() - _stream_started_ms})
			tool_started.emit(new_name)

func _try_parse_emo() -> void:
	var re: RegEx = RegEx.new()
	re.compile('"emotion"\\s*:\\s*(\\d+)')
	var m: RegExMatch = re.search(_stream_content_acc)
	if m != null:
		_stream_emo = int(m.get_string(1))
		_stream_emo_parsed = true

## 從累積的 raw content 抽「目前為止的 text 欄位」內容,並斷句 emit
func _try_emit_sentence() -> void:
	var partial: String = _extract_partial_text(_stream_content_acc)
	if partial.length() <= _stream_emitted_len:
		return
	var new_seg: String = partial.substr(_stream_emitted_len)
	var boundary: int = _find_sentence_boundary(new_seg)
	if boundary < 0:
		return
	var sentence: String = new_seg.substr(0, boundary + 1).strip_edges()
	_stream_emitted_len += boundary + 1
	if sentence == "":
		return
	var is_first: bool = not _stream_first_emitted
	_stream_first_emitted = true
	DoroLogger.log("stream_sentence", {"is_first": is_first,
		"sentence": sentence.substr(0, 80), "emo": _stream_emo,
		"latency_ms": Time.get_ticks_msec() - _stream_started_ms})
	sentence_stream.emit(sentence, is_first, _stream_emo)

const SENTENCE_BOUNDARIES: PackedStringArray = ["。", "！", "？", "!", "?", ".", "\n"]
func _find_sentence_boundary(s: String) -> int:
	var min_pos: int = -1
	for b in SENTENCE_BOUNDARIES:
		var p: int = s.find(b)
		if p >= 0 and (min_pos < 0 or p < min_pos):
			min_pos = p
	return min_pos

## partial JSON 抽 "text":"..." 之間的字元(容錯 escape)
func _extract_partial_text(content: String) -> String:
	var idx: int = content.find('"text":"')
	if idx < 0:
		return ""
	var body: String = content.substr(idx + 8)
	var end_i: int = -1
	var i: int = 0
	while i < body.length():
		var ch: String = body.substr(i, 1)
		if ch == "\\" and i + 1 < body.length():
			i += 2
			continue
		if ch == '"':
			end_i = i
			break
		i += 1
	var raw: String = body.substr(0, end_i) if end_i >= 0 else body
	## 還原常見 escape
	return raw.replace("\\n", "\n").replace('\\"', '"').replace("\\\\", "\\")

## SSE 沒抽到內容時的 fallback:嘗試把 body 當一次性 JSON 或 batched SSE parse
func _try_parse_non_sse_body(raw: String) -> Dictionary:
	var s: String = raw.strip_edges()
	if s == "":
		return {}
	## Case 1: 完整 non-stream response `{"choices":[{"message":{...}}]}`
	var parsed: Variant = JSON.parse_string(s)
	if typeof(parsed) == TYPE_DICTIONARY and (parsed as Dictionary).has("choices"):
		var choices: Array = parsed["choices"]
		if choices.size() > 0:
			var msg: Dictionary = (choices[0] as Dictionary).get("message", {})
			var content: String = String(msg.get("content", ""))
			if content != "":
				return _parse_reply_content_json(content)
	## Case 2: SSE lines 都在 raw 但 line-by-line 之前沒 process 到
	var concat: String = ""
	var concat_emo: int = 0
	for line in s.split("\n"):
		var ln: String = line.strip_edges()
		if not ln.begins_with("data:"):
			continue
		var data: String = ln.substr(5).strip_edges()
		if data == "[DONE]" or data == "":
			continue
		var d: Variant = JSON.parse_string(data)
		if typeof(d) != TYPE_DICTIONARY:
			continue
		var ch: Array = (d as Dictionary).get("choices", [])
		if ch.is_empty():
			continue
		var first: Dictionary = ch[0]
		var delta: Dictionary = first.get("delta", {})
		if delta.has("content"):
			concat += String(delta["content"])
		if first.has("message"):
			concat += String(first["message"].get("content", ""))
	if concat != "":
		return _parse_reply_content_json(concat)
	return {}

## 把 LLM 產出的 content (應該是 JSON `{"emotion":N,"text":"..."}`) parse 成 dict
func _parse_reply_content_json(content: String) -> Dictionary:
	var s: String = content.strip_edges()
	if s.begins_with("```"):
		s = s.trim_prefix("```json").trim_prefix("```").trim_suffix("```").strip_edges()
	var bs: int = s.find("{")
	var be: int = s.rfind("}")
	if bs >= 0 and be > bs:
		s = s.substr(bs, be - bs + 1)
	var d: Variant = JSON.parse_string(s)
	if typeof(d) == TYPE_DICTIONARY and (d as Dictionary).has("text"):
		return {"emotion": int((d as Dictionary).get("emotion", 0)),
			"text": String((d as Dictionary).get("text", ""))}
	## 純文字 fallback
	return {"emotion": 0, "text": content.strip_edges()}

func _stream_fail(reason: String) -> void:
	DoroLogger.log("stream_error", {"reason": reason,
		"acc_len": _stream_content_acc.length()})
	if _stream_client != null:
		_stream_client.close()
	_stream_client = null
	_stream_timer.stop()
	_stream_state = STREAM_IDLE
	## 有累到內容 → 當一般 reply 結束;沒累到 → 走 error
	if _stream_first_emitted or _stream_content_acc != "":
		_stream_finish_success()
	else:
		_clear_flight()
		if not _history.is_empty():
			_history.pop_back()
		error_occurred.emit("stream: " + reason)

func _stream_finish_success() -> void:
	if _stream_client != null:
		_stream_client.close()
	_stream_client = null
	_stream_timer.stop()
	_stream_state = STREAM_IDLE
	var latency_ms: int = Time.get_ticks_msec() - _stream_started_ms
	## Stream 中有 tool_calls → 走 tool round 邏輯(non-stream)
	if _stream_tool_calls.size() > 0 and _round < MAX_TOOL_ROUNDS:
		_round += 1
		var assistant_msg: Dictionary = {"role": "assistant", "content": "",
			"tool_calls": _stream_tool_calls.duplicate(true)}
		_running_messages.append(assistant_msg)
		var calls: Array = _stream_tool_calls.duplicate(true)
		_stream_tool_calls = []
		for tc in calls:
			var fn_name: String = String(tc["function"]["name"])
			var fn_args_str: String = String(tc["function"].get("arguments", "{}"))
			var args_parser: JSON = JSON.new()
			var args: Dictionary = {}
			if args_parser.parse(fn_args_str) == OK and typeof(args_parser.data) == TYPE_DICTIONARY:
				args = args_parser.data
			tool_started.emit(fn_name)
			var tool_result: String = await _execute_tool(fn_name, args)
			if not _in_flight:
				return
			DoroLogger.log("tool_call", {"name": fn_name, "args": args,
				"result": tool_result.substr(0, 200)})
			_running_messages.append({"role": "tool",
				"tool_call_id": tc["id"], "content": tool_result})
		thinking_resumed.emit()
		_send_round()
		return
	var full_text: String = _extract_partial_text(_stream_content_acc)
	## Stream 走完但 SSE 沒抽到 text → 可能 API 假 stream(回一次性 JSON)
	## 先試把 _stream_full_raw 當 non-stream JSON parse,直接抽 message.content
	if full_text.strip_edges() == "":
		var raw_text: String = _stream_full_raw.get_string_from_utf8()
		DoroLogger.log("stream_empty_fallback", {
			"acc_len": _stream_content_acc.length(),
			"raw_len": _stream_full_raw.size(),
			"raw_head": raw_text.substr(0, 300),
			"latency_ms": latency_ms})
		var recovered: Dictionary = _try_parse_non_sse_body(raw_text)
		if not recovered.is_empty():
			DoroLogger.log("stream_recovered_non_sse", {
				"text_len": String(recovered.get("text", "")).length(),
				"emotion": int(recovered.get("emotion", 0))})
			full_text = String(recovered.get("text", ""))
			_stream_emo = int(recovered.get("emotion", 0))
			## 直接 emit 整段當第一句(不再拆句,免延遲)
			if full_text != "":
				sentence_stream.emit(full_text, true, _stream_emo)
				_stream_first_emitted = true
				_stream_emitted_len = full_text.length()
		else:
			## 真的沒救 → 走 non-stream 重跑
			_stream_enabled = false
			_send_round()
			return
	## 剩下的尾巴 emit(最後一句沒句號的話)
	if _stream_emitted_len < full_text.length():
		var tail: String = full_text.substr(_stream_emitted_len).strip_edges()
		if tail != "":
			var is_first: bool = not _stream_first_emitted
			_stream_first_emitted = true
			sentence_stream.emit(tail, is_first, _stream_emo)
	## 收工:mood + history + reply_received
	_dbg_reply_raw = _stream_content_acc
	_dbg_reply_text = full_text
	_dbg_reply_emotion = _stream_emo
	_dbg_latency_ms = latency_ms
	if _mood != null and _stream_emo > 0:
		_mood.call("apply_emotion", _stream_emo)
	var reply_json: String = '{"emotion":%d,"text":"%s"}' % [_stream_emo,
		full_text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")]
	_history.append({"role": "assistant", "content": reply_json,
		"ts": int(Time.get_unix_time_from_system())})
	DoroLogger.log("chat_response", {"text": full_text, "emotion": _stream_emo,
		"model": _model, "latency_ms": latency_ms, "stream": true,
		"sentences_emitted": _stream_emitted_len})
	_clear_flight()
	if _mem != null:
		_mem.call("on_exchange", _history, _api_key,
			_distill_model if _distill_model != "" else _model)
	reply_received.emit(full_text, clamp(_stream_emo, 0, 14))

func _on_response(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
	var latency_ms: int = Time.get_ticks_msec() - _request_started_ms
	if result != HTTPRequest.RESULT_SUCCESS:
		_clear_flight()
		_history.pop_back()
		DoroLogger.log("chat_error", {"reason": "network result=%d" % result, "latency_ms": latency_ms})
		error_occurred.emit("網路錯誤 (result=%d)" % result)
		return
	var text: String = body.get_string_from_utf8()
	if code < 200 or code >= 300:
		_clear_flight()
		_history.pop_back()
		DoroLogger.log("chat_error", {"reason": "HTTP %d" % code, "body": text.substr(0, 500), "latency_ms": latency_ms})
		error_occurred.emit("HTTP %d: %s" % [code, text.substr(0, 200)])
		return
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		_clear_flight()
		_history.pop_back()
		error_occurred.emit("回覆格式異常")
		return
	var data: Dictionary = parsed
	if not data.has("choices") or (data["choices"] as Array).is_empty():
		_clear_flight()
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
	_clear_flight()
	var reply: String = String(message.get("content", ""))
	_history.append({"role": "assistant", "content": reply,
		"ts": int(Time.get_unix_time_from_system())})
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
	_dbg_reply_raw = reply
	_dbg_latency_ms = latency_ms
	if typeof(obj) == TYPE_DICTIONARY and (obj as Dictionary).has("text"):
		var emo: int = int((obj as Dictionary).get("emotion", 0))
		var txt: String = String((obj as Dictionary)["text"]).strip_edges()
		DoroLogger.log("chat_response", {"text": txt, "emotion": emo, "model": _model, "latency_ms": latency_ms})
		_dbg_reply_text = txt
		_dbg_reply_emotion = emo
		if _mood != null and emo > 0:
			_mood.call("apply_emotion", emo)
		reply_received.emit(txt, clamp(emo, 0, 14))
	else:
		DoroLogger.log("chat_response", {"text": clean, "raw": true, "model": _model, "latency_ms": latency_ms})
		_dbg_reply_text = clean
		_dbg_reply_emotion = 0
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
		"recall_memory":
			return String(_mem.call("recall", String(args.get("keyword", ""))))
		"web_search":
			return await _tool_web_search(String(args.get("query", "")))
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

## 免 key 網路搜尋:DuckDuckGo HTML 端點抓前 3 筆結果
func _tool_web_search(query: String) -> String:
	if query.strip_edges() == "":
		return "(搜尋關鍵字是空的)"
	var url: String = "https://html.duckduckgo.com/html/?q=%s" % query.uri_encode()
	var headers: PackedStringArray = [
		"User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
		"Accept-Language: zh-TW,zh;q=0.9,en;q=0.8",
	]
	var err: int = _tool_http.request(url, headers)
	if err != OK:
		return "(搜尋失敗 err=%d)" % err
	var result: Array = await _tool_http.request_completed
	var code: int = int(result[1])
	var body: PackedByteArray = result[3]
	if code < 200 or code >= 300:
		return "(搜尋 HTTP %d — 可能被限流,稍後再試)" % code
	return _parse_ddg_html(body.get_string_from_utf8(), 3)

func _parse_ddg_html(html: String, n: int) -> String:
	var titles_re: RegEx = RegEx.new()
	titles_re.compile('<a[^>]*class="result__a"[^>]*>([\\s\\S]*?)</a>')
	var snip_re: RegEx = RegEx.new()
	snip_re.compile('<a[^>]*class="result__snippet"[^>]*>([\\s\\S]*?)</a>')
	var titles: Array = titles_re.search_all(html)
	var snippets: Array = snip_re.search_all(html)
	var count: int = mini(mini(titles.size(), snippets.size()), n)
	if count == 0:
		## DDG 可能改版或被 rate limit → 至少回一段 raw text 節錄
		return "(沒抓到搜尋結果 — DDG 可能改版或被限流,關鍵字:%s)" % query_hint(html)
	var out: String = "搜尋結果:\n"
	for i in count:
		var t: String = _clean_html(titles[i].get_string(1))
		var s: String = _clean_html(snippets[i].get_string(1))
		out += "%d. %s\n   %s\n" % [i + 1, t, s.substr(0, 220)]
	return out.strip_edges()

func query_hint(html: String) -> String:
	## 從 <title>...</title> 撈一小段,幫助 debug
	var re: RegEx = RegEx.new()
	re.compile("<title>([^<]*)</title>")
	var m: RegExMatch = re.search(html)
	return m.get_string(1) if m != null else "unknown"

func _clean_html(s: String) -> String:
	var tag_re: RegEx = RegEx.new()
	tag_re.compile("<[^>]+>")
	s = tag_re.sub(s, "", true)
	return s.replace("&amp;", "&").replace("&quot;", "\"").replace("&#39;", "'") \
		.replace("&lt;", "<").replace("&gt;", ">").replace("&nbsp;", " ").strip_edges()

## wttr.in 免費 API,format=3 回單行(location, condition, temp, wind)
func _tool_get_weather(city: String) -> String:
	_last_weather_city = city
	## 先查 cache(投機預取或近期查過的)
	var key: String = city.to_lower().strip_edges()
	var now: int = int(Time.get_unix_time_from_system())
	if _weather_cache.has(key):
		var c: Dictionary = _weather_cache[key]
		if now - int(c.get("ts", 0)) < WEATHER_TTL_SEC:
			DoroLogger.log("weather_cache_hit", {"city": city})
			return String(c.get("text", ""))
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
	_weather_cache[key] = {"text": text, "ts": now}
	return text

## 背景投機預取(fire-and-forget);失敗無妨,tool 會自己抓
func _prefetch_weather(city: String) -> void:
	var key: String = city.to_lower().strip_edges()
	var now: int = int(Time.get_unix_time_from_system())
	if _weather_cache.has(key) \
			and now - int(_weather_cache[key].get("ts", 0)) < WEATHER_TTL_SEC:
		return   ## cache 還新鮮
	var url: String = "https://wttr.in/%s?format=3" % city.uri_encode()
	var headers: PackedStringArray = ["User-Agent: curl/7", "Accept-Language: zh-TW,en"]
	if _prefetch_http.request(url, headers) != OK:
		return
	var result: Array = await _prefetch_http.request_completed
	if int(result[1]) < 200 or int(result[1]) >= 300:
		return
	var text: String = (result[3] as PackedByteArray).get_string_from_utf8().strip_edges()
	if text != "":
		_weather_cache[key] = {"text": text,
			"ts": int(Time.get_unix_time_from_system())}
		DoroLogger.log("weather_prefetched", {"city": city, "text": text.substr(0, 60)})
