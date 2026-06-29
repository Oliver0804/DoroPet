extends Node
## 啟動時查 GitHub Release API,有新版彈 bubble
## 比對 project.godot 的 application/config/version 與 release tag(去掉 v 前綴)

signal update_available(latest_tag: String, url: String)
signal up_to_date

const REPO: String = "Oliver0804/DoroPet"
const API_URL: String = "https://api.github.com/repos/%s/releases/latest" % REPO

static func current_version() -> String:
	return String(ProjectSettings.get_setting("application/config/version", "0.0.0"))

const POLL_INTERVAL_SEC: float = 600.0   ## 10 分鐘

var _http: HTTPRequest
var _poll_timer: Timer
var _last_notified_tag: String = ""       ## 已通知過的版本(避免重複念)

func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = 8.0
	_http.request_completed.connect(_on_response)
	add_child(_http)
	_poll_timer = Timer.new()
	_poll_timer.wait_time = POLL_INTERVAL_SEC
	_poll_timer.one_shot = false
	_poll_timer.autostart = false
	_poll_timer.timeout.connect(func() -> void: check())
	add_child(_poll_timer)

func start_polling() -> void:
	if not _poll_timer.is_stopped():
		return
	_poll_timer.start()

func stop_polling() -> void:
	_poll_timer.stop()

func is_polling() -> bool:
	return not _poll_timer.is_stopped()

func reset_notified() -> void:
	_last_notified_tag = ""

func check() -> void:
	## GitHub API 必須帶 User-Agent
	var headers: PackedStringArray = ["User-Agent: DoroPet-UpdateChecker", "Accept: application/vnd.github+json"]
	_http.request(API_URL, headers)

func _on_response(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code < 200 or code >= 300:
		return
	var parser: JSON = JSON.new()
	if parser.parse(body.get_string_from_utf8()) != OK:
		return
	var data: Variant = parser.data
	if typeof(data) != TYPE_DICTIONARY:
		return
	var dict: Dictionary = data
	var tag: String = String(dict.get("tag_name", ""))
	if tag == "":
		return
	var url: String = String(dict.get("html_url", "https://github.com/%s/releases/latest" % REPO))
	var latest: String = tag.lstrip("v")
	if _version_gt(latest, current_version()):
		if tag != _last_notified_tag:
			_last_notified_tag = tag
			update_available.emit(tag, url)
	else:
		up_to_date.emit()

## 簡單版本比較:逐段 int 比(支援 a.b.c 不要 pre-release)
static func _version_gt(a: String, b: String) -> bool:
	var aa: PackedStringArray = a.split(".")
	var bb: PackedStringArray = b.split(".")
	var n: int = max(aa.size(), bb.size())
	for i in n:
		var ai: int = 0 if i >= aa.size() else int(aa[i])
		var bi: int = 0 if i >= bb.size() else int(bb[i])
		if ai != bi:
			return ai > bi
	return false
