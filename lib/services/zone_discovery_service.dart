import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/running_zone.dart';
import '../models/preset_zones.dart';
import '../models/incident_report.dart';
import '../utils/geo_utils.dart';
import 'zone_service.dart';
import 'zone_recommender.dart';

/// บริการค้นหาและคัดกรองโซนวิ่งอัตโนมัติรอบตัวผู้ใช้ (Automatic Zone Discovery)
/// ผ่าน OpenStreetMap Overpass API และแคชผลลัพธ์บน Firestore
class ZoneDiscoveryService {
  static const List<String> _overpassEndpoints = [
    'https://overpass-api.de/api/interpreter',
    'https://overpass.kumi.systems/api/interpreter',
  ];

  /// ค้นหาโซนวิ่งรอบจุด [center] ในรัศมี [radiusKm] (กม.)
  ///
  /// ลำดับการทำงาน:
  /// 1. ตรวจสอบแคชบน Firestore ใน Geohash 5 หลัก (หากมีข้อมูลอายุไม่เกิน 7 วัน จะอ่านจากแคช ไม่เรียก Overpass)
  /// 2. หากไม่มีแคช จะเรียก Overpass API ด้วย query เดียว
  /// 3. คัดกรองพื้นที่ >= 15,000 ตร.ม., ทางเดิน >= 1.0 กม., ตัดพื้นที่ส่วนตัว/ทหาร/สนามกอล์ฟ
  /// 4. ตัดรูปซ้ำซ้อน (overlap >= 60%) และตัดโซนที่ซ้ำกับ preset (overlap >= 30%)
  /// 5. คำนวณคะแนนความปลอดภัย (SafetyScoreEngine) และคะแนนแนะนำ (ZoneRecommender)
  /// 6. บันทึกผลลง Firestore และคืนรายการโซนที่เรียงตามคะแนนแนะนำ
  static Future<List<RunningZone>> discover(
    LatLng center, {
    double radiusKm = 5.0,
    List<RunningZone> presetZones = const [],
    List<IncidentReport> incidents = const [],
  }) async {
    final geohash5 = GeoUtils.encodeGeohash5(center.latitude, center.longitude);
    final neighborHashes = GeoUtils.getGeohashNeighbors(geohash5);

    // ── 1. ตรวจสอบ Firestore Cache ──────────────────────────────────────────
    try {
      final cached = await _fetchFromFirestoreCache(neighborHashes, center, radiusKm);
      if (cached.isNotEmpty) {
        debugPrint(
          '[ZoneDiscovery] Loaded ${cached.length} discovered zones from Firestore cache for geohash: $geohash5 (Overpass skipped)',
        );
        // ให้คะแนนโซนจากแคช (หากยังไม่มีคะแนนหรือคะแนนเก่าเกิน 60 นาที)
        return await _scoreAndRankZones(cached, center, radiusKm, incidents);
      }
    } catch (e) {
      debugPrint('[ZoneDiscovery] Firestore cache check failed, falling back to Overpass: $e');
    }

    // ── 2. เรียก Overpass API (ครั้งเดียว) ───────────────────────────────────
    debugPrint('[ZoneDiscovery] Querying Overpass API around $center (radius: ${radiusKm}km)...');
    List<RunningZone> candidates = [];

    try {
      candidates = await ZoneService.runWithOverpassLock(() async {
        return _fetchFromOverpass(center, radiusKm, presetZones);
      });
    } catch (e) {
      debugPrint('[ZoneDiscovery] Overpass query failed: $e');
      return [];
    }

    if (candidates.isEmpty) {
      return [];
    }

    // ── 3. บันทึก Candidate ลง Firestore แคช ────────────────────────────────
    for (final zone in candidates) {
      _saveZoneToFirestore(zone);
    }

    // ── 4. คำนวณคะแนนและจัดอันดับ ─────────────────────────────────────────
    return _scoreAndRankZones(candidates, center, radiusKm, incidents);
  }

  /// อ่านโซนที่แคชไว้จาก Firestore
  static Future<List<RunningZone>> _fetchFromFirestoreCache(
    List<String> geohashes,
    LatLng center,
    double radiusKm,
  ) async {
    final results = <RunningZone>[];
    final now = DateTime.now();
    const distCalc = Distance();

    // Firestore whereIn รองรับได้สูงสุด 10 ค่า
    final targetHashes = geohashes.take(10).toList();

    final snapshot = await FirebaseFirestore.instance
        .collection('zones')
        .where('source', isEqualTo: 'osm')
        .where('geohash5', whereIn: targetHashes)
        .limit(30)
        .get();

    for (final doc in snapshot.docs) {
      final data = doc.data();
      final zone = RunningZone.fromMap(data, doc.id);

      // ตรวจสอบอายุแคช (ไม่เกิน 7 วัน)
      if (zone.computedAt != null) {
        final age = now.difference(zone.computedAt!);
        if (age.inDays >= 7) continue;
      }

      // ตรวจสอบระยะห่างจากผู้ใช้
      final dKm = distCalc.as(LengthUnit.Meter, center, zone.center) / 1000.0;
      if (dKm <= radiusKm * 1.2 && !zone.hidden) {
        results.add(zone);
      }
    }

    return results;
  }

  /// ดึงข้อมูลจาก Overpass และคัดกรอง Candidate
  static Future<List<RunningZone>> _fetchFromOverpass(
    LatLng center,
    double radiusKm,
    List<RunningZone> presetZones,
  ) async {
    final radiusM = (radiusKm * 1000).round();
    final query = '[out:json][timeout:25];'
        '('
        'way["leisure"~"park|track|stadium|sports_centre|recreation_ground|garden"](around:$radiusM,${center.latitude},${center.longitude});'
        'relation["leisure"~"park|stadium|sports_centre"](around:$radiusM,${center.latitude},${center.longitude});'
        'way["landuse"~"recreation_ground|village_green"](around:$radiusM,${center.latitude},${center.longitude});'
        'way["amenity"="university"](around:$radiusM,${center.latitude},${center.longitude});'
        'way["natural"="water"]["name"](around:$radiusM,${center.latitude},${center.longitude});'
        'way["landuse"="reservoir"](around:$radiusM,${center.latitude},${center.longitude});'
        ');'
        'out geom tags;';

    http.Response? response;
    for (final ep in _overpassEndpoints) {
      try {
        final res = await http
            .post(
              Uri.parse(ep),
              headers: {'Content-Type': 'application/x-www-form-urlencoded'},
              body: {'data': query},
            )
            .timeout(const Duration(seconds: 25));
        if (res.statusCode == 200) {
          response = res;
          break;
        }
      } catch (_) {}
    }

    if (response == null || response.statusCode != 200) {
      return [];
    }

    final data = json.decode(utf8.decode(response.bodyBytes));
    final elements = data['elements'] as List<dynamic>? ?? [];
    final List<RunningZone> candidates = [];
    const distCalc = Distance();

    for (final el in elements) {
      if (el is! Map<String, dynamic>) continue;
      final tags = el['tags'] as Map<String, dynamic>? ?? {};

      // ── กรองสิทธิ์การเข้าถึงและความปลอดภัย ──
      final access = tags['access']?.toString().toLowerCase();
      if (access == 'private' || access == 'no') continue;

      final leisure = tags['leisure']?.toString().toLowerCase();
      if (leisure == 'golf_course') continue;

      final landuse = tags['landuse']?.toString().toLowerCase();
      if (landuse == 'military') continue;

      // ── ดึงพิกัดรูปทรง (Geometry) ──
      List<LatLng> ring = [];
      final geom = el['geometry'] as List<dynamic>?;
      if (geom != null) {
        for (final pt in geom) {
          if (pt is Map) {
            final lat = (pt['lat'] as num?)?.toDouble() ?? 0.0;
            final lon = (pt['lon'] as num?)?.toDouble() ?? 0.0;
            if (lat.isFinite && lon.isFinite && (lat != 0.0 || lon != 0.0)) {
              ring.add(LatLng(lat, lon));
            }
          }
        }
      }

      if (ring.length < 3) continue;

      final isWater = tags['natural'] == 'water' || landuse == 'reservoir';
      if (isWater) {
        // แหล่งน้ำ: สร้างแถบรอบขอบ (Buffer 30 เมตร)
        ring = bufferPolyline(ring, 30.0);
        if (ring.length < 3) continue;
      }

      // ── คำนวณพื้นที่ (Shoelace Area >= 15,000 ตร.ม.) ──
      final area = GeoUtils.calculateShoelaceArea(ring);
      if (area < 15000.0) continue;

      // ── คำนวณความยาวทางวิ่ง (Walkable Length >= 1.0 กม.) ──
      double perimeterM = 0.0;
      for (int i = 0; i < ring.length; i++) {
        perimeterM += distCalc.as(LengthUnit.Meter, ring[i], ring[(i + 1) % ring.length]);
      }
      final walkableKm = math.max(1.0, perimeterM / 1000.0);

      // ── จุดศูนย์กลาง (Center) ──
      double sumLat = 0.0, sumLng = 0.0;
      for (final p in ring) {
        sumLat += p.latitude;
        sumLng += p.longitude;
      }
      final centerPoint = LatLng(sumLat / ring.length, sumLng / ring.length);

      // ── การตั้งชื่อ ──
      String nameTh = tags['name:th']?.toString() ?? tags['name']?.toString() ?? '';
      String nameEn = tags['name:en']?.toString() ?? '';
      if (nameTh.isEmpty && nameEn.isNotEmpty) nameTh = nameEn;
      if (nameEn.isEmpty && nameTh.isNotEmpty) nameEn = nameTh;

      String category = 'other';
      if (leisure == 'park' || leisure == 'garden') {
        category = 'park';
        if (nameTh.isEmpty) { nameTh = 'สวนสาธารณะ (ไม่มีชื่อ)'; nameEn = 'Public Park'; }
      } else if (leisure == 'track') {
        category = 'track';
        if (nameTh.isEmpty) { nameTh = 'ลู่วิ่งออกกำลังกาย'; nameEn = 'Running Track'; }
      } else if (leisure == 'stadium' || leisure == 'sports_centre') {
        category = 'stadium';
        if (nameTh.isEmpty) { nameTh = 'สนามกีฬา'; nameEn = 'Sports Complex'; }
      } else if (tags['amenity'] == 'university') {
        category = 'campus';
        if (nameTh.isEmpty) { nameTh = 'มหาวิทยาลัย'; nameEn = 'University Campus'; }
      } else if (isWater) {
        category = 'reservoir';
        if (nameTh.isEmpty) { nameTh = 'อ่างเก็บน้ำ/หนองน้ำ'; nameEn = 'Water Reservoir'; }
      } else {
        if (nameTh.isEmpty) { nameTh = 'พื้นที่ออกกำลังกาย'; nameEn = 'Recreation Zone'; }
      }

      // ── ตัดซ้ำกับ Preset Zones (ถ้าซ้อนทับ >= 30% ให้ใช้ Preset) ──
      bool overlapsPreset = false;
      for (final pz in presetZones) {
        for (final pRing in pz.polygons) {
          if (GeoUtils.calculatePolygonOverlap(ring, pRing) >= 0.30) {
            overlapsPreset = true;
            break;
          }
        }
        if (overlapsPreset) break;
      }
      if (overlapsPreset) continue;

      // ── ตัดซ้ำระหว่าง Candidates (ถ้าซ้อนทับ >= 60% เก็บอันใหญ่กว่า) ──
      bool skipCandidate = false;
      for (int i = 0; i < candidates.length; i++) {
        final existing = candidates[i];
        if (existing.polygons.isEmpty) continue;
        final overlap = GeoUtils.calculatePolygonOverlap(ring, existing.polygons.first);
        if (overlap >= 0.60) {
          final existingArea = GeoUtils.calculateShoelaceArea(existing.polygons.first);
          if (area > existingArea) {
            candidates.removeAt(i);
            break;
          } else {
            skipCandidate = true;
            break;
          }
        }
      }
      if (skipCandidate) continue;

      final osmId = '${el['type']}_${el['id']}';
      final zoneHash = GeoUtils.encodeGeohash5(centerPoint.latitude, centerPoint.longitude);

      candidates.add(RunningZone(
        id: 'osm_$osmId',
        name: nameTh,
        nameEn: nameEn,
        description: '$nameTh · ทางวิ่ง ${walkableKm.toStringAsFixed(1)} กม.',
        descriptionEn: '$nameEn · Track ${walkableKm.toStringAsFixed(1)} km',
        category: category,
        polygons: [ring],
        center: centerPoint,
        walkableLengthKm: walkableKm,
        source: 'osm',
        osmRef: '${el['type']}/${el['id']}',
        geohash5: zoneHash,
        computedAt: DateTime.now(),
      ));
    }

    return candidates;
  }

  /// คำนวณคะแนนความปลอดภัย (SafetyScoreEngine) และคะแนนแนะนำ (ZoneRecommender)
  static Future<List<RunningZone>> _scoreAndRankZones(
    List<RunningZone> zones,
    LatLng userCenter,
    double radiusKm,
    List<IncidentReport> incidents,
  ) async {
    const distCalc = Distance();
    final scoredZones = <RunningZone>[];

    for (final zone in zones) {
      RunningZone scored = zone;
      // คำนวณคะแนนความปลอดภัยถ้ายังไม่มี
      if (scored.safetyScore == null) {
        try {
          scored = await ZoneService.scoreZone(scored, incidents: incidents);
        } catch (_) {}
      }

      final distKm = distCalc.as(LengthUnit.Meter, userCenter, scored.center) / 1000.0;
      final safety = (scored.safetyScore ?? 70).toDouble();

      // ดึงค่า PM2.5 จาก scoreComponents ถ้ามี
      final aqiData = scored.scoreComponents?['airQuality'] as Map<String, dynamic>?;
      final pm25 = (aqiData?['pm2_5'] as num?)?.toDouble();

      // คำนวณคะแนนแนะนำ R
      final rScore = ZoneRecommender.calculateRecommendationScore(
        safetyScore: safety,
        distanceKm: distKm,
        radiusKm: radiusKm,
        walkableLengthKm: scored.walkableLengthKm,
      );

      // สร้างเหตุผลแนะนำ 2–3 ข้อ
      final reasons = ZoneRecommender.generateReasons(
        scored,
        userDistKm: distKm,
        pm25: pm25,
      );

      scoredZones.add(scored.copyWith(
        recommendationScore: rScore,
        recommendationReasons: reasons,
      ));
    }

    // เรียงตามคะแนนแนะนำ R มากไปน้อย
    scoredZones.sort((a, b) {
      final rA = a.recommendationScore ?? 0.0;
      final rB = b.recommendationScore ?? 0.0;
      return rB.compareTo(rA);
    });

    return scoredZones;
  }

  /// บันทึกโซนลงใน Firestore cache
  static void _saveZoneToFirestore(RunningZone zone) {
    try {
      FirebaseFirestore.instance
          .collection('zones')
          .doc(zone.id)
          .set(zone.toMap(), SetOptions(merge: true))
          .catchError((_) {});
    } catch (_) {}
  }
}
