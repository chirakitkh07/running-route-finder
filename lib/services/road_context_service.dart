import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

/// ลักษณะกายภาพของเส้นทางจริงจากโอเพนสตรีตแมป (OpenStreetMap ผ่าน Overpass API)
///
/// ใช้ทำให้คะแนนความปลอดภัยต่างกันตาม "ถนนที่เส้นทางวิ่งผ่านจริง"
/// แทนการใช้ค่าประมาณจากมุมเลี้ยว (เดิมทุกเส้นทางได้คะแนนใกล้เคียงกัน)
class RoadContext {
  /// สัดส่วนระยะทางที่อยู่บนถนนสายหลัก (trunk/primary/secondary/tertiary) 0–1
  final double majorRoadShare;

  /// สัดส่วนที่มีทางเท้า/ทางจักรยาน/ทางเดินแยกจากรถ 0–1
  final double protectedShare;

  /// สัดส่วนที่มีไฟส่องสว่าง (lit=yes) 0–1 — null ถ้าไม่มีข้อมูลเลย
  final double? litShare;

  /// จำนวนแยกสัญญาณไฟจราจรบนเส้นทาง
  final int trafficSignals;

  /// จำนวนทางข้ามบนเส้นทาง
  final int crossings;

  /// ข้อมูลมาจาก OSM จริง (false = ใช้ค่าประมาณสำรอง)
  final bool fromOsm;

  const RoadContext({
    required this.majorRoadShare,
    required this.protectedShare,
    required this.litShare,
    required this.trafficSignals,
    required this.crossings,
    required this.fromOsm,
  });

  Map<String, dynamic> toMap() => {
        'majorRoadShare': majorRoadShare,
        'protectedShare': protectedShare,
        'litShare': litShare,
        'trafficSignals': trafficSignals,
        'crossings': crossings,
        'fromOsm': fromOsm,
      };
}

class RoadContextService {
  static const _endpoints = [
    'https://overpass-api.de/api/interpreter',
    'https://overpass.kumi.systems/api/interpreter',
  ];

  static const _major = {
    'motorway', 'trunk', 'primary', 'secondary', 'tertiary',
    'motorway_link', 'trunk_link', 'primary_link', 'secondary_link', 'tertiary_link',
  };
  static const _protectedHighway = {
    'footway', 'pedestrian', 'path', 'cycleway', 'track', 'steps', 'living_street',
  };

  /// เลือกจุดตัวอย่างทุก ~[stepM] เมตรตามเส้นทาง
  static List<LatLng> _sample(List<LatLng> path, {double stepM = 40}) {
    if (path.length < 2) return List.of(path);
    final out = <LatLng>[path.first];
    double acc = 0;
    for (int i = 1; i < path.length; i++) {
      final d = Geolocator.distanceBetween(
          path[i - 1].latitude, path[i - 1].longitude, path[i].latitude, path[i].longitude);
      acc += d;
      if (acc >= stepM) {
        out.add(path[i]);
        acc = 0;
      }
    }
    if (out.last != path.last) out.add(path.last);
    return out;
  }

  /// ระยะจากจุด p ถึงส่วนของเส้นตรง a–b (เมตร, ประมาณแบบระนาบ — พอสำหรับระยะไม่กี่สิบเมตร)
  static double _distToSegment(LatLng p, LatLng a, LatLng b) {
    const mPerDegLat = 111320.0;
    final mPerDegLng = 111320.0 * math.cos(p.latitude * math.pi / 180);
    final ax = (a.longitude - p.longitude) * mPerDegLng, ay = (a.latitude - p.latitude) * mPerDegLat;
    final bx = (b.longitude - p.longitude) * mPerDegLng, by = (b.latitude - p.latitude) * mPerDegLat;
    final dx = bx - ax, dy = by - ay;
    final len2 = dx * dx + dy * dy;
    double t = len2 == 0 ? 0 : -(ax * dx + ay * dy) / len2;
    t = t.clamp(0.0, 1.0);
    final cx = ax + t * dx, cy = ay + t * dy;
    return math.sqrt(cx * cx + cy * cy);
  }

  /// ดึงลักษณะถนนตามเส้นทาง คืน null ถ้าดึงไม่ได้ (ผู้เรียกใช้ค่าสำรอง)
  static Future<RoadContext?> fetch(List<LatLng> path) async {
    final pts = _sample(path);
    if (pts.length < 2) return null;
    // จำกัดจำนวนจุดใน query (Overpass รับ polyline ใน around:)
    final step = (pts.length / 60).ceil().clamp(1, pts.length);
    final qPts = <LatLng>[for (int i = 0; i < pts.length; i += step) pts[i]];
    if (qPts.last != pts.last) qPts.add(pts.last);
    final poly = qPts
        .map((p) => '${p.latitude.toStringAsFixed(5)},${p.longitude.toStringAsFixed(5)}')
        .join(',');
    final query = '[out:json][timeout:15];'
        '(way(around:25,$poly)[highway];'
        'node(around:15,$poly)[highway~"traffic_signals|crossing"];);'
        'out geom tags;';

    for (final url in _endpoints) {
      try {
        final res = await http
            .post(Uri.parse(url), body: {'data': query})
            .timeout(const Duration(seconds: 12));
        if (res.statusCode != 200) continue;
        final data = json.decode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
        return _analyse(pts, (data['elements'] as List?) ?? const []);
      } catch (e) {
        debugPrint('[RoadContext] $url error: $e');
      }
    }
    return null;
  }

  static RoadContext? _analyse(List<LatLng> pts, List elements) {
    final ways = <({Map tags, List<LatLng> geom})>[];
    int signals = 0, crossings = 0;
    for (final e in elements) {
      if (e is! Map) continue;
      final tags = (e['tags'] as Map?) ?? const {};
      if (e['type'] == 'node') {
        final hw = tags['highway'];
        if (hw == 'traffic_signals') signals++;
        if (hw == 'crossing') crossings++;
      } else if (e['type'] == 'way' && e['geometry'] is List) {
        final geom = <LatLng>[
          for (final g in e['geometry'] as List)
            if (g is Map && g['lat'] is num && g['lon'] is num)
              LatLng((g['lat'] as num).toDouble(), (g['lon'] as num).toDouble())
        ];
        if (geom.length >= 2) ways.add((tags: tags, geom: geom));
      }
    }
    if (ways.isEmpty) return null;

    int matched = 0, major = 0, protectedCount = 0, litKnown = 0, litYes = 0;
    for (final p in pts) {
      // หาถนนที่ใกล้จุดนี้ที่สุด
      double best = double.infinity;
      Map? bestTags;
      for (final w in ways) {
        for (int i = 0; i < w.geom.length - 1; i++) {
          final d = _distToSegment(p, w.geom[i], w.geom[i + 1]);
          if (d < best) {
            best = d;
            bestTags = w.tags;
          }
        }
      }
      if (bestTags == null || best > 30) continue;
      matched++;
      final hw = bestTags['highway']?.toString() ?? '';
      if (_major.contains(hw)) major++;
      final sidewalk = bestTags['sidewalk']?.toString() ?? '';
      final cycleway = bestTags['cycleway']?.toString() ?? '';
      final hasSidewalk = sidewalk.isNotEmpty && sidewalk != 'no' && sidewalk != 'none';
      final hasCycle = cycleway == 'lane' || cycleway == 'track' || bestTags['cycleway:left'] != null || bestTags['cycleway:right'] != null;
      if (_protectedHighway.contains(hw) || hasSidewalk || hasCycle) protectedCount++;
      final lit = bestTags['lit']?.toString();
      if (lit != null) {
        litKnown++;
        if (lit == 'yes' || lit == '24/7' || lit == 'automatic') litYes++;
      }
    }
    if (matched == 0) return null;

    return RoadContext(
      majorRoadShare: major / matched,
      protectedShare: protectedCount / matched,
      // ถ้ามีข้อมูลไฟน้อยกว่า 20% ของเส้นทาง ถือว่าไม่ทราบ
      litShare: litKnown >= matched * 0.2 ? litYes / litKnown : null,
      trafficSignals: signals,
      crossings: crossings,
      fromOsm: true,
    );
  }

  /// วิเคราะห์ลักษณะถนนและทางเดินภายในพื้นที่ polygon (สำหรับโซนวิ่ง)
  /// คำนวณสัดส่วนตาม "ความยาว" ของแต่ละทาง (เมตร) แทนจำนวนจุด
  static Future<RoadContext?> fetchForArea(List<LatLng> ring) async {
    if (ring.length < 3) return null;

    // จำกัดจำนวนจุดใน poly query ไม่ให้ยาวเกินไป (~25-30 จุด)
    final step = (ring.length / 25).ceil().clamp(1, ring.length);
    final qPts = <LatLng>[for (int i = 0; i < ring.length; i += step) ring[i]];
    if (qPts.length >= 3 && (qPts.first.latitude != qPts.last.latitude || qPts.first.longitude != qPts.last.longitude)) {
      qPts.add(qPts.first);
    }
    final polyStr = qPts
        .map((p) => '${p.latitude.toStringAsFixed(5)} ${p.longitude.toStringAsFixed(5)}')
        .join(' ');

    final query = '[out:json][timeout:25];'
        '(way(poly:"$polyStr")[highway];'
        'node(poly:"$polyStr")[highway~"traffic_signals|crossing"];);'
        'out geom tags;';

    for (final url in _endpoints) {
      try {
        final res = await http
            .post(Uri.parse(url), body: {'data': query})
            .timeout(const Duration(seconds: 15));
        if (res.statusCode != 200) continue;
        final data = json.decode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
        final elements = (data['elements'] as List?) ?? const [];
        final analyzed = _analyseArea(elements);
        if (analyzed != null) return analyzed;
      } catch (e) {
        debugPrint('[RoadContext.fetchForArea] $url error: $e');
      }
    }
    return null;
  }

  static RoadContext? _analyseArea(List elements) {
    double totalLenM = 0;
    double majorLenM = 0;
    double protectedLenM = 0;
    double litKnownLenM = 0;
    double litYesLenM = 0;
    int signals = 0;
    int crossings = 0;

    for (final e in elements) {
      if (e is! Map) continue;
      final tags = (e['tags'] as Map?) ?? const {};

      if (e['type'] == 'node') {
        final hw = tags['highway'];
        if (hw == 'traffic_signals') signals++;
        if (hw == 'crossing') crossings++;
      } else if (e['type'] == 'way' && e['geometry'] is List) {
        final geom = <LatLng>[
          for (final g in e['geometry'] as List)
            if (g is Map && g['lat'] is num && g['lon'] is num)
              LatLng((g['lat'] as num).toDouble(), (g['lon'] as num).toDouble())
        ];
        if (geom.length < 2) continue;

        double wayLen = 0;
        for (int i = 0; i < geom.length - 1; i++) {
          wayLen += Geolocator.distanceBetween(
            geom[i].latitude,
            geom[i].longitude,
            geom[i + 1].latitude,
            geom[i + 1].longitude,
          );
        }
        if (wayLen <= 0) continue;

        totalLenM += wayLen;
        final hw = tags['highway']?.toString() ?? '';
        if (_major.contains(hw)) {
          majorLenM += wayLen;
        }

        final sidewalk = tags['sidewalk']?.toString() ?? '';
        final cycleway = tags['cycleway']?.toString() ?? '';
        final hasSidewalk = sidewalk.isNotEmpty && sidewalk != 'no' && sidewalk != 'none';
        final hasCycle = cycleway == 'lane' ||
            cycleway == 'track' ||
            tags['cycleway:left'] != null ||
            tags['cycleway:right'] != null;

        if (_protectedHighway.contains(hw) || hasSidewalk || hasCycle) {
          protectedLenM += wayLen;
        }

        final lit = tags['lit']?.toString();
        if (lit != null) {
          litKnownLenM += wayLen;
          if (lit == 'yes' || lit == '24/7' || lit == 'automatic') {
            litYesLenM += wayLen;
          }
        }
      }
    }

    if (totalLenM <= 0) return null;

    return RoadContext(
      majorRoadShare: (majorLenM / totalLenM).clamp(0.0, 1.0),
      protectedShare: (protectedLenM / totalLenM).clamp(0.0, 1.0),
      litShare: litKnownLenM >= totalLenM * 0.2
          ? (litYesLenM / litKnownLenM).clamp(0.0, 1.0)
          : null,
      trafficSignals: signals,
      crossings: crossings,
      fromOsm: true,
    );
  }
}

