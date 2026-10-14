import 'package:flutter_test/flutter_test.dart';
import 'package:demo20426/services/air_quality_service.dart';
import 'package:demo20426/services/simulation_engine.dart';
import 'package:demo20426/services/safety_score_engine.dart';

AirQualityData _sample(DateTime at) => AirQualityData(
      pm25: 12,
      pm10: 20,
      ozone: 30,
      temperature: 28,
      humidity: 60,
      windSpeedKmh: 5,
      visibilityKm: 10,
      aqi: 50,
      aqiLabel: 'Good',
      latitude: 18.79,
      longitude: 98.98,
      fetchedAt: at,
    );

void main() {
  group('UC-10/11 A1: ใช้ข้อมูลที่จัดเก็บชั่วคราว (Cache)', () {
    tearDown(() => AirQualityService.debugSetCache(null));

    test('ไม่มีแคช → ใช้แคชไม่ได้', () {
      AirQualityService.debugSetCache(null);
      expect(AirQualityService.canUseCache(), isFalse);
    });

    test('แคชอายุไม่เกิน 1 ชั่วโมง → ใช้ได้', () {
      final now = DateTime(2026, 10, 15, 8, 0);
      AirQualityService.debugSetCache(_sample(now.subtract(const Duration(minutes: 30))));
      expect(AirQualityService.canUseCache(now), isTrue);
    });

    test('แคชเก่ากว่า 1 ชั่วโมง → ใช้ไม่ได้', () {
      final now = DateTime(2026, 10, 15, 8, 0);
      AirQualityService.debugSetCache(_sample(now.subtract(const Duration(minutes: 61))));
      expect(AirQualityService.canUseCache(now), isFalse);
    });

    test('asCached() คงค่าเดิมและระบุว่ามาจากแคช', () {
      final d = _sample(DateTime(2026, 10, 15, 7));
      final c = d.asCached();
      expect(d.fromCache, isFalse);
      expect(c.fromCache, isTrue);
      expect(c.pm25, d.pm25);
      expect(c.aqi, d.aqi);
      expect(c.fetchedAt, d.fetchedAt);
    });
  });

  group('UC-04 / UC-13 ตามเล่ม (ตรวจซ้ำหลังเพิ่มฟังก์ชัน)', () {
    test('UC-04 A1: ปรับจังหวะเฉลี่ยเองแล้วเวลาเปลี่ยนตาม', () {
      final slow = SimulationEngine.runSimulation(distanceKm: 5, paceMinPerKm: 8);
      final fast = SimulationEngine.runSimulation(distanceKm: 5, paceMinPerKm: 5);
      expect(slow.durationMinutes, 40);
      expect(fast.durationMinutes, 25);
    });

    test('UC-13: แจ้งเตือนเฉพาะคะแนน 0–39 (ตารางที่ 3.16)', () {
      expect(SafetyScoreEngine.shouldWarn(39), isTrue);
      expect(SafetyScoreEngine.shouldWarn(40), isFalse);
      expect(SafetyScoreEngine.shouldWarn(69), isFalse);
    });
  });
}
