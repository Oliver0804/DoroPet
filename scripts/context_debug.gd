extends Window
## LLM Debug 視窗 — 即時觀察後端(像 tail -f)
##
## Tabs:
##   1) 🧠 Brain    — 當下心情 + 事實帳本 + Followups(每秒 refresh)
##   2) 📡 Live Log — tail user://logs/YYYY-MM-DD.jsonl,新事件即時 append 底部
##                    上:Tree 每列一筆事件 [時間 · 類型 · 摘要]
##                    下:Detail 顯示點選那筆事件的完整 JSON
##                    可過濾類型、暫停、清空、自動捲底
##   3) 📸 Snapshot — 最近一次 send 的完整 system prompt / messages / reply

const DoroLogger := preload("res://scripts/logger.gd")

var _chat: Node
var _tabs: TabContainer

## --- Brain tab ---
var _brain_view: TextEdit
var _brain_timer: Timer

## --- Live tab ---
var _live_tree: Tree
var _live_detail: TextEdit
var _live_filter: LineEdit
var _live_auto_scroll: CheckBox
var _live_paused: CheckBox
var _live_count_label: Label
var _stats_label: Label
var _live_timer: Timer
var _log_path: String = ""
var _log_offset: int = 0
var _events: Array = []          ## 全解析事件[Dictionary]
const MAX_EVENTS: int = 2000     ## ring buffer 上限;防記憶體爆炸

## --- Snapshot tab ---
var _snap_tabs: TabContainer
var _snap_prompt: TextEdit
var _snap_messages: TextEdit
var _snap_reply: TextEdit

## 事件類別顏色 (BBCode 用不到,Tree cell 顏色用)
const TYPE_COLORS: Dictionary = {
	"chat_request":      Color(0.5, 0.8, 1.0),
	"chat_prompt":       Color(0.4, 0.6, 0.9),
	"chat_response":     Color(0.5, 1.0, 0.6),
	"chat_error":        Color(1.0, 0.4, 0.4),
	"chat_abort":        Color(0.9, 0.6, 0.4),
	"tool_call":         Color(0.9, 0.7, 1.0),
	"stt_request":       Color(0.7, 0.9, 0.9),
	"stt_response":      Color(0.5, 0.9, 0.9),
	"stt_error":         Color(1.0, 0.4, 0.4),
	"stt_echo_dropped":  Color(0.6, 0.6, 0.6),
	"stt_session":       Color(0.6, 0.7, 0.8),
	"tts_vb_fallback":   Color(1.0, 0.6, 0.4),
	"barge_in":          Color(1.0, 0.8, 0.3),
	"mood_apply":        Color(1.0, 0.6, 0.8),
	"memory_ops":        Color(0.6, 0.9, 0.6),
	"memory_distilled":  Color(0.5, 1.0, 0.5),
	"memory_migrate_start": Color(0.7, 0.9, 0.5),
	"memory_migrate_done":  Color(0.5, 1.0, 0.5),
	"memory_consolidated": Color(0.5, 0.9, 0.7),
	"memory_distill_error": Color(1.0, 0.5, 0.5),
	"followup_pop":      Color(1.0, 0.9, 0.5),
	"proactive_followup":Color(1.0, 0.85, 0.5),
	"startup_greeting":  Color(1.0, 0.9, 0.6),
	"idle_voice_play":   Color(0.8, 0.8, 0.6),
	"screenshot_captured": Color(0.7, 0.8, 1.0),
	"screenshot_retry":    Color(1.0, 0.7, 0.5),
	"screenshot_error":    Color(1.0, 0.5, 0.5),
	"screen_promise_retry":Color(1.0, 0.7, 0.4),
	"user_abort":        Color(0.9, 0.6, 0.4),
}

func set_chat(chat: Node) -> void:
	_chat = chat

func _init() -> void:
	title = "🔍 Doro Debug — 後端即時檢視"
	size = Vector2i(1100, 720)
	min_size = Vector2i(600, 400)
	transparent = false
	unresizable = false
	unfocusable = false
	close_requested.connect(func() -> void: hide())

func _ready() -> void:
	var root: VBoxContainer = VBoxContainer.new()
	root.anchor_right = 1.0
	root.anchor_bottom = 1.0
	root.add_theme_constant_override("separation", 4)
	add_child(root)

	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(_tabs)

	_build_brain_tab()
	_build_live_tab()
	_build_snapshot_tab()

	_brain_timer = Timer.new()
	_brain_timer.wait_time = 1.0
	_brain_timer.autostart = false
	_brain_timer.timeout.connect(_refresh_brain)
	add_child(_brain_timer)

	_live_timer = Timer.new()
	_live_timer.wait_time = 0.4
	_live_timer.autostart = false
	_live_timer.timeout.connect(_poll_live_log)
	add_child(_live_timer)

## ---------- Brain tab ----------
func _build_brain_tab() -> void:
	var margin: MarginContainer = _pad_margin()
	_brain_view = _make_readonly_text()
	margin.add_child(_brain_view)
	_tabs.add_child(margin)
	_tabs.set_tab_title(_tabs.get_tab_count() - 1, "🧠 Brain")

func _refresh_brain() -> void:
	if _chat == null:
		_brain_view.text = "(尚未注入 chat client)"
		return
	var out: String = ""
	var mood: Node = _chat.call("get_mood")
	if mood != null:
		out += "─── 🧡 心情狀態 ──────────────────\n"
		out += "  Valence(愉悅度): %+.3f  [-1 低落 ↔ +1 開心]\n" % float(mood.call("get_valence"))
		out += "  Arousal(活力):   %.3f  [ 0 慵懶 ↔  1 亢奮]\n" % float(mood.call("get_arousal"))
		out += "\n  ↳ 注入 prompt 的心情段:\n"
		out += _indent(String(mood.call("prompt_line")), "    ") + "\n\n"
	var mem: Node = _chat.get_node_or_null("MemoryStore")
	if mem != null:
		var summary: String = String(mem.call("get_history_summary"))
		out += "─── 📝 更早對話摘要 ──────────────\n"
		if summary.strip_edges() == "":
			out += "  (空 — history 還沒超過摘要門檻)\n\n"
		else:
			out += _indent(summary, "  ") + "\n\n"
		var facts_text: String = String(mem.call("get_memory"))
		out += "─── 📚 事實帳本(長期記憶) ────────\n"
		if facts_text.strip_edges() == "":
			out += "  (空 — 還沒累積夠訊息蒸餾,或首次啟動)\n\n"
		else:
			out += _indent(facts_text, "  ") + "\n\n"
		out += "─── 📅 Followups(前瞻記憶) ────────\n"
		out += "  到期未消化: %d 條\n" % int(mem.call("due_followup_count"))
		var all: Array = mem.call("get_all_followups")
		if all.is_empty():
			out += "  (空)\n"
		else:
			for f in all:
				var mark: String = "✓" if bool(f.get("consumed", false)) else "○"
				out += "  %s #%d [due=%s] %s\n" % [mark, int(f.get("id", 0)),
					String(f.get("due", "?")),
					String(f.get("text", "")).substr(0, 100)]
	_brain_view.text = out

## ---------- Live tab ----------
func _build_live_tab() -> void:
	var v: VBoxContainer = VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.size_flags_vertical = Control.SIZE_EXPAND_FILL

	## Toolbar
	var bar: HBoxContainer = HBoxContainer.new()
	bar.add_theme_constant_override("separation", 6)
	var lbl: Label = Label.new()
	lbl.text = "🔎 過濾:"
	bar.add_child(lbl)
	_live_filter = LineEdit.new()
	_live_filter.placeholder_text = "空白顯示全部;輸入例:chat 或 stt 或 mood"
	_live_filter.custom_minimum_size = Vector2(280, 0)
	_live_filter.text_changed.connect(func(_t: String) -> void: _rebuild_live_tree())
	bar.add_child(_live_filter)
	_live_paused = CheckBox.new()
	_live_paused.text = "暫停"
	bar.add_child(_live_paused)
	_live_auto_scroll = CheckBox.new()
	_live_auto_scroll.text = "自動捲底"
	_live_auto_scroll.button_pressed = true
	bar.add_child(_live_auto_scroll)
	var clear_btn: Button = Button.new()
	clear_btn.text = "🗑 清空"
	clear_btn.pressed.connect(_clear_live)
	bar.add_child(clear_btn)
	var spacer: Control = Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)
	_live_count_label = Label.new()
	_live_count_label.text = "0 事件"
	_live_count_label.modulate = Color(0.7, 0.7, 0.7)
	bar.add_child(_live_count_label)
	v.add_child(bar)

	## Stats bar:即時 API 呼叫次數與 token 估算
	_stats_label = Label.new()
	_stats_label.text = "📊 尚無 API 呼叫"
	_stats_label.add_theme_font_size_override("font_size", 12)
	_stats_label.modulate = Color(0.85, 0.9, 1.0)
	_stats_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(_stats_label)

	## Splitter: 上事件列表 / 下 detail
	var split: VSplitContainer = VSplitContainer.new()
	split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.split_offset = 400

	_live_tree = Tree.new()
	_live_tree.columns = 3
	_live_tree.column_titles_visible = true
	_live_tree.set_column_title(0, "時間")
	_live_tree.set_column_title(1, "類型")
	_live_tree.set_column_title(2, "摘要")
	_live_tree.set_column_expand(0, false)
	_live_tree.set_column_expand(1, false)
	_live_tree.set_column_expand(2, true)
	_live_tree.set_column_custom_minimum_width(0, 100)
	_live_tree.set_column_custom_minimum_width(1, 190)
	_live_tree.hide_root = true
	_live_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_live_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_live_tree.item_selected.connect(_on_live_selected)
	split.add_child(_live_tree)

	var detail_wrap: MarginContainer = _pad_margin()
	_live_detail = _make_readonly_text()
	_live_detail.placeholder_text = "點選上方一筆事件看完整 JSON"
	detail_wrap.add_child(_live_detail)
	split.add_child(detail_wrap)

	v.add_child(split)
	_tabs.add_child(v)
	_tabs.set_tab_title(_tabs.get_tab_count() - 1, "📡 Live Log")

func _clear_live() -> void:
	_events.clear()
	_live_tree.clear()
	_live_detail.text = ""
	_live_count_label.text = "0 事件"

func _open_current_log() -> void:
	## 每次呼叫都重算今天的 log 檔;跨日仍然自動接下去
	var today: String = Time.get_date_string_from_system()
	var path: String = "%s/%s.jsonl" % ["user://logs", today]
	if path != _log_path:
		_log_path = path
		_log_offset = 0
		## 換檔:載入歷史(最後 200 筆)
		_load_backlog(200)

func _load_backlog(max_n: int) -> void:
	if not FileAccess.file_exists(_log_path):
		return
	var f: FileAccess = FileAccess.open(_log_path, FileAccess.READ)
	if f == null:
		return
	var lines: PackedStringArray = []
	while not f.eof_reached():
		var line: String = f.get_line()
		if line.strip_edges() != "":
			lines.append(line)
	_log_offset = int(f.get_length())
	f.close()
	var start: int = maxi(0, lines.size() - max_n)
	for i in range(start, lines.size()):
		var d: Variant = JSON.parse_string(lines[i])
		if typeof(d) == TYPE_DICTIONARY:
			_append_event(d as Dictionary, false)
	_rebuild_live_tree()

func _poll_live_log() -> void:
	if _live_paused != null and _live_paused.button_pressed:
		return
	_open_current_log()
	if not FileAccess.file_exists(_log_path):
		return
	var f: FileAccess = FileAccess.open(_log_path, FileAccess.READ)
	if f == null:
		return
	var size: int = int(f.get_length())
	if size <= _log_offset:
		f.close()
		return
	f.seek(_log_offset)
	var appended: int = 0
	while not f.eof_reached():
		var line: String = f.get_line()
		if line.strip_edges() == "":
			continue
		var d: Variant = JSON.parse_string(line)
		if typeof(d) == TYPE_DICTIONARY:
			_append_event(d as Dictionary, true)
			appended += 1
	_log_offset = size
	f.close()
	if appended > 0:
		_rebuild_live_tree()

func _append_event(d: Dictionary, _live: bool) -> void:
	_events.append(d)
	if _events.size() > MAX_EVENTS:
		_events = _events.slice(_events.size() - MAX_EVENTS)

func _rebuild_live_tree() -> void:
	var filt: String = _live_filter.text.strip_edges().to_lower() if _live_filter != null else ""
	_live_tree.clear()
	var root: TreeItem = _live_tree.create_item()
	var shown: int = 0
	var total: int = _events.size()
	for e in _events:
		if filt != "":
			var typ: String = String(e.get("type", "")).to_lower()
			var summary: String = _summarize(e).to_lower()
			if not typ.contains(filt) and not summary.contains(filt):
				continue
		var it: TreeItem = _live_tree.create_item(root)
		it.set_text(0, _short_ts(String(e.get("ts", ""))))
		var typ2: String = String(e.get("type", "?"))
		it.set_text(1, typ2)
		if TYPE_COLORS.has(typ2):
			it.set_custom_color(1, TYPE_COLORS[typ2])
		it.set_text(2, _summarize(e))
		it.set_metadata(0, e)
		shown += 1
	_live_count_label.text = "%d / %d 事件" % [shown, total]
	_update_stats_bar()
	if _live_auto_scroll != null and _live_auto_scroll.button_pressed and shown > 0:
		var last: TreeItem = root.get_child(root.get_child_count() - 1)
		if last != null:
			_live_tree.scroll_to_item(last)

## 掃 _events 累計各 API 呼叫次數與 token/字元估算
func _update_stats_bar() -> void:
	var llm_calls: int = 0
	var llm_stream_calls: int = 0
	var llm_in_chars: int = 0
	var llm_out_chars: int = 0
	var tool_calls: int = 0
	var summarize_calls: int = 0
	var distill_calls: int = 0
	var tts_chars: int = 0
	var tts_calls: int = 0
	var stt_utter: int = 0
	var echo_dropped: int = 0
	var barge_in: int = 0
	## STT session 秒數估算:配對 up=true / up=false
	var session_up_ts: int = 0
	var session_total_sec: int = 0
	for e in _events:
		var t: String = String(e.get("type", ""))
		match t:
			"chat_request":
				llm_calls += 1
			"chat_prompt":
				llm_in_chars += String(e.get("system_prompt", "")).length()
			"chat_response":
				llm_out_chars += String(e.get("text", "")).length()
				if bool(e.get("stream", false)):
					llm_stream_calls += 1
			"tool_call":
				tool_calls += 1
			"history_summarized":
				summarize_calls += 1
			"memory_distilled", "memory_consolidated":
				distill_calls += 1
			"tts_bp_start", "tts_vb_start", "tts_bl_start":
				tts_calls += 1
			"stt_response":
				stt_utter += 1
			"stt_echo_dropped":
				echo_dropped += 1
			"barge_in_utter", "barge_in":
				barge_in += 1
			"stt_session":
				var up: bool = bool(e.get("up", false))
				var ts: int = _parse_ts_to_epoch(String(e.get("ts", "")))
				if up:
					session_up_ts = ts
				elif session_up_ts > 0 and ts > session_up_ts:
					session_total_sec += ts - session_up_ts
					session_up_ts = 0
	## 若 session 還 up 中,加上「到現在」的秒數
	if session_up_ts > 0:
		var now_ep: int = int(Time.get_unix_time_from_system())
		if now_ep > session_up_ts:
			session_total_sec += now_ep - session_up_ts

	## TTS 字元 = 所有 chat_response 的 text 長度(TTS 幾乎必然講整段)
	tts_chars = llm_out_chars

	## Tokens 估算:中文約 3 字元/token(粗估;英文 4 字元/token)
	var in_tok: int = int(round(float(llm_in_chars) / 3.0))
	var out_tok: int = int(round(float(llm_out_chars) / 3.0))

	var line1: String = "📊 LLM %d 次(串流 %d)  ·  in ≈ %s tok  ·  out ≈ %s tok  ·  tools %d" % [
		llm_calls, llm_stream_calls, _fmt_num(in_tok), _fmt_num(out_tok), tool_calls]
	var line2: String = "🎙 STT utter %d · echo 攔 %d · barge %d · session ≈ %s   |  🔊 TTS %d 次 ≈ %s 字" % [
		stt_utter, echo_dropped, barge_in, _fmt_duration(session_total_sec),
		tts_calls, _fmt_num(tts_chars)]
	var line3: String = "🧠 蒸餾 %d · 摘要 %d" % [distill_calls, summarize_calls]
	_stats_label.text = line1 + "\n" + line2 + "\n" + line3

func _parse_ts_to_epoch(ts: String) -> int:
	## ts 格式 "YYYY-MM-DDTHH:MM:SS"
	if ts.length() < 19:
		return 0
	var d: Dictionary = {
		"year": int(ts.substr(0, 4)), "month": int(ts.substr(5, 2)),
		"day": int(ts.substr(8, 2)), "hour": int(ts.substr(11, 2)),
		"minute": int(ts.substr(14, 2)), "second": int(ts.substr(17, 2)),
	}
	return int(Time.get_unix_time_from_datetime_dict(d))

func _fmt_num(n: int) -> String:
	if n >= 1_000_000:
		return "%.2fM" % (float(n) / 1_000_000.0)
	if n >= 1000:
		return "%.1fk" % (float(n) / 1000.0)
	return str(n)

func _fmt_duration(sec: int) -> String:
	if sec < 60:
		return "%ds" % sec
	if sec < 3600:
		return "%dm%02ds" % [sec / 60, sec % 60]
	return "%dh%02dm" % [sec / 3600, (sec % 3600) / 60]

func _on_live_selected() -> void:
	var sel: TreeItem = _live_tree.get_selected()
	if sel == null:
		return
	var e: Dictionary = sel.get_metadata(0) as Dictionary
	if e == null:
		return
	_live_detail.text = JSON.stringify(e, "  ")

func _short_ts(ts: String) -> String:
	## ts 格式 "YYYY-MM-DDTHH:MM:SS" — 只顯示時分秒
	if ts.length() >= 19:
		return ts.substr(11, 8)
	return ts

## 生成事件一行摘要(顯示在 Tree 第三欄)
func _summarize(e: Dictionary) -> String:
	var t: String = String(e.get("type", ""))
	match t:
		"chat_request":
			return "「%s」 model=%s%s meta=%s" % [
				String(e.get("text", "")).substr(0, 80),
				String(e.get("model", "")),
				"  📸" if bool(e.get("has_image", false)) else "",
				String(e.get("meta", ""))]
		"chat_prompt":
			return "system_prompt %d 字 · messages=%d" % [
				String(e.get("system_prompt", "")).length(),
				int(e.get("messages_count", 0))]
		"chat_response":
			return "「%s」 emo=%d  %dms" % [
				String(e.get("text", "")).substr(0, 80),
				int(e.get("emotion", 0)),
				int(e.get("latency_ms", 0))]
		"chat_error":
			return "❌ %s  %dms" % [String(e.get("reason", "")).substr(0, 100),
				int(e.get("latency_ms", 0))]
		"tool_call":
			return "🔧 %s(%s) → %s" % [
				String(e.get("name", "")),
				JSON.stringify(e.get("args", {})),
				String(e.get("result", "")).substr(0, 60)]
		"mood_apply":
			return "emo=%d → v=%+.2f a=%.2f" % [int(e.get("emo", 0)),
				float(e.get("v", 0.0)), float(e.get("a", 0.0))]
		"memory_ops":
			return "add=%d update=%d delete=%d followup=%d" % [
				int(e.get("add", 0)), int(e.get("update", 0)),
				int(e.get("delete", 0)), int(e.get("followup", 0))]
		"memory_distilled":
			return "帳本現有 %d 條" % int(e.get("facts", 0))
		"memory_consolidated":
			return "整理後帳本 %d 條" % int(e.get("facts", 0))
		"memory_distill_error":
			return "❌ %s" % String(e.get("reason", ""))
		"followup_pop":
			return "#%d due=%s 「%s」" % [int(e.get("id", 0)),
				String(e.get("due", "")), String(e.get("text", ""))]
		"proactive_followup":
			return "撿到 followup #%d 「%s」" % [int(e.get("id", 0)),
				String(e.get("text", ""))]
		"startup_greeting":
			return "闊別 %.1f 小時 → 主動打招呼" % float(e.get("hours_away", 0.0))
		"idle_voice_play":
			return "🔊 %s 「%s」" % [String(e.get("wav", "")),
				String(e.get("text", ""))]
		"stt_request":
			return "engine=%s  %.2fs audio" % [String(e.get("engine", "")),
				float(e.get("audio_sec", 0.0))]
		"stt_response":
			return "「%s」 %s %dms" % [String(e.get("text", "")).substr(0, 80),
				String(e.get("engine", "")), int(e.get("latency_ms", 0))]
		"stt_error":
			return "❌ %s / %s" % [String(e.get("engine", "")),
				String(e.get("reason", ""))]
		"stt_echo_dropped":
			return "自己回音丟棄:「%s」" % String(e.get("text", ""))
		"stt_session":
			return "session up=%s" % str(e.get("up", ""))
		"barge_in":
			return "被主人插話 gate=%.3f rms=%.3f" % [float(e.get("gate", 0.0)),
				float(e.get("rms", 0.0))]
		"screenshot_captured":
			return "%d bytes → %s" % [int(e.get("bytes", 0)),
				String(e.get("path", "")).get_file()]
		"screenshot_retry":
			return "重試 rc=%d" % int(e.get("rc", 0))
		"screenshot_error":
			return "❌ rc=%d" % int(e.get("rc", 0))
		"screen_promise_retry":
			return "空頭支票攔截:「%s」" % String(e.get("reply", ""))
		"user_abort":
			return "ESC 中止"
		"chat_abort":
			return "chat 中止"
		_:
			## fallback:把非 ts/type 欄位擠成一行
			var parts: PackedStringArray = []
			for k in e.keys():
				if k == "ts" or k == "type":
					continue
				var v: String = JSON.stringify(e[k])
				if v.length() > 60:
					v = v.substr(0, 57) + "..."
				parts.append("%s=%s" % [k, v])
			return " · ".join(parts)

## ---------- Snapshot tab ----------
func _build_snapshot_tab() -> void:
	_snap_tabs = TabContainer.new()
	_snap_tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_snap_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_snap_prompt = _make_readonly_text()
	_snap_messages = _make_readonly_text()
	_snap_reply = _make_readonly_text()
	var m1: MarginContainer = _pad_margin(); m1.add_child(_snap_prompt)
	var m2: MarginContainer = _pad_margin(); m2.add_child(_snap_messages)
	var m3: MarginContainer = _pad_margin(); m3.add_child(_snap_reply)
	_snap_tabs.add_child(m1)
	_snap_tabs.add_child(m2)
	_snap_tabs.add_child(m3)
	_snap_tabs.set_tab_title(0, "System Prompt")
	_snap_tabs.set_tab_title(1, "Messages")
	_snap_tabs.set_tab_title(2, "Reply")

	var wrap: VBoxContainer = VBoxContainer.new()
	var bar: HBoxContainer = HBoxContainer.new()
	var refresh: Button = Button.new()
	refresh.text = "🔄 從最新一次 send 重取"
	refresh.pressed.connect(_refresh_snapshot)
	bar.add_child(refresh)
	var lbl: Label = Label.new()
	lbl.text = "  只顯示最近一次呼叫;完整歷史看 Live Log 分頁"
	lbl.modulate = Color(0.7, 0.7, 0.7)
	bar.add_child(lbl)
	wrap.add_child(bar)
	wrap.add_child(_snap_tabs)
	wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_snap_tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_snap_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.add_child(wrap)
	_tabs.set_tab_title(_tabs.get_tab_count() - 1, "📸 Snapshot")

func _refresh_snapshot() -> void:
	if _chat == null:
		_snap_prompt.text = "(尚未注入 chat client)"
		return
	var snap: Dictionary = _chat.call("get_debug_snapshot")
	_snap_prompt.text = String(snap.get("system_prompt", "(尚未有請求)"))
	_snap_messages.text = _render_messages(snap.get("messages", []))
	_snap_reply.text = _render_reply(snap)

func _render_messages(messages: Array) -> String:
	if messages.is_empty():
		return "(尚未有請求)"
	var out: String = "共 %d 條訊息(第 1 條 system 已在 System Prompt 分頁)\n\n" % messages.size()
	for i in messages.size():
		var m: Variant = messages[i]
		if typeof(m) != TYPE_DICTIONARY:
			continue
		var role: String = String((m as Dictionary).get("role", "?"))
		out += "─ [%d] role=%s\n" % [i, role]
		var c: Variant = (m as Dictionary).get("content", "")
		if typeof(c) == TYPE_STRING:
			out += _indent(String(c), "  ") + "\n"
		elif typeof(c) == TYPE_ARRAY:
			for part in c:
				if typeof(part) == TYPE_DICTIONARY:
					var pt: String = String(part.get("type", ""))
					if pt == "text":
						out += _indent(String(part.get("text", "")), "  ") + "\n"
					elif pt == "image_url":
						var url: String = String(part.get("image_url", {}).get("url", ""))
						out += "  [image_url: base64 略,%d 字元]\n" % url.length()
					else:
						out += "  [%s]\n" % pt
		if (m as Dictionary).has("tool_calls"):
			out += "  🔧 tool_calls: " + JSON.stringify(m["tool_calls"]) + "\n"
		if (m as Dictionary).has("tool_call_id"):
			out += "  ↳ tool_call_id: %s\n" % String(m["tool_call_id"])
		out += "\n"
	return out

func _render_reply(snap: Dictionary) -> String:
	var out: String = ""
	out += "─── 最新 raw content ─────────────────\n"
	out += String(snap.get("last_reply_raw", "(尚無)")) + "\n\n"
	out += "─── 解析結果 ────────────────────────\n"
	out += "emotion: %d\n" % int(snap.get("last_reply_emotion", 0))
	out += "text   : %s\n\n" % String(snap.get("last_reply_text", ""))
	out += "─── Meta ────────────────────────────\n"
	out += "model      : %s\n" % String(snap.get("model", ""))
	out += "latency_ms : %d\n" % int(snap.get("last_latency_ms", 0))
	out += "history    : %d 條\n" % int(snap.get("history_size", 0))
	out += "request meta: %s\n" % String(snap.get("last_meta", ""))
	return out

## ---------- helpers ----------
func _pad_margin() -> MarginContainer:
	var m: MarginContainer = MarginContainer.new()
	m.add_theme_constant_override("margin_left", 6)
	m.add_theme_constant_override("margin_right", 6)
	m.add_theme_constant_override("margin_top", 6)
	m.add_theme_constant_override("margin_bottom", 6)
	m.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	m.size_flags_vertical = Control.SIZE_EXPAND_FILL
	return m

func _make_readonly_text() -> TextEdit:
	var v: TextEdit = TextEdit.new()
	v.editable = false
	v.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_theme_font_size_override("font_size", 13)
	return v

func _indent(text: String, pad: String) -> String:
	var out: String = ""
	for line in text.split("\n"):
		out += pad + String(line) + "\n"
	return out.trim_suffix("\n")

## ---------- 對外開關 ----------
func open_debug() -> void:
	popup_centered()
	_refresh_brain()
	_refresh_snapshot()
	_open_current_log()
	_brain_timer.start()
	_live_timer.start()

func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and not visible:
		if _brain_timer != null: _brain_timer.stop()
		if _live_timer != null:  _live_timer.stop()
