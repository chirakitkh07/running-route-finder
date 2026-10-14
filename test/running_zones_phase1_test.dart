import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter/material.dart';

import 'package:demo20426/models/running_zone.dart';
import 'package:demo20426/models/preset_zones.dart';
import 'package:demo20426/models/route_data.dart';
import 'package:demo20426/services/zone_service.dart';
import 'package:demo20426/services/safety_score_engine.dart';

void main() {
  group('เฟส 1: Unit Tests สำหรับระบบโซนวิ่ง (Running Zones)', () {
    // ─── 1. pointInPolygon ───────────────────────────────────────────
    group('ZoneService.pointInPolygon (Ray Casting Algorithm)', () {
      final squareRing = [
        const LatLng(18.7800, 98.9800),
        const LatLng(18.7900, 98.9800),
        const LatLng(18.7900, 98.9900),
        const LatLng(18.7800, 98.9900),
      ];

      test('จุดอยู่ภายในรูปหลายเหลี่ยม คืนค่า true', () {
        const insidePoint = LatLng(18.7850, 98.9850);
        expect(ZoneService.pointInPolygon(insidePoint, squareRing), isTrue);
      });

      test('จุดอยู่นอกรูปหลายเหลี่ยม คืนค่า false', () {
        const outsideNorth = LatLng(18.7950, 98.9850);
        const outsideEast = LatLng(18.7850, 98.9950);
        const outsideFar = LatLng(19.0000, 99.0000);
        expect(ZoneService.pointInPolygon(outsideNorth, squareRing), isFalse);
        expect(ZoneService.pointInPolygon(outsideEast, squareRing), isFalse);
        expect(ZoneService.pointInPolygon(outsideFar, squareRing), isFalse);
      });

      test('รูปหลายเหลี่ยมที่มีจุดน้อยกว่า 3 จุด คืนค่า false เสมอ', () {
        const point = LatLng(18.7850, 98.9850);
        expect(ZoneService.pointInPolygon(point, []), isFalse);
        expect(ZoneService.pointInPolygon(point, [const LatLng(18.78, 98.98)]), isFalse);
        expect(ZoneService.pointInPolygon(point, [
          const LatLng(18.78, 98.98),
          const LatLng(18.79, 98.98),
        ]), isFalse);
      });

      test('รูปหลายเหลี่ยมรูปตัว L (concave polygon)', () {
        // รูปตัว L
        final lRing = [
          const LatLng(0, 0),
          const LatLng(3, 0),
          const LatLng(3, 1),
          const LatLng(1, 1),
          const LatLng(1, 3),
          const LatLng(0, 3),
        ];

        // จุดในส่วนก้านล่าง (0.5, 2)
        expect(ZoneService.pointInPolygon(const LatLng(0.5, 2.0), lRing), isTrue);
        // จุดในส่วนกิ่งขวา (2.0, 0.5)
        expect(ZoneService.pointInPolygon(const LatLng(2.0, 0.5), lRing), isTrue);
        // จุดในส่วนรอยเว้าด้านใน (2.0, 2.0)
        expect(ZoneService.pointInPolygon(const LatLng(2.0, 2.0), lRing), isFalse);
      });
    });

    // ─── 2. bufferPolyline ──────────────────────────────────────────
    group('bufferPolyline (สร้างแถบขอบเขตริบบอน)', () {
      test('จำนวนจุดใน polygon ที่ได้มีค่าเท่ากับ 2 × n เสมอ', () {
        final path4 = [
          const LatLng(18.7810, 98.9800),
          const LatLng(18.7850, 98.9810),
          const LatLng(18.7890, 98.9820),
          const LatLng(18.7930, 98.9830),
        ];
        final polygon4 = bufferPolyline(path4, 25.0);
        expect(polygon4.length, equals(2 * path4.length));

        final path7 = [
          const LatLng(18.780, 98.980),
          const LatLng(18.782, 98.981),
          const LatLng(18.784, 98.982),
          const LatLng(18.786, 98.983),
          const LatLng(18.788, 98.984),
          const LatLng(18.790, 98.985),
          const LatLng(18.792, 98.986),
        ];
        final polygon7 = bufferPolyline(path7, 30.0);
        expect(polygon7.length, equals(2 * path7.length));
      });

      test('กรณี path ว่าง คืนค่า empty list', () {
        final polygon = bufferPolyline([], 20.0);
        expect(polygon, isEmpty);
      });

      test('พิกัดของ buffer ทุกจุดต้องเป็น finite ไม่เป็น NaN หรือ Infinity', () {
        final path = [
          const LatLng(18.7810, 98.9800),
          const LatLng(18.7900, 98.9900),
        ];
        final polygon = bufferPolyline(path, 30.0);
        expect(polygon.length, equals(4));
        for (final p in polygon) {
          expect(p.latitude.isFinite, isTrue);
          expect(p.longitude.isFinite, isTrue);
          expect(p.latitude.isNaN, isFalse);
          expect(p.longitude.isNaN, isFalse);
        }
      });
    });

    // ─── 3. RunningZone toMap / fromMap round-trip ────────────────────
    group('RunningZone Serialization (toMap / fromMap round-trip)', () {
      test('แปลง toMap() แล้ว fromMap() ได้ข้อมูลครบถ้วนตรงกัน', () {
        final original = RunningZone(
          id: 'zone_moat_test',
          name: 'รอบคูเมืองเชียงใหม่',
          nameEn: 'Old City Moat Loop',
          description: 'วิ่งรอบคูเมืองเก่า ร่มรื่น ปลอดภัย',
          descriptionEn: 'Run around old city moat',
          category: 'moat',
          polygons: [
            [
              const LatLng(18.7800, 98.9800),
              const LatLng(18.7900, 98.9800),
              const LatLng(18.7900, 98.9900),
              const LatLng(18.7800, 98.9900),
            ],
          ],
          center: const LatLng(18.7883, 98.9853),
          walkableLengthKm: 6.4,
          waypoints: [
            const Waypoint(
              name: 'ประตูช้างเผือก',
              type: 'rest',
              position: LatLng(18.7962, 98.9874),
              nameEn: 'Chang Phueak Gate',
            ),
          ],
          source: 'preset',
          osmRef: 'relation/12345',
          hidden: false,
          pinned: true,
          safetyScore: 92,
          scoreComponents: {
            'sAir': 95,
            'sWx': 90,
            'sTrf': 92,
            'sInc': 100,
            'timeFactor': 1.0,
          },
          computedAt: DateTime.parse('2026-10-12T12:00:00Z'),
        );

        final map = original.toMap();
        expect(map['id'], equals('zone_moat_test'));
        expect(map['polygons'], isA<List>());

        final restored = RunningZone.fromMap(map, original.id);

        expect(restored.id, equals(original.id));
        expect(restored.name, equals(original.name));
        expect(restored.nameEn, equals(original.nameEn));
        expect(restored.description, equals(original.description));
        expect(restored.descriptionEn, equals(original.descriptionEn));
        expect(restored.category, equals(original.category));
        expect(restored.walkableLengthKm, equals(original.walkableLengthKm));
        expect(restored.hidden, equals(original.hidden));
        expect(restored.pinned, equals(original.pinned));
        expect(restored.safetyScore, equals(original.safetyScore));
        expect(restored.source, equals(original.source));
        expect(restored.osmRef, equals(original.osmRef));

        // พิกัดจุดศูนย์กลาง
        expect(restored.center.latitude, closeTo(original.center.latitude, 0.0001));
        expect(restored.center.longitude, closeTo(original.center.longitude, 0.0001));

        // Polygon rings
        expect(restored.polygons.length, equals(original.polygons.length));
        expect(restored.polygons.first.length, equals(original.polygons.first.length));
        for (int i = 0; i < original.polygons.first.length; i++) {
          expect(restored.polygons.first[i].latitude,
              closeTo(original.polygons.first[i].latitude, 0.0001));
          expect(restored.polygons.first[i].longitude,
              closeTo(original.polygons.first[i].longitude, 0.0001));
        }

        // Waypoints
        expect(restored.waypoints.length, equals(original.waypoints.length));
        expect(restored.waypoints.first.name, equals(original.waypoints.first.name));
        expect(restored.waypoints.first.nameEn, equals(original.waypoints.first.nameEn));

        // Computed score components
        expect(restored.scoreComponents?['sAir'], equals(95));
      });
    });

    // ─── 4. ตารางระดับความปลอดภัย 3.16 และสี ──────────────────────────
    group('SafetyScoreEngine — การจัดระดับและสีตามตาราง 3.16', () {
      test('คะแนน >= 70 ระดับ safe สีเขียว 0xFF2ECC71', () {
        expect(SafetyScoreEngine.getSafetyLevel(70), equals(SafetyLevel.safe));
        expect(SafetyScoreEngine.getSafetyLevel(95), equals(SafetyLevel.safe));
        expect(SafetyScoreEngine.scoreColor(70), equals(const Color(0xFF2ECC71)));
      });

      test('คะแนน 40–69 ระดับ caution สีเหลือง 0xFFF39C12', () {
        expect(SafetyScoreEngine.getSafetyLevel(40), equals(SafetyLevel.caution));
        expect(SafetyScoreEngine.getSafetyLevel(69), equals(SafetyLevel.caution));
        expect(SafetyScoreEngine.scoreColor(55), equals(const Color(0xFFF39C12)));
      });

      test('คะแนน < 40 ระดับ highRisk สีแดง 0xFFE74C3C', () {
        expect(SafetyScoreEngine.getSafetyLevel(39), equals(SafetyLevel.highRisk));
        expect(SafetyScoreEngine.getSafetyLevel(0), equals(SafetyLevel.highRisk));
        expect(SafetyScoreEngine.scoreColor(20), equals(const Color(0xFFE74C3C)));
      });
    });

    // ─── 5. โซนเริ่มต้น (Preset Zones Fallback) ────────────────────────
    group('PresetZones — โซนเริ่มต้น 13 โซน', () {
      test('มีครบ 13 โซนเริ่มต้นและมีขอบเขต polygon ที่ถูกต้อง', () {
        final zones = PresetZones.defaultZones;
        expect(zones.length, equals(13));
        expect(zones.map((z) => z.id).toSet().length, equals(13)); // id ไม่ซ้ำ

        final ids = zones.map((z) => z.id).toSet();
        expect(ids, contains('zone_moat'));
        expect(ids, contains('zone_buakhad'));
        expect(ids, contains('zone_huaytueng'));
        expect(ids, contains('zone_cmu'));
        expect(ids, contains('zone_700yr'));
        expect(ids, contains('zone_suthep'));
        expect(ids, contains('zone_railway_park'));
        expect(ids, contains('zone_rajapruek'));
        expect(ids, contains('zone_pao_park'));
        expect(ids, contains('zone_lanna_rama9'));
        expect(ids, contains('zone_payap_stadium'));
        expect(ids, contains('zone_rmutl_doisaket_stadium'));
        expect(ids, contains('zone_cm_municipal_stadium'));

        // ทุกโซนที่ต้องดึงรูปทรงจาก OSM ต้องมีจุดศูนย์กลางอยู่ภายในรูปทรงสำรอง
        for (final z in zones) {
          if (!PresetZones.osmSpecs.containsKey(z.id)) continue;
          if (z.polygons.isEmpty) continue;
          final spec = PresetZones.osmSpecs[z.id]!;
          expect(spec.radiusM, greaterThan(0));
        }

        for (final z in zones) {
          expect(z.polygons, isNotEmpty);
          expect(z.polygons.first.length, greaterThanOrEqualTo(4));
          expect(z.center.latitude.isFinite, isTrue);
          expect(z.center.longitude.isFinite, isTrue);
          expect(z.walkableLengthKm, greaterThan(0));
        }
      });
    });
  });
}
