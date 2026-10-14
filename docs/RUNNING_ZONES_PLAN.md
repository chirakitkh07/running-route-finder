# แผนงาน: เปลี่ยน "เส้นทางยอดนิยม" เป็น "โซนวิ่ง" + ระบบแนะนำสถานที่วิ่งอัตโนมัติ

เอกสารนี้เขียนให้ AI agent หรือผู้พัฒนาใช้ทำงานต่อ ให้ทำทีละเฟสตามลำดับ แต่ละเฟสต้องผ่านเกณฑ์รับงานก่อนเริ่มเฟสถัดไป

---

## 0. บริบทของโปรเจกต์ (อ่านก่อนเริ่ม)

- แอป Flutter (Dart SDK ^3.10) ชื่อแพ็กเกจ `demo20426` แผนที่ใช้ `flutter_map ^8.3` และ `latlong2` ฐานข้อมูลคือ Cloud Firestore
- ปัญหาที่ต้องแก้: เส้นทางยอดนิยม 6 เส้นใน `lib/models/route_data.dart` (`ChiangMaiRoutes.routes`) เป็นพิกัดที่วาดด้วยมือ จึงไม่ตรงกับถนนในแผนที่ และการ์ดรายละเอียดก็บังแผนที่
- แนวทางใหม่: แสดงเป็น "โซน" (polygon) ที่ดึงขอบเขตจาก OpenStreetMap แล้วระบายสีตามคะแนนความปลอดภัย จากนั้นให้ระบบค้นหาและจัดอันดับโซนเองได้

ไฟล์ที่เกี่ยวข้อง:

| ไฟล์ | หน้าที่ |
|---|---|
| `lib/screens/map_screen.dart` | หน้าสำรวจ (ไฟล์ใหญ่ ~4,300 บรรทัด และ **ใช้ CRLF line endings ต้องคงไว้**) มี `_selectRoute`, `_fetchRouteGeometry`, `_buildSelectedRouteCard`, `_buildRouteListOverlay`, `_fitMapToPath`, `PolylineLayer` |
| `lib/models/route_data.dart` | `RunningRoute`, `Waypoint`, `ChiangMaiRoutes` (ข้อมูลเส้นทางเริ่มต้น 6 เส้น) |
| `lib/services/safety_score_engine.dart` | สูตร SAW: `S_base = 0.40·S_air + 0.20·S_wx + 0.25·S_trf + 0.15·S_inc`, `S = S_base × T(t)`, เกณฑ์ระดับ 70/40 (ตาราง 3.16), `getSafetyLevel`, `levelColor`, `scoreColor` |
| `lib/services/road_context_service.dart` | เรียก Overpass API และวิเคราะห์ลักษณะถนนตามเส้นทาง (`majorRoadShare`, `protectedShare`, `litShare`, `trafficSignals`) **นำโค้ดส่วนนี้กลับมาใช้** |
| `lib/services/api_service.dart` | `getPreRunSimulation(...)` ดึงสภาพอากาศและฝุ่นจาก Open-Meteo แล้วคำนวณคะแนน |
| `lib/services/routing_service.dart` | OSRM เดินเท้า (`routing.openstreetmap.de/routed-foot`) มี `fetchRoute`, `fetchRouteAlternatives` |
| `lib/services/firestore_service.dart` | CRUD ของ Firestore (`incidents`, `routes`, `simulations`, `air_quality`, `weather`, `activities`) |
| `lib/models/activity.dart` | `Activity.routePoints` = `List<Map<String,double>>` (`{lat, lng}`) ใช้คำนวณความนิยมในเฟส 3 |
| `lib/screens/admin_routes_screen.dart` | หน้าผู้ดูแลสำหรับจัดการเส้นทาง (UC-08) |
| `lib/l10n/app_strings.dart`, `lib/l10n/tr.dart` | ข้อความสองภาษา |
| `firestore.rules` | กฎความปลอดภัย Firestore |
| `test/unit_tests_table_4_1_test.dart` | unit test UT-01–UT-23 และ test ของสูตรคะแนน |

## 1. กติกาที่ต้องทำตามทุกเฟส

1. **สองภาษา:** ข้อความที่ผู้ใช้เห็นทุกข้อความต้องผ่าน `AppStrings` (`_s.xxx`) หรือ `tr('ไทย', 'English')` ห้ามเขียนข้อความภาษาเดียวตรง ๆ และห้ามใช้ `tr()` ภายใน `const` widget (จะ compile ไม่ผ่าน)
2. **ไม่ล้นจอ:** ข้อความที่ยาวไม่แน่นอนต้องอยู่ใน `Expanded`, `Flexible` หรือ `Wrap` ทดสอบบนจอกว้าง 360 dp ต้องไม่มีแถบ "OVERFLOWED"
3. **พิกัดต้องถูกต้อง:** กรองพิกัด `NaN`/`Infinity` ก่อนส่งให้ `flutter_map` ทุกครั้ง และเรียก `fitCamera` ผ่าน `_fitMapToPath` (ฟังก์ชันนี้รอ `onMapReady` แล้ว)
4. **เครือข่ายล้มเหลวต้องไม่พัง:** การเรียก Overpass, Open-Meteo และ OSRM ต้องมี timeout และมีทางสำรอง แอปต้องใช้งานต่อได้เมื่อ API ล่ม
5. **ไม่ใส่ API key เพิ่มในซอร์สโค้ด** และใช้เฉพาะบริการที่ไม่ต้องใช้ key (Overpass, Open-Meteo, OSRM FOSSGIS)
6. **ไม่ลบไฟล์หรือข้อมูลเดิม** ให้ทำแบบ deprecate และเก็บโค้ด Dijkstra/โหมดวางแผนเส้นทาง A→B ไว้ตามเดิม
7. **ส่งงาน:** จบทุกเฟสต้องรัน `flutter analyze` (ไม่มี error) และ `flutter test` (ผ่านทั้งหมด) และต้องรันบนมือถือจริงแล้วแนบภาพหน้าจอ
8. **Overpass:** จำกัดไม่เกิน 1 request พร้อมกัน ใส่ `[timeout:25]` และ cache ผลไว้ (ดูเฟส 2) เพื่อไม่ให้โดน rate limit

---

## เฟส 1: เปลี่ยนเส้นทางยอดนิยม 6 เส้นเป็นโซน

**เป้าหมาย:** ผู้ใช้เห็นพื้นที่วิ่ง (polygon) ที่ตรงกับแผนที่จริง ระบายสีตามคะแนนความปลอดภัย และสร้างเส้นทางวงรอบในโซนได้ตรงถนน

### 1.1 โมเดลข้อมูล

สร้าง `lib/models/running_zone.dart`

```dart
class RunningZone {
  final String id;               // เช่น 'zone_moat', หรือ 'osm_way_123456'
  final String name;             // ไทย
  final String nameEn;
  final String description;      // ไทย
  final String descriptionEn;
  final String category;         // 'moat' | 'park' | 'stadium' | 'campus' | 'reservoir' | 'track' | 'other'
  final List<List<LatLng>> polygons;   // รองรับหลาย ring/หลายส่วน (multipolygon)
  final LatLng center;           // จุดศูนย์กลาง ใช้วาง marker/ป้ายชื่อ
  final double walkableLengthKm; // ความยาวทางเดิน/ทางเท้ารวมในโซน (ถ้าคำนวณได้)
  final List<Waypoint> waypoints;      // นำ Waypoint เดิมกลับมาใช้
  final String source;           // 'preset' | 'osm' | 'admin'
  final String? osmRef;          // เช่น 'way/123456' หรือ 'relation/789'
  final bool hidden;             // ผู้ดูแลซ่อนได้ (เฟส 3)
  final bool pinned;             // ผู้ดูแลปักหมุดได้ (เฟส 3)
  // ค่าที่คำนวณแล้ว (ไม่บังคับต้องมี)
  final int? safetyScore;        // 0–100 หลังคูณ T(t)
  final Map<String, dynamic>? scoreComponents; // ผลจาก SafetyScoreResult.toMap()
  final DateTime? computedAt;

  String get displayName => tr(name, nameEn.isNotEmpty ? nameEn : name);
  String get displayDescription => tr(description, descriptionEn.isNotEmpty ? descriptionEn : description);
  Map<String, dynamic> toMap();
  factory RunningZone.fromMap(Map<String, dynamic> map, String id);
}
```

- เก็บ polygon ใน Firestore เป็น `List<Map>` แบบ `{'ring': [{'lat':..,'lng':..}, ...]}` เพราะ Firestore เก็บ array ซ้อน array ไม่ได้

### 1.2 ข้อมูลโซนเริ่มต้น (แทนเส้นทาง 6 เส้น)

สร้าง `lib/models/preset_zones.dart` กำหนดโซนเริ่มต้นด้วย **OSM reference** ไม่ใช่พิกัดวาดเอง แล้วให้ `ZoneService` ดึงรูปทรงจริงจาก Overpass

| id | ชื่อ | วิธีหาขอบเขต |
|---|---|---|
| `zone_moat` | รอบคูเมืองเชียงใหม่ | Overpass: `way["waterway"~"canal|ditch"]` หรือ `natural=water` ที่ชื่อมี "คูเมือง" ในกรอบ `18.778,98.975,18.800,98.998` แล้วรวมเป็นแนว moat ทำเป็นแถบกว้าง 25 ม. (buffer) รอบแนวคู ถ้าหาไม่เจอ fallback เป็นสี่เหลี่ยม `lat 18.7810–18.7958`, `lng 98.9783–98.9940` |
| `zone_buakhad` | สวนบวกหาด | `leisure=park` ชื่อ "สวนบวกหาด" หรือ "Buak Hard" ใกล้ 18.781, 98.980 |
| `zone_huaytueng` | อ่างเก็บน้ำห้วยตึงเฒ่า | `natural=water` หรือ `landuse=reservoir` ชื่อ "ห้วยตึงเฒ่า" ใกล้ 18.865, 98.945 (โซน = buffer 30 ม. รอบขอบน้ำ) |
| `zone_cmu` | มหาวิทยาลัยเชียงใหม่ | `amenity=university` ชื่อ "มหาวิทยาลัยเชียงใหม่" ใกล้ 18.800, 98.952 |
| `zone_700yr` | สนามกีฬา 700 ปี | `leisure=sports_centre` หรือ `stadium` ชื่อ "700" ใกล้ 18.840, 98.963 |
| `zone_suthep` | เส้นทางดอยสุเทพ | ยังเป็นเส้นทาง trail (ไม่ใช่พื้นที่) ให้คงเป็น polyline เดิม แต่ map-match ด้วย OSRM เดินเท้า และติดป้าย "Trail" |

- คงชื่อ คำอธิบาย และ waypoint (ไทย/อังกฤษ) จาก `ChiangMaiRoutes` เดิมไว้
- ใน Overpass ให้ใช้ `out geom;` แล้วประกอบ ring จาก `way`/`relation` (สำหรับ relation ให้ต่อ member ring ชั้นนอก)
- **Buffer รอบเส้น** (สำหรับคูเมืองและอ่างเก็บน้ำ): เขียน helper `bufferPolyline(List<LatLng>, double meters)` แบบง่ายด้วย offset ฉากซ้าย/ขวาทีละจุดแล้วต่อเป็น polygon ไม่ต้องสมบูรณ์แบบ แค่ให้ดูเป็นแถบ

### 1.3 ZoneService

สร้าง `lib/services/zone_service.dart`
- `Future<List<RunningZone>> loadPresetZones()`
  1. อ่าน cache จาก Firestore คอลเลกชัน `zones` (doc id = zone id) ถ้า `computedAt` ไม่เกิน 7 วันให้ใช้ได้เลย
  2. ถ้าไม่มี cache ให้ดึง polygon จาก Overpass ตามข้อ 1.2 แล้วบันทึกลง `zones`
  3. ถ้า Overpass ล้มเหลว ให้ใช้ fallback polygon ที่กำหนดในโค้ด (สร้างจาก bounding box ของ `RunningRoute.path` เดิมขยายออก 30 ม.)
- `Future<RunningZone> scoreZone(RunningZone z)` คำนวณคะแนน
  - **S_air, S_wx:** เรียก Open-Meteo ที่ `z.center` (ใช้ `ApiService` ร่วมกัน หรือแยกเป็นฟังก์ชันที่คืนค่าดิบ)
  - **S_trf และ litShare:** ใช้ `RoadContextService` โดยวิเคราะห์ "ทางเดินภายใน polygon" แทนเส้นทาง เพิ่มฟังก์ชัน `RoadContextService.fetchForArea(List<LatLng> ring)` ที่ query `way(poly:"lat lon lat lon ...")[highway]` แล้วคิดสัดส่วนตาม **ความยาว** ของแต่ละ way (ไม่ใช่จำนวนจุด)
  - **S_inc:** นับ `IncidentReport` ที่ active ภายใน polygon (point-in-polygon แบบ ray casting)
  - คำนวณผ่าน `SafetyScoreEngine.calculateSafetyScore(...)` เท่านั้น ห้ามเขียนสูตรซ้ำ
- `static bool pointInPolygon(LatLng p, List<LatLng> ring)` ต้องมี unit test

### 1.4 UI ใน `map_screen.dart`

1. **วาดโซน:** เพิ่ม `PolygonLayer` ใต้ `PolylineLayer` เดิม
   - สีเติม = `SafetyScoreEngine.scoreColor(score)` alpha 0.25 ส่วนเส้นขอบใช้สีเดียวกัน alpha 0.9 กว้าง 2.5
   - ถ้ายังไม่มีคะแนน ใช้สีเทา `0xFF95A5A6` และขึ้นป้าย "กำลังประเมิน…"
   - วาง `Marker` ที่ `center` เป็นป้ายเล็ก "ชื่อโซน · คะแนน"
2. **แตะโซน:** ใช้ `MapOptions.onTap` ตรวจ point-in-polygon เพื่อเลือกโซน แล้วแสดง `_buildSelectedZoneCard()` แทน `_buildSelectedRouteCard()`
   - การ์ดย่อไว้เป็นค่าเริ่มต้น (แบบเดียวกับที่ทำไว้แล้ว) ประกอบด้วยชื่อ, chip ระดับความปลอดภัย, คะแนน, PM2.5, ระยะทางจากผู้ใช้ และปุ่มหลัก 2 ปุ่ม
   - ปุ่ม **"วิ่งอิสระในโซนนี้"**: เปิดหน้าบันทึก (`RecordScreen`) โดยไม่มีเส้นทางบังคับ แต่ส่งโซนไปให้ด้วย เพื่อให้แสดง polygon และเตือนเมื่อวิ่งออกนอกโซน (ถ้าทำได้ในเวลาที่มี)
   - ปุ่ม **"สร้างเส้นทางวงรอบ"**: ให้เลือกระยะ 2 / 3 / 5 / 10 กม. แล้วสร้าง loop ตามข้อ 1.5
   - เมื่อขยายการ์ด: แสดงคำอธิบาย, waypoint chips, ปัจจัยคะแนน (S_air/S_wx/S_trf/S_inc, T(t)) และเหตุผลสั้น ๆ เช่น "ไฟสว่าง 85%, ถนนสายหลัก 0%"
3. **รายการโซน:** เปลี่ยนข้อความปุ่ม "เส้นทางแนะนำ" เป็น "โซนแนะนำ" และ `_buildRouteListOverlay` ให้แสดงโซนเรียงตามคะแนน
4. **ซูมแผนที่:** เมื่อเลือกโซน เรียก `_fitMapToPath(ring ชั้นนอก)` ซึ่งเว้นที่ให้การ์ดด้านล่างอยู่แล้ว
5. **ไม่แสดงเส้นทางวาดมือเดิมอีก:** ไม่ต้องเรียก `_fetchRouteGeometry` สำหรับโซน แต่เก็บโค้ดเดิมไว้ให้ trail ดอยสุเทพใช้

### 1.5 สร้างเส้นทางวงรอบในโซน

เพิ่มใน `RoutingService`:

```dart
static Future<List<LatLng>> buildLoopInZone({
  required RunningZone zone,
  required LatLng start,        // ตำแหน่งผู้ใช้ ถ้าอยู่ในโซน ไม่งั้นใช้จุดบนขอบโซนที่ใกล้ผู้ใช้ที่สุด
  required double targetKm,
});
```

อัลกอริทึม:
1. ถ้าเป็นโซนแบบแถบ (moat/reservoir) ให้ใช้แนวกลางของแถบเป็น waypoint (สุ่มตัวอย่างทุก 150 ม.) แล้วเรียก OSRM เดินเท้าแบบวงปิด
2. ถ้าเป็นโซนแบบพื้นที่ ให้เลือก 3–5 จุดภายใน polygon (ใกล้ขอบด้านใน ห่างขอบ 20 ม.) กระจายรอบ `center` เรียงตามมุม แล้วเริ่มและจบที่ `start`
3. เรียก `routed-foot` แล้ววัดความยาว ถ้าต่างจาก `targetKm` เกิน ±15% ให้ปรับรัศมีของจุดแล้วลองใหม่ ไม่เกิน 3 รอบ
4. ถ้าเส้นทางออกนอก polygon เกิน 20% ของความยาว ให้ลดรัศมีลง
5. นำผลไปเข้า `SafetyDijkstraService.run` และ `ApiService.getPreRunSimulation` เหมือนโหมดวางแผน แล้วแสดงด้วย `_buildRoutePlanCard()` เดิม

### 1.6 เกณฑ์รับงานเฟส 1

- [ ] โซนคูเมือง สวนบวกหาด และ มช. แสดง polygon ทับแนวจริงบนแผนที่ (แนบภาพหน้าจอ)
- [ ] สีโซนตรงกับระดับในตาราง 3.16 และเปลี่ยนเมื่อคะแนนเปลี่ยน
- [ ] สร้าง loop 3 กม. ในคูเมือง ได้ความยาว 2.55–3.45 กม. และเส้นทางวิ่งบนถนนจริง
- [ ] ปิดเน็ตแล้วเปิดแอป ต้องเห็นโซนจาก cache หรือ fallback ไม่ crash
- [ ] unit test ใหม่: `pointInPolygon`, `bufferPolyline` (polygon ที่ได้มีจำนวนจุด = 2×n), `RunningZone.toMap/fromMap` round-trip
- [ ] `flutter analyze` และ `flutter test` ผ่าน

---

## เฟส 2: ค้นหาและจัดอันดับโซนอัตโนมัติ (ไม่ต้องให้ผู้พัฒนากำหนด)

**เป้าหมาย:** เมื่อเปิดหน้าสำรวจ ระบบหาสถานที่วิ่งในรัศมีที่กำหนดรอบผู้ใช้ ให้คะแนน แล้วแนะนำ 5 อันดับแรก

### 2.1 หาโซนที่เป็นไปได้ (candidate generation)

`ZoneDiscoveryService.discover(LatLng center, {double radiusKm = 5})`
- Overpass query (ครั้งเดียว):
  ```
  [out:json][timeout:25];
  (
    way["leisure"~"park|track|stadium|sports_centre|recreation_ground|garden"](around:R,lat,lon);
    relation["leisure"~"park|stadium|sports_centre"](around:R,lat,lon);
    way["landuse"~"recreation_ground|village_green"](around:R,lat,lon);
    way["amenity"="university"](around:R,lat,lon);
    way["natural"="water"]["name"](around:R,lat,lon);
    way["landuse"="reservoir"](around:R,lat,lon);
  );
  out geom tags;
  ```
- **คัดกรอง:**
  - พื้นที่ ≥ 15,000 ตร.ม. (คำนวณพื้นที่ polygon ด้วย shoelace บนพิกัดที่แปลงเป็นเมตร)
  - มีทางเดิน/ถนนภายในหรือรอบขอบรวม ≥ 1.0 กม. (query `way(poly:...)[highway~"footway|path|track|pedestrian|service|residential|living_street|cycleway"]` แล้วรวมความยาว)
  - ต้องไม่ใช่ `access=private` หรือ `access=no`
  - ต้องไม่ใช่ `leisure=golf_course` หรือ `landuse=military`
  - แหล่งน้ำ: ใช้เป็นโซนแบบแถบรอบขอบ (buffer) เฉพาะเมื่อมีทางเดินอยู่ห่างขอบไม่เกิน 30 ม.
- **ตัดซ้ำ:** ถ้า polygon ซ้อนทับกันเกิน 60% ให้เก็บอันที่ใหญ่กว่า และถ้าซ้ำกับโซน preset ให้ใช้ preset (preset มีคำอธิบายครบกว่า)
- **ตั้งชื่อ:** ใช้ `name:th` ถ้าไม่มีใช้ `name` และใช้ `name:en` สำหรับภาษาอังกฤษ ถ้าไม่มีชื่อเลยให้ตั้งตามหมวด เช่น "สวนสาธารณะ (ไม่มีชื่อ)"
- **คำอธิบาย:** สร้างอัตโนมัติจากข้อมูล เช่น "สวนสาธารณะ · ทางเดิน 2.4 กม. · ไฟส่องสว่าง 70%"

### 2.2 ให้คะแนนและจัดอันดับ

คะแนนแนะนำ (Recommendation Score) แยกจากคะแนนความปลอดภัย:

```
R = 0.55 · S_safety + 0.20 · S_dist + 0.15 · S_len + 0.10 · S_pop
```

| ตัวแปร | ความหมาย |
|---|---|
| `S_safety` | คะแนนความปลอดภัยจาก `SafetyScoreEngine` (0–100) ซึ่งรวม T(t) แล้ว |
| `S_dist` | `100 × max(0, 1 − d/radius)` โดย d คือระยะจากผู้ใช้ถึงขอบโซน |
| `S_len` | `min(100, walkableLengthKm / 3 × 100)` ให้โซนที่มีทางวิ่ง ≥ 3 กม. ได้เต็ม |
| `S_pop` | ความนิยม เฟส 2 ใช้ค่า 50 คงที่ไปก่อน และจะทำจริงในเฟส 3 |

- ประกาศน้ำหนักเป็น `static const` ใน `lib/services/zone_recommender.dart` และเขียนคอมเมนต์อธิบาย
- แสดง 5 อันดับแรกบนแผนที่ (โซนอื่นที่ผ่านเกณฑ์แสดงแบบจาง) และในรายการ "โซนแนะนำ" ให้แสดงเหตุผล 2–3 ข้อต่อโซน
- เหตุผลสร้างจากปัจจัยที่ทำคะแนนได้ดีที่สุดหรือแย่ที่สุด เช่น "ไม่มีถนนสายหลัก", "ไฟสว่าง 90%", "ใกล้คุณ 1.2 กม.", "PM2.5 สูง"

### 2.3 Cache และประสิทธิภาพ

- **เก็บ candidate:** เก็บใน Firestore `zones` โดยกำหนด `source: 'osm'`, `osmRef`, `computedAt` และ `geohash5` ของ center (เขียนฟังก์ชัน geohash เองหรือใช้แพ็กเกจที่ไม่ต้องใช้ key)
- **ครั้งถัดไป:** ถ้าใน geohash5 นั้นและรอบข้างมีข้อมูลอายุไม่เกิน 7 วัน ให้อ่านจาก Firestore แทน Overpass
- **คะแนนความปลอดภัย** เปลี่ยนตามเวลาและอากาศ: เก็บแยก `scoreComponents` และ `computedAt` แล้วคำนวณใหม่เมื่อเก่ากว่า 60 นาที (ส่วน S_air/S_wx เรียก Open-Meteo ครั้งเดียวต่อกลุ่มโซนที่อยู่ใกล้กัน < 2 กม.)
- **ไม่บล็อก UI:** แสดงโซน preset ก่อน แล้วค่อยเติมโซนที่ค้นพบ พร้อมตัวบอกสถานะ "กำลังค้นหาที่วิ่งใกล้คุณ…"
- เพิ่มกฎใน `firestore.rules` สำหรับ `zones`: ผู้ใช้ที่ login แล้วอ่านได้ และ **create/update ได้เฉพาะ field ที่ระบบคำนวณ** ส่วน `hidden` และ `pinned` แก้ได้เฉพาะ admin

### 2.4 เกณฑ์รับงานเฟส 2

- [ ] เปิดแอปที่ตำแหน่ง มช. แล้วต้องมีโซนที่ไม่ได้อยู่ใน preset อย่างน้อย 3 แห่ง (แนบภาพและรายชื่อ)
- [ ] ไม่มีโซนเป็นพื้นที่ส่วนตัว สนามกอล์ฟ หรือพื้นที่ทหาร
- [ ] เปิดแอปครั้งที่สองในพื้นที่เดิม ต้องไม่เรียก Overpass (ยืนยันจาก log)
- [ ] unit test ใหม่: สูตร `R` (กรณีโซนไกลกว่ารัศมีต้องได้ `S_dist = 0`), พื้นที่ shoelace (สี่เหลี่ยม 100×100 ม. ได้ ≈10,000 ตร.ม. ±2%), การตัดซ้ำ polygon, การสร้างเหตุผล
- [ ] `flutter analyze` และ `flutter test` ผ่าน

---

## เฟส 3: ความนิยมจากผู้ใช้ และเครื่องมือผู้ดูแล

### 3.1 คะแนนความนิยม `S_pop` (ข้อมูลจากมวลชน)

- ทุกครั้งที่บันทึก `Activity` (`FirestoreService.saveActivity`) ให้ตรวจว่า `routePoints` ผ่านโซนใดบ้าง โดยถือว่าผ่านเมื่อ ≥ 30% ของจุดอยู่ใน polygon แล้วเพิ่ม counter ใน `zones/{id}/stats/weekly` ด้วย `FieldValue.increment(1)` แยกเป็นรายสัปดาห์ (`yyyy-Www`)
- `S_pop = 100 × min(1, ln(1 + runs_4w) / ln(1 + P90))` โดย `runs_4w` คือจำนวนครั้งใน 4 สัปดาห์ล่าสุด และ `P90` คือเปอร์เซ็นไทล์ที่ 90 ของทุกโซนในรัศมีเดียวกัน (ถ้ามีน้อยกว่า 5 โซนให้ใช้ 20)
- นับเฉพาะ activity ที่ `isPublic == true` เพื่อความเป็นส่วนตัว และห้ามเก็บ uid ใน stats
- **โซนที่ระบบยังไม่รู้จัก:** ถ้ามีหลาย activity วิ่งวนในพื้นที่ที่ไม่มีโซนอยู่ ให้รวมจุดที่วิ่งซ้ำ (grid 50 ม. ที่มีผู้ใช้ไม่ซ้ำกัน ≥ 3 คน) แล้วเสนอเป็น "โซนที่ชุมชนนิยม" (`source: 'community'`) เพื่อให้ผู้ดูแลอนุมัติก่อนแสดง

### 3.2 หน้าผู้ดูแล (UC-08 จัดการโซน)

แก้ `admin_routes_screen.dart` (หรือสร้าง `admin_zones_screen.dart` แล้วเปลี่ยนลิงก์จากแดชบอร์ด)
- รายการโซนทั้งหมด กรองตาม `source` และสถานะ (`hidden`, `pinned`, รออนุมัติ)
- ผู้ดูแลทำได้ดังนี้
  - ซ่อน/แสดง
  - ปักหมุด (โซนที่ปักหมุดได้ +10 ใน `R` และแสดงเสมอ)
  - แก้ชื่อและคำอธิบายทั้งสองภาษา
  - อนุมัติโซน community
  - สั่ง "คำนวณใหม่" ทีละโซน
- ห้ามแก้ polygon ด้วยมือ (ถ้ารูปทรงผิด ให้แก้ใน OSM แล้วกดคำนวณใหม่) เพื่อให้รูปทรงตรงกับแผนที่เสมอ
- UC-08 E2 (ป้องกันการลบโซนที่มีการใช้งาน): ห้ามลบโซนที่ `runs_4w > 0` ให้ซ่อนแทน

### 3.3 เกณฑ์รับงานเฟส 3

- [ ] บันทึกการวิ่งในสวนบวกหาด 2 ครั้ง แล้ว `stats` ของโซนเพิ่มขึ้น 2 และ `S_pop` เปลี่ยน
- [ ] activity ส่วนตัว (`isPublic == false`) ต้องไม่ถูกนับ
- [ ] ผู้ดูแลซ่อนโซนแล้ว ผู้ใช้ทั่วไปต้องไม่เห็นโซนนั้น และ rules ต้องกันผู้ใช้ทั่วไปแก้ `hidden` (ทดสอบด้วย Firestore emulator หรือแนบผลทดสอบ rules)
- [ ] unit test: สูตร `S_pop`, การนับผ่านโซน (เกณฑ์ 30%), key รายสัปดาห์ ISO (`yyyy-Www`)
- [ ] `flutter analyze` และ `flutter test` ผ่าน

---

## 4. สิ่งที่ต้องแก้ในเล่มปริญญานิพนธ์ (ทำหลังโค้ดเสร็จแต่ละเฟส)

ไฟล์ล่าสุดคือ `รวมเล่มแอพวิ่ง_แก้ไขให้ตรงโค้ด.docx`

- **บทที่ 1 (1.3.2 ขอบเขตด้านระบบ):** เพิ่ม "ระบบแนะนำโซนวิ่งอัตโนมัติจากข้อมูลโอเพนสตรีตแมปและข้อมูลจากมวลชน"
- **2.1.x:** เพิ่มทฤษฎีสั้น ๆ เรื่องการทดสอบจุดในรูปหลายเหลี่ยม (point-in-polygon), การคำนวณพื้นที่ด้วยสูตร shoelace และการจัดอันดับด้วยผลรวมถ่วงน้ำหนัก (ใช้ 2.1.9 SAW อ้างอิงต่อได้)
- **UC-03:** เปลี่ยนเป็น "ดูโซนและเส้นทางแนะนำ" แล้วเพิ่ม A2 "สร้างเส้นทางวงรอบในโซน"
- **UC-08:** เปลี่ยนเป็น "จัดการข้อมูลโซน" (ซ่อน/ปักหมุด/อนุมัติ) โดย E2 ใช้กฎ `runs_4w > 0`
- **ERD (3.3.2.1):** เพิ่มตาราง Zone (id, name, nameEn, category, polygon, center, source, osmRef, hidden, pinned, safetyScore, computedAt) และ ZoneStat (zoneId, weekKey, runs) โดย Zone 1–N ZoneStat และ Zone 1–N Incident (ผ่าน point-in-polygon)
- **แผนภาพคลาส (3.3.2.2):** เพิ่ม `RunningZone`, `ZoneService`, `ZoneDiscoveryService`, `ZoneRecommender`, `RoadContextService` และ `OverpassAPIClient «interface»`
- **3.3.5:** เพิ่มหัวข้อย่อย "คะแนนแนะนำโซน" สมการ `R = 0.55·S_safety + 0.20·S_dist + 0.15·S_len + 0.10·S_pop` พร้อมนิยามตัวแปร
- **บทที่ 4:** เพิ่มกรณีทดสอบ (UT ของ point-in-polygon, shoelace, R, S_pop และ IT "แนะนำโซนอัตโนมัติ") และถ่ายรูปหน้าจอใหม่แทนรูป 4.1–4.3
- **5.2/5.3:** เพิ่มข้อจำกัดเรื่องความครบถ้วนของข้อมูล OSM (ไฟส่องสว่าง/ทางเท้า), rate limit ของ Overpass และกรณีความนิยมยังไม่มีข้อมูลในช่วงแรก (cold start)

## 5. นอกขอบเขต (ห้ามทำในงานนี้)

- ห้ามเปลี่ยนสูตร `SafetyScoreEngine` (น้ำหนัก 0.40/0.20/0.25/0.15 และ T(t)) เพราะผูกกับเล่มบทที่ 3
- ห้ามลบโหมดวางแผนเส้นทาง A→B และ `SafetyDijkstraService`
- ห้ามเพิ่มบริการที่ต้องใช้ API key หรือมีค่าใช้จ่าย
- ห้ามแก้ไฟล์ใน `backend/` (Node/SQLite เดิม ไม่ได้ใช้งาน)
