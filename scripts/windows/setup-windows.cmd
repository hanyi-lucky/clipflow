@echo off
rem ============================================================
rem  ClipFlow Windows 环境一键配置（Windows 端直接运行）
rem  用法：双击本文件，或用管理员 PowerShell 执行：
rem    powershell -ExecutionPolicy Bypass -File "%~dp0setup-windows.ps1"
rem ============================================================
setlocal

rem 提权：非管理员时以管理员身份重新启动
net session >nul 2>&1
if errorlevel 1 (
  echo 需要管理员权限，正在请求提权...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-windows.ps1"
echo.
pause
