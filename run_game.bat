@echo off
setlocal
cd /d "%~dp0"
echo Checking the small WebSocket relay dependency...
python -c "import websockets" >nul 2>&1
if errorlevel 1 python -m pip install -r requirements.txt
if errorlevel 1 (
  echo.
  echo Dependency setup failed. Make sure Python is installed and try again.
  pause
  exit /b 1
)
echo.
echo Leave this window open while you play. The room code appears below.
echo Open http://localhost:8000 on the laptop. Connect the phone to the same Wi-Fi.
echo.
python server.py
pause
