import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:demo20426/services/tcx_import_service.dart';

/// ทดสอบการนำเข้าไฟล์ TCX จริงจากนาฬิกา Amazfit (แอป Zepp) วิ่ง 7.02 กม. 11 มิ.ย. 2026
/// ค่าคาดหวังคำนวณแยกด้วยสคริปต์ Python จากไฟล์เดียวกัน
void main() {
  late TcxActivity run;

  setUpAll(() {
    final text = File('test/fixtures/zepp_sample.tcx').readAsStringSync();
    run = TcxImportService.parse(text);
  });

  test('อ่านข้อมูลพื้นฐานจาก Lap ได้ครบ', () {
    expect(run.sport, 'Running');
    expect(run.activityType, 'running');
    expect(run.startedAt, DateTime.utc(2026, 6, 11, 10, 22, 27));
    expect(run.points.length, 2488);
    expect(run.distanceM, 7020);
    expect(run.elapsedSeconds, 2487);
    expect(run.calories, 566);
    expect(run.avgHeartRate, 174);
    expect(run.maxHeartRate, 182);
  });

  test('ระยะจาก GPS (Haversine) ตรงกับที่นาฬิกาสรุป', () {
    final pos = run.points.where((p) => p.hasPosition).length;
    expect(pos, 2487); // มี 1 จุดที่ไม่มีพิกัด
    final km = run.toActivity(uid: 'u').routePoints.length;
    expect(km, lessThanOrEqualTo(601));
  });

  test('เวลาเคลื่อนที่ไม่รวมช่วงหยุดพัก', () {
    expect(run.movingSeconds, closeTo(2394, 2));
    expect(run.avgPaceSecPerKm, closeTo(354.3, 0.5)); // 5:54 /กม.
    expect(run.movingPaceSecPerKm, closeTo(341.0, 0.5)); // 5:41 /กม.
  });

  test('รอบขาแปลงเป็นก้าวต่อนาที (×2)', () {
    expect(run.avgCadenceSpm, 162);
    expect(run.maxCadenceSpm, 172);
    expect(run.minHeartRate, 124);
    expect(run.maxSpeedMps, 3.38);
  });

  test('แบ่ง split รายกิโลเมตร', () {
    expect(run.splits.length, 7); // 7 กม.เต็ม (20 ม.สุดท้าย < 50 ม. ไม่นับ)
    const expected = [344.8, 340.2, 368.3, 328.5, 429.2, 336.7, 332.8];
    for (var i = 0; i < expected.length; i++) {
      expect(run.splits[i].distanceM, 1000);
      expect(run.splits[i].seconds, closeTo(expected[i], 0.5));
    }
    expect(run.splits[0].avgHeartRate, 163);
    expect(run.fastestSplit!.index, 4);
  });

  test('โซนชีพจร (ชีพจรสูงสุด 190)', () {
    final z = run.heartRateZoneSeconds(maxHr: 190);
    expect(z, [0, 10, 85, 433, 1947]);
  });

  test('แปลงเป็น Activity ของแอปได้', () {
    final a = run.toActivity(uid: 'u1', title: '');
    expect(a.uid, 'u1');
    expect(a.distanceKm, 7.02);
    expect(a.durationSeconds, 2487);
    expect(a.formattedPace, '05:54');
    expect(a.routePoints.first['lat'], closeTo(18.83273699, 1e-8));
    expect(run.toStatsMap()['splits'], hasLength(7));
  });

  test('ไฟล์เสียโยน FormatException', () {
    expect(() => TcxImportService.parse('not xml'), throwsFormatException);
    expect(() => TcxImportService.parse('<TrainingCenterDatabase/>'),
        throwsFormatException);
  });
}
