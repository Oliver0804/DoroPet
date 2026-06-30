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

var _engine: String = "local"        ## "local" | "api"
var _api_key: String = ""
var _endpoint: String = DEFAULT_STT_ENDPOINT
var _model: String = DEFAULT_STT_MODEL
var _local_bin: String = ""
var _local_model: String = ""        ## 完整路徑指向 ggml-*.bin
var _voice: String = ""              ## 預設聲音(依 OS)
var _tts_enabled: bool = true

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
	_tts_player.finished.connect(func() -> void:
		speaking_finished.emit())
	add_child(_tts_player)

## ---------- runtime 設定 ----------
func set_engine(e: String) -> void:
	if e == "api" or e == "local":
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

func is_recording() -> bool: return _recording

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
	if _api_key == "":
		return "雲端：未設定 OPENAI_API_KEY"
	return "雲端 %s" % _model

func has_stt() -> bool:
	if _engine == "local":
		return FileAccess.file_exists(_local_model) and FileAccess.file_exists(_local_bin)
	return _api_key != ""

## ---------- 錄音 ----------
func start_recording() -> bool:
	if _recording:
		return false
	if not has_stt():
		stt_error.emit("沒設 OPENAI_API_KEY（語音轉文字用）")
		return false
	_eff.clear_buffer()
	_player.play()
	_recording = true
	recording_started.emit()
	return true

func abort_recording() -> void:
	if not _recording:
		return
	_recording = false
	_player.stop()
	_eff.clear_buffer()
	recording_stopped.emit()

func stop_and_send() -> void:
	if not _recording:
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
	if OS.get_name() != "macOS" and OS.get_name() != "Windows":
		return
	stop_speaking()
	var t: Thread = Thread.new()
	t.start(_tts_thread.bind(text, _voice))

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
	var i: int = 12
	while i < data.size() - 8:
		var chunk_id: String = data.slice(i, i + 4).get_string_from_ascii()
		var chunk_size: int = data.decode_u32(i + 4)
		if chunk_id == "data":
			var pcm: PackedByteArray = data.slice(i + 8, i + 8 + chunk_size)
			var s: AudioStreamWAV = AudioStreamWAV.new()
			s.format = AudioStreamWAV.FORMAT_16_BITS
			s.mix_rate = TTS_SR
			s.stereo = false
			s.data = pcm
			return s
		i += 8 + chunk_size
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
	return _tts_player != null and _tts_player.playing

func stop_speaking() -> void:
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
