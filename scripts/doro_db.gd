extends RefCounted
class_name DoroDB
## 統一資料層 — 所有記憶/紀錄收進一個 SQLite 檔
##
## 取代原本散在各處的 jsonl:doro_facts / doro_archive / doro_people_log /
## doro_history / doro_followups。原本每個模組各自載入整份檔案到記憶體、
## 各自實作查詢與寫入,查詢是線性掃描、寫入常常要重寫整檔。
##
## 用法(單例,由 pet.gd 開一次傳下去):
##     var db := DoroDB.new()
##     db.open()
##     db.migrate_from_jsonl()      ## 首次執行才會搬;來源 jsonl 原地保留
##
## 注意:GDExtension(addons/godot-sqlite)沒裝的話 open() 回 false,
## 呼叫端要能退回 jsonl 模式,不能直接崩。

const DB_PATH: String = "user://doro.db"
const DoroLogger := preload("res://scripts/logger.gd")

var _db: Object = null
var _ok: bool = false

func is_open() -> bool:
	return _ok

## 開啟並建表。GDExtension 缺席時回 false(呼叫端要 fallback)
func open() -> bool:
	if not ClassDB.class_exists("SQLite"):
		DoroLogger.log("db_unavailable", {"reason": "godot-sqlite 未安裝"})
		return false
	_db = ClassDB.instantiate("SQLite")
	_db.path = DB_PATH
	if not _db.open_db():
		DoroLogger.log("db_error", {"stage": "open"})
		_db = null
		return false
	_ok = true
	_create_schema()
	return true

func close() -> void:
	if _ok and _db != null:
		_db.close_db()
	_ok = false
	_db = null

func _create_schema() -> void:
	## WAL:寫入不擋讀取。桌寵是邊聊邊寫,不想因為落盤卡住對話
	_db.query("PRAGMA journal_mode=WAL;")
	_db.query("PRAGMA synchronous=NORMAL;")

	## 人物記憶:Discord 頻道裡誰說過什麼(逐句原文)
	_db.query("""CREATE TABLE IF NOT EXISTS people_log (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		uid TEXT NOT NULL, name TEXT, text TEXT NOT NULL,
		ts INTEGER NOT NULL, by TEXT NOT NULL DEFAULT 'user');""")
	## (uid, ts) 複合索引:recent_brief 就是「某人最近 N 句」,這是主要查詢型態
	_db.query("CREATE INDEX IF NOT EXISTS idx_people_uid_ts ON people_log(uid, ts DESC);")
	_db.query("CREATE INDEX IF NOT EXISTS idx_people_ts ON people_log(ts DESC);")

	## 事實帳本:蒸餾產生的長期記憶。id 沿用原本 jsonl 裡的編號(蒸餾會用 id 做 update/delete)
	_db.query("""CREATE TABLE IF NOT EXISTS facts (
		id INTEGER PRIMARY KEY,
		type TEXT DEFAULT 'other', text TEXT NOT NULL,
		created TEXT, updated TEXT);""")
	_db.query("CREATE INDEX IF NOT EXISTS idx_facts_type ON facts(type);")

	## 已歸檔的事實(蒸餾判定過時,但不真的刪掉,recall 還查得到)
	_db.query("""CREATE TABLE IF NOT EXISTS facts_archive (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		orig_id INTEGER, type TEXT, text TEXT,
		created TEXT, archived TEXT, reason TEXT);""")

	## 短期對話歷史
	_db.query("""CREATE TABLE IF NOT EXISTS history (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		role TEXT NOT NULL, content TEXT NOT NULL,
		ts INTEGER, meta TEXT);""")

	## 前瞻記憶(約定要在某天提起的事)
	_db.query("""CREATE TABLE IF NOT EXISTS followups (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		due TEXT, text TEXT NOT NULL, created TEXT, done INTEGER DEFAULT 0);""")

	## 雜項鍵值(摘要、meta 之類)
	_db.query("""CREATE TABLE IF NOT EXISTS kv (
		k TEXT PRIMARY KEY, v TEXT);""")

## ---------- 低階操作 ----------
func q(sql: String, args: Array = []) -> Array:
	if not _ok:
		return []
	var ok: bool = _db.query_with_bindings(sql, args) if not args.is_empty() else _db.query(sql)
	if not ok:
		DoroLogger.log("db_error", {"sql": sql.substr(0, 80), "err": String(_db.error_message)})
		return []
	return _db.query_result

func insert(table: String, row: Dictionary) -> bool:
	if not _ok:
		return false
	return _db.insert_row(table, row)

func kv_get(key: String, fallback: String = "") -> String:
	var r: Array = q("SELECT v FROM kv WHERE k=?;", [key])
	return String(r[0]["v"]) if r.size() > 0 else fallback

func kv_set(key: String, value: String) -> void:
	q("INSERT INTO kv(k,v) VALUES(?,?) ON CONFLICT(k) DO UPDATE SET v=excluded.v;", [key, value])

## ---------- 跨表搜尋(設定 → 記憶檢視器用)----------
## 一次問「Doro 到底記得什麼」,不用自己去猜要翻哪張表。
## 回傳 [{source, text, date, extra}],由新到舊
func search_all(keyword: String, limit_per_table: int = 40) -> Array:
	if not _ok:
		return []
	var kw: String = "%" + keyword.strip_edges().to_lower() + "%"
	var out: Array = []

	var facts: Array = q("""SELECT id, type, text, created, updated FROM facts
		WHERE ? = '%%' OR LOWER(text) LIKE ? ORDER BY updated DESC, id DESC LIMIT ?;""",
		[kw, kw, limit_per_table])
	for r in facts:
		out.append({"source": "事實", "text": String(r["text"]),
			"date": String(r.get("updated", "")) if String(r.get("updated", "")) != "" else String(r.get("created", "")),
			"extra": "#%d [%s]" % [int(r["id"]), String(r.get("type", ""))]})

	var ppl: Array = q("""SELECT name, text, ts, by FROM people_log
		WHERE ? = '%%' OR LOWER(text) LIKE ? OR LOWER(name) LIKE ?
		ORDER BY ts DESC, id DESC LIMIT ?;""", [kw, kw, kw, limit_per_table])
	for r in ppl:
		out.append({"source": "人物", "text": String(r["text"]),
			"date": _ts_date(int(r.get("ts", 0))),
			"extra": String(r.get("name", "")) + ("(Doro)" if String(r.get("by", "")) == "doro" else "")})

	var arc: Array = q("""SELECT text, archived, reason FROM facts_archive
		WHERE ? = '%%' OR LOWER(text) LIKE ? ORDER BY archived DESC LIMIT ?;""",
		[kw, kw, limit_per_table])
	for r in arc:
		out.append({"source": "已歸檔", "text": String(r["text"]),
			"date": String(r.get("archived", "")), "extra": String(r.get("reason", ""))})

	var his: Array = q("""SELECT role, content, ts FROM history
		WHERE ? = '%%' OR LOWER(content) LIKE ? ORDER BY ts DESC, id DESC LIMIT ?;""",
		[kw, kw, limit_per_table])
	for r in his:
		out.append({"source": "對話", "text": String(r["content"]),
			"date": _ts_date(int(r.get("ts", 0))),
			"extra": "主人" if String(r.get("role", "")) == "user" else "Doro"})

	out.sort_custom(func(a, b): return String(a["date"]) > String(b["date"]))
	return out

## 各表筆數,給檢視器顯示「記得多少東西」
func stats() -> Dictionary:
	var out: Dictionary = {}
	for t in ["facts", "people_log", "facts_archive", "history", "followups"]:
		var r: Array = q("SELECT COUNT(*) AS n FROM %s;" % t)
		out[t] = int(r[0]["n"]) if r.size() > 0 else 0
	return out

static func _ts_date(ts: int) -> String:
	if ts <= 0:
		return ""
	var d: Dictionary = Time.get_datetime_dict_from_unix_time(ts)
	return "%04d-%02d-%02d %02d:%02d" % [d.year, d.month, d.day, d.hour, d.minute]

## ---------- 從舊 jsonl 搬家 ----------
## 只搬一次(表空 + 沒搬過)。來源檔原封不動留著 —— 還沒切到 DB 的模組要繼續讀它
func migrate_from_jsonl() -> Dictionary:
	var stats: Dictionary = {}
	if not _ok:
		return stats
	stats["facts"] = _migrate_facts()
	stats["facts_archive"] = _migrate_archive()
	stats["people_log"] = _migrate_people()
	stats["history"] = _migrate_history()
	stats["followups"] = _migrate_followups()
	var total: int = 0
	for k in stats:
		total += int(stats[k])
	if total > 0:
		DoroLogger.log("db_migrated", stats)
	return stats

func _table_empty(t: String) -> bool:
	var r: Array = q("SELECT COUNT(*) AS n FROM %s;" % t)
	return r.is_empty() or int(r[0]["n"]) == 0

func _read_jsonl(path: String) -> Array:
	var out: Array = []
	if not FileAccess.file_exists(path):
		return out
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return out
	while not f.eof_reached():
		var line: String = f.get_line().strip_edges()
		if line == "":
			continue
		var d: Variant = JSON.parse_string(line)
		if typeof(d) == TYPE_DICTIONARY:
			out.append(d)
	f.close()
	return out

## 不改名來源檔 —— 模組是逐步切到 DB 的,還在讀 jsonl 的那些一旦找不到檔案
## 就等於失憶(實測踩過:facts 被改名後 memory_store 讀不到,Doro 直接失憶)。
## 改用 kv 記一筆「搬過了」,兩邊並存直到該模組完全切換。
func _mark_migrated(path: String) -> void:
	kv_set("migrated:" + path, String(Time.get_datetime_string_from_system(false, true)))

func _already_migrated(path: String) -> bool:
	return kv_get("migrated:" + path, "") != ""

func _migrate_facts() -> int:
	if not _table_empty("facts") or _already_migrated("user://doro_facts.jsonl"):
		return 0
	var rows: Array = _read_jsonl("user://doro_facts.jsonl")
	for r in rows:
		insert("facts", {
			"id": int(r.get("id", 0)),
			"type": String(r.get("type", "other")),
			"text": String(r.get("text", "")),
			"created": String(r.get("created", "")),
			"updated": String(r.get("updated", "")),
		})
	if rows.size() > 0:
		_mark_migrated("user://doro_facts.jsonl")
	return rows.size()

func _migrate_archive() -> int:
	if not _table_empty("facts_archive") or _already_migrated("user://doro_archive.jsonl"):
		return 0
	var rows: Array = _read_jsonl("user://doro_archive.jsonl")
	for r in rows:
		insert("facts_archive", {
			"orig_id": int(r.get("id", 0)),
			"type": String(r.get("type", "")),
			"text": String(r.get("text", "")),
			"created": String(r.get("created", "")),
			"archived": String(r.get("archived", "")),
			"reason": String(r.get("reason", "")),
		})
	if rows.size() > 0:
		_mark_migrated("user://doro_archive.jsonl")
	return rows.size()

func _migrate_people() -> int:
	if not _table_empty("people_log") or _already_migrated("user://doro_people_log.jsonl"):
		return 0
	var rows: Array = _read_jsonl("user://doro_people_log.jsonl")
	for r in rows:
		insert("people_log", {
			"uid": String(r.get("uid", "")), "name": String(r.get("name", "")),
			"text": String(r.get("text", "")), "ts": int(r.get("ts", 0)),
			"by": String(r.get("by", "user")),
		})
	if rows.size() > 0:
		_mark_migrated("user://doro_people_log.jsonl")
	return rows.size()

func _migrate_history() -> int:
	var path: String = "user://doro_history.json"
	if not _table_empty("history") or _already_migrated(path):
		return 0
	if not FileAccess.file_exists(path):
		return 0
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 0
	var d: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(d) != TYPE_ARRAY:
		return 0
	for m in d:
		if typeof(m) != TYPE_DICTIONARY:
			continue
		insert("history", {
			"role": String(m.get("role", "")), "content": String(m.get("content", "")),
			"ts": int(m.get("ts", 0)), "meta": String(m.get("meta", "")),
		})
	if (d as Array).size() > 0:
		_mark_migrated(path)
	return (d as Array).size()

func _migrate_followups() -> int:
	if not _table_empty("followups") or _already_migrated("user://doro_followups.jsonl"):
		return 0
	var rows: Array = _read_jsonl("user://doro_followups.jsonl")
	for r in rows:
		insert("followups", {
			"due": String(r.get("due", "")), "text": String(r.get("text", "")),
			"created": String(r.get("created", "")), "done": 0,
		})
	if rows.size() > 0:
		_mark_migrated("user://doro_followups.jsonl")
	return rows.size()
