extends Node
## Doro 心情狀態(持久化)
## 兩軸模型:
##   valence  ∈ [-1, +1]  低落 ↔ 開心
##   arousal  ∈ [ 0, 1]   慵懶 ↔ 亢奮
## 更新來源:
##   1. 每次 LLM 回覆的 emotion 編號(1-14) → 依表帶動 delta
##   2. 主人互動事件(講話+、abort-、久違重逢-)
##   3. 時間衰減:valence 向 0 回歸、arousal 向 baseline 0.4 回歸
## 用途:
##   - chat_client 組 prompt 時注入「你現在的狀態」,LLM 演得像有情緒延續的生物
##   - pet.gd 自動表情按心情加權(低落抽失神/無言、開心抽開心/吐舌)
##   - 未來可驅動 idle 語音挑選、TTS 語速等

const SAVE_PATH: String = "user://doro_mood.json"
const AROUSAL_BASELINE: float = 0.4     ## 靜置回歸這個值(自然放鬆狀態)
const VALENCE_HALFLIFE_HR: float = 3.0  ## valence 回歸 0 的半衰期(小時) — 短一點免蓄積
const AROUSAL_HALFLIFE_HR: float = 1.5
const IDLE_VALENCE_PER_HR: float = -0.03   ## 沒人陪 → 每小時愉悅度往下
const IDLE_VALENCE_FLOOR: float = -0.5     ## 低落的地板(不會完全崩潰)
const DELTA_SCALE: float = 0.35            ## emotion → delta 統一縮放,免頻繁 apply 撞頂
const VALENCE_CAP: float = 0.85            ## 保留頭尾空間,別 clamp 到 ±1(永遠爆滿)
const AROUSAL_CAP: float = 0.9

## emotion 1-14 → (valence_delta, arousal_delta)
const EMO_DELTA: Dictionary = {
	1:  Vector2(-0.05,  0.20),   ## 生氣
	2:  Vector2(-0.05, -0.10),   ## 無言
	3:  Vector2( 0.02,  0.15),   ## 驚訝
	4:  Vector2( 0.00,  0.05),   ## 疑問
	5:  Vector2( 0.05,  0.00),   ## 酷酷
	6:  Vector2( 0.15,  0.10),   ## 禮物
	7:  Vector2( 0.00,  0.00),   ## 讀取中
	8:  Vector2( 0.15,  0.10),   ## 開心
	9:  Vector2( 0.10,  0.10),   ## 吐舌調皮
	10: Vector2(-0.05, -0.15),   ## 失神累
	11: Vector2( 0.05,  0.02),   ## 點頭
	12: Vector2(-0.02,  0.02),   ## 搖頭
	13: Vector2(-0.02, -0.05),   ## 眯眼
	14: Vector2( 0.02,  0.05),   ## 挑眉
}

const DoroLogger := preload("res://scripts/logger.gd")

var _valence: float = 0.0
var _arousal: float = AROUSAL_BASELINE
var _last_update_ts: int = 0        ## Unix 秒
var _last_interact_ts: int = 0      ## 最近一次主人真的互動的時間

func _ready() -> void:
	_load()
	if _last_update_ts == 0:
		_last_update_ts = int(Time.get_unix_time_from_system())

## ---------- 對外查詢 ----------
func get_valence() -> float:
	_decay_to_now()
	return _valence

func get_arousal() -> float:
	_decay_to_now()
	return _arousal

## 給 chat_client 塞進 system prompt 的一段
func prompt_line() -> String:
	_decay_to_now()
	var v: float = _valence
	var a: float = _arousal
	var mood_word: String = _mood_word(v, a)
	var out: String = "\n# 你當下的心情狀態(自然反映在語氣,別直接報數字)\n"
	out += "- 愉悅度 %+.2f、活力 %.2f → %s\n" % [v, a, mood_word]
	if v <= -0.3:
		out += "  低落時語氣別太亢奮;可以短、悶、有點想討抱,別強顏歡笑\n"
	elif v >= 0.5:
		out += "  心情好時可以主動撒嬌、話多一點,但仍守 50 字上限\n"
	if a <= 0.2:
		out += "  沒精神時可以「唔…」「嗯…」慢半拍,別跳很嗨\n"
	elif a >= 0.7:
		out += "  亢奮時語氣快、感嘆詞多(「欸欸!」「哇~」),但別長篇\n"
	return out

## pet.gd 自動表情抽選權重:回傳 {emo_id: weight}
## 低落心情下:失神/無言/搖頭權重高;開心心情下:開心/吐舌/驚訝權重高
func emotion_weights(candidates: Array) -> Array:
	_decay_to_now()
	var v: float = _valence
	var weights: Array = []
	for id in candidates:
		var w: float = 1.0
		match int(id):
			1: w = 1.0 + maxf(0.0, -v) * 1.0        ## 生氣:低落時多
			2: w = 1.0 + maxf(0.0, -v) * 1.5        ## 無言:低落時多
			8: w = 1.0 + maxf(0.0,  v) * 2.0        ## 開心:愉悅時多
			9: w = 1.0 + maxf(0.0,  v) * 1.5        ## 吐舌:愉悅時多
			10: w = 1.0 + maxf(0.0, -v) * 2.5       ## 失神:低落時多
			3: w = 1.0 + maxf(0.0,  v) * 1.0
			6: w = 1.0 + maxf(0.0,  v) * 1.2
			4: w = 1.0
			5: w = 1.0
		weights.append(w)
	return weights

## ---------- 事件套用 ----------
func apply_emotion(emo: int) -> void:
	if not EMO_DELTA.has(emo):
		return
	_decay_to_now()
	var d: Vector2 = EMO_DELTA[emo]
	_valence = clamp(_valence + d.x * DELTA_SCALE, -VALENCE_CAP, VALENCE_CAP)
	_arousal = clamp(_arousal + d.y * DELTA_SCALE, 0.0, AROUSAL_CAP)
	_save()
	DoroLogger.log("mood_apply", {"emo": emo, "v": _valence, "a": _arousal})

func on_user_message() -> void:
	## 主人主動搭話 = 陪伴,愉悅度和活力都稍微上升
	_decay_to_now()
	_valence = clamp(_valence + 0.05 * DELTA_SCALE, -VALENCE_CAP, VALENCE_CAP)
	_arousal = clamp(_arousal + 0.05 * DELTA_SCALE, 0.0, AROUSAL_CAP)
	_last_interact_ts = int(Time.get_unix_time_from_system())
	_save()

func on_user_abort() -> void:
	## 講到一半被打斷:小失落
	_decay_to_now()
	_valence = clamp(_valence - 0.08 * DELTA_SCALE, -VALENCE_CAP, VALENCE_CAP)
	_save()

func on_positive_stroke() -> void:
	## 被摸頭/點擊 → 開心一點
	_decay_to_now()
	_valence = clamp(_valence + 0.05 * DELTA_SCALE, -VALENCE_CAP, VALENCE_CAP)
	_arousal = clamp(_arousal + 0.03 * DELTA_SCALE, 0.0, AROUSAL_CAP)
	_last_interact_ts = int(Time.get_unix_time_from_system())
	_save()

## ---------- 內部:時間衰減 ----------
func _decay_to_now() -> void:
	var now: int = int(Time.get_unix_time_from_system())
	if _last_update_ts == 0:
		_last_update_ts = now
		return
	var dt_hr: float = float(now - _last_update_ts) / 3600.0
	if dt_hr <= 0.0:
		return
	## 半衰期指數衰減:v(t) = v0 * 0.5^(dt/T)
	var v_factor: float = pow(0.5, dt_hr / VALENCE_HALFLIFE_HR)
	_valence = _valence * v_factor
	var a_factor: float = pow(0.5, dt_hr / AROUSAL_HALFLIFE_HR)
	_arousal = AROUSAL_BASELINE + (_arousal - AROUSAL_BASELINE) * a_factor
	## 沒人陪的孤獨感:超過 3 小時沒互動才開始扣
	var idle_hr: float = float(now - _last_interact_ts) / 3600.0 if _last_interact_ts > 0 else 0.0
	if idle_hr > 3.0:
		_valence = maxf(_valence + IDLE_VALENCE_PER_HR * dt_hr, IDLE_VALENCE_FLOOR)
	_last_update_ts = now

## ---------- 文字描述 ----------
func _mood_word(v: float, a: float) -> String:
	## 簡單 4 象限 + 中性
	if v >= 0.3 and a >= 0.5:  return "開心又有活力"
	if v >= 0.3 and a < 0.5:   return "舒服放鬆"
	if v <= -0.3 and a >= 0.5: return "煩躁不安"
	if v <= -0.3 and a < 0.5:  return "有點低落沒精神"
	if a <= 0.2:               return "懶洋洋想睡"
	if a >= 0.7:               return "有點亢奮"
	return "還好、平常心"

## ---------- 落盤 ----------
func _load() -> void:
	var f: FileAccess = FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		return
	var raw: String = f.get_as_text()
	f.close()
	var d: Variant = JSON.parse_string(raw)
	if typeof(d) != TYPE_DICTIONARY:
		return
	_valence = clamp(float((d as Dictionary).get("v", 0.0)), -1.0, 1.0)
	_arousal = clamp(float((d as Dictionary).get("a", AROUSAL_BASELINE)), 0.0, 1.0)
	_last_update_ts = int((d as Dictionary).get("t", 0))
	_last_interact_ts = int((d as Dictionary).get("li", 0))

func _save() -> void:
	var f: FileAccess = FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({
		"v": _valence, "a": _arousal,
		"t": _last_update_ts, "li": _last_interact_ts,
	}))
	f.close()
