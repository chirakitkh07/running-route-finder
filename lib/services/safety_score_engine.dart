import 'package:flutter/material.dart';

/// ระดับความปลอดภัยตามตารางที่ 3.16 ในเล่มปริญญานิพนธ์
enum SafetyLevel { safe, caution, highRisk }

/// ผลลัพธ์การคำนวณคะแนนความปลอดภัย (UC-14)
class SafetyScoreResult {
  /// คะแนนย่อยแต่ละปัจจัย (0–100)
  final double sAir;
  final double sWx;
  final double sTrf;
  final double sInc;

  /// คะแนนพื้นฐาน S_base ตามสมการที่ (3.1)
  final double baseScore;

  /// ค่าปรับตามช่วงเวลา T(t) (0.7–1.0)
  final double timeFactor;

  /// คะแนนสุดท้าย S = S_base × T(t) ตามสมการที่ (3.2) (ปัดเป็นจำนวนเต็ม 0–100)
  final int score;

  final SafetyLevel level;

  const SafetyScoreResult({
    required this.sAir,
    required this.sWx,
    required this.sTrf,
    required this.sInc,
    required this.baseScore,
    required this.timeFactor,
    required this.score,
    required this.level,
  });

  Map<String, dynamic> toMap() => {
        'sAir': sAir.round(),
        'sWx': sWx.round(),
        'sTrf': sTrf.round(),
        'sInc': sInc.round(),
        'baseScore': baseScore.round(),
        'timeFactor': timeFactor,
        'score': score,
        'level': level.name,
      };
}

/// SafetyScoreEngine — ส่วนประมวลผลคะแนนความปลอดภัย (Safety Score Engine)
///
/// ใช้วิธีผลรวมถ่วงน้ำหนักอย่างง่าย (SAW) ตามหัวข้อ 2.1.9 และ 3.3.5
///
///   S_base = w1·S_air + w2·S_wx + w3·S_trf + w4·S_inc      (3.1)
///   S      = S_base × T(t)                                  (3.2)
///
/// w1 = 0.40, w2 = 0.20, w3 = 0.25, w4 = 0.15 (รวม = 1)
/// T(t) = 1.0 ช่วงกลางวัน, 0.7 ช่วงกลางคืน (21:00–05:59)
class SafetyScoreEngine {
  // ─── ค่าน้ำหนัก (สมการที่ 3.1) ─────────────────────────────
  static const double wAir = 0.40;
  static const double wWeather = 0.20;
  static const double wTraffic = 0.25;
  static const double wIncident = 0.15;

  // ─── ค่าปรับตามช่วงเวลา (สมการที่ 3.2) ─────────────────────
  static const double dayFactor = 1.0;
  static const double nightFactor = 0.7;
  static const int nightStartHour = 21; // 21:00
  static const int nightEndHour = 6; // ถึง 05:59

  // ─── เกณฑ์การจัดระดับ (ตารางที่ 3.16) ─────────────────────
  static const int safeThreshold = 70; // 70–100 = ปลอดภัย (เขียว)
  static const int cautionThreshold = 40; // 40–69 = ควรระวัง (เหลือง), 0–39 = เสี่ยงสูง (แดง)

  /// คะแนนที่ลดลงต่อรายงานเหตุการณ์ที่ยังไม่หมดอายุ 1 รายการบนเส้นทาง
  static const double incidentPenalty = 20.0;

  static bool isNight([DateTime? now]) {
    final hour = (now ?? DateTime.now()).hour;
    return hour >= nightStartHour || hour < nightEndHour;
  }

  /// T(t) — ค่าปรับตามช่วงเวลา
  /// กลางคืน: 0.7 ถ้าไม่ทราบไฟส่องสว่าง หรือ 0.7 + 0.3 × สัดส่วนเส้นทางที่มีไฟ (สูงสุด 1.0)
  /// เส้นทางที่มีไฟสว่างตลอดจึงถูกปรับลดน้อยกว่าเส้นทางมืด (ยังอยู่ในช่วง 0.7–1.0 ตามสมการ 3.2)
  static double timeFactor([DateTime? now, double? litShare]) {
    if (!isNight(now)) return dayFactor;
    if (litShare == null) return nightFactor;
    return (nightFactor + (dayFactor - nightFactor) * litShare.clamp(0.0, 1.0)).toDouble();
  }

  /// S_air — แปลงดัชนีคุณภาพอากาศ (US AQI) เป็นคะแนน 0–100
  /// AQI 0–50 = 100, 100 = 75, 150 = 50, 200 = 25, ≥300 = 0 (เชิงเส้นระหว่างจุด)
  static double airScore(int aqi) {
    const points = <List<double>>[
      [0, 100],
      [50, 100],
      [100, 75],
      [150, 50],
      [200, 25],
      [300, 0],
    ];
    final a = aqi.toDouble();
    if (a <= 0) return 100;
    for (int i = 1; i < points.length; i++) {
      if (a <= points[i][0]) {
        final x0 = points[i - 1][0], y0 = points[i - 1][1];
        final x1 = points[i][0], y1 = points[i][1];
        return y0 + (y1 - y0) * (a - x0) / (x1 - x0);
      }
    }
    return 0;
  }

  /// S_wx — คะแนนสภาพอากาศจากอุณหภูมิ ปริมาณฝน และความชื้น (และลมแรง)
  static double weatherScore({
    required double temperatureC,
    double precipitationMm = 0,
    double humidityPct = 0,
    double windKmh = 0,
  }) {
    double s = 100;
    // อุณหภูมิ
    if (temperatureC > 38) {
      s -= 50;
    } else if (temperatureC > 33) {
      s -= 25;
    } else if (temperatureC < 10) {
      s -= 15;
    }
    // ปริมาณฝน (มม./ชม.)
    if (precipitationMm > 5) {
      s -= 30;
    } else if (precipitationMm > 0.5) {
      s -= 15;
    }
    // ความชื้นสูงร่วมกับอากาศร้อน ทำให้ระบายความร้อนได้ยาก
    if (humidityPct >= 85 && temperatureC > 30) {
      s -= 10;
    }
    // ลมแรง
    if (windKmh > 40) s -= 10;
    return s.clamp(0, 100).toDouble();
  }

  /// S_trf — คะแนนการจราจรของเส้นทาง
  ///
  /// - [majorRoadShare] สัดส่วนที่วิ่งบนถนนสายหลัก (จาก OSM) หักสูงสุด 45 คะแนน
  /// - [protectedShare] สัดส่วนที่มีทางเท้า/ทางจักรยานแยก ชดเชยคืนสูงสุด 60% ของส่วนที่หักจากถนนสายหลัก
  /// - [trafficLightCount] แยกสัญญาณไฟ หัก 4 คะแนนต่อแยก (สูงสุด 8 แยก)
  /// - [congestionPct] ร้อยละของเส้นทางที่รถติด หัก 0.3 ต่อ 1%
  static double trafficScore({
    double congestionPct = 0,
    int trafficLightCount = 0,
    double majorRoadShare = 0,
    double protectedShare = 0,
  }) {
    final pct = congestionPct.clamp(0, 100).toDouble();
    final lights = trafficLightCount.clamp(0, 8);
    final major = majorRoadShare.clamp(0.0, 1.0);
    final prot = protectedShare.clamp(0.0, 1.0);
    final roadPenalty = 45 * major * (1 - 0.6 * prot);
    final s = 100 - roadPenalty - (lights * 4) - (pct * 0.3);
    return s.clamp(0, 100).toDouble();
  }

  /// S_inc — คะแนนเหตุการณ์ ลดลงตามจำนวนรายงานที่ยังไม่หมดอายุบนเส้นทาง
  static double incidentScore(int activeIncidentCount) {
    final s = 100 - incidentPenalty * activeIncidentCount.clamp(0, 5);
    return s.clamp(0, 100).toDouble();
  }

  /// calculateSafetyScore() — คำนวณตามสมการที่ (3.1) และ (3.2)
  static SafetyScoreResult calculateSafetyScore({
    required int aqi,
    required double temperatureC,
    double precipitationMm = 0,
    double humidityPct = 0,
    double windKmh = 0,
    double congestionPct = 0,
    int trafficLightCount = 0,
    int activeIncidentCount = 0,
    double majorRoadShare = 0,
    double protectedShare = 0,
    double? litShare,
    DateTime? now,
  }) {
    final sAir = airScore(aqi);
    final sWx = weatherScore(
      temperatureC: temperatureC,
      precipitationMm: precipitationMm,
      humidityPct: humidityPct,
      windKmh: windKmh,
    );
    final sTrf = trafficScore(
      congestionPct: congestionPct,
      trafficLightCount: trafficLightCount,
      majorRoadShare: majorRoadShare,
      protectedShare: protectedShare,
    );
    final sInc = incidentScore(activeIncidentCount);

    final base = wAir * sAir + wWeather * sWx + wTraffic * sTrf + wIncident * sInc;
    final t = timeFactor(now, litShare);
    final score = (base * t).round().clamp(0, 100);

    return SafetyScoreResult(
      sAir: sAir,
      sWx: sWx,
      sTrf: sTrf,
      sInc: sInc,
      baseScore: base,
      timeFactor: t,
      score: score,
      level: getSafetyLevel(score),
    );
  }

  /// getSafetyLevel() — จัดระดับตามตารางที่ 3.16
  static SafetyLevel getSafetyLevel(int score) {
    if (score >= safeThreshold) return SafetyLevel.safe;
    if (score >= cautionThreshold) return SafetyLevel.caution;
    return SafetyLevel.highRisk;
  }

  /// สีที่แสดงบนแผนที่ตามตารางที่ 3.16
  static Color levelColor(SafetyLevel level) {
    switch (level) {
      case SafetyLevel.safe:
        return const Color(0xFF2ECC71); // เขียว
      case SafetyLevel.caution:
        return const Color(0xFFF39C12); // เหลือง
      case SafetyLevel.highRisk:
        return const Color(0xFFE74C3C); // แดง
    }
  }

  static Color scoreColor(int score) => levelColor(getSafetyLevel(score));

  /// UC-13: แสดงคำเตือนความเสี่ยงเมื่อคะแนนอยู่ในระดับเสี่ยงสูง (0–39)
  static bool shouldWarn(int score) =>
      getSafetyLevel(score) == SafetyLevel.highRisk;
}
