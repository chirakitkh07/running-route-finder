import 'package:latlong2/latlong.dart';

/// ข้อมูลสรุปการวิ่งล่าสุด — ใช้ส่งจาก RecordScreen ไปยัง HomeScreen/FeedScreen
class LastRunSummary {
  final String title;
  final double distanceKm;
  final int durationSeconds;
  final double paceSecPerKm;
  final List<LatLng> routePoints;
  final DateTime finishedAt;
  final String activityType; // 'running' | 'cycling'

  const LastRunSummary({
    required this.title,
    required this.distanceKm,
    required this.durationSeconds,
    required this.paceSecPerKm,
    required this.routePoints,
    required this.finishedAt,
    this.activityType = 'running',
  });

  String get durationFormatted {
    final m = durationSeconds ~/ 60;
    final s = durationSeconds % 60;
    if (m >= 60) {
      final h = m ~/ 60;
      final remM = m % 60;
      return '${h}h ${remM}m';
    }
    return '${m}m ${s}s';
  }

  String get avgPaceFormatted {
    if (paceSecPerKm <= 0 || paceSecPerKm.isInfinite) return '0:00';
    final m = paceSecPerKm ~/ 60;
    final s = (paceSecPerKm % 60).toInt();
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}
