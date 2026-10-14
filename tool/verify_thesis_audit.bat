@echo off
chcp 65001 >nul
rem Run flutter analyze + flutter test and save output for the thesis audit
cd /d "%~dp0\.."
set OUT=test_reports\results\thesis_audit
if not exist "%OUT%" mkdir "%OUT%"
echo running flutter pub get ...
call flutter pub get > "%OUT%\pub_get.txt" 2>&1
echo running flutter analyze ...
call flutter analyze --no-fatal-infos > "%OUT%\analyze.txt" 2>&1
echo exit=%ERRORLEVEL%>> "%OUT%\analyze.txt"
echo running flutter test ...
call flutter test --reporter expanded > "%OUT%\test.txt" 2>&1
echo exit=%ERRORLEVEL%>> "%OUT%\test.txt"
echo DONE> "%OUT%\done.txt"
echo Finished. Results in %OUT%
timeout /t 5
