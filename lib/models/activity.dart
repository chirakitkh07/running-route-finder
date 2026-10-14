import 'dart:math' as math;
import 'package:cloud_firestore/cloud_firestore.dart';
import '../l10n/tr.dart';

/// Model สำหรับเก็บข้อมูลกิจกรรมการวิ่งแต่ละครั้ง
class Activity {
  final String? id;
  final String uid;
  final String title;
  final double distanceKm;
  final int durationSeconds;
  final double avgPaceSecPerKm; // seconds per km
  final int elevationM;
  final String activityType; // 'running' | 'cycling'
  final DateTime startedAt;

  // ─── Community Fields ────────────────────────────────────
  final bool isPublic;
  final int likesCount;
  final int commentsCount;
  final List<String> likedBy; // uid list
  final List<Map<String, double>> routePoints; // [{lat: x, lng: y}, ...]
  final String? authorName;
  final String? authorPhotoUrl;

  /// ผู้ใช้แก้ไขสถิติ/ชื่อย้อนหลัง (เส้นทาง GPS ไม่ถูกแก้)
  final DateTime? editedAt;
  /// สถิติจริงที่บันทึกจาก GPS ก่อนแก้ครั้งแรก {distanceKm, durationSeconds, avgPaceSecPerKm}
  final Map<String, num>? originalStats;

  const Activity({
    this.id,
    required this.uid,
    required this.title,
    required this.distanceKm,
    required this.durationSeconds,
    required this.avgPaceSecPerKm,
    required this.elevationM,
    this.activityType = 'running',
    required this.startedAt,
    this.isPublic = false,
    this.likesCount = 0,
    this.commentsCount = 0,
    this.likedBy = const [],
    this.routePoints = const [],
    this.authorName,
    this.authorPhotoUrl,
    this.editedAt,
    this.originalStats,
  });

  bool get isEdited => editedAt != null;

  /// ระยะทางของเส้นทาง GPS ที่บันทึกไว้ (กม.) — ใช้เทียบตอนแก้ไขระยะทาง
  double get gpsTrackKm {
    double sum = 0;
    for (var i = 0; i < routePoints.length - 1; i++) {
      final a = routePoints[i], b = routePoints[i + 1];
      final la1 = a['lat']! * math.pi / 180, la2 = b['lat']! * math.pi / 180;
      final dLa = la2 - la1;
      final dLo = (b['lng']! - a['lng']!) * math.pi / 180;
      final h = math.sin(dLa / 2) * math.sin(dLa / 2) +
          math.cos(la1) * math.cos(la2) * math.sin(dLo / 2) * math.sin(dLo / 2);
      sum += 2 * 6371.0 * math.asin(math.min(1.0, math.sqrt(h)));
    }
    return sum;
  }

  /// แปลง Activity เป็น Map สำหรับบันทึกใน Firestore
  Map<String, dynamic> toMap() => {
        'uid': uid,
        'title': title,
        'distanceKm': distanceKm,
        'durationSeconds': durationSeconds,
        'avgPaceSecPerKm': avgPaceSecPerKm,
        'elevationM': elevationM,
        'activityType': activityType,
        'startedAt': Timestamp.fromDate(startedAt),
        'createdAt': FieldValue.serverTimestamp(),
        'isPublic': isPublic,
        'likesCount': likesCount,
        'commentsCount': commentsCount,
        'likedBy': likedBy,
        'routePoints': routePoints,
        'authorName': authorName ?? '',
        'authorPhotoUrl': authorPhotoUrl ?? '',
      };

  /// สร้าง Activity จาก Firestore document
  factory Activity.fromMap(Map<String, dynamic> map, String id) {
    return Activity(
      id: id,
      uid: map['uid'] as String? ?? '',
      title: map['title'] as String? ?? tr('วิ่ง', 'Run'),
      distanceKm: (map['distanceKm'] as num?)?.toDouble() ?? 0.0,
      durationSeconds: (map['durationSeconds'] as num?)?.toInt() ?? 0,
      avgPaceSecPerKm: (map['avgPaceSecPerKm'] as num?)?.toDouble() ?? 0.0,
      elevationM: (map['elevationM'] as num?)?.toInt() ?? 0,
      activityType: map['activityType'] as String? ?? 'running',
      startedAt: (map['startedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      isPublic: map['isPublic'] as bool? ?? false,
      likesCount: (map['likesCount'] as num?)?.toInt() ?? 0,
      commentsCount: (map['commentsCount'] as num?)?.toInt() ?? 0,
      likedBy: List<String>.from(map['likedBy'] as List? ?? []),
      routePoints: (map['routePoints'] as List? ?? []).map((p) {
        final pt = p as Map<String, dynamic>;
        return {'lat': (pt['lat'] as num).toDouble(), 'lng': (pt['lng'] as num).toDouble()};
      }).toList(),
      authorName: map['authorName'] as String?,
      authorPhotoUrl: map['authorPhotoUrl'] as String?,
      editedAt: (map['editedAt'] as Timestamp?)?.toDate(),
      originalStats: (map['originalStats'] as Map?)?.map(
          (k, v) => MapEntry(k.toString(), (v as num?) ?? 0)),
    );
  }

  /// คืน Activity ใหม่ที่มีบางค่าเปลี่ยน
  Activity copyWith({
    bool? isPublic,
    int? likesCount,
    int? commentsCount,
    List<String>? likedBy,
    String? activityType,
    List<Map<String, double>>? routePoints,
  }) {
    return Activity(
      id: id,
      uid: uid,
      title: title,
      distanceKm: distanceKm,
      durationSeconds: durationSeconds,
      avgPaceSecPerKm: avgPaceSecPerKm,
      elevationM: elevationM,
      activityType: activityType ?? this.activityType,
      startedAt: startedAt,
      isPublic: isPublic ?? this.isPublic,
      likesCount: likesCount ?? this.likesCount,
      commentsCount: commentsCount ?? this.commentsCount,
      likedBy: likedBy ?? this.likedBy,
      routePoints: routePoints ?? this.routePoints,
      authorName: authorName,
      authorPhotoUrl: authorPhotoUrl,
      editedAt: editedAt,
      originalStats: originalStats,
    );
  }

  /// ฟอร์แมตเวลา hh:mm:ss หรือ mm:ss
  String get formattedDuration {
    final h = durationSeconds ~/ 3600;
    final m = (durationSeconds % 3600) ~/ 60;
    final s = durationSeconds % 60;
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  /// คำนวณความเร็วเฉลี่ย (km/h)
  double get speedKmh {
    if (durationSeconds <= 0 || distanceKm < 0.01) return 0.0;
    return (distanceKm / (durationSeconds / 3600));
  }

  /// ฟอร์แมตความเร็ว (เช่น 8.5 km/h)
  String get formattedSpeed {
    if (speedKmh <= 0) return '0.0 km/h';
    return '${speedKmh.toStringAsFixed(1)} km/h';
  }

  /// ฟอร์แมตเพซ mm:ss/km (ซ่อนเพซที่ผิดปกติเกิน 30:00 นาที/กม.)
  String get formattedPace {
    if (avgPaceSecPerKm <= 0 || avgPaceSecPerKm > 1800 || distanceKm < 0.01) return '--:--';
    final m = avgPaceSecPerKm ~/ 60;
    final s = (avgPaceSecPerKm % 60).round();
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }


  /// ฟอร์แมตวันที่แบบไทย
  String get formattedDate {
    final now = DateTime.now();
    final diff = now.difference(startedAt);
    if (diff.inDays == 0) return tr('วันนี้ ${_timeStr(startedAt)}', 'Today ${_timeStr(startedAt)}');
    if (diff.inDays == 1) return tr('เมื่อวาน ${_timeStr(startedAt)}', 'Yesterday ${_timeStr(startedAt)}');
    final thaiMonths = ['', 'ม.ค.', 'ก.พ.', 'มี.ค.', 'เม.ย.', 'พ.ค.', 'มิ.ย.', 'ก.ค.', 'ส.ค.', 'ก.ย.', 'ต.ค.', 'พ.ย.', 'ธ.ค.'];
    return '${startedAt.day} ${thaiMonths[startedAt.month]} ${_timeStr(startedAt)}';
  }

  String _timeStr(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}

// ─── Comment Model ───────────────────────────────────────

/// Model สำหรับ Comment ในกิจกรรม
class ActivityComment {
  final String? id;
  final String uid;
  final String authorName;
  final String? authorPhotoUrl;
  final String text;
  final DateTime createdAt;

  const ActivityComment({
    this.id,
    required this.uid,
    required this.authorName,
    this.authorPhotoUrl,
    required this.text,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        'uid': uid,
        'authorName': authorName,
        'authorPhotoUrl': authorPhotoUrl ?? '',
        'text': text,
        'createdAt': Timestamp.fromDate(createdAt),
      };

  factory ActivityComment.fromMap(Map<String, dynamic> map, String id) {
    return ActivityComment(
      id: id,
      uid: map['uid'] as String? ?? '',
      authorName: map['authorName'] as String? ?? tr('นักวิ่ง', 'Runner'),
      authorPhotoUrl: map['authorPhotoUrl'] as String?,
      text: map['text'] as String? ?? '',
      createdAt: (map['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  /// relative time string
  String get timeAgo {
    final diff = DateTime.now().difference(createdAt);
    if (diff.inMinutes < 1) return tr('เมื่อกี้', 'Just now');
    if (diff.inMinutes < 60) return tr('${diff.inMinutes} นาทีที่แล้ว', '${diff.inMinutes} min ago');
    if (diff.inHours < 24) return tr('${diff.inHours} ชั่วโมงที่แล้ว', '${diff.inHours} h ago');
    return tr('${diff.inDays} วันที่แล้ว', '${diff.inDays} d ago');
  }
}
