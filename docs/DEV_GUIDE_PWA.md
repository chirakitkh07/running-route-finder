# คู่มือนักพัฒนาสำหรับการพัฒนาและดูแลระบบ PWA (Developer Guide)

คู่มือนี้จัดทำขึ้นสำหรับนักพัฒนาที่ต้องการพัฒนา, ทดสอบ, คอมไพล์ (Build), และ Deploy เว็บแอปพลิเคชัน **Running Finder** ในรูปแบบ **Progressive Web App (PWA)** ด้วย Visual Studio Code และเครื่องมือต่าง ๆ

---

## สารบัญ
1. [สิ่งที่ต้องติดตั้งในเครื่อง (Prerequisites)](#1-สิ่งที่ต้องติดตั้งในเครื่อง-prerequisites)
2. [การ Clone โครงการและการสลับ Branch](#2-การ-clone-โครงการและการสลับ-branch)
3. [ไฟล์ข้อมูลลับและการตั้งค่า Firebase (Credentials Setup)](#3-ไฟล์ข้อมูลลับและการตั้งค่า-firebase-credentials-setup)
4. [การรันและดีบักใน VS Code (Debugging & Launch Configs)](#4-การรันและดีบักใน-vs-code-debugging--launch-configs)
5. [การ Build และ Deploy ขึ้น Firebase Hosting](#5-การ-build-และ-deploy-ขึ้น-firebase-hosting)
6. [ขั้นตอนการ Release เวอร์ชันใหม่ และการตั้ง Force Update](#6-ขั้นตอนการ-release-เวอร์ชันใหม่-และการตั้ง-force-update)
7. [โครงสร้าง Branch และการทำงานร่วมกับ Git](#7-โครงสร้าง-branch-และการทำงานร่วมกับ-git)
8. [กฎเหล็กการเขียนโค้ดรองรับ Cross-Platform (Mobile & Web)](#8-กฎเหล็กการเขียนโค้ดรองรับ-cross-platform-mobile--web)
9. [เอกสารอ้างอิงที่เกี่ยวข้อง](#9-เอกสารอ้างอิงที่เกี่ยวข้อง)

---

## 1. สิ่งที่ต้องติดตั้งในเครื่อง (Prerequisites)

ก่อนเริ่มต้นพัฒนา ตรวจสอบให้แน่ใจว่าได้ติดตั้งเครื่องมือเหล่านี้บนเครื่องเรียบร้อยแล้ว:

1. **Flutter SDK (เวอร์ชัน 3.24+ ขึ้นไป):**
   - ตรวจสอบด้วยคำสั่ง: `flutter doctor`
   - ตรวจสอบว่าเปิดใช้งาน Web Support: `flutter config --enable-web`
2. **Node.js (เวอร์ชัน LTS 20 หรือ 22):**
   - ตรวจสอบด้วยคำสั่ง: `node -v` และ `npm -v`
3. **Firebase CLI:**
   - ติดตั้งผ่าน npm: `npm install -g firebase-tools`
   - เข้าสู่ระบบด้วยคำสั่ง: `firebase login`
   - ตรวจสอบเวอร์ชัน: `firebase --version`
4. **Visual Studio Code Extensions:**
   - **Flutter** (`Dart-Code.flutter`)
   - **Dart** (`Dart-Code.dart-code`)

---

## 2. การ Clone โครงการและการสลับ Branch

```bash
# 1. Clone โครงการจาก GitHub
git clone https://github.com/chirakitkh07/running-route-finder.git
cd running-route-finder

# 2. สลับมายัง branch "pwa" สำหรับการพัฒนาเว็บแอป
git checkout pwa

# 3. ตรวจสอบสถานะ branch ปัจจุบัน
git branch --show-current
# ต้องแสดงผลลัพธ์เป็น: pwa

# 4. ดาวน์โหลด dependencies ทั้งหมด
flutter pub get
```

---

## 3. ไฟล์ข้อมูลลับและการตั้งค่า Firebase (Credentials Setup)

> [!WARNING]
> เพื่อความปลอดภัย ไฟล์คีย์ลับ ข้อมูลเชื่อมต่อ Firebase และ Environment variables จะ **ถูกละเว้นไว้ใน `.gitignore` เสมอ** ห้ามนำขึ้น GitHub เด็ดขาด

นักพัฒนาต้องสร้างไฟล์เหล่านี้ในเครื่องก่อนเริ่มรัน:

### 1. ไฟล์ `lib/firebase_options.dart`
สร้างไฟล์นี้ได้โดยอัตโนมัติผ่านเครื่องมือ **FlutterFire CLI**:
```bash
# ติดตั้ง FlutterFire CLI (หากยังไม่มี)
dart pub global activate flutterfire_cli

# รันคำสั่งสร้างการตั้งค่า Firebase อัตโนมัติ (เลือกโปรเจกต์ fir-walkrunbike-f6792)
flutterfire configure
```
หรือดูรูปแบบโครงสร้างได้จากไฟล์ตัวอย่าง: [lib/firebase_options.example.dart](file:///c:/I/Rmutl/project/code/otc10/lib/firebase_options.example.dart)

### 2. ไฟล์ `android/app/google-services.json` (สำหรับ Android)
- ดาวน์โหลดจาก Firebase Console > Project Settings > แอป Android
- ดูตัวอย่างได้ที่: `android/app/google-services.example.json`

### 3. ไฟล์ `backend/.env` (สำหรับ Backend Server)
- ดูตัวอย่างได้ที่: `backend/.env.example`

---

## 4. การรันและดีบักใน VS Code (Debugging & Launch Configs)

โปรเจกต์ได้กำหนดค่าเริ่มต้นใน [.vscode/launch.json](file:///c:/I/Rmutl/project/code/otc10/.vscode/launch.json) ไว้ให้เรียบร้อยแล้ว โดยมี 3 รูปแบบการรัน:

```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "name": "Mobile",
      "request": "launch",
      "type": "dart"
    },
    {
      "name": "Web (Chrome)",
      "request": "launch",
      "type": "dart",
      "args": ["-d", "chrome"]
    },
    {
      "name": "Web + API (dart-define)",
      "request": "launch",
      "type": "dart",
      "args": [
        "-d",
        "chrome",
        "--dart-define=API_BASE_URL=https://your-api-domain.com",
        "--dart-define=VAPID_KEY=YOUR_VAPID_KEY_HERE"
      ]
    }
  ]
}
```

### วิธีการรันใน VS Code:
1. กดปุ่ม `Ctrl + Shift + D` (เปิดหน้าต่าง Run & Debug)
2. เลือกรูปแบบที่ต้องการรันจาก Dropdown ด้านบน:
   - **`Web (Chrome)`:** เหมาะสำหรับการพัฒนาหน้าจอและฟังก์ชันเว็บทั่วไป
   - **`Mobile`:** เลือกรันบน Android Emulator หรือมือถือจริง
   - **`Web + API (dart-define)`:** รันพร้อมกำหนด URL ของ Backend API
3. กดปุ่ม **F5** หรือกดปุ่มลูกศรสีเขียวเพื่อเริ่มรัน

### การรันผ่าน Terminal Command Line:
```bash
# รันบน Google Chrome
flutter run -d chrome

# รันพร้อมส่งค่า API_BASE_URL
flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:3000
```

---

## 5. การ Build และ Deploy ขึ้น Firebase Hosting

### 1. การ Build Web Release ผ่าน Script อัตโนมัติ:
รันสคริปต์ที่เตรียมไว้ในโฟลเดอร์ `tool/`:
```cmd
tool\build_web.bat
```
*การทำงานของสคริปต์:*
- ดึงเลขเวอร์ชันจาก `pubspec.yaml` อัตโนมัติ
- รัน `flutter analyze` ตรวจสอบคุณภาพโค้ด
- คอมไพล์เป็นเว็บแอปพลิเคชันเวอร์ชัน Release เก็บไว้ที่โฟลเดอร์ `build/web/`

### 2. การทดสอบ PWA ในเครื่องก่อน Deploy (Local Test Server):
```cmd
tool\serve_pwa_local.bat
```
เปิดเบราว์เซอร์เข้าที่: `http://localhost:8080` เพื่อทดสอบ Service Worker, Manifest, และ Cache

### 3. การ Deploy ขึ้น Firebase Hosting:
```bash
# ตรวจสอบว่าโปรเจกต์ชี้ไปที่ fir-walkrunbike-f6792
firebase use default

# Deploy เฉพาะส่วนของ Hosting
firebase deploy --only hosting

# Deploy กฎความปลอดภัย Firestore Rules
firebase deploy --only firestore:rules
```

---

## 6. ขั้นตอนการ Release เวอร์ชันใหม่ และการตั้ง Force Update

เมื่อพัฒนาฟีเจอร์ใหม่และพร้อมปล่อยให้ผู้ใช้ใช้งาน ให้ปฏิบัติตามขั้นตอนดังนี้:

### ขั้นตอนที่ 1: ปรับเลขเวอร์ชันในโค้ด
1. แก้ไขเลขเวอร์ชันใน [pubspec.yaml](file:///c:/I/Rmutl/project/code/otc10/pubspec.yaml) เช่น:
   ```yaml
   version: 1.0.1+2
   ```
2. แก้ไขเลขเวอร์ชันใน [web/version.json](file:///c:/I/Rmutl/project/code/otc10/web/version.json) ให้ตรงกัน:
   ```json
   {
     "version": "1.0.1",
     "build_number": 2,
     "release_date": "2026-10-15"
   }
   ```

### ขั้นตอนที่ 2: สั่ง Build และ Deploy
```cmd
tool\build_web.bat
firebase deploy --only hosting
```

### ขั้นตอนที่ 3: การตั้ง Force Update (กรณีต้องการบังคับให้แอปเก่าต้องอัปเดต)
หากมีการเปลี่ยนแปลงโครงสร้างฐานข้อมูลหรือ API ที่ไม่รองรับเวอร์ชันเดิม:
1. เปิด **Firebase Console** > เข้าสู่ **Cloud Firestore**
2. ไปที่ Collection: `settings` > Document: `app_config`
3. แก้ไขฟิลด์ดังนี้:
   ```json
   {
     "min_version": "1.0.1",
     "latest_apk_url": "https://github.com/chirakitkh07/running-route-finder/releases/latest",
     "message": "กรุณาอัปเดตแอปพลิเคชันเป็นเวอร์ชันล่าสุดเพื่อความปลอดภัยและฟีเจอร์ใหม่"
   }
   ```
4. ผู้ใช้ที่เปิดแอปด้วยเวอร์ชันต่ำกว่า `1.0.1` จะพบหน้าต่างบังคับอัปเดตและไม่สามารถกดข้ามได้

---

## 7. โครงสร้าง Branch และการทำงานร่วมกับ Git

### นโยบาย Branch ของโครงการ:
- **`master`:** เวอร์ชันหลักของแอปพลิเคชัน (เน้น Android Mobile เป็นหลัก)
- **`pwa`:** เวอร์ชันที่เพิ่มการรองรับ Progressive Web App (PWA) และ Web Browser

### วิธีการสลับ Branch ใน VS Code:
1. มองไปที่ **แถบสถานะด้านล่างสุด (Status Bar) มุมซ้ายล่าง**
2. คลิกที่ชื่อ Branch ปัจจุบัน (เช่น `master` หรือ `pwa`)
3. เมนูด้านบนจะแสดงรายการ Branch ให้คลิกเลือก `pwa` หรือ `master` เพื่อสลับทันที

> [!CAUTION]
> **ข้อควรระวังในการใช้ Git:**
> - ให้ทำงานและ commit บน branch `pwa` เท่านั้น
> - ห้ามใช้คำสั่ง `git checkout master`, `git merge`, หรือ `git push origin master` โดยไม่ได้รับความเห็นชอบจากหัวหน้าทีม

---

## 8. กฎเหล็กการเขียนโค้ดรองรับ Cross-Platform (Mobile & Web)

เพื่อให้แอปพลิเคชันทำงานได้สมบูรณ์ทั้งบน Android และ Web PWA โดยไม่มีข้อผิดพลาดรันไทม์:

1. **ห้าม Import `dart:io` โดยตรงในไฟล์ที่ Web ต้องใช้งาน:**
   - การเรียกใช้ `Platform.isAndroid` หรือ `Platform.isIOS` จะทำให้ Web แครชทันที
   - **แนวทางที่ถูกต้อง:** ใช้ `kIsWeb` จาก `package:flutter/foundation.dart`:
     ```dart
     import 'package:flutter/foundation.dart';

     if (kIsWeb) {
       // โค้ดสำหรับ Web PWA
     } else {
       // โค้ดสำหรับ Mobile Native
     }
     ```
2. **การเรียกใช้ Web Browser APIs:**
   - ให้ใช้เทคนิค **Conditional Imports** และ `dart:js_interop` ร่วมกับไฟล์ Stub เสมอ เช่น:
     - `web_reload_stub.dart` (สำหรับ Mobile)
     - `web_reload_web.dart` (สำหรับ Web)
3. **การเข้าถึงฮาร์ดแวร์และตำแหน่ง (GPS):**
   - ห้ามสั่งขอสิทธิ์ Geolocation ทันทีที่เปิดแอป ให้รอจนกว่าผู้ใช้จะกดเข้าหน้าจอแผนที่หรือกดเริ่มวิ่ง
4. **การรัน Unit Test ทุกครั้งก่อน Commit:**
   ```powershell
   flutter test
   ```

---

## 9. เอกสารอ้างอิงที่เกี่ยวข้อง

- [docs/USER_GUIDE_PWA.md](file:///c:/I/Rmutl/project/code/otc10/docs/USER_GUIDE_PWA.md) — คู่มือการใช้งานสำหรับผู้ใช้ทั่วไป
- [docs/PWA_MIGRATION_REPORT.md](file:///c:/I/Rmutl/project/code/otc10/docs/PWA_MIGRATION_REPORT.md) — รายงานการพัฒนา PWA และการวิเคราะห์ข้อจำกัดทางเทคนิค
- [README.md](file:///c:/I/Rmutl/project/code/otc10/README.md) — ภาพรวมของโครงการ Running Finder
