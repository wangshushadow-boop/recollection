@echo off
setlocal
chcp 65001 >nul
for %%I in ("%~dp0..\..\..\..\..") do set "repo=%%~fI"
set "trial=%repo%\out\native-move\play-5277bd4-8da02c3c"
set "engine=D:\Program\Godot\Standard\Godot_v4.7.2-stable_win64.exe"
set "console=D:\Program\Godot\Standard\Godot_v4.7.2-stable_win64_console.exe"
if not exist "%engine%" goto :failed
if not exist "%console%" goto :failed
if not exist "%trial%" mkdir "%trial%" || goto :failed
set "APPDATA=%trial%\appdata"
set "LOCALAPPDATA=%trial%\localdata"
if not exist "%trial%\baseline.ready" (
    git -C "%repo%" archive --format=zip --output="%trial%\baseline.zip" 5277bd474a74841f7c4d3d5e64e0f5cfbdf081b5 game || goto :failed
    tar -xf "%trial%\baseline.zip" -C "%trial%" || goto :failed
    echo 5277bd4>"%trial%\baseline.ready"
)
tar -xf "%~dp0experiment.zip" -C "%trial%" || goto :failed
"%console%" --headless --path "%trial%\game" --import || goto :failed
"%console%" --headless --path "%trial%\game" --script res://native/verify.gd || goto :failed
if /i "%~1"=="--check-only" exit /b 0
start "" "%engine%" --path "%trial%\game" --resolution 960x600 -- --profile=client
exit /b %errorlevel%
:failed
echo 无法启动 C++ 试玩版，请检查 Godot 4.7.2 Standard、Git 及上方错误信息。
if /i "%~1"=="--check-only" exit /b 1
pause
exit /b 1
