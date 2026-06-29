extends Node
## 啟動時查 GitHub Release API,有新版彈 bubble
## 比對 project.godot 的 application/config/version 與 release tag(去掉 v 前綴)

signal update_available(latest_tag: String, url: String)
signal up_to_date

const REPO: String = "Oliver0804/DoroPet"
const API_URL: String = "https://api.github.com/repos/%s/releases/latest" % REPO

static func current_version() -> String:
	return String(ProjectSettings.get_setting("application/config/version", "0.0.0"))

var _http: HTTPRequest

func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = 8.0
	_http.request_completed.connect(_on_response)
	add_child(_http)

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
