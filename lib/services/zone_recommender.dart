import 'dart:math' as math;
import '../l10n/tr.dart';
import '../models/running_zone.dart';

/// บริการคำนวณคะแนนแนะนำโซนวิ่ง (Zone Recommender Service)
///
/// คำนวณคะแนนแนะนำ R ตามสูตรในแผนงานเฟส 2:
/// R = 0.55 · S_safety + 0.20 · S_dist + 0.15 · S_len + 0.10 · S_pop
/// โดยแยกคะแนนแนะนำออกจากคะแนนความปลอดภัยของโซน
class ZoneRecommender {
  /// ค่าน้ำหนักตามสูตรแนะนำ (ผลรวมเท่ากับ 1.0)
  /// - wSafety: ความสำคัญของความปลอดภัยและสภาพแวดล้อม (55%)
  /// - wDist: ความสะดวกในการเดินทาง ใกล้ผู้ใช้ (20%)
  /// - wLen: ความยาวของทางวิ่งในโซน ยิ่งยาววิ่งได้หลากหลาย (15%)
  /// - wPop: ความนิยมจากชุมชนผู้ใช้งาน (10%)
  static const double wSafety = 0.55;
  static const double wDist = 0.20;
  static const double wLen = 0.15;
  static const double wPop = 0.10;

  /// คำนวณคะแนนแนะนำ (R) ช่วง 0.0 – 100.0
  ///
  /// - [safetyScore]: คะแนนความปลอดภัยจาก SafetyScoreEngine (0-100)
  /// - [distanceKm]: ระยะห่างจากผู้ใช้ถึงขอบ/ศูนย์กลางโซน (กม.)
  /// - [radiusKm]: รัศมีค้นหาสูงสุด (กม.) เช่น 5.0 กม.
  /// - [walkableLengthKm]: ความยาวทางวิ่งรวมภายในโซน (กม.)
  /// - [popScore]: คะแนนความนิยม (เฟส 2 ใช้ค่าคงที่ 50.0)
  static double calculateRecommendationScore({
    required double safetyScore,
    required double distanceKm,
    required double radiusKm,
    required double walkableLengthKm,
    double popScore = 50.0,
    bool isPinned = false,
  }) {
    // 1. S_safety: 0–100
    final sSafety = safetyScore.clamp(0.0, 100.0);

    // 2. S_dist: 100 × max(0, 1 − d/radius) ถ้าไกลกว่ารัศมีได้ 0
    final sDist = radiusKm > 0
        ? 100.0 * math.max(0.0, 1.0 - (distanceKm / radiusKm))
        : 0.0;

    // 3. S_len: min(100, walkableLengthKm / 3 × 100)
    final sLen = math.min(100.0, (walkableLengthKm / 3.0) * 100.0);

    // 4. S_pop: ความนิยม
    final sPop = popScore.clamp(0.0, 100.0);

    // รวมคะแนนตามน้ำหนัก
    double r = (wSafety * sSafety) +
        (wDist * sDist) +
        (wLen * sLen) +
        (wPop * sPop);

    // โซนที่ผู้ดูแลปักหมุดไว้ (pinned) ได้รับคะแนนพิเศษ +10 (แผนงานเฟส 3.2)
    if (isPinned) {
      r += 10.0;
    }

    return r.clamp(0.0, 100.0);
  }

  /// เหตุผลด้านระยะทางจากผู้ใช้ (ขึ้นต้นด้วย 📍) — null ถ้าไกลเกิน 3.5 กม.
  static String? distanceReason(double userDistKm) {
    final km = userDistKm.toStringAsFixed(1);
    if (userDistKm <= 1.5) return tr('📍 ใกล้คุณมาก ($km กม.)', '📍 Very close to you ($km km)');
    if (userDistKm <= 3.5) return tr('📍 เดินทางสะดวก ($km กม.)', '📍 Convenient distance ($km km)');
    return null;
  }

  /// เหตุผลสำหรับแสดงผล: ตัดเหตุผลระยะทางที่คำนวณไว้ก่อน (อาจมาจากแคช/ตำแหน่งอื่น)
  /// แล้วคำนวณใหม่จากระยะทางปัจจุบัน [userDistKm] (null = ไม่รู้ตำแหน่ง → ไม่แสดง)
  static List<String> displayReasons(List<String> stored, double? userDistKm) {
    final rest = stored.where((r) => !r.startsWith('📍')).toList();
    final near = userDistKm == null ? null : distanceReason(userDistKm);
    return [?near, ...rest].take(3).toList();
  }

  /// สร้างเหตุผลแนะนำ 2–3 ข้อต่อโซน (Recommendation Reasons)
  ///
  /// คัดเลือกจากจุดเด่นหรือปัจจัยสำคัญ เช่น ความใกล้, ไฟส่องสว่าง, สภาพอากาศ, ทางเท้า
  static List<String> generateReasons(
    RunningZone zone, {
    double? userDistKm,
    double? pm25,
  }) {
    final reasons = <String>[];

    // โซนที่ปักหมุด
    if (zone.pinned) {
      reasons.add(tr('📌 โซนปักหมุดแนะนำโดยผู้ดูแล', '📌 Pinned by admin'));
    }
    final comps = zone.scoreComponents;
    final road = comps?['roadCharacteristics'] as Map<String, dynamic>?;

    // 1. ตรวจสอบระยะทาง
    final near = userDistKm == null ? null : distanceReason(userDistKm);
    if (near != null) reasons.add(near);

    // 2. ลักษณะถนน/ทางวิ่ง
    if (road != null) {
      final majorShare = (road['majorRoadShare'] as num?)?.toDouble() ?? 0.0;
      final litShare = (road['litShare'] as num?)?.toDouble() ?? 0.0;
      final sidewalkShare = (road['hasSidewalkShare'] as num?)?.toDouble() ?? 0.0;

      if (majorShare == 0.0) {
        reasons.add(tr('🛡️ ไม่มีถนนสายหลัก ปลอดภัยจากรถยนต์', '🛡️ No major roads, safe from traffic'));
      }
      if (litShare >= 0.70) {
        reasons.add(tr(
          '💡 ไฟส่องสว่าง ${(litShare * 100).round()}% ทัศนวิสัยดี',
          '💡 ${(litShare * 100).round()}% well-lit, good visibility',
        ));
      }
      if (sidewalkShare >= 0.65) {
        reasons.add(tr(
          '🚶 มีทางเท้า ${(sidewalkShare * 100).round()}% เหมาะกับการวิ่ง',
          '🚶 ${(sidewalkShare * 100).round()}% sidewalk, ideal for running',
        ));
      }
    }

    // 3. ความยาวเส้นทาง
    if (zone.walkableLengthKm >= 3.0) {
      reasons.add(tr(
        '🏃 ทางวิ่งยาว ${zone.walkableLengthKm.toStringAsFixed(1)} กม. เลือกระยะได้หลากหลาย',
        '🏃 Long track ${zone.walkableLengthKm.toStringAsFixed(1)} km, great distance choices',
      ));
    }

    // 4. คุณภาพอากาศ
    if (pm25 != null) {
      if (pm25 <= 25.0) {
        reasons.add(tr(
          '🌿 อากาศสะอาด PM2.5 ต่ำ (${pm25.toStringAsFixed(0)} µg/m³)',
          '🌿 Clean air, low PM2.5 (${pm25.toStringAsFixed(0)} µg/m³)',
        ));
      } else if (pm25 > 50.0) {
        reasons.add(tr(
          '⚠️ PM2.5 สูง (${pm25.toStringAsFixed(0)} µg/m³) แนะนำสวมหน้ากาก',
          '⚠️ Elevated PM2.5 (${pm25.toStringAsFixed(0)} µg/m³)',
        ));
      }
    }

    // 5. คะแนนความปลอดภัยโดยรวม
    if (reasons.length < 2 && zone.safetyScore != null && zone.safetyScore! >= 75) {
      reasons.add(tr(
        '⭐ คะแนนความปลอดภัยระดับสูง (${zone.safetyScore}/100)',
        '⭐ High safety score (${zone.safetyScore}/100)',
      ));
    }

    // ตัดให้เหลือ 2–3 ข้อตามเกณฑ์
    if (reasons.length > 3) {
      return reasons.take(3).toList();
    }
    if (reasons.isEmpty) {
      reasons.add(tr('🏞️ พื้นที่เหมาะสำหรับการออกกำลังกาย', '🏞️ Suitable exercise area'));
    }
    return reasons;
  }
}
