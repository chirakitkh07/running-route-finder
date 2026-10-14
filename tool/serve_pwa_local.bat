@echo off
chcp 65001 >nul
echo ========================================================
echo   Running Finder — Local PWA Test Server
echo ========================================================
if not exist "build\web\index.html" (
    echo [INFO] ยังไม่พบ build\web กำลังสั่ง build ให้อัตโนมัติ...
    call tool\build_web.bat
)
echo.
echo เว็บเซิร์ฟเวอร์เปิดใช้งานเรียบร้อย:
echo   - บนเครื่องคอมพิวเตอร์นี้ : http://localhost:8080
echo   - กด Ctrl + C เพื่อหยุดการทำงาน
echo ========================================================
npx -y serve -s build/web -l 8080
