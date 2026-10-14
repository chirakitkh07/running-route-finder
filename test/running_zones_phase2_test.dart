import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:demo20426/models/running_zone.dart';
import 'package:demo20426/utils/geo_utils.dart';
import 'package:demo20426/services/zone_recommender.dart';

void main() {
  group('เฟส 2: Unit Tests ระบบค้นหาและจัดอันดับโซนวิ่งอัตโนมัติ', () {
    // ─────────────────────────────────────────────────────────────────────────
    // 1. ทดสอบสูตรคะแนนแนะนำ R (สมการ 2.2)
    // ─────────────────────────────────────────────────────────────────────────
    group('ZoneRecommender — สูตรคำนวณคะแนนแนะนำ R', () {
      test('ผลรวมค่าน้ำหนัก wSafety + wDist + wLen + wPop เท่ากับ 1.0', () {
        final sum = ZoneRecommender.wSafety +
            ZoneRecommender.wDist +
            ZoneRecommender.wLen +
            ZoneRecommender.wPop;
        expect(sum, closeTo(1.0, 0.0001));
      });

      test('กรณีโซนไกลกว่ารัศมี (d >= radius) ต้องได้ S_dist = 0', () {
        // เมื่อ safety=100, dist=6km, radius=5km, len=3km, pop=50
        // S_safety = 100, S_dist = 0, S_len = 100, S_pop = 50
        // R = 0.55*100 + 0.20*0 + 0.15*100 + 0.10*50 = 55 + 0 + 15 + 5 = 75.0
        final r = ZoneRecommender.calculateRecommendationScore(
          safetyScore: 100.0,
          distanceKm: 6.0,
          radiusKm: 5.0,
          walkableLengthKm: 3.0,
          popScore: 50.0,
        );
        expect(r, closeTo(75.0, 0.01));
      });

      test('กรณีโซนอยู่ที่ระยะ 0 กม. (d = 0) ได้ S_dist = 100 เต็ม', () {
        // S_safety = 80, S_dist = 100, S_len = 3.0 (100), S_pop = 50
        // R = 0.55*80 + 0.20*100 + 0.15*100 + 0.10*50 = 44 + 20 + 15 + 5 = 84.0
        final r = ZoneRecommender.calculateRecommendationScore(
          safetyScore: 80.0,
          distanceKm: 0.0,
          radiusKm: 5.0,
          walkableLengthKm: 3.0,
          popScore: 50.0,
        );
        expect(r, closeTo(84.0, 0.01));
      });

      test('ความยาวทางวิ่ง walkableLengthKm >= 3.0 กม. ได้ S_len เต็ม 100', () {
        final r3 = ZoneRecommender.calculateRecommendationScore(
          safetyScore: 100.0,
          distanceKm: 5.0,
          radiusKm: 5.0,
          walkableLengthKm: 3.0,
          popScore: 50.0,
        );
        final r5 = ZoneRecommender.calculateRecommendationScore(
          safetyScore: 100.0,
          distanceKm: 5.0,
          radiusKm: 5.0,
          walkableLengthKm: 5.0,
          popScore: 50.0,
        );
        expect(r3, equals(r5));
      });

      test('ความยาวทางวิ่ง 1.5 กม. ได้ S_len เท่ากับ 50', () {
        // S_len = 1.5 / 3.0 * 100 = 50
        // R = 0.55*0 + 0.20*0 + 0.15*50 + 0.10*0 = 7.5
        final r = ZoneRecommender.calculateRecommendationScore(
          safetyScore: 0.0,
          distanceKm: 10.0,
          radiusKm: 5.0,
          walkableLengthKm: 1.5,
          popScore: 0.0,
        );
        expect(r, closeTo(7.5, 0.01));
      });
    });

    // ─────────────────────────────────────────────────────────────────────────
    // 2. ทดสอบพื้นที่ Shoelace Algorithm บนพิกัดภูมิศาสตร์
    // ─────────────────────────────────────────────────────────────────────────
    group('GeoUtils.calculateShoelaceArea — คำนวณพื้นที่ Polygon', () {
      test('สี่เหลี่ยมจัตุรัส 100x100 ม. ได้พื้นที่ ≈ 10,000 ตร.ม. (±2%)', () {
        // อ้างอิงที่ละติจูดเชียงใหม่ ~18.79°
        const centerLat = 18.7900;
        const centerLng = 98.9800;
        const sideM = 100.0;

        // แปลงเมตรเป็นองศาละติจูดและลองจิจูด
        const dLat = (sideM / GeoUtils.earthRadiusMeters) * (180.0 / math.pi);
        final dLng = (sideM / (GeoUtils.earthRadiusMeters * math.cos(centerLat * math.pi / 180.0))) *
            (180.0 / math.pi);

        final square100m = [
          const LatLng(centerLat, centerLng),
          LatLng(centerLat + dLat, centerLng),
          LatLng(centerLat + dLat, centerLng + dLng),
          LatLng(centerLat, centerLng + dLng),
        ];

        final area = GeoUtils.calculateShoelaceArea(square100m);
        // คาดหวัง 10,000 ตร.ม. ± 2% (9,800 - 10,200)
        expect(area, closeTo(10000.0, 200.0));
      });

      test('รูปหลายเหลี่ยมที่มีจุดน้อยกว่า 3 จุด คืนค่า 0.0', () {
        expect(GeoUtils.calculateShoelaceArea([]), equals(0.0));
        expect(GeoUtils.calculateShoelaceArea([const LatLng(18.0, 98.0)]), equals(0.0));
        expect(
          GeoUtils.calculateShoelaceArea([
            const LatLng(18.0, 98.0),
            const LatLng(18.1, 98.1),
          ]),
          equals(0.0),
        );
      });
    });

    // ─────────────────────────────────────────────────────────────────────────
    // 3. ทดสอบการตัดซ้ำ Polygon (Polygon Overlap Calculation)
    // ─────────────────────────────────────────────────────────────────────────
    group('GeoUtils.calculatePolygonOverlap — การตัดซ้ำ Polygon', () {
      test('รูปสองรูปที่ซ้อนทับกันอย่างมีนัยสำคัญ ได้ overlap >= 0.60', () {
        final polyA = [
          const LatLng(18.790, 98.980),
          const LatLng(18.795, 98.980),
          const LatLng(18.795, 98.985),
          const LatLng(18.790, 98.985),
        ];
        // polyB ซ้อนทับ 80% กับ polyA
        final polyB = [
          const LatLng(18.791, 98.981),
          const LatLng(18.795, 98.981),
          const LatLng(18.795, 98.985),
          const LatLng(18.791, 98.985),
        ];

        final overlap = GeoUtils.calculatePolygonOverlap(polyA, polyB);
        expect(overlap, greaterThanOrEqualTo(0.60));
      });

      test('รูปสองรูปที่อยู่ห่างกันคนละพื้นที่ คืนค่า overlap = 0.0', () {
        final polyA = [
          const LatLng(18.790, 98.980),
          const LatLng(18.795, 98.980),
          const LatLng(18.795, 98.985),
          const LatLng(18.790, 98.985),
        ];
        // polyB อยู่ห่างออกไป 10 กม.
        final polyB = [
          const LatLng(18.890, 98.980),
          const LatLng(18.895, 98.980),
          const LatLng(18.895, 98.985),
          const LatLng(18.890, 98.985),
        ];

        final overlap = GeoUtils.calculatePolygonOverlap(polyA, polyB);
        expect(overlap, equals(0.0));
      });
    });

    // ─────────────────────────────────────────────────────────────────────────
    // 4. ทดสอบการสร้างเหตุผลแนะนำ (Recommendation Reasons)
    // ─────────────────────────────────────────────────────────────────────────
    group('ZoneRecommender.generateReasons — การสร้างเหตุผลแนะนำ', () {
      test('สร้างเหตุผลแนะนำ 2–3 ข้อตามคุณลักษณะของโซน', () {
        const testZone = RunningZone(
          id: 'test_park',
          name: 'สวนสาธารณะทดสอบ',
          description: 'สวนสาธารณะ',
          category: 'park',
          polygons: [],
          center: LatLng(18.79, 98.98),
          walkableLengthKm: 4.5,
          safetyScore: 88,
          scoreComponents: {
            'roadCharacteristics': {
              'majorRoadShare': 0.0,
              'litShare': 0.85,
              'hasSidewalkShare': 0.80,
            },
          },
        );

        final reasons = ZoneRecommender.generateReasons(
          testZone,
          userDistKm: 1.2,
          pm25: 18.0,
        );

        expect(reasons.length, inInclusiveRange(2, 3));
        // ตรวจสอบว่ามีเหตุผลเกี่ยวกับความใกล้หรือความปลอดภัย
        expect(reasons.any((r) => r.contains('ใกล้') || r.contains('close') || r.contains('1.2')), isTrue);
      });

      test('โซนที่ไม่มีข้อมูลเสริมยังมีเหตุผลเริ่มต้นที่เหมาะสม', () {
        const minimalZone = RunningZone(
          id: 'test_minimal',
          name: 'ลานวิ่ง',
          description: '',
          category: 'track',
          polygons: [],
          center: LatLng(18.79, 98.98),
        );

        final reasons = ZoneRecommender.generateReasons(minimalZone);
        expect(reasons.isNotEmpty, isTrue);
      });
    });

    // ─────────────────────────────────────────────────────────────────────────
    // 5. ทดสอบ Geohash 5 หลัก และ Geohash Neighbors
    // ─────────────────────────────────────────────────────────────────────────
    group('GeoUtils — Geohash-5 Encoding & Neighbors', () {
      test('encodeGeohash5 คืนค่าความยาว 5 ตัวอักษรและพิกัดเดียวกันได้ผลลัพธ์เดิม', () {
        final hash1 = GeoUtils.encodeGeohash5(18.7900, 98.9800);
        final hash2 = GeoUtils.encodeGeohash5(18.7900, 98.9800);
        expect(hash1.length, equals(5));
        expect(hash1, equals(hash2));
      });

      test('getGeohashNeighbors คืนช่องรอบข้างรวมช่องตัวเองครบ 9 ช่อง', () {
        final centerHash = GeoUtils.encodeGeohash5(18.7900, 98.9800);
        final neighbors = GeoUtils.getGeohashNeighbors(centerHash);
        expect(neighbors.length, equals(9));
        expect(neighbors.contains(centerHash), isTrue);
      });
    });
  });
}
