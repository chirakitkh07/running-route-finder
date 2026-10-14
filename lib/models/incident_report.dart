import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:latlong2/latlong.dart';
import '../l10n/tr.dart';

class IncidentReport {
  final String id;
  final String userId;
  final String userName;
  final String type; // 'dogs', 'slippery', 'construction', 'lighting', 'flooding', 'accident', 'other'
  final String title;
  final String description;
  final double latitude;
  final double longitude;
  final DateTime createdAt;
  final DateTime expiresAt;
  final int confirmationsCount;
  final int denialsCount;
  final List<String> confirmedBy;
  final List<String> deniedBy;
  final String status; // 'active', 'pending', 'suspended', 'expired', 'resolved'

  /// คะแนนความเชื่อมั่นจากบริการคัดกรองเนื้อหาด้วย AI (0–1) — UC-09 / UC-15
  final double? aiConfidence;

  IncidentReport({
    required this.id,
    required this.userId,
    required this.userName,
    required this.type,
    required this.title,
    required this.description,
    required this.latitude,
    required this.longitude,
    required this.createdAt,
    required this.expiresAt,
    this.confirmationsCount = 1,
    this.denialsCount = 0,
    this.confirmedBy = const [],
    this.deniedBy = const [],
    this.status = 'active',
    this.aiConfidence,
  });

  LatLng get position => LatLng(latitude, longitude);

  bool get isExpired => DateTime.now().isAfter(expiresAt);

  Map<String, dynamic> toMap() {
    return {
      'userId': userId,
      'userName': userName,
      'type': type,
      'title': title,
      'description': description,
      'latitude': latitude,
      'longitude': longitude,
      'createdAt': Timestamp.fromDate(createdAt),
      'expiresAt': Timestamp.fromDate(expiresAt),
      'confirmationsCount': confirmationsCount,
      'denialsCount': denialsCount,
      'confirmedBy': confirmedBy,
      'deniedBy': deniedBy,
      'status': status,
      if (aiConfidence != null) 'aiConfidence': aiConfidence,
    };
  }

  factory IncidentReport.fromMap(Map<String, dynamic> map, String docId) {
    DateTime parseDate(dynamic value) {
      if (value is Timestamp) return value.toDate();
      if (value is String) return DateTime.tryParse(value) ?? DateTime.now();
      return DateTime.now();
    }

    return IncidentReport(
      id: docId,
      userId: map['userId'] ?? '',
      userName: map['userName'] ?? tr('ผู้ใช้งาน', 'User'),
      type: map['type'] ?? 'other',
      title: map['title'] ?? tr('รายงานเหตุการณ์', 'Incident report'),
      description: map['description'] ?? '',
      latitude: (map['latitude'] as num?)?.toDouble() ?? 0.0,
      longitude: (map['longitude'] as num?)?.toDouble() ?? 0.0,
      createdAt: parseDate(map['createdAt']),
      expiresAt: parseDate(map['expiresAt']),
      confirmationsCount: map['confirmationsCount'] ?? 1,
      denialsCount: map['denialsCount'] ?? 0,
      confirmedBy: List<String>.from(map['confirmedBy'] ?? []),
      deniedBy: List<String>.from(map['deniedBy'] ?? []),
      status: map['status'] ?? 'active',
      aiConfidence: (map['aiConfidence'] as num?)?.toDouble(),
    );
  }

  /// ชื่อที่แสดงตามภาษาปัจจุบัน — title ที่บันทึกไว้เป็นชื่อประเภทภาษาไทย จึงแสดงจาก type แทน
  String get displayTitle => getTypeLabel(type);

  /// ชื่อประเภทเหตุการณ์ตามภาษาปัจจุบันของแอป
  static String getTypeLabel(String type) => tr(getTypeLabelTh(type), getTypeLabelEn(type));

  /// ชื่อประเภทภาษาไทย (ใช้บันทึกลงฐานข้อมูลและส่งให้ AI)
  static String getTypeLabelTh(String type) {
    switch (type) {
      case 'dogs':
        return '🐶 สุนัขจรจัด/ดุร้าย';
      case 'slippery':
        return '🌧️ ถนน/ทางลื่น';
      case 'construction':
        return '🚧 มีการก่อสร้าง/ปิดทาง';
      case 'lighting':
        return '🌙 ไฟส่องสว่างดับ/มืด';
      case 'flooding':
        return '🌊 น้ำท่วมขัง';
      case 'accident':
        return '🚨 เกิดอุบัติเหตุ';
      default:
        return '⚠️ เหตุการณ์/สิ่งกีดขวาง';
    }
  }

  static String getTypeLabelEn(String type) {
    switch (type) {
      case 'dogs':
        return '🐶 Stray/aggressive dogs';
      case 'slippery':
        return '🌧️ Slippery road/path';
      case 'construction':
        return '🚧 Construction/road closed';
      case 'lighting':
        return '🌙 Broken lights/dark';
      case 'flooding':
        return '🌊 Flooding';
      case 'accident':
        return '🚨 Accident';
      default:
        return '⚠️ Incident/obstacle';
    }
  }
}
