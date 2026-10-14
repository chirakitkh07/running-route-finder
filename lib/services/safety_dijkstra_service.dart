import 'dart:collection';
import 'dart:math' as math;
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import '../models/incident_report.dart';

class SafetyDijkstraService {
  static const double _wIncident = 0.40; // ลดลงเล็กน้อยเพื่อเปิดพื้นที่ให้ r_traffic / r_light
  static const double _wLighting = 0.25;
  static const double _wBuffer   = 0.15;
  static const double _wWidth    = 0.10;
  static const double _wTraffic  = 0.07; // น้ำหนักรถติดสีแดง
  static const double _wLight    = 0.03; // น้ำหนักแยกสัญญาณไฟ
  static const double _incidentRadiusM  = 60.0;
  static const double _trafficRadiusM   = 80.0; // รัศมีตรวจ segment รถติด
  static const double _lightRadiusM     = 30.0; // รัศมีตรวจจุดแยกไฟ

  static double _incidentBaseRisk(String type) {
    switch (type) {
      case 'accident':     return 1.00;
      case 'dogs':         return 0.85;
      case 'flooding':     return 0.80;
      case 'slippery':     return 0.70;
      case 'lighting':     return 0.65;
      case 'construction': return 0.55;
      default:             return 0.50;
    }
  }

  static SafetyDijkstraResult run({
    required List<LatLng> osrmPath,
    required List<IncidentReport> incidents,
    bool isNight = false,
    // เส้นทางย่อยที่รถติด (TomTom congested segments — list ของ [start, end] LatLng pairs)
    List<List<LatLng>> trafficSegments = const [],
    // จุดแยกสัญญาณไฟ (LatLng ของสี่แยกในเส้นทาง)
    List<LatLng> trafficLightNodes = const [],
  }) {
    if (osrmPath.length < 2) {
      return SafetyDijkstraResult(path: osrmPath, edgeWeights: [], totalSafetyWeight: 0, highRiskSegments: []);
    }
    final n = osrmPath.length;
    final edgeWeights = <double>[];
    final highRiskSegments = <_HighRiskSegment>[];

    for (int i = 0; i < n - 1; i++) {
      final u = osrmPath[i];
      final v = osrmPath[i + 1];
      final de = Geolocator.distanceBetween(u.latitude, u.longitude, v.latitude, v.longitude);
      final mid = LatLng((u.latitude + v.latitude) / 2, (u.longitude + v.longitude) / 2);
      final nearby = incidents.where((inc) => Geolocator.distanceBetween(mid.latitude, mid.longitude, inc.latitude, inc.longitude) <= _incidentRadiusM).toList();

      double r1 = 0.0;
      for (final inc in nearby) {
        final risk = math.min(_incidentBaseRisk(inc.type) + math.min(inc.confirmationsCount * 0.05, 0.20), 1.0);
        if (risk > r1) r1 = risk;
      }

      double r2 = isNight ? 0.4 : 0.0;
      if (nearby.any((inc) => inc.type == 'lighting')) r2 = math.min(r2 + 0.4, 1.0);

      double r3 = 0.1;
      if (i > 0 && i < n - 1) {
        final prev = osrmPath[i - 1];
        final b1 = _bearing(prev, u);
        final b2 = _bearing(u, v);
        final diff = (b2 - b1).abs() % 360;
        final turn = diff > 180 ? 360 - diff : diff;
        if (turn > 75) {
          r3 = 0.8;
        } else if (turn > 45) {
          r3 = 0.5;
        } else {
          r3 = 0.1;
        }
      }

      final r4 = de < 10 ? 0.7 : de < 25 ? 0.4 : de < 60 ? 0.2 : 0.0;

      // r5: รถติดสีแดง (TomTom congestion) — 1.0 ถ้า segment นี้ทับ segment รถติด
      double r5 = 0.0;
      if (trafficSegments.isNotEmpty) {
        for (final seg in trafficSegments) {
          if (seg.length < 2) continue;
          final segMid = LatLng((seg[0].latitude + seg[1].latitude) / 2, (seg[0].longitude + seg[1].longitude) / 2);
          final dist = Geolocator.distanceBetween(mid.latitude, mid.longitude, segMid.latitude, segMid.longitude);
          if (dist <= _trafficRadiusM) { r5 = 1.0; break; }
        }
      }

      // r6: แยกสัญญาณไฟ (traffic light node) — 1.0 ถ้า edge นี้ผ่านจุดแยก
      double r6 = 0.0;
      if (trafficLightNodes.isNotEmpty) {
        for (final node in trafficLightNodes) {
          final distU = Geolocator.distanceBetween(u.latitude, u.longitude, node.latitude, node.longitude);
          final distV = Geolocator.distanceBetween(v.latitude, v.longitude, node.latitude, node.longitude);
          if (distU <= _lightRadiusM || distV <= _lightRadiusM) { r6 = 1.0; break; }
        }
      }

      final riskSum = (_wIncident * r1) + (_wLighting * r2) + (_wBuffer * r3) + (_wWidth * r4) +
                      (_wTraffic * r5) + (_wLight * r6);
      final we = de * (1.0 + riskSum);
      edgeWeights.add(we);
      if (riskSum > 0.30) {
        highRiskSegments.add(_HighRiskSegment(
          start: u,
          end: v,
          riskScore: riskSum,
          nearbyIncidents: nearby,
          isTrafficRisk: r5 > 0,
          isLightRisk: r6 > 0,
        ));
      }
    }

    final distArr = List<double>.filled(n, double.infinity);
    final prevArr = List<int>.filled(n, -1);
    distArr[0] = 0.0;
    final pq = SplayTreeSet<_PqEntry>((a, b) => a.cost != b.cost ? a.cost.compareTo(b.cost) : a.idx.compareTo(b.idx));
    pq.add(_PqEntry(0.0, 0));
    final adj = List<List<_Edge>>.generate(n, (_) => []);
    for (int i = 0; i < n - 1; i++) {
      adj[i].add(_Edge(i + 1, edgeWeights[i]));
    }
    // ทางลัดข้ามจุด (i→i+2, i→i+3) อนุญาตเฉพาะเมื่อจุดที่ถูกข้าม "อยู่บนแนวเส้นตรงเดียวกัน"
    // (เบี่ยงไม่เกิน 3 ม.) — เดิมอนุญาตทุกจุด ทำให้เส้นทางลากตัดมุม/ตัดผ่านตึกและบล็อกอาคาร
    // จนเส้นทางไม่อยู่บนถนน (สาเหตุที่เส้นทางวงรอบดูยุ่งเหยิง)
    for (int i = 0; i < n - 2; i++) {
      if (_offLine(osrmPath[i + 1], osrmPath[i], osrmPath[i + 2]) <= _maxShortcutDeviationM) {
        adj[i].add(_Edge(i + 2, (edgeWeights[i] + edgeWeights[i + 1]) * 0.90));
      }
    }
    for (int i = 0; i < n - 3; i++) {
      if (_offLine(osrmPath[i + 1], osrmPath[i], osrmPath[i + 3]) <= _maxShortcutDeviationM &&
          _offLine(osrmPath[i + 2], osrmPath[i], osrmPath[i + 3]) <= _maxShortcutDeviationM) {
        adj[i].add(_Edge(i + 3, (edgeWeights[i] + edgeWeights[i + 1] + edgeWeights[i + 2]) * 0.85));
      }
    }

    while (pq.isNotEmpty) {
      final entry = pq.first;
      pq.remove(entry);
      final u = entry.idx;
      if (entry.cost > distArr[u]) continue;
      if (u == n - 1) break;
      for (final edge in adj[u]) {
        final nc = distArr[u] + edge.weight;
        if (nc < distArr[edge.to]) {
          distArr[edge.to] = nc;
          prevArr[edge.to] = u;
          pq.add(_PqEntry(nc, edge.to));
        }
      }
    }

    final pathIdx = <int>[];
    var cur = n - 1;
    while (cur != -1) { pathIdx.add(cur); cur = prevArr[cur]; }
    final safetyPath = pathIdx.reversed.map((i) => osrmPath[i]).toList();
    if (safetyPath.length < 2) {
      return SafetyDijkstraResult(path: osrmPath, edgeWeights: edgeWeights, totalSafetyWeight: distArr.last, highRiskSegments: highRiskSegments.map(_mapHighRisk).toList());
    }
    return SafetyDijkstraResult(path: safetyPath, edgeWeights: edgeWeights, totalSafetyWeight: distArr[n - 1], highRiskSegments: highRiskSegments.map(_mapHighRisk).toList());
  }

  static const double _maxShortcutDeviationM = 3.0;

  /// ระยะ (เมตร) จากจุด [p] ถึงส่วนของเส้นตรง [a]–[b]
  static double _offLine(LatLng p, LatLng a, LatLng b) {
    final k = math.cos(p.latitude * math.pi / 180.0);
    const m = 111320.0;
    final ax = a.longitude * k * m, ay = a.latitude * m;
    final bx = b.longitude * k * m, by = b.latitude * m;
    final px = p.longitude * k * m, py = p.latitude * m;
    final dx = bx - ax, dy = by - ay;
    final len2 = dx * dx + dy * dy;
    if (len2 == 0) return math.sqrt((px - ax) * (px - ax) + (py - ay) * (py - ay));
    final t = (((px - ax) * dx + (py - ay) * dy) / len2).clamp(0.0, 1.0);
    final qx = ax + t * dx, qy = ay + t * dy;
    return math.sqrt((px - qx) * (px - qx) + (py - qy) * (py - qy));
  }

  /// คำนวณมุมทิศทาง (bearing) ระหว่างสองจุด
  static double bearing(LatLng a, LatLng b) => _bearing(a, b);

  static double _bearing(LatLng a, LatLng b) {
    final lat1 = a.latitude * math.pi / 180;
    final lat2 = b.latitude * math.pi / 180;
    final dLng = (b.longitude - a.longitude) * math.pi / 180;
    return math.atan2(math.sin(dLng) * math.cos(lat2), math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(dLng)) * 180 / math.pi;
  }

  static HighRiskSegment _mapHighRisk(_HighRiskSegment s) {
    final types = s.nearbyIncidents.map((i) => i.type).toSet().toList();
    if (s.isTrafficRisk) types.add('traffic');
    if (s.isLightRisk) types.add('traffic_light');
    final count = s.nearbyIncidents.isNotEmpty
        ? s.nearbyIncidents.length
        : ((s.isTrafficRisk ? 1 : 0) + (s.isLightRisk ? 1 : 0));
    return HighRiskSegment(
      start: s.start,
      end: s.end,
      riskScore: s.riskScore,
      incidentCount: count,
      incidentTypes: types,
    );
  }
}

class SafetyDijkstraResult {
  final List<LatLng> path;
  final List<double> edgeWeights;
  final double totalSafetyWeight;
  final List<HighRiskSegment> highRiskSegments;
  const SafetyDijkstraResult({required this.path, required this.edgeWeights, required this.totalSafetyWeight, required this.highRiskSegments});
  int get avoidedIncidents => highRiskSegments.fold(0, (s, x) => s + x.incidentCount);
}

class HighRiskSegment {
  final LatLng start;
  final LatLng end;
  final double riskScore;
  final int incidentCount;
  final List<String> incidentTypes;
  const HighRiskSegment({required this.start, required this.end, required this.riskScore, required this.incidentCount, required this.incidentTypes});
  int get riskLevel => riskScore > 0.65 ? 3 : riskScore > 0.45 ? 2 : 1;
}

class _PqEntry { final double cost; final int idx; const _PqEntry(this.cost, this.idx); }
class _Edge { final int to; final double weight; const _Edge(this.to, this.weight); }
class _HighRiskSegment {
  final LatLng start;
  final LatLng end;
  final double riskScore;
  final List<IncidentReport> nearbyIncidents;
  final bool isTrafficRisk;
  final bool isLightRisk;
  const _HighRiskSegment({
    required this.start,
    required this.end,
    required this.riskScore,
    required this.nearbyIncidents,
    this.isTrafficRisk = false,
    this.isLightRisk = false,
  });
}
