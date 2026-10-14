# รายงานผลการทดสอบระดับหน่วย (Unit Test)

- วันที่รัน: 2026-10-14 13:07
- ไฟล์ผลดิบ: `results.json`
- เวลารวม: 5.2 วินาที

| ทั้งหมด | ผ่าน | ไม่ผ่าน | ข้าม | อัตราผ่าน |
|---:|---:|---:|---:|---:|
| 84 | 84 | 0 | 0 | 100.0% |

**ผลรวม: ✅ ผ่านทั้งหมด**

## `test/route_loop_test.dart` (7/7)

| ลำดับ | กลุ่ม | กรณีทดสอบ | ผล | เวลา (ms) |
|---:|---|---|:---:|---:|
| 1 | RoutingService.extractLoop | ตัดติ่งไป-กลับออก เหลือวงปิดเท่าเส้นรอบรูป | ✅ ผ่าน | 60 |
| 2 | RoutingService.extractLoop | ติ่งที่มีวงย่อยอยู่ปลายทาง: ทิ้งทางเชื่อมที่เดินไป-กลับ เก็บวงที่ยาวที่สุด | ✅ ผ่าน | 14 |
| 3 | RoutingService.extractLoop | ติ่งผอมยาว: ออกทางหนึ่ง กลับอีกทางที่ขนานกัน (ห่าง ~30 ม.) ถูกตัดออก | ✅ ผ่าน | 10 |
| 4 | RoutingService.extractLoop | เส้นที่เดินไป-กลับล้วน ๆ ไม่มีวง → คืนลิสต์ว่าง | ✅ ผ่าน | 17 |
| 5 | เส้นทางยอดนิยม (ChiangMaiRoutes) | ทุกเส้นใช้ path ที่สร้างจาก Routing API และระยะทางตรงกับ path | ✅ ผ่าน | 16 |
| 6 | เส้นทางยอดนิยม (ChiangMaiRoutes) | setRoutes: path วาดมือจาก Firestore ถูกแทนด้วย path ที่แนบถนน | ✅ ผ่าน | 23 |
| 7 | เส้นทางวงรอบของโซนที่มีเส้นทางในแอป | ใช้เส้นที่แนบถนนไว้แล้วได้ทันที แม้ยังไม่ได้ขอบเขตจริงจาก OSM | ✅ ผ่าน | 18 |

## `test/running_zones_phase1_test.dart` (12/12)

| ลำดับ | กลุ่ม | กรณีทดสอบ | ผล | เวลา (ms) |
|---:|---|---|:---:|---:|
| 8 | เฟส 1: Unit Tests สำหรับระบบโซนวิ่ง (Running Zones) ZoneService.pointInPolygon (Ray Casting Algorithm) | จุดอยู่ภายในรูปหลายเหลี่ยม คืนค่า true | ✅ ผ่าน | 69 |
| 9 | เฟส 1: Unit Tests สำหรับระบบโซนวิ่ง (Running Zones) ZoneService.pointInPolygon (Ray Casting Algorithm) | จุดอยู่นอกรูปหลายเหลี่ยม คืนค่า false | ✅ ผ่าน | 6 |
| 10 | เฟส 1: Unit Tests สำหรับระบบโซนวิ่ง (Running Zones) ZoneService.pointInPolygon (Ray Casting Algorithm) | รูปหลายเหลี่ยมที่มีจุดน้อยกว่า 3 จุด คืนค่า false เสมอ | ✅ ผ่าน | 7 |
| 11 | เฟส 1: Unit Tests สำหรับระบบโซนวิ่ง (Running Zones) ZoneService.pointInPolygon (Ray Casting Algorithm) | รูปหลายเหลี่ยมรูปตัว L (concave polygon) | ✅ ผ่าน | 8 |
| 12 | เฟส 1: Unit Tests สำหรับระบบโซนวิ่ง (Running Zones) bufferPolyline (สร้างแถบขอบเขตริบบอน) | จำนวนจุดใน polygon ที่ได้มีค่าเท่ากับ 2 × n เสมอ | ✅ ผ่าน | 13 |
| 13 | เฟส 1: Unit Tests สำหรับระบบโซนวิ่ง (Running Zones) bufferPolyline (สร้างแถบขอบเขตริบบอน) | กรณี path ว่าง คืนค่า empty list | ✅ ผ่าน | 9 |
| 14 | เฟส 1: Unit Tests สำหรับระบบโซนวิ่ง (Running Zones) bufferPolyline (สร้างแถบขอบเขตริบบอน) | พิกัดของ buffer ทุกจุดต้องเป็น finite ไม่เป็น NaN หรือ Infinity | ✅ ผ่าน | 8 |
| 15 | เฟส 1: Unit Tests สำหรับระบบโซนวิ่ง (Running Zones) RunningZone Serialization (toMap / fromMap round-trip) | แปลง toMap() แล้ว fromMap() ได้ข้อมูลครบถ้วนตรงกัน | ✅ ผ่าน | 20 |
| 16 | เฟส 1: Unit Tests สำหรับระบบโซนวิ่ง (Running Zones) SafetyScoreEngine — การจัดระดับและสีตามตาราง 3.16 | คะแนน >= 70 ระดับ safe สีเขียว 0xFF2ECC71 | ✅ ผ่าน | 10 |
| 17 | เฟส 1: Unit Tests สำหรับระบบโซนวิ่ง (Running Zones) SafetyScoreEngine — การจัดระดับและสีตามตาราง 3.16 | คะแนน 40–69 ระดับ caution สีเหลือง 0xFFF39C12 | ✅ ผ่าน | 7 |
| 18 | เฟส 1: Unit Tests สำหรับระบบโซนวิ่ง (Running Zones) SafetyScoreEngine — การจัดระดับและสีตามตาราง 3.16 | คะแนน < 40 ระดับ highRisk สีแดง 0xFFE74C3C | ✅ ผ่าน | 7 |
| 19 | เฟส 1: Unit Tests สำหรับระบบโซนวิ่ง (Running Zones) PresetZones — โซนเริ่มต้น 13 โซน | มีครบ 13 โซนเริ่มต้นและมีขอบเขต polygon ที่ถูกต้อง | ✅ ผ่าน | 20 |

## `test/running_zones_phase2_test.dart` (13/13)

| ลำดับ | กลุ่ม | กรณีทดสอบ | ผล | เวลา (ms) |
|---:|---|---|:---:|---:|
| 20 | เฟส 2: Unit Tests ระบบค้นหาและจัดอันดับโซนวิ่งอัตโนมัติ ZoneRecommender — สูตรคำนวณคะแนนแนะนำ R | ผลรวมค่าน้ำหนัก wSafety + wDist + wLen + wPop เท่ากับ 1.0 | ✅ ผ่าน | 35 |
| 21 | เฟส 2: Unit Tests ระบบค้นหาและจัดอันดับโซนวิ่งอัตโนมัติ ZoneRecommender — สูตรคำนวณคะแนนแนะนำ R | กรณีโซนไกลกว่ารัศมี (d >= radius) ต้องได้ S_dist = 0 | ✅ ผ่าน | 9 |
| 22 | เฟส 2: Unit Tests ระบบค้นหาและจัดอันดับโซนวิ่งอัตโนมัติ ZoneRecommender — สูตรคำนวณคะแนนแนะนำ R | กรณีโซนอยู่ที่ระยะ 0 กม. (d = 0) ได้ S_dist = 100 เต็ม | ✅ ผ่าน | 25 |
| 23 | เฟส 2: Unit Tests ระบบค้นหาและจัดอันดับโซนวิ่งอัตโนมัติ ZoneRecommender — สูตรคำนวณคะแนนแนะนำ R | ความยาวทางวิ่ง walkableLengthKm >= 3.0 กม. ได้ S_len เต็ม 100 | ✅ ผ่าน | 8 |
| 24 | เฟส 2: Unit Tests ระบบค้นหาและจัดอันดับโซนวิ่งอัตโนมัติ ZoneRecommender — สูตรคำนวณคะแนนแนะนำ R | ความยาวทางวิ่ง 1.5 กม. ได้ S_len เท่ากับ 50 | ✅ ผ่าน | 5 |
| 25 | เฟส 2: Unit Tests ระบบค้นหาและจัดอันดับโซนวิ่งอัตโนมัติ GeoUtils.calculateShoelaceArea — คำนวณพื้นที่ Polygon | สี่เหลี่ยมจัตุรัส 100x100 ม. ได้พื้นที่ ≈ 10,000 ตร.ม. (±2%) | ✅ ผ่าน | 32 |
| 26 | เฟส 2: Unit Tests ระบบค้นหาและจัดอันดับโซนวิ่งอัตโนมัติ GeoUtils.calculateShoelaceArea — คำนวณพื้นที่ Polygon | รูปหลายเหลี่ยมที่มีจุดน้อยกว่า 3 จุด คืนค่า 0.0 | ✅ ผ่าน | 11 |
| 27 | เฟส 2: Unit Tests ระบบค้นหาและจัดอันดับโซนวิ่งอัตโนมัติ GeoUtils.calculatePolygonOverlap — การตัดซ้ำ Polygon | รูปสองรูปที่ซ้อนทับกันอย่างมีนัยสำคัญ ได้ overlap >= 0.60 | ✅ ผ่าน | 11 |
| 28 | เฟส 2: Unit Tests ระบบค้นหาและจัดอันดับโซนวิ่งอัตโนมัติ GeoUtils.calculatePolygonOverlap — การตัดซ้ำ Polygon | รูปสองรูปที่อยู่ห่างกันคนละพื้นที่ คืนค่า overlap = 0.0 | ✅ ผ่าน | 5 |
| 29 | เฟส 2: Unit Tests ระบบค้นหาและจัดอันดับโซนวิ่งอัตโนมัติ ZoneRecommender.generateReasons — การสร้างเหตุผลแนะนำ | สร้างเหตุผลแนะนำ 2–3 ข้อตามคุณลักษณะของโซน | ✅ ผ่าน | 14 |
| 30 | เฟส 2: Unit Tests ระบบค้นหาและจัดอันดับโซนวิ่งอัตโนมัติ ZoneRecommender.generateReasons — การสร้างเหตุผลแนะนำ | โซนที่ไม่มีข้อมูลเสริมยังมีเหตุผลเริ่มต้นที่เหมาะสม | ✅ ผ่าน | 9 |
| 31 | เฟส 2: Unit Tests ระบบค้นหาและจัดอันดับโซนวิ่งอัตโนมัติ GeoUtils — Geohash-5 Encoding & Neighbors | encodeGeohash5 คืนค่าความยาว 5 ตัวอักษรและพิกัดเดียวกันได้ผลลัพธ์เดิม | ✅ ผ่าน | 6 |
| 32 | เฟส 2: Unit Tests ระบบค้นหาและจัดอันดับโซนวิ่งอัตโนมัติ GeoUtils — Geohash-5 Encoding & Neighbors | getGeohashNeighbors คืนช่องรอบข้างรวมช่องตัวเองครบ 9 ช่อง | ✅ ผ่าน | 10 |

## `test/running_zones_phase3_test.dart` (13/13)

| ลำดับ | กลุ่ม | กรณีทดสอบ | ผล | เวลา (ms) |
|---:|---|---|:---:|---:|
| 33 | เฟส 3: Unit Tests ความนิยมจากมวลชน (S_pop) และเครื่องมือผู้ดูแล (UC-08) ZonePopularityService.calculatePopScore — คำนวณคะแนนความนิยม S_pop | เมื่อ runs_4w = 0 คืนค่า S_pop = 0 | ✅ ผ่าน | 77 |
| 34 | เฟส 3: Unit Tests ความนิยมจากมวลชน (S_pop) และเครื่องมือผู้ดูแล (UC-08) ZonePopularityService.calculatePopScore — คำนวณคะแนนความนิยม S_pop | เมื่อ runs_4w = P90 (20 ครั้ง) คืนค่า S_pop = 100 เต็ม | ✅ ผ่าน | 8 |
| 35 | เฟส 3: Unit Tests ความนิยมจากมวลชน (S_pop) และเครื่องมือผู้ดูแล (UC-08) ZonePopularityService.calculatePopScore — คำนวณคะแนนความนิยม S_pop | เมื่อ runs_4w มากกว่า P90 ต้องถูกจำกัดไม่เกิน 100 (clamp) | ✅ ผ่าน | 5 |
| 36 | เฟส 3: Unit Tests ความนิยมจากมวลชน (S_pop) และเครื่องมือผู้ดูแล (UC-08) ZonePopularityService.calculatePopScore — คำนวณคะแนนความนิยม S_pop | การปรับสเกลแบบ Logarithmic ให้คะแนนเติบโตตามสัดส่วน | ✅ ผ่าน | 6 |
| 37 | เฟส 3: Unit Tests ความนิยมจากมวลชน (S_pop) และเครื่องมือผู้ดูแล (UC-08) ZonePopularityService.isRouteInZone — เกณฑ์ตรวจจับการวิ่งผ่านโซน | มีจุดในโซน >= 30% (เช่น 5 จาก 10 จุด = 50%) คืนค่า true | ✅ ผ่าน | 8 |
| 38 | เฟส 3: Unit Tests ความนิยมจากมวลชน (S_pop) และเครื่องมือผู้ดูแล (UC-08) ZonePopularityService.isRouteInZone — เกณฑ์ตรวจจับการวิ่งผ่านโซน | มีจุดในโซน < 30% (เช่น 2 จาก 10 จุด = 20%) คืนค่า false | ✅ ผ่าน | 7 |
| 39 | เฟส 3: Unit Tests ความนิยมจากมวลชน (S_pop) และเครื่องมือผู้ดูแล (UC-08) ZonePopularityService.isRouteInZone — เกณฑ์ตรวจจับการวิ่งผ่านโซน | เส้นทางว่างเปล่า คืนค่า false | ✅ ผ่าน | 6 |
| 40 | เฟส 3: Unit Tests ความนิยมจากมวลชน (S_pop) และเครื่องมือผู้ดูแล (UC-08) ZonePopularityService — ISO Week Key Formatting | getIsoWeekKey ได้รูปแบบมาตรฐาน yyyy-Www | ✅ ผ่าน | 10 |
| 41 | เฟส 3: Unit Tests ความนิยมจากมวลชน (S_pop) และเครื่องมือผู้ดูแล (UC-08) ZonePopularityService — ISO Week Key Formatting | getRecent4WeekKeys คืนค่า 4 สัปดาห์ย้อนหลังครบถ้วน | ✅ ผ่าน | 5 |
| 42 | เฟส 3: Unit Tests ความนิยมจากมวลชน (S_pop) และเครื่องมือผู้ดูแล (UC-08) ZoneRecommender — Pinned Zone Bonus | โซนที่ปักหมุดได้คะแนนแนะนำ R เพิ่ม +10 คะแนน | ✅ ผ่าน | 6 |
| 43 | เฟส 3: Unit Tests ความนิยมจากมวลชน (S_pop) และเครื่องมือผู้ดูแล (UC-08) ZoneRecommender — Pinned Zone Bonus | คะแนน R ของโซนที่ปักหมุดไม่เกิน 100 แม้คะแนนพื้นฐานสูง | ✅ ผ่าน | 5 |
| 44 | เฟส 3: Unit Tests ความนิยมจากมวลชน (S_pop) และเครื่องมือผู้ดูแล (UC-08) UC-08 E2 — การป้องกันการลบโซนที่มีการใช้งาน | เมื่อ runs_4w > 0 กฎกำหนดให้ต้องปฏิเสธการลบ | ✅ ผ่าน | 5 |
| 45 | เฟส 3: Unit Tests ความนิยมจากมวลชน (S_pop) และเครื่องมือผู้ดูแล (UC-08) UC-08 E2 — การป้องกันการลบโซนที่มีการใช้งาน | เมื่อ runs_4w == 0 สามารถลบโซนได้ | ✅ ผ่าน | 7 |

## `test/safety_scoring_test.dart` (3/3)

| ลำดับ | กลุ่ม | กรณีทดสอบ | ผล | เวลา (ms) |
|---:|---|---|:---:|---:|
| 46 | Safety Score Deduction Rules | Traffic congestion deduction (<=10% = 0, 10-30% = 5, >30% = 10) | ✅ ผ่าน | 50 |
| 47 | Safety Score Deduction Rules | Traffic light deduction (0-1 = 0, 2-3 = 5, >=4 = 10) | ✅ ผ่าน | 6 |
| 48 | Safety Dijkstra Algorithm with Traffic and Light penalties | Calculates path and penalizes congested segments and traffic lights | ✅ ผ่าน | 24 |

## `test/unit_tests_table_4_1_test.dart` (35/35)

| ลำดับ | กลุ่ม | กรณีทดสอบ | ผล | เวลา (ms) |
|---:|---|---|:---:|---:|
| 49 | ตารางที่ 4.1 การทดสอบระดับหน่วย | UT-01 calculateAQI: PM2.5 = 0 → AQI = 0 | ✅ ผ่าน | 27 |
| 50 | ตารางที่ 4.1 การทดสอบระดับหน่วย | UT-02 calculateAQI: PM2.5 = 12.0 → AQI = 50 | ✅ ผ่าน | 4 |
| 51 | ตารางที่ 4.1 การทดสอบระดับหน่วย | UT-03 calculateAQI: PM2.5 = 35.4 → AQI ≈ 100 | ✅ ผ่าน | 6 |
| 52 | ตารางที่ 4.1 การทดสอบระดับหน่วย | UT-04 calculateAQI: PM2.5 = 55.4 → AQI ≈ 150 | ✅ ผ่าน | 9 |
| 53 | ตารางที่ 4.1 การทดสอบระดับหน่วย | UT-05 calculateAQI: PM2.5 = -1 → AQI = 0 | ✅ ผ่าน | 4 |
| 54 | ตารางที่ 4.1 การทดสอบระดับหน่วย | UT-06 aqiLabel: AQI 50 → "ดี" | ✅ ผ่าน | 8 |
| 55 | ตารางที่ 4.1 การทดสอบระดับหน่วย | UT-07 aqiLabel: AQI 150 → "ไม่ดีสำหรับกลุ่มเสี่ยง" | ✅ ผ่าน | 4 |
| 56 | ตารางที่ 4.1 การทดสอบระดับหน่วย | UT-08 aqiLabel: AQI 300 → "อันตราย" | ✅ ผ่าน | 5 |
| 57 | ตารางที่ 4.1 การทดสอบระดับหน่วย | UT-09 aqiColorValue: AQI 50 → เขียว 0xFF2ECC71 | ✅ ผ่าน | 8 |
| 58 | ตารางที่ 4.1 การทดสอบระดับหน่วย | UT-10 aqiColorValue: AQI 201 → ม่วง 0xFF8E44AD | ✅ ผ่าน | 6 |
| 59 | ตารางที่ 4.1 การทดสอบระดับหน่วย | UT-11 getTimedSafetyScore: base 100 → [70, 100] | ✅ ผ่าน | 6 |
| 60 | ตารางที่ 4.1 การทดสอบระดับหน่วย | UT-12 getTimedSafetyScore: base 0 → 0 | ✅ ผ่าน | 4 |
| 61 | ตารางที่ 4.1 การทดสอบระดับหน่วย | UT-13 getTimedSafetyScore: base 90 → ≤ 90 | ✅ ผ่าน | 7 |
| 62 | ตารางที่ 4.1 การทดสอบระดับหน่วย | UT-14 getTimedSafetyScore: base 100 → ≤ 100 | ✅ ผ่าน | 4 |
| 63 | ตารางที่ 4.1 การทดสอบระดับหน่วย | UT-15 shouldWarn: base 30 → true | ✅ ผ่าน | 3 |
| 64 | ตารางที่ 4.1 การทดสอบระดับหน่วย | UT-16 shouldWarn: base 100 → false | ✅ ผ่าน | 6 |
| 65 | ตารางที่ 4.1 การทดสอบระดับหน่วย | UT-17 getDifficultyColor: easy → เขียว | ✅ ผ่าน | 8 |
| 66 | ตารางที่ 4.1 การทดสอบระดับหน่วย | UT-18 getDifficultyColor: hard → แดง | ✅ ผ่าน | 8 |
| 67 | ตารางที่ 4.1 การทดสอบระดับหน่วย | UT-19 getDifficultyColor: unknown → Colors.white | ✅ ผ่าน | 12 |
| 68 | ตารางที่ 4.1 การทดสอบระดับหน่วย | UT-20 getDifficultyLabel: easy → "ง่าย" | ✅ ผ่าน | 8 |
| 69 | ตารางที่ 4.1 การทดสอบระดับหน่วย | UT-21 getDifficultyLabel: moderate → "ปานกลาง" | ✅ ผ่าน | 7 |
| 70 | ตารางที่ 4.1 การทดสอบระดับหน่วย | UT-22 getDifficultyLabel: hard → "ยาก" | ✅ ผ่าน | 4 |
| 71 | ตารางที่ 4.1 การทดสอบระดับหน่วย | UT-23 classifyDifficultyFromElevation: 5 m → easy | ✅ ผ่าน | 13 |
| 72 | สมการที่ (3.1), (3.2) และตารางที่ 3.16 | ผลรวมค่าน้ำหนัก w1..w4 = 1 | ✅ ผ่าน | 9 |
| 73 | สมการที่ (3.1), (3.2) และตารางที่ 3.16 | สภาพดีทุกปัจจัย กลางวัน → 100 (ปลอดภัย) | ✅ ผ่าน | 8 |
| 74 | สมการที่ (3.1), (3.2) และตารางที่ 3.16 | สภาพดีทุกปัจจัย กลางคืน → 100 × 0.7 = 70 | ✅ ผ่าน | 7 |
| 75 | สมการที่ (3.1), (3.2) และตารางที่ 3.16 | คะแนนสุดท้ายไม่เกินคะแนนพื้นฐาน | ✅ ผ่าน | 33 |
| 76 | สมการที่ (3.1), (3.2) และตารางที่ 3.16 | ตารางที่ 3.16 ขอบเขตระดับ | ✅ ผ่าน | 7 |
| 77 | สมการที่ (3.1), (3.2) และตารางที่ 3.16 | เส้นทางบนถนนสายหลักได้ S_trf ต่ำกว่าทางที่มีทางเท้า | ✅ ผ่าน | 7 |
| 78 | สมการที่ (3.1), (3.2) และตารางที่ 3.16 | T(t) กลางคืนขึ้นกับสัดส่วนไฟส่องสว่าง (0.7–1.0) | ✅ ผ่าน | 6 |
| 79 | สมการที่ (3.1), (3.2) และตารางที่ 3.16 | S_inc ลดลงตามจำนวนรายงานที่ยังไม่หมดอายุ | ✅ ผ่าน | 6 |
| 80 | SimulationEngine (UC-04) | estimateDurationMinutes: 6.4 กม. จังหวะ 6 นาที/กม. ไม่มีความชัน ≈ 38 นาที | ✅ ผ่าน | 6 |
| 81 | SimulationEngine (UC-04) | estimateDurationMinutes: ความชันเพิ่มเวลา | ✅ ผ่าน | 23 |
| 82 | SimulationEngine (UC-04) | estimateCalories: วิ่ง 5 กม. ≈ 325 kcal | ✅ ผ่าน | 7 |
| 83 | SimulationEngine (UC-04) | classifyDifficultyFromElevation เกณฑ์ 30 / 200 เมตร | ✅ ผ่าน | 14 |

## `test/widget_test.dart` (1/1)

| ลำดับ | กลุ่ม | กรณีทดสอบ | ผล | เวลา (ms) |
|---:|---|---|:---:|---:|
| 84 |  | App basic smoke test | ✅ ผ่าน | 343 |

