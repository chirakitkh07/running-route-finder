@echo off
chcp 65001 >nul
echo ========================================================
echo   Running Finder — Build Web PWA Release
echo ========================================================

REM กำหนดค่าเริ่มต้น หากไม่มีการส่งผ่าน Environment Variables
if "%API_BASE_URL%"=="" (
    set API_BASE_URL=http://localhost:3000
)

if "%APP_VERSION%"=="" (
    for /f "tokens=2 delims= " %%a in ('findstr /r "^version:" pubspec.yaml') do set APP_VERSION=%%a
)
if "%APP_VERSION%"=="" (
    set APP_VERSION=1.0.0+1
)

echo [1/3] ตรวจสอบความถูกต้องของโค้ด (flutter analyze)...
call flutter analyze
if %errorlevel% neq 0 (
    echo [ERROR] flutter analyze พบข้อผิดพลาด กรุณาแก้ไขก่อน build!
    exit /b %errorlevel%
)

echo [2/3] กำลังคอมไพล์ Flutter Web (Release)...
echo       - APP_VERSION  : %APP_VERSION%
echo       - API_BASE_URL : %API_BASE_URL%
if not "%VAPID_KEY%"=="" (
    echo       - VAPID_KEY    : [CONFIGURED]
    call flutter build web --release --dart-define=APP_VERSION=%APP_VERSION% --dart-define=API_BASE_URL=%API_BASE_URL% --dart-define=VAPID_KEY=%VAPID_KEY%
) else (
    echo       - VAPID_KEY    : [NONE - Optional for Web Push]
    call flutter build web --release --dart-define=APP_VERSION=%APP_VERSION% --dart-define=API_BASE_URL=%API_BASE_URL%
)

if %errorlevel% neq 0 (
    echo [ERROR] การ build web ล้มเหลว!
    exit /b %errorlevel%
)

echo [3/3] Build สำเร็จเรียบร้อย! ไฟล์อยู่ที่ build\web\
echo ========================================================
echo   พร้อมสำหรับการ Deploy ขึ้น Firebase Hosting:
echo   คำสั่ง: firebase deploy --only hosting
echo ========================================================
