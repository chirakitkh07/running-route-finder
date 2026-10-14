import 'dart:math' as math;

import 'package:xml/xml.dart';

import '../l10n/tr.dart';
import '../models/activity.dart';

/// นำเข้าไฟล์ TCX (Training Center XML) ที่ export จากนาฬิกา เช่น Zepp / Amazfit
///
/// ตัวอย่างไฟล์ Zepp: test/fixtures/zepp_sample.tcx
/// - 1 Activity → 1 Lap (สรุป TotalTimeSeconds, DistanceMeters, Calories, ชีพจรเฉลี่ย/สูงสุด)
/// - Trackpoint ทุก 1 วินาที: Time, Position(lat/lng), HeartRateBpm, Cadence, ns3:TPX/Speed (m/s)
/// - ไม่มี AltitudeMeters และ DistanceMeters รายจุด → ระยะทางสะสมคำนวณด้วย Haversine
/// - Cadence ของ Zepp เป็น "ก้าวต่อนาทีต่อขาเดียว" (เฉลี่ย ~78) จึงคูณ 2 เป็น spm
class TcxImportService {
  TcxImportService._();

  /// ค่า cadence ในไฟล์เป็นต่อขาเดียว (Zepp/Garmin TCX) → คูณ 2 ให้เป็นก้าวต่อนาที
  static const bool cadenceIsPerLeg = true;

  /// ความเร็วขั้นต่ำที่นับว่า "กำลังเคลื่อนที่" (m/s) — ต่ำกว่านี้ถือว่าหยุดพัก
  static const double movingSpeedThreshold = 0.5;

  /// ช่วงห่างระหว่างจุดที่เกินนี้ไม่นับเป็นเวลาเคลื่อนที่ (เช่น GPS หาย / กดหยุด)
  static const int maxMovingGapSeconds = 30;

  /// อ่านไฟล์ TCX ทั้งไฟล์ → [TcxActivity]
  /// โยน [FormatException] ถ้าไม่ใช่ไฟล์ TCX หรือไม่มีจุดข้อมูล
  static TcxActivity parse(String tcxText) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(tcxText);
    } on XmlException catch (e) {
      throw FormatException(tr('ไฟล์ TCX ไม่ถูกต้อง: ${e.message}',
          'Invalid TCX file: ${e.message}'));
    }

    final activityEl = _desc(doc, 'Activity').firstOrNull;
    if (activityEl == null) {
      throw FormatException(
          tr('ไม่พบข้อมูลกิจกรรมในไฟล์', 'No activity found in file'));
    }

    final sport = activityEl.getAttribute('Sport') ?? 'Running';

    // ─── สรุปจาก Lap (ค่าที่นาฬิกาคำนวณเอง) ──────────────────
    double lapDistance = 0;
    double lapSeconds = 0;
    int lapCalories = 0;
    int? lapMaxHr;
    double hrWeighted = 0; // avgHR × เวลา เพื่อเฉลี่ยหลาย lap
    double hrWeightSec = 0;
    var hasLapDistance = false, hasLapTime = false, hasCalories = false;

    final points = <TcxTrackpoint>[];
    for (final lap in _desc(activityEl, 'Lap')) {
      final t = _num(_child(lap, 'TotalTimeSeconds'));
      final d = _num(_child(lap, 'DistanceMeters'));
      final c = _num(_child(lap, 'Calories'));
      final avgHr = _num(_child(_child(lap, 'AverageHeartRateBpm'), 'Value'));
      final maxHr = _num(_child(_child(lap, 'MaximumHeartRateBpm'), 'Value'));
      if (t != null) {
        lapSeconds += t;
        hasLapTime = true;
      }
      if (d != null) {
        lapDistance += d;
        hasLapDistance = true;
      }
      if (c != null) {
        lapCalories += c.round();
        hasCalories = true;
      }
      if (avgHr != null && t != null && t > 0) {
        hrWeighted += avgHr * t;
        hrWeightSec += t;
      }
      if (maxHr != null) {
        lapMaxHr = math.max(lapMaxHr ?? 0, maxHr.round());
      }

      for (final tp in _desc(lap, 'Trackpoint')) {
        final timeText = _child(tp, 'Time')?.innerText.trim();
        final time = timeText == null ? null : DateTime.tryParse(timeText);
        if (time == null) continue;
        final pos = _child(tp, 'Position');
        final cad = _num(_child(tp, 'Cadence')) ??
            _num(_desc(tp, 'RunCadence').firstOrNull);
        points.add(TcxTrackpoint(
          time: time.toUtc(),
          lat: _num(_child(pos, 'LatitudeDegrees')),
          lng: _num(_child(pos, 'LongitudeDegrees')),
          heartRate: _num(_child(_child(tp, 'HeartRateBpm'), 'Value'))?.round(),
          cadenceSpm: cad == null
              ? null
              : (cadenceIsPerLeg ? cad * 2 : cad).round(),
          speedMps: _num(_desc(tp, 'Speed').firstOrNull),
          altitudeM: _num(_child(tp, 'AltitudeMeters')),
        ));
      }
    }

    if (points.isEmpty) {
      throw FormatException(tr('ไฟล์ไม่มีจุดข้อมูลการวิ่ง (Trackpoint)',
          'File has no trackpoints'));
    }
    points.sort((a, b) => a.time.compareTo(b.time));

    final idText = _child(activityEl, 'Id')?.innerText.trim();
    final startedAt =
        (idText == null ? null : DateTime.tryParse(idText))?.toUtc() ??
            points.first.time;

    return TcxActivity._compute(
      sport: sport,
      startedAt: startedAt,
      points: points,
      lapDistanceM: hasLapDistance ? lapDistance : null,
      lapSeconds: hasLapTime ? lapSeconds.round() : null,
      calories: hasCalories ? lapCalories : null,
      lapAvgHr: hrWeightSec > 0 ? (hrWeighted / hrWeightSec).round() : null,
      lapMaxHr: lapMaxHr,
    );
  }

  // ─── XML helpers (เทียบชื่อแบบ local name → ไม่สนใจ prefix ns2/ns3) ──
  static XmlElement? _child(XmlElement? e, String local) {
    if (e == null) return null;
    for (final c in e.children) {
      if (c is XmlElement && c.name.local == local) return c;
    }
    return null;
  }

  static Iterable<XmlElement> _desc(XmlNode e, String local) => e.descendants
      .whereType<XmlElement>()
      .where((x) => x.name.local == local);

  static double? _num(XmlElement? e) =>
      e == null ? null : double.tryParse(e.innerText.trim());
}

/// จุดข้อมูล 1 จุดจากนาฬิกา (โดยปกติทุก 1 วินาที)
class TcxTrackpoint {
  final DateTime time; // UTC
  final double? lat;
  final double? lng;
  final int? heartRate; // bpm
  final int? cadenceSpm; // ก้าวต่อนาที (สองขา)
  final double? speedMps; // ความเร็วที่นาฬิกาวัด (m/s)
  final double? altitudeM;

  const TcxTrackpoint({
    required this.time,
    this.lat,
    this.lng,
    this.heartRate,
    this.cadenceSpm,
    this.speedMps,
    this.altitudeM,
  });

  bool get hasPosition => lat != null && lng != null;
}

/// สถิติรายกิโลเมตร (km สุดท้ายอาจไม่เต็ม — ดู [distanceM])
class TcxSplit {
  final int index; // 1, 2, 3, ...
  final double distanceM;
  final double seconds;
  final int? avgHeartRate;
  final int? avgCadenceSpm;

  const TcxSplit({
    required this.index,
    required this.distanceM,
    required this.seconds,
    this.avgHeartRate,
    this.avgCadenceSpm,
  });

  double get paceSecPerKm => distanceM > 0 ? seconds / distanceM * 1000 : 0;

  Map<String, dynamic> toMap() => {
        'index': index,
        'distanceM': double.parse(distanceM.toStringAsFixed(1)),
        'seconds': seconds.round(),
        'paceSecPerKm': paceSecPerKm.round(),
        if (avgHeartRate != null) 'avgHeartRate': avgHeartRate,
        if (avgCadenceSpm != null) 'avgCadenceSpm': avgCadenceSpm,
      };
}

/// ผลการนำเข้า + สถิติที่คำนวณแล้ว
class TcxActivity {
  final String sport; // ค่า Sport ในไฟล์ เช่น Running, Biking
  final DateTime startedAt; // UTC
  final List<TcxTrackpoint> points;

  final double distanceM;
  final int elapsedSeconds; // เวลารวมตั้งแต่เริ่มจนจบ (รวมช่วงหยุด)
  final int movingSeconds; // เฉพาะช่วงที่เคลื่อนที่
  final int? calories;

  final int? avgHeartRate;
  final int? maxHeartRate;
  final int? minHeartRate;
  final int? avgCadenceSpm; // เฉลี่ยเฉพาะช่วงที่วิ่ง (ไม่นับ 0)
  final int? maxCadenceSpm;
  final double? maxSpeedMps;
  final int elevationGainM;

  final List<TcxSplit> splits;

  TcxActivity._({
    required this.sport,
    required this.startedAt,
    required this.points,
    required this.distanceM,
    required this.elapsedSeconds,
    required this.movingSeconds,
    required this.calories,
    required this.avgHeartRate,
    required this.maxHeartRate,
    required this.minHeartRate,
    required this.avgCadenceSpm,
    required this.maxCadenceSpm,
    required this.maxSpeedMps,
    required this.elevationGainM,
    required this.splits,
  });

  /// 'running' | 'cycling' ตามที่ [Activity.activityType] ใช้
  String get activityType {
    final s = sport.toLowerCase();
    return (s.contains('bik') || s.contains('cycl')) ? 'cycling' : 'running';
  }

  double get distanceKm => distanceM / 1000;

  /// เพซเฉลี่ยจากเวลารวม (ตรงกับที่แอป Zepp แสดง)
  double get avgPaceSecPerKm =>
      distanceM > 0 ? elapsedSeconds / distanceM * 1000 : 0;

  /// เพซเฉลี่ยเฉพาะช่วงที่เคลื่อนที่
  double get movingPaceSecPerKm =>
      distanceM > 0 ? movingSeconds / distanceM * 1000 : 0;

  /// km ที่เร็วที่สุด (เฉพาะ km เต็ม)
  TcxSplit? get fastestSplit {
    final full = splits.where((s) => s.distanceM >= 999);
    if (full.isEmpty) return null;
    return full.reduce((a, b) => a.paceSecPerKm <= b.paceSecPerKm ? a : b);
  }

  /// เวลาในแต่ละโซนชีพจร (วินาที) แบ่งตาม % ของชีพจรสูงสุด [maxHr]
  /// โซน 1: <60%, 2: 60–70%, 3: 70–80%, 4: 80–90%, 5: ≥90%
  /// ไม่รู้ชีพจรสูงสุดของผู้ใช้ → ประมาณด้วย 220 − อายุ
  List<int> heartRateZoneSeconds({required int maxHr}) {
    final zones = List<int>.filled(5, 0);
    if (maxHr <= 0) return zones;
    for (var i = 1; i < points.length; i++) {
      final hr = points[i].heartRate;
      if (hr == null) continue;
      final dt = points[i].time.difference(points[i - 1].time).inSeconds;
      if (dt <= 0 || dt > TcxImportService.maxMovingGapSeconds) continue;
      final pct = hr / maxHr;
      final z = pct < 0.6
          ? 0
          : pct < 0.7
              ? 1
              : pct < 0.8
                  ? 2
                  : pct < 0.9
                      ? 3
                      : 4;
      zones[z] += dt;
    }
    return zones;
  }

  /// พิกัดเส้นทางสำหรับ [Activity.routePoints] — ลดจุดให้ไม่เกิน [maxPoints]
  /// (เอกสาร Firestore จำกัด 1 MB และแผนที่ย่อไม่ต้องใช้ทุกวินาที)
  List<Map<String, double>> routePoints({int maxPoints = 600}) {
    final pos = points.where((p) => p.hasPosition).toList();
    if (pos.isEmpty) return const [];
    final step = (pos.length / maxPoints).ceil().clamp(1, pos.length);
    final out = <Map<String, double>>[];
    for (var i = 0; i < pos.length; i += step) {
      out.add({'lat': pos[i].lat!, 'lng': pos[i].lng!});
    }
    final last = pos.last;
    if (out.last['lat'] != last.lat || out.last['lng'] != last.lng) {
      out.add({'lat': last.lat!, 'lng': last.lng!});
    }
    return out;
  }

  /// แปลงเป็น [Activity] เดิมของแอป เพื่อบันทึกผ่าน FirestoreService.saveActivity
  Activity toActivity({
    required String uid,
    String? title,
    bool isPublic = false,
    String? authorName,
    String? authorPhotoUrl,
  }) {
    return Activity(
      uid: uid,
      title: (title == null || title.trim().isEmpty)
          ? tr('วิ่งจากนาฬิกา', 'Watch run')
          : title.trim(),
      distanceKm: double.parse(distanceKm.toStringAsFixed(3)),
      durationSeconds: elapsedSeconds,
      avgPaceSecPerKm: avgPaceSecPerKm,
      elevationM: elevationGainM,
      activityType: activityType,
      startedAt: startedAt.toLocal(),
      isPublic: isPublic,
      authorName: authorName,
      authorPhotoUrl: authorPhotoUrl,
      routePoints: routePoints(),
    );
  }

  /// สถิติเพิ่มเติมที่ [Activity] ยังไม่มีช่อง — บันทึกเป็นฟิลด์ `watchStats`
  /// คู่กับ toMap() ได้ (firestore.rules ฝั่ง create ไม่จำกัดชื่อฟิลด์)
  Map<String, dynamic> toStatsMap() => {
        'source': 'tcx',
        'sport': sport,
        'movingSeconds': movingSeconds,
        'movingPaceSecPerKm': movingPaceSecPerKm.round(),
        if (calories != null) 'calories': calories,
        if (avgHeartRate != null) 'avgHeartRate': avgHeartRate,
        if (maxHeartRate != null) 'maxHeartRate': maxHeartRate,
        if (avgCadenceSpm != null) 'avgCadenceSpm': avgCadenceSpm,
        if (maxCadenceSpm != null) 'maxCadenceSpm': maxCadenceSpm,
        if (maxSpeedMps != null)
          'maxSpeedKmh': double.parse((maxSpeedMps! * 3.6).toStringAsFixed(1)),
        'splits': splits.map((s) => s.toMap()).toList(),
      };

  // ─── คำนวณสถิติทั้งหมดครั้งเดียวตอนสร้าง ───────────────────
  factory TcxActivity._compute({
    required String sport,
    required DateTime startedAt,
    required List<TcxTrackpoint> points,
    required double? lapDistanceM,
    required int? lapSeconds,
    required int? calories,
    required int? lapAvgHr,
    required int? lapMaxHr,
  }) {
    // ระยะทางสะสมด้วย Haversine (ไฟล์ Zepp ไม่มี DistanceMeters รายจุด)
    final pos = points.where((p) => p.hasPosition).toList();
    double gpsDistance = 0;
    double movingSec = 0;
    final cum = List<double>.filled(pos.length, 0);
    for (var i = 1; i < pos.length; i++) {
      final d = _haversineM(pos[i - 1], pos[i]);
      gpsDistance += d;
      cum[i] = gpsDistance;
      final dt = pos[i].time.difference(pos[i - 1].time).inMilliseconds / 1000;
      if (dt > 0 &&
          dt <= TcxImportService.maxMovingGapSeconds &&
          d / dt >= TcxImportService.movingSpeedThreshold) {
        movingSec += dt;
      }
    }

    // ระยะ/เวลา: ใช้ค่าที่นาฬิกาสรุปใน Lap ก่อน (ตรงกับแอป Zepp) ไม่มีจึงคำนวณเอง
    final distanceM = lapDistanceM ?? gpsDistance;
    final elapsed =
        lapSeconds ?? points.last.time.difference(points.first.time).inSeconds;

    // ชีพจร
    final hrs = points.map((p) => p.heartRate).whereType<int>().toList();
    int? avgHr = lapAvgHr;
    if (avgHr == null && hrs.isNotEmpty) {
      avgHr = (hrs.reduce((a, b) => a + b) / hrs.length).round();
    }
    final maxHr = lapMaxHr ?? (hrs.isEmpty ? null : hrs.reduce(math.max));
    final minHr = hrs.isEmpty ? null : hrs.reduce(math.min);

    // รอบขา (ไม่นับ 0 = ยืนนิ่ง)
    final cads =
        points.map((p) => p.cadenceSpm).whereType<int>().where((c) => c > 0);
    final avgCad = cads.isEmpty
        ? null
        : (cads.reduce((a, b) => a + b) / cads.length).round();
    final maxCad = cads.isEmpty ? null : cads.reduce(math.max);

    final speeds = points.map((p) => p.speedMps).whereType<double>();
    final maxSpeed = speeds.isEmpty ? null : speeds.reduce(math.max);

    // ความสูงสะสม (ถ้าไฟล์มี AltitudeMeters) — กรองสัญญาณรบกวน < 1 ม.
    double gain = 0;
    double? ref;
    for (final p in points) {
      final a = p.altitudeM;
      if (a == null) continue;
      if (ref == null) {
        ref = a;
      } else if (a - ref >= 1) {
        gain += a - ref;
        ref = a;
      } else if (a < ref) {
        ref = a;
      }
    }

    return TcxActivity._(
      sport: sport,
      startedAt: startedAt,
      points: List.unmodifiable(points),
      distanceM: distanceM,
      elapsedSeconds: elapsed,
      movingSeconds: movingSec.round(),
      calories: calories,
      avgHeartRate: avgHr,
      maxHeartRate: maxHr,
      minHeartRate: minHr,
      avgCadenceSpm: avgCad,
      maxCadenceSpm: maxCad,
      maxSpeedMps: maxSpeed,
      elevationGainM: gain.round(),
      splits: _splits(pos, cum),
    );
  }

  /// แบ่งรายกิโลเมตร — หาเวลาที่ผ่านแต่ละ km ด้วยการประมาณเชิงเส้นระหว่างสองจุด
  static List<TcxSplit> _splits(List<TcxTrackpoint> pos, List<double> cum) {
    final out = <TcxSplit>[];
    if (pos.length < 2) return out;
    final total = cum.last;
    double t0 = 0; // วินาทีจากจุดเริ่ม ณ ต้น km นี้
    final start = pos.first.time;
    var km = 1;
    var hrSum = 0, hrN = 0, cadSum = 0, cadN = 0;

    for (var i = 1; i < pos.length; i++) {
      final p = pos[i];
      if (p.heartRate != null) {
        hrSum += p.heartRate!;
        hrN++;
      }
      if (p.cadenceSpm != null && p.cadenceSpm! > 0) {
        cadSum += p.cadenceSpm!;
        cadN++;
      }
      // ใช้ while เพราะช่วงเดียวอาจข้ามหลาย km (GPS กระโดด)
      while (cum[i] >= km * 1000.0) {
        final target = km * 1000.0;
        final segD = cum[i] - cum[i - 1];
        final frac = segD > 0 ? (target - cum[i - 1]) / segD : 1.0;
        final ta = pos[i - 1].time.difference(start).inMilliseconds / 1000;
        final tb = p.time.difference(start).inMilliseconds / 1000;
        final tCross = ta + (tb - ta) * frac;
        out.add(TcxSplit(
          index: km,
          distanceM: 1000,
          seconds: tCross - t0,
          avgHeartRate: hrN > 0 ? (hrSum / hrN).round() : null,
          avgCadenceSpm: cadN > 0 ? (cadSum / cadN).round() : null,
        ));
        t0 = tCross;
        km++;
        hrSum = 0;
        hrN = 0;
        cadSum = 0;
        cadN = 0;
      }
    }

    // km สุดท้ายที่ไม่เต็ม (เก็บเมื่อ ≥ 50 ม.)
    final rest = total - (km - 1) * 1000.0;
    if (rest >= 50) {
      final tEnd = pos.last.time.difference(start).inMilliseconds / 1000;
      out.add(TcxSplit(
        index: km,
        distanceM: rest,
        seconds: tEnd - t0,
        avgHeartRate: hrN > 0 ? (hrSum / hrN).round() : null,
        avgCadenceSpm: cadN > 0 ? (cadSum / cadN).round() : null,
      ));
    }
    return out;
  }

  static double _haversineM(TcxTrackpoint a, TcxTrackpoint b) {
    const r = 6371008.8;
    final la1 = a.lat! * math.pi / 180, la2 = b.lat! * math.pi / 180;
    final dLa = la2 - la1;
    final dLo = (b.lng! - a.lng!) * math.pi / 180;
    final h = math.sin(dLa / 2) * math.sin(dLa / 2) +
        math.cos(la1) * math.cos(la2) * math.sin(dLo / 2) * math.sin(dLo / 2);
    return 2 * r * math.asin(math.min(1.0, math.sqrt(h)));
  }
}
