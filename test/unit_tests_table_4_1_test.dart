// การทดสอบระดับหน่วย UT-01 ถึง UT-23 ตามตารางที่ 4.1 ในเล่มปริญญานิพนธ์
// และการทดสอบเพิ่มเติมของสมการคะแนนความปลอดภัย (3.1), (3.2) และตารางที่ 3.16
//
// รันด้วย: flutter test test/unit_tests_table_4_1_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:demo20426/services/air_quality_service.dart';
import 'package:demo20426/services/safety_service.dart';
import 'package:demo20426/services/safety_score_engine.dart';
import 'package:demo20426/services/simulation_engine.dart';
import 'package:demo20426/utils/difficulty_utils.dart';

AirQualityData _aq(int aqi) => AirQualityData(
      pm25: 0,
      pm10: 0,
      ozone: 0,
      temperature: 0,
      humidity: 0,
      windSpeedKmh: 0,
      visibilityKm: 0,
      aqi: aqi,
      aqiLabel: '',
      latitude: 0,
      longitude: 0,
      fetchedAt: DateTime(2026),
    );

void main() {
  final day = DateTime(2026, 10, 1, 10); // 10:00 กลางวัน
  final night = DateTime(2026, 10, 1, 22); // 22:00 กลางคืน

  group('ตารางที่ 4.1 การทดสอบระดับหน่วย', () {
    test('UT-01 calculateAQI: PM2.5 = 0 → AQI = 0', () {
      expect(AirQualityService.calculateAQI(0), 0);
    });
    test('UT-02 calculateAQI: PM2.5 = 12.0 → AQI = 50', () {
      expect(AirQualityService.calculateAQI(12.0), 50);
    });
    test('UT-03 calculateAQI: PM2.5 = 35.4 → AQI ≈ 100', () {
      expect(AirQualityService.calculateAQI(35.4), closeTo(100, 1));
    });
    test('UT-04 calculateAQI: PM2.5 = 55.4 → AQI ≈ 150', () {
      expect(AirQualityService.calculateAQI(55.4), closeTo(150, 1));
    });
    test('UT-05 calculateAQI: PM2.5 = -1 → AQI = 0', () {
      expect(AirQualityService.calculateAQI(-1), 0);
    });
    test('UT-06 aqiLabel: AQI 50 → "ดี"', () {
      expect(AirQualityService.aqiLabel(50), contains('ดี'));
    });
    test('UT-07 aqiLabel: AQI 150 → "ไม่ดีสำหรับกลุ่มเสี่ยง"', () {
      expect(AirQualityService.aqiLabel(150), contains('ไม่ดีสำหรับกลุ่มเสี่ยง'));
    });
    test('UT-08 aqiLabel: AQI 300 → "อันตราย"', () {
      expect(AirQualityService.aqiLabel(300), contains('อันตราย'));
    });
    test('UT-09 aqiColorValue: AQI 50 → เขียว 0xFF2ECC71', () {
      expect(_aq(50).aqiColorValue, 0xFF2ECC71);
    });
    test('UT-10 aqiColorValue: AQI 201 → ม่วง 0xFF8E44AD', () {
      expect(_aq(201).aqiColorValue, 0xFF8E44AD);
    });
    test('UT-11 getTimedSafetyScore: base 100 → [70, 100]', () {
      for (final t in [day, night]) {
        final s = SafetyService.getTimedSafetyScore(100, now: t);
        expect(s, inInclusiveRange(70, 100));
      }
    });
    test('UT-12 getTimedSafetyScore: base 0 → 0', () {
      expect(SafetyService.getTimedSafetyScore(0, now: day), 0);
      expect(SafetyService.getTimedSafetyScore(0, now: night), 0);
    });
    test('UT-13 getTimedSafetyScore: base 90 → ≤ 90', () {
      expect(SafetyService.getTimedSafetyScore(90, now: day), lessThanOrEqualTo(90));
      expect(SafetyService.getTimedSafetyScore(90, now: night), lessThanOrEqualTo(90));
    });
    test('UT-14 getTimedSafetyScore: base 100 → ≤ 100', () {
      expect(SafetyService.getTimedSafetyScore(100, now: day), lessThanOrEqualTo(100));
      expect(SafetyService.getTimedSafetyScore(100, now: night), lessThanOrEqualTo(100));
    });
    test('UT-15 shouldWarn: base 30 → true', () {
      expect(SafetyService.shouldWarn(30, now: day), isTrue);
      expect(SafetyService.shouldWarn(30, now: night), isTrue);
    });
    test('UT-16 shouldWarn: base 100 → false', () {
      expect(SafetyService.shouldWarn(100, now: day), isFalse);
      expect(SafetyService.shouldWarn(100, now: night), isFalse);
    });
    test('UT-17 getDifficultyColor: easy → เขียว', () {
      expect(getDifficultyColor('easy'), const Color(0xFF2ECC71));
    });
    test('UT-18 getDifficultyColor: hard → แดง', () {
      expect(getDifficultyColor('hard'), const Color(0xFFE74C3C));
    });
    test('UT-19 getDifficultyColor: unknown → Colors.white', () {
      expect(getDifficultyColor('unknown'), Colors.white);
    });
    test('UT-20 getDifficultyLabel: easy → "ง่าย"', () {
      expect(getDifficultyLabel('easy'), 'ง่าย');
    });
    test('UT-21 getDifficultyLabel: moderate → "ปานกลาง"', () {
      expect(getDifficultyLabel('moderate'), 'ปานกลาง');
    });
    test('UT-22 getDifficultyLabel: hard → "ยาก"', () {
      expect(getDifficultyLabel('hard'), 'ยาก');
    });
    test('UT-23 classifyDifficultyFromElevation: 5 m → easy', () {
      expect(classifyDifficultyFromElevation(5), 'easy');
    });
  });

  group('สมการที่ (3.1), (3.2) และตารางที่ 3.16', () {
    test('ผลรวมค่าน้ำหนัก w1..w4 = 1', () {
      const sum = SafetyScoreEngine.wAir +
          SafetyScoreEngine.wWeather +
          SafetyScoreEngine.wTraffic +
          SafetyScoreEngine.wIncident;
      expect(sum, closeTo(1.0, 1e-9));
    });
    test('สภาพดีทุกปัจจัย กลางวัน → 100 (ปลอดภัย)', () {
      final r = SafetyScoreEngine.calculateSafetyScore(
          aqi: 25, temperatureC: 25, now: day);
      expect(r.score, 100);
      expect(r.level, SafetyLevel.safe);
    });
    test('สภาพดีทุกปัจจัย กลางคืน → 100 × 0.7 = 70', () {
      final r = SafetyScoreEngine.calculateSafetyScore(
          aqi: 25, temperatureC: 25, now: night);
      expect(r.timeFactor, 0.7);
      expect(r.score, 70);
    });
    test('คะแนนสุดท้ายไม่เกินคะแนนพื้นฐาน', () {
      final r = SafetyScoreEngine.calculateSafetyScore(
          aqi: 120, temperatureC: 35, congestionPct: 40, trafficLightCount: 3,
          activeIncidentCount: 2, now: night);
      expect(r.score, lessThanOrEqualTo(r.baseScore.round()));
    });
    test('ตารางที่ 3.16 ขอบเขตระดับ', () {
      expect(SafetyScoreEngine.getSafetyLevel(100), SafetyLevel.safe);
      expect(SafetyScoreEngine.getSafetyLevel(70), SafetyLevel.safe);
      expect(SafetyScoreEngine.getSafetyLevel(69), SafetyLevel.caution);
      expect(SafetyScoreEngine.getSafetyLevel(40), SafetyLevel.caution);
      expect(SafetyScoreEngine.getSafetyLevel(39), SafetyLevel.highRisk);
      expect(SafetyScoreEngine.getSafetyLevel(0), SafetyLevel.highRisk);
    });
    test('เส้นทางบนถนนสายหลักได้ S_trf ต่ำกว่าทางที่มีทางเท้า', () {
      final mainRoad = SafetyScoreEngine.trafficScore(majorRoadShare: 1.0, trafficLightCount: 4);
      final parkPath = SafetyScoreEngine.trafficScore(majorRoadShare: 0.0, protectedShare: 1.0);
      expect(parkPath, greaterThan(mainRoad));
      expect(parkPath, 100);
      expect(mainRoad, closeTo(100 - 45 - 16, 0.001));
    });
    test('T(t) กลางคืนขึ้นกับสัดส่วนไฟส่องสว่าง (0.7–1.0)', () {
      expect(SafetyScoreEngine.timeFactor(night), 0.7);
      expect(SafetyScoreEngine.timeFactor(night, 0.0), 0.7);
      expect(SafetyScoreEngine.timeFactor(night, 1.0), 1.0);
      expect(SafetyScoreEngine.timeFactor(night, 0.5), closeTo(0.85, 1e-9));
      expect(SafetyScoreEngine.timeFactor(day, 0.0), 1.0);
    });
    test('S_inc ลดลงตามจำนวนรายงานที่ยังไม่หมดอายุ', () {
      expect(SafetyScoreEngine.incidentScore(0), 100);
      expect(SafetyScoreEngine.incidentScore(1), 80);
      expect(SafetyScoreEngine.incidentScore(10), 0);
    });
  });

  group('SimulationEngine (UC-04)', () {
    test('estimateDurationMinutes: 6.4 กม. จังหวะ 6 นาที/กม. ไม่มีความชัน ≈ 38 นาที', () {
      expect(SimulationEngine.estimateDurationMinutes(6.4), 38);
    });
    test('estimateDurationMinutes: ความชันเพิ่มเวลา', () {
      expect(SimulationEngine.estimateDurationMinutes(5, elevationGainM: 50),
          greaterThan(SimulationEngine.estimateDurationMinutes(5)));
    });
    test('estimateCalories: วิ่ง 5 กม. ≈ 325 kcal', () {
      expect(SimulationEngine.estimateCalories(5), 325);
    });
    test('classifyDifficultyFromElevation เกณฑ์ 30 / 200 เมตร', () {
      expect(classifyDifficultyFromElevation(29), 'easy');
      expect(classifyDifficultyFromElevation(30), 'moderate');
      expect(classifyDifficultyFromElevation(199), 'moderate');
      expect(classifyDifficultyFromElevation(200), 'hard');
    });
  });
}
