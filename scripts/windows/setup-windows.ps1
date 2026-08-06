# 注意：本文件必须保存为 UTF-8 with BOM（Windows PowerShell 5.1 按 ANSI 解析无 BOM 脚本会乱码报错）。
# ============================================================
#  ClipFlow Windows 端 SSH 一键配置
#  用途：保证 Windows 重启后 Mac 端仍可通过 UU+SSH 远程控制
#    1. 安装 OpenSSH Server（如未安装）
#    2. 设为开机自启
#    3. 启动并验证
#    4. 放行防火墙 22 端口
#  运行：双击 scripts\windows\setup-windows.cmd（会自动提权）
# ============================================================
$ErrorActionPreference = 'Continue'

function OK   ($m) { Write-Host "[OK]   $m" -ForegroundColor Green }
function WARN ($m) { Write-Host "[WARN] $m" -ForegroundColor Yellow }
function FAIL ($m) { Write-Host "[FAIL] $m" -ForegroundColor Red }

Write-Host '============================================' -ForegroundColor Cyan
Write-Host '  ClipFlow Windows 端 SSH 一键配置'           -ForegroundColor Cyan
Write-Host '============================================' -ForegroundColor Cyan

# ---------- 1. 安装 OpenSSH Server ----------
Write-Host "`n[1/4] 安装 OpenSSH Server" -ForegroundColor Cyan
$sshd = Get-Service sshd -ErrorAction SilentlyContinue
if (-not $sshd) {
    WARN '未检测到 sshd，开始安装 OpenSSH.Server（可能需要几分钟，若提示重启请重启后再运行一次）'
    Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Host
    $sshd = Get-Service sshd -ErrorAction SilentlyContinue
}
if ($sshd) { OK 'OpenSSH Server 已安装' }
else { FAIL 'OpenSSH Server 安装失败，请手动执行：Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0' }

# ---------- 2. 开机自启 ----------
Write-Host "`n[2/4] 设为开机自启" -ForegroundColor Cyan
if ($sshd) {
    & sc.exe config sshd start= auto | Out-Null
    OK 'sshd 已设为开机自启（sc config start= auto）'
}

# ---------- 3. 启动并验证 ----------
Write-Host "`n[3/4] 启动 sshd" -ForegroundColor Cyan
if ($sshd) {
    if ($sshd.Status -ne 'Running') {
        & sc.exe start sshd | Out-Null
        Start-Sleep -Seconds 1
    }
    $check = Get-Service sshd
    if ($check.Status -eq 'Running') { OK 'sshd 运行中' }
    else { WARN 'sshd 启动失败，请手动检查服务' }
}

# ---------- 4. 防火墙放行 22 ----------
Write-Host "`n[4/4] 防火墙放行 22 端口" -ForegroundColor Cyan
$fw = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
if (-not $fw) {
    try {
        New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
        OK '已新建防火墙规则：放行 TCP 22'
    } catch {
        WARN "创建防火墙规则失败：$($_.Exception.Message)"
    }
} else {
    OK '防火墙规则 OpenSSH-Server-In-TCP 已存在'
}

Write-Host "`n=== 完成 ===`n" -ForegroundColor Green
Write-Host 'Mac 端远程控制还需：Windows 端打开 UU 远程并确认 clipflow-ssh 映射在线。' -ForegroundColor Yellow
