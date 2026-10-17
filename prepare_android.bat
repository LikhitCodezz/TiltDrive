@echo off
setlocal
cd /d "%~dp0"
set "SCAFFOLD=%TEMP%\tiltdrive_scaffold_%RANDOM%"
echo Creating a tiny temporary Flutter project to get the Gradle wrapper for this SDK...
flutter create --platforms=android --project-name=tiltdrive_scaffold --org=com.likhit "%SCAFFOLD%"
if errorlevel 1 (
  echo.
  echo Flutter could not create the temporary Android scaffold.
  echo Check that Flutter is installed and available with the command: flutter --version
  pause
  exit /b 1
)
if not exist "%SCAFFOLD%\android\gradlew.bat" (
  echo Flutter created the scaffold, but the Gradle launcher was not found.
  pause
  exit /b 1
)
copy /y "%SCAFFOLD%\android\gradlew.bat" "android\gradlew.bat" >nul
if exist "%SCAFFOLD%\android\gradlew" copy /y "%SCAFFOLD%\android\gradlew" "android\gradlew" >nul
xcopy /e /i /y "%SCAFFOLD%\android\gradle\wrapper" "android\gradle\wrapper" >nul
echo.
echo Android build wrapper is ready. Your TiltDrive app files were kept in place.
echo Next, open this folder in Android Studio and press Run.
pause
