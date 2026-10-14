import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// สถานะของผู้วิ่งเทียบกับเส้นทางที่วางแผนไว้
enum RouteFollowState {
  /// ยังไม่ถึงเส้นทาง (กำลังเดินไปจุดเริ่ม) — ยังไม่เตือน
  approaching,
  onRoute,
  offRoute,
}

/// เหตุการณ์ที่หน้าจอต้องแจ้งผู้ใช้
enum OffRouteEvent {
  none,
  /// เข้าสู่เส้นทางครั้งแรก
  joined,
  /// เพิ่งออกนอกเส้นทาง
  wentOff,
  /// ยังอยู่นอกเส้นทาง — เตือนซ้ำ
  stillOff,
  /// กลับเข้าเส้นทางแล้ว
  backOn,
}

/// ตรวจว่าผู้วิ่งออกนอกเส้นทางหรือไม่ จากตำแหน่ง GPS ทีละจุด
///
/// - ระยะห่าง = ระยะสั้นสุดจากตำแหน่งถึงเส้นทาง (ทุกช่วงของ polyline)
/// - ออกนอกเส้นทางเมื่อห่างเกิน [offThresholdM] (บวกความคลาดเคลื่อน GPS ที่เกิน 15 ม.)
///   ติดกันอย่างน้อย [minOffFixes] จุด และนานอย่างน้อย [minOffDuration] — กัน GPS กระโดด
/// - กลับเข้าเส้นทางเมื่อห่างไม่เกิน [backOnThresholdM] (น้อยกว่าเกณฑ์ออก กันสถานะสลับไปมา)
/// - ระหว่างที่ยังไม่ถึงเส้นทาง (เดินจากบ้านไปจุดเริ่ม) จะไม่เตือน
class OffRouteMonitor {
  final List<LatLng> path;
  final double offThresholdM;
  final double backOnThresholdM;
  final int minOffFixes;
  final Duration minOffDuration;
  final Duration repeatEvery;

  OffRouteMonitor(
    List<LatLng> path, {
    this.offThresholdM = 40,
    this.backOnThresholdM = 25,
    this.minOffFixes = 3,
    this.minOffDuration = const Duration(seconds: 6),
    this.repeatEvery = const Duration(seconds: 45),
  }) : path = path
            .where((p) => p.latitude.isFinite && p.longitude.isFinite)
            .toList();

  RouteFollowState state = RouteFollowState.approaching;

  /// ระยะห่างจากเส้นทางล่าสุด (เมตร)
  double? distanceM;

  /// จุดบนเส้นทางที่ใกล้ที่สุด (ใช้ชี้ทางกลับ)
  LatLng? nearestPoint;

  int _farFixes = 0;
  DateTime? _farSince;
  DateTime? _lastAlertAt;

  bool get isUsable => path.length >= 2;

  /// เริ่มนับใหม่ (เช่น หลังกดพักแล้ววิ่งต่อ)
  void resetStreak() {
    _farFixes = 0;
    _farSince = null;
  }

  OffRouteEvent update(LatLng pos, {double accuracyM = 0, DateTime? now}) {
    if (!isUsable) return OffRouteEvent.none;
    final t = now ?? DateTime.now();
    final hit = nearestOnPath(pos, path);
    distanceM = hit.$1;
    nearestPoint = hit.$2;
    final d = hit.$1;
    final slack = (accuracyM - 15).clamp(0.0, 30.0);
    final offLimit = offThresholdM + slack;

    switch (state) {
      case RouteFollowState.approaching:
        if (d <= backOnThresholdM + slack) {
          state = RouteFollowState.onRoute;
          resetStreak();
          return OffRouteEvent.joined;
        }
        return OffRouteEvent.none;

      case RouteFollowState.onRoute:
        if (d > offLimit) {
          _farFixes++;
          _farSince ??= t;
          if (_farFixes >= minOffFixes &&
              t.difference(_farSince!) >= minOffDuration) {
            state = RouteFollowState.offRoute;
            _lastAlertAt = t;
            return OffRouteEvent.wentOff;
          }
        } else {
          resetStreak();
        }
        return OffRouteEvent.none;

      case RouteFollowState.offRoute:
        if (d <= backOnThresholdM + slack) {
          state = RouteFollowState.onRoute;
          resetStreak();
          return OffRouteEvent.backOn;
        }
        if (_lastAlertAt == null || t.difference(_lastAlertAt!) >= repeatEvery) {
          _lastAlertAt = t;
          return OffRouteEvent.stillOff;
        }
        return OffRouteEvent.none;
    }
  }

  /// ระยะสั้นสุด (เมตร) จาก [p] ถึงเส้น [path] และจุดบนเส้นที่ใกล้ที่สุด
  /// ใช้พิกัดระนาบท้องถิ่น (equirectangular) รอบ [p] — แม่นพอสำหรับระยะไม่กี่กิโลเมตร
  static (double, LatLng) nearestOnPath(LatLng p, List<LatLng> path) {
    const r = 6371000.0;
    final lat0 = p.latitude * math.pi / 180;
    final kx = r * math.cos(lat0) * math.pi / 180;
    const ky = r * math.pi / 180;
    double x(LatLng q) => (q.longitude - p.longitude) * kx;
    double y(LatLng q) => (q.latitude - p.latitude) * ky;

    var best = double.infinity;
    var bestPt = path.first;
    for (var i = 0; i < path.length - 1; i++) {
      final a = path[i], b = path[i + 1];
      final ax = x(a), ay = y(a), bx = x(b), by = y(b);
      final dx = bx - ax, dy = by - ay;
      final len2 = dx * dx + dy * dy;
      var u = len2 == 0 ? 0.0 : -(ax * dx + ay * dy) / len2;
      u = u.clamp(0.0, 1.0);
      final cx = ax + u * dx, cy = ay + u * dy;
      final d = math.sqrt(cx * cx + cy * cy);
      if (d < best) {
        best = d;
        bestPt = LatLng(
          a.latitude + u * (b.latitude - a.latitude),
          a.longitude + u * (b.longitude - a.longitude),
        );
      }
    }
    return (best, bestPt);
  }

  /// ทิศ (องศา 0 = เหนือ, ตามเข็มนาฬิกา) จาก [from] ไป [to]
  static double bearing(LatLng from, LatLng to) {
    final la1 = from.latitude * math.pi / 180, la2 = to.latitude * math.pi / 180;
    final dLon = (to.longitude - from.longitude) * math.pi / 180;
    final yv = math.sin(dLon) * math.cos(la2);
    final xv = math.cos(la1) * math.sin(la2) -
        math.sin(la1) * math.cos(la2) * math.cos(dLon);
    return (math.atan2(yv, xv) * 180 / math.pi + 360) % 360;
  }
}
