// Service จัดการตรวจสอบการอัปเดตเวอร์ชันของแอปทั้งบน Web PWA และ Mobile
// - Web: เช็ค version.json และแสดงแถบ "มีเวอร์ชันใหม่" (ไม่แสดงระหว่างบันทึกการวิ่ง)
// - Force update: อ่าน settings/app_config ใน Firestore เพื่อบังคับอัปเดตหากต่ำกว่า min_version

import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'web_reload_stub.dart'
    if (dart.library.js_interop) 'web_reload_web.dart';

class ForceUpdateConfig {
  final String minVersion;
  final String latestApkUrl;
  final String message;

  const ForceUpdateConfig({
    required this.minVersion,
    required this.latestApkUrl,
    required this.message,
  });
}

class UpdateService with WidgetsBindingObserver {
  UpdateService._();
  static final UpdateService instance = UpdateService._();

  static const String currentAppVersion =
      String.fromEnvironment('APP_VERSION', defaultValue: '1.0.0+1');

  final ValueNotifier<bool> hasWebUpdateNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<ForceUpdateConfig?> forceUpdateNotifier =
      ValueNotifier<ForceUpdateConfig?>(null);

  bool _initialized = false;
  String? _latestWebVersion;
  String? get latestWebVersion => _latestWebVersion;

  /// ตัวบอกว่ากำลังวิ่งอยู่หรือไม่ (ถ้า true จะไม่แสดงแถบเตือนอัปเดต)
  static bool isRecordingRun = false;

  void init() {
    if (_initialized) return;
    _initialized = true;
    WidgetsBinding.instance.addObserver(this);
    checkForUpdates();
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      checkForUpdates();
    }
  }

  Future<void> checkForUpdates() async {
    await Future.wait([
      _checkFirestoreConfig(),
      if (kIsWeb) _checkWebVersionJson(),
    ]);
  }

  /// 1. เช็ค Force Update จาก Firestore collection('settings').doc('app_config')
  Future<void> _checkFirestoreConfig() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('settings')
          .doc('app_config')
          .get();

      if (!doc.exists || doc.data() == null) {
        forceUpdateNotifier.value = null;
        return;
      }

      final data = doc.data()!;
      final minVersion = data['min_version'] as String? ?? '1.0.0';
      final latestApkUrl = data['latest_apk_url'] as String? ?? '';
      final message = data['message'] as String? ??
          'กรุณาอัปเดตแอปพลิเคชันเป็นเวอร์ชันล่าสุดเพื่อใช้งานต่อ';

      if (_isVersionBelow(currentAppVersion, minVersion)) {
        forceUpdateNotifier.value = ForceUpdateConfig(
          minVersion: minVersion,
          latestApkUrl: latestApkUrl,
          message: message,
        );
      } else {
        forceUpdateNotifier.value = null;
      }
    } catch (e) {
      debugPrint('[UpdateService] checkFirestoreConfig error: $e');
      forceUpdateNotifier.value = null;
    }
  }

  /// 2. บน Web (PWA): ดึง `version.json?t=<timestamp>`
  Future<void> _checkWebVersionJson() async {
    if (!kIsWeb) return;
    try {
      final uri = Uri.parse('version.json?t=${DateTime.now().millisecondsSinceEpoch}');
      final res = await http.get(uri).timeout(const Duration(seconds: 6));
      if (res.statusCode == 200) {
        final data = json.decode(res.body) as Map<String, dynamic>;
        final serverVer = data['version'] as String?;
        if (serverVer != null && serverVer.isNotEmpty) {
          _latestWebVersion = serverVer;
          // ถ้าเวอร์ชันบน server ต่างจากเวอร์ชันปัจจุบัน
          if (_isDifferentVersion(currentAppVersion, serverVer)) {
            hasWebUpdateNotifier.value = true;
          }
        }
      }
    } catch (e) {
      debugPrint('[UpdateService] checkWebVersionJson error: $e');
    }
  }

  /// รีเฟรชหน้าเว็บและอัปเดต Service Worker
  Future<void> triggerWebReload() async {
    hasWebUpdateNotifier.value = false;
    await reloadWebPage();
  }

  /// เปรียบเทียบ semantic version
  static bool _isVersionBelow(String current, String min) {
    try {
      final curClean = current.split('+')[0];
      final minClean = min.split('+')[0];
      final curParts = curClean.split('.').map((e) => int.tryParse(e) ?? 0).toList();
      final minParts = minClean.split('.').map((e) => int.tryParse(e) ?? 0).toList();

      for (int i = 0; i < 3; i++) {
        final c = i < curParts.length ? curParts[i] : 0;
        final m = i < minParts.length ? minParts[i] : 0;
        if (c < m) return true;
        if (c > m) return false;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  static bool _isDifferentVersion(String current, String remote) {
    final curClean = current.split('+')[0].trim();
    final remClean = remote.split('+')[0].trim();
    return curClean != remClean;
  }
}
