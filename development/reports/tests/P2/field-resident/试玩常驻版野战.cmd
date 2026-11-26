@echo off
setlocal
set "RECOLLECTION_WINDOW_DIR=%APPDATA%\Godot\app_userdata\recollection"
chcp 65001 >nul
for %%I in ("%~dp0..\..\..\..\..") do set "repo=%%~fI"
set "base=0da63557563a91290dc3f679fe86dcda779e7d1d"
set "trial=%repo%\out\resident\play-0da6355"
set "engine=D:\Program\Godot\Standard\Godot_v4.7.2-stable_win64.exe"
set "console=D:\Program\Godot\Standard\Godot_v4.7.2-stable_win64_console.exe"
set "RECOLLECTION_MOVE_WORKERS=1"
if not exist "%engine%" goto :failed
if not exist "%console%" goto :failed
if not exist "%trial%" mkdir "%trial%" || goto :failed
set "APPDATA=%repo%\out\resident\play-bbcdc93\appdata"
set "LOCALAPPDATA=%repo%\out\resident\play-bbcdc93\localdata"
if not exist "%trial%\baseline.ready" (
    git -C "%repo%" archive --format=zip --output="%trial%\baseline.zip" "%base%" game || goto :failed
    tar -xf "%trial%\baseline.zip" -C "%trial%" || goto :failed
    echo %base%>"%trial%\baseline.ready"
)
tar -xf "%~dp0experiment.zip" -C "%trial%" game || goto :failed
"%console%" --headless --path "%trial%\game" --import || goto :failed
"%console%" --headless --path "%trial%\game" --script res://native/verify.gd || goto :failed
if /i "%~1"=="--check-only" exit /b 0
set "RECOLLECTION_REMEMBER_WINDOW=1"
start "" "%engine%" --path "%trial%\game" -- --profile=client
exit /b %errorlevel%
:failed
echo 无法启动常驻版野战，请检查 Godot 4.7.2 Standard、Git 及上方错误信息。
if /i "%~1"=="--check-only" exit /b 1
pause
exit /b 1
