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
## 給 UI 顯示的人類可讀名（順序與 EMOTION_MAP 對齊)
const EMOTION_LABELS: Array = [
	"😠 生氣", "😑 無言", "😲 驚訝", "❓ 疑問", "😎 酷酷",
	"🎁 禮物", "⏳ 讀取中", "😄 開心", "😝 調皮吐舌", "😵 失神",
]
## 動作(非 .exp3.json,跑參數動畫):
##   11 = 點頭(yes,ParamAngleY 上下振盪)
##   12 = 搖頭(no,ParamAngleX 左右振盪)
##   13 = 眯眼
##   14 = 挑眉
const ACTION_LABELS: Array = [
	{"id": 11, "label": "👍 點頭(yes)"},
	{"id": 12, "label": "👎 搖頭(no)"},
	{"id": 13, "label": "😏 眯眼"},
	{"id": 14, "label": "🤨 挑眉"},
]
var _action_anim_t: float = -1.0          ## >=0 動作動畫進行中
var _action_anim_id: int = 0              ## 當前動作 id

## 不同動作不同時長
const ACTION_DURATIONS: Dictionary = {
	11: 1.4,    ## 點頭
	12: 1.4,    ## 搖頭
	13: 2.6,    ## 眯眼(分階段:快眯 + 停留 + 緩睜)
	14: 2.0,    ## 挑眉(久一點才看得明顯)
}

func _action_duration(id: int) -> float:
	return float(ACTION_DURATIONS.get(id, 1.4))
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
const DoroLogger := preload("res://scripts/logger.gd")
var _logs_viewer: Window
var _updater: Node
var _update_url: String = ""
var _auto_check_updates: bool = true
var _vision_enabled: bool = true                ## 關鍵字截圖視覺
var _proactive_chat_enabled: bool = false       ## Doro 主動搭話
var _proactive_chat_min_sec: float = 600.0      ## idle 多久觸發(預設 10 分鐘)
var _proactive_chat_max_sec: float = 1800.0     ## 上限 30 分鐘
var _proactive_prompt: String = ""              ## 自訂搭話指令(留空用預設)
var _proactive_with_screenshot: bool = false    ## 主動搭話時自動拍螢幕一起送
var _proactive_timer: Timer
const DEFAULT_PROACTIVE_PROMPT: String = "(系統提示:主人靜默了一段時間,你主動找他/她聊個有趣或關心的話題,維持 30 字內。話題可以是天氣、時間、最近有沒有累、想吃什麼等貼心關懷,或分享你今天的『心情』。)"

## 系統匣 / menu bar 圖示
var _tray_id: int = -1
var _tray_menu: PopupMenu
var _hidden: bool = false
var _chat: Node                            ## ChatClient 實例
var _voice: Node                           ## VoiceClient 實例
var _bubble_window: Window                 ## 浮在 Doro 頭頂的對話氣泡（獨立視窗）
var _bubble: PanelContainer
var _bubble_label: Label
var _bubble_timer: Timer
var _input_window: Window                  ## 浮在 Doro 腳下的輸入框（獨立視窗）
var _input_box: LineEdit
var _input_idle_timer: Timer                ## 送出後保留輸入框 N 秒,過了沒動作再關
const INPUT_IDLE_SEC: float = 5.0
## 連續對話:STT 送出後 → Doro 回覆/TTS 完成 → 自動繼續錄音等下一輪
## user 不講話超過 _continuous_timeout_sec 才真關
var _continuous_voice: bool = true
var _continuous_timeout_sec: float = 15.0
var _settings: Window                      ## SettingsDialog 實例
var _last_input_voice: bool = false        ## 最近一次輸入是否來自語音（決定要不要朗讀回覆）
var _pending_bubble_text: String = ""      ## TTS 生成中先壓著的回覆文字，開播才顯示
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

## 眨眼 / 挑眉(idle 期間隨機 trigger)
var _blink_t: float = 15.0                  ## 距離下一次眨眼倒數
var _blink_anim_t: float = -1.0            ## 正在播眨眼動畫的時間(>=0 時 active)
const BLINK_DURATION: float = 0.18         ## 一次眨眼總時長
var _brow_t: float = 12.0
var _brow_anim_t: float = -1.0
const BROW_DURATION: float = 0.6           ## 挑眉動畫時長

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
	_setup_tray()
	_setup_proactive_chat()

## ---------- 主動搭話 ----------
func _setup_proactive_chat() -> void:
	_proactive_timer = Timer.new()
	_proactive_timer.one_shot = true
	_proactive_timer.timeout.connect(_on_proactive_timer)
	add_child(_proactive_timer)
	if _proactive_chat_enabled:
		_schedule_proactive()

func _schedule_proactive() -> void:
	if not _proactive_chat_enabled or _proactive_timer == null:
		return
	var sec: float = randf_range(_proactive_chat_min_sec, _proactive_chat_max_sec)
	_proactive_timer.start(sec)

func _on_proactive_timer() -> void:
	## 處理中 / 對話開啟時跳過,重排
	if _thinking or (_input_window != null and _input_window.visible) or not _proactive_chat_enabled:
		_schedule_proactive()
		return
	if _chat == null or not _chat.call("is_enabled"):
		_schedule_proactive()
		return
	_last_input_voice = false
	_begin_thinking()
	var p: String = _proactive_prompt.strip_edges()
	if p == "":
		p = DEFAULT_PROACTIVE_PROMPT
	var img: String = ""
	if _proactive_with_screenshot and _vision_enabled:
		_show_bubble("📸 Doro 偷看一眼螢幕…", 999.0)
		img = _grab_screenshot_b64()
		if img != "":
			p += "\n(附上剛拍的螢幕截圖,可基於畫面內容主動搭話)"
	_show_bubble("💭 Doro 想說話…", 999.0)
	_chat.call("send", p, img)
	_schedule_proactive()

## ---------- 結束 ----------

## ---------- 系統匣 / menu bar ----------
func _setup_tray() -> void:
	if not DisplayServer.has_feature(DisplayServer.FEATURE_STATUS_INDICATOR):
		return
	## tray 專用 PopupMenu
	_tray_menu = PopupMenu.new()
	_tray_menu.add_item("💬 跟 Doro 對話", 201)
	_tray_menu.add_item("顯示 / 隱藏 Doro", 200)
	_tray_menu.add_separator()
	_tray_menu.add_item("檢查更新 / 下載新版", 202)
	_tray_menu.add_item("設定…", 203)
	_tray_menu.add_separator()
	_tray_menu.add_item("結束", 299)
	_tray_menu.id_pressed.connect(_on_tray_menu)
	add_child(_tray_menu)

	## 圖示用 Doro icon
	var icon: Texture2D = load("res://assets/doro/icon.png")
	_tray_id = DisplayServer.create_status_indicator(icon, "DoroPet — 點擊顯示 / 隱藏", _on_tray_click)

func _on_tray_click(mouse_button: int, mouse_pos: Vector2i) -> void:
	if mouse_button == MOUSE_BUTTON_LEFT:
		## 左鍵 = 顯示 Doro + 立即開對話輸入框(等同全局熱鍵替代)
		_show_window_if_hidden()
		get_window().grab_focus()
		_open_input()
	elif mouse_button == MOUSE_BUTTON_RIGHT:
		_tray_menu.reset_size()
		_tray_menu.position = mouse_pos
		_tray_menu.popup()

func _on_tray_menu(id: int) -> void:
	match id:
		200: _toggle_window_hidden()
		201:
			_show_window_if_hidden()
			get_window().grab_focus()
			_open_input()
		202:
			if _update_url != "":
				_install_latest_and_restart()
			else:
				_updater.call("reset_notified")
				_updater.call("check")
		203:
			_show_window_if_hidden()
			_open_settings()
		299:
			_cleanup_tray()
			get_tree().quit()

func _toggle_window_hidden() -> void:
	if _hidden:
		_show_window_if_hidden()
	else:
		_hide_window_to_tray()

func _hide_window_to_tray() -> void:
	_hidden = true
	get_window().hide()
	if _bubble_window != null: _bubble_window.hide()
	if _input_window != null: _input_window.hide()

func _show_window_if_hidden() -> void:
	if not _hidden:
		return
	_hidden = false
	get_window().show()
	get_window().always_on_top = _always_on_top

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
	## 啟動延遲 5 秒查更新
	await get_tree().create_timer(5.0).timeout
	_updater.call("check")
	## 自動輪詢開關
	if _auto_check_updates:
		_updater.call("start_polling")

func _on_update_available(latest_tag: String, url: String) -> void:
	_update_url = url
	_show_bubble("🎉 新版 %s 可用!右鍵 → 下載新版" % latest_tag, 12.0)
	var idx: int = _menu.get_item_index(41)
	if idx >= 0:
		_menu.set_item_text(idx, "⬇ 下載新版 %s" % latest_tag)
	## TTS 念出來(如果開了)
	if _voice and _voice.call("is_tts_enabled"):
		_voice.call("speak", "主人,有新版本可以更新喔~")

func _install_latest_and_restart() -> void:
	var os_name: String = OS.get_name()
	if os_name != "macOS" and os_name != "Windows":
		_show_bubble("一鍵更新目前只支援 macOS / Windows", 4.0)
		return
	_show_bubble("⬇️ 下載最新版中...請等一下", 3.0)
	if _voice and _voice.call("is_tts_enabled"):
		_voice.call("speak", "Doro 準備自己更新嘍~")
	## 給 TTS + bubble 一點露臉時間,然後退出讓 installer 接手
	await get_tree().create_timer(1.5).timeout
	var ok: bool = false
	if os_name == "macOS":
		ok = Updater.install_macos_latest()
	else:
		ok = Updater.install_windows_latest()
	if ok:
		_cleanup_tray()
		get_tree().quit()
	else:
		_show_bubble("啟動更新腳本失敗 :(", 3.0)

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
		emo_sub.add_item(EMOTION_LABELS[i], 100 + (i + 1))   ## 101..110 = emotion 1..10
	emo_sub.add_separator()
	for a in ACTION_LABELS:
		emo_sub.add_item(a.label, 100 + a.id)                ## 111..114 = action
	emo_sub.id_pressed.connect(_on_menu)
	_menu.add_child(emo_sub)
	_menu.add_submenu_item("表情 / 動作 ▸", "EmotionSubMenu")
	_menu.add_item("重設表情", 1)
	_menu.add_separator()
	_menu.add_item("放大 (+)", 20)
	_menu.add_item("縮小 (-)", 21)
	_menu.add_item("重設大小", 22)
	_menu.add_separator()
	_menu.add_item("設定…", 40)
	_menu.add_item("檢查更新 (v%s)" % Updater.current_version(), 41)
	_menu.add_separator()
	_menu.add_item("隱藏到系統匣", 50)
	_menu.add_item("結束", 99)
	_menu.id_pressed.connect(_on_menu)
	add_child(_menu)

func _on_menu(id: int) -> void:
	## 101..114 = emotion 1..10 + action 11..14
	if id >= 101 and id <= 114:
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
				## 已知有新版 → 直接一鍵更新並重啟
				_install_latest_and_restart()
			else:
				_show_bubble("檢查更新中…(目前 v%s)" % Updater.current_version(), 2.0)
				_updater.call("reset_notified")
				_updater.call("check")
		50:
			_hide_window_to_tray()
		99:
			_cleanup_tray()
			get_tree().quit()

func _cleanup_tray() -> void:
	if _tray_id >= 0:
		DisplayServer.delete_status_indicator(_tray_id)
		_tray_id = -1

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		_cleanup_tray()

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
			if not _vad_has_spoken and _input_idle_timer != null:
				## user 開講話 → 取消 idle 關閉倒數(連續對話流程)
				_input_idle_timer.stop()
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

	## --- 眨眼 ---
	_update_blink(dt)
	## --- 挑眉(隨機,較不頻繁)---
	_update_brow(dt)
	## --- 點頭 / 搖頭 / 眯眼 / 挑眉 一次性動作 ---
	_update_action(dt)

func _update_action(dt: float) -> void:
	if _action_anim_t < 0.0:
		return
	_action_anim_t += dt
	var dur: float = _action_duration(_action_anim_id)
	var t: float = _action_anim_t / dur
	if t >= 1.0:
		_action_anim_t = -1.0
		return
	match _action_anim_id:
		11:    ## 點頭:兩次上下,Y 振盪
			var v: float = sin(t * PI * 4.0) * 25.0
			_set_param("ParamAngleY", -v)
		12:    ## 搖頭:兩次左右,X 振盪
			var v: float = sin(t * PI * 4.0) * 30.0
			_set_param("ParamAngleX", v)
		13:    ## 眯眼(半閉,不到完全閉)
			##   t∈[0, 0.15]   1 → 0.4
			##   t∈[0.15, 0.7] 維持 0.4
			##   t∈[0.7, 1.0]  0.4 → 1
			var v: float
			if t < 0.15:
				v = lerp(1.0, 0.4, t / 0.15)
			elif t < 0.7:
				v = 0.4
			else:
				v = lerp(0.4, 1.0, (t - 0.7) / 0.3)
			_set_param("ParamEyeLOpen", v)
			_set_param("ParamEyeROpen", v)
		14:    ## 挑眉:快抬→停→緩降 + 同時頭微抬讓動作明顯
			var brow: float
			if t < 0.15:
				brow = lerp(0.0, 1.0, t / 0.15)
			elif t < 0.75:
				brow = 1.0
			else:
				brow = lerp(1.0, 0.0, (t - 0.75) / 0.25)
			_set_param("ParamBrowLY", brow)
			_set_param("ParamBrowRY", brow)
			## 配合眼睛瞇 + 頭微抬,挑眉更明顯
			_set_param("ParamEyeLOpen", 1.0 - brow * 0.25)
			_set_param("ParamEyeROpen", 1.0 - brow * 0.25)
			_set_param("ParamAngleY", -brow * 6.0)

func _update_blink(dt: float) -> void:
	if _thinking:
		return
	if _blink_anim_t >= 0.0:
		_blink_anim_t += dt
		if _blink_anim_t >= BLINK_DURATION:
			_blink_anim_t = -1.0
			_set_param("ParamEyeLOpen", 1.0)
			_set_param("ParamEyeROpen", 1.0)
			_schedule_next_blink()
		else:
			## 三角形:0→1→0 對應 open→close→open
			var t: float = _blink_anim_t / BLINK_DURATION
			var openv: float = (1.0 - abs(t * 2.0 - 1.0))   ## 0..1..0
			var eye: float = 1.0 - openv                     ## 1=睜, 0=閉
			_set_param("ParamEyeLOpen", eye)
			_set_param("ParamEyeROpen", eye)
	else:
		_blink_t -= dt
		if _blink_t <= 0.0:
			_blink_anim_t = 0.0

func _schedule_next_blink() -> void:
	_blink_t = randf_range(10.0, 30.0)   ## 10–30 秒眨一次

func _update_brow(dt: float) -> void:
	if _thinking:
		return
	if _brow_anim_t >= 0.0:
		_brow_anim_t += dt
		if _brow_anim_t >= BROW_DURATION:
			_brow_anim_t = -1.0
			_set_param("ParamBrowLY", 0.0)
			_set_param("ParamBrowRY", 0.0)
			_schedule_next_brow()
		else:
			## sin 曲線:平滑上下
			var t: float = _brow_anim_t / BROW_DURATION
			var v: float = sin(t * PI) * 1.0   ## 0→1.0→0,挑眉幅度全開
			_set_param("ParamBrowLY", v)
			_set_param("ParamBrowRY", v)
	else:
		_brow_t -= dt
		if _brow_t <= 0.0:
			_brow_anim_t = 0.0

func _schedule_next_brow() -> void:
	_brow_t = randf_range(8.0, 20.0)   ## 8-20 秒挑一次眉,自然但不頻繁

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
	_chat.connect("tool_started", _on_chat_tool_started)
	_chat.connect("thinking_resumed", _on_chat_thinking_resumed)

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
	_chat.call("set_distill_model", _config_get("chat", "distill_model", ""))

	## voice client
	_voice = VoiceClient.new()
	_voice.name = "VoiceClient"
	add_child(_voice)
	_voice.connect("transcribed", _on_voice_transcribed)
	_voice.connect("stt_error", _on_voice_error)
	_voice.connect("recording_started", _on_recording_started)
	_voice.connect("recording_stopped", _on_recording_stopped)
	_voice.connect("speaking_started", _on_tts_started)
	_voice.connect("speaking_finished", _on_tts_finished)

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
	_voice.call("set_tts_volume", float(_config_get("voice", "tts_volume", 1.0)))
	_voice.call("set_tts_backend", _config_get("voice", "tts_backend", "system"))
	_voice.call("set_vb_endpoint", _config_get("voice", "vb_endpoint", ""))
	_voice.call("set_vb_profile", _config_get("voice", "vb_profile", ""))
	_voice.call("set_vb_model_size", _config_get("voice", "vb_model_size", "0.6B"))
	_voice.call("set_bl_endpoint", _config_get("voice", "bl_endpoint", ""))
	_voice.call("set_bl_api_key", _config_get("voice", "bl_api_key", ""))
	_voice.call("set_bl_model", _config_get("voice", "bl_model", ""))
	_voice.call("set_bl_voice", _config_get("voice", "bl_voice", ""))

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

	## 輸入框送出後保留 5 秒等下一輪輸入
	_input_idle_timer = Timer.new()
	_input_idle_timer.one_shot = true
	_input_idle_timer.timeout.connect(_close_input)
	add_child(_input_idle_timer)

func _open_input() -> void:
	if not _chat.call("is_enabled"):
		_show_bubble("(沒設 OPENROUTER_API_KEY 啦~)", 3.0)
		return
	if _input_idle_timer != null:
		_input_idle_timer.stop()
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
	if not _vision_enabled:
		return ""
	var path: String = _platform_temp_dir() + "/doropet_screen.png"
	var rc: int = -1
	if OS.get_name() == "macOS":
		rc = OS.execute("/usr/sbin/screencapture", ["-x", "-t", "png", "-m", path], [], false)
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
	else:
		return ""
	if rc != 0 or not FileAccess.file_exists(path):
		return ""
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var bytes: PackedByteArray = f.get_buffer(f.get_length())
	f.close()
	## 存到 logs/screenshots/YYYY-MM-DD/ 給 user 查
	var saved_path: String = DoroLogger.save_screenshot(bytes)
	if saved_path != "":
		DoroLogger.log("screenshot_captured", {"path": saved_path, "bytes": bytes.size()})
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
	## 使用者開始打字 → 中止錄音 + 取消 idle 關閉倒數
	if _voice != null and _voice.call("is_recording"):
		_voice.call("abort_recording")
	if _input_idle_timer != null:
		_input_idle_timer.stop()

func _on_submit(text: String) -> void:
	var t: String = text.strip_edges()
	if t == "":
		_close_input()
		return
	## 不立刻關輸入框 — 清空 + 起 5 秒倒數,等下一輪
	_input_box.text = ""
	_input_box.grab_focus()
	_start_input_idle_timer()
	_last_input_voice = false
	_begin_thinking()
	var img: String = ""
	if _wants_screenshot(t):
		_show_bubble("📸 Doro 在看畫面…", 999.0)
		img = _grab_screenshot_b64()
	_show_bubble("💭 Doro 正在想…", 999.0)
	_chat.call("send", t, img)

func _start_input_idle_timer() -> void:
	if _input_idle_timer != null:
		_input_idle_timer.stop()
		_input_idle_timer.start(INPUT_IDLE_SEC)

func _on_chat_reply(text: String, emotion: int) -> void:
	_end_thinking()
	_set_emotion(emotion)
	## 若 TTS 啟用:文字先壓著,等第一段語音真的開始播才顯示(跟聲音同步;
	## voicebox 生成要好幾秒)。保底 30 秒:生成掛了也要把字亮出來
	if _voice and _voice.call("is_tts_enabled"):
		_pending_bubble_text = text
		_show_bubble("🎙 Doro 醞釀聲音中…", 999.0)
		_voice.call("speak", text)
		var guard: String = text
		get_tree().create_timer(30.0).timeout.connect(func() -> void:
			if _pending_bubble_text == guard:
				_reveal_pending_bubble(999.0))
	else:
		_show_bubble(text, _bubble_seconds)
		## TTS 關閉:沒 speaking_finished signal → 手動觸發連續流程
		_on_tts_finished()

func _on_tts_started() -> void:
	_reveal_pending_bubble(999.0)   ## 開始講了 → 文字亮出來,停到講完

func _reveal_pending_bubble(seconds: float) -> void:
	if _pending_bubble_text == "":
		return
	_show_bubble(_pending_bubble_text, seconds)
	_pending_bubble_text = ""

func _on_tts_finished() -> void:
	## TTS 沒真的播出來(生成失敗/平台不支援)→ 這裡保底把字亮出來
	_reveal_pending_bubble(_bubble_seconds)
	## TTS 念完後 bubble 再停留 user 設的秒數
	if _bubble_window != null and _bubble_window.visible and not _recording_ui:
		_bubble_timer.stop()
		_bubble_timer.start(_bubble_seconds)
	## 連續對話:input 窗仍開 + 上次來源是語音 → 自動繼續錄等下一輪
	if _continuous_voice and _last_input_voice and _input_window != null and _input_window.visible:
		if _voice != null and _voice.call("has_stt") and not _voice.call("is_recording"):
			_vad_has_spoken = false
			_vad_silence_t = 0.0
			_voice.call("start_recording")
		## 起一個較長的 timeout(user 不講話超過 _continuous_timeout_sec 才真關)
		_start_continuous_timeout()

func _start_continuous_timeout() -> void:
	if _input_idle_timer != null:
		_input_idle_timer.stop()
		_input_idle_timer.start(_continuous_timeout_sec)

func _set_emotion(emo: int) -> void:
	if model == null:
		return
	## user 介入 → 取消自動 reset
	if not _setting_auto_emo and _auto_emo_reset_timer != null:
		_auto_emo_reset_timer.stop()
	## 11..14 = 動作(動畫,非 .exp3.json)
	if emo >= 11 and emo <= 14:
		_trigger_action(emo)
		return
	if emo <= 0 or not EMOTION_MAP.has(emo):
		model.call("stop_expression")
		return
	model.call("start_expression", EMOTION_MAP[emo])

func _trigger_action(action_id: int) -> void:
	_action_anim_id = action_id
	_action_anim_t = 0.0

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

func _on_chat_tool_started(name: String) -> void:
	match name:
		"take_screenshot":
			_show_bubble("📸 Doro 在看畫面…", 999.0)
		"get_weather":
			_show_bubble("☁️ Doro 查天氣中…", 999.0)
		"get_time":
			_show_bubble("⏰ Doro 看一下時間…", 999.0)
		_:
			_show_bubble("⚙️ Doro 呼叫工具中…", 999.0)

func _on_chat_thinking_resumed() -> void:
	_show_bubble("💭 Doro 正在想…", 999.0)

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
	## STT 完成 → 直接送
	_last_input_voice = true
	_show_bubble("「%s」" % text, 2.0)
	await get_tree().create_timer(0.3).timeout
	_show_bubble("💭 Doro 正在想…", 999.0)
	_chat.call("send", text)
	if _input_box != null and _input_window.visible:
		_input_box.text = ""
		## 連續對話模式:不起 idle timer,等 TTS 結束 _on_tts_finished 會自動再開錄音
		## 非連續模式:5 秒沒下一輪才關
		if not _continuous_voice:
			_start_input_idle_timer()

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
		"distill_model": _chat.call("get_distill_model"),
		"voice_engine": _voice.call("get_engine") if _voice else "local",
		"voice_api_key": _voice.call("get_api_key") if _voice else "",
		"voice_endpoint": _voice.call("get_endpoint") if _voice else "",
		"voice_model": _voice.call("get_model") if _voice else "",
		"voice_local_bin": _voice.call("get_local_bin") if _voice else "",
		"voice_local_model": _voice.call("get_local_model") if _voice else "",
		"tts_voice": _voice.call("get_voice") if _voice else "Mei-Jia",
		"tts_enabled": _voice.call("is_tts_enabled") if _voice else true,
		"tts_volume": _voice.call("get_tts_volume") if _voice else 1.0,
		"tts_backend": _voice.call("get_tts_backend") if _voice else "system",
		"vb_endpoint": _voice.call("get_vb_endpoint") if _voice else "",
		"vb_profile": _voice.call("get_vb_profile") if _voice else "",
		"vb_model_size": _voice.call("get_vb_model_size") if _voice else "0.6B",
		"bl_endpoint": _voice.call("get_bl_endpoint") if _voice else "",
		"bl_api_key": _voice.call("get_bl_api_key") if _voice else "",
		"bl_model": _voice.call("get_bl_model") if _voice else "",
		"bl_voice": _voice.call("get_bl_voice") if _voice else "",
		"hotkey_keycode": _hotkey_keycode,
		"hotkey_mods": _hotkey_mods,
		"vad_enabled": _vad_enabled,
		"vad_threshold": _vad_threshold,
		"vad_silence_sec": _vad_silence_sec,
		"continuous_voice": _continuous_voice,
		"continuous_timeout_sec": _continuous_timeout_sec,
		"msaa": _msaa,
		"auto_check_updates": _auto_check_updates,
		"vision_enabled": _vision_enabled,
		"proactive_chat_enabled": _proactive_chat_enabled,
		"proactive_chat_min_sec": _proactive_chat_min_sec,
		"proactive_chat_max_sec": _proactive_chat_max_sec,
		"proactive_prompt": _proactive_prompt,
		"proactive_prompt_default": DEFAULT_PROACTIVE_PROMPT,
		"proactive_with_screenshot": _proactive_with_screenshot,
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
	_continuous_voice = bool(data.get("continuous_voice", _continuous_voice))
	_continuous_timeout_sec = float(data.get("continuous_timeout_sec", _continuous_timeout_sec))
	var new_msaa: int = int(data.get("msaa", _msaa))
	if new_msaa != _msaa:
		_msaa = new_msaa
		_apply_msaa()
	var new_auto: bool = bool(data.get("auto_check_updates", _auto_check_updates))
	if new_auto != _auto_check_updates:
		_auto_check_updates = new_auto
		if _updater:
			if _auto_check_updates:
				_updater.call("start_polling")
			else:
				_updater.call("stop_polling")
	_vision_enabled = bool(data.get("vision_enabled", _vision_enabled))
	var new_proactive: bool = bool(data.get("proactive_chat_enabled", _proactive_chat_enabled))
	_proactive_chat_min_sec = float(data.get("proactive_chat_min_sec", _proactive_chat_min_sec))
	_proactive_chat_max_sec = float(data.get("proactive_chat_max_sec", _proactive_chat_max_sec))
	_proactive_prompt = String(data.get("proactive_prompt", _proactive_prompt))
	_proactive_with_screenshot = bool(data.get("proactive_with_screenshot", _proactive_with_screenshot))
	if new_proactive != _proactive_chat_enabled:
		_proactive_chat_enabled = new_proactive
		if _proactive_chat_enabled:
			_schedule_proactive()
		elif _proactive_timer:
			_proactive_timer.stop()
	_apply_scale()
	get_window().always_on_top = _always_on_top
	if _chat:
		_chat.call("set_api_key", data.get("api_key", ""))
		_chat.call("set_model", data.get("model", ""))
		_chat.call("set_persona", data.get("persona", ""))
		_chat.call("set_distill_model", data.get("distill_model", ""))
	if _voice:
		_voice.call("set_engine", data.get("voice_engine", "local"))
		_voice.call("set_api_key", data.get("voice_api_key", ""))
		_voice.call("set_endpoint", data.get("voice_endpoint", ""))
		_voice.call("set_model", data.get("voice_model", ""))
		_voice.call("set_local_bin", data.get("voice_local_bin", ""))
		_voice.call("set_local_model", data.get("voice_local_model", ""))
		_voice.call("set_voice", data.get("tts_voice", "Mei-Jia"))
		_voice.call("set_tts_enabled", bool(data.get("tts_enabled", true)))
		_voice.call("set_tts_volume", float(data.get("tts_volume", 1.0)))
		_voice.call("set_tts_backend", data.get("tts_backend", "system"))
		_voice.call("set_vb_endpoint", data.get("vb_endpoint", ""))
		_voice.call("set_vb_profile", data.get("vb_profile", ""))
		_voice.call("set_vb_model_size", data.get("vb_model_size", "0.6B"))
		_voice.call("set_bl_endpoint", data.get("bl_endpoint", ""))
		_voice.call("set_bl_api_key", data.get("bl_api_key", ""))
		_voice.call("set_bl_model", data.get("bl_model", ""))
		_voice.call("set_bl_voice", data.get("bl_voice", ""))
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
	_continuous_voice = bool(cfg.get_value("pet", "continuous_voice", _continuous_voice))
	_continuous_timeout_sec = float(cfg.get_value("pet", "continuous_timeout_sec", _continuous_timeout_sec))
	_msaa = int(cfg.get_value("pet", "msaa", _msaa))
	_auto_check_updates = bool(cfg.get_value("pet", "auto_check_updates", _auto_check_updates))
	_vision_enabled = bool(cfg.get_value("pet", "vision_enabled", _vision_enabled))
	_proactive_chat_enabled = bool(cfg.get_value("pet", "proactive_chat_enabled", _proactive_chat_enabled))
	_proactive_chat_min_sec = float(cfg.get_value("pet", "proactive_chat_min_sec", _proactive_chat_min_sec))
	_proactive_chat_max_sec = float(cfg.get_value("pet", "proactive_chat_max_sec", _proactive_chat_max_sec))
	_proactive_prompt = String(cfg.get_value("pet", "proactive_prompt", _proactive_prompt))
	_proactive_with_screenshot = bool(cfg.get_value("pet", "proactive_with_screenshot", _proactive_with_screenshot))

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
	cfg.set_value("pet", "continuous_voice", _continuous_voice)
	cfg.set_value("pet", "continuous_timeout_sec", _continuous_timeout_sec)
	cfg.set_value("pet", "msaa", _msaa)
	cfg.set_value("pet", "auto_check_updates", _auto_check_updates)
	cfg.set_value("pet", "vision_enabled", _vision_enabled)
	cfg.set_value("pet", "proactive_chat_enabled", _proactive_chat_enabled)
	cfg.set_value("pet", "proactive_chat_min_sec", _proactive_chat_min_sec)
	cfg.set_value("pet", "proactive_chat_max_sec", _proactive_chat_max_sec)
	cfg.set_value("pet", "proactive_prompt", _proactive_prompt)
	cfg.set_value("pet", "proactive_with_screenshot", _proactive_with_screenshot)
	if _chat:
		cfg.set_value("chat", "api_key", _chat.call("get_api_key"))
		cfg.set_value("chat", "model", _chat.call("get_model"))
		cfg.set_value("chat", "persona", _chat.call("get_persona"))
		cfg.set_value("chat", "distill_model", _chat.call("get_distill_model"))
	if _voice:
		cfg.set_value("voice", "engine", _voice.call("get_engine"))
		cfg.set_value("voice", "api_key", _voice.call("get_api_key"))
		cfg.set_value("voice", "endpoint", _voice.call("get_endpoint"))
		cfg.set_value("voice", "model", _voice.call("get_model"))
		cfg.set_value("voice", "local_bin", _voice.call("get_local_bin"))
		cfg.set_value("voice", "local_model", _voice.call("get_local_model"))
		cfg.set_value("voice", "tts_voice", _voice.call("get_voice"))
		cfg.set_value("voice", "tts_enabled", _voice.call("is_tts_enabled"))
		cfg.set_value("voice", "tts_volume", _voice.call("get_tts_volume"))
		cfg.set_value("voice", "tts_backend", _voice.call("get_tts_backend"))
		cfg.set_value("voice", "vb_endpoint", _voice.call("get_vb_endpoint"))
		cfg.set_value("voice", "vb_profile", _voice.call("get_vb_profile"))
		cfg.set_value("voice", "vb_model_size", _voice.call("get_vb_model_size"))
		cfg.set_value("voice", "bl_endpoint", _voice.call("get_bl_endpoint"))
		cfg.set_value("voice", "bl_api_key", _voice.call("get_bl_api_key"))
		cfg.set_value("voice", "bl_model", _voice.call("get_bl_model"))
		cfg.set_value("voice", "bl_voice", _voice.call("get_bl_voice"))
	cfg.save(CONFIG_PATH)
