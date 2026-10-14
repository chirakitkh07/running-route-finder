import 'package:flutter_test/flutter_test.dart';
import 'package:demo20426/services/zone_recommender.dart';

void main() {
  group('ZoneRecommender.displayReasons — เหตุผลระยะทางคำนวณจากตำแหน่งปัจจุบัน', () {
    const stored = ['📍 stale 0.0', '🛡️ no major roads', '💡 lit 80%'];

    test('ไม่รู้ตำแหน่ง → ตัดเหตุผลระยะทางที่แคชไว้ออก', () {
      final r = ZoneRecommender.displayReasons(stored, null);
      expect(r.any((e) => e.startsWith('📍')), isFalse);
      expect(r, ['🛡️ no major roads', '💡 lit 80%']);
    });

    test('ไกลเกิน 3.5 กม. → ไม่มีเหตุผลระยะทาง', () {
      final r = ZoneRecommender.displayReasons(stored, 6.1);
      expect(r.any((e) => e.startsWith('📍')), isFalse);
    });

    test('ใกล้ → ใช้ระยะทางปัจจุบันแทนค่าที่แคชไว้ และไม่เกิน 3 ข้อ', () {
      final r = ZoneRecommender.displayReasons(stored, 1.2);
      expect(r.first, startsWith('📍'));
      expect(r.first, contains('1.2'));
      expect(r.length, 3);
    });
  });
}
