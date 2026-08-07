extends Node
## 記憶系統 v2 — 事實帳本(操作式蒸餾),對照 Mem0/Letta 的實踐:
## 1. 短期:對話歷史落盤(user://doro_history.json)
## 2. 長期:事實帳本(doro_facts.jsonl,一行一條事實),蒸餾輸出 add/update/delete
##    「操作」而非整份重寫 → 沒被觸及的事實一個字節都不變,杜絕轉述漂移
## 3. 歸檔:被刪除/過期的事實進 doro_archive.jsonl,可被 recall 搜回
## 4. 蒸餾只餵「上次之後的新訊息」,頻率 6 輪一次(少改多批,減少誤覆蓋)
## 5. 每日整理:合併重複、過期事件下沉歸檔

signal distilled(note: String)

const HISTORY_PATH: String = "user://doro_history.json"
const FACTS_PATH: String = "user://doro_facts.jsonl"
const ARCHIVE_PATH: String = "user://doro_archive.jsonl"
const META_PATH: String = "user://doro_memory_meta.json"
const FOLLOWUPS_PATH: String = "user://doro_followups.jsonl"
const SUMMARY_PATH: String = "user://doro_history_summary.txt"
## Context 摘要:超過門檻就把舊訊息壓成摘要,取代直接 rollover 丟失
const HISTORY_SUMMARIZE_THRESHOLD: int = 32   ## history 超過 32 條(16 turn)觸發
const HISTORY_KEEP_VERBATIM: int = 12         ## 保留最後 12 條(6 turn)原文
const SUMMARY_MAX_CHARS: int = 1500           ## 摘要本身上限,超過再壓縮
const LEGACY_PATH: String = "user://doro_memory.txt"   ## v1 扁平筆記(遷移用)
const DISTILL_EVERY: int = 12       ## 每 12 條訊息(6 輪)蒸餾一次
const MAX_NEW_MSGS: int = 24        ## 單次蒸餾最多帶的新訊息數
const ENDPOINT: String = "https://openrouter.ai/api/v1/chat/completions"
const DoroLogger := preload("res://scripts/logger.gd")

const TYPE_LABELS: Dictionary = {
	"identity": "身份/稱呼", "project": "工作/專案", "preference": "偏好與要求",
	"relation": "人際關係", "event": "重要事件", "warning": "警示",
	"habit": "習慣", "speech": "口頭禪/常用詞", "other": "其他",
}
const TYPE_ORDER: PackedStringArray = [
	"identity", "project", "preference", "relation", "warning", "habit", "speech", "event", "other"]

var _facts: Array = []              ## [{id,type,text,created,updated}]
var _followups: Array = []          ## [{id,due,text,created,consumed:bool}]
var _history_summary: String = ""   ## 累積摘要 (chat_client 注入 prompt)
var _summary_busy: bool = false
var _next_id: int = 1
var _next_followup_id: int = 1
var _since_distill: int = 0
var _last_consolidate: String = ""
var _busy: bool = false
var _http: HTTPRequest
var _summary_http: HTTPRequest    ## 摘要專用,免跟蒸餾撞 _http

func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = 120.0
	add_child(_http)
	_summary_http = HTTPRequest.new()
	_summary_http.timeout = 60.0
	add_child(_summary_http)
	_load_facts()
	_load_followups()
	_load_meta()
	_history_summary = _load_text(SUMMARY_PATH)

## ---------- 對外:短期歷史(與 v1 相同) ----------
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
	_history_summary = ""
	_save_text(SUMMARY_PATH, "")

## ---------- Context 摘要 ----------
func get_history_summary() -> String:
	return _history_summary

func summary_section() -> String:
	if _history_summary.strip_edges() == "":
		return ""
	return "\n\n# 更早的對話摘要(比目前上下文更舊,自然當作背景記憶)\n" \
		+ _history_summary.strip_edges() + "\n"

## 若 history 太長 → 摘要最舊那批,回傳新的(較短)history。呼叫者:chat_client.send() 前
## 用便宜的 distill_model 壓,失敗 keep 原樣。async。
func maybe_summarize_history(history: Array, api_key: String, model: String) -> Array:
	if _summary_busy or api_key == "" or history.size() <= HISTORY_SUMMARIZE_THRESHOLD:
		return history
	var cut_at: int = history.size() - HISTORY_KEEP_VERBATIM
	if cut_at <= 0:
		return history
	var old_part: Array = history.slice(0, cut_at)
	var convo: String = ""
	for m in old_part:
		var role: String = String(m.get("role", ""))
		if role == "user" and String(m.get("meta", "")) == "proactive":
			continue
		convo += "%s: %s\n" % ["主人" if role == "user" else "Doro",
			String(m.get("content", "")).substr(0, 200)]
	if convo.strip_edges() == "":
		return history
	_summary_busy = true
	var new_chunk: String = await _llm_summarize_convo(convo, api_key, model)
	_summary_busy = false
	if new_chunk.strip_edges() == "":
		return history
	if _history_summary.strip_edges() == "":
		_history_summary = new_chunk
	else:
		_history_summary += "\n" + new_chunk
	if _history_summary.length() > SUMMARY_MAX_CHARS:
		var condensed: String = await _llm_summarize_convo(
			"以下是舊對話摘要片段,合併壓縮成更精簡版本(< 800 字):\n" + _history_summary,
			api_key, model)
		if condensed.strip_edges() != "":
			_history_summary = condensed
	_save_text(SUMMARY_PATH, _history_summary)
	DoroLogger.log("history_summarized", {
		"old_msgs": old_part.size(),
		"kept_msgs": HISTORY_KEEP_VERBATIM,
		"summary_chars": _history_summary.length()})
	return history.slice(cut_at)

const HIST_SUMMARY_PROMPT: String = """把下面對話濃縮成 3-5 句繁體中文摘要,
保留:主人做過的重要事、決定、心情起伏、Doro 觀察到的主人狀態變化。
省略:寒暄、問時間問天氣、單次玩笑。
只輸出摘要正文,不要標題不要條列符號,句子短、要點明確。"""

func _llm_summarize_convo(convo: String, api_key: String, model: String) -> String:
	var body: Dictionary = {
		"model": model,
		"messages": [
			{"role": "system", "content": HIST_SUMMARY_PROMPT},
			{"role": "user", "content": convo},
		],
		"max_tokens": 500,
		"temperature": 0.2,
	}
	var headers: PackedStringArray = [
		"Authorization: Bearer " + api_key,
		"Content-Type: application/json",
		"HTTP-Referer: https://github.com/Oliver0804/DoroPet",
		"X-Title: DoroPet",
	]
	if _summary_http.request(ENDPOINT, headers, HTTPClient.METHOD_POST, JSON.stringify(body)) != OK:
		return ""
	var result: Array = await _summary_http.request_completed
	if int(result[0]) != HTTPRequest.RESULT_SUCCESS or int(result[1]) < 200 or int(result[1]) >= 300:
		return ""
	var parsed: Variant = JSON.parse_string((result[3] as PackedByteArray).get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY or not (parsed as Dictionary).has("choices"):
		return ""
	return _choice_content(parsed).strip_edges()

## 從 OpenRouter 回應抽 choices[0].message.content。
## 思考型模型可能回 content:null,String(null) 在 export build 會拿到暫存器殘值
## (整包 response body),必須型別檢查後才轉字串。
static func _choice_content(parsed: Variant) -> String:
	if typeof(parsed) != TYPE_DICTIONARY:
		return ""
	var choices: Array = (parsed as Dictionary).get("choices", [])
	if choices.is_empty() or typeof(choices[0]) != TYPE_DICTIONARY:
		return ""
	var msg: Variant = (choices[0] as Dictionary).get("message")
	if typeof(msg) != TYPE_DICTIONARY:
		return ""
	var c: Variant = (msg as Dictionary).get("content")
	return c if c is String else ""

## ---------- 對外:注入 context 的記憶段 ----------
func get_memory() -> String:
	return _render_facts()

func memory_section() -> String:
	var body: String = _render_facts()
	if body.strip_edges() == "":
		return ""
	## 整段標題已限定「關於主人」,下面條列都省略主詞;讀時把每條當「主人 <該條>」理解
	var out: String = "\n\n# 關於主人(累積的筆記,自然運用,別逐條背誦)\n" + body + "\n"
	if body.contains("【口頭禪"):
		out += "(【口頭禪】那些詞可以偶爾自然學來用—頻率低、別每句都塞)\n"
	return out

const MEMORY_SECTION_MAX_CHARS: int = 2500   ## 注入 prompt 的記憶段上限,超過就精簡

## 帳本 → 分類條列文字。當總長超過上限,依 TYPE_ORDER 優先順序取,
## event/project 只保留近期,其餘靠 LLM 用 recall_memory 撈
func _render_facts() -> String:
	if _facts.is_empty():
		return ""
	## 先分組並依 event 日期新到舊排序
	var groups: Dictionary = {}
	for f in _facts:
		var t: String = String(f.get("type", "other"))
		if not groups.has(t):
			groups[t] = []
		groups[t].append(f)
	if groups.has("event"):
		var arr: Array = groups["event"]
		arr.sort_custom(func(a, b): return String(a.get("created", "")) > String(b.get("created", "")))
		groups["event"] = arr
	if groups.has("project"):
		var arr2: Array = groups["project"]
		arr2.sort_custom(func(a, b): return String(a.get("updated", "")) > String(b.get("updated", "")))
		groups["project"] = arr2

	var full: String = _format_groups(groups, {})
	if full.length() <= MEMORY_SECTION_MAX_CHARS:
		return full.strip_edges()

	## 超過上限 → 每類設上限,event/project 只保留 5 條
	var caps: Dictionary = {"event": 5, "project": 5, "other": 3}
	var trimmed: String = _format_groups(groups, caps)
	if trimmed.length() <= MEMORY_SECTION_MAX_CHARS:
		return (trimmed + "\n(其餘記憶靠 recall_memory 撈)").strip_edges()
	## 仍超過 → 進一步砍到剛好上限,尾巴接省略提示
	trimmed = trimmed.substr(0, MEMORY_SECTION_MAX_CHARS)
	return (trimmed + "\n…(記憶太多,已省略;用 recall_memory 找特定關鍵字)").strip_edges()

func _format_groups(groups: Dictionary, per_type_cap: Dictionary) -> String:
	var out: String = ""
	for t in TYPE_ORDER:
		if not groups.has(t):
			continue
		out += "【%s】\n" % TYPE_LABELS.get(t, t)
		var arr: Array = groups[t]
		var cap: int = int(per_type_cap.get(t, -1))
		var n: int = arr.size() if cap < 0 else mini(arr.size(), cap)
		for i in n:
			var f: Dictionary = arr[i]
			var date_tag: String = ""
			if t == "event":
				date_tag = "(%s)" % String(f.get("created", ""))
			out += "- %s%s\n" % [_strip_owner_prefix(String(f.get("text", ""))), date_tag]
		if cap >= 0 and arr.size() > cap:
			out += "  (…另有 %d 條省略)\n" % (arr.size() - cap)
	return out

## 判斷一條 add op 看起來像不像 Doro 自己回音被誤蒸餾成主人的話
## 主要防 speech 污染,但 identity/preference 等含明顯自稱 Doro 的也擋
const _POLLUTION_KEYWORDS: PackedStringArray = [
	"Doro", "抄我", "偷學", "我的台詞", "我講話", "學我", "偷臭"]
func _looks_like_doro_selfspeak(op: Dictionary) -> bool:
	var text: String = String(op.get("text", ""))
	var typ: String = String(op.get("type", ""))
	if typ == "speech":
		for kw in _POLLUTION_KEYWORDS:
			if text.contains(kw):
				return true
		if text.begins_with("哼！") or text.begins_with("哼!"):
			return true
		if text.contains("才沒有啦") or text.contains("明明就是你") or text.contains("明明是你"):
			return true
		## 撒嬌語尾 (~ + 啦/呀/喔) 大量出現 → Doro 語氣
		if text.contains("~") and (text.contains("啦") or text.contains("呀") or text.contains("喔")):
			return true
	## 非 speech 也擋明顯自稱 Doro / 「我的台詞」的
	for kw in ["抄我的", "偷學Doro", "我的台詞"]:
		if text.contains(kw):
			return true
	return false

## 記憶條在「關於主人」段下,開頭的「主人/主人的」冗詞剝掉,主詞讓 LLM 從上下文補
func _strip_owner_prefix(text: String) -> String:
	var t: String = text.strip_edges()
	if t.begins_with("主人的"):
		return t.substr(3).strip_edges()
	if t.begins_with("主人"):
		return t.substr(2).strip_edges()
	return t

## ---------- 對外:每輪對話後呼叫 ----------
func on_exchange(history: Array, api_key: String, model: String) -> void:
	save_history(history)
	_since_distill += 2
	if _busy or api_key == "":
		return
	## v1 → v2 遷移:還沒有帳本但有舊筆記 → 先把舊筆記拆成事實
	if _facts.is_empty() and _load_text(LEGACY_PATH).strip_edges() != "":
		_migrate_legacy(api_key, model)
		return
	if _since_distill >= DISTILL_EVERY:
		_distill(history, api_key, model)

## ---------- 蒸餾:只餵新訊息,輸出操作 ----------
const DISTILL_PROMPT: String = """你是 Doro(桌面寵物)的記憶管理器。
根據「新對話」對「既有事實帳本」提出修改操作,輸出 JSON array:
[{"op":"add","type":"<類型>","text":"..."},
 {"op":"update","id":<編號>,"text":"..."},
 {"op":"delete","id":<編號>,"reason":"過時/錯誤"},
 {"op":"followup","due":"YYYY-MM-DD","text":"到時候你想主動關心/追問的一句話"}]
類型限定:identity(身份) project(工作專案) preference(偏好要求)
relation(人際,名字+關係) event(帶日期事件) warning(警示) habit(穩定習慣)
speech(主人的口頭禪/常用詞/語尾癖,必須是重複出現多次的)
規則:
- 只記值得長期記住的事實;瑣事(單次行為、打招呼方式)不記
- 主人在對話中**重複使用**的口頭禪、常用詞、介係詞習慣 → 記 speech
  (例:「主打一個X」「媽的」「就是說」;只出現一次的不算)
- **STT 回音警戒**:若「主人」的訊息明顯是 Doro 語氣(「哼！」開頭撒嬌詞、
  自稱 Doro、「~」語尾、「才沒有啦」「明明就是你」「抄我 / 學我 / 我的台詞」),
  那極可能是 STT 誤把 Doro 自己回音當主人講話。**跳過整條訊息**,
  不要當 speech 記,也不要基於它推 identity / preference / event
- 與既有事實矛盾 → update 該編號;不再成立 → delete
- 既有帳本已涵蓋 → 不要重複 add;沒有新東西就輸出 []
- event 的 text 開頭帶時間戳(今天是 {date}):
  * 需要精確時序的:「YYYY-MM-DD HH:MM 主人熬夜寫 code 到崩潰」
  * 一般日期即可:「YYYY-MM-DD 主人生日」
  * 依事件重要性判斷,別每件都記到分鐘
- text 一律用繁體中文(台灣用字)
- **text 不要以「主人」開頭**,主詞省略(整段已在「關於主人」下)
  例:記「喜歡吃布丁」不寫「主人喜歡吃布丁」;「明天要面試」不寫「主人明天要面試」
- followup:主人提到「明天/下週/等下要 X」「稍後要 Y」等未來事件 → 用 followup
  記下你未來想主動關心的話,due 是那件事發生的日期(相對今天推算)。
  例:主人說「明天要面試」→ {"op":"followup","due":"...","text":"面試怎麼樣了?緊張嗎"}
  只在主人明確提到未來時間點時建立;沒有就不要憑空生。
- 只輸出 JSON array,不要解釋、不要 code fence"""

func _distill(history: Array, api_key: String, model: String) -> void:
	_busy = true
	var n: int = mini(_since_distill, MAX_NEW_MSGS)
	var tail: Array = history.slice(maxi(0, history.size() - n))
	var convo: String = ""
	for m in tail:
		var role: String = String(m.get("role", ""))
		## 系統注入的 proactive 提示不是主人講的話,跳過(Doro 對 proactive 的回覆仍保留)
		if role == "user" and String(m.get("meta", "")) == "proactive":
			continue
		convo += "%s: %s\n" % ["主人" if role == "user" else "Doro", String(m.get("content", ""))]
	var user_msg: String = "【既有事實帳本】\n%s\n\n【新對話】\n%s" % [_ledger_text(), convo]
	var dt: Dictionary = Time.get_datetime_dict_from_system()
	var now_ref: String = "%04d-%02d-%02d %02d:%02d" % [
		dt.year, dt.month, dt.day, dt.hour, dt.minute]
	var ok: bool = await _llm_ops(api_key, model,
		DISTILL_PROMPT.replace("{date}", now_ref), user_msg)
	_busy = false
	if ok:
		_since_distill = 0
		_save_all()
		DoroLogger.log("memory_distilled", {"facts": _facts.size()})
		distilled.emit(_render_facts())
		_maybe_consolidate(api_key, model)

## 帳本渲染成「#id [類型] 內容」給 LLM 看
func _ledger_text() -> String:
	if _facts.is_empty():
		return "(空)"
	var out: String = ""
	for f in _facts:
		out += "#%d [%s] %s\n" % [int(f.get("id", 0)), String(f.get("type", "other")), String(f.get("text", ""))]
	return out

## 呼叫 LLM 拿操作陣列並套用;回傳是否成功
func _llm_ops(api_key: String, model: String, system_prompt: String, user_msg: String) -> bool:
	var body: Dictionary = {
		"model": model,
		"messages": [
			{"role": "system", "content": system_prompt},
			{"role": "user", "content": user_msg},
		],
		"max_tokens": 8000,
		"temperature": 0.1,
	}
	var headers: PackedStringArray = [
		"Authorization: Bearer " + api_key,
		"Content-Type: application/json",
		"HTTP-Referer: https://github.com/Oliver0804/DoroPet",
		"X-Title: DoroPet",
	]
	if _http.request(ENDPOINT, headers, HTTPClient.METHOD_POST, JSON.stringify(body)) != OK:
		DoroLogger.log("memory_distill_error", {"reason": "request start fail"})
		return false
	var result: Array = await _http.request_completed
	if int(result[0]) != HTTPRequest.RESULT_SUCCESS or int(result[1]) < 200 or int(result[1]) >= 300:
		DoroLogger.log("memory_distill_error", {"reason": "HTTP %d" % int(result[1])})
		return false
	var parsed: Variant = JSON.parse_string((result[3] as PackedByteArray).get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY or not (parsed as Dictionary).has("choices"):
		DoroLogger.log("memory_distill_error", {"reason": "bad json"})
		return false
	var text: String = _choice_content(parsed).strip_edges()
	if text.begins_with("```"):
		text = text.trim_prefix("```json").trim_prefix("```").trim_suffix("```").strip_edges()
	## 剝掉 array 外的前後綴
	var s: int = text.find("[")
	var e: int = text.rfind("]")
	if s < 0 or e <= s:
		DoroLogger.log("memory_distill_error", {"reason": "no ops array", "raw": text.substr(0, 100)})
		return false
	var ops: Variant = JSON.parse_string(text.substr(s, e - s + 1))
	if typeof(ops) != TYPE_ARRAY:
		DoroLogger.log("memory_distill_error", {"reason": "ops parse fail"})
		return false
	_apply_ops(ops)
	return true

## 套用操作到帳本;delete 進歸檔不銷毀
func _apply_ops(ops: Array) -> void:
	var dt: Dictionary = Time.get_datetime_dict_from_system()
	var today: String = "%04d-%02d-%02d" % [dt.year, dt.month, dt.day]
	## created/updated 用 datetime 時分秒:回顧記憶時能 sort by time,recall 更準
	var now_iso: String = "%04d-%02d-%02d %02d:%02d:%02d" % [
		dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second]
	var applied: Dictionary = {"add": 0, "update": 0, "delete": 0, "followup": 0, "rejected": 0}
	for o in ops:
		if typeof(o) != TYPE_DICTIONARY:
			continue
		## 第三層保險:防止蒸餾器把 Doro 自己語氣的話當主人口頭禪記進去
		if String(o.get("op", "")) == "add" and _looks_like_doro_selfspeak(o):
			applied["rejected"] += 1
			DoroLogger.log("distill_rejected", {
				"reason": "self_speak_pollution",
				"type": String(o.get("type", "")),
				"text": String(o.get("text", "")).substr(0, 80)})
			continue
		match String(o.get("op", "")):
			"followup":
				var due: String = String(o.get("due", "")).strip_edges()
				var ftext: String = String(o.get("text", "")).strip_edges()
				if due == "" or ftext == "":
					continue
				_followups.append({
					"id": _next_followup_id, "due": due, "text": ftext,
					"created": today, "consumed": false,
				})
				_next_followup_id += 1
				applied["followup"] += 1
			"add":
				var text: String = String(o.get("text", "")).strip_edges()
				if text == "":
					continue
				var t: String = String(o.get("type", "other"))
				if not TYPE_LABELS.has(t):
					t = "other"
				_facts.append({"id": _next_id, "type": t, "text": text,
					"created": now_iso, "updated": now_iso})
				_next_id += 1
				applied["add"] += 1
			"update":
				var uid: int = int(o.get("id", -1))
				for f in _facts:
					if int(f.get("id", 0)) == uid:
						f["text"] = String(o.get("text", f["text"]))
						f["updated"] = now_iso
						applied["update"] += 1
						break
			"delete":
				var did: int = int(o.get("id", -1))
				for i in _facts.size():
					if int(_facts[i].get("id", 0)) == did:
						var f: Dictionary = _facts[i]
						f["archived"] = now_iso
						f["reason"] = String(o.get("reason", ""))
						_append_jsonl(ARCHIVE_PATH, f)
						_facts.remove_at(i)
						applied["delete"] += 1
						break
	DoroLogger.log("memory_ops", applied)

## ---------- v1 遷移:舊扁平筆記拆成事實 ----------
const MIGRATE_PROMPT: String = """把下面這份人物筆記拆成獨立事實,輸出 JSON array:
[{"op":"add","type":"<類型>","text":"一條獨立完整的事實"}]
類型限定:identity project preference relation event warning habit
- 每條事實獨立可讀,不依賴上下文
- 瑣事(單次行為、口頭禪列舉)直接丟棄
- text 一律用繁體中文(台灣用字)
- 只輸出 JSON array"""

func _migrate_legacy(api_key: String, model: String) -> void:
	_busy = true
	var legacy: String = _load_text(LEGACY_PATH)
	DoroLogger.log("memory_migrate_start", {"chars": legacy.length()})
	var ok: bool = await _llm_ops(api_key, model, MIGRATE_PROMPT, legacy)
	_busy = false
	if ok and not _facts.is_empty():
		_save_all()
		## 舊筆記改名保留備份,避免重複遷移
		DirAccess.rename_absolute(
			ProjectSettings.globalize_path(LEGACY_PATH),
			ProjectSettings.globalize_path(LEGACY_PATH + ".migrated"))
		DoroLogger.log("memory_migrate_done", {"facts": _facts.size()})
		distilled.emit(_render_facts())

## ---------- 每日整理:合併重複、過期事件下沉 ----------
const CONSOLIDATE_PROMPT: String = """你是記憶整理器。檢查這份事實帳本,輸出修正操作(JSON array):
- 內容重複/高度相似的多條 → 保留一條(update 使其完整),其餘 delete
- event 超過 7 天且非長期重要 → delete(reason:"過期")
- 明顯矛盾 → 保留較新的,delete 舊的
- 帳本健康就輸出 []
今天是 {date}。只輸出 JSON array。"""

func _maybe_consolidate(api_key: String, model: String) -> void:
	var dt: Dictionary = Time.get_datetime_dict_from_system()
	var today: String = "%04d-%02d-%02d" % [dt.year, dt.month, dt.day]
	if _last_consolidate == today or _facts.size() < 15 or _busy:
		return
	_busy = true
	var ledger: String = ""
	for f in _facts:
		ledger += "#%d [%s] (建立 %s) %s\n" % [int(f["id"]), String(f["type"]),
			String(f.get("created", "")), String(f["text"])]
	var ok: bool = await _llm_ops(api_key, model,
		CONSOLIDATE_PROMPT.replace("{date}", today), ledger)
	_busy = false
	if ok:
		_last_consolidate = today
		_save_all()
		DoroLogger.log("memory_consolidated", {"facts": _facts.size()})

## ---------- recall:搜尋歸檔 + 對話 log ----------
func recall(keyword: String) -> String:
	var kw: String = keyword.strip_edges()
	if kw == "":
		return "(關鍵字是空的)"
	var hits: Array = []
	## 1. 現役帳本
	for f in _facts:
		if String(f["text"]).contains(kw):
			hits.append("[記憶] %s" % String(f["text"]))
	## 2. 歸檔
	for line in _load_text(ARCHIVE_PATH).split("\n"):
		if line.contains(kw):
			var d: Variant = JSON.parse_string(line)
			if typeof(d) == TYPE_DICTIONARY:
				hits.append("[舊記憶,%s 歸檔] %s" % [String(d.get("archived", "?")), String(d.get("text", ""))])
	## 3. 對話 log(由新到舊掃,最多 10 筆)
	var log_dir: String = "user://logs"
	var files: PackedStringArray = DirAccess.get_files_at(log_dir)
	files.sort()
	files.reverse()
	for fname in files:
		if hits.size() >= 14 or not fname.ends_with(".jsonl"):
			continue
		var day: String = fname.trim_suffix(".jsonl")
		for line in _load_text(log_dir + "/" + fname).split("\n"):
			if hits.size() >= 14:
				break
			if not line.contains(kw):
				continue
			var d: Variant = JSON.parse_string(line)
			if typeof(d) != TYPE_DICTIONARY:
				continue
			var t: String = String((d as Dictionary).get("type", ""))
			if t == "chat_request":
				## 系統自動觸發的 proactive 搭話提示不算主人講的話
				if String((d as Dictionary).get("meta", "")) == "proactive":
					continue
				hits.append("[%s 主人說] %s" % [day, String(d.get("text", "")).substr(0, 80)])
			elif t == "chat_response":
				hits.append("[%s Doro說] %s" % [day, String(d.get("text", "")).substr(0, 80)])
	if hits.is_empty():
		return "(翻遍記憶和舊對話都沒找到「%s」)" % kw
	return "\n".join(PackedStringArray(hits)).substr(0, 1200)

## ---------- 檔案 IO ----------
func _load_facts() -> void:
	_facts.clear()
	for line in _load_text(FACTS_PATH).split("\n"):
		if line.strip_edges() == "":
			continue
		var d: Variant = JSON.parse_string(line)
		if typeof(d) == TYPE_DICTIONARY:
			_facts.append(d)
			_next_id = maxi(_next_id, int((d as Dictionary).get("id", 0)) + 1)

func _save_all() -> void:
	var out: String = ""
	for f in _facts:
		out += JSON.stringify(f) + "\n"
	_save_text(FACTS_PATH, out)
	_save_followups()
	_save_text(META_PATH, JSON.stringify({
		"next_id": _next_id, "next_followup_id": _next_followup_id,
		"last_consolidate": _last_consolidate}))

## ---------- Followups(前瞻記憶) ----------
func _load_followups() -> void:
	_followups.clear()
	for line in _load_text(FOLLOWUPS_PATH).split("\n"):
		if line.strip_edges() == "":
			continue
		var d: Variant = JSON.parse_string(line)
		if typeof(d) == TYPE_DICTIONARY:
			_followups.append(d)
			_next_followup_id = maxi(_next_followup_id, int((d as Dictionary).get("id", 0)) + 1)

func _save_followups() -> void:
	var out: String = ""
	for f in _followups:
		out += JSON.stringify(f) + "\n"
	_save_text(FOLLOWUPS_PATH, out)

## 撿一條到期(due <= today)且未消化的 followup;找到就標記 consumed 存檔
func pop_due_followup() -> Dictionary:
	var dt: Dictionary = Time.get_datetime_dict_from_system()
	var today: String = "%04d-%02d-%02d" % [dt.year, dt.month, dt.day]
	for f in _followups:
		if bool(f.get("consumed", false)):
			continue
		var due: String = String(f.get("due", ""))
		if due != "" and due <= today:
			f["consumed"] = true
			f["consumed_on"] = today
			_save_followups()
			DoroLogger.log("followup_pop", {"id": f.get("id"), "due": due,
				"text": String(f.get("text", "")).substr(0, 60)})
			return f
	return {}

## 給 debug view 讀所有 followups(唯讀複本)
func get_all_followups() -> Array:
	return _followups.duplicate()

## 未消化且已到期的數量(給 UI/log 統計用)
func due_followup_count() -> int:
	var dt: Dictionary = Time.get_datetime_dict_from_system()
	var today: String = "%04d-%02d-%02d" % [dt.year, dt.month, dt.day]
	var c: int = 0
	for f in _followups:
		if bool(f.get("consumed", false)):
			continue
		if String(f.get("due", "")) <= today:
			c += 1
	return c

func _load_meta() -> void:
	var raw: String = _load_text(META_PATH)
	if raw.strip_edges() == "":
		return
	var d: Variant = JSON.parse_string(raw)
	if typeof(d) == TYPE_DICTIONARY:
		_next_id = maxi(_next_id, int((d as Dictionary).get("next_id", 1)))
		_next_followup_id = maxi(_next_followup_id,
			int((d as Dictionary).get("next_followup_id", 1)))
		_last_consolidate = String((d as Dictionary).get("last_consolidate", ""))

func _append_jsonl(path: String, obj: Dictionary) -> void:
	var f: FileAccess
	if FileAccess.file_exists(path):
		f = FileAccess.open(path, FileAccess.READ_WRITE)
		f.seek_end()
	else:
		f = FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_line(JSON.stringify(obj))
		f.close()

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
