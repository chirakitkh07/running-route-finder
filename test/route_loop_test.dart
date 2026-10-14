import 'package:demo20426/models/preset_zones.dart';
import 'package:demo20426/models/route_data.dart';
import 'package:demo20426/services/routing_service.dart';
import 'package:demo20426/services/zone_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

double _len(List<LatLng> p) {
  double m = 0;
  for (int i = 0; i < p.length - 1; i++) {
    m += Geolocator.distanceBetween(p[i].latitude, p[i].longitude, p[i + 1].latitude, p[i + 1].longitude);
  }
  return m;
}

void main() {
  // สี่เหลี่ยม ~111 × 105 ม.
  const a = LatLng(18.7800, 98.9800), b = LatLng(18.7800, 98.9810);
  const c = LatLng(18.7810, 98.9810), d = LatLng(18.7810, 98.9800);

  group('RoutingService.extractLoop', () {
    test('ตัดติ่งไป-กลับออก เหลือวงปิดเท่าเส้นรอบรูป', () {
      const tip = LatLng(18.7795, 98.9815); // ซอยตันจากมุม b
      const mid = LatLng(18.7805, 98.9810); // จุดผ่านกลางด้าน b–c (ขาไปแบ่งด้าน ขากลับไม่แบ่ง)
      final walk = [a, b, tip, b, mid, c, d, a];
      final loop = RoutingService.extractLoop(walk);
      expect(loop.first, loop.last);
      expect(loop.contains(tip), isFalse);
      expect(_len(loop), closeTo(_len([a, b, c, d, a]), 0.5));
    });

    test('ติ่งที่มีวงย่อยอยู่ปลายทาง: ทิ้งทางเชื่อมที่เดินไป-กลับ เก็บวงที่ยาวที่สุด', () {
      const e = LatLng(18.7800, 98.9830), f = LatLng(18.7802, 98.9832), g = LatLng(18.7800, 98.9834);
      final walk = [a, b, e, f, g, e, b, c, d, a]; // b→e→(วงเล็ก e-f-g)→e→b
      final loop = RoutingService.extractLoop(walk);
      expect(loop.first, loop.last);
      expect(loop.contains(f), isFalse);
      expect(_len(loop), closeTo(_len([a, b, c, d, a]), 0.5));
    });

    test('ติ่งผอมยาว: ออกทางหนึ่ง กลับอีกทางที่ขนานกัน (ห่าง ~30 ม.) ถูกตัดออก', () {
      const t1 = LatLng(18.7800, 98.9840), t2 = LatLng(18.78027, 98.9840); // ยื่นจากมุม b ไป ~315 ม.
      final walk = [a, b, t1, t2, b, c, d, a];
      final loop = RoutingService.extractLoop(walk);
      expect(loop.first, loop.last);
      expect(loop.contains(t1), isFalse);
      expect(_len(loop), closeTo(_len([a, b, c, d, a]), 0.5));
    });

    test('เส้นที่เดินไป-กลับล้วน ๆ ไม่มีวง → คืนลิสต์ว่าง', () {
      expect(RoutingService.extractLoop([a, b, c, b, a]), isEmpty);
    });
  });

  group('เส้นทางยอดนิยม (ChiangMaiRoutes)', () {
    test('ทุกเส้นใช้ path ที่สร้างจาก Routing API และระยะทางตรงกับ path', () {
      for (final r in ChiangMaiRoutes.routes) {
        expect(ChiangMaiRoutes.hasRoadPath(r), isTrue, reason: r.id);
        expect(_len(r.path) / 1000, closeTo(r.distanceKm, 0.1), reason: r.id);
        final closed = Geolocator.distanceBetween(r.path.first.latitude, r.path.first.longitude,
                r.path.last.latitude, r.path.last.longitude) <
            1;
        expect(closed, r.id != 'doi_suthep', reason: '${r.id} วงปิด');
      }
    });

    test('setRoutes: path วาดมือจาก Firestore ถูกแทนด้วย path ที่แนบถนน', () {
      final original = List<RunningRoute>.of(ChiangMaiRoutes.routes);
      final moat = original.firstWhere((r) => r.id == 'moat_loop');
      ChiangMaiRoutes.setRoutes([
        moat.copyWith(path: const [LatLng(18.7963, 98.9790), LatLng(18.7963, 98.9937)], distanceKm: 6.4),
      ]);
      final merged = ChiangMaiRoutes.routes.single;
      expect(ChiangMaiRoutes.hasRoadPath(merged), isTrue);
      expect(merged.distanceKm, moat.distanceKm);
      ChiangMaiRoutes.setRoutes(original);
    });
  });

  group('เส้นทางวงรอบของโซนที่มีเส้นทางในแอป', () {
    test('ใช้เส้นที่แนบถนนไว้แล้วได้ทันที แม้ยังไม่ได้ขอบเขตจริงจาก OSM', () async {
      final zone = PresetZones.defaultZones.firstWhere((z) => z.id == 'zone_buakhad');
      // scoreZone ตั้ง computedAt ให้ — ต้องยังถือว่ายังไม่ได้ขอบเขตจริง
      expect(ZoneService.needsGeometry(zone.copyWith(computedAt: DateTime.now())), isTrue);
      expect(RoutingService.hasBuiltInCourse(zone), isTrue);
      final two = await RoutingService.fixedCourse(zone, zone.center, 2);
      expect(two, isNotNull);
      expect(two!.first, two.last);
      expect(_len(two) / 1000, closeTo(2 * 0.62, 0.02));
      expect(RoutingService.fixedCourseLapKm(zone), closeTo(0.62, 0.01));
    });
  });
}
