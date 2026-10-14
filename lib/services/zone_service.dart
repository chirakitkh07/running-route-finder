import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/running_zone.dart';
import '../models/preset_zones.dart';
import '../models/incident_report.dart';
import 'road_context_service.dart';
import 'safety_score_engine.dart';
import 'air_quality_service.dart';
import '../utils/geo_utils.dart';

/// บริการจัดการและคำนวณคะแนนโซนวิ่ง (ZoneService)
class ZoneService {
  static const _endpoints = [
    'https://overpass-api.de/api/interpreter',
    'https://overpass.kumi.systems/api/interpreter',
    'https://overpass.private.coffee/api/interpreter',
    'https://maps.mail.ru/osm/tools/overpass/api/interpreter',
  ];

  static const String _weatherUrl = 'https://api.open-meteo.com/v1/forecast';
  static const String _aqiUrl = 'https://air-quality-api.open-meteo.com/v1/air-quality';

  // ─── Overpass Concurrency Mutex (จำกัดไม่เกิน 1 request พร้อมกัน) ─────────────
  static Future<void> _overpassLock = Future.value();

  static Future<T> _runWithOverpassLock<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _overpassLock = _overpassLock.then((_) async {
      try {
        final result = await action();
        completer.complete(result);
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  static Future<T> runWithOverpassLock<T>(Future<T> Function() action) {
    return _runWithOverpassLock(action);
  }

  /// ตรวจสอบว่าพิกัด [p] อยู่ภายในรูปหลายเหลี่ยม [ring] หรือไม่ (Ray Casting Algorithm)
  static bool pointInPolygon(LatLng p, List<LatLng> ring) {
    if (ring.length < 3) return false;
    bool inside = false;
    int j = ring.length - 1;
    for (int i = 0; i < ring.length; i++) {
      final pi = ring[i];
      final pj = ring[j];

      final intersects = ((pi.latitude > p.latitude) != (pj.latitude > p.latitude)) &&
          (p.longitude <
              (pj.longitude - pi.longitude) *
                      (p.latitude - pi.latitude) /
                      (pj.latitude - pi.latitude) +
                  pi.longitude);

      if (intersects) inside = !inside;
      j = i;
    }
    return inside;
  }

  /// ตรวจสอบว่าจุดอยู่ภายในโซนหรือไม่ (รองรับ multipolygon)
  static bool pointInZone(LatLng p, RunningZone zone) {
    for (final ring in zone.polygons) {
      if (pointInPolygon(p, ring)) return true;
    }
    return false;
  }

  /// โหลดข้อมูลโซนเริ่มต้น 6 โซน
  /// 1. อ่าน cache จาก Firestore collection 'zones' (อายุไม่เกิน 7 วัน)
  /// 2. ถ้าไม่มี cache ดึงรูปทรงจริงจาก Overpass API
  /// 3. ถ้า Overpass ล้มเหลว ให้ใช้ fallback polygon จาก PresetZones
  /// โหลดโซนเริ่มต้นแบบเร็ว: ค่าเริ่มต้น + แคช Firestore (ไม่เรียก Overpass)
  /// ใช้แสดงผลบนแผนที่ทันที แล้วค่อยเรียก [resolvePresetGeometry] ทีละโซนใน background
  static Future<List<RunningZone>> loadPresetZonesFast() async {
    final defaultList = PresetZones.defaultZones;
    final Map<String, RunningZone> zoneMap = {for (final z in defaultList) z.id: z};

    try {
      final firestore = FirebaseFirestore.instance;
      // whereIn รับได้จำกัดจำนวน → แบ่งเป็นชุดละ 10
      final ids = zoneMap.keys.toList();
      final docs = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
      for (int k = 0; k < ids.length; k += 10) {
        final snap = await firestore
            .collection('zones')
            .where(FieldPath.documentId, whereIn: ids.sublist(k, (k + 10).clamp(0, ids.length)))
            .get()
            .timeout(const Duration(seconds: 4));
        docs.addAll(snap.docs);
      }

      for (final doc in docs) {
        if (!doc.exists) continue;
        try {
          final data = doc.data();
          // แคชที่ดึงด้วยวิธีเก่า (รูปทรงไม่ตรงสถานที่จริง) ให้ดึงใหม่
          if ((data['geomVersion'] as num?)?.toInt() != PresetZones.geometryVersion) continue;
          final cachedZone = RunningZone.fromMap(data, doc.id);
          if (cachedZone.polygons.isNotEmpty && cachedZone.computedAt != null) {
            final ageDays = DateTime.now().difference(cachedZone.computedAt!).inDays;
            if (ageDays < 7) {
              zoneMap[doc.id] = cachedZone;
            }
          }
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('[ZoneService] Firestore cache lookup note: $e');
    }
    return zoneMap.values.toList();
  }

  /// true ถ้าโซนนี้ยังใช้รูปทรงสำรอง (ยังไม่ได้ขอบเขตจริงจาก OSM/แคช)
  /// ดูจาก [RunningZone.source] — เดิมดูจาก computedAt ซึ่ง [scoreZone] ก็ตั้งค่าให้ด้วย
  /// ทำให้โซนที่ยังเป็นรูปทรงสำรองถูกมองว่าได้ขอบเขตจริงแล้ว (เส้นทางวงรอบจึงสร้างจากรูปทรงสำรอง)
  static bool needsGeometry(RunningZone zone) =>
      PresetZones.osmSpecs.containsKey(zone.id) &&
      (zone.source != 'osm' || zone.polygons.isEmpty);

  /// ดึงขอบเขตจริงของโซนเดียวจาก OSM ถ้ายังไม่มี (คืนโซนเดิมถ้าล้มเหลว)
  static Future<RunningZone> resolvePresetGeometry(RunningZone preset) async {
    if (!needsGeometry(preset)) return preset;
    try {
      final osmRings = await _fetchPresetOsmGeometry(preset.id);
      if (osmRings != null && osmRings.isNotEmpty) {
        final resolved = preset.copyWith(
          polygons: osmRings,
          source: 'osm',
          computedAt: DateTime.now(),
        );
        // บันทึกลง Firestore cache แบบ background (ignore error)
        _saveZoneCache(resolved);
        return resolved;
      }
    } catch (e) {
      debugPrint('[ZoneService] Overpass fetch error for ${preset.id}: $e');
    }
    return preset;
  }

  /// โหลดโซนเริ่มต้นพร้อมขอบเขตจริงครบทุกโซน (ช้า — รอ Overpass ทุกโซน)
  static Future<List<RunningZone>> loadPresetZones() async {
    final zones = await loadPresetZonesFast();
    final results = <RunningZone>[];
    for (final z in zones) {
      results.add(await resolvePresetGeometry(z));
    }
    return results;
  }

  /// ดึงขอบเขตจริงของโซนเริ่มต้นจาก OpenStreetMap (Overpass)
  ///
  /// ค้นหา way/relation ตาม [PresetZoneOsmSpec] แล้วเลือกรูปหลายเหลี่ยมที่ "ครอบจุดศูนย์กลาง"
  /// ของสถานที่ (ถ้ามีหลายอันเลือกอันที่ใหญ่ที่สุดแต่ไม่เกิน 6 ตร.กม.) คืน null ถ้าหาไม่ได้
  static Future<List<List<LatLng>>?> _fetchPresetOsmGeometry(String zoneId) async {
    final spec = PresetZones.osmSpecs[zoneId];
    if (spec == null) return null;
    final c = spec.center;
    final r = spec.radiusM.round();
    final query = '[out:json][timeout:25];'
        '('
        'way${spec.tagFilter}(around:$r,${c.latitude},${c.longitude});'
        'relation${spec.tagFilter}(around:$r,${c.latitude},${c.longitude});'
        ');'
        'out geom;';

    return _runWithOverpassLock(() async {
      for (final endpoint in _endpoints) {
        try {
          final res = await http
              .post(Uri.parse(endpoint), body: {'data': query})
              .timeout(const Duration(seconds: 15));
          if (res.statusCode != 200) continue;
          final data = json.decode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
          final elements = (data['elements'] as List?) ?? const [];
          final picked = _pickAreaContaining(elements, c);
          if (picked != null) return picked;
          return null; // ตอบกลับสำเร็จแต่ไม่มีพื้นที่ที่ตรง → ใช้ค่าสำรอง
        } catch (e) {
          debugPrint('[ZoneService] Overpass $endpoint error: $e');
        }
      }
      return null;
    });
  }

  static List<LatLng> _geomOf(dynamic g) => <LatLng>[
        if (g is List)
          for (final p in g)
            if (p is Map && p['lat'] is num && p['lon'] is num)
              LatLng((p['lat'] as num).toDouble(), (p['lon'] as num).toDouble())
      ];

  static bool _closed(List<LatLng> ring) =>
      ring.length >= 4 &&
      (ring.first.latitude - ring.last.latitude).abs() < 1e-7 &&
      (ring.first.longitude - ring.last.longitude).abs() < 1e-7;

  /// ต่อเส้น outer ของ relation ให้เป็นวงปิด (way หลายเส้นต่อปลายกัน)
  static List<List<LatLng>> _assembleRings(List<List<LatLng>> parts) {
    final rings = <List<LatLng>>[];
    final pool = parts.where((p) => p.length >= 2).map((p) => List<LatLng>.of(p)).toList();
    bool same(LatLng a, LatLng b) =>
        (a.latitude - b.latitude).abs() < 1e-7 && (a.longitude - b.longitude).abs() < 1e-7;
    while (pool.isNotEmpty) {
      var ring = pool.removeAt(0);
      var grew = true;
      while (!_closed(ring) && grew) {
        grew = false;
        for (int i = 0; i < pool.length; i++) {
          final p = pool[i];
          if (same(ring.last, p.first)) {
            ring = [...ring, ...p.skip(1)];
          } else if (same(ring.last, p.last)) {
            ring = [...ring, ...p.reversed.skip(1)];
          } else if (same(ring.first, p.last)) {
            ring = [...p, ...ring.skip(1)];
          } else if (same(ring.first, p.first)) {
            ring = [...p.reversed, ...ring.skip(1)];
          } else {
            continue;
          }
          pool.removeAt(i);
          grew = true;
          break;
        }
      }
      if (_closed(ring)) rings.add(ring);
    }
    return rings;
  }

  /// เลือกรูปหลายเหลี่ยมจากผล Overpass
  static List<List<LatLng>>? _pickAreaContaining(List elements, LatLng center) {
    final candidates = <List<List<LatLng>>>[]; // แต่ละ element อาจมีหลาย ring (multipolygon)
    for (final e in elements) {
      if (e is! Map) continue;
      if (e['type'] == 'way') {
        final ring = _geomOf(e['geometry']);
        if (_closed(ring)) candidates.add([ring]);
      } else if (e['type'] == 'relation' && e['members'] is List) {
        final outers = <List<LatLng>>[
          for (final m in e['members'] as List)
            if (m is Map && m['type'] == 'way' && (m['role'] == 'outer' || m['role'] == ''))
              _geomOf(m['geometry'])
        ];
        final rings = _assembleRings(outers);
        if (rings.isNotEmpty) candidates.add(rings);
      }
    }
    if (candidates.isEmpty) return null;

    double areaOf(List<List<LatLng>> rings) =>
        rings.fold(0.0, (s, r) => s + GeoUtils.calculateShoelaceArea(r));
    const maxArea = 6000000.0; // 6 ตร.กม. กันเลือกพื้นที่ใหญ่เกิน (เช่น ทั้งตำบล)
    const minArea = 2000.0;

    final containing = candidates.where((rings) {
      final a = areaOf(rings);
      return a >= minArea && a <= maxArea && rings.any((r) => pointInPolygon(center, r));
    }).toList();
    if (containing.isNotEmpty) {
      containing.sort((a, b) => areaOf(b).compareTo(areaOf(a)));
      return containing.first;
    }

    // ไม่มีอันไหนครอบจุดศูนย์กลาง → เลือกอันที่ศูนย์กลางใกล้ที่สุด
    List<List<LatLng>>? best;
    double bestD = double.infinity;
    for (final rings in candidates) {
      final a = areaOf(rings);
      if (a < minArea || a > maxArea) continue;
      final pts = rings.first;
      final lat = pts.map((p) => p.latitude).reduce((x, y) => x + y) / pts.length;
      final lng = pts.map((p) => p.longitude).reduce((x, y) => x + y) / pts.length;
      final d = const Distance().as(LengthUnit.Meter, center, LatLng(lat, lng));
      if (d < bestD) {
        bestD = d;
        best = rings;
      }
    }
    return best;
  }

  static void _saveZoneCache(RunningZone zone) {
    try {
      FirebaseFirestore.instance
          .collection('zones')
          .doc(zone.id)
          .set({
            ...zone.toMap(),
            // ประทับเวอร์ชันเฉพาะเมื่อรูปทรงเป็นของจริง (จาก OSM หรือโซนที่กำหนดรูปทรงในโค้ด)
            // ถ้าเป็นค่าสำรองวงกลมประมาณ จะไม่ประทับ เพื่อให้ครั้งหน้าลองดึงจาก OSM ใหม่
            if (zone.source == 'osm' || !PresetZones.osmSpecs.containsKey(zone.id))
              'geomVersion': PresetZones.geometryVersion
            else
              'geomVersion': FieldValue.delete(),
          }, SetOptions(merge: true))
          .catchError((_) {});
    } catch (_) {}
  }

  /// คำนวณคะแนนความปลอดภัยของโซนวิ่ง (S_base, T(t), S)
  /// คำนวณผ่าน [SafetyScoreEngine.calculateSafetyScore] เท่านั้น
  static Future<RunningZone> scoreZone(
    RunningZone zone, {
    List<IncidentReport> incidents = const [],
  }) async {
    try {
      final lat = zone.center.latitude;
      final lng = zone.center.longitude;

      // 1. ดึงข้อมูลคุณภาพอากาศและสภาพอากาศจาก Open-Meteo
      final weatherResFuture = http
          .get(Uri.parse(
            '$_weatherUrl?latitude=$lat&longitude=$lng'
            '&current=temperature_2m,wind_speed_10m,relative_humidity_2m,precipitation'
            '&wind_speed_unit=kmh&timezone=Asia/Bangkok',
          ))
          .timeout(const Duration(seconds: 8));

      final aqiResFuture = http
          .get(Uri.parse(
            '$_aqiUrl?latitude=$lat&longitude=$lng'
            '&current=pm2_5,us_aqi&timezone=Asia/Bangkok',
          ))
          .timeout(const Duration(seconds: 8));

      // 2. วิเคราะห์ลักษณะถนน/ทางเดินภายในโซน
      Future<RoadContext?> roadFuture = Future.value(null);
      if (zone.polygons.isNotEmpty && zone.polygons.first.length >= 3) {
        roadFuture = RoadContextService.fetchForArea(zone.polygons.first);
      }

      final results = await Future.wait([
        weatherResFuture,
        aqiResFuture,
        roadFuture,
      ]);

      final weatherRes = results[0] as http.Response;
      final aqiRes = results[1] as http.Response;
      final roadCtx = results[2] as RoadContext?;

      double temp = 28.0;
      double rain = 0.0;
      double humidity = 60.0;
      double wind = 5.0;
      int aqi = 40;

      if (weatherRes.statusCode == 200) {
        final wData = json.decode(weatherRes.body)['current'] ?? {};
        temp = (wData['temperature_2m'] as num?)?.toDouble() ?? 28.0;
        rain = (wData['precipitation'] as num?)?.toDouble() ?? 0.0;
        humidity = (wData['relative_humidity_2m'] as num?)?.toDouble() ?? 60.0;
        wind = (wData['wind_speed_10m'] as num?)?.toDouble() ?? 5.0;
      }

      if (aqiRes.statusCode == 200) {
        final aData = json.decode(aqiRes.body)['current'] ?? {};
        final usAqi = (aData['us_aqi'] as num?)?.toInt();
        final pm25 = (aData['pm2_5'] as num?)?.toDouble();
        if (usAqi != null && usAqi > 0) {
          aqi = usAqi;
        } else if (pm25 != null) {
          aqi = AirQualityService.calculateAQI(pm25);
        }
      }

      // 3. นับรายงานเหตุการณ์ที่ active ภายในโซน (Point-in-Polygon)
      int activeIncidentsCount = 0;
      if (zone.polygons.isNotEmpty) {
        final outerRing = zone.polygons.first;
        for (final inc in incidents) {
          if (pointInPolygon(inc.position, outerRing)) {
            activeIncidentsCount++;
          }
        }
      }

      // 4. คำนวณคะแนนความปลอดภัยผ่าน SafetyScoreEngine
      final safetyResult = SafetyScoreEngine.calculateSafetyScore(
        aqi: aqi,
        temperatureC: temp,
        precipitationMm: rain,
        humidityPct: humidity,
        windKmh: wind,
        majorRoadShare: roadCtx?.majorRoadShare ?? 0.0,
        protectedShare: roadCtx?.protectedShare ?? 0.85,
        litShare: roadCtx?.litShare ?? 0.80,
        trafficLightCount: roadCtx?.trafficSignals ?? 0,
        activeIncidentCount: activeIncidentsCount,
      );

      final components = safetyResult.toMap();
      components['temp'] = temp.round();
      components['pm25'] = aqi; // AQI reference
      if (roadCtx != null) {
        components['road'] = roadCtx.toMap();
      }

      final scoredZone = zone.copyWith(
        safetyScore: safetyResult.score,
        scoreComponents: components,
        computedAt: DateTime.now(),
      );

      // บันทึก cache
      _saveZoneCache(scoredZone);

      return scoredZone;
    } catch (e) {
      debugPrint('[ZoneService.scoreZone] Error scoring zone ${zone.id}: $e');
      // หากเกิดข้อผิดพลาด ให้คืนค่าเดิมพร้อมคะแนนสำรอง
      return zone;
    }
  }
}
