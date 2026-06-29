extends Node2D
## Doro 桌寵主控腳本
## 功能：拖曳移動、視線跟滑鼠、點擊隨機切換表情、右鍵選單、滾輪縮放、設定持久化

@export var model_path: String = "res://assets/doro/Doro.model3.json"
@export var model_scale: float = 0.25            ## Live2D 模型在 viewport 上的縮放（預設）
@export var model_y_anchor: float = 0.5          ## 0.5=中央；Doro 模型原點在中心
@export var head_follow_strength: float = 30.0  ## 頭部跟滑鼠的角度幅度
@export var eye_follow_strength: float = 1.0    ## 眼球跟滑鼠的偏移幅度

const SCALE_MIN: float = 0.05
const SCALE_MAX: float = 1.0
const SCALE_STEP: float = 1.10              ## 每次滾輪 / 按鈕 ±10%
const CONFIG_PATH: String = "user://doropet.cfg"

var model: Node  ## 實際型別是 GDCubismUserModel（由 GDExtension 動態註冊）
var _expression_ids: Array = []           ## 由 model.get_expressions() 取得的名字
var _expression_index: int = 0

## emotion(1-10) → expression_id 名稱（對應 Doro.model3.json 內的 Name 欄）
const EMOTION_MAP: Dictionary = {
	1: "Exp1",          ## 生氣
	2: "Exp2",          ## 無言
	3: "Exp3",          ## 驚訝
	4: "Exp4",          ## 疑問
	5: "Exp5",          ## 酷酷
	6: "Exp6",          ## 禮物
	7: "Exp7",          ## 讀取中（思考時 trigger）
	8: "Exp8",          ## 開心
	9: "TongueOut",     ## 調皮吐舌頭
	10: "Highlight OFF",## 失神
}
## 給 UI 顯示的人類可讀名（順序與 EMOTION_MAP 對齊）
const EMOTION_LABELS: Array = [
	"😠 生氣", "😑 無言", "😲 驚訝", "❓ 疑問", "😎 酷酷",
	"🎁 禮物", "⏳ 讀取中", "😄 開心", "😝 調皮吐舌", "😵 失神",
]
var _drag_offset: Vector2 = Vector2.ZERO
var _dragging: bool = false
var _menu: PopupMenu
var _gaze_follow: bool = true
var _bubble_seconds: float = 8.0
var _always_on_top: bool = true
## 對話熱鍵（預設 ⇧D,可在設定面板改）
var _hotkey_keycode: int = KEY_D
var _hotkey_mods: int = 8                  ## bitmask: cmd=1, ctrl=2, alt=4, shift=8
## VAD（語音活動偵測）
var _vad_enabled: bool = true
var _vad_threshold: float = 0.02           ## RMS 門檻：> 視為有聲
var _vad_silence_sec: float = 1.2          ## 持續沉默幾秒 → 自動送出
var _vad_has_spoken: bool = false          ## 本次錄音內是否說過話
var _vad_silence_t: float = 0.0
## 反鋸齒(0=關, 1=2x, 2=4x, 3=8x;對應 Viewport.MSAA_*)
var _msaa: int = 2
## 隨機自動表情
const AUTO_EMO_MIN_SEC: float = 60.0       ## 1 分鐘
const AUTO_EMO_MAX_SEC: float = 300.0      ## 5 分鐘
const AUTO_EMO_HOLD_SEC: float = 10.0      ## 表情停留時長
const AUTO_EMO_CHOICES: Array = [1, 2, 3, 4, 5, 6, 8, 9, 10]  ## 略過 7(讀取中)
var _auto_emo_timer: Timer
var _auto_emo_reset_timer: Timer
var _setting_auto_emo: bool = false        ## 標記目前 _set_emotion 是否為 auto 觸發

const ChatClient := preload("res://scripts/chat_client.gd")
const SettingsDialog := preload("res://scripts/settings_dialog.gd")
const VoiceClient := preload("res://scripts/voice_client.gd")
const LogsViewer := preload("res://scripts/logs_viewer.gd")
const Updater := preload("res://scripts/updater.gd")
var _logs_viewer: Window
var _updater: Node
var _update_url: String = ""
var _chat: Node                            ## ChatClient 實例
var _voice: Node                           ## VoiceClient 實例
var _bubble_window: Window                 ## 浮在 Doro 頭頂的對話氣泡（獨立視窗）
var _bubble: PanelContainer
var _bubble_label: Label
var _bubble_timer: Timer
var _input_window: Window                  ## 浮在 Doro 腳下的輸入框（獨立視窗）
var _input_box: LineEdit
var _settings: Window                      ## SettingsDialog 實例
var _last_input_voice: bool = false        ## 最近一次輸入是否來自語音（決定要不要朗讀回覆）
var _last_mouse_pos: Vector2 = Vector2.ZERO
var _mouse_idle_time: float = 0.0
const IDLE_TRIGGER_SEC: float = 3.0        ## 多久沒動進入 idle
var _thinking: bool = false                ## LLM / STT 處理中
var _thinking_t: float = 0.0
var _smooth_dx: float = 0.0                ## 視線目標經過 LERP 平滑後的值
var _smooth_dy: float = 0.0
const GAZE_LERP_SPEED: float = 6.0         ## 越大越快、越小越慢
var _smooth_mouth: float = 0.0
const MOUTH_LERP_SPEED: float = 20.0       ## 嘴巴 LERP 要快，才能跟上聲音

func _ready() -> void:
	_load_config()
	model_y_anchor = 0.5     ## 一次性覆蓋舊 config 的 0.55，確保 Doro 置中
	_load_model()
	_collect_expressions()
	_build_menu()
	_build_chat_ui()
	get_window().always_on_top = _always_on_top
	_apply_msaa()
	_setup_auto_emotion()
	_setup_updater()

func _apply_msaa() -> void:
	var v: Viewport = get_viewport()
	if v == null:
		return
	v.msaa_2d = clamp(_msaa, 0, 3) as Viewport.MSAA

func _setup_updater() -> void:
	_updater = Updater.new()
	_updater.name = "Updater"
	add_child(_updater)
	_updater.update_available.connect(_on_update_available)
	_updater.up_to_date.connect(_on_up_to_date)
	## 啟動延遲 5 秒查更新,避免影響開啟速度
	await get_tree().create_timer(5.0).timeout
	_updater.call("check")

func _on_update_available(latest_tag: String, url: String) -> void:
	_update_url = url
	_show_bubble("🎉 新版 %s 可用!右鍵 → 下載新版" % latest_tag, 10.0)
	## 把 menu 項目改顯眼
	var idx: int = _menu.get_item_index(41)
	if idx >= 0:
		_menu.set_item_text(idx, "⬇ 下載新版 %s" % latest_tag)

func _on_up_to_date() -> void:
	var idx: int = _menu.get_item_index(41)
	if idx >= 0:
		_menu.set_item_text(idx, "✓ 已是最新版 (v%s)" % Updater.current_version())

func _setup_auto_emotion() -> void:
	_auto_emo_timer = Timer.new()
	_auto_emo_timer.one_shot = true
	_auto_emo_timer.timeout.connect(_auto_emo_fire)
	add_child(_auto_emo_timer)

	_auto_emo_reset_timer = Timer.new()
	_auto_emo_reset_timer.one_shot = true
	_auto_emo_reset_timer.timeout.connect(_auto_emo_reset)
	add_child(_auto_emo_reset_timer)

	_schedule_next_auto_emo()

func _schedule_next_auto_emo() -> void:
	var sec: float = randf_range(AUTO_EMO_MIN_SEC, AUTO_EMO_MAX_SEC)
	_auto_emo_timer.start(sec)

func _auto_emo_fire() -> void:
	## 處理中時不打斷,延後再試
	if _thinking:
		_schedule_next_auto_emo()
		return
	var emo: int = AUTO_EMO_CHOICES[randi() % AUTO_EMO_CHOICES.size()]
	_setting_auto_emo = true
	_set_emotion(emo)
	_setting_auto_emo = false
	_auto_emo_reset_timer.start(AUTO_EMO_HOLD_SEC)

func _auto_emo_reset() -> void:
	if not _thinking:
		_setting_auto_emo = true
		_set_emotion(0)
		_setting_auto_emo = false
	_schedule_next_auto_emo()

func _load_model() -> void:
	if not ClassDB.class_exists("GDCubismUserModel"):
		push_error("找不到 GDCubismUserModel — 確認 addons/gd_cubism 已啟用")
		return
	model = ClassDB.instantiate("GDCubismUserModel")
	model.set("assets", model_path)
	## 用內建 texture filter 強制走 linear+mipmaps(對抗縮放鋸齒)
	model.set("texture_filter", CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS)
	_apply_scale()
	add_child(model)

func _reload_model(new_path: String) -> void:
	if new_path == "" or new_path == model_path:
		return
	model_path = new_path
	if model != null:
		model.queue_free()
		model = null
	_expression_ids.clear()
	_expression_index = 0
	_load_model()                  ## 已 add 到 _ss_viewport
	_collect_expressions()
	_show_bubble("已切換模型:%s" % new_path.get_file(), 3.0)

## 主視窗尺寸隨 model_scale 動態貼合 Doro
## 實測 Doro 在 anchor=0.5 下，寬比高大(Q 版頭大)
const BASE_W: float = 1700.0
const BASE_H: float = 1500.0

func _apply_scale() -> void:
	if model == null:
		return
	model.set("scale", Vector2(model_scale, model_scale))
	var new_w: int = max(int(round(model_scale * BASE_W)), 160)
	var new_h: int = max(int(round(model_scale * BASE_H)), 200)
	var old_pos: Vector2i = DisplayServer.window_get_position()
	var old_size: Vector2i = DisplayServer.window_get_size()
	if old_size.x != new_w or old_size.y != new_h:
		var center: Vector2i = old_pos + old_size / 2
		DisplayServer.window_set_size(Vector2i(new_w, new_h))
		DisplayServer.window_set_position(center - Vector2i(new_w / 2, new_h / 2))
	var size: Vector2 = Vector2(new_w, new_h)
	model.set("position", Vector2(size.x * 0.5, size.y * model_y_anchor))
	_reposition_bubble()
	_reposition_input()

func _adjust_scale(factor: float) -> void:
	model_scale = clamp(model_scale * factor, SCALE_MIN, SCALE_MAX)
	_apply_scale()
	_save_config()

func _reset_scale() -> void:
	model_scale = 0.25
	_apply_scale()
	_save_config()

func _collect_expressions() -> void:
	## 從模型本身取（model3.json 的 FileReferences.Expressions[].Name）
	if model == null:
		return
	var ids: Array = model.call("get_expressions")
	_expression_ids = ids
	if _expression_ids.is_empty():
		push_warning("模型沒有宣告任何 Expression")
	else:
		print("[Doro] 已載入 %d 個表情: %s" % [_expression_ids.size(), str(_expression_ids)])

func _build_menu() -> void:
	_menu = PopupMenu.new()
	_menu.add_item("跟 Doro 對話", 30)
	_menu.add_item("清空對話", 31)
	_menu.add_separator()
	## 表情子選單(直接挑 10 種)
	var emo_sub: PopupMenu = PopupMenu.new()
	emo_sub.name = "EmotionSubMenu"
	for i in EMOTION_LABELS.size():
		emo_sub.add_item(EMOTION_LABELS[i], 100 + (i + 1))   ## id = 101..110 對應 emotion 1..10
	emo_sub.id_pressed.connect(_on_menu)
	_menu.add_child(emo_sub)
	_menu.add_submenu_item("選擇表情 ▸", "EmotionSubMenu")
	_menu.add_item("重設表情", 1)
	_menu.add_separator()
	_menu.add_item("放大 (+)", 20)
	_menu.add_item("縮小 (-)", 21)
	_menu.add_item("重設大小", 22)
	_menu.add_separator()
	_menu.add_item("設定…", 40)
	_menu.add_item("檢查更新 (v%s)" % Updater.current_version(), 41)
	_menu.add_separator()
	_menu.add_item("結束", 99)
	_menu.id_pressed.connect(_on_menu)
	add_child(_menu)

func _on_menu(id: int) -> void:
	## 101..110 是 emotion submenu(直接設指定表情)
	if id >= 101 and id <= 110:
		_set_emotion(id - 100)
		return
	match id:
		0:
			_cycle_expression()
		1:
			_reset_expression()
		20:
			_adjust_scale(SCALE_STEP)
		21:
			_adjust_scale(1.0 / SCALE_STEP)
		22:
			_reset_scale()
		30:
			_open_input()
		31:
			if _chat:
				_chat.call("reset_history")
				_show_bubble("(對話清空了 ~)", 2.5)
		40:
			_open_settings()
		41:
			if _update_url != "":
				OS.shell_open(_update_url)
			else:
				_show_bubble("檢查更新中…(目前 v%s)" % Updater.current_version(), 2.0)
				_updater.call("check")
		99:
			get_tree().quit()

func _cycle_expression() -> void:
	if _expression_ids.is_empty() or model == null:
		return
	var name: String = _expression_ids[_expression_index]
	model.call("start_expression", name)
	_expression_index = (_expression_index + 1) % _expression_ids.size()

func _reset_expression() -> void:
	if model == null:
		return
	model.call("stop_expression")
	_expression_index = 0

func _process(dt: float) -> void:
	## 防拖曳卡死:_dragging=true 但實際左鍵沒按下 → reset
	## (popup/輸入框可能吃掉 release event 讓 _input 沒收到)
	if _dragging and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_dragging = false
		_drag_offset = Vector2.ZERO

	## 每 frame 只拉一次 RMS,meter / VAD 共用
	var rms: float = 0.0
	if _voice != null:
		rms = _voice.call("consume_rms")

	## 錄音中 → 更新 bubble 內的 emoji 音量條
	if _recording_ui:
		_update_recording_bubble(rms)

	## VAD：錄音中監聽音量，沉默自動送出
	if _voice != null and _voice.call("is_recording") and _vad_enabled:
		if rms > _vad_threshold:
			_vad_has_spoken = true
			_vad_silence_t = 0.0
		elif _vad_has_spoken:
			_vad_silence_t += dt
			if _vad_silence_t >= _vad_silence_sec:
				## 自動結束送出
				_vad_has_spoken = false
				_vad_silence_t = 0.0
				_last_input_voice = true
				_begin_thinking()
				_voice.call("stop_and_send")

	if model == null:
		return

	var dx: float = 0.0
	var dy: float = 0.0

	if _thinking:
		## 處理中：眼睛繞圈，不受 _gaze_follow 限制（一定要動）
		_thinking_t += dt
		var ang: float = _thinking_t * 3.0
		dx = cos(ang) * 0.7
		dy = sin(ang) * 0.7
	elif not _gaze_follow:
		return
	else:
		## 全螢幕滑鼠座標：Doro 主視窗很小，game viewport 內幾乎沒有滑鼠
		var mouse_screen: Vector2 = Vector2(DisplayServer.mouse_get_position())
		if mouse_screen.distance_to(_last_mouse_pos) > 2.0:
			_last_mouse_pos = mouse_screen
			_mouse_idle_time = 0.0
		else:
			_mouse_idle_time += dt
		if _mouse_idle_time < IDLE_TRIGGER_SEC:
			var win_pos: Vector2 = Vector2(DisplayServer.window_get_position())
			var win_size: Vector2 = Vector2(DisplayServer.window_get_size())
			var doro_center: Vector2 = win_pos + win_size * 0.5
			var delta: Vector2 = mouse_screen - doro_center
			dx = clamp(delta.x / 600.0, -1.0, 1.0)
			dy = clamp(delta.y / 600.0, -1.0, 1.0)
		else:
			## Idle 擺頭：兩個不同頻率 sin 疊加，自然不規律
			var t: float = _mouse_idle_time - IDLE_TRIGGER_SEC
			dx = (sin(t * 0.5) * 0.6 + sin(t * 1.3) * 0.2)
			dy = (sin(t * 0.7) * 0.3 + cos(t * 1.1) * 0.2)

	## 對 target (dx,dy) 做 LERP 平滑，避免模式切換瞬間跳值
	var k: float = clamp(dt * GAZE_LERP_SPEED, 0.0, 1.0)
	_smooth_dx = lerp(_smooth_dx, dx, k)
	_smooth_dy = lerp(_smooth_dy, dy, k)
	_set_param("ParamAngleX", _smooth_dx * head_follow_strength)
	_set_param("ParamAngleY", -_smooth_dy * head_follow_strength)
	_set_param("ParamAngleZ", _smooth_dx * head_follow_strength * 0.3)
	_set_param("ParamEyeBallX", _smooth_dx * eye_follow_strength)
	_set_param("ParamEyeBallY", -_smooth_dy * eye_follow_strength)
	_set_param("ParamBodyAngleX", _smooth_dx * 10.0)

	## --- TTS Lipsync ---
	var target_mouth: float = 0.0
	if _voice != null:
		target_mouth = _voice.call("get_tts_mouth_level")
	var mk: float = clamp(dt * MOUTH_LERP_SPEED, 0.0, 1.0)
	_smooth_mouth = lerp(_smooth_mouth, target_mouth, mk)
	_set_param("ParamMouthOpenY", _smooth_mouth)

func _set_param(id: String, value: float) -> void:
	if model == null:
		return
	var params: Array = model.call("get_parameters")
	for p in params:
		if p.id == id:
			p.value = value
			return

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var input_open: bool = _input_box != null and _input_window.visible
		## 熱鍵：未開時 → 開輸入框 + 立刻錄音；已開時 → 結束錄音送 STT
		if _matches_hotkey(event):
			if input_open:
				if _voice != null and _voice.call("is_recording"):
					_last_input_voice = true
					_begin_thinking()
					_voice.call("stop_and_send")
			else:
				_open_input()
			get_viewport().set_input_as_handled()
			return
		## ESC：取消
		if event.keycode == KEY_ESCAPE and input_open:
			if _voice != null and _voice.call("is_recording"):
				_voice.call("abort_recording")
			_close_input()
			get_viewport().set_input_as_handled()
			return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_dragging = true
				_drag_offset = DisplayServer.mouse_get_position() - DisplayServer.window_get_position()
			else:
				if _dragging and _drag_offset.length() < 4.0:
					_cycle_expression()
				_dragging = false
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			_show_menu_at_mouse()
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_adjust_scale(SCALE_STEP)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_adjust_scale(1.0 / SCALE_STEP)
	elif event is InputEventMouseMotion and _dragging:
		## 雙重保險:確認左鍵真的還按著才搬視窗
		if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			_dragging = false
			return
		var new_pos: Vector2i = DisplayServer.mouse_get_position() - Vector2i(_drag_offset)
		DisplayServer.window_set_position(new_pos)
		_reposition_bubble()
		_reposition_input()

func _show_menu_at_mouse() -> void:
	_menu.reset_size()
	## 非 embed 模式：position 是螢幕絕對座標
	_menu.position = DisplayServer.mouse_get_position()
	_menu.popup()

## ---------- 對話 UI ----------
func _build_chat_ui() -> void:
	## chat client
	_chat = ChatClient.new()
	_chat.name = "ChatClient"
	add_child(_chat)
	_chat.connect("reply_received", _on_chat_reply)
	_chat.connect("error_occurred", _on_chat_error)

	## 套用 config 中可能覆蓋 env 的設定
	var cfg_key: String = _config_get("chat", "api_key", "")
	if cfg_key != "":
		_chat.call("set_api_key", cfg_key)
	var cfg_model: String = _config_get("chat", "model", "")
	if cfg_model != "":
		_chat.call("set_model", cfg_model)
	var cfg_persona: String = _config_get("chat", "persona", "")
	if cfg_persona != "":
		_chat.call("set_persona", cfg_persona)

	## voice client
	_voice = VoiceClient.new()
	_voice.name = "VoiceClient"
	add_child(_voice)
	_voice.connect("transcribed", _on_voice_transcribed)
	_voice.connect("stt_error", _on_voice_error)
	_voice.connect("recording_started", _on_recording_started)
	_voice.connect("recording_stopped", _on_recording_stopped)

	var v_engine: String = _config_get("voice", "engine", "local")
	_voice.call("set_engine", v_engine)
	var v_key: String = _config_get("voice", "api_key", "")
	if v_key != "": _voice.call("set_api_key", v_key)
	var v_ep: String = _config_get("voice", "endpoint", "")
	if v_ep != "": _voice.call("set_endpoint", v_ep)
	var v_model: String = _config_get("voice", "model", "")
	if v_model != "": _voice.call("set_model", v_model)
	var v_bin: String = _config_get("voice", "local_bin", "")
	if v_bin != "": _voice.call("set_local_bin", v_bin)
	var v_lmodel: String = _config_get("voice", "local_model", "")
	if v_lmodel != "": _voice.call("set_local_model", v_lmodel)
	var v_voice: String = _config_get("voice", "tts_voice", "")
	if v_voice != "": _voice.call("set_voice", v_voice)
	_voice.call("set_tts_enabled", _config_get("voice", "tts_enabled", true))

	## 錄音指示由 bubble 顯示（不再需要獨立 Label）

	## 對話泡泡（獨立子視窗，浮在 Doro 頭頂上方）
	_bubble_window = _make_floating_window(Vector2i(360, 60))
	_bubble = PanelContainer.new()
	_bubble.anchor_right = 1.0
	_bubble.anchor_bottom = 1.0
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, 0.95)
	sb.border_color = Color(0xff/255.0, 0x9a/255.0, 0xc4/255.0, 1)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(14)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	_bubble.add_theme_stylebox_override("panel", sb)
	_bubble_label = Label.new()
	_bubble_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_bubble_label.add_theme_color_override("font_color", Color.BLACK)
	_bubble_label.add_theme_font_size_override("font_size", 16)
	_bubble_label.custom_minimum_size = Vector2(320, 0)
	_bubble.add_child(_bubble_label)
	_bubble_window.add_child(_bubble)
	add_child(_bubble_window)

	_bubble_timer = Timer.new()
	_bubble_timer.one_shot = true
	_bubble_timer.timeout.connect(func() -> void: _bubble_window.hide())
	add_child(_bubble_timer)

	## 輸入框（獨立子視窗，浮在 Doro 腳下）
	_input_window = _make_floating_window(Vector2i(360, 44))
	_input_box = LineEdit.new()
	_input_box.placeholder_text = "跟 Doro 說…（Enter 送出，Esc 取消）"
	_input_box.anchor_right = 1.0
	_input_box.anchor_bottom = 1.0
	_input_box.add_theme_font_size_override("font_size", 14)
	_input_box.text_submitted.connect(_on_submit)
	_input_box.text_changed.connect(_on_input_text_changed)
	_input_window.add_child(_input_box)
	add_child(_input_window)

func _open_input() -> void:
	if not _chat.call("is_enabled"):
		_show_bubble("(沒設 OPENROUTER_API_KEY 啦~)", 3.0)
		return
	_input_box.text = ""
	var hotkey_str: String = hotkey_to_string(_hotkey_keycode, _hotkey_mods)
	_input_box.placeholder_text = "🎙 聽你說... 再按 %s 結束 / Esc 取消 / 直接打字也行" % hotkey_str
	_input_window.show()
	_reposition_input()
	_input_box.grab_focus()
	## 立即啟動錄音聆聽（若 STT 可用）
	_vad_has_spoken = false
	_vad_silence_t = 0.0
	if _voice != null and _voice.call("has_stt"):
		_voice.call("start_recording")

func _close_input() -> void:
	_input_box.release_focus()
	_input_window.hide()
	if _voice != null and _voice.call("is_recording"):
		_voice.call("abort_recording")

func _make_floating_window(default_size: Vector2i) -> Window:
	var w: Window = Window.new()
	w.borderless = true
	w.always_on_top = true
	w.transparent = true
	w.transparent_bg = true
	w.unresizable = true
	w.unfocusable = false
	w.size = default_size
	w.min_size = Vector2i(80, 30)
	w.visible = false
	return w

func _reposition_input() -> void:
	if _input_window == null or not _input_window.visible:
		return
	var main_pos: Vector2i = DisplayServer.window_get_position()
	var main_size: Vector2i = DisplayServer.window_get_size()
	var iw: int = _input_window.size.x
	var ih: int = _input_window.size.y
	## 主視窗水平中心 → 輸入框中心對齊；垂直放在主視窗下方 8 px
	var cx: int = main_pos.x + main_size.x / 2
	var x: int = cx - iw / 2
	var y: int = main_pos.y + main_size.y + 8
	_input_window.position = Vector2i(x, y)

## 訊息含這些關鍵字 → 自動截圖附帶
const SCREEN_KEYWORDS: PackedStringArray = [
	"螢幕", "畫面", "桌面", "你看", "看看", "看一下", "幫我看", "看這",
	"這個", "這邊", "我這", "截圖",
	"screen", "see this", "look at", "screenshot",
]

func _wants_screenshot(text: String) -> bool:
	var low: String = text.to_lower()
	for k in SCREEN_KEYWORDS:
		if low.contains(k.to_lower()):
			return true
	return false

func _grab_screenshot_b64() -> String:
	var path: String = _platform_temp_dir() + "/doropet_screen.png"
	var rc: int = -1
	if OS.get_name() == "macOS":
		rc = OS.execute("/usr/sbin/screencapture", ["-x", "-t", "png", "-m", path], [], false)
	elif OS.get_name() == "Windows":
		## PowerShell:抓主螢幕 → 存 PNG
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
	else:
		return ""
	if rc != 0 or not FileAccess.file_exists(path):
		return ""
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var bytes: PackedByteArray = f.get_buffer(f.get_length())
	f.close()
	return Marshalls.raw_to_base64(bytes)

func _platform_temp_dir() -> String:
	if OS.get_name() == "Windows":
		var t: String = OS.get_environment("TEMP")
		if t == "":
			t = OS.get_environment("TMP")
		if t == "":
			t = "C:\\Windows\\Temp"
		return t
	var t2: String = OS.get_environment("TMPDIR")
	if t2 == "":
		t2 = "/tmp"
	return t2.rstrip("/")

func _on_input_text_changed(_t: String) -> void:
	## 使用者開始打字 → 中止錄音（避免 STT 結果覆蓋 user 輸入）
	if _voice != null and _voice.call("is_recording"):
		_voice.call("abort_recording")

func _on_submit(text: String) -> void:
	var t: String = text.strip_edges()
	if t == "":
		_close_input()
		return
	_close_input()
	_last_input_voice = false
	_begin_thinking()
	var img: String = ""
	if _wants_screenshot(t):
		_show_bubble("📸 看一下螢幕…", 999.0)
		img = _grab_screenshot_b64()
	if img != "":
		_show_bubble("…(Doro 在看畫面)", 999.0)
	else:
		_show_bubble("…(Doro 想想)", 999.0)
	_chat.call("send", t, img)

func _on_chat_reply(text: String, emotion: int) -> void:
	_end_thinking()
	_set_emotion(emotion)
	_show_bubble(text, _bubble_seconds)
	## 不論文字 / 語音輸入，只要 TTS 開著就念
	if _voice and _voice.call("is_tts_enabled"):
		_voice.call("speak", text)

func _set_emotion(emo: int) -> void:
	if model == null:
		return
	## user 介入(不是 auto 觸發)→ 取消自動 reset,讓 user 選的表情留住直到下次互動
	if not _setting_auto_emo and _auto_emo_reset_timer != null:
		_auto_emo_reset_timer.stop()
	if emo <= 0 or not EMOTION_MAP.has(emo):
		model.call("stop_expression")
		return
	model.call("start_expression", EMOTION_MAP[emo])

func _begin_thinking() -> void:
	_thinking = true
	_thinking_t = 0.0
	_set_emotion(7)               ## 讀取中

func _end_thinking() -> void:
	_thinking = false

## ---------- 熱鍵 ----------
func _event_modifiers(ev: InputEventKey) -> int:
	var m: int = 0
	if ev.meta_pressed: m |= 1
	if ev.ctrl_pressed: m |= 2
	if ev.alt_pressed:  m |= 4
	if ev.shift_pressed: m |= 8
	return m

func _matches_hotkey(ev: InputEventKey) -> bool:
	if ev.keycode != _hotkey_keycode:
		return false
	return _event_modifiers(ev) == _hotkey_mods

static func hotkey_to_string(keycode: int, mods: int) -> String:
	var parts: PackedStringArray = []
	if mods & 2: parts.append("⌃")    ## ctrl
	if mods & 4: parts.append("⌥")    ## alt/option
	if mods & 8: parts.append("⇧")    ## shift
	if mods & 1: parts.append("⌘")    ## cmd/meta
	parts.append(OS.get_keycode_string(keycode))
	return "+".join(parts)

func _on_chat_error(reason: String) -> void:
	_end_thinking()
	_show_bubble("(嗚… %s)" % reason, 4.0)

## ---------- 語音 ----------
func _toggle_voice() -> void:
	if _voice == null:
		return
	if not _voice.call("has_stt"):
		_show_bubble("(沒設 OPENAI_API_KEY，沒辦法聽你說話 ~)", 3.0)
		return
	if _voice.call("is_recording"):
		_show_bubble("(收到，Doro 正在聽…)", 2.0)
		_last_input_voice = true
		_begin_thinking()         ## STT + LLM 處理期間
		_voice.call("stop_and_send")
	else:
		_voice.call("start_recording")

## 錄音狀態(用 bubble 顯示;音量條用 emoji 拼,免高度被撐爆)
var _recording_ui: bool = false
const METER_BARS: String = "▁▂▃▄▅▆▇█"
const METER_WIDTH: int = 14

func _meter_string(rms: float) -> String:
	var amp: float = clamp(rms * 4.0, 0.0, 1.0)
	var lit: int = int(round(amp * float(METER_WIDTH)))
	var out: String = ""
	for i in METER_WIDTH:
		if i < lit:
			var lvl: int = int(amp * 7.0)
			out += METER_BARS.substr(lvl, 1)
		else:
			out += "▁"
	return out

func _update_recording_bubble(rms: float) -> void:
	if not _recording_ui:
		return
	var hk: String = hotkey_to_string(_hotkey_keycode, _hotkey_mods)
	_bubble_label.text = "🎙 %s\n(再按 %s 結束 / Esc 取消)" % [_meter_string(rms), hk]

func _on_recording_started() -> void:
	_recording_ui = true
	_bubble_timer.stop()
	_update_recording_bubble(0.0)
	## 錄音 bubble 兩行字 → 給足固定 size,免高度被切
	_bubble_window.size = Vector2i(380, 78)
	_bubble_window.show()
	_reposition_bubble()

func _on_recording_stopped() -> void:
	_recording_ui = false
	_bubble_window.hide()
	_bubble_timer.stop()

func _on_voice_transcribed(text: String) -> void:
	## STT 完成 → 直接送，不等 user 按 Enter
	if _input_box != null and _input_window.visible:
		_close_input()
	_last_input_voice = true
	## _begin_thinking 已在錄音停止時呼叫,這裡先顯示 user 講的話
	_show_bubble("「%s」" % text, 2.0)
	## 短暫延遲後送 chat(讓使用者看到自己講了什麼)
	await get_tree().create_timer(0.3).timeout
	_chat.call("send", text)

func _on_voice_error(reason: String) -> void:
	_end_thinking()
	_show_bubble("(嗚… %s)" % reason, 3.0)

func _show_bubble(text: String, seconds: float) -> void:
	_bubble_label.text = text
	_bubble_window.show()
	_bubble_timer.stop()
	_bubble_timer.start(seconds)
	_reposition_bubble()
	## 等 layout 算完再依照新的尺寸定位
	await get_tree().process_frame
	var min_sz: Vector2 = _bubble.get_combined_minimum_size()
	_bubble_window.size = Vector2i(int(ceil(min_sz.x)), int(ceil(min_sz.y)))
	_reposition_bubble()

func _reposition_bubble() -> void:
	if _bubble_window == null or not _bubble_window.visible:
		return
	var main_pos: Vector2i = DisplayServer.window_get_position()
	var main_size: Vector2i = DisplayServer.window_get_size()
	var bw: int = _bubble_window.size.x
	var bh: int = _bubble_window.size.y
	var cx: int = main_pos.x + main_size.x / 2
	var x: int = cx - bw / 2
	var y: int = main_pos.y - bh - 8
	_bubble_window.position = Vector2i(x, y)

## ---------- 設定視窗 ----------
func _open_settings() -> void:
	if _settings == null:
		_settings = SettingsDialog.new()
		add_child(_settings)
		_settings.settings_changed.connect(_on_settings_changed)
		_settings.logs_requested.connect(_open_logs)
	## 把 voice node 注入,讓 dialog 自己列裝置 / 跑測試 / 顯示 RMS
	_settings.call("set_voice_node", _voice)
	var data: Dictionary = {
		"model_path": model_path,
		"scale": model_scale,
		"head": head_follow_strength,
		"eye": eye_follow_strength,
		"bubble_seconds": _bubble_seconds,
		"always_on_top": _always_on_top,
		"gaze_follow": _gaze_follow,
		"api_key": _chat.call("get_api_key"),
		"model": _chat.call("get_model"),
		"persona": _chat.call("get_persona"),
		"voice_engine": _voice.call("get_engine") if _voice else "local",
		"voice_api_key": _voice.call("get_api_key") if _voice else "",
		"voice_endpoint": _voice.call("get_endpoint") if _voice else "",
		"voice_model": _voice.call("get_model") if _voice else "",
		"voice_local_bin": _voice.call("get_local_bin") if _voice else "",
		"voice_local_model": _voice.call("get_local_model") if _voice else "",
		"tts_voice": _voice.call("get_voice") if _voice else "Mei-Jia",
		"tts_enabled": _voice.call("is_tts_enabled") if _voice else true,
		"hotkey_keycode": _hotkey_keycode,
		"hotkey_mods": _hotkey_mods,
		"vad_enabled": _vad_enabled,
		"vad_threshold": _vad_threshold,
		"vad_silence_sec": _vad_silence_sec,
		"msaa": _msaa,
	}
	_settings.open(data, _chat.call("get_status"), _voice.call("stt_status") if _voice else "")

func _open_logs() -> void:
	if _logs_viewer == null:
		_logs_viewer = LogsViewer.new()
		add_child(_logs_viewer)
	_logs_viewer.call("open")

func _on_settings_changed(data: Dictionary) -> void:
	## 即時套用 + 寫 config
	var new_model_path: String = String(data.get("model_path", model_path))
	if new_model_path != "" and new_model_path != model_path:
		_reload_model(new_model_path)
	model_scale = clamp(float(data.get("scale", model_scale)), SCALE_MIN, SCALE_MAX)
	head_follow_strength = float(data.get("head", head_follow_strength))
	eye_follow_strength = float(data.get("eye", eye_follow_strength))
	_bubble_seconds = float(data.get("bubble_seconds", _bubble_seconds))
	_always_on_top = bool(data.get("always_on_top", _always_on_top))
	_gaze_follow = bool(data.get("gaze_follow", _gaze_follow))
	_hotkey_keycode = int(data.get("hotkey_keycode", _hotkey_keycode))
	_hotkey_mods = int(data.get("hotkey_mods", _hotkey_mods))
	_vad_enabled = bool(data.get("vad_enabled", _vad_enabled))
	_vad_threshold = float(data.get("vad_threshold", _vad_threshold))
	_vad_silence_sec = float(data.get("vad_silence_sec", _vad_silence_sec))
	var new_msaa: int = int(data.get("msaa", _msaa))
	if new_msaa != _msaa:
		_msaa = new_msaa
		_apply_msaa()
	_apply_scale()
	get_window().always_on_top = _always_on_top
	if _chat:
		_chat.call("set_api_key", data.get("api_key", ""))
		_chat.call("set_model", data.get("model", ""))
		_chat.call("set_persona", data.get("persona", ""))
	if _voice:
		_voice.call("set_engine", data.get("voice_engine", "local"))
		_voice.call("set_api_key", data.get("voice_api_key", ""))
		_voice.call("set_endpoint", data.get("voice_endpoint", ""))
		_voice.call("set_model", data.get("voice_model", ""))
		_voice.call("set_local_bin", data.get("voice_local_bin", ""))
		_voice.call("set_local_model", data.get("voice_local_model", ""))
		_voice.call("set_voice", data.get("tts_voice", "Mei-Jia"))
		_voice.call("set_tts_enabled", bool(data.get("tts_enabled", true)))
	_save_config()

## ---------- 設定持久化 ----------
func _config_get(section: String, key: String, default_val: Variant) -> Variant:
	var cfg: ConfigFile = ConfigFile.new()
	if cfg.load(CONFIG_PATH) != OK:
		return default_val
	return cfg.get_value(section, key, default_val)

func _load_config() -> void:
	var cfg: ConfigFile = ConfigFile.new()
	if cfg.load(CONFIG_PATH) != OK:
		return
	model_path = cfg.get_value("pet", "model_path", model_path)
	model_scale = clamp(cfg.get_value("pet", "scale", model_scale), SCALE_MIN, SCALE_MAX)
	model_y_anchor = cfg.get_value("pet", "y_anchor", model_y_anchor)
	head_follow_strength = cfg.get_value("pet", "head", head_follow_strength)
	eye_follow_strength = cfg.get_value("pet", "eye", eye_follow_strength)
	_bubble_seconds = cfg.get_value("pet", "bubble_seconds", _bubble_seconds)
	_always_on_top = cfg.get_value("pet", "always_on_top", _always_on_top)
	_gaze_follow = cfg.get_value("pet", "gaze_follow", _gaze_follow)
	_hotkey_keycode = int(cfg.get_value("pet", "hotkey_keycode", _hotkey_keycode))
	_hotkey_mods = int(cfg.get_value("pet", "hotkey_mods", _hotkey_mods))
	_vad_enabled = bool(cfg.get_value("pet", "vad_enabled", _vad_enabled))
	_vad_threshold = float(cfg.get_value("pet", "vad_threshold", _vad_threshold))
	_vad_silence_sec = float(cfg.get_value("pet", "vad_silence_sec", _vad_silence_sec))
	_msaa = int(cfg.get_value("pet", "msaa", _msaa))

func _save_config() -> void:
	var cfg: ConfigFile = ConfigFile.new()
	## 載入既有再覆寫，保留 chat 段
	cfg.load(CONFIG_PATH)
	cfg.set_value("pet", "model_path", model_path)
	cfg.set_value("pet", "scale", model_scale)
	cfg.set_value("pet", "y_anchor", model_y_anchor)
	cfg.set_value("pet", "head", head_follow_strength)
	cfg.set_value("pet", "eye", eye_follow_strength)
	cfg.set_value("pet", "bubble_seconds", _bubble_seconds)
	cfg.set_value("pet", "always_on_top", _always_on_top)
	cfg.set_value("pet", "gaze_follow", _gaze_follow)
	cfg.set_value("pet", "hotkey_keycode", _hotkey_keycode)
	cfg.set_value("pet", "hotkey_mods", _hotkey_mods)
	cfg.set_value("pet", "vad_enabled", _vad_enabled)
	cfg.set_value("pet", "vad_threshold", _vad_threshold)
	cfg.set_value("pet", "vad_silence_sec", _vad_silence_sec)
	cfg.set_value("pet", "msaa", _msaa)
	if _chat:
		cfg.set_value("chat", "api_key", _chat.call("get_api_key"))
		cfg.set_value("chat", "model", _chat.call("get_model"))
		cfg.set_value("chat", "persona", _chat.call("get_persona"))
	if _voice:
		cfg.set_value("voice", "engine", _voice.call("get_engine"))
		cfg.set_value("voice", "api_key", _voice.call("get_api_key"))
		cfg.set_value("voice", "endpoint", _voice.call("get_endpoint"))
		cfg.set_value("voice", "model", _voice.call("get_model"))
		cfg.set_value("voice", "local_bin", _voice.call("get_local_bin"))
		cfg.set_value("voice", "local_model", _voice.call("get_local_model"))
		cfg.set_value("voice", "tts_voice", _voice.call("get_voice"))
		cfg.set_value("voice", "tts_enabled", _voice.call("is_tts_enabled"))
	cfg.save(CONFIG_PATH)
