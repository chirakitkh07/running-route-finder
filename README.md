# 🏃 Running Route Finder — แอปวางแผนเส้นทางวิ่งและประเมินความปลอดภัย

ปริญญานิพนธ์ มทร.ล้านนา — Flutter + Firebase + Node.js Backend

---

## 📥 ดาวน์โหลดทดสอบ (ไม่ต้อง build เอง)

ไปที่หน้า **[Releases](../../releases)** แล้วดาวน์โหลดไฟล์ `app-release.apk` ติดตั้งบน Android ได้เลย

> ⚠️ ต้องเปิด "ติดตั้งจากแหล่งที่ไม่รู้จัก" ในตั้งค่าเครื่อง Android ก่อน

---

## 🛠️ Build เองจาก Source

### สิ่งที่ต้องติดตั้งก่อน
- Flutter SDK ≥ 3.10
- Dart SDK (มาพร้อม Flutter)
- Android Studio หรือ Android SDK
- Node.js ≥ 18 (สำหรับ backend)
- Firebase CLI + FlutterFire CLI

### ขั้นตอน

#### 1. ตั้งค่า Firebase credentials

คัดลอกไฟล์ตัวอย่างแล้วใส่ค่าจริงของ Firebase project:

```bash
# Flutter
cp lib/firebase_options.example.dart lib/firebase_options.dart
# แก้ไขใส่ API key, appId, projectId ของคุณ

# Android
cp android/app/google-services.example.json android/app/google-services.json
# แก้ไขใส่ค่าจริงจาก Firebase Console

# iOS: ลงทะเบียน Bundle ID com.example.demo20426 ใน Firebase Console
# แล้วดาวน์โหลด GoogleService-Info.plist ไปที่ ios/Runner/
# เพิ่มไฟล์ใน Xcode Runner target และตั้งค่า URL Scheme เป็น REVERSED_CLIENT_ID
```

หรือใช้ FlutterFire CLI:
```bash
flutterfire configure --project=fir-walkrunbike-f6792 --platforms=android,ios,web
```

#### 2. Build แอป Flutter

```bash
flutter pub get
flutter run            # รันบนอุปกรณ์/emulator
flutter build apk      # สร้างไฟล์ APK
```

#### 3. รัน Backend (ถ้าต้องการ)

```bash
cd backend
npm install
cp .env.example .env   # แก้ไขค่าตัวแปรตามต้องการ
node server.js         # หรือ npm start (ถ้าตั้ง script ไว้)
```

---

## 🌐 PWA (Progressive Web App) สำหรับ iPhone (Safari) และ Web

แอปพลิเคชันรองรับการทำงานในรูปแบบ **PWA (Progressive Web App)** ทำให้ผู้ใช้ iPhone สามารถใช้งานผ่านเบราว์เซอร์ Safari ได้เต็มหน้าจอโดยไม่ต้องติดตั้งผ่าน App Store

### 1. วิธี Build Web PWA
รันคำสั่งผ่านสคริปต์อัตโนมัติ:
```cmd
tool\build_web.bat
```
หรือรันคำสั่ง Flutter โดยตรง:
```bash
flutter build web --release --dart-define=API_BASE_URL=https://your-api.com --dart-define=VAPID_KEY=YOUR_VAPID_KEY
```

### 2. วิธี Deploy ขึ้น Firebase Hosting
หลังจาก Build เสร็จเรียบร้อย (ผลลัพธ์อยู่ที่ `build/web/`):
```bash
firebase deploy --only hosting
```

### 3. วิธีติดตั้งลงหน้าจออุปกรณ์ (Install PWA)
* **บน iPhone (iOS Safari):**
  1. เปิดลิงก์เว็บแอปในเบราว์เซอร์ **Safari**
  2. แตะที่ปุ่ม **"แชร์" (Share)** ที่แถบเมนูด้านล่าง
  3. เลื่อนลงมาเลือก **"เพิ่มไปยังหน้าจอโฮม" (Add to Home Screen)**
  4. แตะ **"เพิ่ม" (Add)** ที่มุมขวาบน จะได้ไอคอนแอปบนหน้าจอหลักที่เปิดใช้งานได้แบบเต็มจอ (Standalone)
* **บน Android (Chrome) หรือ PC:**
  1. เปิดเว็บแอปบน Google Chrome
  2. แตะที่เมนู 3 จุด หรือแถบแบนเนอร์แจ้งเตือนในแอป แล้วเลือก **"ติดตั้งแอป" (Install App)**

---

## ✅ ฟีเจอร์หลัก

### Core Features
- 🗺️ **ค้นหาและแนะนำเส้นทาง** — คำนวณและวาดเส้นทางบนแผนที่ (OSRM API)
- 🛡️ **ประเมินความปลอดภัย** — คะแนน Safety Score พร้อมแถบสี เขียว/ส้ม/แดง
- 🌤️ **สภาพอากาศและ PM2.5** — ข้อมูล real-time จาก Open-Meteo
- 🏋️ **จำลองการออกกำลังกาย** — ประเมินความยาก เวลา และแสดงผลลัพธ์

### Community Features
- 📍 **รายงานเหตุอันตราย** — ปักหมุดแจ้งเหตุบนแผนที่สาธารณะ
- ✅ **โหวตยืนยัน/ปฏิเสธ** — ผู้ใช้ร่วมตรวจสอบความถูกต้อง
- ⏰ **Time-based Validity** — Cron Job ซ่อนหมุดเก่าเกิน 24 ชม. อัตโนมัติ

### User Management
- 🔐 **Google Sign-In** — เข้าสู่ระบบด้วยบัญชี Google
- ⭐ **เส้นทางโปรด** — บันทึกและเรียกดูเส้นทางที่ชอบ

### Architecture
- **N-Tier Architecture** — แบ่ง UI / Service / Controller ชัดเจน
- **Cross-platform** — Flutter, รันได้ทั้ง Android และ Web

---

## 📁 โครงสร้างโปรเจกต์

```
otc10/
├── lib/                  # Flutter source code
│   ├── models/           # Data models
│   ├── providers/        # State management (Provider)
│   ├── screens/          # UI screens
│   ├── services/         # Business logic & API calls
│   ├── utils/            # Utility functions
│   ├── widgets/          # Reusable widgets
│   └── l10n/             # Localization (Thai/English)
├── assets/               # Images, icons, fonts
├── test/                 # Unit & widget tests
├── backend/              # Node.js API server
│   ├── controllers/
│   ├── services/
│   ├── models/
│   ├── routes/
│   └── config/
├── android/              # Android platform files
├── ios/                  # iOS platform files
├── web/                  # Web platform files
├── docs/                 # Documentation
├── dataconnect/          # Firebase Data Connect
└── tool/                 # Scripts & utilities
```

---

## ⚠️ หมายเหตุ

- ไฟล์ credentials (API keys, service accounts) **ไม่ได้อยู่ใน repo** — ต้องสร้างเองตามขั้นตอนด้านบน
- ดูไฟล์ตัวอย่าง: `lib/firebase_options.example.dart`, `android/app/google-services.example.json`, `backend/.env.example`
