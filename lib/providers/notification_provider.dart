import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import '../models/app_notification.dart';
import '../models/incident_report.dart';
import '../models/last_run_summary.dart';
import '../services/firestore_service.dart';
import '../services/air_quality_service.dart';
import '../services/push_service.dart';
import 'language_provider.dart';

class NotificationProvider extends ChangeNotifier {
  final FirestoreService _firestoreService = FirestoreService();

  final List<AppNotification> _notifications = [];
  final Set<String> _readIds = {};
  final Set<String> _deletedIds = {};
  final Set<String> _knownIncidentIds = {};

  StreamSubscription<List<IncidentReport>>? _incidentSubscription;
  StreamSubscription<User?>? _authSubscription;
  StreamSubscription<RemoteMessage>? _pushSubscription;

  AppNotification? _bannerNotification;
  bool _showBanner = false;
  Timer? _bannerTimer;
  bool _isFirstIncidentLoad = true;
  String? _lastAirQualityNotifiedDate;

  List<AppNotification> get notifications => List.unmodifiable(_notifications);
  int get unreadCount => _notifications.where((n) => !n.isRead).length;

  AppNotification? get bannerNotification => _bannerNotification;
  bool get showBanner => _showBanner;

  NotificationProvider() {
    _init();
  }

  Future<void> _init() async {
    await _loadPreferences();
    _seedDefaultNotifications();
    _startIncidentListener();
    _startAuthListener();
    _startPushListener();
  }

  Future<void> _loadPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final read = prefs.getStringList('read_notification_ids') ?? [];
      final deleted = prefs.getStringList('deleted_notification_ids') ?? [];
      _readIds.addAll(read);
      _deletedIds.addAll(deleted);
      _lastAirQualityNotifiedDate = prefs.getString('last_aqi_notif_date');
    } catch (e) {
      debugPrint('[NotificationProvider] Error loading prefs: $e');
    }
  }

  Future<void> _savePreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('read_notification_ids', _readIds.toList());
      await prefs.setStringList('deleted_notification_ids', _deletedIds.toList());
      if (_lastAirQualityNotifiedDate != null) {
        await prefs.setString('last_aqi_notif_date', _lastAirQualityNotifiedDate!);
      }
    } catch (e) {
      debugPrint('[NotificationProvider] Error saving prefs: $e');
    }
  }

  /// ข้อมูลเริ่มต้นจำลอง สำหรับความก้าวหน้าและการแนะนำเส้นทาง
  void _seedDefaultNotifications() {
    final now = DateTime.now();

    final defaults = [
      AppNotification(
        id: 'seed_route_cmu',
        type: NotificationType.route,
        titleTh: '🗺️ เส้นทางใหม่แนะนำ',
        titleEn: '🗺️ Recommended New Route',
        subtitleTh: 'รอบคูเมืองเชียงใหม่ • 6.4 km • ระดับความปลอดภัย 90/100',
        subtitleEn: 'Chiang Mai Moat Loop • 6.4 km • Safety 90/100',
        timestamp: now.subtract(const Duration(hours: 2)),
        isRead: false,
        icon: Icons.route,
        iconColor: const Color(0xFFE84200),
      ),
      AppNotification(
        id: 'seed_weekly_goal',
        type: NotificationType.milestone,
        titleTh: '🎯 เป้าหมายสัปดาห์ใกล้สำเร็จ!',
        titleEn: '🎯 Weekly Goal Almost Reached!',
        subtitleTh: 'คุณวิ่งไปแล้ว 80% ของเป้าหมายสัปดาห์นี้ เหลืออีกเพียง 4 km',
        subtitleEn: "You've reached 80% of your weekly goal, only 4 km to go!",
        timestamp: now.subtract(const Duration(hours: 18)),
        isRead: false,
        icon: Icons.emoji_events,
        iconColor: const Color(0xFFF39C12),
      ),
      AppNotification(
        id: 'seed_welcome',
        type: NotificationType.system,
        titleTh: '🏃‍♂️ ยินดีต้อนรับสู่ Running Route Finder',
        titleEn: '🏃‍♂️ Welcome to Running Route Finder',
        subtitleTh: 'ค้นหาเส้นทางวิ่งที่ปลอดภัยในเชียงใหม่ พร้อมรายงานเหตุการณ์แบบ Real-time',
        subtitleEn: 'Explore safe running routes in Chiang Mai with real-time incident alerts',
        timestamp: now.subtract(const Duration(days: 1)),
        isRead: true,
        icon: Icons.directions_run,
        iconColor: const Color(0xFF3498DB),
      ),
    ];

    for (final item in defaults) {
      if (!_deletedIds.contains(item.id)) {
        if (_readIds.contains(item.id)) {
          item.isRead = true;
        }
        _notifications.add(item);
      }
    }
    _sortNotifications();
  }

  /// ติดตามเหตุการณ์จาก Firestore แบบ Real-time ทันที
  void _startIncidentListener() {
    _incidentSubscription?.cancel();
    _incidentSubscription = _firestoreService.streamActiveIncidents().listen(
      (incidents) {
        bool hasChanges = false;
        final currentIncidentNotificationIds = <String>{};

        for (final report in incidents) {
          final notifId = 'incident_${report.id}';
          currentIncidentNotificationIds.add(notifId);

          if (_deletedIds.contains(notifId)) continue;

          // ตรวจสอบว่าเป็น incident ใหม่หรือไม่
          final isNewToSession = !_knownIncidentIds.contains(report.id);
          _knownIncidentIds.add(report.id);

          final existingIndex = _notifications.indexWhere((n) => n.id == notifId);

          if (existingIndex < 0) {
            // ยังไม่มีในรายการ -> เพิ่มเข้าไป
            final isRead = _readIds.contains(notifId);
            final notif = AppNotification.fromIncident(report, isRead: isRead);
            _notifications.add(notif);
            hasChanges = true;

            // ถ้าไม่ใช่การโหลดครั้งแรก และสร้างขึ้นไม่เกิน 2 ชั่วโมง -> แสดง Floating Banner ทันที!
            final age = DateTime.now().difference(report.createdAt);
            if (!_isFirstIncidentLoad && isNewToSession && age.inHours < 24) {
              triggerBanner(notif);
              // แสดงบนแถบแจ้งเตือนของโทรศัพท์ด้วย (ไม่แจ้งเหตุที่ตัวเองรายงาน)
              if (report.userId != FirebaseAuth.instance.currentUser?.uid) {
                PushService.showSystemNotification(
                  tag: notifId,
                  title: notif.getTitle(LanguageProvider.isThaiNow),
                  body: notif.getSubtitle(LanguageProvider.isThaiNow),
                );
              }
            }
          }
        }

        if (_isFirstIncidentLoad) {
          _isFirstIncidentLoad = false;
        }

        if (hasChanges) {
          _sortNotifications();
          notifyListeners();
        }
      },
      onError: (err) {
        debugPrint('[NotificationProvider] Incident stream error: $err');
      },
    );
  }

  void _startAuthListener() {
    _authSubscription?.cancel();
    _authSubscription = FirebaseAuth.instance.authStateChanges().listen((user) {
      if (user != null) {
        // เมื่อ user เข้าสู่ระบบ ให้ sync preferences และ listener
        _loadPreferences();
        PushService.registerUser(user.uid);
      }
    });
  }

  /// รับ push (FCM) ที่เข้ามาตอนเปิดแอป หรือที่ผู้ใช้แตะจากแถบแจ้งเตือน
  void _startPushListener() {
    _pushSubscription?.cancel();
    _pushSubscription = PushService.onMessage.listen(_handlePush);
  }

  void _handlePush(RemoteMessage message) {
    final data = message.data;
    final type = data['type'] as String?;
    // เหตุการณ์ใหม่ได้จาก stream ของ Firestore อยู่แล้ว (มีข้อมูลครบ ใช้นำทางบนแผนที่ได้)
    if (type == 'incident') return;
    // ไม่แจ้งเตือนสิ่งที่ตัวเองทำ
    final actorUid = data['actorUid'] as String?;
    if (actorUid != null && actorUid == FirebaseAuth.instance.currentUser?.uid) return;

    final now = DateTime.now();
    final id = data['notifId'] as String? ??
        'push_${message.messageId ?? now.millisecondsSinceEpoch}';
    if (_deletedIds.contains(id) || _notifications.any((n) => n.id == id)) return;

    final title = message.notification?.title ?? '';
    final body = message.notification?.body ?? '';
    final (NotificationType nType, IconData icon, Color color) = switch (type) {
      'like' => (NotificationType.like, Icons.favorite_rounded, const Color(0xFFE74C3C)),
      'comment' => (NotificationType.comment, Icons.chat_bubble_rounded, const Color(0xFF3498DB)),
      _ => (NotificationType.system, Icons.notifications_rounded, const Color(0xFFE84200)),
    };

    final notif = AppNotification(
      id: id,
      type: nType,
      titleTh: data['titleTh'] as String? ?? title,
      titleEn: data['titleEn'] as String? ?? title,
      subtitleTh: data['bodyTh'] as String? ?? body,
      subtitleEn: data['bodyEn'] as String? ?? body,
      timestamp: message.sentTime ?? now,
      isRead: _readIds.contains(id),
      icon: icon,
      iconColor: color,
      activityId: data['activityId'] as String?,
    );
    _notifications.insert(0, notif);
    _sortNotifications();
    triggerBanner(notif);
    notifyListeners();
  }

  /// แสดง In-App Floating Heads-up Banner
  void triggerBanner(AppNotification notification) {
    _bannerTimer?.cancel();
    _bannerNotification = notification;
    _showBanner = true;
    notifyListeners();

    // ซ่อนแบนเนอร์อัตโนมัติหลังจาก 5 วินาที
    _bannerTimer = Timer(const Duration(milliseconds: 5500), () {
      _showBanner = false;
      notifyListeners();
    });
  }

  /// ปิดแบนเนอร์ด้วยมือ
  void dismissBanner() {
    _bannerTimer?.cancel();
    _showBanner = false;
    notifyListeners();
  }

  /// แจ้งเตือนเมื่อจบการวิ่งสำเร็จ
  void notifyRunCompleted(LastRunSummary summary) {
    final now = DateTime.now();
    final notif = AppNotification(
      id: 'run_${now.millisecondsSinceEpoch}',
      type: NotificationType.milestone,
      titleTh: '🎉 บันทึกการวิ่งสำเร็จ!',
      titleEn: '🎉 Activity Saved Successfully!',
      subtitleTh:
          'วิ่ง ${summary.distanceKm.toStringAsFixed(2)} km • ${summary.durationFormatted} • เพซ ${summary.avgPaceFormatted} /km',
      subtitleEn:
          'Run ${summary.distanceKm.toStringAsFixed(2)} km • ${summary.durationFormatted} • Pace ${summary.avgPaceFormatted} /km',
      timestamp: now,
      isRead: false,
      icon: Icons.check_circle_rounded,
      iconColor: const Color(0xFF2ECC71),
    );

    _notifications.insert(0, notif);
    triggerBanner(notif);
    notifyListeners();
  }

  /// แจ้งเตือนเมื่อมีคนถูกใจกิจกรรม
  void notifySocialLike({
    required String likerName,
    required String activityTitle,
    required String activityId,
  }) {
    final now = DateTime.now();
    final notif = AppNotification(
      id: 'like_${activityId}_${now.millisecondsSinceEpoch}',
      type: NotificationType.like,
      titleTh: '❤️ มีคนถูกใจกิจกรรมของคุณ',
      titleEn: '❤️ New Like on your activity',
      subtitleTh: '$likerName ได้ถูกใจ "$activityTitle"',
      subtitleEn: '$likerName liked "$activityTitle"',
      timestamp: now,
      isRead: false,
      icon: Icons.favorite_rounded,
      iconColor: const Color(0xFFE74C3C),
      activityId: activityId,
    );

    _notifications.insert(0, notif);
    triggerBanner(notif);
    notifyListeners();
  }

  /// แจ้งเตือนเมื่อมีคนแสดงความคิดเห็น
  void notifySocialComment({
    required String commenterName,
    required String commentText,
    required String activityTitle,
    required String activityId,
  }) {
    final now = DateTime.now();
    final notif = AppNotification(
      id: 'comment_${activityId}_${now.millisecondsSinceEpoch}',
      type: NotificationType.comment,
      titleTh: '💬 ความคิดเห็นใหม่ในกิจกรรม',
      titleEn: '💬 New Comment on your activity',
      subtitleTh: '$commenterName: "$commentText"',
      subtitleEn: '$commenterName: "$commentText"',
      timestamp: now,
      isRead: false,
      icon: Icons.chat_bubble_rounded,
      iconColor: const Color(0xFF3498DB),
      activityId: activityId,
    );

    _notifications.insert(0, notif);
    triggerBanner(notif);
    notifyListeners();
  }

  /// อัปเดตข้อมูลคุณภาพอากาศ และแจ้งเตือน Real-time หากผิดปกติ
  void updateAirQuality(AirQualityData air) {
    final today = '${DateTime.now().year}-${DateTime.now().month}-${DateTime.now().day}';
    if (_lastAirQualityNotifiedDate == today) return; // แจ้งเตือนวันละ 1 ครั้งเพื่อไม่ให้รบกวน

    final now = DateTime.now();
    AppNotification? notif;

    if (air.pm25 > 50) {
      notif = AppNotification(
        id: 'aqi_warning_$today',
        type: NotificationType.weather,
        titleTh: '⚠️ แจ้งเตือนคุณภาพอากาศ PM2.5 สูง',
        titleEn: '⚠️ Air Quality Warning: High PM2.5',
        subtitleTh:
            'ค่า PM2.5 อยู่ที่ ${air.pm25.toStringAsFixed(1)} µg/m³ (${air.aqiLabel}) แนะนำให้สวมหน้ากากหรือวิ่งในร่ม',
        subtitleEn:
            'PM2.5 level is ${air.pm25.toStringAsFixed(1)} µg/m³ (${air.aqiLabel}). Consider wearing a mask or running indoors.',
        timestamp: now,
        isRead: false,
        icon: Icons.warning_amber_rounded,
        iconColor: const Color(0xFFE67E22),
      );
    } else if (air.pm25 <= 25) {
      notif = AppNotification(
        id: 'aqi_good_$today',
        type: NotificationType.weather,
        titleTh: '🌱 อากาศดีวันนี้ เหมาะสำหรับวิ่ง!',
        titleEn: '🌱 Great Weather For Outdoor Running!',
        subtitleTh:
            'ค่า PM2.5 อยู่ที่ ${air.pm25.toStringAsFixed(1)} µg/m³ (${air.aqiLabel}) อากาศสดชื่น เหมาะแก่ออกกำลังกายกลางแจ้ง',
        subtitleEn:
            'PM2.5 level is ${air.pm25.toStringAsFixed(1)} µg/m³ (${air.aqiLabel}). Perfect conditions for outdoor running!',
        timestamp: now,
        isRead: false,
        icon: Icons.air_rounded,
        iconColor: const Color(0xFF2ECC71),
      );
    }

    if (notif != null) {
      _lastAirQualityNotifiedDate = today;
      _notifications.insert(0, notif);
      triggerBanner(notif);
      _savePreferences();
      notifyListeners();
    }
  }

  /// มาร์กว่าอ่านแล้ว
  void markAsRead(String id) {
    final index = _notifications.indexWhere((n) => n.id == id);
    if (index >= 0 && !_notifications[index].isRead) {
      _notifications[index].isRead = true;
      _readIds.add(id);
      _savePreferences();
      notifyListeners();
    }
  }

  /// มาร์กทั้งหมดว่าอ่านแล้ว
  void markAllAsRead() {
    for (final n in _notifications) {
      n.isRead = true;
      _readIds.add(n.id);
    }
    _savePreferences();
    notifyListeners();
  }

  /// ลบการแจ้งเตือน
  void removeNotification(String id) {
    _notifications.removeWhere((n) => n.id == id);
    _deletedIds.add(id);
    _savePreferences();
    notifyListeners();
  }

  /// เรียงลำดับตามเวลาล่าสุด
  void _sortNotifications() {
    _notifications.sort((a, b) => b.timestamp.compareTo(a.timestamp));
  }

  @override
  void dispose() {
    _bannerTimer?.cancel();
    _incidentSubscription?.cancel();
    _authSubscription?.cancel();
    _pushSubscription?.cancel();
    super.dispose();
  }
}
