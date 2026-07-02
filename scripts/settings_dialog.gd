extends Window
## DoroPet 設定視窗。所有欄位即時生效，按關閉自動寫 config。

signal settings_changed(data: Dictionary)
signal logs_requested

## 由 pet.gd 在 open() 時帶入當前值
var _initial: Dictionary = {}

var _model_path_edit: LineEdit
var _model_path_btn: Button
var _msaa_select: OptionButton
var _scale_slider: HSlider
var _scale_label: Label
var _head_slider: HSlider
var _eye_slider: HSlider
var _bubble_spin: SpinBox
var _ontop_check: CheckBox
var _gaze_check: CheckBox
var _api_key: LineEdit
var _model_edit: LineEdit
var _model_preset: OptionButton
var _persona_edit: TextEdit
var _model_status: Label

## OpenRouter 常用 model 預設(依用途分組)
const MODEL_PRESETS: Array = [
	{"label": "—— 自訂 ——", "value": ""},
	{"label": "ByteDance Seed 2.0 mini(預設・支援視覺)", "value": "bytedance-seed/seed-2.0-mini"},
	{"label": "ByteDance Seed 1.6 Flash", "value": "bytedance-seed/seed-1.6-flash"},
	{"label": "Gemini 2.5 Flash(免費・支援視覺)", "value": "google/gemini-2.5-flash-image-preview:free"},
	{"label": "Gemini 2.0 Flash Exp(免費・支援視覺)", "value": "google/gemini-2.0-flash-exp:free"},
	{"label": "DeepSeek Chat v3.1(免費・純文字)", "value": "deepseek/deepseek-chat-v3.1:free"},
	{"label": "Llama 3.3 70B(免費・純文字)", "value": "meta-llama/llama-3.3-70b-instruct:free"},
	{"label": "Qwen 2.5 72B(免費・純文字)", "value": "qwen/qwen-2.5-72b-instruct:free"},
	{"label": "Claude 3.5 Haiku(付費・很穩)", "value": "anthropic/claude-3.5-haiku"},
	{"label": "GPT-4o mini(付費・支援視覺)", "value": "openai/gpt-4o-mini"},
]

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

## TTS 後端（系統內建 / Voicebox）
var _tts_backend_sel: OptionButton
var _vb_endpoint: LineEdit
var _vb_profile: OptionButton
var _vb_model_size: OptionButton
var _vb_status: Label
var _vb_http: HTTPRequest                ## 抓 /profiles 用
var _vb_saved_profile: String = ""       ## 抓不到清單時保留原設定
var _tts_system_rows: Array[Control] = []
var _tts_vb_rows: Array[Control] = []

## 百炼雲端 TTS
var _bl_endpoint: LineEdit
var _bl_api_key: LineEdit
var _bl_model: LineEdit
var _bl_voice: LineEdit
var _tts_bl_rows: Array[Control] = []
var _voice_node: Node                    ## 直接拿到 VoiceClient 來查裝置 / 測試
var _mic_device: OptionButton
var _mic_test_btn: Button
var _mic_test_bar: ProgressBar

## 熱鍵
var _hotkey_btn: Button
var _hotkey_keycode: int = KEY_D
var _hotkey_mods: int = 8           ## ⇧
var _capturing_hotkey: bool = false

## STT 條件顯示用
var _stt_local_rows: Array[Control] = []
var _stt_cloud_rows: Array[Control] = []

## 自動更新
var _auto_update_check: CheckBox

## 視覺 + 主動搭話
var _vision_check: CheckBox
var _proactive_check: CheckBox
var _proactive_min_spin: SpinBox
var _proactive_max_spin: SpinBox
var _proactive_prompt_edit: TextEdit
var _proactive_screenshot_check: CheckBox

## VAD
var _vad_check: CheckBox
var _continuous_voice_check: CheckBox
var _continuous_timeout_spin: SpinBox
var _vad_threshold_slider: HSlider
var _vad_threshold_label: Label
var _vad_silence_spin: SpinBox

func _init() -> void:
	var v: String = String(ProjectSettings.get_setting("application/config/version", "0.0.0"))
	title = "Doro 設定 — v" + v
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
	_model_path_edit.text = initial.get("model_path", "res://assets/doro/Doro.model3.json")
	_scale_slider.value = initial.get("scale", 0.25)
	_head_slider.value = initial.get("head", 30.0)
	_eye_slider.value = initial.get("eye", 1.0)
	_bubble_spin.value = initial.get("bubble_seconds", 8.0)
	_ontop_check.button_pressed = initial.get("always_on_top", true)
	_gaze_check.button_pressed = initial.get("gaze_follow", true)
	_msaa_select.select(clamp(int(initial.get("msaa", 2)), 0, 3))
	_api_key.text = initial.get("api_key", "")
	_model_edit.text = initial.get("model", "bytedance-seed/seed-2.0-mini")
	_sync_model_preset()
	_persona_edit.text = initial.get("persona", "")
	_model_status.text = "OpenRouter: " + chat_status
	_voice_api_key.text = initial.get("voice_api_key", "")
	_voice_endpoint.text = initial.get("voice_endpoint", "")
	_voice_model.text = initial.get("voice_model", "whisper-1")
	_voice_local_bin.text = initial.get("voice_local_bin", "")
	_voice_local_model.text = initial.get("voice_local_model", "")
	var eng: String = initial.get("voice_engine", "local")
	_voice_engine.select(0 if eng == "local" else 1)
	_update_stt_visibility()
	_tts_enabled.button_pressed = initial.get("tts_enabled", true)
	var v: String = initial.get("tts_voice", "Mei-Jia")
	for i in _tts_voice.item_count:
		if _tts_voice.get_item_text(i) == v:
			_tts_voice.select(i)
			break
	var backend: String = String(initial.get("tts_backend", "system"))
	_tts_backend_sel.select(2 if backend == "bailian" else (1 if backend == "voicebox" else 0))
	_bl_endpoint.text = String(initial.get("bl_endpoint", ""))
	_bl_api_key.text = String(initial.get("bl_api_key", ""))
	_bl_model.text = String(initial.get("bl_model", ""))
	_bl_voice.text = String(initial.get("bl_voice", ""))
	_vb_endpoint.text = String(initial.get("vb_endpoint", ""))
	_vb_saved_profile = String(initial.get("vb_profile", ""))
	var msize: String = String(initial.get("vb_model_size", "0.6B"))
	_vb_model_size.select(clampi(VB_MODEL_SIZES.find(msize), 0, VB_MODEL_SIZES.size() - 1))
	_update_tts_visibility()
	if backend == "voicebox":
		_refresh_vb_profiles()
	_voice_status.text = "Whisper: " + voice_status
	_hotkey_keycode = int(initial.get("hotkey_keycode", KEY_SPACE))
	_hotkey_mods = int(initial.get("hotkey_mods", 0))
	_refresh_hotkey_btn()
	_auto_update_check.button_pressed = bool(initial.get("auto_check_updates", true))
	_vision_check.button_pressed = bool(initial.get("vision_enabled", true))
	_proactive_check.button_pressed = bool(initial.get("proactive_chat_enabled", false))
	_proactive_min_spin.value = float(initial.get("proactive_chat_min_sec", 600.0))
	_proactive_max_spin.value = float(initial.get("proactive_chat_max_sec", 1800.0))
	_proactive_prompt_edit.text = String(initial.get("proactive_prompt", ""))
	_proactive_prompt_edit.placeholder_text = String(initial.get("proactive_prompt_default", ""))
	_proactive_screenshot_check.button_pressed = bool(initial.get("proactive_with_screenshot", false))
	_vad_check.button_pressed = bool(initial.get("vad_enabled", true))
	_vad_threshold_slider.value = float(initial.get("vad_threshold", 0.02))
	_vad_silence_spin.value = float(initial.get("vad_silence_sec", 1.2))
	_continuous_voice_check.button_pressed = bool(initial.get("continuous_voice", true))
	_continuous_timeout_spin.value = float(initial.get("continuous_timeout_sec", 15.0))
	_update_vad_threshold_label(_vad_threshold_slider.value)
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

	## Live2D 模型路徑
	var mp_row: HBoxContainer = HBoxContainer.new()
	var mp_cap: Label = Label.new()
	mp_cap.text = "模型"
	mp_cap.custom_minimum_size = Vector2(80, 0)
	_model_path_edit = LineEdit.new()
	_model_path_edit.placeholder_text = "res:// 路徑或絕對路徑 (.model3.json)"
	_model_path_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_model_path_edit.text_changed.connect(_on_text_changed)
	_model_path_btn = Button.new()
	_model_path_btn.text = "📂"
	_model_path_btn.tooltip_text = "選一個 .model3.json"
	_model_path_btn.pressed.connect(_on_model_path_pick)
	mp_row.add_child(mp_cap)
	mp_row.add_child(_model_path_edit)
	mp_row.add_child(_model_path_btn)
	vb.add_child(mp_row)

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

	## MSAA 反鋸齒
	var msaa_row: HBoxContainer = HBoxContainer.new()
	var msaa_cap: Label = Label.new()
	msaa_cap.text = "反鋸齒"
	msaa_cap.custom_minimum_size = Vector2(80, 0)
	_msaa_select = OptionButton.new()
	_msaa_select.add_item("關")          ## 0
	_msaa_select.add_item("2x")          ## 1
	_msaa_select.add_item("4x (建議)")    ## 2
	_msaa_select.add_item("8x")          ## 3
	_msaa_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_msaa_select.item_selected.connect(func(_i: int) -> void: _emit())
	msaa_row.add_child(msaa_cap)
	msaa_row.add_child(_msaa_select)
	vb.add_child(msaa_row)

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

	## 對話熱鍵
	var hk_row: HBoxContainer = HBoxContainer.new()
	var hk_cap: Label = Label.new()
	hk_cap.text = "對話熱鍵"
	hk_cap.custom_minimum_size = Vector2(80, 0)
	_hotkey_btn = Button.new()
	_hotkey_btn.toggle_mode = true
	_hotkey_btn.toggled.connect(_on_hotkey_btn_toggled)
	_hotkey_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var hk_hint: Label = Label.new()
	hk_hint.text = "(點按鈕後按任一鍵組合)"
	hk_hint.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	hk_hint.add_theme_font_size_override("font_size", 12)
	hk_row.add_child(hk_cap)
	hk_row.add_child(_hotkey_btn)
	hk_row.add_child(hk_hint)
	vb.add_child(hk_row)

	## 自動檢查更新(每 10 分鐘 + TTS 通知)
	_auto_update_check = CheckBox.new()
	_auto_update_check.text = "每 10 分鐘檢查更新 + 用語音通知"
	_auto_update_check.toggled.connect(_on_any_toggled)
	vb.add_child(_auto_update_check)

	## VAD 自動分段送出
	_vad_check = CheckBox.new()
	_vad_check.text = "VAD：講完話沉默自動送出"
	_vad_check.toggled.connect(_on_any_toggled)
	vb.add_child(_vad_check)

	var vad_th_row: HBoxContainer = HBoxContainer.new()
	var vad_th_cap: Label = Label.new()
	vad_th_cap.text = "音量門檻"
	vad_th_cap.custom_minimum_size = Vector2(80, 0)
	_vad_threshold_slider = HSlider.new()
	_vad_threshold_slider.min_value = 0.005
	_vad_threshold_slider.max_value = 0.15
	_vad_threshold_slider.step = 0.005
	_vad_threshold_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vad_threshold_slider.value_changed.connect(_on_any_changed)
	_vad_threshold_slider.value_changed.connect(_update_vad_threshold_label)
	_vad_threshold_label = Label.new()
	_vad_threshold_label.custom_minimum_size = Vector2(60, 0)
	vad_th_row.add_child(vad_th_cap)
	vad_th_row.add_child(_vad_threshold_slider)
	vad_th_row.add_child(_vad_threshold_label)
	vb.add_child(vad_th_row)

	var vad_sil_row: HBoxContainer = HBoxContainer.new()
	var vad_sil_cap: Label = Label.new()
	vad_sil_cap.text = "沉默送出"
	vad_sil_cap.custom_minimum_size = Vector2(80, 0)
	_vad_silence_spin = SpinBox.new()
	_vad_silence_spin.min_value = 0.3
	_vad_silence_spin.max_value = 5.0
	_vad_silence_spin.step = 0.1
	_vad_silence_spin.suffix = " 秒"
	_vad_silence_spin.value_changed.connect(_on_any_changed)
	vad_sil_row.add_child(vad_sil_cap)
	vad_sil_row.add_child(_vad_silence_spin)
	vb.add_child(vad_sil_row)

	## 連續對話
	_continuous_voice_check = CheckBox.new()
	_continuous_voice_check.text = "🔁 連續對話:Doro 講完後自動繼續錄音等下一句"
	_continuous_voice_check.toggled.connect(_on_any_toggled)
	vb.add_child(_continuous_voice_check)

	var ct_row: HBoxContainer = HBoxContainer.new()
	var ct_cap: Label = Label.new()
	ct_cap.text = "  超時關閉"
	ct_cap.custom_minimum_size = Vector2(80, 0)
	_continuous_timeout_spin = SpinBox.new()
	_continuous_timeout_spin.min_value = 5
	_continuous_timeout_spin.max_value = 120
	_continuous_timeout_spin.step = 1
	_continuous_timeout_spin.suffix = " 秒"
	_continuous_timeout_spin.value_changed.connect(_on_any_changed)
	ct_row.add_child(ct_cap)
	ct_row.add_child(_continuous_timeout_spin)
	vb.add_child(ct_row)

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

	## Model 預設下拉
	var preset_row: HBoxContainer = HBoxContainer.new()
	var preset_cap: Label = Label.new()
	preset_cap.text = "預設"
	preset_cap.custom_minimum_size = Vector2(80, 0)
	_model_preset = OptionButton.new()
	_model_preset.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for p in MODEL_PRESETS:
		_model_preset.add_item(p.label)
	_model_preset.item_selected.connect(_on_model_preset_selected)
	preset_row.add_child(preset_cap)
	preset_row.add_child(_model_preset)
	vb.add_child(preset_row)

	## 自訂 Model ID
	var model_row: HBoxContainer = HBoxContainer.new()
	var model_cap: Label = Label.new()
	model_cap.text = "Model ID"
	model_cap.custom_minimum_size = Vector2(80, 0)
	_model_edit = LineEdit.new()
	_model_edit.placeholder_text = "bytedance-seed/seed-2.0-mini"
	_model_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_model_edit.text_changed.connect(_on_model_text_changed)
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

	## 視覺輸入(screen 關鍵字截圖)
	_vision_check = CheckBox.new()
	_vision_check.text = "📸 講『螢幕』『你看』等關鍵字時自動附帶截圖"
	_vision_check.toggled.connect(_on_any_toggled)
	vb.add_child(_vision_check)

	## 主動搭話
	_proactive_check = CheckBox.new()
	_proactive_check.text = "💬 Doro 偶爾主動搭話"
	_proactive_check.toggled.connect(_on_any_toggled)
	vb.add_child(_proactive_check)

	var pro_row: HBoxContainer = HBoxContainer.new()
	var pro_cap: Label = Label.new()
	pro_cap.text = "  間隔"
	pro_cap.custom_minimum_size = Vector2(80, 0)
	_proactive_min_spin = SpinBox.new()
	_proactive_min_spin.min_value = 60
	_proactive_min_spin.max_value = 3600
	_proactive_min_spin.step = 30
	_proactive_min_spin.suffix = " 秒"
	_proactive_min_spin.value_changed.connect(_on_any_changed)
	var pro_dash: Label = Label.new()
	pro_dash.text = " ~ "
	_proactive_max_spin = SpinBox.new()
	_proactive_max_spin.min_value = 60
	_proactive_max_spin.max_value = 7200
	_proactive_max_spin.step = 30
	_proactive_max_spin.suffix = " 秒"
	_proactive_max_spin.value_changed.connect(_on_any_changed)
	pro_row.add_child(pro_cap)
	pro_row.add_child(_proactive_min_spin)
	pro_row.add_child(pro_dash)
	pro_row.add_child(_proactive_max_spin)
	vb.add_child(pro_row)

	var pp_label: Label = Label.new()
	pp_label.text = "  搭話 prompt(空 = 預設關懷話題)"
	pp_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	pp_label.add_theme_font_size_override("font_size", 12)
	vb.add_child(pp_label)
	_proactive_prompt_edit = TextEdit.new()
	_proactive_prompt_edit.custom_minimum_size = Vector2(0, 80)
	_proactive_prompt_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_proactive_prompt_edit.text_changed.connect(_emit)
	vb.add_child(_proactive_prompt_edit)

	_proactive_screenshot_check = CheckBox.new()
	_proactive_screenshot_check.text = "  📸 主動搭話時自動附帶當下螢幕(需勾上方視覺)"
	_proactive_screenshot_check.toggled.connect(_on_any_toggled)
	vb.add_child(_proactive_screenshot_check)

	## ---------- 🎙 STT — 語音輸入 ----------
	vb.add_child(_separator())
	vb.add_child(_section("🎙 STT — 語音輸入"))

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
	_voice_engine.add_item("本地 (whisper.cpp,免費離線)")
	_voice_engine.add_item("雲端 API (OpenAI 兼容)")
	_voice_engine.item_selected.connect(_on_voice_engine_changed)
	eng_row.add_child(eng_cap)
	eng_row.add_child(_voice_engine)
	vb.add_child(eng_row)

	## --- 本地配置(選本地時才顯示)---
	var lbin_row: HBoxContainer = HBoxContainer.new()
	var lbin_cap: Label = Label.new()
	lbin_cap.text = "binary 路徑"
	lbin_cap.custom_minimum_size = Vector2(90, 0)
	_voice_local_bin = LineEdit.new()
	_voice_local_bin.placeholder_text = "/opt/homebrew/bin/whisper-cli"
	_voice_local_bin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_voice_local_bin.text_changed.connect(_on_text_changed)
	lbin_row.add_child(lbin_cap)
	lbin_row.add_child(_voice_local_bin)
	vb.add_child(lbin_row)
	_stt_local_rows.append(lbin_row)

	var lmodel_row: HBoxContainer = HBoxContainer.new()
	var lmodel_cap: Label = Label.new()
	lmodel_cap.text = "model 路徑"
	lmodel_cap.custom_minimum_size = Vector2(90, 0)
	_voice_local_model = LineEdit.new()
	_voice_local_model.placeholder_text = "~/.local/share/doropet/whisper-models/ggml-base.bin"
	_voice_local_model.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_voice_local_model.text_changed.connect(_on_text_changed)
	lmodel_row.add_child(lmodel_cap)
	lmodel_row.add_child(_voice_local_model)
	vb.add_child(lmodel_row)
	_stt_local_rows.append(lmodel_row)

	## --- 雲端配置(選雲端時才顯示)---
	var vkey_row: HBoxContainer = HBoxContainer.new()
	var vkey_cap: Label = Label.new()
	vkey_cap.text = "API Key"
	vkey_cap.custom_minimum_size = Vector2(90, 0)
	_voice_api_key = LineEdit.new()
	_voice_api_key.secret = true
	_voice_api_key.placeholder_text = "sk-... (OpenAI / Groq / 自架 server)"
	_voice_api_key.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_voice_api_key.text_changed.connect(_on_text_changed)
	vkey_row.add_child(vkey_cap)
	vkey_row.add_child(_voice_api_key)
	vb.add_child(vkey_row)
	_stt_cloud_rows.append(vkey_row)

	var vep_row: HBoxContainer = HBoxContainer.new()
	var vep_cap: Label = Label.new()
	vep_cap.text = "Endpoint"
	vep_cap.custom_minimum_size = Vector2(90, 0)
	_voice_endpoint = LineEdit.new()
	_voice_endpoint.placeholder_text = "https://api.openai.com/v1/audio/transcriptions"
	_voice_endpoint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_voice_endpoint.text_changed.connect(_on_text_changed)
	vep_row.add_child(vep_cap)
	vep_row.add_child(_voice_endpoint)
	vb.add_child(vep_row)
	_stt_cloud_rows.append(vep_row)

	var vmodel_row: HBoxContainer = HBoxContainer.new()
	var vmodel_cap: Label = Label.new()
	vmodel_cap.text = "model"
	vmodel_cap.custom_minimum_size = Vector2(90, 0)
	_voice_model = LineEdit.new()
	_voice_model.placeholder_text = "whisper-1 / whisper-large-v3-turbo …"
	_voice_model.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_voice_model.text_changed.connect(_on_text_changed)
	vmodel_row.add_child(vmodel_cap)
	vmodel_row.add_child(_voice_model)
	vb.add_child(vmodel_row)
	_stt_cloud_rows.append(vmodel_row)

	## ---------- 🔊 TTS — 語音輸出 ----------
	vb.add_child(_separator())
	vb.add_child(_section("🔊 TTS — 語音輸出"))

	_tts_enabled = CheckBox.new()
	_tts_enabled.text = "Doro 用語音回覆"
	_tts_enabled.toggled.connect(_on_any_toggled)
	vb.add_child(_tts_enabled)

	## TTS 後端選擇
	var be_row: HBoxContainer = HBoxContainer.new()
	var be_cap: Label = Label.new()
	be_cap.text = "TTS 引擎"
	be_cap.custom_minimum_size = Vector2(90, 0)
	_tts_backend_sel = OptionButton.new()
	_tts_backend_sel.add_item("系統內建（快、音色普通）")     ## 0 = system
	_tts_backend_sel.add_item("Voicebox（本機、克隆音色）")   ## 1 = voicebox
	_tts_backend_sel.add_item("百炼雲端（快、克隆音色、要網路）")  ## 2 = bailian
	_tts_backend_sel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tts_backend_sel.item_selected.connect(_on_tts_backend_changed)
	be_row.add_child(be_cap)
	be_row.add_child(_tts_backend_sel)
	vb.add_child(be_row)

	var voice_row: HBoxContainer = HBoxContainer.new()
	var voice_cap: Label = Label.new()
	voice_cap.text = "聲音"
	voice_cap.custom_minimum_size = Vector2(90, 0)
	_tts_voice = OptionButton.new()
	_tts_voice.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var vc: GDScript = load("res://scripts/voice_client.gd")
	var voices: Array = vc.call("suggested_voices")
	for v in voices:
		_tts_voice.add_item(v)
	_tts_voice.item_selected.connect(func(_i: int) -> void: _emit())
	voice_row.add_child(voice_cap)
	voice_row.add_child(_tts_voice)
	vb.add_child(voice_row)
	_tts_system_rows.append(voice_row)

	## --- Voicebox 配置（選 Voicebox 時才顯示）---
	var vbep_row: HBoxContainer = HBoxContainer.new()
	var vbep_cap: Label = Label.new()
	vbep_cap.text = "Endpoint"
	vbep_cap.custom_minimum_size = Vector2(90, 0)
	_vb_endpoint = LineEdit.new()
	_vb_endpoint.placeholder_text = "http://127.0.0.1:17493"
	_vb_endpoint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vb_endpoint.text_changed.connect(_on_text_changed)
	vbep_row.add_child(vbep_cap)
	vbep_row.add_child(_vb_endpoint)
	vb.add_child(vbep_row)
	_tts_vb_rows.append(vbep_row)

	var vbp_row: HBoxContainer = HBoxContainer.new()
	var vbp_cap: Label = Label.new()
	vbp_cap.text = "Profile"
	vbp_cap.custom_minimum_size = Vector2(90, 0)
	_vb_profile = OptionButton.new()
	_vb_profile.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vb_profile.item_selected.connect(_on_vb_profile_selected)
	var vbp_btn: Button = Button.new()
	vbp_btn.text = "↻"
	vbp_btn.tooltip_text = "重新抓 Voicebox profile 清單"
	vbp_btn.pressed.connect(_refresh_vb_profiles)
	vbp_row.add_child(vbp_cap)
	vbp_row.add_child(_vb_profile)
	vbp_row.add_child(vbp_btn)
	vb.add_child(vbp_row)
	_tts_vb_rows.append(vbp_row)

	var vbm_row: HBoxContainer = HBoxContainer.new()
	var vbm_cap: Label = Label.new()
	vbm_cap.text = "模型大小"
	vbm_cap.custom_minimum_size = Vector2(90, 0)
	_vb_model_size = OptionButton.new()
	_vb_model_size.add_item("0.6B（快）")
	_vb_model_size.add_item("1.7B（慢、細膩）")
	_vb_model_size.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vb_model_size.item_selected.connect(func(_i: int) -> void: _emit())
	vbm_row.add_child(vbm_cap)
	vbm_row.add_child(_vb_model_size)
	vb.add_child(vbm_row)
	_tts_vb_rows.append(vbm_row)

	_vb_status = Label.new()
	_vb_status.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	_vb_status.add_theme_font_size_override("font_size", 12)
	vb.add_child(_vb_status)
	_tts_vb_rows.append(_vb_status)

	## --- 百炼雲端配置（選百炼時才顯示）---
	var bl_defs: Array = [
		["Endpoint", "https://{WorkspaceId}.ap-southeast-1.maas.aliyuncs.com", false],
		["API Key", "sk-ws-...（workspace 專屬 key）", true],
		["合成模型", "qwen3-tts-vc-2026-01-22", false],
		["Voice ID", "qwen-tts-vc-...（音色 ID）", false],
	]
	var bl_edits: Array[LineEdit] = []
	for d in bl_defs:
		var row: HBoxContainer = HBoxContainer.new()
		var cap: Label = Label.new()
		cap.text = d[0]
		cap.custom_minimum_size = Vector2(90, 0)
		var edit: LineEdit = LineEdit.new()
		edit.placeholder_text = d[1]
		edit.secret = d[2]
		edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		edit.text_changed.connect(_on_text_changed)
		row.add_child(cap)
		row.add_child(edit)
		vb.add_child(row)
		_tts_bl_rows.append(row)
		bl_edits.append(edit)
	_bl_endpoint = bl_edits[0]
	_bl_api_key = bl_edits[1]
	_bl_model = bl_edits[2]
	_bl_voice = bl_edits[3]

	_vb_http = HTTPRequest.new()
	_vb_http.timeout = 5.0
	_vb_http.request_completed.connect(_on_vb_profiles_response)
	add_child(_vb_http)
	_update_tts_visibility()

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

func _update_vad_threshold_label(v: float) -> void:
	_vad_threshold_label.text = "%.3f" % v

func _on_any_changed(_v: float) -> void:
	_emit()

func _on_any_toggled(_b: bool) -> void:
	_emit()

func _on_text_changed(_s: String) -> void:
	_emit()

func _on_model_text_changed(s: String) -> void:
	## 使用者手動改文字 → 下拉切到「自訂」(除非剛好對到某預設)
	var matched_idx: int = 0
	for i in MODEL_PRESETS.size():
		if MODEL_PRESETS[i].value == s and MODEL_PRESETS[i].value != "":
			matched_idx = i
			break
	if _model_preset.selected != matched_idx:
		_model_preset.select(matched_idx)
	_emit()

func _on_model_preset_selected(idx: int) -> void:
	var v: String = MODEL_PRESETS[idx].value
	if v != "":
		_model_edit.text = v
	_emit()

func _sync_model_preset() -> void:
	## open() 時依當前 model 文字選擇對應下拉
	if _model_preset == null:
		return
	for i in MODEL_PRESETS.size():
		if MODEL_PRESETS[i].value == _model_edit.text and MODEL_PRESETS[i].value != "":
			_model_preset.select(i)
			return
	_model_preset.select(0)

func _on_persona_changed() -> void:
	_emit()

func _emit() -> void:
	settings_changed.emit(_collect())

func _collect() -> Dictionary:
	var tts_v: String = "Mei-Jia"
	if _tts_voice.selected >= 0:
		tts_v = _tts_voice.get_item_text(_tts_voice.selected)
	return {
		"model_path": _model_path_edit.text,
		"scale": _scale_slider.value,
		"head": _head_slider.value,
		"eye": _eye_slider.value,
		"bubble_seconds": _bubble_spin.value,
		"always_on_top": _ontop_check.button_pressed,
		"gaze_follow": _gaze_check.button_pressed,
		"msaa": _msaa_select.selected,
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
		"tts_backend": ["system", "voicebox", "bailian"][maxi(0, _tts_backend_sel.selected)],
		"vb_endpoint": _vb_endpoint.text,
		"vb_profile": _vb_saved_profile,
		"vb_model_size": VB_MODEL_SIZES[maxi(0, _vb_model_size.selected)],
		"bl_endpoint": _bl_endpoint.text,
		"bl_api_key": _bl_api_key.text,
		"bl_model": _bl_model.text,
		"bl_voice": _bl_voice.text,
		"hotkey_keycode": _hotkey_keycode,
		"hotkey_mods": _hotkey_mods,
		"vad_enabled": _vad_check.button_pressed,
		"auto_check_updates": _auto_update_check.button_pressed,
		"vision_enabled": _vision_check.button_pressed,
		"proactive_chat_enabled": _proactive_check.button_pressed,
		"proactive_chat_min_sec": _proactive_min_spin.value,
		"proactive_chat_max_sec": _proactive_max_spin.value,
		"proactive_prompt": _proactive_prompt_edit.text,
		"proactive_with_screenshot": _proactive_screenshot_check.button_pressed,
		"vad_threshold": _vad_threshold_slider.value,
		"vad_silence_sec": _vad_silence_spin.value,
		"continuous_voice": _continuous_voice_check.button_pressed,
		"continuous_timeout_sec": _continuous_timeout_spin.value,
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

func _on_model_path_pick() -> void:
	var fd: FileDialog = FileDialog.new()
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	fd.filters = PackedStringArray(["*.model3.json ; Live2D Model"])
	fd.size = Vector2i(720, 480)
	fd.use_native_dialog = true
	add_child(fd)
	fd.file_selected.connect(func(p: String) -> void:
		_model_path_edit.text = p
		_emit()
		fd.queue_free())
	fd.canceled.connect(func() -> void: fd.queue_free())
	fd.popup_centered()

func _on_close() -> void:
	## 關閉前停掉測試
	if _mic_test_btn and _mic_test_btn.button_pressed:
		_mic_test_btn.button_pressed = false
	_emit()
	hide()

## ---------- TTS 後端切換 / Voicebox profiles ----------
const VB_MODEL_SIZES: Array = ["0.6B", "1.7B"]

func _on_tts_backend_changed(_i: int) -> void:
	_update_tts_visibility()
	if _tts_backend_sel.selected == 1 and _vb_profile.item_count == 0:
		_refresh_vb_profiles()
	_emit()

func _update_tts_visibility() -> void:
	var sel: int = _tts_backend_sel.selected if _tts_backend_sel != null else 0
	for r in _tts_system_rows:
		r.visible = sel == 0
	for r in _tts_vb_rows:
		r.visible = sel == 1
	for r in _tts_bl_rows:
		r.visible = sel == 2

func _vb_endpoint_or_default() -> String:
	var e: String = _vb_endpoint.text.strip_edges()
	return e.rstrip("/") if e != "" else "http://127.0.0.1:17493"

func _refresh_vb_profiles() -> void:
	_vb_status.text = "抓取 profile 清單中…"
	_vb_http.cancel_request()
	var err: int = _vb_http.request(
		_vb_endpoint_or_default() + "/profiles",
		PackedStringArray(["X-Voicebox-Client-Id: doropet"]))
	if err != OK:
		_vb_status.text = "連不上 Voicebox，請確認 app 有開"

func _on_vb_profiles_response(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code < 200 or code >= 300:
		_vb_status.text = "連不上 Voicebox（%s）— 沿用「%s」" % [_vb_endpoint_or_default(), _vb_saved_profile]
		_set_vb_profile_items([_vb_saved_profile] if _vb_saved_profile != "" else [])
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	var items: Array = parsed if typeof(parsed) == TYPE_ARRAY else []
	var names: Array = []
	for p in items:
		if typeof(p) == TYPE_DICTIONARY and String(p.get("name", "")) != "":
			names.append(String(p.get("name", "")))
	if names.is_empty():
		_vb_status.text = "Voicebox 內沒有 profile，先去 app 建一個聲音"
	else:
		_vb_status.text = "Voicebox 連線 OK（%d 個 profile）" % names.size()
	_set_vb_profile_items(names)

func _set_vb_profile_items(names: Array) -> void:
	_vb_profile.clear()
	var sel: int = 0
	for i in names.size():
		_vb_profile.add_item(String(names[i]))
		if names[i] == _vb_saved_profile:
			sel = i
	if _vb_profile.item_count > 0:
		_vb_profile.select(sel)
		_vb_saved_profile = _vb_profile.get_item_text(sel)

func _on_vb_profile_selected(idx: int) -> void:
	_vb_saved_profile = _vb_profile.get_item_text(idx)
	_emit()

## ---------- STT 引擎切換 ----------
func _on_voice_engine_changed(_i: int) -> void:
	_update_stt_visibility()
	_emit()

func _update_stt_visibility() -> void:
	var is_local: bool = _voice_engine.selected == 0
	for r in _stt_local_rows:
		r.visible = is_local
	for r in _stt_cloud_rows:
		r.visible = not is_local

## ---------- 對話熱鍵 capture ----------
func _refresh_hotkey_btn() -> void:
	if _hotkey_btn == null:
		return
	_hotkey_btn.text = _hotkey_string(_hotkey_keycode, _hotkey_mods)

func _hotkey_string(keycode: int, mods: int) -> String:
	var parts: PackedStringArray = []
	if mods & 2: parts.append("⌃")
	if mods & 4: parts.append("⌥")
	if mods & 8: parts.append("⇧")
	if mods & 1: parts.append("⌘")
	parts.append(OS.get_keycode_string(keycode))
	return "+".join(parts)

func _on_hotkey_btn_toggled(on: bool) -> void:
	_capturing_hotkey = on
	if on:
		_hotkey_btn.text = "按下任一組合鍵…（Esc 取消）"
		grab_focus()
	else:
		_refresh_hotkey_btn()

func _input(event: InputEvent) -> void:
	if not _capturing_hotkey:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		var k: int = event.keycode
		## 純 modifier 鍵不能單獨當熱鍵
		if k in [KEY_META, KEY_CTRL, KEY_ALT, KEY_SHIFT]:
			return
		if k == KEY_ESCAPE:
			_capturing_hotkey = false
			_hotkey_btn.button_pressed = false
			_refresh_hotkey_btn()
			set_input_as_handled()
			return
		_hotkey_keycode = k
		_hotkey_mods = 0
		if event.meta_pressed:  _hotkey_mods |= 1
		if event.ctrl_pressed:  _hotkey_mods |= 2
		if event.alt_pressed:   _hotkey_mods |= 4
		if event.shift_pressed: _hotkey_mods |= 8
		_capturing_hotkey = false
		_hotkey_btn.button_pressed = false
		_refresh_hotkey_btn()
		_emit()
		set_input_as_handled()

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
