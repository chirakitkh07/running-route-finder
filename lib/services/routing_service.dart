import 'dart:convert';
import 'dart:math' as math;
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import '../models/running_zone.dart';
import '../models/route_data.dart';
import 'zone_service.dart';

/// ดึง geometry ของเส้นทางตามถนนจริงจาก Routing API
/// ลอง MapTiler ก่อน ถ้าไม่ได้ใช้ OSRM เป็น fallback
class RoutingService {
  static const String _mapTilerKey = 'KPAM4YzsLppPleBVLffd';
  // OpenRouteService (โหมด round_trip สร้างเส้นทางวงรอบจากโครงข่ายถนนจริง)
  static const String _orsKey =
      'eyJvcmciOiI1YjNjZTM1OTc4NTExMTAwMDFjZjYyNDgiLCJpZCI6IjhjMzMwMGNmYTY2ZTRlMzY4YjNhNzYwMzMyYjhkYTQzIiwiaCI6Im11cm11cjY0In0=';
  static const String _orsRoundTripUrl =
      'https://api.openrouteservice.org/v2/directions/foot-walking/geojson';

  /// คืนเส้นทางตามถนน/ทางเดินจริงผ่าน [waypoints] — คืนลิสต์ว่างถ้า Routing API ทุกตัวใช้ไม่ได้
  /// (ไม่คืนเส้นตรงระหว่างจุด เพราะจะลากตัดผ่านอาคาร)
  static Future<List<LatLng>> fetchRoute(List<LatLng> waypoints) async {
    if (waypoints.length < 2) return const [];

    // ลด waypoints ให้เหลือสูงสุด 25 จุด — เดิม 10 จุด ทำให้เส้นทางวงรอบตัดมุม/วิ่งผิดถนน
    final reduced = _reduceWaypoints(waypoints, maxPoints: 25);

    // 1) OSRM โปรไฟล์เดินเท้าของ FOSSGIS (routing.openstreetmap.de) — ใช้ทางเท้า/ซอย ไม่ติดถนนวันเวย์
    //    (เซิร์ฟเวอร์ router.project-osrm.org รองรับเฉพาะรถยนต์ แม้ใส่ /foot ก็คำนวณแบบรถ
    //     จึงอ้อมตามถนนวันเวย์รอบคูเมือง เส้นทางจึงไม่ตรงถนนที่วิ่งจริง)
    try {
      final result = await _fromOsrmFoot(reduced);
      if (result.length > 2) return result;
    } catch (_) {}

    // 2) OpenRouteService โปรไฟล์เดินเท้า
    try {
      final result = await _fromOrs(reduced);
      if (result.length > 2) return result;
    } catch (_) {}

    // 3) MapTiler
    try {
      final result = await _fromMapTiler(reduced);
      if (result.length > 2) return result;
    } catch (_) {}

    // 4) OSRM สาธารณะ (โปรไฟล์รถยนต์ — ยังอยู่บนถนนจริง)
    try {
      final result = await _fromOSRM(reduced);
      if (result.length > 2) return result;
    } catch (_) {}

    return const [];
  }

  /// ดึงเส้นทางทางเลือกหลายเส้น (OSRM alternatives) สำหรับให้ Safety-Aware Dijkstra
  /// เปรียบเทียบค่าน้ำหนักความปลอดภัยสะสมและเลือกเส้นทางที่ปลอดภัยที่สุด (UC-03 A1)
  /// คืนอย่างน้อย 1 เส้นทางเสมอ (fallback = [fetchRoute])
  static Future<List<List<LatLng>>> fetchRouteAlternatives(LatLng start, LatLng end) async {
    try {
      final url =
          '$_osrmFootBase/${start.longitude},${start.latitude};${end.longitude},${end.latitude}'
          '?overview=full&geometries=geojson&alternatives=3';
      final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final data = json.decode(res.body) as Map<String, dynamic>;
        final routes = (data['routes'] as List?) ?? [];
        final result = <List<LatLng>>[];
        for (final r in routes) {
          final coords = (r['geometry']?['coordinates'] as List?) ?? [];
          final pts = coords
              .map((c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
              .where((p) => p.latitude.isFinite && p.longitude.isFinite)
              .toList();
          if (pts.length > 2) result.add(pts);
        }
        if (result.isNotEmpty) return result;
      }
    } catch (_) {}
    return [await fetchRoute([start, end])];
  }

  // ─── MapTiler Directions API ──────────────────────────────
  static Future<List<LatLng>> _fromMapTiler(List<LatLng> pts) async {
    final coords = pts.map((p) => '${p.longitude},${p.latitude}').join(';');
    final url =
        'https://api.maptiler.com/directions/v2/route/foot/$coords?key=$_mapTilerKey&overview=full&geometries=geojson';

    final res = await http
        .get(Uri.parse(url))
        .timeout(const Duration(seconds: 10));

    if (res.statusCode == 200) {
      return _parseGeoJsonRoutes(res.body);
    }
    return [];
  }

  // ─── OpenRouteService Directions (foot-walking) ───────────
  static Future<List<LatLng>> _fromOrs(List<LatLng> pts) async {
    final res = await http
        .post(
          Uri.parse(_orsRoundTripUrl),
          headers: {
            'Authorization': _orsKey,
            'Content-Type': 'application/json',
            'Accept': 'application/geo+json, application/json',
          },
          body: json.encode({
            'coordinates': [
              for (final p in pts) [p.longitude, p.latitude]
            ],
          }),
        )
        .timeout(const Duration(seconds: 12));
    if (res.statusCode != 200) return [];
    final data = json.decode(res.body) as Map<String, dynamic>;
    final features = (data['features'] as List?) ?? const [];
    if (features.isEmpty) return [];
    final coords = (features.first['geometry']?['coordinates'] as List?) ?? const [];
    return coords
        .map((c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
        .where((p) => p.latitude.isFinite && p.longitude.isFinite)
        .toList();
  }

  // ─── OSRM foot profile (FOSSGIS) ─────────────────────────
  static const _osrmFootBase = 'https://routing.openstreetmap.de/routed-foot/route/v1/driving';

  static Future<List<LatLng>> _fromOsrmFoot(List<LatLng> pts, {bool alternatives = false}) async {
    final coords = pts.map((p) => '${p.longitude},${p.latitude}').join(';');
    final url = '$_osrmFootBase/$coords?overview=full&geometries=geojson'
        '${alternatives ? '&alternatives=3' : ''}';
    final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 12));
    if (res.statusCode == 200) {
      return _parseGeoJsonRoutes(res.body);
    }
    return [];
  }

  // ─── OSRM Public API (fallback — โปรไฟล์รถยนต์) ────────────
  static Future<List<LatLng>> _fromOSRM(List<LatLng> pts) async {
    final coords = pts.map((p) => '${p.longitude},${p.latitude}').join(';');
    final url =
        'https://router.project-osrm.org/route/v1/foot/$coords?overview=full&geometries=geojson';

    final res = await http
        .get(Uri.parse(url))
        .timeout(const Duration(seconds: 10));

    if (res.statusCode == 200) {
      return _parseGeoJsonRoutes(res.body);
    }
    return [];
  }

  // ─── Parse GeoJSON geometry ───────────────────────────────
  static List<LatLng> _parseGeoJsonRoutes(String body) {
    final data = json.decode(body) as Map<String, dynamic>;
    final routes = data['routes'] as List?;
    if (routes == null || routes.isEmpty) return [];

    final geometry = routes[0]['geometry'] as Map<String, dynamic>?;
    if (geometry == null) return [];

    final coords = geometry['coordinates'] as List;
    return coords
        .map((c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
        .where((p) => p.latitude.isFinite && p.longitude.isFinite) // กัน LatLng(NaN, NaN)
        .toList();
  }

  // ─── ลด waypoints ────────────────────────────────────────
  static List<LatLng> _reduceWaypoints(List<LatLng> pts, {int maxPoints = 10}) {
    if (pts.length <= maxPoints) return pts;
    final step = (pts.length / (maxPoints - 1)).ceil();
    final result = <LatLng>[];
    for (int i = 0; i < pts.length; i += step) {
      result.add(pts[i]);
    }
    if (result.last != pts.last) result.add(pts.last);
    return result;
  }

  // ─── เส้นทางมาตรฐาน (ตายตัว) ของโซน ─────────────────────────
  //
  // 1 รอบ = "ขอบจริงของสถานที่" (รอบคูเมือง / รอบสวน / รอบอ่าง จาก OSM) ที่แนบเข้ากับ
  // โครงข่ายถนน/ทางเดินจริงด้วย Routing API → เส้นทางอยู่บนทางจริงเสมอ ไม่ตัดผ่านอาคาร
  // ผู้ใช้เลือก "จำนวนรอบ" แทนระยะทางอิสระ
  //
  // วิธีแนบ (ทดสอบกับ OSRM FOSSGIS แล้วได้ผลดีที่สุด — map matching ของเซิร์ฟเวอร์นี้รับได้แค่ 10 จุด):
  //   1) สุ่มจุดผ่านบนขอบโซน (ลองหลายแบบ: จำนวนจุด / ขยับขอบเข้า-ออกเล็กน้อย)
  //   2) ขอเส้นทางเดินเท้าวนผ่านจุดเหล่านั้นกลับมาจุดแรก
  //   3) ตัดทุกช่วงที่ "เดินไปแล้วย้อนกลับทางเดิม" ออก ([extractLoop]) เหลือเฉพาะวงปิด
  //   4) เลือกแบบที่ระยะใกล้เส้นรอบโซนและแนบขอบโซนที่สุด

  /// โซนที่ไม่ใช่วงรอบ (เส้นทางขึ้นเขา) ใช้เส้นทางเดิมแบบทางเดียว
  static const Map<String, String> _linearCourseRouteIds = {'zone_suthep': 'doi_suthep'};

  static bool isLinearCourse(RunningZone zone) => _linearCourseRouteIds.containsKey(zone.id);

  static List<LatLng>? _linearCoursePath(RunningZone zone) {
    final rid = _linearCourseRouteIds[zone.id];
    if (rid == null) return null;
    for (final r in ChiangMaiRoutes.routes) {
      if (r.id == rid && r.path.length >= 2) return r.path;
    }
    return null;
  }

  /// โซนที่มีเส้นทางวงรอบสร้างไว้ล่วงหน้าในแอป (เส้นเดียวกับ "เส้นทางยอดนิยม" — สร้างจาก Routing API แล้ว)
  /// ใช้ได้ทันทีโดยไม่ต้องรอ Overpass/OSRM และได้เส้นเดิมทุกครั้ง
  static const Map<String, String> _builtInCourseRouteIds = {
    'zone_moat': 'moat_loop',
    'zone_buakhad': 'buak_had',
    'zone_huaytueng': 'huay_tueng_thao',
    'zone_cmu': 'cmu_campus',
    'zone_700yr': 'stadium_700',
  };

  static List<LatLng>? _builtInCoursePath(RunningZone zone) {
    final rid = _builtInCourseRouteIds[zone.id];
    if (rid == null) return null;
    for (final r in ChiangMaiRoutes.routes) {
      if (r.id == rid && ChiangMaiRoutes.hasRoadPath(r)) return r.path;
    }
    return null;
  }

  /// true ถ้าโซนนี้มีเส้นทางมาตรฐานพร้อมใช้ โดยไม่ต้องมีขอบเขตจริงจาก OSM ก่อน
  static bool hasBuiltInCourse(RunningZone zone) =>
      _linearCoursePath(zone) != null || _builtInCoursePath(zone) != null;

  /// วงหลักของโซน = ring ที่มีพื้นที่มากที่สุด
  static List<LatLng> _mainRing(RunningZone zone) {
    List<LatLng> best = const [];
    double bestArea = -1;
    for (final r in zone.polygons) {
      final ring = _openRing(r);
      if (ring.length < 3) continue;
      final a = _ringAreaM2(ring);
      if (a > bestArea) {
        bestArea = a;
        best = ring;
      }
    }
    return best;
  }

  static final Map<String, ZoneCourse> _courseCache = {};

  static String _courseKey(RunningZone zone, List<LatLng> ring) => ring.isEmpty
      ? zone.id
      : '${zone.id}:${ring.length}:${ring.first.latitude.toStringAsFixed(5)},'
          '${ring.first.longitude.toStringAsFixed(5)}';

  /// เส้นทางมาตรฐานที่คำนวณไว้แล้วของโซน (null = ยังไม่ได้คำนวณ)
  static ZoneCourse? cachedCourse(RunningZone zone) {
    final linear = _linearCoursePath(zone);
    if (linear != null) return ZoneCourse(linear, onRoads: true);
    final builtIn = _builtInCoursePath(zone);
    if (builtIn != null) return ZoneCourse(builtIn, onRoads: true);
    return _courseCache[_courseKey(zone, _mainRing(zone))];
  }

  /// ระยะทาง 1 รอบของเส้นทางมาตรฐาน (กม.) — ก่อนคำนวณเส้นทางจริงเสร็จใช้เส้นรอบโซนเป็นค่าประมาณ
  static double fixedCourseLapKm(RunningZone zone) {
    final cached = cachedCourse(zone);
    if (cached != null) return cached.lapKm;
    final ring = _mainRing(zone);
    if (ring.length < 3) return zone.walkableLengthKm;
    return _pathLengthM([...ring, ring.first]) / 1000.0;
  }

  /// ตัวเลือกจำนวนรอบที่เหมาะกับขนาดโซน (สูงสุด 4 ตัวเลือก) เช่น ลู่ 400 ม. → 3/5/8/13 รอบ
  static List<int> lapOptions(RunningZone zone) {
    if (isLinearCourse(zone)) return const [1];
    final lapKm = fixedCourseLapKm(zone);
    if (lapKm <= 0) return const [1];
    final out = <int>{};
    for (final t in const [1.0, 2.0, 3.0, 5.0, 10.0]) {
      final laps = math.max(1, (t / lapKm).round());
      if (laps * lapKm <= 21.5) out.add(laps);
    }
    if (out.isEmpty) out.add(1);
    final list = out.toList()..sort();
    return list.take(4).toList();
  }

  /// เส้นทางมาตรฐาน 1 รอบของโซน แนบกับถนน/ทางเดินจริง (ผลถูกแคชไว้ต่อโซน)
  ///
  /// คืน null เมื่อสร้างเส้นทางบนทางจริงไม่ได้ (Routing API ใช้ไม่ได้ หรือไม่มีทางใน OSM ใกล้ขอบโซน)
  /// ยกเว้นสนามกีฬา: ถ้ารอบสนามไม่มีทางใน OSM จะคืนขอบสนามจริงจาก OSM (ลู่/ขอบสนาม) โดย
  /// [ZoneCourse.onRoads] = false เพื่อให้หน้าจอแจ้งผู้ใช้
  ///
  /// [useBuiltIn] = false บังคับคำนวณใหม่จากขอบโซนด้วย Routing API (ใช้ตอนสร้างเส้นทางในแอปใหม่
  /// ด้วย tool/route_check_test.dart)
  static Future<ZoneCourse?> zoneCourse(RunningZone zone, {bool useBuiltIn = true}) async {
    final linear = _linearCoursePath(zone);
    if (linear != null) return ZoneCourse(linear, onRoads: true);
    if (useBuiltIn) {
      final builtIn = _builtInCoursePath(zone);
      if (builtIn != null) return ZoneCourse(builtIn, onRoads: true);
    }
    final ring = _mainRing(zone);
    if (ring.length < 3) return null;
    final key = _courseKey(zone, ring);
    final hit = _courseCache[key];
    if (hit != null) return hit;

    final perimeterM = _pathLengthM([...ring, ring.first]);
    final sizeM = math.sqrt(_ringAreaM2(ring));
    if (perimeterM < 50) return null;

    List<LatLng>? best;
    double bestPenalty = double.infinity;
    bool anyResponse = false;
    final tried = <String>{};
    // (สัดส่วนการขยับขอบเทียบขนาดโซน: ลบ = เข้าด้านใน, จำนวนจุดผ่านโดยประมาณ)
    for (final c in const [(0.0, 10), (0.0, 20), (-0.06, 20), (-0.14, 10), (0.06, 20)]) {
      final offsetM = (c.$1 * sizeM).clamp(-60.0, 35.0);
      final n = (perimeterM / (perimeterM / c.$2).clamp(25.0, 450.0)).round().clamp(4, 40);
      if (!tried.add('${offsetM.round()}:$n')) continue;
      final wps = _sampleRingN(_offsetRing(ring, offsetM), n);
      final routed = await _routeLoop([...wps, wps.first]);
      if (routed.length < 4) continue;
      anyResponse = true;
      var loop = extractLoop(routed);
      if (loop.length < 4) continue;
      // ติ่งแคบที่ปากไม่ได้อยู่จุดเดียวกันพอดี (ออก–กลับคนละจุดบนถนนเดียวกัน): ตัดออกแล้วขอเส้นทางใหม่
      // ผ่านจุดบนวงที่ตัดแล้ว เพื่อให้รอยต่อตรงปากติ่งเป็นทางจริงจาก Routing API เช่นเดิม
      final trimmed = _cutNearLobes(loop);
      if (trimmed.length < loop.length) {
        final m = (_pathLengthM(trimmed) / 100).round().clamp(8, 40);
        final wps2 = _sampleRingN(_openRing(trimmed), m);
        final again = extractLoop(await _routeLoop([...wps2, wps2.first]));
        if (again.length >= 4 && _pathLengthM(again) <= _pathLengthM(loop)) loop = again;
      }
      final ratio = _pathLengthM(loop) / perimeterM;
      final dev = _medianDeviationM(loop, ring);
      // ยอมรับเฉพาะวงที่ระยะไม่ต่างจากเส้นรอบโซนเกินไป และยังเกาะขอบโซน
      if (ratio < 0.3 || ratio > 1.8 || dev > math.max(45.0, 0.12 * sizeM)) continue;
      final penalty = math.log(ratio).abs() + dev / 100.0;
      if (penalty < bestPenalty) {
        bestPenalty = penalty;
        best = loop;
      }
      if (bestPenalty <= 0.2) break;
    }

    if (best != null) {
      return _courseCache[key] = ZoneCourse(best, onRoads: true);
    }
    // Routing API ไม่ตอบเลย → ไม่แคช ให้ลองใหม่ครั้งหน้า
    if (!anyResponse) return null;
    if (zone.category == 'stadium') {
      return _courseCache[key] = ZoneCourse([...ring, ring.first], onRoads: false);
    }
    return null;
  }

  /// เส้นทางมาตรฐาน [laps] รอบ เริ่ม–จบที่จุดบนเส้นทางที่ใกล้ [start] ที่สุด
  /// คืน null เมื่อสร้างเส้นทางบนทางจริงไม่ได้ (ดู [zoneCourse])
  static Future<List<LatLng>?> fixedCourse(RunningZone zone, LatLng start, int laps) async {
    final course = await zoneCourse(zone);
    if (course == null) return null;
    if (isLinearCourse(zone)) return List<LatLng>.of(course.lap);
    final open = _openRing(course.lap);
    if (open.length < 3) return null;
    final near = _nearestOnRing(start, open);
    final lap = _ringStartingAt(open, near.point, near.segIndex)..add(near.point);
    final out = <LatLng>[...lap];
    for (int i = 1; i < laps; i++) {
      out.addAll(lap.skip(1));
    }
    return out;
  }

  /// พื้นที่ของ ring (ตร.ม.) แบบ shoelace บนระนาบประมาณ
  static double _ringAreaM2(List<LatLng> ring) => _signedAreaM2(ring).abs();

  static double _signedAreaM2(List<LatLng> ring) {
    if (ring.length < 3) return 0;
    const m = 111320.0;
    final k = m * math.cos(ring.first.latitude * math.pi / 180.0);
    double a = 0;
    for (int i = 0; i < ring.length; i++) {
      final p = ring[i], q = ring[(i + 1) % ring.length];
      a += (p.longitude * k) * (q.latitude * m) - (q.longitude * k) * (p.latitude * m);
    }
    return a / 2;
  }

  /// ขยับขอบ ring ออกด้านนอก ([metres] > 0) หรือเข้าด้านใน ([metres] < 0) ตามแนวตั้งฉากของแต่ละจุด
  static List<LatLng> _offsetRing(List<LatLng> ring, double metres) {
    if (metres.abs() < 1 || ring.length < 3) return ring;
    const m = 111320.0;
    final k = m * math.cos(ring.first.latitude * math.pi / 180.0);
    final sgn = _signedAreaM2(ring) > 0 ? 1.0 : -1.0;
    final n = ring.length;
    final out = <LatLng>[];
    for (int i = 0; i < n; i++) {
      final a = ring[(i - 1 + n) % n], b = ring[i], c = ring[(i + 1) % n];
      final dx = (c.longitude - a.longitude) * k, dy = (c.latitude - a.latitude) * m;
      final len = math.sqrt(dx * dx + dy * dy);
      if (len < 1e-6) {
        out.add(b);
        continue;
      }
      final nx = dy / len * sgn, ny = -dx / len * sgn;
      out.add(LatLng(b.latitude + ny * metres / m, b.longitude + nx * metres / k));
    }
    return out;
  }

  /// จุดผ่าน [n] จุด ระยะห่างเท่ากันตามเส้นรอบ ring (ไม่รวมจุดปิดท้าย)
  static List<LatLng> _sampleRingN(List<LatLng> ring, int n) {
    final closed = [...ring, ring.first];
    final step = _pathLengthM(closed) / n;
    final out = <LatLng>[closed.first];
    double target = step, acc = 0;
    for (int i = 0; i < closed.length - 1 && out.length < n; i++) {
      final a = closed[i], b = closed[i + 1];
      final seg = _d(a, b);
      while (seg > 0 && acc + seg >= target && out.length < n) {
        final t = (target - acc) / seg;
        out.add(LatLng(a.latitude + (b.latitude - a.latitude) * t,
            a.longitude + (b.longitude - a.longitude) * t));
        target += step;
      }
      acc += seg;
    }
    return out;
  }

  /// ค่ากลางของระยะ (ม.) จากจุดบน [path] (ทุก ~20 ม.) ถึงขอบ [ring]
  static double _medianDeviationM(List<LatLng> path, List<LatLng> ring) {
    final ds = <double>[];
    for (int i = 0; i < path.length - 1; i++) {
      final a = path[i], b = path[i + 1];
      final steps = math.max(1, (_d(a, b) / 20).floor());
      for (int j = 0; j < steps; j++) {
        final t = j / steps;
        final p = LatLng(a.latitude + (b.latitude - a.latitude) * t,
            a.longitude + (b.longitude - a.longitude) * t);
        ds.add(_d(p, _nearestOnRing(p, ring).point));
      }
    }
    if (ds.isEmpty) return double.infinity;
    ds.sort();
    return ds[ds.length ~/ 2];
  }

  /// ดึง "วงปิด" ออกจากเส้นทางวนที่ได้จาก Routing API
  ///
  /// เส้นทางที่วนผ่านจุดผ่านหลายจุดมักมีช่วงที่เดินเข้าไปแล้วย้อนกลับทางเดิม (จุดผ่านไปตกบน
  /// ซอยตัน/ถนนอีกฝั่ง) ช่วงแบบนั้นแต่ละด้านจะถูกเดินเป็นจำนวนคู่ครั้ง จึงเก็บเฉพาะด้านที่ถูกเดิน
  /// เป็นจำนวนคี่ครั้ง — ที่เหลือเป็นกราฟที่ทุกจุดมีดีกรีคู่ (เดินวนได้ครบโดยไม่ซ้ำด้าน)
  /// แล้วเลือกกลุ่มที่ยาวที่สุดมาเดินเป็นวงเดียว (Euler circuit) ทุกด้านยังเป็นทางจริงจาก API
  static List<LatLng> extractLoop(List<LatLng> path) {
    (int, int) keyOf(LatLng p) => ((p.latitude * 1e6).round(), (p.longitude * 1e6).round());
    final pts = <LatLng>[];
    for (final p in path) {
      if (pts.isEmpty || keyOf(pts.last) != keyOf(p)) pts.add(p);
    }
    if (pts.length < 4) return const [];

    const m = 111320.0;
    final k = m * math.cos(pts.first.latitude * math.pi / 180.0);
    final coord = <(int, int), LatLng>{for (final p in pts) keyOf(p): p};
    final xy = <(int, int), (double, double)>{
      for (final e in coord.entries) e.key: (e.value.longitude * k, e.value.latitude * m)
    };
    // ดัชนีกริดของจุดยอด (ช่อง 30 ม.) ใช้หาจุดที่ตกอยู่กลางด้าน เพื่อแบ่งด้านให้ตรงกันทั้งขาไป-ขากลับ
    const cell = 30.0;
    final grid = <(int, int), List<(int, int)>>{};
    for (final e in xy.entries) {
      grid.putIfAbsent(((e.value.$1 / cell).floor(), (e.value.$2 / cell).floor()), () => []).add(e.key);
    }

    final count = <((int, int), (int, int)), int>{};
    void addEdge((int, int) a, (int, int) b) {
      if (a == b) return;
      final lower = a.$1 < b.$1 || (a.$1 == b.$1 && a.$2 < b.$2);
      final e = lower ? (a, b) : (b, a);
      count[e] = (count[e] ?? 0) + 1;
    }

    for (int i = 0; i < pts.length - 1; i++) {
      final a = keyOf(pts[i]), b = keyOf(pts[i + 1]);
      final (ax, ay) = xy[a]!;
      final (bx, by) = xy[b]!;
      final dx = bx - ax, dy = by - ay;
      final len2 = dx * dx + dy * dy;
      final mids = <(double, (int, int))>[];
      if (len2 > 1) {
        for (int gx = (math.min(ax, bx) / cell).floor(); gx <= (math.max(ax, bx) / cell).floor(); gx++) {
          for (int gy = (math.min(ay, by) / cell).floor(); gy <= (math.max(ay, by) / cell).floor(); gy++) {
            for (final v in grid[(gx, gy)] ?? const <(int, int)>[]) {
              if (v == a || v == b) continue;
              final (px, py) = xy[v]!;
              final t = ((px - ax) * dx + (py - ay) * dy) / len2;
              if (t <= 0 || t >= 1) continue;
              final ox = px - ax - t * dx, oy = py - ay - t * dy;
              if (ox * ox + oy * oy < 0.36) mids.add((t, v));
            }
          }
        }
        mids.sort((p, q) => p.$1.compareTo(q.$1));
      }
      var prev = a;
      for (final mid in mids) {
        addEdge(prev, mid.$2);
        prev = mid.$2;
      }
      addEdge(prev, b);
    }

    final adj = <(int, int), Set<(int, int)>>{};
    count.forEach((e, c) {
      if (c.isEven) return; // เดินจำนวนคู่ครั้ง = ไป-กลับทางเดิม
      adj.putIfAbsent(e.$1, () => {}).add(e.$2);
      adj.putIfAbsent(e.$2, () => {}).add(e.$1);
    });
    if (adj.isEmpty) return const [];

    // กลุ่มที่เชื่อมถึงกัน → เลือกกลุ่มที่ความยาวรวมมากที่สุด
    final seen = <(int, int)>{};
    List<(int, int)> bestComp = const [];
    double bestLen = -1;
    for (final s in adj.keys) {
      if (!seen.add(s)) continue;
      final comp = <(int, int)>[];
      final stack = [s];
      double len = 0;
      while (stack.isNotEmpty) {
        final u = stack.removeLast();
        comp.add(u);
        for (final v in adj[u]!) {
          len += _d(coord[u]!, coord[v]!) / 2;
          if (seen.add(v)) stack.add(v);
        }
      }
      if (len > bestLen) {
        bestLen = len;
        bestComp = comp;
      }
    }
    if (bestComp.length < 3 || bestComp.any((u) => adj[u]!.length.isOdd)) return const [];

    // Hierholzer: เดินครบทุกด้านของกลุ่มเป็นวงเดียว
    final rem = {for (final u in bestComp) u: Set.of(adj[u]!)};
    final stack = [bestComp.first];
    final circuit = <LatLng>[];
    while (stack.isNotEmpty) {
      final u = stack.last;
      final next = rem[u]!;
      if (next.isNotEmpty) {
        final v = next.first;
        next.remove(v);
        rem[v]!.remove(u);
        stack.add(v);
      } else {
        circuit.add(coord[stack.removeLast()]!);
      }
    }
    return _dropThinLobes(circuit);
  }

  static bool _isThinLobe(List<LatLng> open) {
    final len = _pathLengthM([...open, open.first]);
    if (len <= 0 || open.length < 3) return true;
    final area = _ringAreaM2(open);
    return area / (len / 2) < 20 || 4 * math.pi * area / (len * len) < 0.35;
  }

  /// ตัดช่วงของวงที่ออกไปแล้ววกกลับมาใกล้จุดเดิม (≤ 25 ม.) เป็นรูปผอมยาว — ผลลัพธ์มีรอยต่อสั้น ๆ
  /// ที่ยังไม่ได้ยืนยันว่าเป็นทางจริง ผู้เรียกต้องขอเส้นทางใหม่ผ่านจุดบนผลลัพธ์นี้
  static List<LatLng> _cutNearLobes(List<LatLng> circuit) {
    var loop = List<LatLng>.of(circuit);
    for (int guard = 0; guard < 20; guard++) {
      final n = loop.length;
      if (n < 8) break;
      final cum = List<double>.filled(n, 0);
      for (int i = 1; i < n; i++) {
        cum[i] = cum[i - 1] + _d(loop[i - 1], loop[i]);
      }
      final maxLobe = cum.last * 0.4;
      int bestI = -1, bestJ = -1;
      double bestLen = 0;
      for (int i = 0; i < n - 3; i++) {
        for (int j = i + 3; j < n - 1; j++) {
          final along = cum[j] - cum[i];
          if (along > maxLobe) break;
          if (along <= bestLen || along < 60) continue;
          final gap = _d(loop[i], loop[j]);
          if (gap > 25 || along < 4 * gap) continue;
          if (_isThinLobe(loop.sublist(i, j + 1))) {
            bestI = i;
            bestJ = j;
            bestLen = along;
          }
        }
      }
      if (bestI < 0) break;
      loop = [...loop.sublist(0, bestI + 1), ...loop.sublist(bestJ)];
    }
    return loop;
  }

  /// ตัด "ติ่งแคบ" ออกจากวง: วงย่อยที่ออกจากจุดหนึ่งแล้ววนกลับมาจุดเดิมโดยขาไป-ขากลับขนานชิดกัน
  /// (เช่น ออกทางถนนแล้วกลับทางเท้า/อีกฝั่งของถนนคู่ขนาน) — ความกว้างเฉลี่ย < 20 ม.
  /// หรือรูปทรงผอมยาว (4πA/P² < 0.35 เช่น ออกถนนเส้นหนึ่งยาว ๆ แล้วกลับอีกเส้นที่ขนานกัน)
  /// ตัดที่จุดเดียวกันพอดี เส้นที่เหลือจึงยังต่อเนื่องบนทางจริง
  static List<LatLng> _dropThinLobes(List<LatLng> circuit) {
    (int, int) keyOf(LatLng p) => ((p.latitude * 1e6).round(), (p.longitude * 1e6).round());
    bool isThin(List<LatLng> cyc) {
      final len = _pathLengthM(cyc);
      if (len <= 0) return true;
      final area = _ringAreaM2(cyc.sublist(0, cyc.length - 1));
      return area / (len / 2) < 20 || 4 * math.pi * area / (len * len) < 0.35;
    }

    var loop = List<LatLng>.of(circuit);
    for (int guard = 0; guard < 50; guard++) {
      if (loop.length < 5) break;
      final lastSeen = <(int, int), int>{};
      List<LatLng>? reduced;
      for (int i = 0; i < loop.length - 1 && reduced == null; i++) {
        final k = keyOf(loop[i]);
        final prev = lastSeen[k];
        lastSeen[k] = i;
        if (prev == null || i - prev < 2) continue;
        // จุดเดียวกันถูกผ่านสองครั้ง → วงแยกเป็น 2 วงย่อยที่จุดนี้: ช่วง prev..i และส่วนที่เหลือ (อ้อมจุดเริ่ม)
        final inner = loop.sublist(prev, i + 1);
        final outer = [...loop.sublist(i, loop.length - 1), ...loop.sublist(0, prev + 1)];
        final innerThin = isThin(inner), outerThin = isThin(outer);
        if (innerThin && outerThin) {
          reduced = _pathLengthM(inner) < _pathLengthM(outer) ? outer : inner;
        } else if (innerThin) {
          reduced = outer;
        } else if (outerThin) {
          reduced = inner;
        }
      }
      if (reduced == null) break;
      loop = reduced;
    }
    return loop;
  }

  /// สร้างเส้นทางวงรอบ (Loop route) ภายในโซนวิ่งตามระยะทางเป้าหมาย (targetKm)
  /// (วิธีเดิม — ไม่ได้ใช้ในหน้าโซนแล้ว เก็บไว้สำหรับอ้างอิง/โซนที่ไม่มีขอบชัดเจน)
  ///
  /// แนวคิด: ใช้ "รูปทรงของโซน" เป็นแม่แบบของวง แล้วให้ Routing API เดินตามถนนจริง
  ///   1) วงฐาน = ขอบโซน (คูเมือง/อ่างเก็บน้ำ ใช้ขอบจริง, สวน/สนาม หดเข้าหาศูนย์กลาง 15% ให้ใช้ทางเดินด้านใน)
  ///   2) ระยะเป้าหมาย ≥ ~80% ของเส้นรอบวง → วิ่งรอบโซนเต็มวง (หลายรอบถ้าเป้าหมายยาว)
  ///      ระยะสั้นกว่า → ย่อวงฐานลงโดยยึดจุดเริ่มเป็นจุดตรึง ได้วงเล็กรูปทรงเดียวกันที่แตะจุดเริ่ม
  ///   3) สุ่มจุดผ่านตามระยะทางบนวง (ทุก ~250 ม.) เรียงทิศทางเดียว → ไม่ย้อนไปมา
  ///   4) ขอเส้นทางแบบ continue_straight (ห้ามกลับรถที่จุดผ่าน) แล้วตัด "ติ่ง" ไป-กลับที่เหลือ
  ///   5) ปรับขนาดวงสูงสุด 3 รอบให้ระยะใกล้เป้าหมาย (±15%)
  static Future<List<LatLng>> buildLoopInZone({
    required RunningZone zone,
    required LatLng start,
    required double targetKm,
  }) async {
    final rawRing = _openRing(zone.polygons.isNotEmpty ? zone.polygons.first : <LatLng>[]);
    if (rawRing.length < 3) return [start];

    final isRibbon = zone.category == 'moat' || zone.category == 'reservoir';
    final centroid = _centroid(rawRing);
    final baseRing = isRibbon ? rawRing : _scaleRing(rawRing, centroid, 0.85);

    // จุดเริ่ม: ตำแหน่งผู้ใช้ถ้าอยู่ในโซน ไม่งั้นจุดบนขอบที่ใกล้ที่สุด
    final onRing = _nearestOnRing(start, baseRing);
    final LatLng anchor = onRing.point;
    final ringFromAnchor = _ringStartingAt(baseRing, onRing.point, onRing.segIndex);
    final perimeterM = _pathLengthM([...ringFromAnchor, ringFromAnchor.first]);
    if (perimeterM < 50) return [start];

    final targetM = targetKm * 1000;
    // เส้นทางตามถนนมักยาวกว่ารูปหลายเหลี่ยม ~15–25%
    const roadFactor = 1.2;

    // ── 0) OpenRouteService round_trip: วงรอบจากโครงข่ายถนนจริง ──
    // ระยะต่ำกว่าเส้นรอบโซน → ให้ ORS สร้างวงจากจุดเริ่ม (ผู้ใช้ในโซน = ตำแหน่งผู้ใช้)
    // แล้วเลือกผลที่ "อยู่ในโซนมากที่สุด" และระยะใกล้เป้าหมายที่สุด
    if (targetM < perimeterM * roadFactor * 0.8) {
      final origin = ZoneService.pointInZone(start, zone) ? start : anchor;
      final ors = await _orsBestRoundTrip(
        origin: origin,
        targetM: targetM,
        zone: zone,
        ring: baseRing,
      );
      if (ors != null) return ors;
    }

    // ── กรณีวิ่งรอบโซนเต็มวง ──
    if (targetM >= perimeterM * roadFactor * 0.8) {
      final lapWps = _sampleClosedRing(ringFromAnchor, perimeterM);
      final lap = _removeSpurs(await _routeLoop(lapWps));
      final lapM = _pathLengthM(lap);
      if (lap.length < 2 || lapM <= 0) return lapWps;
      final laps = math.max(1, (targetM / lapM).round());
      final out = <LatLng>[...lap];
      for (int i = 1; i < laps; i++) {
        out.addAll(lap.skip(1));
      }
      return out;
    }

    // ── กรณีวงย่อ: ย่อรูปทรงโซนโดยยึดจุดเริ่ม ──
    double f = (targetM / (perimeterM * roadFactor)).clamp(0.08, 1.0);
    List<LatLng> best = const [];
    double bestDiff = double.infinity;
    for (int attempt = 0; attempt < 3; attempt++) {
      final small = _scaleRing(ringFromAnchor, anchor, f);
      final smallLen = _pathLengthM([...small, small.first]);
      final wps = _sampleClosedRing(small, smallLen);
      final path = _removeSpurs(await _routeLoop(wps));
      final km = _pathLengthM(path) / 1000.0;
      if (path.length >= 2 && km > 0) {
        final diff = (km - targetKm).abs() / targetKm;
        if (diff < bestDiff) {
          bestDiff = diff;
          best = path;
        }
        if (diff <= 0.15) break;
        f = (f * targetKm / km).clamp(0.08, 1.0);
      } else if (best.isEmpty) {
        best = [...wps];
      }
    }
    return best.isNotEmpty ? best : [anchor];
  }

  // ─── OpenRouteService round_trip ──────────────────────────

  /// ขอวงรอบจาก ORS หลาย seed พร้อมกัน แล้วเลือกเส้นที่ดีที่สุด
  /// คะแนน = สัดส่วนจุดที่อยู่ในโซน (หรือห่างขอบ ≤ 80 ม.) − 0.8 × ความคลาดเคลื่อนของระยะ
  /// คืน null ถ้า ORS ใช้ไม่ได้ (ไม่มีเน็ต, โควตาหมด ฯลฯ) → ใช้วิธีสำรอง
  static Future<List<LatLng>?> _orsBestRoundTrip({
    required LatLng origin,
    required double targetM,
    required RunningZone zone,
    required List<LatLng> ring,
  }) async {
    // ORS มักได้ระยะยาวกว่าที่ขอเล็กน้อย → ขอสั้นลง 10%
    final reqLen = (targetM * 0.9).clamp(300.0, 40000.0);
    final points = targetM <= 2500 ? 3 : (targetM <= 6000 ? 4 : 5);
    final results = await Future.wait([
      for (final seed in const [1, 7, 23])
        _orsRoundTrip(origin, reqLen, points, seed),
    ]);

    List<LatLng>? best;
    double bestScore = -double.infinity;
    for (final path in results) {
      if (path == null || path.length < 3) continue;
      final lenM = _pathLengthM(path);
      if (lenM <= 0) continue;
      final diff = (lenM - targetM).abs() / targetM;
      int inside = 0, sampled = 0;
      final step = math.max(1, path.length ~/ 60);
      for (int i = 0; i < path.length; i += step) {
        sampled++;
        final p = path[i];
        if (ZoneService.pointInZone(p, zone) || _d(p, _nearestOnRing(p, ring).point) <= 80) {
          inside++;
        }
      }
      final insideFrac = sampled == 0 ? 0.0 : inside / sampled;
      final score = insideFrac - 0.8 * diff;
      if (score > bestScore) {
        bestScore = score;
        best = path;
      }
    }
    return best == null ? null : _removeSpurs(best);
  }

  static Future<List<LatLng>?> _orsRoundTrip(
      LatLng origin, double lengthM, int points, int seed) async {
    try {
      final body = json.encode({
        'coordinates': [
          [origin.longitude, origin.latitude]
        ],
        'options': {
          'round_trip': {'length': lengthM.round(), 'points': points, 'seed': seed},
        },
        'preference': 'recommended',
      });
      final res = await http
          .post(
            Uri.parse(_orsRoundTripUrl),
            headers: {
              'Authorization': _orsKey,
              'Content-Type': 'application/json',
              'Accept': 'application/geo+json, application/json',
            },
            body: body,
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return null;
      final data = json.decode(res.body) as Map<String, dynamic>;
      final features = (data['features'] as List?) ?? const [];
      if (features.isEmpty) return null;
      final coords = (features.first['geometry']?['coordinates'] as List?) ?? const [];
      final pts = coords
          .map((c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
          .where((p) => p.latitude.isFinite && p.longitude.isFinite)
          .toList();
      return pts.length > 2 ? pts : null;
    } catch (_) {
      return null;
    }
  }

  // ─── Loop helpers ─────────────────────────────────────────

  /// ขอเส้นทางวงรอบ: OSRM เดินเท้าแบบห้ามกลับรถที่จุดผ่าน (continue_straight) → fallback ปกติ
  static Future<List<LatLng>> _routeLoop(List<LatLng> wps) async {
    if (wps.length < 2) return wps;
    try {
      final coords = wps.map((p) => '${p.longitude},${p.latitude}').join(';');
      final url = '$_osrmFootBase/$coords?overview=full&geometries=geojson&continue_straight=true';
      final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 12));
      if (res.statusCode == 200) {
        final r = _parseGeoJsonRoutes(res.body);
        if (r.length > 2) return r;
      }
    } catch (_) {}
    return fetchRoute(wps);
  }

  static double _d(LatLng a, LatLng b) =>
      Geolocator.distanceBetween(a.latitude, a.longitude, b.latitude, b.longitude);

  static double _pathLengthM(List<LatLng> path) {
    double m = 0;
    for (int i = 0; i < path.length - 1; i++) {
      m += _d(path[i], path[i + 1]);
    }
    return m;
  }

  /// ตัดจุดปิดท้ายที่ซ้ำกับจุดแรกออก (ring แบบเปิด)
  static List<LatLng> _openRing(List<LatLng> ring) {
    final r = ring.where((p) => p.latitude.isFinite && p.longitude.isFinite).toList();
    if (r.length > 1 && _d(r.first, r.last) < 1) r.removeLast();
    return r;
  }

  static LatLng _centroid(List<LatLng> ring) {
    double lat = 0, lng = 0;
    for (final p in ring) {
      lat += p.latitude;
      lng += p.longitude;
    }
    return LatLng(lat / ring.length, lng / ring.length);
  }

  /// ย่อ/ขยายรูปทรงรอบจุด [o] ด้วยอัตราส่วน [f]
  static List<LatLng> _scaleRing(List<LatLng> ring, LatLng o, double f) => [
        for (final p in ring)
          LatLng(o.latitude + (p.latitude - o.latitude) * f,
              o.longitude + (p.longitude - o.longitude) * f),
      ];

  /// จุดบนขอบ ring ที่ใกล้ [p] ที่สุด (ฉายลงบนแต่ละด้าน)
  static ({LatLng point, int segIndex}) _nearestOnRing(LatLng p, List<LatLng> ring) {
    final mPerLng = math.cos(p.latitude * math.pi / 180.0);
    LatLng best = ring.first;
    int bestSeg = 0;
    double bestD = double.infinity;
    for (int i = 0; i < ring.length; i++) {
      final a = ring[i];
      final b = ring[(i + 1) % ring.length];
      final ax = a.longitude * mPerLng, ay = a.latitude;
      final bx = b.longitude * mPerLng, by = b.latitude;
      final px = p.longitude * mPerLng, py = p.latitude;
      final dx = bx - ax, dy = by - ay;
      final len2 = dx * dx + dy * dy;
      double t = len2 == 0 ? 0 : ((px - ax) * dx + (py - ay) * dy) / len2;
      t = t.clamp(0.0, 1.0);
      final q = LatLng(a.latitude + (b.latitude - a.latitude) * t,
          a.longitude + (b.longitude - a.longitude) * t);
      final d = _d(p, q);
      if (d < bestD) {
        bestD = d;
        best = q;
        bestSeg = i;
      }
    }
    return (point: best, segIndex: bestSeg);
  }

  /// เรียง ring ใหม่ให้เริ่มที่จุด [start] (อยู่บนด้าน segIndex) แล้ววนตามลำดับเดิม
  static List<LatLng> _ringStartingAt(List<LatLng> ring, LatLng start, int segIndex) {
    final out = <LatLng>[start];
    for (int k = 1; k <= ring.length; k++) {
      final q = ring[(segIndex + k) % ring.length];
      if (_d(q, out.last) > 1) out.add(q);
    }
    return out;
  }

  /// สุ่มจุดผ่านตามระยะทางบนวงปิด (เริ่ม–จบที่จุดแรก) ห่างกันราว 250 ม. (6–14 จุด)
  static List<LatLng> _sampleClosedRing(List<LatLng> ring, double lengthM) {
    final closed = [...ring, ring.first];
    final n = (lengthM / 250).round().clamp(6, 14);
    final step = lengthM / n;
    final out = <LatLng>[closed.first];
    double target = step;
    double acc = 0;
    for (int i = 0; i < closed.length - 1 && out.length < n; i++) {
      final a = closed[i], b = closed[i + 1];
      final seg = _d(a, b);
      while (seg > 0 && acc + seg >= target && out.length < n) {
        final t = (target - acc) / seg;
        out.add(LatLng(a.latitude + (b.latitude - a.latitude) * t,
            a.longitude + (b.longitude - a.longitude) * t));
        target += step;
      }
      acc += seg;
    }
    out.add(closed.first);
    return out;
  }

  /// ตัด "ติ่ง" ที่เส้นทางวิ่งเข้าซอยแล้วย้อนกลับทางเดิม (เกิดจากจุดผ่านไปตกบนซอยตัน)
  static List<LatLng> _removeSpurs(List<LatLng> path) {
    if (path.length < 4) return path;
    final total = _pathLengthM(path);
    final maxSpurM = math.min(600.0, total * 0.2);
    final out = <LatLng>[];
    int i = 0;
    while (i < path.length) {
      out.add(path[i]);
      // หาจุดข้างหน้าที่กลับมาใกล้จุดนี้ (≤15 ม.) ภายในระยะทางสั้น ๆ → ข้ามช่วงนั้น
      double along = 0;
      int jump = -1;
      for (int j = i + 1; j < path.length; j++) {
        along += _d(path[j - 1], path[j]);
        if (along > maxSpurM) break;
        if (j >= i + 2 && along > 40 && _d(path[i], path[j]) <= 15) jump = j;
      }
      i = jump > 0 ? jump + 1 : i + 1;
    }
    if (_d(out.last, path.last) > 1) out.add(path.last);
    return out.length >= 2 ? out : path;
  }
}

/// เส้นทางมาตรฐาน 1 รอบของโซน
class ZoneCourse {
  /// จุดของเส้นทาง 1 รอบ (วงปิด: จุดแรก = จุดสุดท้าย, เส้นทางขึ้นเขา: ทางเดียว)
  final List<LatLng> lap;

  /// true = ทุกช่วงมาจาก Routing API (อยู่บนถนน/ทางเดินจริง)
  /// false = ขอบสนามจาก OSM (รอบสนามไม่มีทางใน OSM ให้แนบ)
  final bool onRoads;

  const ZoneCourse(this.lap, {required this.onRoads});

  double get lapKm {
    double m = 0;
    for (int i = 0; i < lap.length - 1; i++) {
      m += Geolocator.distanceBetween(
          lap[i].latitude, lap[i].longitude, lap[i + 1].latitude, lap[i + 1].longitude);
    }
    return m / 1000.0;
  }
}
