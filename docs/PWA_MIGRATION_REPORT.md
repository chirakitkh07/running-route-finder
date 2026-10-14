# สรุปผลการพัฒนา Progressive Web App (PWA) และคู่มือการติดตั้งระบบ
**ระบบวางแผนเส้นทางวิ่งและประเมินความปลอดภัย (Running Route Finder)**
**Branch:** `pwa`

---

## 1. ภาพรวมการดำเนินงาน (Overview)

การพัฒนานี้มีเป้าหมายเพื่อยกระดับแอปพลิเคชัน Flutter ให้ทำงานในรูปแบบ **Progressive Web App (PWA)** ได้อย่างสมบูรณ์ เพื่อให้ผู้ใช้งาน **iPhone (iOS Safari)** และคอมพิวเตอร์สามารถเข้าใช้งานได้ทันทีผ่านเว็บเบราว์เซอร์ พร้อมทั้งสามารถติดตั้งลงหน้าจอโฮม (Add to Home Screen) เสมือนแอป Native โดยไม่ต้องผ่าน App Store 

### ข้อกำหนดที่รักษาไว้อย่างเข้มงวด:
1. **เวอร์ชัน Android ไม่ได้รับผลกระทบใดๆ:** โค้ดทั้งหมดที่รันบนอุปกรณ์ Android ยังคงทำงานได้ 100%
2. **ไม่แตะต้องโฟลเดอร์ระบบ Native:** ไม่มีการแก้ไขไฟล์ใดๆ ในโฟลเดอร์ `android/` และ `ios/`
3. **การแยกการทำงานด้วย `kIsWeb`:** ดักจับ Platform ทุกจุดที่มีการใช้งานฮาร์ดแวร์หรือแพ็กเกจที่ไม่รองรับเว็บบนเบราว์เซอร์
4. **ความปลอดภัยของระบบ:** รักษากฎความปลอดภัยของ Firestore และไม่มีการฝังความลับลงในโค้ดส่วนที่เปิดเผย

---

## 2. รายละเอียดการพัฒนาแยกตามเฟส (Phases 1 – 7)

```
[Phase 1] สำรวจโค้ด & ตรวจสอบ CORS API ภายนอก (ผ่านทุกตัว)
    ↓
[Phase 2] แก้ไข Web Compatibility (dart:io, Push, Geo, Google Sign-In)
    ↓
[Phase 3] ตั้งค่า Installable PWA (Manifest, Splash, Icons, PwaInstallPrompt)
    ↓
[Phase 4] บรรเทาข้อจำกัด Web GPS (WakeLock, Keep-Screen-On, Session Recovery)
    ↓
[Phase 5] ซิงก์รายชื่อผู้ติดต่อฉุกเฉิน (Firestore Sync + Migration)
    ↓
[Phase 6] ตั้งค่า Hosting & Script Build (firebase.json, build_web.bat)
    ↓
[Phase 6.5] ระบบอัปเดตเวอร์ชันอัตโนมัติ (UpdateService, version.json, Force Update)
    ↓
[Phase 7] ตรวจสอบคุณภาพ (0 errors, 97 unit tests pass, Android & Web pass)
```

### รายละเอียดการเปลี่ยนแปลงในแต่ละเฟส:

| เฟส | รายละเอียดการพัฒนา | ไฟล์หลักที่แก้ไข/สร้างขึ้น |
|---|---|---|
| **Phase 1** | สำรวจ codebase, ตรวจสอบไลบรารีที่ขัดแย้งกับ Web, ตรวจสอบ CORS headers ของ Open-Meteo, FOSSGIS OSRM และ ORS | `phase1_pwa_survey.md` |
| **Phase 2** | แทนที่ `dart:io Platform` ด้วย `ApiConfig`, ปรับแต่ง `PushService` สำหรับ Web, ป้องกัน Geolocation ขอกดสิทธิ์ตั้งแต่เปิดแอป | `lib/config/api_config.dart`, `lib/services/push_service.dart`, `lib/screens/admin_dashboard_screen.dart`, `lib/screens/record_screen.dart`, `lib/screens/map_screen.dart` |
| **Phase 3** | กำหนดสเปก PWA ใน `manifest.json`, ออกแบบ Splash Screen แบบ CSS, สร้าง `firebase-messaging-sw.js`, สร้าง Widget แนะนำการกด "เพิ่มไปยังหน้าจอโฮม" บน Safari | `web/manifest.json`, `web/index.html`, `web/firebase-messaging-sw.js`, `lib/widgets/pwa_install_prompt.dart` |
| **Phase 4** | ใช้ Screen WakeLock API ป้องกันจอดับขณะวิ่ง, แสดงแบนเนอร์แจ้งเตือนผู้ใช้เปิดจอทิ้งไว้, ระบบกู้คืนเซสชันการวิ่งหากเผลอปิดหรือรีเฟรช, ตัวกรอง GPS กระโดด | `lib/utils/web_wake_lock.dart`, `lib/screens/record_screen.dart` |
| **Phase 5** | เปลี่ยนการเก็บข้อมูลผู้ติดต่อฉุกเฉินจากเครื่องเดี่ยว (`SharedPreferences`) มาบันทึกลง Firestore (`users/{uid}/emergency_contacts/default`) พร้อมระบบ Auto-migration และ Security Rules รัดกุม | `lib/services/emergency_contact_service.dart`, `firestore.rules` |
| **Phase 6** | กำหนด Header Caching ใน `firebase.json` (ห้ามแคช Service Worker / ให้แคชไฟล์สถิตได้นาน), พัฒนาสคริปต์ `tool/build_web.bat` สำหรับ build web อัตโนมัติ | `firebase.json`, `tool/build_web.bat`, `README.md` |
| **Phase 6.5** | เพิ่มระบบตรวจสอบเวอร์ชัน `UpdateService`, ตรวจสอบไฟล์ `version.json`, กลไก Force Update ผ่าน Firestore `settings/app_config`, แสดงเวอร์ชันในหน้าโปรไฟล์ | `web/version.json`, `lib/services/update_service.dart`, `lib/services/web_reload_*.dart`, `lib/screens/home_screen.dart`, `lib/screens/profile_screen.dart` |
| **Phase 7** | ตรวจสอบคุณภาพโค้ด, รัน Unit Test ครบ 97 ข้อ, ทดสอบคอมไพล์ Web และ Android APK สำเร็จ 100% | `docs/PWA_MIGRATION_REPORT.md` |

---

## 3. สิ่งที่ผู้ดูแลระบบต้องตั้งค่าใน Firebase Console (Checklist)

> [!IMPORTANT]
> ระบบจะไม่ดำเนินการปรับแต่ง Firebase Console โดยตรง ผู้ดูแลระบบต้องเข้าไปตั้งค่าผ่านหน้าคอนโซลตามขั้นตอนดังนี้:

### ขั้นตอนที่ 1: เพิ่ม Web App ใน Firebase Project
1. เปิด [Firebase Console](https://console.firebase.google.com/) เข้าสู่โปรเจกต์ `fir-walkrunbike-f6792`
2. คลิกรูปเฟือง **Project Settings (การตั้งค่าโปรเจกต์)** > แท็บ **General (ทั่วไป)**
3. เลื่อนลงมาที่หัวข้อ **Your apps (แอปของคุณ)** หากยังไม่มี Web App ให้คลิกปุ่ม **Add app** เลือกไอคอน **Web (`</>`)**
4. ตั้งชื่อแอป เช่น `Running Route Finder Web` และติ๊กเลือก **"Also set up Firebase Hosting for this app"**

### ขั้นตอนที่ 2: เพิ่ม Authorized Domains ใน Firebase Authentication
เพื่อให้การเข้าสู่ระบบด้วย Google บน Web ใช้งานได้โดยไม่ติดบล็อกความปลอดภัย:
1. ไปที่เมนู **Authentication** > แท็บ **Settings (การตั้งค่า)** > เลือกหัวข้อ **Authorized domains (โดเมนที่ได้รับอนุญาต)**
2. คลิกปุ่ม **Add domain** แล้วเพิ่มโดเมนดังนี้:
   - `localhost` (สำหรับทดสอบในเครื่อง)
   - `fir-walkrunbike-f6792.web.app` (โดเมนของ Firebase Hosting)
   - `fir-walkrunbike-f6792.firebaseapp.com`
   - โดเมนส่วนตัวอื่น ๆ (หากมี)

### ขั้นตอนที่ 3: กำหนด Web Client ID สำหรับ Google Sign-In
1. ไปที่ [Google Cloud Console Credentials](https://console.cloud.google.com/apis/credentials) ของโปรเจกต์เดียวกัน
2. ค้นหา **OAuth 2.0 Client IDs** ชนิด **Web client (auto created by Google Service)**
3. คัดลอกค่า **Client ID** (มีรูปแบบลงท้ายด้วย `.apps.googleusercontent.com`)
4. นำค่านั้นมาวางในไฟล์ [web/index.html](file:///c:/I/Rmutl/project/code/otc10/web/index.html) ที่บรรทัด:
   ```html
   <meta name="google-signin-client_id" content="YOUR_WEB_CLIENT_ID.apps.googleusercontent.com">
   ```

### ขั้นตอนที่ 4: สร้าง VAPID Key สำหรับ Web Push Notifications (FCM)
หากต้องการให้เว็บส่ง Web Push เข้า Safari / Chrome ได้:
1. ใน Firebase Console ไปที่ **Project Settings** > แท็บ **Cloud Messaging**
2. เลื่อนลงมาที่หัวข้อ **Web configuration (การกำหนดค่าเว็บ)** > หัวข้อ **Web Push certificates**
3. คลิกปุ่ม **Generate key pair (สร้างคู่คีย์)**
4. นำคีย์ที่ได้ส่งผ่านคำสั่ง build เช่น:
   ```cmd
   set VAPID_KEY=คีย์ที่ได้จากคอนโซล
   tool\build_web.bat
   ```

### ขั้นตอนที่ 5: Deploy Firestore Rules และ Firebase Hosting
เมื่อเตรียมการเสร็จ ให้รันคำสั่ง deploy จากโฟลเดอร์โปรเจกต์:
```bash
# 1. อัปเดต Security Rules ให้รองรับ emergency_contacts และ settings/app_config
firebase deploy --only firestore:rules

# 2. Deploy Web ขึ้น Hosting
firebase deploy --only hosting
```

---

## 4. ข้อจำกัดและข้อแตกต่างระหว่าง Web PWA กับ Native Android (สำหรับเขียนในเล่มโครงงาน)

เนื้อหาส่วนนี้สรุปความแตกต่างเชิงเทคนิคเพื่อใช้เป็นข้อมูลใน **บทที่ 4 หรือ บทที่ 5 (หัวข้อข้อจำกัดของระบบ - System Limitations)**:

| ปัจจัยเชิงเทคนิค | Native Android Application | Progressive Web App (iOS Safari / Web) | แนวทางการแก้ไขและบรรเทาผลกระทบที่พัฒนาในระบบ |
|---|---|---|---|
| **การรับพิกัด GPS เบื้องหลัง (Background Geolocation)** | ทำงานได้เต็มรูปแบบผ่าน Background Service / Foreground Service แม้ล็อกหน้าจอ | **iOS Safari จะระงับการทำงาน (Freeze/Suspend) การประมวลผล JavaScript ทันที** เมื่อผู้ใช้ล็อกหน้าจอหรือสลับแอป | 1. **Screen WakeLock API:** ล็อกหน้าจอให้สว่างอยู่เสมอขณะกดเริ่มวิ่ง เพื่อไม่ให้ iOS ตัดการทำงานของ GPS<br>2. **Session Recovery:** มีการบันทึกสถานะการวิ่งทุก 5 วินาที หากเผลอปิดแอปหรือหน้าจอรีเฟรช จะมีปุ่มให้กดกู้คืนเส้นทางและเวลาเดิมได้ทันที<br>3. **GPS Jump Filter:** กรองพิกัดกระโดดที่เกิดจากการตื่นตัวของเบราว์เซอร์หลังจากถูกพักการทำงาน |
| **การแจ้งเตือน (Push Notifications)** | รองรับ FCM ในตัว ไม่ต้องมีเงื่อนไขเพิ่มเติม | บน iOS ต้องเป็นเวอร์ชัน **iOS 16.4 ขึ้นไป** และผู้ใช้ต้องกด **"Add to Home Screen"** ก่อนเท่านั้น จึงจะขอสิทธิ์แจ้งเตือนได้ | 1. ออกแบบ Widget แนะนำการติดตั้ง (`PwaInstallPrompt`) แจ้งผู้ใช้ให้เพิ่มลงหน้าจอโฮมก่อน<br>2. ชะลอการขอสิทธิ์แจ้งเตือน ไม่ขัดจังหวะทันทีที่เปิดแอป |
| **การเข้าถึงพื้นที่จัดเก็บข้อมูล (Storage Persistence)** | จัดเก็บในระบบไฟล์ของแอปและฐานข้อมูล SQLite/Room ได้ถาวร | ใช้ **IndexedDB / LocalStorage** ซึ่งอาจถูกระบบปฏิบัติการ iOS กวาดทิ้ง (Eviction) ได้หากหน่วยความจำเครื่องเต็มหรือไม่ได้เปิดใช้งานเกิน 7 วัน | ย้ายการจัดเก็บข้อมูลสำคัญ เช่น **รายชื่อผู้ติดต่อฉุกเฉิน (Emergency Contacts)** จาก local storage ขึ้นสู่คลาวด์ **Cloud Firestore** เพื่อความปลอดภัยและการใช้งานข้ามอุปกรณ์ |
| **การติดตั้งและอัปเดต (Distribution & Updates)** | ต้องติดตั้งผ่านไฟล์ APK หรือ Google Play Store | ผู้ใช้เข้า URL ได้ทันที และกดปุ่มแชร์เพิ่มลงหน้าจอโฮม ไม่ต้องดาวน์โหลดไฟล์ติดตั้งขนาดใหญ่ | **UpdateService & version.json:** มีระบบดึงเลขเวอร์ชันมาตรวจสอบ หากมีเวอร์ชันใหม่ เบราว์เซอร์จะเคลียร์ Service Worker และรีเฟรชเป็นเวอร์ชันล่าสุดให้ทันที |

---

## 5. วิธีรวมโค้ดเข้าสู่ Master เมื่อพร้อม (Merge Workflow)

เนื่องจากงานทั้งหมดพัฒนาอยู่บนกิ่ง **`pwa`** เมื่อผู้ใช้ทดสอบจนพึงพอใจและต้องการรวมเข้าสู่กิ่งหลัก `master`:

```bash
# ตรวจสอบสถานะว่าไม่มีไฟล์ค้าง
git status

# สลับกลับไปกิ่ง master
git checkout master

# ทำการรวมโค้ดจากกิ่ง pwa เข้ามา
git merge pwa

# อัปเดตขึ้น GitHub Remote
git push origin master
```
