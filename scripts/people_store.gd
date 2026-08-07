extends Node
## 人物記憶庫 — 記住 Discord 頻道裡「誰說過什麼、什麼時候說的」
##
## 跟 memory_store 的分工:
##   memory_store  是主人中心的長期事實帳本(蒸餾產生,精煉但不分人)
##   people_store  是逐句流水帳,以 Discord user_id 為 key,保留原文與日期
##
## 為什麼要分開:語音頻道裡每個人都是獨立的對話對象,把他們的話混進主人的
## 事實帳本會污染人設(Doro 會把路人的事當成主人的事)。而且這裡要的是
## 「他上次說過什麼」的可查性,不是精煉後的結論。

const DoroLogger := preload("res://scripts/logger.gd")

const LOG_PATH: String = "user://doro_people_log.jsonl"
const MAX_ENTRIES: int = 4000      ## 超過就砍最舊的(一行約 100 bytes,4000 條 ≈ 400KB)
const TRIM_TO: int = 3000          ## 砍一次就砍到這個量,不要每次都在邊界上重寫檔案

var _entries: Array = []           ## [{uid, name, text, ts, by}]

func _ready() -> void:
	_load()

func _load() -> void:
	_entries.clear()
	if not FileAccess.file_exists(LOG_PATH):
		return
	var f: FileAccess = FileAccess.open(LOG_PATH, FileAccess.READ)
	if f == null:
		return
	while not f.eof_reached():
		var line: String = f.get_line()
		if line.strip_edges() == "":
			continue
		var d: Variant = JSON.parse_string(line)
		if typeof(d) == TYPE_DICTIONARY:
			_entries.append(d)
	f.close()

## 整檔重寫。只在 trim(砍舊資料)時才做 —— 平常走 _append_one,
## 不然語音頻道每講一句就要重寫整個檔案(4000 條約 480KB),磁碟會一直被打
func _rewrite_all() -> void:
	var f: FileAccess = FileAccess.open(LOG_PATH, FileAccess.WRITE)
	if f == null:
		return
	for e in _entries:
		f.store_line(JSON.stringify(e))
	f.close()

func _append_one(e: Dictionary) -> void:
	var f: FileAccess = FileAccess.open(LOG_PATH, FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open(LOG_PATH, FileAccess.WRITE)   ## 檔案還不存在
		if f == null:
			return
	else:
		f.seek_end()
	f.store_line(JSON.stringify(e))
	f.close()

## 記一句話。by: "user" = 對方說的, "doro" = Doro 回的
func record(uid: String, name: String, text: String, by: String = "user") -> void:
	var t: String = text.strip_edges()
	if t == "" or uid == "":
		return
	var e: Dictionary = {
		"uid": uid, "name": name, "text": t.substr(0, 300),
		"ts": int(Time.get_unix_time_from_system()), "by": by,
	}
	_entries.append(e)
	if _entries.size() > MAX_ENTRIES:
		_entries = _entries.slice(_entries.size() - TRIM_TO)
		_rewrite_all()          ## 砍過才需要整檔重寫
	else:
		_append_one(e)          ## 平常只補一行

## 這個人講過幾句(用來判斷是不是新面孔)
func count_for(uid: String) -> int:
	var n: int = 0
	for e in _entries:
		if String(e.get("uid", "")) == uid:
			n += 1
	return n

## 認識的人清單:[{uid, name, count, last_ts}],最近講過話的排前面
func known_people() -> Array:
	var by_uid: Dictionary = {}
	for e in _entries:
		var uid: String = String(e.get("uid", ""))
		if uid == "":
			continue
		if not by_uid.has(uid):
			by_uid[uid] = {"uid": uid, "name": String(e.get("name", "")), "count": 0, "last_ts": 0}
		var rec: Dictionary = by_uid[uid]
		rec["count"] = int(rec["count"]) + 1
		rec["name"] = String(e.get("name", rec["name"]))   ## 名字以最新的為準
		rec["last_ts"] = max(int(rec["last_ts"]), int(e.get("ts", 0)))
	var out: Array = by_uid.values()
	out.sort_custom(func(a, b): return int(a["last_ts"]) > int(b["last_ts"]))
	return out

## 依 uid 或名字找人(名字用模糊比對,STT 常把人名聽歪)
func _matches_person(e: Dictionary, who: String) -> bool:
	if who == "":
		return true
	var w: String = who.strip_edges().to_lower()
	return String(e.get("uid", "")) == who \
		or String(e.get("name", "")).to_lower().contains(w) \
		or w.contains(String(e.get("name", "")).to_lower())

## 查某人說過的話。who 可以是 uid 或名字;keyword 空 = 給最近的
## 回傳給 LLM 看的文字(帶日期,因為「什麼時候說的」常常才是重點)
func recall(who: String, keyword: String = "", limit: int = 12) -> String:
	var kw: String = keyword.strip_edges().to_lower()
	var hits: Array = []
	for i in range(_entries.size() - 1, -1, -1):     ## 由新到舊
		var e: Dictionary = _entries[i]
		if not _matches_person(e, who):
			continue
		if kw != "" and not String(e.get("text", "")).to_lower().contains(kw):
			continue
		hits.append(e)
		if hits.size() >= limit:
			break
	if hits.is_empty():
		if who != "" and keyword != "":
			return "(沒查到 %s 講過「%s」)" % [who, keyword]
		if who != "":
			return "(沒有 %s 的紀錄,可能是第一次遇到)" % who
		return "(沒查到相關紀錄)"
	hits.reverse()                                    ## 輸出時改回時間順序
	var out: String = ""
	for e in hits:
		out += "[%s] %s%s: %s\n" % [
			_date_of(int(e.get("ts", 0))),
			String(e.get("name", "?")),
			"(Doro 回)" if String(e.get("by", "")) == "doro" else "",
			String(e.get("text", ""))]
	return out.strip_edges()

## 注入 context 用的簡短版:這個人最近說過什麼
func recent_brief(uid: String, n: int = 6) -> String:
	var hits: Array = []
	for i in range(_entries.size() - 1, -1, -1):
		var e: Dictionary = _entries[i]
		if String(e.get("uid", "")) != uid:
			continue
		if String(e.get("by", "")) == "doro":
			continue                                  ## 只要對方說的,Doro 自己講的不用回顧
		hits.append(e)
		if hits.size() >= n:
			break
	if hits.is_empty():
		return ""
	hits.reverse()
	var name: String = String(hits[hits.size() - 1].get("name", "?"))
	var out: String = "\n\n# 你對「%s」的印象(他之前說過的話)\n" % name
	for e in hits:
		out += "- [%s] %s\n" % [_date_of(int(e.get("ts", 0))), String(e.get("text", ""))]
	return out

## 清空(設定 → 資料管理)。這裡存的是頻道裡每個人講話的逐字原文,
## 使用者要能自己刪掉
func clear_all() -> void:
	_entries.clear()
	_rewrite_all()
	DoroLogger.log("people_log_cleared", {})

## 檔案被外部刪掉(設定的資料管理頁)後重讀。
## 不重讀的話記憶體裡的舊資料會在下次 record 時被寫回檔案,等於沒刪掉
func reload() -> void:
	_load()

static func _date_of(ts: int) -> String:
	if ts <= 0:
		return "?"
	var d: Dictionary = Time.get_datetime_dict_from_unix_time(ts)
	return "%04d-%02d-%02d %02d:%02d" % [d.year, d.month, d.day, d.hour, d.minute]
