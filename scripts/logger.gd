extends RefCounted
class_name DoroLogger
## DoroPet 請求記錄 — 寫 jsonl 到 user://logs/YYYY-MM-DD.jsonl
## 用法：DoroLogger.log("chat_request", {text=..., model=...})

const LOG_DIR: String = "user://logs"

## 記一筆事件。type 例：chat_request / chat_response / chat_error /
##                       stt_request / stt_response / stt_error
static func log(event_type: String, data: Dictionary = {}) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(LOG_DIR))
	var date_str: String = Time.get_date_string_from_system()
	var path: String = "%s/%s.jsonl" % [LOG_DIR, date_str]
	var entry: Dictionary = {
		"ts": Time.get_datetime_string_from_system(false, true),
		"type": event_type,
	}
	for k in data.keys():
		entry[k] = data[k]
	var line: String = JSON.stringify(entry) + "\n"
	var f: FileAccess = FileAccess.open(path, FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open(path, FileAccess.WRITE)
		if f == null:
			return
	else:
		f.seek_end()
	f.store_string(line)
	f.close()

## 列出 logs 目錄內所有 jsonl 檔案（最新在前）
static func list_log_files() -> Array[String]:
	var out: Array[String] = []
	var dir: DirAccess = DirAccess.open(LOG_DIR)
	if dir == null:
		return out
	for f in dir.get_files():
		if f.ends_with(".jsonl"):
			out.append("%s/%s" % [LOG_DIR, f])
	out.sort()
	out.reverse()
	return out

## 讀取某天 logs（解析每行 JSON）
static func read_log(path: String, max_entries: int = 200) -> Array:
	var out: Array = []
	if not FileAccess.file_exists(path):
		return out
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return out
	while not f.eof_reached():
		var line: String = f.get_line()
		if line.strip_edges() == "":
			continue
		var parsed: Variant = JSON.parse_string(line)
		if typeof(parsed) == TYPE_DICTIONARY:
			out.append(parsed)
	f.close()
	## 只回最近 N 筆
	if out.size() > max_entries:
		out = out.slice(out.size() - max_entries)
	out.reverse()  ## 新的在前
	return out

## 回傳 logs 目錄絕對路徑（給「開啟資料夾」用）
static func get_log_dir_abs() -> String:
	return ProjectSettings.globalize_path(LOG_DIR)

## 把截圖存到 logs/screenshots/YYYY-MM-DD/HHMMSS.png,回 absolute path
static func save_screenshot(png_bytes: PackedByteArray) -> String:
	var date_str: String = Time.get_date_string_from_system()
	var t: Dictionary = Time.get_time_dict_from_system()
	var ts: String = "%02d%02d%02d_%03d" % [t.hour, t.minute, t.second, Time.get_ticks_msec() % 1000]
	var sub_dir: String = "%s/screenshots/%s" % [LOG_DIR, date_str]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(sub_dir))
	var rel_path: String = "%s/%s.png" % [sub_dir, ts]
	var f: FileAccess = FileAccess.open(rel_path, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_buffer(png_bytes)
	f.close()
	return ProjectSettings.globalize_path(rel_path)
