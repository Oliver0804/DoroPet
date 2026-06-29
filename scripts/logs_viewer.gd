extends Window
## DoroPet 請求記錄檢視器
## 左邊列每天的 log 檔，右邊顯示該天事件

const DoroLogger := preload("res://scripts/logger.gd")

var _file_list: ItemList
var _entries: RichTextLabel
var _filter: OptionButton
var _open_dir_btn: Button
var _refresh_btn: Button
var _current_file: String = ""

func _init() -> void:
	title = "Doro 請求記錄"
	size = Vector2i(880, 560)
	min_size = Vector2i(620, 380)
	transparent = false
	close_requested.connect(hide)

func _ready() -> void:
	var root: MarginContainer = MarginContainer.new()
	root.anchor_right = 1.0
	root.anchor_bottom = 1.0
	root.add_theme_constant_override("margin_left", 14)
	root.add_theme_constant_override("margin_right", 14)
	root.add_theme_constant_override("margin_top", 12)
	root.add_theme_constant_override("margin_bottom", 12)
	add_child(root)

	var v: VBoxContainer = VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	root.add_child(v)

	## 工具列
	var tool: HBoxContainer = HBoxContainer.new()
	tool.add_theme_constant_override("separation", 8)
	var fcap: Label = Label.new()
	fcap.text = "篩選"
	tool.add_child(fcap)
	_filter = OptionButton.new()
	_filter.add_item("全部")
	_filter.add_item("LLM (chat_*)")
	_filter.add_item("STT (stt_*)")
	_filter.add_item("錯誤 (*_error)")
	_filter.item_selected.connect(func(_i: int) -> void: _refresh_entries())
	tool.add_child(_filter)
	_refresh_btn = Button.new()
	_refresh_btn.text = "🔄 重整"
	_refresh_btn.pressed.connect(_refresh_files)
	tool.add_child(_refresh_btn)
	_open_dir_btn = Button.new()
	_open_dir_btn.text = "📂 開啟資料夾"
	_open_dir_btn.pressed.connect(func() -> void: OS.shell_open(DoroLogger.get_log_dir_abs()))
	tool.add_child(_open_dir_btn)
	var export_btn: Button = Button.new()
	export_btn.text = "📝 匯出 .md"
	export_btn.pressed.connect(_export_md)
	tool.add_child(export_btn)
	v.add_child(tool)

	## 左右分割
	var split: HSplitContainer = HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.split_offset = 200
	v.add_child(split)

	_file_list = ItemList.new()
	_file_list.custom_minimum_size = Vector2(180, 0)
	_file_list.item_selected.connect(_on_file_selected)
	split.add_child(_file_list)

	_entries = RichTextLabel.new()
	_entries.bbcode_enabled = true
	_entries.scroll_following = false
	_entries.selection_enabled = true
	_entries.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(_entries)

func open() -> void:
	popup_centered()
	_refresh_files()

func _refresh_files() -> void:
	_file_list.clear()
	var files: Array[String] = DoroLogger.list_log_files()
	for p in files:
		_file_list.add_item(p.get_file().trim_suffix(".jsonl"))
		_file_list.set_item_metadata(_file_list.item_count - 1, p)
	if files.is_empty():
		_entries.text = "[i](尚無記錄)[/i]"
		return
	_file_list.select(0)
	_on_file_selected(0)

func _on_file_selected(idx: int) -> void:
	_current_file = _file_list.get_item_metadata(idx)
	_refresh_entries()

func _refresh_entries() -> void:
	if _current_file == "":
		_entries.text = ""
		return
	var rows: Array = DoroLogger.read_log(_current_file, 500)
	var filter_idx: int = _filter.selected
	var lines: PackedStringArray = []
	for r in rows:
		var t: String = r.get("type", "")
		if filter_idx == 1 and not t.begins_with("chat_"): continue
		if filter_idx == 2 and not t.begins_with("stt_"): continue
		if filter_idx == 3 and not t.ends_with("_error"): continue
		lines.append(_format_entry(r))
	if lines.is_empty():
		_entries.text = "[i](沒有符合的記錄)[/i]"
	else:
		_entries.text = "\n".join(lines)

func _export_md() -> void:
	if _current_file == "":
		return
	var rows: Array = DoroLogger.read_log(_current_file, 9999)
	rows.reverse()  ## 由舊到新更易讀
	var date_str: String = _current_file.get_file().trim_suffix(".jsonl")
	var lines: PackedStringArray = []
	lines.append("# Doro 對話記錄 — %s" % date_str)
	lines.append("")
	for r in rows:
		var t: String = r.get("type", "")
		var ts: String = r.get("ts", "")
		match t:
			"chat_request":
				var img: bool = r.get("has_image", false)
				lines.append("### 🙋 [%s] 我問:%s" % [ts, ("📸 " if img else "")])
				lines.append("> %s" % String(r.get("text", "")))
				lines.append("")
			"chat_response":
				var emo: int = int(r.get("emotion", 0))
				var emo_str: String = (" — 情緒 %d" % emo) if emo > 0 else ""
				var ms: int = int(r.get("latency_ms", 0))
				lines.append("### 🐱 Doro 回覆%s _(%dms)_" % [emo_str, ms])
				lines.append("> %s" % String(r.get("text", "")))
				lines.append("")
			"chat_error":
				lines.append("> ❌ 錯誤:%s" % r.get("reason", ""))
				lines.append("")
			"stt_request":
				var s: float = float(r.get("audio_sec", 0.0))
				lines.append("- 🎙 STT 開始(引擎 %s,%.1fs 音訊)" % [r.get("engine", "?"), s])
			"stt_response":
				lines.append("  - 辨識:「%s」" % r.get("text", ""))
			"stt_error":
				lines.append("  - 辨識失敗:%s" % r.get("reason", ""))
	var path: String = "%s/conversation-%s.md" % [DoroLogger.get_log_dir_abs(), date_str]
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_entries.text = "[color=red]無法寫入 %s[/color]" % path
		return
	f.store_string("\n".join(lines))
	f.close()
	_entries.text = "[color=#3aa05a]✅ 匯出至:[/color]\n%s" % path
	OS.shell_open(DoroLogger.get_log_dir_abs())

func _format_entry(e: Dictionary) -> String:
	var ts: String = e.get("ts", "")
	var typ: String = e.get("type", "")
	var color: String = "#888888"
	if typ.begins_with("chat_response") or typ.begins_with("stt_response"):
		color = "#3aa05a"
	elif typ.ends_with("_error"):
		color = "#d04848"
	elif typ.ends_with("_request"):
		color = "#3a7ed8"
	var head: String = "[color=%s][b]%s[/b][/color]  [color=#888]%s[/color]" % [color, typ, ts]
	var body_parts: PackedStringArray = []
	for k in e.keys():
		if k == "ts" or k == "type": continue
		var val: Variant = e[k]
		var s: String = JSON.stringify(val) if typeof(val) != TYPE_STRING else String(val)
		if s.length() > 300:
			s = s.substr(0, 300) + "…"
		body_parts.append("  %s: %s" % [k, s])
	return head + "\n" + "\n".join(body_parts) + "\n"
