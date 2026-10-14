# คู่มือการทดสอบ (Unit Test + ทดสอบบนมือถือ)

โฟลเดอร์นี้เก็บ **ผลการทดสอบ** และ **วิธีทดสอบด้วยตัวเอง** ของแอปวางแผนเส้นทางวิ่งฯ

```
test_reports/
├── README.md                    ← คู่มือนี้
├── run_tests.ps1                ← สคริปต์รัน unit test + สร้างรายงานอัตโนมัติ
├── MANUAL_TEST_CHECKLIST.md     ← เช็กลิสต์ทดสอบบนมือถือจริง (กรอกผลเอง)
└── results/
    └── 2026-10-14_1307/         ← ผลแต่ละครั้ง (ชื่อ = วันที่_เวลา)
        ├── summary.md           ← สรุปผลเป็นตาราง (ใช้แนบเล่ม)
        ├── results.csv          ← ตารางเดียวกัน เปิดด้วย Excel ได้
        ├── console.txt          ← ข้อความจาก flutter test ทั้งหมด
        ├── results.json         ← ผลดิบ (JSON reporter)
        └── flutter_version.txt  ← เวอร์ชัน Flutter ที่ใช้รัน
```

ตัวแปลง JSON → รายงานอยู่ที่ `tool/test_report.dart`

---

## 1. Unit Test แบบอัตโนมัติ (แนะนำ)

เปิด Terminal ที่โฟลเดอร์โปรเจกต์ (`otc10`) แล้วรัน

```powershell
powershell -ExecutionPolicy Bypass -File test_reports\run_tests.ps1
```

- ใช้เวลาประมาณ 10 วินาที–1 นาที (ครั้งแรกนานกว่าเพราะต้อง compile)
- เมื่อเสร็จ จะมีโฟลเดอร์ใหม่ใน `test_reports/results/` → เปิด `summary.md` ดูผล
- บรรทัดสุดท้ายจะขึ้น **ผลรวม: ผ่านทั้งหมด** (สีเขียว) หรือ **มีข้อไม่ผ่าน** (สีแดง)

รันเฉพาะบางไฟล์:

```powershell
powershell -ExecutionPolicy Bypass -File test_reports\run_tests.ps1 test\safety_scoring_test.dart
powershell -ExecutionPolicy Bypass -File test_reports\run_tests.ps1 test\route_loop_test.dart test\unit_tests_table_4_1_test.dart
```

## 2. Unit Test แบบสั่งเอง (ไม่สร้างรายงาน)

```powershell
flutter test                                   # ทุกไฟล์ใน test/
flutter test test\unit_tests_table_4_1_test.dart   # ไฟล์เดียว
flutter test --plain-name "UT-03"              # เฉพาะเทสต์ที่ชื่อมีคำว่า UT-03
flutter test --reporter expanded               # แสดงชื่อเทสต์ทุกข้อ
flutter analyze                                # ตรวจโค้ด ต้องไม่มี error
```

## 3. ไฟล์ทดสอบมีอะไรบ้าง

| ไฟล์ | ทดสอบอะไร | อ้างอิงเล่ม |
|---|---|---|
| `test/unit_tests_table_4_1_test.dart` | UT-01–UT-23: AQI, ป้าย/สี AQI, คะแนนตามเวลา, ระดับความยาก + สมการคะแนนความปลอดภัย + SimulationEngine | ตาราง 4.1, สมการ 3.1–3.2, ตาราง 3.16 |
| `test/safety_scoring_test.dart` | กฎหักคะแนนจราจร/ไฟจราจร, SafetyDijkstraService | บท 3.3.5 |
| `test/running_zones_phase1_test.dart` | pointInPolygon, bufferPolyline, RunningZone toMap/fromMap, ระดับสีคะแนน, 13 โซนเริ่มต้น | ระบบโซนวิ่ง เฟส 1 |
| `test/running_zones_phase2_test.dart` | ZoneRecommender (คะแนน R), พื้นที่ Shoelace, การซ้อนทับ polygon, เหตุผลแนะนำ, Geohash | เฟส 2 |
| `test/running_zones_phase3_test.dart` | S_pop ความนิยม, ตรวจการวิ่งผ่านโซน, ISO week, โบนัสปักหมุด, ห้ามลบโซนที่ใช้งาน (UC-08) | เฟส 3 |
| `test/route_loop_test.dart` | extractLoop (ตัดทางไป-กลับ), เส้นทางยอดนิยมแนบถนน, วงรอบโซนที่ฝังในแอป | เส้นทางตามถนนจริง |
| `test/widget_test.dart` | smoke test | – |

## 4. อ่านรายงาน / เมื่อมีข้อไม่ผ่าน

1. เปิด `summary.md` → ดูตารางสรุปบนสุด (ทั้งหมด / ผ่าน / ไม่ผ่าน / อัตราผ่าน)
2. ข้อที่ไม่ผ่านมีเครื่องหมาย ❌ และรายละเอียดอยู่ท้ายไฟล์ในหัวข้อ **รายละเอียดข้อที่ไม่ผ่าน**
   (บอกว่าค่าที่ได้ `Actual` ต่างจากที่คาด `Expected` อย่างไร และอยู่บรรทัดไหน)
3. รันเฉพาะข้อนั้นซ้ำเพื่อดูละเอียด: `flutter test --plain-name "ชื่อเทสต์"`
4. แก้โค้ด (หรือแก้เทสต์ถ้าสเปกเปลี่ยน — เช่น สูตรต้องตรงเล่ม บท 3.3.5) แล้วรันสคริปต์ใหม่
5. ถ้า `console.txt` มีคำว่า `Failed to load` แปลว่าไฟล์เทสต์ compile ไม่ผ่าน → รัน `flutter analyze`

**ใส่ผลในเล่ม:** เปิด `results.csv` ด้วย Excel → คัดลอกตารางไปวางใน Word หรือคัดลอกตารางจาก `summary.md`

## 5. ทดสอบกับ API จริง (เส้นทาง/โซน)

ไม่ได้อยู่ใน `flutter test` ปกติ เพราะต้องใช้อินเทอร์เน็ตและ Overpass ช้า/ล่มบ่อย

```powershell
flutter test tool\route_check_test.dart
```

ผลอยู่ที่ `build/route_check/summary.txt` และไฟล์ `*.geojson`
(ลากไฟล์ geojson ไปวางที่ https://geojson.io เพื่อดูเส้นทางบนแผนที่ว่าวิ่งตามถนนจริง ไม่ตัดผ่านตึก)
ถ้าต้องการเก็บผลไว้เป็นหลักฐาน ให้คัดลอก `build/route_check/` มาไว้ใน `test_reports/results/<วันที่>_route_check/`

## 6. ทดสอบบนมือถือจริง

ดู [`MANUAL_TEST_CHECKLIST.md`](MANUAL_TEST_CHECKLIST.md) — คัดลอกไฟล์ไปไว้ใน `results/<วันที่>_device/`
แล้วกรอกผลทีละข้อ

ลงแอป (Xiaomi ต้องเปิด USB debugging (Security settings) ด้วย):

```powershell
flutter run                                   # รันแบบ debug ผ่านสาย USB
# หรือ build แล้วติดตั้งทับ (ข้อมูลในเครื่องไม่หาย)
flutter build apk --debug --target-platform android-arm64 --split-per-abi
adb install -r build\app\outputs\flutter-apk\app-arm64-v8a-debug.apk
```

ถ่ายหน้าจอเป็นหลักฐาน:

```powershell
adb exec-out screencap -p > test_reports\results\<โฟลเดอร์>\TC-01.png
```

## 7. เพิ่มเทสต์ใหม่

- สร้างไฟล์ `test/<ชื่อ>_test.dart` (ต้องลงท้าย `_test.dart` จึงจะถูกรัน)
- ตั้งชื่อเทสต์ให้อ่านแล้วรู้ผลที่คาด เช่น `test('UT-24 calculateAQI: PM2.5 = 150 → AQI ≈ 200', ...)`
- ใช้ `group('...')` จัดกลุ่ม — ชื่อกลุ่มจะเป็นคอลัมน์ "กลุ่ม" ในรายงาน
- รัน `run_tests.ps1` ใหม่ แล้วอัปเดตตารางในหัวข้อ 3

## 8. ก่อนส่งงาน / ก่อน commit

- [ ] `flutter analyze` ไม่มี error
- [ ] `run_tests.ps1` ผ่านทั้งหมด และเก็บโฟลเดอร์ผลล่าสุดไว้
- [ ] ทดสอบบนมือถือตามเช็กลิสต์ครบ
