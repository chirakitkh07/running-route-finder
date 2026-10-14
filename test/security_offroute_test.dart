import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:demo20426/screens/login_screen.dart' show isValidEmail;
import 'package:demo20426/services/off_route_monitor.dart';
import 'package:demo20426/utils/password_policy.dart';

void main() {
  group('PasswordPolicy', () {
    test('ยอมรับรหัสที่ครบทุกเงื่อนไข', () {
      expect(PasswordPolicy.validate('Run#Safe2026'), isNull);
    });

    test('ปฏิเสธรหัสที่ไม่ผ่านเงื่อนไข', () {
      expect(PasswordPolicy.validate(''), isNotNull);
      expect(PasswordPolicy.validate('Ab1!'), isNotNull); // สั้น
      expect(PasswordPolicy.validate('abcdefg1!'), isNotNull); // ไม่มีตัวใหญ่
      expect(PasswordPolicy.validate('Abcdefgh!'), isNotNull); // ไม่มีตัวเลข
      expect(PasswordPolicy.validate('Abcdefgh1'), isNotNull); // ไม่มีสัญลักษณ์
      expect(PasswordPolicy.validate('Abc def1!'), isNotNull); // มีช่องว่าง
      expect(PasswordPolicy.validate('A' * 60 + 'b1!xxx'), isNotNull); // ยาวเกิน 64
      expect(PasswordPolicy.validate('P@ssw0rd'), isNotNull); // รหัสยอดนิยม
    });

    test('ห้ามมีชื่อหรืออีเมลของผู้ใช้', () {
      expect(
          PasswordPolicy.validate('Somchai#2026', email: 'somchai@mail.com'),
          isNotNull);
      expect(PasswordPolicy.validate('Runner#2026x', name: 'Runner Kit'), isNotNull);
      expect(PasswordPolicy.validate('Blue#Moon77', email: 'somchai@mail.com'), isNull);
    });

    test('ระดับความแข็งแรง', () {
      expect(PasswordPolicy.strength(''), 0);
      expect(PasswordPolicy.strength('abc'), 1);
      expect(PasswordPolicy.strength('abcdefgh12'), 1);
      expect(PasswordPolicy.strength('Abcdefgh12'), 2);
      expect(PasswordPolicy.strength('Abcdef#12'), 3);
      expect(PasswordPolicy.strength('Abcdef#12345'), 4);
    });
  });

  group('LoginThrottle', () {
    test('ผิด 4 ครั้งแรกยังไม่ล็อก', () {
      for (var i = 0; i < LoginThrottle.freeAttempts; i++) {
        expect(LoginThrottle.lockFor(i), Duration.zero);
      }
    });

    test('ล็อก 30 วิ แล้วเพิ่มเท่าตัว สูงสุด 15 นาที', () {
      expect(LoginThrottle.lockFor(5), const Duration(seconds: 30));
      expect(LoginThrottle.lockFor(6), const Duration(seconds: 60));
      expect(LoginThrottle.lockFor(7), const Duration(seconds: 120));
      expect(LoginThrottle.lockFor(20), const Duration(minutes: 15));
    });
  });

  group('isValidEmail', () {
    test('รูปแบบอีเมล', () {
      expect(isValidEmail('runner@gmail.com'), isTrue);
      expect(isValidEmail('a.b+run@rmutl.ac.th'), isTrue);
      expect(isValidEmail('runner@gmail'), isFalse);
      expect(isValidEmail('runner gmail.com'), isFalse);
      expect(isValidEmail('@gmail.com'), isFalse);
      expect(isValidEmail('a@b.c'), isFalse);
    });
  });

  group('OffRouteMonitor', () {
    // เส้นทางตรงไปทางทิศเหนือ ~1.1 กม. (ลองจิจูดคงที่)
    const lng = 98.98;
    final path = [const LatLng(18.780, lng), const LatLng(18.790, lng)];
    // ~ระยะ 1 ม. ในแนวตะวันออก-ตะวันตกที่ละติจูด 18.78
    const mPerDegLng = 105400.0;
    LatLng east(double lat, double meters) => LatLng(lat, lng + meters / mPerDegLng);
    final t0 = DateTime(2026, 10, 14, 6);
    DateTime at(int s) => t0.add(Duration(seconds: s));

    test('ระยะถึงเส้นทาง', () {
      final (d, p) = OffRouteMonitor.nearestOnPath(east(18.785, 50), path);
      expect(d, closeTo(50, 1.5));
      expect(p.latitude, closeTo(18.785, 1e-6));
      expect(p.longitude, closeTo(lng, 1e-9));
    });

    test('ยังไม่ถึงเส้นทาง → ไม่เตือน, ถึงแล้ว → joined', () {
      final m = OffRouteMonitor(path);
      expect(m.update(east(18.785, 300), now: at(0)), OffRouteEvent.none);
      expect(m.state, RouteFollowState.approaching);
      expect(m.update(east(18.785, 10), now: at(5)), OffRouteEvent.joined);
      expect(m.state, RouteFollowState.onRoute);
    });

    test('GPS กระโดดจุดเดียวไม่นับว่าออกนอกเส้นทาง', () {
      final m = OffRouteMonitor(path)..update(east(18.781, 0), now: at(0));
      expect(m.update(east(18.782, 80), now: at(1)), OffRouteEvent.none);
      expect(m.update(east(18.782, 5), now: at(2)), OffRouteEvent.none);
      expect(m.state, RouteFollowState.onRoute);
    });

    test('ออกนอกเส้นทางต่อเนื่อง → wentOff, เตือนซ้ำ, กลับเข้า → backOn', () {
      final m = OffRouteMonitor(path)..update(east(18.781, 0), now: at(0));
      expect(m.update(east(18.782, 60), now: at(1)), OffRouteEvent.none);
      expect(m.update(east(18.782, 70), now: at(4)), OffRouteEvent.none);
      expect(m.update(east(18.782, 80), now: at(8)), OffRouteEvent.wentOff);
      expect(m.state, RouteFollowState.offRoute);
      expect(m.update(east(18.782, 85), now: at(20)), OffRouteEvent.none);
      expect(m.update(east(18.782, 90), now: at(54)), OffRouteEvent.stillOff);
      // 30 ม. ยังไม่ถือว่ากลับ (ต้อง ≤ 25 ม.)
      expect(m.update(east(18.782, 30), now: at(56)), OffRouteEvent.none);
      expect(m.update(east(18.782, 10), now: at(58)), OffRouteEvent.backOn);
      expect(m.state, RouteFollowState.onRoute);
    });

    test('GPS คลาดเคลื่อนมาก → ขยายเกณฑ์', () {
      final m = OffRouteMonitor(path)..update(east(18.781, 0), now: at(0));
      for (var i = 1; i <= 5; i++) {
        expect(m.update(east(18.782, 55), accuracyM: 35, now: at(i * 4)),
            OffRouteEvent.none);
      }
      expect(m.state, RouteFollowState.onRoute);
    });

    test('ทิศทาง', () {
      expect(OffRouteMonitor.bearing(path.first, path.last), closeTo(0, 0.5));
      expect(OffRouteMonitor.bearing(path.first, east(18.780, 100)), closeTo(90, 0.5));
    });
  });
}
