// สคริปต์ตรวจ "เส้นทางทุกโหมดอยู่บนถนน/ทางเดินจริง" — เรียก API จริง (OSRM / Overpass) ด้วยโค้ดเดียวกับแอป
//
// รัน:   flutter test tool/route_check_test.dart
// ผล:    build/route_check/all_routes.geojson  (เปิดดูที่ https://geojson.io)
//        build/route_check/<โหมด>.geojson, summary.txt, popular_paths.json
//
// แต่ละเส้นทางจะถูกตรวจ:
//   - closed   วงปิด (จุดแรก–จุดสุดท้ายห่างกันกี่เมตร)
//   - retrace  ระยะที่เดินซ้ำแนวเดิม (ติ่งไป-กลับ) — ควรเป็น 0
//   - ratio    ความยาวเทียบเส้นรอบขอบโซน
//   - snap     ระยะจากจุดบนเส้นทางถึงโครงข่ายทางเดินของ OSRM (/nearest) — ควร ≈ 0 ม.
//   - bldg     จำนวนช่วงของเส้นทางที่ตัดผ่านรูปอาคารใน OSM (Overpass) โดยที่ตรงนั้น "ไม่มีทาง" — ควรเป็น 0
//              (ถ้าตรงจุดตัดมีทางของ OSM อยู่จริง เช่น ถนนลอดใต้อาคาร/ทางเดินมีหลังคา จะนับแยกเป็น "ทางลอดอาคาร")
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:demo20426/models/preset_zones.dart';
import 'package:demo20426/models/route_data.dart';
import 'package:demo20426/models/running_zone.dart';
import 'package:demo20426/services/routing_service.dart';
import 'package:demo20426/services/safety_dijkstra_service.dart';
import 'package:demo20426/services/zone_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

const _osrm = 'https://routing.openstreetmap.de/routed-foot';
const _overpass = [
  'https://overpass-api.de/api/interpreter',
  'https://overpass.private.coffee/api/interpreter',
  'https://overpass.kumi.systems/api/interpreter',
  'https://maps.mail.ru/osm/tools/overpass/api/interpreter',
];
final _out = Directory('build/route_check');
final _cache = Directory('build/route_check/cache');
final _summary = StringBuffer();
final _allFeatures = <Map<String, dynamic>>[];
final _failures = <String>[];

double _d(LatLng a, LatLng b) =>
    Geolocator.distanceBetween(a.latitude, a.longitude, b.latitude, b.longitude);

double _len(List<LatLng> p) {
  double m = 0;
  for (int i = 0; i < p.length - 1; i++) {
    m += _d(p[i], p[i + 1]);
  }
  return m;
}

void _log(String s) {
  _summary.writeln(s);
  // ignore: avoid_print
  print(s);
}

Map<String, dynamic> _feature(String name, List<LatLng> pts, String color, [Map<String, dynamic>? extra]) => {
      'type': 'Feature',
      'properties': {'name': name, 'stroke': color, 'stroke-width': 4, 'stroke-opacity': 0.9, ...?extra},
      'geometry': {
        'type': 'LineString',
        'coordinates': [
          for (final p in pts) [p.longitude, p.latitude]
        ],
      },
    };

void _write(String file, List<Map<String, dynamic>> features) {
  File('${_out.path}/$file')
      .writeAsStringSync(json.encode({'type': 'FeatureCollection', 'features': features}));
}

List<LatLng> _densify(List<LatLng> path, double step) {
  final out = <LatLng>[if (path.isNotEmpty) path.first];
  for (int i = 0; i < path.length - 1; i++) {
    final a = path[i], b = path[i + 1];
    final k = math.max(1, (_d(a, b) / step).floor());
    for (int j = 1; j <= k; j++) {
      final t = j / k;
      out.add(LatLng(a.latitude + (b.latitude - a.latitude) * t, a.longitude + (b.longitude - a.longitude) * t));
    }
  }
  return out;
}

/// ระยะ (ม.) ของเส้นทางที่เป็นติ่งไป-กลับ: จุดที่ห่างกันตามเส้นทาง > 30 ม. แต่อยู่ซ้อนกัน ≤ 4 ม. (แนวเดียวกัน)
/// หรือวิ่งสวนทิศกันโดยขนานห่างกัน ≤ 20 ม. (ออกทางหนึ่ง กลับอีกทางที่ขนานกัน)
double _retraceM(List<LatLng> path, {required bool closed, int laps = 1}) {
  const step = 5.0, tol = 4.0, wide = 20.0;
  final d = _densify(path, step);
  if (d.length < 3) return 0;
  const m = 111320.0;
  final k = m * math.cos(d.first.latitude * math.pi / 180.0);
  final xs = [for (final p in d) p.longitude * k], ys = [for (final p in d) p.latitude * m];
  final grid = <int, List<int>>{};
  int cellOf(double x, double y) => (x / wide).floor() * 100003 + (y / wide).floor();
  for (int i = 0; i < d.length; i++) {
    grid.putIfAbsent(cellOf(xs[i], ys[i]), () => []).add(i);
  }
  final total = d.length * step;
  final lapLen = total / laps;
  int dup = 0;
  for (int i = 0; i < d.length; i++) {
    bool hit = false;
    for (int dx = -1; dx <= 1 && !hit; dx++) {
      for (int dy = -1; dy <= 1 && !hit; dy++) {
        for (final j in grid[cellOf(xs[i] + dx * wide, ys[i] + dy * wide)] ?? const <int>[]) {
          double along = (j - i).abs() * step;
          if (closed) {
            along = along % lapLen; // รอบที่ 2, 3 … ทับรอบแรกโดยตั้งใจ
            along = math.min(along, lapLen - along);
          }
          final ex = xs[j] - xs[i], ey = ys[j] - ys[i];
          final dist2 = ex * ex + ey * ey;
          if (along > 30 && dist2 <= wide * wide) {
            // นับเฉพาะช่วงที่ซ้อนขนานกัน (ไป-กลับ) ไม่นับจุดที่เส้นทางแค่ตัด/แตะกัน
            final i2 = math.min(i + 1, d.length - 1), i1 = math.max(i2 - 1, 0);
            final j2 = math.min(j + 1, d.length - 1), j1 = math.max(j2 - 1, 0);
            final ux = xs[i2] - xs[i1], uy = ys[i2] - ys[i1], vx = xs[j2] - xs[j1], vy = ys[j2] - ys[j1];
            final nu = math.sqrt(ux * ux + uy * uy), nv = math.sqrt(vx * vx + vy * vy);
            final cos = nu > 0 && nv > 0 ? (ux * vx + uy * vy) / (nu * nv) : 0.0;
            if (dist2 <= tol * tol ? cos.abs() > 0.9 : (cos < -0.9 && along > 60)) {
              hit = true;
              break;
            }
          }
        }
      }
    }
    if (hit) dup++;
  }
  return dup * step;
}

/// ระยะมากสุด/เฉลี่ย (ม.) จากจุดตัวอย่างบนเส้นทางถึงโครงข่ายทางเดินของ OSRM
Future<({double max, double mean, int n})?> _snapCheck(List<LatLng> path, {int samples = 10}) async {
  final d = _densify(path, 15);
  if (d.isEmpty) return null;
  final ds = <double>[];
  for (int s = 0; s < samples; s++) {
    final p = d[((s + 0.5) * d.length / samples).floor().clamp(0, d.length - 1)];
    try {
      final res = await http
          .get(Uri.parse('$_osrm/nearest/v1/driving/${p.longitude},${p.latitude}?number=1'))
          .timeout(const Duration(seconds: 12));
      if (res.statusCode == 200) {
        ds.add(((json.decode(res.body)['waypoints'] as List).first['distance'] as num).toDouble());
      }
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 150));
  }
  if (ds.isEmpty) return null;
  return (max: ds.reduce(math.max), mean: ds.reduce((a, b) => a + b) / ds.length, n: ds.length);
}

Future<Map<String, dynamic>?> _overpassQuery(String q) async {
  for (final ep in _overpass) {
    try {
      final res = await http.post(Uri.parse(ep),
          body: {'data': q},
          headers: {'User-Agent': 'otc10-route-check/1.0'}).timeout(const Duration(seconds: 25));
      if (res.statusCode == 200) return json.decode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {}
  }
  return null;
}

bool _segCross(double ax, double ay, double bx, double by, double cx, double cy, double dx, double dy) {
  double o(double px, double py, double qx, double qy, double rx, double ry) =>
      (qx - px) * (ry - py) - (qy - py) * (rx - px);
  final d1 = o(cx, cy, dx, dy, ax, ay), d2 = o(cx, cy, dx, dy, bx, by);
  final d3 = o(ax, ay, bx, by, cx, cy), d4 = o(ax, ay, bx, by, dx, dy);
  return ((d1 > 0) != (d2 > 0)) && ((d3 > 0) != (d4 > 0)) && d1 != 0 && d2 != 0 && d3 != 0 && d4 != 0;
}

/// นับช่วงของเส้นทางที่ตัดผ่านรูปอาคารใน OSM (null = Overpass ใช้ไม่ได้ ตรวจไม่ได้)
/// ไม่นับอาคารที่เป็นหลังคา/ทางเดินมีหลังคา (building=roof) และทางที่ลอดอาคาร (tunnel/covered ใน OSM มักเป็นแบบนี้)
Future<({List<LatLng> crossings, Set<int> buildings})?> _buildingCheck(String id, List<LatLng> path) async {
  final file = File('${_cache.path}/bldg_$id.json');
  Map<String, dynamic>? data;
  if (file.existsSync()) {
    data = json.decode(file.readAsStringSync()) as Map<String, dynamic>;
  } else {
    final pts = _densify(path, 40);
    final step = math.max(1, (pts.length / 150).ceil());
    final line = [
      for (int i = 0; i < pts.length; i += step)
        '${pts[i].latitude.toStringAsFixed(5)},${pts[i].longitude.toStringAsFixed(5)}'
    ].join(',');
    data = await _overpassQuery(
        '[out:json][timeout:30];way["building"]["building"!="roof"](around:${40 * step ~/ 2 + 15},$line);out geom;');
    if (data == null) return null;
    file.writeAsStringSync(json.encode(data));
  }
  const m = 111320.0;
  final k = m * math.cos(path.first.latitude * math.pi / 180.0);
  final crossings = <LatLng>[];
  final hit = <int>{};
  final polys = <(int, List<double>, List<double>)>[];
  for (final e in (data['elements'] as List? ?? const [])) {
    final g = e['geometry'] as List?;
    if (g == null || g.length < 4) continue;
    polys.add((
      e['id'] as int,
      [for (final p in g) (p['lon'] as num).toDouble() * k],
      [for (final p in g) (p['lat'] as num).toDouble() * m]
    ));
  }
  for (int i = 0; i < path.length - 1; i++) {
    final ax = path[i].longitude * k, ay = path[i].latitude * m;
    final bx = path[i + 1].longitude * k, by = path[i + 1].latitude * m;
    bool crossed = false;
    for (final (bid, xs, ys) in polys) {
      if (math.max(ax, bx) < xs.reduce(math.min) || math.min(ax, bx) > xs.reduce(math.max)) continue;
      if (math.max(ay, by) < ys.reduce(math.min) || math.min(ay, by) > ys.reduce(math.max)) continue;
      for (int j = 0; j < xs.length - 1; j++) {
        if (_segCross(ax, ay, bx, by, xs[j], ys[j], xs[j + 1], ys[j + 1])) {
          crossed = true;
          hit.add(bid);
          break;
        }
      }
    }
    if (crossed) {
      crossings.add(LatLng((path[i].latitude + path[i + 1].latitude) / 2,
          (path[i].longitude + path[i + 1].longitude) / 2));
    }
  }
  return (crossings: crossings, buildings: hit);
}

/// ขอบจริงของโซน (ดึงด้วยโค้ดของแอป; แคชลงไฟล์เพราะ Overpass ช้า/ล่มบ่อย)
Future<RunningZone> _resolveZone(RunningZone z) async {
  if (!ZoneService.needsGeometry(z)) return z;
  final file = File('${_cache.path}/ring_v${PresetZones.geometryVersion}_${z.id}.json');
  if (file.existsSync()) {
    final rings = (json.decode(file.readAsStringSync()) as List)
        .map((r) => [for (final p in r as List) LatLng((p[0] as num).toDouble(), (p[1] as num).toDouble())])
        .toList();
    return z.copyWith(polygons: rings, source: 'osm', computedAt: DateTime.now());
  }
  for (int attempt = 0; attempt < 3; attempt++) {
    final r = await ZoneService.resolvePresetGeometry(z);
    if (!ZoneService.needsGeometry(r)) {
      file.writeAsStringSync(json.encode([
        for (final ring in r.polygons) [for (final p in ring) [p.latitude, p.longitude]]
      ]));
      return r;
    }
    await Future<void>.delayed(const Duration(seconds: 3));
  }
  return z;
}

Future<String> _checks(String id, List<LatLng> path) async {
  final snap = await _snapCheck(path);
  final bldg = await _buildingCheck(id, path);
  final snapTxt = snap == null
      ? 'snap=ตรวจไม่ได้'
      : 'snap เฉลี่ย/มากสุด=${snap.mean.toStringAsFixed(1)}/${snap.max.toStringAsFixed(1)} ม. (${snap.n} จุด)';
  String bldgTxt = 'bldg=ตรวจไม่ได้ (Overpass ไม่ตอบ)';
  if (bldg != null) {
    // ช่วงที่ทับรูปอาคาร: ถ้าตรงนั้นมีทางของ OSM อยู่จริง (OSRM /nearest ≈ 0 ม.) = ถนน/ทางเดินลอดอาคาร
    int offRoad = 0;
    for (final mid in bldg.crossings) {
      final near = await _snapCheck([mid, mid], samples: 1);
      if (near == null || near.max > 3) offRoad++;
    }
    final under = bldg.crossings.length - offRoad;
    bldgTxt = 'bldg=$offRoad ช่วง'
        '${under > 0 ? ' (+ทางลอดอาคารตาม OSM $under ช่วง: way ${bldg.buildings.take(4).join(', ')})' : ''}';
    if (offRoad > 0) _failures.add('$id: ตัดผ่านอาคาร $offRoad ช่วง');
  }
  if (snap != null && snap.max > 8) _failures.add('$id: จุดบนเส้นทางห่างโครงข่ายทาง ${snap.max.toStringAsFixed(1)} ม.');
  return '$snapTxt | $bldgTxt';
}

void main() {
  HttpOverrides.global = null; // ใช้ HTTP จริง
  _cache.createSync(recursive: true);

  tearDownAll(() {
    _write('all_routes.geojson', _allFeatures);
    _log('\nสรุป: ${_failures.isEmpty ? 'ผ่านทุกข้อ' : 'พบ ${_failures.length} จุดที่ต้องดู'}');
    for (final f in _failures) {
      _log('  ! $f');
    }
    File('${_out.path}/summary.txt').writeAsStringSync(_summary.toString());
  });

  test('1) เส้นทางวงรอบในโซน (RoutingService.zoneCourse / fixedCourse)', () async {
    _log('== เส้นทางวงรอบในโซน ==');
    final feats = <Map<String, dynamic>>[];
    final popular = <String, List<List<double>>>{};
    for (final preset in PresetZones.defaultZones) {
      final zone = await _resolveZone(preset);
      if (ZoneService.needsGeometry(zone)) {
        _log('${zone.id}: ดึงขอบเขตจริงจาก Overpass ไม่ได้ — ข้าม');
        continue;
      }
      // คำนวณใหม่จากขอบโซนด้วย API จริงเสมอ (ไม่ใช้เส้นที่ฝังไว้ในแอป)
      final course = await RoutingService.zoneCourse(zone, useBuiltIn: false);
      final ring = zone.polygons.isEmpty ? <LatLng>[] : zone.polygons.reduce((a, b) => a.length >= b.length ? a : b);
      if (!RoutingService.isLinearCourse(zone) && ring.length >= 3) {
        feats.add(_feature('${zone.id} ขอบโซน', [...ring, ring.first], '#888888', {'stroke-width': 2}));
      }
      if (course == null) {
        _log('${zone.id}: สร้างเส้นทางบนทางจริงไม่ได้ (แอปจะแจ้งผู้ใช้ ไม่วาดเส้น)');
        continue;
      }
      final lap = course.lap;
      final linear = RoutingService.isLinearCourse(zone);
      final gap = _d(lap.first, lap.last);
      final retrace = _retraceM(lap, closed: !linear);
      final per = ring.length >= 3 ? _len([...ring, ring.first]) : 0.0;
      final checks = course.onRoads ? await _checks(zone.id, lap) : 'ขอบสนามจาก OSM (รอบสนามไม่มีทางใน OSM)';
      _log('${zone.id}: ${linear ? 'ทางเดียว' : 'วงรอบ'} ${(course.lapKm).toStringAsFixed(2)} กม.'
          '${linear || per == 0 ? '' : ' (${(course.lapKm * 1000 / per * 100).round()}% ของขอบโซน ${per.round()} ม.)'}'
          ' | closed gap=${gap.toStringAsFixed(1)} ม. | retrace=${retrace.round()} ม. | $checks');
      if (!linear && gap > 2) _failures.add('${zone.id}: วงไม่ปิด (${gap.toStringAsFixed(1)} ม.)');
      if (course.onRoads && retrace > 25) _failures.add('${zone.id}: มีติ่งไป-กลับ ${retrace.round()} ม.');
      feats.add(_feature('${zone.id} เส้นทาง ${course.lapKm.toStringAsFixed(2)} กม.', lap,
          course.onRoads ? '#e53935' : '#fb8c00'));
      popular[zone.id] = [for (final p in lap) [p.latitude, p.longitude]];

      // fixedCourse: 2 รอบ เริ่มที่จุดใกล้ศูนย์กลางโซน ต้องปิดวงและยาว 2 เท่า
      if (!linear) {
        final two = await RoutingService.fixedCourse(zone, zone.center, 2);
        expect(two, isNotNull);
        expect(_d(two!.first, two.last), lessThan(2.0));
        final lapM = RoutingService.fixedCourseLapKm(zone) * 1000;
        expect((_len(two) - 2 * lapM).abs(), lessThan(5.0));
      }
    }
    // เส้นทางขึ้นดอยสุเทพ (ทางเดียว): น้ำตกห้วยแก้ว/สวนสัตว์ → วัดผาลาด → วัดพระธาตุดอยสุเทพ
    final doi = await RoutingService.fetchRoute(const [LatLng(18.8105, 98.9460), LatLng(18.8048, 98.9215)]);
    if (doi.length > 2) popular['doi_suthep_route'] = [for (final p in doi) [p.latitude, p.longitude]];

    _write('zone_loops.geojson', feats);
    _allFeatures.addAll(feats);
    File('${_out.path}/popular_paths.json').writeAsStringSync(json.encode(popular));
  }, timeout: const Timeout(Duration(minutes: 25)));

  test('2) เส้นทางยอดนิยม 6 เส้น (ChiangMaiRoutes)', () async {
    _log('\n== เส้นทางยอดนิยม ==');
    final feats = <Map<String, dynamic>>[];
    for (final r in ChiangMaiRoutes.routes) {
      if (r.path.length < 2) {
        _log('${r.id}: ยังไม่มี path');
        _failures.add('${r.id}: ไม่มี path');
        continue;
      }
      final linear = r.id == 'doi_suthep';
      final km = _len(r.path) / 1000;
      final gap = _d(r.path.first, r.path.last);
      final retrace = _retraceM(r.path, closed: !linear);
      _log('${r.id}: ${km.toStringAsFixed(2)} กม. (distanceKm=${r.distanceKm}) | '
          '${linear ? 'ทางเดียว' : 'closed gap=${gap.toStringAsFixed(1)} ม.'} | retrace=${retrace.round()} ม. | '
          '${await _checks('route_${r.id}', r.path)}');
      expect(ChiangMaiRoutes.hasRoadPath(r), isTrue);
      if (!linear && gap > 2) _failures.add('${r.id}: วงไม่ปิด');
      if (retrace > 25) _failures.add('${r.id}: มีติ่งไป-กลับ ${retrace.round()} ม.');
      if ((km - r.distanceKm).abs() > 0.15) _failures.add('${r.id}: distanceKm ไม่ตรงกับ path');
      feats.add(_feature('${r.id} ${km.toStringAsFixed(2)} กม.', r.path, '#1e88e5'));
    }
    _write('popular_routes.geojson', feats);
    _allFeatures.addAll(feats);
  }, timeout: const Timeout(Duration(minutes: 15)));

  test('3) โหมดวางแผน A→B (fetchRouteAlternatives + Safety Dijkstra)', () async {
    _log('\n== โหมดวางแผน A→B ==');
    final feats = <Map<String, dynamic>>[];
    const cases = [
      ('ท่าแพ→วัดพระสิงห์', LatLng(18.7877, 98.9933), LatLng(18.7885, 98.9817)),
      ('นิมมาน→อ่างแก้ว มช.', LatLng(18.7995, 98.9680), LatLng(18.8062, 98.9505)),
      ('สวนบวกหาด→ประตูเชียงใหม่', LatLng(18.7822, 98.9795), LatLng(18.7812, 98.9868)),
      ('สถานีรถไฟ→กาดหลวง', LatLng(18.7845, 99.0170), LatLng(18.7903, 99.0010)),
    ];
    for (int c = 0; c < cases.length; c++) {
      final (name, a, b) = cases[c];
      final alts = await RoutingService.fetchRouteAlternatives(a, b);
      expect(alts.first.length, greaterThan(2), reason: 'ไม่ได้เส้นทางจาก Routing API');
      List<LatLng> path = alts.first;
      double best = double.infinity;
      for (final alt in alts) {
        final r = SafetyDijkstraService.run(osrmPath: alt, incidents: const []);
        if (r.totalSafetyWeight < best) {
          best = r.totalSafetyWeight;
          path = alt;
        }
      }
      final dj = SafetyDijkstraService.run(osrmPath: path, incidents: const [], isNight: true);
      // เส้นทางหลัง Dijkstra ต้องเป็นจุดของ OSRM เท่านั้น และไม่เบี่ยงจากเส้น OSRM เกิน 3 ม.
      double maxOff = 0;
      for (final p in _densify(dj.path, 5)) {
        double near = double.infinity;
        for (int i = 0; i < path.length - 1; i++) {
          near = math.min(near, _pointSegM(p, path[i], path[i + 1]));
        }
        maxOff = math.max(maxOff, near);
      }
      _log('$name: ทางเลือก ${alts.length} เส้น | เลือก ${(_len(dj.path) / 1000).toStringAsFixed(2)} กม. '
          '(เส้นตรง ${(_d(a, b) / 1000).toStringAsFixed(2)} กม.) | เบี่ยงจากเส้น OSRM มากสุด ${maxOff.toStringAsFixed(1)} ม. | '
          '${await _checks('ab_$c', dj.path)}');
      if (maxOff > 3.5) _failures.add('$name: Dijkstra ลัดออกนอกเส้น OSRM ${maxOff.toStringAsFixed(1)} ม.');
      for (int i = 0; i < alts.length; i++) {
        if (!identical(alts[i], path)) feats.add(_feature('$name ทางเลือก ${i + 1}', alts[i], '#9e9e9e', {'stroke-width': 2}));
      }
      feats.add(_feature('$name (เส้นที่แอปแสดง)', dj.path, '#43a047'));
    }
    _write('plan_a_to_b.geojson', feats);
    _allFeatures.addAll(feats);
  }, timeout: const Timeout(Duration(minutes: 15)));
}

double _pointSegM(LatLng p, LatLng a, LatLng b) {
  const m = 111320.0;
  final k = m * math.cos(p.latitude * math.pi / 180.0);
  final ax = a.longitude * k, ay = a.latitude * m, bx = b.longitude * k, by = b.latitude * m;
  final px = p.longitude * k, py = p.latitude * m;
  final dx = bx - ax, dy = by - ay;
  final l2 = dx * dx + dy * dy;
  final t = l2 == 0 ? 0.0 : (((px - ax) * dx + (py - ay) * dy) / l2).clamp(0.0, 1.0);
  final ex = px - ax - t * dx, ey = py - ay - t * dy;
  return math.sqrt(ex * ex + ey * ey);
}
