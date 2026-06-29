# DoroPet Windows 一鍵安裝
# 1) 下載 whisper.cpp Windows binary（GitHub release）
# 2) 下載 ggml-base whisper model
#
# 注意:Windows 上桌寵本體必須用 GitHub Actions build 出的 DoroPet.exe(含 plugin .dll)。
#   下載連結:https://github.com/Oliver0804/DoroPet/actions
#   Artifact: DoroPet-Windows-x86_64
#
# 用法(PowerShell,可能要 Set-ExecutionPolicy):
#   powershell -ExecutionPolicy Bypass -File scripts_sh\00_install.ps1

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Step($msg) { Write-Host "`n>>> $msg" -ForegroundColor Cyan }

# ---- whisper.cpp ----
$whisperDir = "$env:USERPROFILE\.local\bin"
$whisperExe = "$whisperDir\whisper-cli.exe"
if (-not (Test-Path $whisperExe)) {
    Step "下載 whisper.cpp Windows binary"
    New-Item -ItemType Directory -Force -Path $whisperDir | Out-Null
    # whisper.cpp 官方 release CPU 版
    $url = "https://github.com/ggerganov/whisper.cpp/releases/latest/download/whisper-bin-x64.zip"
    $tmp = "$env:TEMP\whisper-bin.zip"
    Invoke-WebRequest -Uri $url -OutFile $tmp
    Expand-Archive -Path $tmp -DestinationPath "$env:TEMP\whisper-extract" -Force
    # release 內 binary 可能名為 main.exe 或 whisper-cli.exe
    $candidates = @(
        "$env:TEMP\whisper-extract\whisper-cli.exe",
        "$env:TEMP\whisper-extract\main.exe",
        "$env:TEMP\whisper-extract\Release\whisper-cli.exe",
        "$env:TEMP\whisper-extract\Release\main.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) {
            Copy-Item $c $whisperExe
            # 順便把 dll 拷貝過去
            Copy-Item "$(Split-Path $c)\*.dll" $whisperDir -ErrorAction SilentlyContinue
            break
        }
    }
    Remove-Item -Recurse -Force "$env:TEMP\whisper-extract"
    Remove-Item $tmp
    if (-not (Test-Path $whisperExe)) { throw "找不到 whisper-cli.exe,請手動下載放到 $whisperDir" }
    Write-Host "✓ $whisperExe"
    # 把 $whisperDir 加進當前 session 與使用者 PATH
    $existing = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($existing -notlike "*$whisperDir*") {
        [Environment]::SetEnvironmentVariable("Path", "$existing;$whisperDir", "User")
        Write-Host "✓ 已將 $whisperDir 加入使用者 PATH(重開終端機生效)"
    }
} else {
    Write-Host "✓ whisper-cli 已存在: $whisperExe"
}

# ---- ggml model ----
$modelDir = "$env:USERPROFILE\.local\share\doropet\whisper-models"
$modelFile = "$modelDir\ggml-base.bin"
if (-not (Test-Path $modelFile)) {
    Step "下載 whisper ggml-base 模型(~140MB,多語言)"
    New-Item -ItemType Directory -Force -Path $modelDir | Out-Null
    $modelUrl = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin"
    Invoke-WebRequest -Uri $modelUrl -OutFile $modelFile
    Write-Host "✓ $modelFile"
} else {
    Write-Host "✓ model 已存在"
}

Write-Host "`n✅ 全部完成。"
Write-Host "下一步:"
Write-Host "  1. 去 GitHub Actions 下載最新 DoroPet-Windows-x86_64 artifact 並解壓"
Write-Host "  2. 設定 OPENROUTER_API_KEY 環境變數(`setx OPENROUTER_API_KEY sk-or-v1-xxx`)"
Write-Host "  3. 雙擊 DoroPet.exe 啟動"
