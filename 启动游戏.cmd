@echo off
setlocal
set "RECOLLECTION_WINDOW_DIR=%APPDATA%\Godot\app_userdata\recollection"
chcp 65001 >nul
set "engine=D:\Program\Godot\Standard\Godot_v4.7.2-stable_win64.exe"
set "project=%~dp0game"

if not exist "%engine%" (
    echo 找不到 Godot，请检查引擎路径 "%engine%"。
    goto :failed
)
if not exist "%project%\project.godot" (
    echo 找不到游戏项目，请将此脚本放在仓库根目录。
    goto :failed
)

echo 正在检查游戏资源，首次启动可能需要一点时间……
"%engine%" --headless --path "%project%" --import
if errorlevel 1 goto :failed
set "RECOLLECTION_REMEMBER_WINDOW=1"
start "" "%engine%" --path "%project%" -- --profile=client
if errorlevel 1 goto :failed
exit /b 0

:failed
echo 游戏启动失败。
pause
exit /b 1
