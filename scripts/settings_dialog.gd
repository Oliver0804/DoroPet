extends Window
## DoroPet 設定視窗。所有欄位即時生效，按關閉自動寫 config。

signal settings_changed(data: Dictionary)
signal logs_requested

## 由 pet.gd 在 open() 時帶入當前值
var _initial: Dictionary = {}

var _scale_slider: HSlider
var _scale_label: Label
var _head_slider: HSlider
var _eye_slider: HSlider
var _bubble_spin: SpinBox
var _ontop_check: CheckBox
var _gaze_check: CheckBox
var _api_key: LineEdit
var _model_edit: LineEdit
var _persona_edit: TextEdit
var _model_status: Label

## 語音
var _voice_engine: OptionButton
var _voice_api_key: LineEdit
var _voice_endpoint: LineEdit
var _voice_model: LineEdit
var _voice_local_bin: LineEdit
var _voice_local_model: LineEdit
var _tts_voice: OptionButton
var _tts_enabled: CheckBox
var _voice_status: Label
var _voice_node: Node                    ## 直接拿到 VoiceClient 來查裝置 / 測試
var _mic_device: OptionButton
var _mic_test_btn: Button
var _mic_test_bar: ProgressBar

func _init() -> void:
	title = "Doro 設定"
	size = Vector2i(560, 680)
	min_size = Vector2i(460, 360)
	transient = false
	exclusive = false
	## 預設子視窗不透明、有邊框，跟主視窗對比
	transparent = false
	close_requested.connect(_on_close)

func _ready() -> void:
	_build_ui()

func open(initial: Dictionary, chat_status: String, voice_status: String = "") -> void:
	_initial = initial.duplicate()
	_scale_slider.value = initial.get("scale", 0.25)
	_head_slider.value = initial.get("head", 30.0)
	_eye_slider.value = initial.get("eye", 1.0)
	_bubble_spin.value = initial.get("bubble_seconds", 8.0)
	_ontop_check.button_pressed = initial.get("always_on_top", true)
	_gaze_check.button_pressed = initial.get("gaze_follow", true)
	_api_key.text = initial.get("api_key", "")
	_model_edit.text = initial.get("model", "bytedance-seed/seed-1.6-flash")
	_persona_edit.text = initial.get("persona", "")
	_model_status.text = "OpenRouter: " + chat_status
	_voice_api_key.text = initial.get("voice_api_key", "")
	_voice_endpoint.text = initial.get("voice_endpoint", "")
	_voice_model.text = initial.get("voice_model", "whisper-1")
	_voice_local_bin.text = initial.get("voice_local_bin", "")
	_voice_local_model.text = initial.get("voice_local_model", "")
	var eng: String = initial.get("voice_engine", "local")
	_voice_engine.select(0 if eng == "local" else 1)
	_tts_enabled.button_pressed = initial.get("tts_enabled", true)
	var v: String = initial.get("tts_voice", "Mei-Jia")
	for i in _tts_voice.item_count:
		if _tts_voice.get_item_text(i) == v:
			_tts_voice.select(i)
			break
	_voice_status.text = "Whisper: " + voice_status
	_update_scale_label(_scale_slider.value)
	popup_centered()

func _build_ui() -> void:
	var root: MarginContainer = MarginContainer.new()
	root.add_theme_constant_override("margin_left", 18)
	root.add_theme_constant_override("margin_right", 18)
	root.add_theme_constant_override("margin_top", 14)
	root.add_theme_constant_override("margin_bottom", 14)
	root.anchor_right = 1.0
	root.anchor_bottom = 1.0
	add_child(root)

	## 外層 VBox: [ Scroll(可滾) | 底部按鈕(固定) ]
	var outer: VBoxContainer = VBoxContainer.new()
	outer.add_theme_constant_override("separation", 8)
	root.add_child(outer)

	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	outer.add_child(scroll)

	var vb: VBoxContainer = VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vb)

	vb.add_child(_section("外觀"))

	## 縮放滑桿
	var scale_row: HBoxContainer = HBoxContainer.new()
	var scale_caption: Label = Label.new()
	scale_caption.text = "大小"
	scale_caption.custom_minimum_size = Vector2(80, 0)
	_scale_slider = HSlider.new()
	_scale_slider.min_value = 0.05
	_scale_slider.max_value = 1.0
	_scale_slider.step = 0.01
	_scale_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scale_slider.value_changed.connect(_on_any_changed)
	_scale_slider.value_changed.connect(_update_scale_label)
	_scale_label = Label.new()
	_scale_label.custom_minimum_size = Vector2(50, 0)
	scale_row.add_child(scale_caption)
	scale_row.add_child(_scale_slider)
	scale_row.add_child(_scale_label)
	vb.add_child(scale_row)

	## 視線跟隨強度
	## min 設 1 / 0.05,避免拉到 0 後 Doro 看起來「死掉」
	_head_slider = _slider_row(vb, "視線(頭)", 1.0, 60.0, 1.0)
	_eye_slider = _slider_row(vb, "視線(眼)", 0.05, 2.0, 0.05)

	_gaze_check = CheckBox.new()
	_gaze_check.text = "啟用視線跟滑鼠"
	_gaze_check.toggled.connect(_on_any_toggled)
	vb.add_child(_gaze_check)

	_ontop_check = CheckBox.new()
	_ontop_check.text = "永遠置頂"
	_ontop_check.toggled.connect(_on_any_toggled)
	vb.add_child(_ontop_check)

	## 對話氣泡停留
	var bubble_row: HBoxContainer = HBoxContainer.new()
	var bubble_cap: Label = Label.new()
	bubble_cap.text = "氣泡停留"
	bubble_cap.custom_minimum_size = Vector2(80, 0)
	_bubble_spin = SpinBox.new()
	_bubble_spin.min_value = 2
	_bubble_spin.max_value = 60
	_bubble_spin.step = 1
	_bubble_spin.suffix = " 秒"
	_bubble_spin.value_changed.connect(_on_any_changed)
	bubble_row.add_child(bubble_cap)
	bubble_row.add_child(_bubble_spin)
	vb.add_child(bubble_row)

	vb.add_child(_separator())
	vb.add_child(_section("對話（OpenRouter）"))

	_model_status = Label.new()
	_model_status.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	vb.add_child(_model_status)

	var key_row: HBoxContainer = HBoxContainer.new()
	var key_cap: Label = Label.new()
	key_cap.text = "API Key"
	key_cap.custom_minimum_size = Vector2(80, 0)
	_api_key = LineEdit.new()
	_api_key.secret = true
	_api_key.placeholder_text = "sk-or-v1-..."
	_api_key.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_api_key.text_changed.connect(_on_text_changed)
	key_row.add_child(key_cap)
	key_row.add_child(_api_key)
	vb.add_child(key_row)

	var model_row: HBoxContainer = HBoxContainer.new()
	var model_cap: Label = Label.new()
	model_cap.text = "Model"
	model_cap.custom_minimum_size = Vector2(80, 0)
	_model_edit = LineEdit.new()
	_model_edit.placeholder_text = "bytedance-seed/seed-1.6-flash"
	_model_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_model_edit.text_changed.connect(_on_text_changed)
	model_row.add_child(model_cap)
	model_row.add_child(_model_edit)
	vb.add_child(model_row)

	var persona_label: Label = Label.new()
	persona_label.text = "人設 prompt"
	vb.add_child(persona_label)

	_persona_edit = TextEdit.new()
	_persona_edit.custom_minimum_size = Vector2(0, 110)
	_persona_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_persona_edit.text_changed.connect(_on_persona_changed)
	vb.add_child(_persona_edit)

	## ---------- 語音 ----------
	vb.add_child(_separator())
	vb.add_child(_section("語音（Whisper STT + macOS say TTS）"))

	_voice_status = Label.new()
	_voice_status.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	vb.add_child(_voice_status)

	## --- 麥克風裝置 + 測試 ---
	var dev_row: HBoxContainer = HBoxContainer.new()
	var dev_cap: Label = Label.new()
	dev_cap.text = "輸入裝置"
	dev_cap.custom_minimum_size = Vector2(90, 0)
	_mic_device = OptionButton.new()
	_mic_device.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mic_device.item_selected.connect(_on_device_selected)
	dev_row.add_child(dev_cap)
	dev_row.add_child(_mic_device)
	vb.add_child(dev_row)

	var test_row: HBoxContainer = HBoxContainer.new()
	var test_cap: Label = Label.new()
	test_cap.text = "麥克風測試"
	test_cap.custom_minimum_size = Vector2(90, 0)
	_mic_test_btn = Button.new()
	_mic_test_btn.text = "▶ 開始測試"
	_mic_test_btn.toggle_mode = true
	_mic_test_btn.toggled.connect(_on_mic_test_toggled)
	_mic_test_bar = ProgressBar.new()
	_mic_test_bar.show_percentage = false
	_mic_test_bar.min_value = 0.0
	_mic_test_bar.max_value = 1.0
	_mic_test_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mic_test_bar.custom_minimum_size = Vector2(0, 18)
	test_row.add_child(test_cap)
	test_row.add_child(_mic_test_btn)
	test_row.add_child(_mic_test_bar)
	vb.add_child(test_row)

	var eng_row: HBoxContainer = HBoxContainer.new()
	var eng_cap: Label = Label.new()
	eng_cap.text = "STT 引擎"
	eng_cap.custom_minimum_size = Vector2(90, 0)
	_voice_engine = OptionButton.new()
	_voice_engine.add_item("本地 (whisper.cpp)")
	_voice_engine.add_item("雲端 (OpenAI 兼容)")
	_voice_engine.item_selected.connect(func(_i: int) -> void: _emit())
	eng_row.add_child(eng_cap)
	eng_row.add_child(_voice_engine)
	vb.add_child(eng_row)

	## --- 本地 ---
	var lbin_row: HBoxContainer = HBoxContainer.new()
	var lbin_cap: Label = Label.new()
	lbin_cap.text = "本地 binary"
	lbin_cap.custom_minimum_size = Vector2(90, 0)
	_voice_local_bin = LineEdit.new()
	_voice_local_bin.placeholder_text = "/opt/homebrew/bin/whisper-cli"
	_voice_local_bin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_voice_local_bin.text_changed.connect(_on_text_changed)
	lbin_row.add_child(lbin_cap)
	lbin_row.add_child(_voice_local_bin)
	vb.add_child(lbin_row)

	var lmodel_row: HBoxContainer = HBoxContainer.new()
	var lmodel_cap: Label = Label.new()
	lmodel_cap.text = "本地 model"
	lmodel_cap.custom_minimum_size = Vector2(90, 0)
	_voice_local_model = LineEdit.new()
	_voice_local_model.placeholder_text = "~/.local/share/doropet/whisper-models/ggml-base.bin"
	_voice_local_model.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_voice_local_model.text_changed.connect(_on_text_changed)
	lmodel_row.add_child(lmodel_cap)
	lmodel_row.add_child(_voice_local_model)
	vb.add_child(lmodel_row)

	## --- 雲端 ---
	var vkey_row: HBoxContainer = HBoxContainer.new()
	var vkey_cap: Label = Label.new()
	vkey_cap.text = "雲端 API Key"
	vkey_cap.custom_minimum_size = Vector2(90, 0)
	_voice_api_key = LineEdit.new()
	_voice_api_key.secret = true
	_voice_api_key.placeholder_text = "sk-... (OpenAI 等兼容服務)"
	_voice_api_key.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_voice_api_key.text_changed.connect(_on_text_changed)
	vkey_row.add_child(vkey_cap)
	vkey_row.add_child(_voice_api_key)
	vb.add_child(vkey_row)

	var vep_row: HBoxContainer = HBoxContainer.new()
	var vep_cap: Label = Label.new()
	vep_cap.text = "雲端 Endpoint"
	vep_cap.custom_minimum_size = Vector2(90, 0)
	_voice_endpoint = LineEdit.new()
	_voice_endpoint.placeholder_text = "https://api.openai.com/v1/audio/transcriptions"
	_voice_endpoint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_voice_endpoint.text_changed.connect(_on_text_changed)
	vep_row.add_child(vep_cap)
	vep_row.add_child(_voice_endpoint)
	vb.add_child(vep_row)

	var vmodel_row: HBoxContainer = HBoxContainer.new()
	var vmodel_cap: Label = Label.new()
	vmodel_cap.text = "雲端 model"
	vmodel_cap.custom_minimum_size = Vector2(90, 0)
	_voice_model = LineEdit.new()
	_voice_model.placeholder_text = "whisper-1 / whisper-large-v3-turbo …"
	_voice_model.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_voice_model.text_changed.connect(_on_text_changed)
	vmodel_row.add_child(vmodel_cap)
	vmodel_row.add_child(_voice_model)
	vb.add_child(vmodel_row)

	var voice_row: HBoxContainer = HBoxContainer.new()
	var voice_cap: Label = Label.new()
	voice_cap.text = "TTS 聲音"
	voice_cap.custom_minimum_size = Vector2(80, 0)
	_tts_voice = OptionButton.new()
	## 直接 require VoiceClient.suggested_voices()
	var vc: GDScript = load("res://scripts/voice_client.gd")
	var voices: Array = vc.call("suggested_voices")
	for v in voices:
		_tts_voice.add_item(v)
	_tts_voice.item_selected.connect(func(_i: int) -> void: _emit())
	voice_row.add_child(voice_cap)
	voice_row.add_child(_tts_voice)
	vb.add_child(voice_row)

	_tts_enabled = CheckBox.new()
	_tts_enabled.text = "Doro 用語音回覆（macOS say）"
	_tts_enabled.toggled.connect(_on_any_toggled)
	vb.add_child(_tts_enabled)

	## 底部按鈕在 outer（scroll 外），永遠看得到
	var sep_bot: HSeparator = HSeparator.new()
	outer.add_child(sep_bot)

	var bot: HBoxContainer = HBoxContainer.new()
	bot.alignment = BoxContainer.ALIGNMENT_END
	var logs_btn: Button = Button.new()
	logs_btn.text = "📋 查看記錄"
	logs_btn.pressed.connect(func() -> void: logs_requested.emit())
	var reset_btn: Button = Button.new()
	reset_btn.text = "還原預設值"
	reset_btn.pressed.connect(_reset_defaults)
	var close_btn: Button = Button.new()
	close_btn.text = "儲存並關閉"
	close_btn.pressed.connect(_on_close)
	bot.add_child(logs_btn)
	bot.add_child(reset_btn)
	bot.add_child(close_btn)
	outer.add_child(bot)

func _section(title: String) -> Label:
	var l: Label = Label.new()
	l.text = title
	l.add_theme_font_size_override("font_size", 18)
	return l

func _separator() -> HSeparator:
	return HSeparator.new()

func _slider_row(parent: Container, caption: String, lo: float, hi: float, step: float) -> HSlider:
	var row: HBoxContainer = HBoxContainer.new()
	var cap: Label = Label.new()
	cap.text = caption
	cap.custom_minimum_size = Vector2(80, 0)
	var s: HSlider = HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.value_changed.connect(_on_any_changed)
	var v: Label = Label.new()
	v.custom_minimum_size = Vector2(50, 0)
	s.value_changed.connect(func(val: float) -> void: v.text = "%.2f" % val)
	row.add_child(cap)
	row.add_child(s)
	row.add_child(v)
	parent.add_child(row)
	return s

func _update_scale_label(v: float) -> void:
	_scale_label.text = "%.2f" % v

func _on_any_changed(_v: float) -> void:
	_emit()

func _on_any_toggled(_b: bool) -> void:
	_emit()

func _on_text_changed(_s: String) -> void:
	_emit()

func _on_persona_changed() -> void:
	_emit()

func _emit() -> void:
	settings_changed.emit(_collect())

func _collect() -> Dictionary:
	var tts_v: String = "Mei-Jia"
	if _tts_voice.selected >= 0:
		tts_v = _tts_voice.get_item_text(_tts_voice.selected)
	return {
		"scale": _scale_slider.value,
		"head": _head_slider.value,
		"eye": _eye_slider.value,
		"bubble_seconds": _bubble_spin.value,
		"always_on_top": _ontop_check.button_pressed,
		"gaze_follow": _gaze_check.button_pressed,
		"api_key": _api_key.text,
		"model": _model_edit.text,
		"persona": _persona_edit.text,
		"voice_engine": "local" if _voice_engine.selected == 0 else "api",
		"voice_api_key": _voice_api_key.text,
		"voice_endpoint": _voice_endpoint.text,
		"voice_model": _voice_model.text,
		"voice_local_bin": _voice_local_bin.text,
		"voice_local_model": _voice_local_model.text,
		"tts_voice": tts_v,
		"tts_enabled": _tts_enabled.button_pressed,
	}

func _reset_defaults() -> void:
	_scale_slider.value = 0.25
	_head_slider.value = 30.0
	_eye_slider.value = 1.0
	_bubble_spin.value = 8.0
	_ontop_check.button_pressed = true
	_gaze_check.button_pressed = true
	_model_edit.text = "bytedance-seed/seed-1.6-flash"
	## persona/api_key 不動，避免誤刪

func _on_close() -> void:
	## 關閉前停掉測試
	if _mic_test_btn and _mic_test_btn.button_pressed:
		_mic_test_btn.button_pressed = false
	_emit()
	hide()

## ---------- 麥克風裝置 / 測試 ----------
func set_voice_node(n: Node) -> void:
	_voice_node = n
	_refresh_devices()

func _refresh_devices() -> void:
	if _voice_node == null or _mic_device == null:
		return
	_mic_device.clear()
	var devs: Array = _voice_node.call("list_input_devices")
	var current: String = _voice_node.call("get_input_device")
	var sel: int = 0
	for i in devs.size():
		_mic_device.add_item(devs[i])
		if devs[i] == current:
			sel = i
	if devs.is_empty():
		_mic_device.add_item("(無輸入裝置)")
		_mic_device.disabled = true
	else:
		_mic_device.disabled = false
		_mic_device.select(sel)

func _on_device_selected(idx: int) -> void:
	if _voice_node == null:
		return
	var name: String = _mic_device.get_item_text(idx)
	_voice_node.call("set_input_device", name)

func _on_mic_test_toggled(on: bool) -> void:
	if _voice_node == null:
		return
	if on:
		_voice_node.call("start_test")
		_mic_test_btn.text = "■ 停止測試"
	else:
		_voice_node.call("stop_test")
		_mic_test_btn.text = "▶ 開始測試"
		_mic_test_bar.value = 0.0

func _process(_dt: float) -> void:
	if not visible or _voice_node == null or _mic_test_bar == null:
		return
	if _mic_test_btn != null and _mic_test_btn.button_pressed:
		var rms: float = _voice_node.call("consume_rms")
		_mic_test_bar.value = clamp(rms * 4.0, 0.0, 1.0)
