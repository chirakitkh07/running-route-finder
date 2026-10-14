import 'package:latlong2/latlong.dart';
import '../l10n/tr.dart';
import 'route_data.dart';

/// โมเดลข้อมูล "โซนวิ่ง" (Running Zone)
///
/// แสดงพื้นที่วิ่งแบบ Polygon ที่ดึงขอบเขตจริงจาก OpenStreetMap
/// และประเมินคะแนนความปลอดภัยตามสูตร SAW ของระบบ
class RunningZone {
  final String id; // เช่น 'zone_moat', หรือ 'osm_way_123456'
  final String name; // ไทย
  final String nameEn;
  final String description; // ไทย
  final String descriptionEn;
  final String category; // 'moat' | 'park' | 'stadium' | 'campus' | 'reservoir' | 'track' | 'other'
  final List<List<LatLng>> polygons; // รองรับหลาย ring/หลายส่วน (multipolygon)
  final LatLng center; // จุดศูนย์กลาง ใช้วาง marker/ป้ายชื่อ
  final double walkableLengthKm; // ความยาวทางเดิน/ทางเท้ารวมในโซน
  final List<Waypoint> waypoints; // นำ Waypoint เดิมกลับมาใช้
  final String source; // 'preset' | 'osm' | 'admin' | 'community'
  final String? osmRef; // เช่น 'way/123456' หรือ 'relation/789'
  final bool hidden; // ผู้ดูแลซ่อนได้
  final bool pinned; // ผู้ดูแลปักหมุดได้
  final String? geohash5; // Geohash 5 ตัวอักษรสำหรับแคชการค้นหา
  // ค่าที่คำนวณแล้ว (ไม่บังคับต้องมี)
  final int? safetyScore; // 0–100 หลังคูณ T(t)
  final Map<String, dynamic>? scoreComponents; // ผลจาก SafetyScoreResult.toMap()
  final double? recommendationScore; // R score (สมการ 2.2)
  final List<String> recommendationReasons; // เหตุผลแนะนำ 2-3 ข้อ
  final DateTime? computedAt;

  const RunningZone({
    required this.id,
    required this.name,
    this.nameEn = '',
    required this.description,
    this.descriptionEn = '',
    required this.category,
    required this.polygons,
    required this.center,
    this.walkableLengthKm = 0.0,
    this.waypoints = const [],
    this.source = 'preset',
    this.osmRef,
    this.hidden = false,
    this.pinned = false,
    this.geohash5,
    this.safetyScore,
    this.scoreComponents,
    this.recommendationScore,
    this.recommendationReasons = const [],
    this.computedAt,
  });

  String get displayName => tr(name, nameEn.isNotEmpty ? nameEn : name);
  String get displayDescription =>
      tr(description, descriptionEn.isNotEmpty ? descriptionEn : description);

  RunningZone copyWith({
    String? id,
    String? name,
    String? nameEn,
    String? description,
    String? descriptionEn,
    String? category,
    List<List<LatLng>>? polygons,
    LatLng? center,
    double? walkableLengthKm,
    List<Waypoint>? waypoints,
    String? source,
    String? osmRef,
    bool? hidden,
    bool? pinned,
    String? geohash5,
    int? safetyScore,
    Map<String, dynamic>? scoreComponents,
    double? recommendationScore,
    List<String>? recommendationReasons,
    DateTime? computedAt,
  }) {
    return RunningZone(
      id: id ?? this.id,
      name: name ?? this.name,
      nameEn: nameEn ?? this.nameEn,
      description: description ?? this.description,
      descriptionEn: descriptionEn ?? this.descriptionEn,
      category: category ?? this.category,
      polygons: polygons ?? this.polygons,
      center: center ?? this.center,
      walkableLengthKm: walkableLengthKm ?? this.walkableLengthKm,
      waypoints: waypoints ?? this.waypoints,
      source: source ?? this.source,
      osmRef: osmRef ?? this.osmRef,
      hidden: hidden ?? this.hidden,
      pinned: pinned ?? this.pinned,
      geohash5: geohash5 ?? this.geohash5,
      safetyScore: safetyScore ?? this.safetyScore,
      scoreComponents: scoreComponents ?? this.scoreComponents,
      recommendationScore: recommendationScore ?? this.recommendationScore,
      recommendationReasons:
          recommendationReasons ?? this.recommendationReasons,
      computedAt: computedAt ?? this.computedAt,
    );
  }

  /// แปลงเป็น Map สำหรับบันทึกใน Firestore
  /// เก็บ polygon เป็น List<Map> แบบ {'ring': [{'lat':..,'lng':..}, ...]} เพราะ Firestore ไม่รองรับ array ซ้อน array
  Map<String, dynamic> toMap() {
    final serializedPolygons = polygons.map((ring) {
      return {
        'ring': ring
            .map((p) => {
                  'lat': p.latitude,
                  'lng': p.longitude,
                })
            .toList(),
      };
    }).toList();

    return {
      'id': id,
      'name': name,
      'nameEn': nameEn,
      'description': description,
      'descriptionEn': descriptionEn,
      'category': category,
      'polygons': serializedPolygons,
      'center': {
        'lat': center.latitude,
        'lng': center.longitude,
      },
      'walkableLengthKm': walkableLengthKm,
      'waypoints': waypoints.map((w) => w.toMap()).toList(),
      'source': source,
      if (osmRef != null) 'osmRef': osmRef,
      'hidden': hidden,
      'pinned': pinned,
      if (geohash5 != null) 'geohash5': geohash5,
      if (safetyScore != null) 'safetyScore': safetyScore,
      if (scoreComponents != null) 'scoreComponents': scoreComponents,
      if (recommendationScore != null)
        'recommendationScore': recommendationScore,
      if (recommendationReasons.isNotEmpty)
        'recommendationReasons': recommendationReasons,
      if (computedAt != null) 'computedAt': computedAt!.toIso8601String(),
    };
  }

  factory RunningZone.fromMap(Map<String, dynamic> map, String id) {
    // แยก polygon รองรับทั้ง {'ring': [{'lat': ..., 'lng': ...}]} และ flat list
    final rawPolygons = map['polygons'] as List<dynamic>? ?? [];
    final List<List<LatLng>> parsedPolygons = [];

    for (final item in rawPolygons) {
      if (item is Map && item['ring'] is List) {
        final ringList = item['ring'] as List<dynamic>;
        final ring = <LatLng>[];
        for (final pt in ringList) {
          if (pt is Map) {
            final lat = (pt['lat'] as num?)?.toDouble() ?? 0.0;
            final lng = (pt['lng'] as num?)?.toDouble() ?? 0.0;
            if (lat.isFinite && lng.isFinite && (lat != 0.0 || lng != 0.0)) {
              ring.add(LatLng(lat, lng));
            }
          }
        }
        if (ring.isNotEmpty) parsedPolygons.add(ring);
      } else if (item is List) {
        // Fallback รองรับ raw array of points
        final ring = <LatLng>[];
        for (final pt in item) {
          if (pt is Map) {
            final lat = (pt['lat'] as num?)?.toDouble() ?? 0.0;
            final lng = (pt['lng'] as num?)?.toDouble() ?? 0.0;
            if (lat.isFinite && lng.isFinite && (lat != 0.0 || lng != 0.0)) {
              ring.add(LatLng(lat, lng));
            }
          }
        }
        if (ring.isNotEmpty) parsedPolygons.add(ring);
      }
    }

    // จุดกึ่งกลาง
    LatLng parsedCenter = const LatLng(18.7883, 98.9853);
    final rawCenter = map['center'];
    if (rawCenter is Map) {
      final lat = (rawCenter['lat'] as num?)?.toDouble() ?? 0.0;
      final lng = (rawCenter['lng'] as num?)?.toDouble() ?? 0.0;
      if (lat.isFinite && lng.isFinite && (lat != 0.0 || lng != 0.0)) {
        parsedCenter = LatLng(lat, lng);
      }
    } else if (parsedPolygons.isNotEmpty && parsedPolygons.first.isNotEmpty) {
      parsedCenter = parsedPolygons.first.first;
    }

    // Waypoints
    final rawWaypoints = map['waypoints'] as List<dynamic>? ?? [];
    final parsedWaypoints = rawWaypoints
        .whereType<Map<String, dynamic>>()
        .map((w) => Waypoint.fromMap(w))
        .toList();

    DateTime? parsedComputedAt;
    if (map['computedAt'] != null) {
      if (map['computedAt'] is String) {
        parsedComputedAt = DateTime.tryParse(map['computedAt'] as String);
      } else if (map['computedAt'] is DateTime) {
        parsedComputedAt = map['computedAt'] as DateTime;
      }
    }

    return RunningZone(
      id: id.isNotEmpty ? id : (map['id']?.toString() ?? ''),
      name: map['name']?.toString() ?? '',
      nameEn: map['nameEn']?.toString() ?? '',
      description: map['description']?.toString() ?? '',
      descriptionEn: map['descriptionEn']?.toString() ?? '',
      category: map['category']?.toString() ?? 'other',
      polygons: parsedPolygons,
      center: parsedCenter,
      walkableLengthKm: (map['walkableLengthKm'] as num?)?.toDouble() ?? 0.0,
      waypoints: parsedWaypoints,
      source: map['source']?.toString() ?? 'preset',
      osmRef: map['osmRef']?.toString(),
      hidden: map['hidden'] == true,
      pinned: map['pinned'] == true,
      geohash5: map['geohash5']?.toString(),
      safetyScore: (map['safetyScore'] as num?)?.toInt(),
      scoreComponents: map['scoreComponents'] is Map<String, dynamic>
          ? map['scoreComponents'] as Map<String, dynamic>
          : (map['scoreComponents'] is Map
              ? Map<String, dynamic>.from(map['scoreComponents'] as Map)
              : null),
      recommendationScore: (map['recommendationScore'] as num?)?.toDouble(),
      recommendationReasons: (map['recommendationReasons'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
      computedAt: parsedComputedAt,
    );
  }
}
