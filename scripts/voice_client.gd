extends Node
## 語音輸入(Whisper STT) + 語音輸出(macOS say TTS)
## STT 引擎二擇一：
##   - "local": 走 whisper.cpp CLI（離線、免費、預設）
##   - "api"  : 走 OpenAI 兼容雲端 API（要 OPENAI_API_KEY）

signal transcribed(text: String)
signal stt_error(reason: String)
signal recording_started
signal recording_stopped
signal speaking_started
signal speaking_finished
signal barge_in_detected(spoken_chars: int)   ## 使用者插話時 emit,附上估算已播字元

const DEFAULT_STT_ENDPOINT: String = "https://api.openai.com/v1/audio/transcriptions"
const DEFAULT_STT_MODEL: String = "whisper-1"
const DEFAULT_LOCAL_MODEL_DIR: String = "whisper-models"            ## 相對於 user://
const TMP_WAV: String = "user://doro_record.wav"

static func default_local_bin() -> String:
	match OS.get_name():
		"macOS":   return "/opt/homebrew/bin/whisper-cli"
		"Windows": return "whisper-cli.exe"          ## 透過 PATH 找
		_:         return "whisper-cli"

var _bus_idx: int = -1
var _eff: AudioEffectCapture            ## 錄音用（不要被 meter 吃掉）
var _meter_eff: AudioEffectCapture      ## 只給音量條用
var _player: AudioStreamPlayer

## --- TTS 播放 ---
var _tts_bus_idx: int = -1
var _tts_player: AudioStreamPlayer
var _tts_spectrum: AudioEffectSpectrumAnalyzerInstance
const TTS_SR: int = 22050
const TMP_TTS_PATH: String = "user://doro_tts.wav"
var _recording: bool = false
var _sample_rate: int = 0

## --- 百炼 qwen3-asr-flash（STT 第三引擎,同步 HTTP,憑證共用百炼 TTS）---
var _asr_http: HTTPRequest
var _asr_busy: bool = false

## --- BytePlus 串流 ASR 2.0（STT 第四引擎,WebSocket,最快+繁體輸出）---
const ByteplusSTT := preload("res://scripts/byteplus_stt.gd")
var _bp_stt: Node
var _bp_asr_key: String = ""
var _stt_stream_enabled: bool = true       ## 常駐串流模式(engine=byteplus 時生效)
var _stream_acc: PackedVector2Array = PackedVector2Array()

## --- 雲端/本機生成式 TTS 後端（voicebox 本機 / bailian 雲端）---
const VoiceboxTTS := preload("res://scripts/voicebox_tts.gd")
const BailianTTS := preload("res://scripts/bailian_tts.gd")
const ByteplusTTS := preload("res://scripts/byteplus_tts.gd")
var _tts_backend: String = "system"      ## "system" | "voicebox" | "bailian" | "byteplus"
var _vb: Node
var _bl: Node
var _bp: Node
var _vb_queue: Array[String] = []        ## 已生成待播的 wav（user:// 路徑，兩後端共用）
var _vb_generating: bool = false
var _vb_started_emitted: bool = false
var _vb_pending_text: String = ""        ## 生成掛掉時 fallback 系統 TTS 用
var _last_spoken_text: String = ""       ## 最近一句正在講/剛講的話(給 STT echo 判斷用)
## 保留最近 N 句 Doro 說過的話(附時間戳);STT 有延遲,回音可能在 TTS 講完幾秒後才被辨識回來
var _recent_spoken: Array = []           ## [{text: String, ts: int}]
const RECENT_SPOKEN_KEEP: int = 8
const ECHO_WINDOW_SEC: int = 15          ## TTS 講完 15 秒內收到的相似句都當回音丟
## barge-in truncate:估算目前 TTS 已播到第幾字,讓 chat_client 把 history 尾巴 assistant 訊息截斷
var _speak_start_ms: int = 0             ## Time.get_ticks_msec() 這句 speak 開始的時間
var _speak_full_text_len: int = 0        ## 這句 speak 全文長度(中文字元計)
const SPEAK_CHARS_PER_SEC: float = 5.0   ## 平均語速估算(中文 TTS)

## 思考填充語:LLM 慢時 Doro 先「嗯~讓我想想」;首次用 TTS 真生成並存 cache,
## 之後直接播 wav 零 API 成本
const FILLER_DIR: String = "user://voice_filler/"
const FILLER_PHRASES: PackedStringArray = [
	"嗯嗯?", "唔...讓我想想喔", "欸,等一下下喔", "讓Doro想一下下~"]
var _filler_capture_path: String = ""    ## 非空 = 下一個生成的 wav 要複製進 filler cache
var _filler_player: AudioStreamPlayer    ## cached filler 用獨立 player,不觸發 speaking signals
## Filler 回音窗:filler 走獨立 player 不算 is_speaking,繞過 barge-in 那層防護,
## 而且 ASR 很容易把它誤聽成別的字(實測「讓Doro想一下下~」→「讓都讓下」),
## 字面比對擋不住 → 播放期間 + 尾窗內改用寬鬆比對,窗外不受影響。
const FILLER_ECHO_TAIL_SEC: float = 3.0  ## 播完後還要防多久(ASR 伺服器 VAD 斷句有延遲)
const FILLER_ECHO_RATIO: float = 0.4     ## 窗內的 LCS/長度 門檻(一般路徑仍是 0.5)
var _filler_echo_until_ms: int = 0       ## 回音窗結束時間;0 = 不在窗內
## 比對前要剝掉的標點(帶不帶句號會讓 LCS 比值差一截)
const ECHO_PUNCT: String = "。，、？！~,.?!…:;：；「」『』()（）〜-— \t\n"

var _engine: String = "local"        ## "local" | "api" | "bailian" | "byteplus"
var _api_key: String = ""
var _endpoint: String = DEFAULT_STT_ENDPOINT
var _model: String = DEFAULT_STT_MODEL
var _local_bin: String = ""
var _local_model: String = ""        ## 完整路徑指向 ggml-*.bin
var _voice: String = ""              ## 預設聲音(依 OS)
var _tts_enabled: bool = true
var _tts_volume: float = 1.0         ## 0..1 線性音量,套在 _tts_player 上(三後端共用)

static func default_voice() -> String:
	match OS.get_name():
		"macOS":
			## 優先挑系統實際裝的 premium 中文聲(Meijia/Sin-ji/Tingting/Yu-shu),
			## 否則拿第一個 premium voice;再不行才隨意
			var avail: Array[String] = _available_macos_voices()
			for prefer in ["Meijia", "Mei-Jia", "Tingting", "Yu-shu", "Sin-ji"]:
				if prefer in avail:
					return prefer
			if not avail.is_empty():
				return avail[0]
			return "Samantha"
		"Windows": return "Microsoft Hanhan"   ## 台繁(若未裝會 fallback default)
		_:         return ""

const DoroLogger := preload("res://scripts/logger.gd")
var _http: HTTPRequest
var _say_pid: int = -1
var _testing: bool = false              ## 測試模式：只看音量不送 STT
var _peak_rms: float = 0.0              ## 從上次拉取後的峰值 RMS
var _stt_started_ms: int = 0

func _ready() -> void:
	_api_key = OS.get_environment("OPENAI_API_KEY")
	var ep: String = OS.get_environment("OPENAI_STT_ENDPOINT")
	if ep != "":
		_endpoint = ep

	_local_bin = default_local_bin()
	_voice = default_voice()

	## 預設 local model 路徑(跨平台)
	if OS.get_name() == "Windows":
		var profile: String = OS.get_environment("USERPROFILE")
		_local_model = profile + "\\.local\\share\\doropet\\whisper-models\\ggml-base.bin"
	else:
		var home: String = OS.get_environment("HOME")
		_local_model = home + "/.local/share/doropet/whisper-models/ggml-base.bin"

	_http = HTTPRequest.new()
	_http.timeout = 60.0
	_http.request_completed.connect(_on_stt_response)
	add_child(_http)

	## 建立專用麥克風 bus
	_bus_idx = AudioServer.bus_count
	AudioServer.add_bus(_bus_idx)
	AudioServer.set_bus_name(_bus_idx, "MicCapture")
	AudioServer.set_bus_mute(_bus_idx, true)   ## 不要從喇叭聽到自己錄音
	_eff = AudioEffectCapture.new()
	_eff.buffer_length = 10.0       ## 錄音 buffer 大一點
	AudioServer.add_bus_effect(_bus_idx, _eff)
	_meter_eff = AudioEffectCapture.new()
	_meter_eff.buffer_length = 0.2  ## 只給音量條用，短 buffer 可頻繁拉
	AudioServer.add_bus_effect(_bus_idx, _meter_eff)

	_player = AudioStreamPlayer.new()
	_player.stream = AudioStreamMicrophone.new()
	_player.bus = "MicCapture"
	add_child(_player)
	_sample_rate = int(AudioServer.get_mix_rate())

	## TTS bus + spectrum analyzer（給 lipsync 用）
	_tts_bus_idx = AudioServer.bus_count
	AudioServer.add_bus(_tts_bus_idx)
	AudioServer.set_bus_name(_tts_bus_idx, "TTSBus")
	var spec: AudioEffectSpectrumAnalyzer = AudioEffectSpectrumAnalyzer.new()
	AudioServer.add_bus_effect(_tts_bus_idx, spec)
	_tts_spectrum = AudioServer.get_bus_effect_instance(_tts_bus_idx, 0) as AudioEffectSpectrumAnalyzerInstance
	_tts_player = AudioStreamPlayer.new()
	_tts_player.bus = "TTSBus"
	_tts_player.volume_db = linear_to_db(maxf(_tts_volume, 0.001))
	_tts_player.finished.connect(_on_player_finished)
	add_child(_tts_player)

	_vb = VoiceboxTTS.new()
	_vb.name = "VoiceboxTTS"
	_vb.chunk_ready.connect(_on_vb_chunk_ready)
	_vb.finished_generating.connect(_on_vb_finished_generating)
	_vb.failed_first.connect(_on_vb_failed_first)
	add_child(_vb)

	_bl = BailianTTS.new()
	_bl.name = "BailianTTS"
	_bl.chunk_ready.connect(_on_vb_chunk_ready)
	_bl.finished_generating.connect(_on_vb_finished_generating)
	_bl.failed_first.connect(_on_vb_failed_first)
	add_child(_bl)

	_asr_http = HTTPRequest.new()
	_asr_http.timeout = 20.0
	_asr_http.request_completed.connect(_on_asr_response)
	add_child(_asr_http)

	_bp_stt = ByteplusSTT.new()
	_bp_stt.name = "ByteplusSTT"
	_bp_stt.recognized.connect(_on_bp_stt_ok)
	_bp_stt.failed.connect(_on_bp_stt_fail)
	_bp_stt.utterance.connect(_on_stream_utterance)
	_bp_stt.session_changed.connect(func(up: bool) -> void:
		DoroLogger.log("stt_session", {"up": up}))
	add_child(_bp_stt)

	_bp = ByteplusTTS.new()
	_bp.name = "ByteplusTTS"
	_bp.chunk_ready.connect(_on_vb_chunk_ready)
	_bp.finished_generating.connect(_on_vb_finished_generating)
	_bp.failed_first.connect(_on_vb_failed_first)
	add_child(_bp)

	## Filler 專用 player:cached wav 直接播不觸發 speaking_* signal,
	## 免 pet.gd 誤走「真回覆播完」的 recording/bubble 邏輯造成 UI 閃爍
	_filler_player = AudioStreamPlayer.new()
	_filler_player.bus = "TTSBus"
	_filler_player.volume_db = linear_to_db(maxf(_tts_volume, 0.001))
	add_child(_filler_player)

## ---------- runtime 設定 ----------
func set_engine(e: String) -> void:
	if e in ["api", "local", "bailian", "byteplus"]:
		_engine = e
func get_engine() -> String: return _engine

func set_api_key(k: String) -> void: _api_key = k
func get_api_key() -> String: return _api_key
func set_endpoint(e: String) -> void: _endpoint = e if e.strip_edges() != "" else DEFAULT_STT_ENDPOINT
func get_endpoint() -> String: return _endpoint
func set_model(m: String) -> void: _model = m if m.strip_edges() != "" else DEFAULT_STT_MODEL
func get_model() -> String: return _model
func set_local_bin(b: String) -> void: _local_bin = b if b.strip_edges() != "" else default_local_bin()
func get_local_bin() -> String: return _local_bin
func set_local_model(p: String) -> void: _local_model = p
func get_local_model() -> String: return _local_model
func set_voice(v: String) -> void:
	## macOS: 拒收 Eloquence (含括號的低品質聲);自動改回 default premium
	if OS.get_name() == "macOS" and v.contains("("):
		_voice = default_voice()
		return
	_voice = v if v != "" else default_voice()
func get_voice() -> String: return _voice
func set_tts_enabled(b: bool) -> void: _tts_enabled = b
func is_tts_enabled() -> bool: return _tts_enabled

func set_tts_volume(v: float) -> void:
	_tts_volume = clamp(v, 0.0, 1.0)
	if _tts_player != null:
		## 0 會變 -inf dB,固定夾在 -60dB 當靜音底
		_tts_player.volume_db = linear_to_db(maxf(_tts_volume, 0.001))
func get_tts_volume() -> float: return _tts_volume

func set_tts_backend(b: String) -> void:
	if b in ["system", "voicebox", "bailian", "byteplus"]:
		_tts_backend = b
func get_tts_backend() -> String: return _tts_backend
func set_vb_endpoint(e: String) -> void:
	_vb.endpoint = e.rstrip("/") if e.strip_edges() != "" else "http://127.0.0.1:17493"
func get_vb_endpoint() -> String: return _vb.endpoint
func set_vb_profile(p: String) -> void: _vb.profile_name = p
func get_vb_profile() -> String: return _vb.profile_name
func set_vb_model_size(m: String) -> void:
	_vb.model_size = m if m.strip_edges() != "" else "0.6B"
func get_vb_model_size() -> String: return _vb.model_size
func set_bl_endpoint(e: String) -> void: _bl.endpoint = e.strip_edges().rstrip("/")
func get_bl_endpoint() -> String: return _bl.endpoint
func set_bl_api_key(k: String) -> void: _bl.api_key = k.strip_edges()
func get_bl_api_key() -> String: return _bl.api_key
func set_bl_model(m: String) -> void:
	_bl.model = m if m.strip_edges() != "" else "qwen3-tts-vc-2026-01-22"
func get_bl_model() -> String: return _bl.model
func set_bl_voice(v: String) -> void: _bl.voice = v.strip_edges()
func get_bl_voice() -> String: return _bl.voice
func set_bp_endpoint(e: String) -> void:
	_bp.endpoint = e.strip_edges().rstrip("/") if e.strip_edges() != "" else "https://voice.ap-southeast-1.bytepluses.com"
func get_bp_endpoint() -> String: return _bp.endpoint
func set_bp_app_id(a: String) -> void: _bp.app_id = a.strip_edges()
func get_bp_app_id() -> String: return _bp.app_id
func set_bp_access_token(t: String) -> void: _bp.access_token = t.strip_edges()
func get_bp_access_token() -> String: return _bp.access_token
func set_bp_cluster(c: String) -> void:
	_bp.cluster = c.strip_edges() if c.strip_edges() != "" else "volcano_icl"
func get_bp_cluster() -> String: return _bp.cluster
func set_bp_speaker(s: String) -> void: _bp.speaker = s.strip_edges()
func get_bp_speaker() -> String: return _bp.speaker
func set_bp_asr_key(k: String) -> void:
	_bp_asr_key = k.strip_edges()
	if _bp_stt != null:
		_bp_stt.api_key = _bp_asr_key
func get_bp_asr_key() -> String: return _bp_asr_key
## 常駐串流:錄音期間音訊持續推送,伺服器 VAD 斷句即時回 utterance
func is_stt_stream() -> bool:
	return _stt_stream_enabled and _engine == "byteplus" and _bp_asr_key != ""

func _on_stream_utterance(text: String) -> void:
	## Filler 回音優先擋:filler 不算 is_speaking,繞過下面的 barge-in 過濾,
	## 而且誤聽後字面對不上一般門檻(「讓Doro想一下下~」→「讓都讓下」)
	if _in_filler_echo_window():
		var fm: String = _match_filler_echo(text)
		if fm != "":
			DoroLogger.log("stt_filler_echo_dropped", {
				"text": text.substr(0, 60), "matched": fm})
			return
	## Echo 檢查不再依賴 is_speaking:STT 有延遲,TTS 講完後幾秒內收到的相似句仍算回音
	var matched: String = _match_recent_spoken(text)
	if matched != "":
		DoroLogger.log("stt_echo_dropped", {"text": text.substr(0, 60),
			"matched": matched.substr(0, 60)})
		return
	if is_speaking():
		## Doro 講話中,判斷是否真的插話:
		##   - 短於 4 字元 → 多半是背景音被 STT 誤辨識,不 barge
		##   - 「嗯/哦/欸/好」等單字附和 → 不 barge(這是主人自然應答,不要中斷 Doro)
		var stripped: String = text.strip_edges()
		var is_short_noise: bool = stripped.length() < 4
		var backchannels: PackedStringArray = ["嗯", "嗯嗯", "哦", "喔", "欸", "誒",
			"好", "好的", "對", "对", "是", "是的", "哈", "哈哈", "哦哦"]
		var is_backchannel: bool = backchannels.has(stripped)
		if is_short_noise or is_backchannel:
			DoroLogger.log("barge_ignored", {"text": stripped,
				"reason": "backchannel" if is_backchannel else "short_noise"})
			return
		## 不是回音又在講話 → 主人真的插話
		var spoken_chars: int = get_spoken_chars_estimate()
		DoroLogger.log("barge_in_utter", {"text": text.substr(0, 60),
			"spoken_chars": spoken_chars})
		barge_in_detected.emit(spoken_chars)   ## 讓 pet.gd truncate history
		stop_speaking()
		flush_recording_buffer()
	DoroLogger.log("stt_response", {"engine": "byteplus_stream", "text": text,
		"latency_ms": 0})
	transcribed.emit(text)

## 在最近 ECHO_WINDOW_SEC 秒內講過的話裡找相似的;找到就回傳那句話,沒找到回 ""
func _match_recent_spoken(utter: String) -> String:
	if _recent_spoken.is_empty():
		return ""
	var u: String = utter.strip_edges()
	if u == "":
		return ""
	var now: int = int(Time.get_unix_time_from_system())
	for entry in _recent_spoken:
		var age: int = now - int(entry.get("ts", 0))
		if age > ECHO_WINDOW_SEC:
			continue
		var s: String = String(entry.get("text", "")).strip_edges()
		if s == "":
			continue
		if _is_echo_pair(u, s):
			return s
	return ""

func _is_echo_pair(u: String, s: String) -> bool:
	## 短句(< 6 字元):嚴格 substring,免「嗯/好/對」誤傷
	if u.length() < 6:
		return s.contains(u)
	## 一般句:LCS/utter 長度 ≥ 0.5 算回音(容忍標點差、繁簡轉換、STT 錯字)
	var ov: int = _lcs_len(u.substr(0, 40), s.substr(0, 80))
	return float(ov) / float(u.length()) >= 0.5

## O(n*m) LCS;n,m 受限 40/80,可接受
func _lcs_len(a: String, b: String) -> int:
	var n: int = a.length()
	var m: int = b.length()
	if n == 0 or m == 0:
		return 0
	var w: int = m + 1
	var dp: PackedInt32Array = PackedInt32Array()
	dp.resize((n + 1) * w)
	for i in n:
		for j in m:
			if a.substr(i, 1) == b.substr(j, 1):
				dp[(i + 1) * w + (j + 1)] = dp[i * w + j] + 1
			else:
				dp[(i + 1) * w + (j + 1)] = maxi(
					dp[i * w + (j + 1)],
					dp[(i + 1) * w + j])
	return dp[n * w + m]

func _process(_dt: float) -> void:
	## 串流泵浦:錄音中把 mic buffer 每 ~200ms 推給常駐 ASR session
	if not _recording or not is_stt_stream() or _bp_stt == null:
		return
	if not bool(_bp_stt.call("is_session_up")):
		return
	var n: int = _eff.get_frames_available()
	if n > 0:
		_stream_acc.append_array(_eff.get_buffer(n))
	if _stream_acc.size() < int(_sample_rate * 0.2):
		return
	var pcm: PackedVector2Array = _resample(_stream_acc, _sample_rate, 16000)
	_stream_acc = PackedVector2Array()
	var bytes: PackedByteArray = PackedByteArray()
	bytes.resize(pcm.size() * 2)
	for i in pcm.size():
		bytes.encode_s16(i * 2, int(round(clamp(pcm[i].x, -1.0, 1.0) * 32767.0)))
	_bp_stt.call("session_push", bytes)

func set_stt_hotwords(s: String) -> void:
	## 逗號/頓號分隔的熱詞清單
	var words: PackedStringArray = []
	for w in s.replace("、", ",").replace("，", ",").split(","):
		if w.strip_edges() != "":
			words.append(w.strip_edges())
	if _bp_stt != null:
		_bp_stt.hotwords = words
func get_stt_hotwords() -> String:
	return "、".join(_bp_stt.hotwords) if _bp_stt != null else ""

func is_recording() -> bool: return _recording

## 清掉錄音 buffer 但不停止錄音(插話打斷時沖掉 Doro 自己的殘響)
func flush_recording_buffer() -> void:
	if _eff != null:
		_eff.clear_buffer()

## ---------- 思考填充語 ----------
## LLM 還在想時播一句短語掩蓋延遲。回傳是否真的播了。
func speak_filler() -> bool:
	if not _tts_enabled or is_speaking():
		return false
	var idx: int = randi() % FILLER_PHRASES.size()
	var phrase: String = FILLER_PHRASES[idx]
	var cache_path: String = FILLER_DIR + "filler_%d.wav" % idx
	if FileAccess.file_exists(cache_path):
		## cache 命中:走獨立 _filler_player,不 emit speaking_* signals,
		## 避免 pet.gd 觸發錄音/bubble 邏輯造成 UI 閃爍
		var stream: AudioStreamWAV = _load_wav_as_stream(
			ProjectSettings.globalize_path(cache_path))
		if stream == null:
			return false
		_recent_spoken.append({"text": phrase, "ts": int(Time.get_unix_time_from_system())})
		if _recent_spoken.size() > RECENT_SPOKEN_KEEP:
			_recent_spoken = _recent_spoken.slice(_recent_spoken.size() - RECENT_SPOKEN_KEEP)
		_filler_player.stream = stream
		_filler_player.play()
		_open_filler_echo_window(stream.get_length())
		DoroLogger.log("filler_play", {"idx": idx, "cached": true})
		return true
	## 沒 cache → 真 TTS 生成一次(只發生首輪),同時把 wav 捕捉進 cache
	DoroLogger.log("filler_play", {"idx": idx, "cached": false})
	speak(phrase)
	## 這條路徑拿不到音檔長度,用語速估(只發生首輪,估不準也還有 3 秒尾窗兜著)
	_open_filler_echo_window(float(phrase.length()) / SPEAK_CHARS_PER_SEC)
	_filler_capture_path = cache_path
	return true

## 開啟 filler 回音窗:播放長度 + 尾窗
func _open_filler_echo_window(play_sec: float) -> void:
	_filler_echo_until_ms = Time.get_ticks_msec() + int(
		(maxf(play_sec, 0.0) + FILLER_ECHO_TAIL_SEC) * 1000.0)

func _in_filler_echo_window() -> bool:
	return _filler_echo_until_ms > 0 and Time.get_ticks_msec() < _filler_echo_until_ms

## 剝掉標點與空白:「讓都讓下。」帶句號是 5 字比值 0.4,剝掉是 4 字比值 0.5,
## 差一個標點就決定攔不攔得住,比對前一律先剝
static func _strip_punct(s: String) -> String:
	var out: String = ""
	for i in range(s.length()):
		var ch: String = s[i]
		if not ECHO_PUNCT.contains(ch):
			out += ch
	return out

## 窗內比對:拿 utterance 直接跟 4 句 filler 比(不查 _recent_spoken,
## cache 命中/miss 兩條路徑都蓋得到)。命中回傳那句 filler,沒中回 ""
func _match_filler_echo(utter: String) -> String:
	var u: String = _strip_punct(utter)
	if u == "":
		return ""
	for p in FILLER_PHRASES:
		var s: String = _strip_punct(p)
		if s == "":
			continue
		var ov: int = _lcs_len(u.substr(0, 40), s.substr(0, 80))
		if float(ov) / float(u.length()) >= FILLER_ECHO_RATIO:
			return p
	return ""

## TTS 生成出 wav 時,若正等著捕捉 filler → 複製一份進 cache
func _maybe_capture_filler(src_path: String) -> void:
	if _filler_capture_path == "":
		return
	var dst: String = _filler_capture_path
	_filler_capture_path = ""
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(FILLER_DIR))
	var abs_src: String = src_path
	if src_path.begins_with("user://") or src_path.begins_with("res://"):
		abs_src = ProjectSettings.globalize_path(src_path)
	var err: int = DirAccess.copy_absolute(abs_src, ProjectSettings.globalize_path(dst))
	DoroLogger.log("filler_cached", {"dst": dst, "err": err})

## barge-in 用:估算「主人打斷時,Doro TTS 已播到第幾字」
## 用平均語速 × 經過時間;不精確但夠 truncate history 用
func get_spoken_chars_estimate() -> int:
	if _speak_start_ms <= 0 or _speak_full_text_len <= 0:
		return 0
	var elapsed_sec: float = float(Time.get_ticks_msec() - _speak_start_ms) / 1000.0
	var estimated: int = int(round(elapsed_sec * SPEAK_CHARS_PER_SEC))
	return clamp(estimated, 0, _speak_full_text_len)

## ---------- 系統聲音輸入(loopback) ----------
var _capture_system_audio: bool = false
var _mic_device_backup: String = ""   ## 開啟前的麥克風,關閉時還原

## 找系統上的 loopback 虛擬裝置(BlackHole / Soundflower / Background Music 等)
func find_loopback_device() -> String:
	for d in AudioServer.get_input_device_list():
		var low: String = String(d).to_lower()
		for key in ["blackhole", "loopback", "soundflower", "background music", "aggregate", "聚集"]:
			if low.contains(key):
				return d
	return ""

func set_capture_system_audio(b: bool) -> void:
	if b == _capture_system_audio:
		return
	_capture_system_audio = b
	if b:
		var loop_dev: String = find_loopback_device()
		if loop_dev == "":
			_capture_system_audio = false   ## 沒裝虛擬裝置,不硬切
			return
		_mic_device_backup = AudioServer.input_device
		AudioServer.input_device = loop_dev
	else:
		if _mic_device_backup != "":
			AudioServer.input_device = _mic_device_backup
		else:
			AudioServer.input_device = "Default"

func is_capture_system_audio() -> bool:
	return _capture_system_audio

## ---------- 麥克風裝置 ----------
func list_input_devices() -> Array:
	return AudioServer.get_input_device_list()

func get_input_device() -> String:
	return AudioServer.input_device

func set_input_device(name: String) -> void:
	if name.strip_edges() != "":
		AudioServer.input_device = name

## 拿從上次呼叫到現在的 peak RMS (0..1)
func consume_rms() -> float:
	if _meter_eff == null:
		return 0.0
	var n: int = _meter_eff.get_frames_available()
	if n > 0:
		var fr: PackedVector2Array = _meter_eff.get_buffer(n)
		var sum: float = 0.0
		for v in fr:
			sum += v.x * v.x
		var rms: float = sqrt(sum / max(1, fr.size()))
		_peak_rms = max(_peak_rms, rms)
	var r: float = _peak_rms
	_peak_rms *= 0.6   ## 衰減
	return r

## 測試麥克風（不上傳，只 capture 拿音量）
func start_test() -> void:
	if _recording or _testing:
		return
	_eff.clear_buffer()
	_player.play()
	_testing = true

func stop_test() -> void:
	if not _testing:
		return
	_testing = false
	_player.stop()
	_eff.clear_buffer()
	_peak_rms = 0.0

func is_testing() -> bool:
	return _testing

func stt_status() -> String:
	if _engine == "local":
		if not FileAccess.file_exists(_local_model):
			return "本地：找不到模型 %s" % _local_model
		return "本地 whisper.cpp (%s)" % _local_model.get_file()
	if _engine == "bailian":
		if _bl == null or _bl.api_key == "" or _bl.endpoint == "":
			return "百炼：未設定（沿用 TTS 的百炼 Endpoint/Key）"
		return "百炼 qwen3-asr-flash"
	if _engine == "byteplus":
		if _bp_asr_key == "":
			return "BytePlus：未設定 API Key"
		return "BytePlus 串流 ASR 2.0"
	if _api_key == "":
		return "雲端：未設定 OPENAI_API_KEY"
	return "雲端 %s" % _model

func has_stt() -> bool:
	if _engine == "local":
		return FileAccess.file_exists(_local_model) and FileAccess.file_exists(_local_bin)
	if _engine == "bailian":
		return _bl != null and _bl.api_key != "" and _bl.endpoint != ""
	if _engine == "byteplus":
		return _bp_asr_key != ""
	return _api_key != ""

## ---------- 錄音 ----------
func start_recording() -> bool:
	if _recording:
		return false
	if not has_stt():
		stt_error.emit("沒設 OPENAI_API_KEY（語音轉文字用）")
		return false
	_eff.clear_buffer()
	_stream_acc = PackedVector2Array()
	_player.play()
	_recording = true
	if is_stt_stream() and not bool(_bp_stt.call("is_session_up")):
		_bp_stt.call("session_start")   ## 常駐 ASR 連線隨錄音開啟
	recording_started.emit()
	return true

func abort_recording() -> void:
	if not _recording:
		return
	_recording = false
	_player.stop()
	_eff.clear_buffer()
	if _bp_stt != null and bool(_bp_stt.call("is_session_up")):
		_bp_stt.call("session_stop")   ## 錄音結束就斷 ASR 連線(按時長計費)
	recording_stopped.emit()

func stop_and_send() -> void:
	if not _recording:
		return
	if is_stt_stream() and bool(_bp_stt.call("is_session_up")):
		## 串流模式:句子由伺服器 VAD 即時斷,手動送出=結束錄音即可
		abort_recording()
		return
	_recording = false
	_player.stop()
	recording_stopped.emit()
	var frames: PackedVector2Array = _eff.get_buffer(_eff.get_frames_available())
	if frames.size() < _sample_rate / 4:    ## < 0.25 秒 → 略過
		stt_error.emit("錄音太短了")
		return
	## whisper 要 16k mono；如果 mix_rate 不是 16000 先降採樣
	var target_sr: int = 16000
	var pcm: PackedVector2Array = frames
	if _sample_rate != target_sr:
		pcm = _resample(frames, _sample_rate, target_sr)
	var wav: PackedByteArray = _frames_to_wav(pcm, target_sr)
	var f: FileAccess = FileAccess.open(TMP_WAV, FileAccess.WRITE)
	if f == null:
		stt_error.emit("無法寫入暫存檔")
		return
	f.store_buffer(wav)
	f.close()
	_stt_started_ms = Time.get_ticks_msec()
	var audio_sec: float = float(frames.size()) / float(_sample_rate)
	DoroLogger.log("stt_request", {"engine": _engine, "audio_sec": audio_sec})
	if _engine == "local":
		_run_local_whisper(ProjectSettings.globalize_path(TMP_WAV))
	elif _engine == "bailian":
		_submit_bailian_asr(wav)
	elif _engine == "byteplus":
		_bp_stt.call("start", wav)
	else:
		_upload_wav(wav)

## 簡單線性插值降採樣（44k1 / 48k → 16k）
func _resample(src: PackedVector2Array, from_sr: int, to_sr: int) -> PackedVector2Array:
	if from_sr == to_sr:
		return src
	var ratio: float = float(from_sr) / float(to_sr)
	var out_n: int = int(float(src.size()) / ratio)
	var out: PackedVector2Array = PackedVector2Array()
	out.resize(out_n)
	for i in out_n:
		var sx: float = float(i) * ratio
		var i0: int = int(floor(sx))
		var i1: int = min(i0 + 1, src.size() - 1)
		var t: float = sx - float(i0)
		out[i] = src[i0].lerp(src[i1], t)
	return out

## ---------- 本地 whisper.cpp ----------
func _run_local_whisper(wav_path: String) -> void:
	if not FileAccess.file_exists(_local_bin):
		stt_error.emit("找不到 whisper-cli: %s（brew install whisper-cpp）" % _local_bin)
		return
	if not FileAccess.file_exists(_local_model):
		stt_error.emit("找不到 model: %s" % _local_model)
		return
	## 非阻塞背景 thread 跑（用 Godot Callable + Thread）
	var t: Thread = Thread.new()
	t.start(_local_whisper_thread.bind(wav_path, _local_bin, _local_model))

func _local_whisper_thread(wav_path: String, bin: String, model_path: String) -> void:
	var out: Array = []
	var args: PackedStringArray = [
		"-m", model_path,
		"-f", wav_path,
		"-nt",                ## no timestamps
		"-l", "auto",
		"--no-prints",
	]
	## 第四參數 read_stderr=false → 只收 stdout(過濾掉 BLAS/Metal init 訊息)
	var rc: int = OS.execute(bin, args, out, false)
	var raw: String = ""
	for s in out:
		raw += String(s)
	## 再過濾 whisper 常見 artifact tag
	var text: String = raw.strip_edges()
	var noise: PackedStringArray = ["[BLANK_AUDIO]", "[MUSIC]", "[NOISE]", "[_BEG_]", "[_TT_0]"]
	for n in noise:
		text = text.replace(n, "")
	## 去掉行首/行尾空白與括號內的描述
	text = text.strip_edges()
	call_deferred("_emit_local_result", rc, text)

func _emit_local_result(rc: int, text: String) -> void:
	var lat: int = Time.get_ticks_msec() - _stt_started_ms
	if rc != 0:
		DoroLogger.log("stt_error", {"engine": "local", "reason": "rc=%d" % rc, "latency_ms": lat})
		stt_error.emit("whisper-cli 退出碼 %d" % rc)
		return
	if text == "":
		DoroLogger.log("stt_error", {"engine": "local", "reason": "empty", "latency_ms": lat})
		stt_error.emit("沒辨識到內容")
		return
	DoroLogger.log("stt_response", {"engine": "local", "text": text, "latency_ms": lat})
	transcribed.emit(text)

## PCM frames(Vector2，-1~1) → 16-bit mono WAV
func _frames_to_wav(frames: PackedVector2Array, sr: int) -> PackedByteArray:
	var n: int = frames.size()
	var data_size: int = n * 2          ## 16-bit mono
	var buf: PackedByteArray = PackedByteArray()
	buf.resize(44 + data_size)
	## RIFF header
	buf.encode_u8(0, 0x52); buf.encode_u8(1, 0x49); buf.encode_u8(2, 0x46); buf.encode_u8(3, 0x46)  ## "RIFF"
	buf.encode_u32(4, 36 + data_size)
	buf.encode_u8(8, 0x57); buf.encode_u8(9, 0x41); buf.encode_u8(10, 0x56); buf.encode_u8(11, 0x45)  ## "WAVE"
	buf.encode_u8(12, 0x66); buf.encode_u8(13, 0x6d); buf.encode_u8(14, 0x74); buf.encode_u8(15, 0x20)  ## "fmt "
	buf.encode_u32(16, 16)               ## subchunk size
	buf.encode_u16(20, 1)                ## PCM
	buf.encode_u16(22, 1)                ## mono
	buf.encode_u32(24, sr)
	buf.encode_u32(28, sr * 2)           ## byte rate
	buf.encode_u16(32, 2)                ## block align
	buf.encode_u16(34, 16)               ## bits per sample
	buf.encode_u8(36, 0x64); buf.encode_u8(37, 0x61); buf.encode_u8(38, 0x74); buf.encode_u8(39, 0x61)  ## "data"
	buf.encode_u32(40, data_size)
	## samples（取左聲道）
	for i in n:
		var s: float = clamp(frames[i].x, -1.0, 1.0)
		var v: int = int(round(s * 32767.0))
		buf.encode_s16(44 + i * 2, v)
	return buf

## ---------- BytePlus 串流 ASR callback ----------
func _on_bp_stt_ok(text: String) -> void:
	var lat: int = Time.get_ticks_msec() - _stt_started_ms
	if text == "":
		DoroLogger.log("stt_error", {"engine": "byteplus", "reason": "empty", "latency_ms": lat})
		stt_error.emit("沒辨識到內容")
		return
	DoroLogger.log("stt_response", {"engine": "byteplus", "text": text, "latency_ms": lat})
	transcribed.emit(text)

func _on_bp_stt_fail(reason: String) -> void:
	DoroLogger.log("stt_error", {"engine": "byteplus", "reason": reason,
		"latency_ms": Time.get_ticks_msec() - _stt_started_ms})
	stt_error.emit("BytePlus ASR: " + reason)

## ---------- 百炼 qwen3-asr-flash（同步 HTTP,一來一回,實測 ~1.3s）----------
func _submit_bailian_asr(wav: PackedByteArray) -> void:
	_asr_busy = true
	var body: String = JSON.stringify({
		"model": "qwen3-asr-flash",
		"input": {"messages": [{"role": "user", "content": [
			{"audio": "data:audio/wav;base64," + Marshalls.raw_to_base64(wav)},
		]}]},
		"parameters": {"asr_options": {"enable_itn": true}},
	})
	var headers: PackedStringArray = [
		"Authorization: Bearer " + String(_bl.api_key),
		"Content-Type: application/json",
	]
	var err: int = _asr_http.request(
		String(_bl.endpoint).rstrip("/") + "/api/v1/services/aigc/multimodal-generation/generation",
		headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		_asr_busy = false
		stt_error.emit("百炼 ASR 送出失敗 (err=%d)" % err)

func _on_asr_response(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
	if not _asr_busy:
		return
	_asr_busy = false
	var lat: int = Time.get_ticks_msec() - _stt_started_ms
	if result != HTTPRequest.RESULT_SUCCESS:
		DoroLogger.log("stt_error", {"engine": "bailian", "reason": "network %d" % result, "latency_ms": lat})
		stt_error.emit("百炼 ASR 網路錯誤 (result=%d)" % result)
		return
	var raw: String = body.get_string_from_utf8()
	if code < 200 or code >= 300:
		DoroLogger.log("stt_error", {"engine": "bailian", "reason": "HTTP %d" % code, "body": raw.substr(0, 200), "latency_ms": lat})
		stt_error.emit("百炼 ASR HTTP %d: %s" % [code, raw.substr(0, 150)])
		return
	## output.choices[0].message.content[0].text
	var text: String = ""
	var parsed: Variant = JSON.parse_string(raw)
	if typeof(parsed) == TYPE_DICTIONARY:
		var choices: Array = ((parsed as Dictionary).get("output", {}) as Dictionary).get("choices", [])
		if not choices.is_empty():
			var content: Array = (choices[0].get("message", {}) as Dictionary).get("content", [])
			for c in content:
				if typeof(c) == TYPE_DICTIONARY and c.has("text"):
					text += String(c["text"])
	text = text.strip_edges()
	if text == "":
		DoroLogger.log("stt_error", {"engine": "bailian", "reason": "empty", "latency_ms": lat})
		stt_error.emit("沒辨識到內容")
		return
	DoroLogger.log("stt_response", {"engine": "bailian", "text": text, "latency_ms": lat})
	transcribed.emit(text)

## ---------- Whisper multipart upload ----------
func _upload_wav(wav: PackedByteArray) -> void:
	var boundary: String = "----DoroPetBoundary%dXyZ" % Time.get_ticks_msec()
	var crlf: String = "\r\n"
	var body: PackedByteArray = PackedByteArray()
	var prefix: String = ""
	prefix += "--" + boundary + crlf
	prefix += 'Content-Disposition: form-data; name="model"' + crlf + crlf
	prefix += _model + crlf
	prefix += "--" + boundary + crlf
	prefix += 'Content-Disposition: form-data; name="response_format"' + crlf + crlf
	prefix += "json" + crlf
	prefix += "--" + boundary + crlf
	prefix += 'Content-Disposition: form-data; name="file"; filename="speech.wav"' + crlf
	prefix += "Content-Type: audio/wav" + crlf + crlf
	body.append_array(prefix.to_utf8_buffer())
	body.append_array(wav)
	body.append_array((crlf + "--" + boundary + "--" + crlf).to_utf8_buffer())

	var headers: PackedStringArray = [
		"Authorization: Bearer " + _api_key,
		"Content-Type: multipart/form-data; boundary=" + boundary,
	]
	var err: int = _http.request_raw(_endpoint, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		stt_error.emit("HTTPRequest 啟動失敗: %d" % err)

func _on_stt_response(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
	var lat: int = Time.get_ticks_msec() - _stt_started_ms
	if result != HTTPRequest.RESULT_SUCCESS:
		DoroLogger.log("stt_error", {"engine": "api", "reason": "network %d" % result, "latency_ms": lat})
		stt_error.emit("網路錯誤 (result=%d)" % result)
		return
	var txt: String = body.get_string_from_utf8()
	if code < 200 or code >= 300:
		DoroLogger.log("stt_error", {"engine": "api", "reason": "HTTP %d" % code, "body": txt.substr(0, 300), "latency_ms": lat})
		stt_error.emit("STT HTTP %d: %s" % [code, txt.substr(0, 200)])
		return
	var parsed: Variant = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_DICTIONARY or not (parsed as Dictionary).has("text"):
		DoroLogger.log("stt_error", {"engine": "api", "reason": "bad json", "latency_ms": lat})
		stt_error.emit("STT 回覆格式異常")
		return
	var text: String = String((parsed as Dictionary)["text"]).strip_edges()
	if text == "":
		DoroLogger.log("stt_error", {"engine": "api", "reason": "empty", "latency_ms": lat})
		stt_error.emit("沒辨識到內容")
		return
	DoroLogger.log("stt_response", {"engine": "api", "text": text, "latency_ms": lat})
	transcribed.emit(text)

## ---------- TTS (寫 WAV → Godot 內部播放 → spectrum lipsync) ----------
## macOS:  /usr/bin/say
## Windows: PowerShell System.Speech.Synthesis
func speak(text: String) -> void:
	if not _tts_enabled or text.strip_edges() == "":
		return
	stop_speaking()
	_last_spoken_text = text
	_recent_spoken.append({"text": text, "ts": int(Time.get_unix_time_from_system())})
	if _recent_spoken.size() > RECENT_SPOKEN_KEEP:
		_recent_spoken = _recent_spoken.slice(_recent_spoken.size() - RECENT_SPOKEN_KEEP)
	_speak_start_ms = Time.get_ticks_msec()
	_speak_full_text_len = text.length()
	if _tts_backend != "system":
		_vb_pending_text = text
		_vb_generating = true
		_vb_started_emitted = false
		var gen: Node = {"voicebox": _vb, "bailian": _bl, "byteplus": _bp}[_tts_backend]
		gen.call("start", text)
		return
	_speak_system(text)

func _speak_system(text: String) -> void:
	if OS.get_name() != "macOS" and OS.get_name() != "Windows":
		return
	var t: Thread = Thread.new()
	t.start(_tts_thread.bind(text, _voice))

## ---------- Voicebox 佇列播放 ----------
func _on_vb_chunk_ready(path: String, _idx: int) -> void:
	_maybe_capture_filler(path)
	_vb_queue.append(path)
	if not _tts_player.playing:
		_play_next_vb()

func _on_vb_finished_generating(_ok_count: int) -> void:
	_vb_generating = false
	## 全生成完且播完 → 收工（邊播邊生成時由 _on_player_finished 收）
	if _vb_queue.is_empty() and not _tts_player.playing:
		_finish_speaking()

func _on_vb_failed_first(reason: String) -> void:
	## 第一段就失敗（多半是 Voicebox 沒開）→ fallback 系統 TTS
	_vb_generating = false
	_vb_queue.clear()
	DoroLogger.log("tts_vb_fallback", {"reason": reason})
	_speak_system(_vb_pending_text)

func _play_next_vb() -> void:
	while not _vb_queue.is_empty():
		var path: String = _vb_queue.pop_front()
		var stream: AudioStreamWAV = _load_wav_as_stream(ProjectSettings.globalize_path(path))
		if stream == null:
			continue
		_tts_player.stream = stream
		_tts_player.play()
		if not _vb_started_emitted:
			_vb_started_emitted = true
			speaking_started.emit()
		return
	## 佇列空了；若也不再生成 → 收工
	if not _vb_generating:
		_finish_speaking()

func _on_player_finished() -> void:
	if _tts_backend != "system" and (_vb_generating or not _vb_queue.is_empty()):
		_play_next_vb()
		return
	_finish_speaking()

func _finish_speaking() -> void:
	speaking_finished.emit()

func _tts_thread(text: String, voice: String) -> void:
	var tmp: String = ProjectSettings.globalize_path(TMP_TTS_PATH)
	if OS.get_name() == "macOS":
		var args: PackedStringArray = [
			"-v", voice,
			"-o", tmp,
			"--file-format=WAVE",
			"--data-format=LEI16@%d" % TTS_SR,
			text,
		]
		OS.execute("/usr/bin/say", args, [], false)
	elif OS.get_name() == "Windows":
		var ps_path: String = tmp.replace("/", "\\")
		## 對單引號跟換行做最小 escape(text 內若含則破)
		var safe_text: String = text.replace("'", "''").replace("`r", "").replace("\n", " ")
		var script: String = (
			"Add-Type -AssemblyName System.Speech;" +
			"$s=New-Object System.Speech.Synthesis.SpeechSynthesizer;" +
			## 嘗試挑指定聲音,找不到就用預設
			"try { $s.SelectVoice('%s') } catch {};" +
			"$s.SetOutputToWaveFile('%s');" +
			"$s.Speak('%s');" +
			"$s.Dispose();") % [voice, ps_path, safe_text]
		OS.execute("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", script], [], false)
	call_deferred("_play_tts_file", tmp)

func _play_tts_file(path: String) -> void:
	_maybe_capture_filler(path)
	var stream: AudioStreamWAV = _load_wav_as_stream(path)
	if stream == null:
		speaking_finished.emit()
		return
	_tts_player.stream = stream
	_tts_player.play()
	speaking_started.emit()

## 解析 WAV 找 "data" chunk，建 AudioStreamWAV
func _load_wav_as_stream(path: String) -> AudioStreamWAV:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var data: PackedByteArray = f.get_buffer(f.get_length())
	f.close()
	if data.size() < 44:
		return null
	## 先掃 fmt chunk 拿實際取樣率/聲道（say 是 22050、voicebox 是 24000）
	var sr: int = TTS_SR
	var channels: int = 1
	var i: int = 12
	while i < data.size() - 8:
		var chunk_id: String = data.slice(i, i + 4).get_string_from_ascii()
		var chunk_size: int = data.decode_u32(i + 4)
		if chunk_id == "fmt " and chunk_size >= 16:
			channels = data.decode_u16(i + 10)
			sr = data.decode_u32(i + 12)
		elif chunk_id == "data":
			var pcm: PackedByteArray = data.slice(i + 8, i + 8 + chunk_size)
			var s: AudioStreamWAV = AudioStreamWAV.new()
			s.format = AudioStreamWAV.FORMAT_16_BITS
			s.mix_rate = sr
			s.stereo = channels >= 2
			s.data = pcm
			return s
		i += 8 + chunk_size + (chunk_size & 1)   ## RIFF chunk 奇數長度會補 1 byte
	return null

## 給 pet.gd 用：當前 TTS 音訊在人聲頻段的能量 (0..1)
func get_tts_mouth_level() -> float:
	if _tts_spectrum == null or _tts_player == null or not _tts_player.playing:
		return 0.0
	var mag: Vector2 = _tts_spectrum.get_magnitude_for_frequency_range(
		80.0, 1200.0, AudioEffectSpectrumAnalyzerInstance.MAGNITUDE_AVERAGE)
	## linear scale → 放大到視覺顯著範圍
	return clamp(mag.length() * 36.0, 0.0, 1.0)

func is_speaking() -> bool:
	if _tts_player != null and _tts_player.playing:
		return true
	if _filler_player != null and _filler_player.playing:
		return true
	return _vb_generating or not _vb_queue.is_empty()

## 播放預先生成的靜態 wav(idle 語音、按鈕音效等)。
## 忙碌中就跳過並回 false;成功會發 speaking_started,播完發 speaking_finished。
func play_static_wav(path: String) -> bool:
	if is_speaking():
		return false
	if _tts_player == null:
		return false
	var stream: AudioStreamWAV = _load_wav_as_stream(path)
	if stream == null:
		return false
	_tts_player.stream = stream
	_tts_player.play()
	speaking_started.emit()
	return true

func stop_speaking() -> void:
	## filler 生成中被打斷 → 取消捕捉,免得把下一句真回覆誤存成 filler
	_filler_capture_path = ""
	if _filler_player != null and _filler_player.playing:
		_filler_player.stop()
	if _vb != null:
		_vb.call("cancel")
	if _bl != null:
		_bl.call("cancel")
	if _bp != null:
		_bp.call("cancel")
	_vb_generating = false
	_vb_queue.clear()
	if _tts_player != null and _tts_player.playing:
		_tts_player.stop()

## 跨平台 TTS 聲音建議名(直接顯示在設定下拉)
## macOS: 動態 query say -v ? 取得系統實際裝的聲音
## Windows: 動態 query SpeechSynthesizer.GetInstalledVoices()
static func suggested_voices() -> Array[String]:
	if OS.get_name() == "macOS":
		return _available_macos_voices()
	if OS.get_name() == "Windows":
		return _available_windows_voices()
	return []

static func _available_macos_voices() -> Array[String]:
	## 解析 say -v ? → 兩組:premium(無括號,品質好) + eloquence(含括號,1980s 合成器品質差)
	## 預設只回 premium;若系統完全沒裝 premium 才 fallback eloquence
	var premium: Array[String] = []
	var eloquence: Array[String] = []
	var lines: Array = []
	var err: int = OS.execute("/usr/bin/say", ["-v", "?"], lines, false)
	if err != 0 or lines.is_empty():
		return ["Samantha"]
	var raw: String = String(lines[0])
	for ln in raw.split("\n"):
		var s: String = String(ln).strip_edges()
		if s == "":
			continue
		var hash_idx: int = s.find("#")
		var pre: String = s if hash_idx < 0 else s.substr(0, hash_idx)
		var parts: PackedStringArray = pre.split(" ", false)
		if parts.size() < 2:
			continue
		var name_parts: PackedStringArray = parts.slice(0, parts.size() - 1)
		var name: String = " ".join(name_parts).strip_edges()
		if name == "":
			continue
		## 含「(」一律視為 Eloquence(macOS 14+ 輕量低品質,1980s 合成風)
		if name.contains("("):
			if not eloquence.has(name):
				eloquence.append(name)
		else:
			if not premium.has(name):
				premium.append(name)
	premium.sort()
	if premium.is_empty():
		eloquence.sort()
		return eloquence
	return premium

static func _available_windows_voices() -> Array[String]:
	var out: Array[String] = []
	var script: String = (
		"Add-Type -AssemblyName System.Speech;" +
		"$s=New-Object System.Speech.Synthesis.SpeechSynthesizer;" +
		"$s.GetInstalledVoices() | ForEach-Object { $_.VoiceInfo.Name };" +
		"$s.Dispose();"
	)
	var lines: Array = []
	var err: int = OS.execute("powershell.exe",
		["-NoProfile", "-NonInteractive", "-Command", script], lines, false)
	if err != 0 or lines.is_empty():
		return ["Microsoft Hanhan"]
	var raw: String = String(lines[0])
	for ln in raw.split("\n"):
		var name: String = String(ln).strip_edges()
		if name != "" and not out.has(name):
			out.append(name)
	out.sort()
	return out
