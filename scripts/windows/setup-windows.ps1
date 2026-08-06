# 注意：本文件必须保存为 UTF-8 with BOM（Windows PowerShell 5.1 按 ANSI 解析无 BOM 脚本会乱码报错）。
# ============================================================
#  ClipFlow Windows 环境一键配置
#  用途：
#    1. 检查 git / node / npm / flutter 是否就绪
#    2. 修复 Claude Code（claude.exe 缺失导致 claude.cmd 无法启动时自动重装）
#    3. 配置 OpenSSH Server 开机自启并启动（保证重启后 Mac 端 SSH 仍可连接）
#    4. 拉取项目最新代码（E:\VSCode\clipflow）
#  运行：双击 scripts\windows\setup-windows.cmd（会自动提权）
# ============================================================
$ErrorActionPreference = 'Continue'

$APPDATA_NPM = Join-Path $env:APPDATA 'npm'
$claudePkg   = Join-Path $APPDATA_NPM 'node_modules\@anthropic-ai\claude-code'
$claudeCmd   = Join-Path $APPDATA_NPM 'claude.cmd'
$flutterBat  = 'E:\flutter\bin\flutter.bat'
$project     = 'E:\VSCode\clipflow'

function OK   ($m) { Write-Host "[OK]   $m" -ForegroundColor Green }
function WARN ($m) { Write-Host "[WARN] $m" -ForegroundColor Yellow }
function FAIL ($m) { Write-Host "[FAIL] $m" -ForegroundColor Red }

Write-Host '============================================' -ForegroundColor Cyan
Write-Host '  ClipFlow Windows 环境一键配置'             -ForegroundColor Cyan
Write-Host '============================================' -ForegroundColor Cyan

# ---------- 1. git ----------
Write-Host "`n[1/6] Git" -ForegroundColor Cyan
$git = Get-Command git -ErrorAction SilentlyContinue
if ($git) { OK "git: $(& git --version)" } else { WARN '未找到 git，请执行：winget install Git.Git' }

# ---------- 2. node / npm ----------
Write-Host "`n[2/6] Node.js / npm" -ForegroundColor Cyan
$node = Get-Command node -ErrorAction SilentlyContinue
$npm  = Get-Command npm  -ErrorAction SilentlyContinue
if ($node -and $npm) {
    OK "node: $(& node -v)  npm: $(& npm -v)"
} else {
    FAIL '未找到 node/npm，请先安装 Node.js（https://nodejs.org）'
}

# ---------- 3. flutter ----------
Write-Host "`n[3/6] Flutter" -ForegroundColor Cyan
if (Test-Path $flutterBat) { OK "flutter: $flutterBat" }
elseif (Get-Command flutter -ErrorAction SilentlyContinue) { OK 'flutter: 已加入 PATH' }
else { WARN "未找到 flutter（$flutterBat 不存在，也未加入 PATH）" }

# ---------- 4. 修复 Claude Code ----------
Write-Host "`n[4/6] 修复 Claude Code" -ForegroundColor Cyan
if (Test-Path $claudePkg) {
    $claudeExe = Join-Path $claudePkg 'bin\claude.exe'
    if (-not (Test-Path $claudeExe)) {
        WARN '检测到 claude.exe 缺失（上次升级残留），先手动清理再重装'
        Remove-Item -Recurse -Force $claudePkg -ErrorAction SilentlyContinue
        Remove-Item -Force (Join-Path $APPDATA_NPM 'claude.cmd') -ErrorAction SilentlyContinue
        Remove-Item -Force (Join-Path $APPDATA_NPM 'claude.ps1') -ErrorAction SilentlyContinue
    }
}
Write-Host 'npm uninstall -g @anthropic-ai/claude-code ...'
& npm uninstall -g @anthropic-ai/claude-code 2>&1 | Out-Host
Write-Host 'npm install  -g @anthropic-ai/claude-code ...'
& npm install -g @anthropic-ai/claude-code 2>&1 | Out-Host

if (Test-Path $claudeCmd) {
    Write-Host "`nclaude.cmd --version:"
    & $claudeCmd --version
    if ($LASTEXITCODE -eq 0) {
        OK 'claude.cmd 启动正常'
        Write-Host 'claude -p "输出 READY"（若首次使用会提示登录）：'
        & $claudeCmd -p '输出 READY' 2>&1 | Out-Host
    } else {
        FAIL 'claude.cmd 仍无法启动，请把上方错误信息发回'
    }
} else {
    FAIL "未找到 $claudeCmd，npm 全局安装可能失败"
}

# ---------- 5. OpenSSH Server（保证重启后 Mac 端仍可 SSH） ----------
Write-Host "`n[5/6] OpenSSH Server (sshd)" -ForegroundColor Cyan
$sshd = Get-Service sshd -ErrorAction SilentlyContinue
if ($sshd) {
    # 用 sc.exe 设置开机自启，兼容 Windows PowerShell 5.1
    & sc.exe config sshd start= auto | Out-Null
    OK 'sshd 已设为开机自启（sc config start= auto）'
    if ($sshd.Status -ne 'Running') {
        & sc.exe start sshd | Out-Null
        Start-Sleep -Seconds 1
    }
    $check = Get-Service sshd
    if ($check.Status -eq 'Running') { OK 'sshd 运行中' }
    else { WARN 'sshd 启动失败，请手动检查服务' }
} else {
    WARN '未安装 OpenSSH Server，可执行：Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0'
}

# ---------- 6. 项目目录 + 拉取最新 ----------
Write-Host "`n[6/6] 项目目录 $project" -ForegroundColor Cyan
if (Test-Path (Join-Path $project '.git')) {
    Set-Location $project
    & git pull --ff-only origin main
    if ($LASTEXITCODE -eq 0) { OK 'git pull 完成' }
    else { WARN 'git pull 未完成，请检查网络或本地冲突' }
} else {
    WARN "$project 不存在或不是 git 仓库，请先克隆：git clone https://github.com/hanyi-lucky/clipflow.git"
}

Write-Host "`n=== 完成 ===`n" -ForegroundColor Green
