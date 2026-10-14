import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Color;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../providers/language_provider.dart';

/// รับ push จาก FCM ตอนแอปอยู่เบื้องหลัง/ถูกปิด
///
/// ข้อความแบบ `notification` ระบบ Android แสดงให้เองอยู่แล้ว จึงไม่ต้องทำอะไรเพิ่ม
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  debugPrint('[Push] background message ${message.messageId}');
}

/// ระบบแจ้งเตือนแบบ Push (Firebase Cloud Messaging)
///
/// - เก็บ token ของเครื่องไว้ที่ `users/{uid}.fcmTokens` (+ `fcmLang`) ให้ตัวส่งฝั่งเซิร์ฟเวอร์
///   ส่งหาเจ้าของกิจกรรมเมื่อมีคนถูกใจ/แสดงความคิดเห็น
/// - สมัคร topic `incidents_th` / `incidents_en` ตามภาษาแอป สำหรับแจ้งเหตุการณ์ใหม่ถึงทุกคน
/// - ข้อความที่มาตอนเปิดแอปอยู่ ส่งต่อให้ [NotificationProvider] ผ่าน [onMessage]
///   (แสดงเป็นแบนเนอร์ในแอป ไม่ซ้ำกับแจ้งเตือนของระบบ)
class PushService {
  PushService._();

  static const String channelId = 'rrf_alerts';
  static const String _topicTh = 'incidents_th';
  static const String _topicEn = 'incidents_en';

  static final FlutterLocalNotificationsPlugin _local =
      FlutterLocalNotificationsPlugin();
  static final StreamController<RemoteMessage> _messages =
      StreamController<RemoteMessage>.broadcast();

  static bool _initialized = false;
  static String? _uid;
  static String? _token;
  static bool? _subscribedThai;
  static StreamSubscription<String>? _tokenRefreshSub;

  /// ข้อความ push ที่เข้ามาตอนแอปเปิดอยู่ หรือที่ผู้ใช้แตะเปิดจากแถบแจ้งเตือน
  static Stream<RemoteMessage> get onMessage => _messages.stream;

  /// ตรวจสอบว่าระบบรองรับ push notification หรือไม่
  /// บน Web รองรับผ่าน FCM (Service Worker)
  /// บน Mobile รองรับผ่าน Native FCM + flutter_local_notifications
  static bool get _supported =>
      kIsWeb ||
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  /// แสดงแจ้งเตือนบนแถบแจ้งเตือนของโทรศัพท์ (ใช้ตอนแอปเปิดอยู่ ซึ่ง FCM ไม่แสดงให้เอง)
  /// บน Web จะไม่ใช้ flutter_local_notifications
  static Future<void> showSystemNotification({
    required String tag,
    required String title,
    required String body,
  }) async {
    if (kIsWeb || !_supported) return;
    await init();
    try {
      await _local.show(
        id: 0,
        title: title,
        body: body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            channelId,
            'Running Route Finder',
            channelDescription: 'Incident, like and comment alerts',
            importance: Importance.high,
            priority: Priority.high,
            tag: tag,
            color: const Color(0xFFE84200),
            styleInformation: BigTextStyleInformation(body),
          ),
          iOS: const DarwinNotificationDetails(),
        ),
        payload: tag,
      );
    } catch (e) {
      debugPrint('[Push] showSystemNotification error: $e');
    }
  }

  /// ลบแจ้งเตือนบนแถบแจ้งเตือนที่แสดงด้วย [showSystemNotification] (tag เดียวกัน)
  static Future<void> cancelSystemNotification(String tag) async {
    if (kIsWeb || !_supported) return;
    try {
      await _local.cancel(id: 0, tag: tag);
    } catch (e) {
      debugPrint('[Push] cancelSystemNotification error: $e');
    }
  }

  /// เรียกครั้งเดียวหลัง Firebase.initializeApp
  static Future<void> init() async {
    if (_initialized || !_supported) return;
    _initialized = true;
    try {
      if (!kIsWeb) {
        await _local.initialize(
          settings: const InitializationSettings(
            android: AndroidInitializationSettings('@mipmap/ic_launcher'),
            iOS: DarwinInitializationSettings(),
          ),
        );
        await _local
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>()
            ?.createNotificationChannel(
              const AndroidNotificationChannel(
                channelId,
                'Running Route Finder',
                description: 'Incident, like and comment alerts',
                importance: Importance.high,
              ),
            );
      }

      FirebaseMessaging.onMessage.listen(_messages.add);
      FirebaseMessaging.onMessageOpenedApp.listen(_messages.add);
      final initial = await FirebaseMessaging.instance.getInitialMessage();
      if (initial != null) {
        // รอให้ NotificationProvider subscribe ก่อน
        Future.delayed(const Duration(seconds: 2), () => _messages.add(initial));
      }
    } catch (e) {
      debugPrint('[Push] init error: $e');
    }
  }

  /// ขอสิทธิ์ + บันทึก token ของผู้ใช้ที่ล็อกอินอยู่
  /// บน Web: ถ้ายังไม่ได้กดเปิดสิทธิ์ หรือไม่ได้ request จาก user gesture จะไม่บังคับขอทันทีเพื่อป้องกัน browser block
  static Future<void> registerUser(String uid, {bool userInitiated = false}) async {
    if (!_supported) return;
    await init();
    _uid = uid;

    // กฎสำหรับ Web: ถ้าไม่ได้เป็นการกดจากผู้ใช้โดยตรง (userInitiated == false)
    // ให้เช็คสถานะก่อน ถ้ายังไม่เคยอนุญาต (notDetermined) ห้าม popup กวนใจผู้ใช้ตอนเปิดแอป
    if (kIsWeb && !userInitiated) {
      try {
        final currentSettings = await FirebaseMessaging.instance.getNotificationSettings();
        if (currentSettings.authorizationStatus != AuthorizationStatus.authorized &&
            currentSettings.authorizationStatus != AuthorizationStatus.provisional) {
          debugPrint('[Push Web] skipping prompt on startup; wait for user action');
          return;
        }
      } catch (e) {
        debugPrint('[Push Web] getNotificationSettings error: $e');
        return;
      }
    }

    try {
      final settings = await FirebaseMessaging.instance.requestPermission();
      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        debugPrint('[Push] permission denied');
        return;
      }
      const vapidKey = String.fromEnvironment('VAPID_KEY');
      final token = await FirebaseMessaging.instance.getToken(
        vapidKey: (kIsWeb && vapidKey.isNotEmpty) ? vapidKey : null,
      );
      if (token != null) await _saveToken(token);

      _tokenRefreshSub ??=
          FirebaseMessaging.instance.onTokenRefresh.listen((t) async {
        final old = _token;
        await _saveToken(t);
        if (old != null && old != t && _uid != null) {
          await _userDoc(_uid!).set({
            'fcmTokens': FieldValue.arrayRemove([old]),
          }, SetOptions(merge: true));
        }
      });

      await syncLanguage();
    } catch (e) {
      debugPrint('[Push] registerUser error: $e');
    }
  }

  /// เรียกเมื่อเปลี่ยนภาษา — ย้าย topic และอัปเดตภาษาที่เซิร์ฟเวอร์ใช้ส่งหาเรา
  static Future<void> syncLanguage() async {
    if (!_supported || _uid == null) return;
    final thai = LanguageProvider.isThaiNow;
    if (_subscribedThai == thai) return;
    try {
      final fm = FirebaseMessaging.instance;
      await fm.subscribeToTopic(thai ? _topicTh : _topicEn);
      await fm.unsubscribeFromTopic(thai ? _topicEn : _topicTh);
      _subscribedThai = thai;
      await _userDoc(_uid!).set({'fcmLang': thai ? 'th' : 'en'},
          SetOptions(merge: true));
    } catch (e) {
      debugPrint('[Push] syncLanguage error: $e');
    }
  }

  /// เรียกก่อนออกจากระบบ — เลิกส่งแจ้งเตือนของบัญชีนี้มาที่เครื่องนี้
  static Future<void> unregisterUser() async {
    if (!_supported || _uid == null) return;
    final uid = _uid!;
    _uid = null;
    try {
      if (_token != null) {
        await _userDoc(uid).set({
          'fcmTokens': FieldValue.arrayRemove([_token]),
        }, SetOptions(merge: true));
      }
      final fm = FirebaseMessaging.instance;
      await fm.unsubscribeFromTopic(_topicTh);
      await fm.unsubscribeFromTopic(_topicEn);
      _subscribedThai = null;
    } catch (e) {
      debugPrint('[Push] unregisterUser error: $e');
    }
  }

  static Future<void> _saveToken(String token) async {
    _token = token;
    if (_uid == null) return;
    await _userDoc(_uid!).set({
      'fcmTokens': FieldValue.arrayUnion([token]),
      'fcmUpdatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    debugPrint('[Push] token saved for $_uid');
  }

  static DocumentReference<Map<String, dynamic>> _userDoc(String uid) =>
      FirebaseFirestore.instance.collection('users').doc(uid);
}
