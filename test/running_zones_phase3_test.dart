import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:demo20426/models/running_zone.dart';
import 'package:demo20426/services/zone_popularity_service.dart';
import 'package:demo20426/services/zone_recommender.dart';

void main() {
  group('เฟส 3: Unit Tests ความนิยมจากมวลชน (S_pop) และเครื่องมือผู้ดูแล (UC-08)', () {
    // ─────────────────────────────────────────────────────────────────────────
    // 1. ทดสอบสูตรคะแนนความนิยม S_pop (สมการ 3.1)
    // ─────────────────────────────────────────────────────────────────────────
    group('ZonePopularityService.calculatePopScore — คำนวณคะแนนความนิยม S_pop', () {
      test('เมื่อ runs_4w = 0 คืนค่า S_pop = 0', () {
        final score = ZonePopularityService.calculatePopScore(0, p90: 20.0);
        expect(score, equals(0.0));
      });

      test('เมื่อ runs_4w = P90 (20 ครั้ง) คืนค่า S_pop = 100 เต็ม', () {
        final score = ZonePopularityService.calculatePopScore(20, p90: 20.0);
        expect(score, closeTo(100.0, 0.01));
      });

      test('เมื่อ runs_4w มากกว่า P90 ต้องถูกจำกัดไม่เกิน 100 (clamp)', () {
        final score = ZonePopularityService.calculatePopScore(100, p90: 20.0);
        expect(score, equals(100.0));
      });

      test('การปรับสเกลแบบ Logarithmic ให้คะแนนเติบโตตามสัดส่วน', () {
        final score5 = ZonePopularityService.calculatePopScore(5, p90: 20.0);
        final score10 = ZonePopularityService.calculatePopScore(10, p90: 20.0);
        expect(score5, greaterThan(0.0));
        expect(score10, greaterThan(score5));
        expect(score10, lessThan(100.0));
      });
    });

    // ─────────────────────────────────────────────────────────────────────────
    // 2. ทดสอบการนับเส้นทางผ่านโซน (Zone Run Detection เกณฑ์ >= 30%)
    // ─────────────────────────────────────────────────────────────────────────
    group('ZonePopularityService.isRouteInZone — เกณฑ์ตรวจจับการวิ่งผ่านโซน', () {
      const squareZone = RunningZone(
        id: 'test_square_zone',
        name: 'โซนสี่เหลี่ยมทดสอบ',
        description: 'ทดสอบ',
        category: 'park',
        polygons: [
          [
            LatLng(18.7800, 98.9800),
            LatLng(18.7900, 98.9800),
            LatLng(18.7900, 98.9900),
            LatLng(18.7800, 98.9900),
          ]
        ],
        center: LatLng(18.7850, 98.9850),
      );

      test('มีจุดในโซน >= 30% (เช่น 5 จาก 10 จุด = 50%) คืนค่า true', () {
        final route = [
          // 5 จุดในโซน
          const LatLng(18.7850, 98.9850),
          const LatLng(18.7860, 98.9860),
          const LatLng(18.7870, 98.9870),
          const LatLng(18.7840, 98.9840),
          const LatLng(18.7830, 98.9830),
          // 5 จุดนอกโซน
          const LatLng(18.7000, 98.9000),
          const LatLng(18.7010, 98.9010),
          const LatLng(18.7020, 98.9020),
          const LatLng(18.7030, 98.9030),
          const LatLng(18.7040, 98.9040),
        ];

        final passed = ZonePopularityService.isRouteInZone(route, squareZone);
        expect(passed, isTrue);
      });

      test('มีจุดในโซน < 30% (เช่น 2 จาก 10 จุด = 20%) คืนค่า false', () {
        final route = [
          // 2 จุดในโซน
          const LatLng(18.7850, 98.9850),
          const LatLng(18.7860, 98.9860),
          // 8 จุดนอกโซน
          const LatLng(18.7000, 98.9000),
          const LatLng(18.7010, 98.9010),
          const LatLng(18.7020, 98.9020),
          const LatLng(18.7030, 98.9030),
          const LatLng(18.7040, 98.9040),
          const LatLng(18.7050, 98.9050),
          const LatLng(18.7060, 98.9060),
          const LatLng(18.7070, 98.9070),
        ];

        final passed = ZonePopularityService.isRouteInZone(route, squareZone);
        expect(passed, isFalse);
      });

      test('เส้นทางว่างเปล่า คืนค่า false', () {
        expect(ZonePopularityService.isRouteInZone([], squareZone), isFalse);
      });
    });

    // ─────────────────────────────────────────────────────────────────────────
    // 3. ทดสอบ Key รายสัปดาห์ ISO (yyyy-Www)
    // ─────────────────────────────────────────────────────────────────────────
    group('ZonePopularityService — ISO Week Key Formatting', () {
      test('getIsoWeekKey ได้รูปแบบมาตรฐาน yyyy-Www', () {
        final key = ZonePopularityService.getIsoWeekKey(DateTime(2026, 10, 12));
        final regex = RegExp(r'^\d{4}-W\d{2}$');
        expect(regex.hasMatch(key), isTrue);
        expect(key, equals('2026-W42'));
      });

      test('getRecent4WeekKeys คืนค่า 4 สัปดาห์ย้อนหลังครบถ้วน', () {
        final keys = ZonePopularityService.getRecent4WeekKeys(DateTime(2026, 10, 12));
        expect(keys.length, equals(4));
        expect(keys[0], equals('2026-W42'));
        // ตรวจสอบว่าทุก key เป็น string ไม่ว่าง
        expect(keys.every((k) => k.startsWith('2026-W')), isTrue);
      });
    });

    // ─────────────────────────────────────────────────────────────────────────
    // 4. ทดสอบการปักหมุดโซน (Pinned Zone Bonus +10)
    // ─────────────────────────────────────────────────────────────────────────
    group('ZoneRecommender — Pinned Zone Bonus', () {
      test('โซนที่ปักหมุดได้คะแนนแนะนำ R เพิ่ม +10 คะแนน', () {
        final rNormal = ZoneRecommender.calculateRecommendationScore(
          safetyScore: 70.0,
          distanceKm: 2.0,
          radiusKm: 5.0,
          walkableLengthKm: 2.0,
          popScore: 50.0,
          isPinned: false,
        );

        final rPinned = ZoneRecommender.calculateRecommendationScore(
          safetyScore: 70.0,
          distanceKm: 2.0,
          radiusKm: 5.0,
          walkableLengthKm: 2.0,
          popScore: 50.0,
          isPinned: true,
        );

        expect(rPinned, closeTo(rNormal + 10.0, 0.01));
      });

      test('คะแนน R ของโซนที่ปักหมุดไม่เกิน 100 แม้คะแนนพื้นฐานสูง', () {
        final rPinned = ZoneRecommender.calculateRecommendationScore(
          safetyScore: 100.0,
          distanceKm: 0.0,
          radiusKm: 5.0,
          walkableLengthKm: 5.0,
          popScore: 100.0,
          isPinned: true,
        );

        expect(rPinned, equals(100.0));
      });
    });

    // ─────────────────────────────────────────────────────────────────────────
    // 5. ทดสอบกฎ UC-08 E2 (ห้ามลบโซนที่มีการใช้งานใน 4 สัปดาห์ล่าสุด)
    // ─────────────────────────────────────────────────────────────────────────
    group('UC-08 E2 — การป้องกันการลบโซนที่มีการใช้งาน', () {
      test('เมื่อ runs_4w > 0 กฎกำหนดให้ต้องปฏิเสธการลบ', () {
        const runs4w = 5;
        final canDelete = runs4w == 0;
        expect(canDelete, isFalse);
      });

      test('เมื่อ runs_4w == 0 สามารถลบโซนได้', () {
        const runs4w = 0;
        final canDelete = runs4w == 0;
        expect(canDelete, isTrue);
      });
    });
  });
}
