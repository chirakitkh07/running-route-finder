import 'package:flutter/material.dart';
import 'incident_report.dart';

enum NotificationType {
  incident,
  like,
  comment,
  weather,
  milestone,
  route,
  system,
}

/// Model สำหรับการแจ้งเตือน Real-time ทั่วทั้งแอป
class AppNotification {
  final String id;
  final NotificationType type;
  final String titleTh;
  final String titleEn;
  final String subtitleTh;
  final String subtitleEn;
  final DateTime timestamp;
  bool isRead;
  final IconData icon;
  final Color iconColor;
  final IncidentReport? incidentReport;
  final String? activityId;
  final String? routeId;
  final double? targetLat;
  final double? targetLng;

  AppNotification({
    required this.id,
    required this.type,
    required this.titleTh,
    required this.titleEn,
    required this.subtitleTh,
    required this.subtitleEn,
    required this.timestamp,
    this.isRead = false,
    required this.icon,
    required this.iconColor,
    this.incidentReport,
    this.activityId,
    this.routeId,
    this.targetLat,
    this.targetLng,
  });

  String getTitle(bool isThai) => isThai ? titleTh : titleEn;
  String getSubtitle(bool isThai) => isThai ? subtitleTh : subtitleEn;

  /// คำนวณเวลาแบบ Relative Time (เช่น "เมื่อกี้", "5 นาทีที่แล้ว", "2 ชม. ที่แล้ว")
  String getTime(bool isThai) {
    final diff = DateTime.now().difference(timestamp);
    if (diff.inSeconds < 60) {
      return isThai ? 'เมื่อสักครู่' : 'Just now';
    } else if (diff.inMinutes < 60) {
      final m = diff.inMinutes;
      return isThai ? '$m นาทีที่แล้ว' : '${m}m ago';
    } else if (diff.inHours < 24) {
      final h = diff.inHours;
      return isThai ? '$h ชั่วโมงที่แล้ว' : '${h}h ago';
    } else if (diff.inDays == 1) {
      return isThai ? 'เมื่อวานนี้' : 'Yesterday';
    } else if (diff.inDays < 7) {
      final d = diff.inDays;
      return isThai ? '$d วันที่แล้ว' : '${d}d ago';
    } else {
      final d = timestamp.day.toString().padLeft(2, '0');
      final m = timestamp.month.toString().padLeft(2, '0');
      return '$d/$m';
    }
  }

  /// แปลง IncidentReport เป็น AppNotification อัตโนมัติ
  factory AppNotification.fromIncident(IncidentReport report, {bool isRead = false}) {
    IconData icon;
    Color color;

    switch (report.type) {
      case 'dogs':
        icon = Icons.pets_rounded;
        color = const Color(0xFFE67E22);
        break;
      case 'slippery':
        icon = Icons.water_drop_rounded;
        color = const Color(0xFF3498DB);
        break;
      case 'construction':
        icon = Icons.construction_rounded;
        color = const Color(0xFFF39C12);
        break;
      case 'lighting':
        icon = Icons.lightbulb_outline_rounded;
        color = const Color(0xFF9B59B6);
        break;
      case 'flooding':
        icon = Icons.water_rounded;
        color = const Color(0xFF2980B9);
        break;
      case 'accident':
        icon = Icons.car_crash_rounded;
        color = const Color(0xFFE74C3C);
        break;
      default:
        icon = Icons.warning_amber_rounded;
        color = const Color(0xFFE84200);
        break;
    }

    final typeLabel = IncidentReport.getTypeLabel(report.type);
    final descText = report.description.isNotEmpty ? ' • ${report.description}' : '';

    return AppNotification(
      id: 'incident_${report.id}',
      type: NotificationType.incident,
      titleTh: '🚨 เหตุการณ์ใหม่: $typeLabel',
      titleEn: '🚨 Incident Alert: $typeLabel',
      subtitleTh: 'รายงานโดย ${report.userName}$descText',
      subtitleEn: 'Reported by ${report.userName}$descText',
      timestamp: report.createdAt,
      isRead: isRead,
      icon: icon,
      iconColor: color,
      incidentReport: report,
      targetLat: report.latitude,
      targetLng: report.longitude,
    );
  }
}
