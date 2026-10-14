import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/activity.dart';
import '../models/running_zone.dart';
import 'zone_service.dart';

/// บริการจัดการและคำนวณคะแนนความนิยมของโซนวิ่ง (Zone Popularity Service)
/// ประมวลผลข้อมูลจากมวลชน (Crowdsourced Runs) ใน 4 สัปดาห์ล่าสุด (S_pop)
class ZonePopularityService {
  /// คำนวณ ISO-8601 Week Key ในรูปแบบ 'yyyy-Www' (เช่น '2026-W42')
  static String getIsoWeekKey(DateTime date) {
    // หาวันพฤหัสบดีของสัปดาห์นี้ตามมาตรฐาน ISO-8601
    final dayOfWeek = date.weekday; // 1 = Monday, 7 = Sunday
    final thursday = date.add(Duration(days: 4 - dayOfWeek));
    final year = thursday.year;

    // หาวันพฤหัสบดีแรกของปี
    final firstDayOfYear = DateTime(year, 1, 1);
    final firstThursday = firstDayOfYear.add(Duration(days: (4 - firstDayOfYear.weekday + 7) % 7));

    final diffDays = thursday.difference(firstThursday).inDays;
    final weekNumber = 1 + (diffDays / 7).round();

    return '$year-W${weekNumber.toString().padLeft(2, '0')}';
  }

  /// คืนรายการ Key ของ 4 สัปดาห์ล่าสุด (สัปดาห์ปัจจุบัน + 3 สัปดาห์ก่อนหน้า)
  static List<String> getRecent4WeekKeys([DateTime? referenceDate]) {
    final now = referenceDate ?? DateTime.now();
    final keys = <String>[];
    for (int i = 0; i < 4; i++) {
      final d = now.subtract(Duration(days: i * 7));
      keys.add(getIsoWeekKey(d));
    }
    return keys;
  }

  /// ตรวจสอบว่าเส้นทางวิ่งผ่านโซนหรือไม่ (เกณฑ์ >= 30% ของจุดอยู่ใน polygon)
  static bool isRouteInZone(
    List<LatLng> routePoints,
    RunningZone zone, {
    double minFraction = 0.30,
  }) {
    if (routePoints.isEmpty || zone.polygons.isEmpty) return false;
    int insideCount = 0;
    for (final p in routePoints) {
      if (ZoneService.pointInZone(p, zone)) {
        insideCount++;
      }
    }
    return (insideCount / routePoints.length) >= minFraction;
  }

  /// คำนวณคะแนนความนิยม S_pop (สมการ 3.1)
  ///
  /// S_pop = 100 × min(1, ln(1 + runs_4w) / ln(1 + P90))
  /// - runs4w: จำนวนครั้งที่วิ่งในโซน 4 สัปดาห์ล่าสุด
  /// - p90: เปอร์เซ็นไทล์ที่ 90 (ถ้ามีน้อยกว่า 5 โซนหรือต่ำกว่า 20 ให้ใช้ 20.0)
  static double calculatePopScore(int runs4w, {double p90 = 20.0}) {
    if (runs4w <= 0) return 0.0;
    final double baseP90 = p90 < 20.0 ? 20.0 : p90;
    final numerator = math.log(1.0 + runs4w);
    final denominator = math.log(1.0 + baseP90);
    if (denominator <= 0) return 0.0;

    final score = 100.0 * math.min(1.0, numerator / denominator);
    return score.clamp(0.0, 100.0);
  }

  /// ดึงจำนวนครั้งการวิ่งใน 4 สัปดาห์ล่าสุด (runs_4w) ของโซน
  static Future<int> getRuns4w(String zoneId) async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('zones')
          .doc(zoneId)
          .collection('stats')
          .doc('weekly')
          .get();

      if (!doc.exists) return 0;
      final data = doc.data() ?? {};
      final recentKeys = getRecent4WeekKeys();
      int total = 0;
      for (final k in recentKeys) {
        final val = data[k];
        if (val is num) {
          total += val.toInt();
        }
      }
      return total;
    } catch (e) {
      debugPrint('[ZonePopularity] Error reading stats for $zoneId: $e');
      return 0;
    }
  }

  /// บันทึกสถิติการวิ่งผ่านโซนเมื่อผู้ใช้บันทึกกิจกรรม (Activity)
  ///
  /// - นับเฉพาะกิจกรรมสาธารณะ (isPublic == true) เท่านั้น
  /// - ไม่มีการจัดเก็บ UID ของผู้ใช้ เพื่อความเป็นส่วนตัวสูงสุด
  static Future<void> recordActivityZones(
    Activity activity, {
    List<RunningZone>? availableZones,
  }) async {
    // 1. ตรวจสอบความเป็นส่วนตัว
    if (!activity.isPublic) {
      debugPrint('[ZonePopularity] Skipping private activity (isPublic == false)');
      return;
    }

    if (activity.routePoints.isEmpty) return;

    // แปลงจุดพิกัดเส้นทาง
    final points = <LatLng>[];
    for (final pt in activity.routePoints) {
      final lat = pt['lat'];
      final lng = pt['lng'];
      if (lat != null && lng != null && lat.isFinite && lng.isFinite) {
        points.add(LatLng(lat, lng));
      }
    }

    if (points.isEmpty) return;

    // 2. ดึงโซนที่ต้องตรวจสอบ
    List<RunningZone> zonesToCheck = availableZones ?? [];
    if (zonesToCheck.isEmpty) {
      try {
        zonesToCheck = await ZoneService.loadPresetZones();
      } catch (_) {}
    }

    final weekKey = getIsoWeekKey(activity.startedAt);

    // 3. ตรวจสอบและอัปเดตเคาน์เตอร์สำหรับทุกโซนที่ผ่านเกณฑ์ >= 30%
    for (final zone in zonesToCheck) {
      if (isRouteInZone(points, zone)) {
        try {
          await FirebaseFirestore.instance
              .collection('zones')
              .doc(zone.id)
              .collection('stats')
              .doc('weekly')
              .set({
            weekKey: FieldValue.increment(1),
            'totalRuns': FieldValue.increment(1),
          }, SetOptions(merge: true));

          debugPrint('[ZonePopularity] ✅ Incremented run stat for zone: ${zone.id} (Week: $weekKey)');
        } catch (e) {
          debugPrint('[ZonePopularity] Error incrementing run stat for ${zone.id}: $e');
        }
      }
    }
  }
}
