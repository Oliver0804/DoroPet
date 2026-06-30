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

## 觸發 macOS 一鍵下載 + 取代 + 重啟。回 bool 表示有沒有真的啟動 installer。
## 1. 找 latest release 內副檔名為 .dmg 的 asset
## 2. fork shell 跑 download + mount + cp + open + 終
## 3. 呼叫端 quit self,新 process 接手
static func install_macos_latest() -> bool:
	if OS.get_name() != "macOS":
		return false
	## 寫一段 shell 到 /tmp 跑(避免 quoting 問題)
	var script: String = """#!/bin/bash
set -e
DMG_URL="https://github.com/Oliver0804/DoroPet/releases/latest/download/DoroPet.dmg"
DMG="/tmp/DoroPet-update.dmg"
MNT="/Volumes/DoroPet"

# 等舊 process 退(最多 5 秒)
for i in 1 2 3 4 5; do
  pgrep -x DoroPet > /dev/null || break
  sleep 1
done

## 先算舊 binary hash(若不存在 OLD_SHA 為空 → 視為新裝)
OLD_SHA=""
[ -f "/Applications/DoroPet.app/Contents/MacOS/DoroPet" ] && \
  OLD_SHA=$(shasum -a 256 /Applications/DoroPet.app/Contents/MacOS/DoroPet 2>/dev/null | awk '{print $1}')
curl -L --silent -o "$DMG" "$DMG_URL"
[ -f "$DMG" ] || exit 1
hdiutil attach "$DMG" -nobrowse -quiet
rm -rf "/Applications/DoroPet.app"
cp -R "$MNT/DoroPet.app" /Applications/
hdiutil detach "$MNT" -quiet || true
rm -f "$DMG"
xattr -dr com.apple.quarantine /Applications/DoroPet.app 2>/dev/null || true
NEW_SHA=$(shasum -a 256 /Applications/DoroPet.app/Contents/MacOS/DoroPet 2>/dev/null | awk '{print $1}')
## binary 真變了才 reset TCC,避免 user 重複授權
if [ "$OLD_SHA" != "$NEW_SHA" ]; then
  tccutil reset ScreenCapture com.bashcat.doropet 2>/dev/null || true
  tccutil reset Microphone com.bashcat.doropet 2>/dev/null || true
  osascript -e 'display notification "DoroPet 已更新,視覺/麥克風需重新授權" with title "DoroPet"' 2>/dev/null || true
else
  osascript -e 'display notification "DoroPet 已是最新版(binary 未變)" with title "DoroPet"' 2>/dev/null || true
fi
sleep 1
open /Applications/DoroPet.app
"""
	var path: String = "/tmp/doropet_install.sh"
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(script)
	f.close()
	OS.execute("/bin/chmod", ["+x", path])
	## non-blocking 啟動,主 process 立刻退出
	var pid: int = OS.create_process("/bin/bash", [path])
	return pid > 0

## Windows 一鍵下載 + 取代 + 重啟。
## 由 PowerShell 接手:等本程序退 → 下載 → 解壓 → 覆蓋安裝目錄 → 啟動。
## 不支援裝在 Program Files 等需要 admin 的目錄。
static func install_windows_latest() -> bool:
	if OS.get_name() != "Windows":
		return false
	var exe_path: String = OS.get_executable_path()
	var install_dir: String = exe_path.get_base_dir()
	var pid: int = OS.get_process_id()
	## PowerShell 路徑用單引號避免特殊字
	var ps_script: String = """
$ErrorActionPreference = 'SilentlyContinue'
Wait-Process -Id %d -Timeout 15 -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 800

$zip = Join-Path $env:TEMP 'DoroPet-update.zip'
$dir = Join-Path $env:TEMP 'DoroPet-update'
$url = 'https://github.com/Oliver0804/DoroPet/releases/latest/download/DoroPet-Windows-x86_64.zip'

Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
Expand-Archive -Path $zip -DestinationPath $dir -Force

$installDir = %s
Copy-Item -Recurse -Force (Join-Path $dir '*') $installDir

Remove-Item -Recurse -Force $dir
Remove-Item -Force $zip

Start-Process (Join-Path $installDir 'DoroPet.exe')
""" % [pid, _ps_quote(install_dir)]

	var tmp_dir: String = OS.get_environment("TEMP")
	if tmp_dir == "": tmp_dir = "C:\\Windows\\Temp"
	var script_path: String = tmp_dir + "\\doropet_install.ps1"
	var f: FileAccess = FileAccess.open(script_path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(ps_script)
	f.close()
	var new_pid: int = OS.create_process("powershell.exe", [
		"-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script_path
	])
	return new_pid > 0

static func _ps_quote(s: String) -> String:
	## PowerShell 單引號內單引號要連兩個
	return "'" + s.replace("'", "''") + "'"

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
