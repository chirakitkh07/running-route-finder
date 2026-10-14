import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';

/// การตั้งค่า URL สำหรับเชื่อมต่อ Backend API
///
/// รองรับการส่งค่าผ่าน `--dart-define=API_BASE_URL=https://your-api.com`
/// หากไม่กำหนด:
/// - บน Web: ใช้ localhost / 127.0.0.1:3000
/// - บน Android Device/Emulator: ใช้ 10.0.2.2:3000 สำหรับ Emulator หรือ 127.0.0.1
/// - บน iOS/Desktop: ใช้ 127.0.0.1:3000
class ApiConfig {
  ApiConfig._();

  static const String _definedBaseUrl = String.fromEnvironment('API_BASE_URL');

  /// URL หลักของ Backend API (เช่น 'http://localhost:3000' หรือค่าจาก --dart-define)
  static String get baseUrl {
    if (_definedBaseUrl.isNotEmpty) {
      return _definedBaseUrl.endsWith('/')
          ? _definedBaseUrl.substring(0, _definedBaseUrl.length - 1)
          : _definedBaseUrl;
    }

    if (kIsWeb) {
      return 'http://127.0.0.1:3000';
    }

    try {
      if (!kIsWeb && Platform.isAndroid) {
        return 'http://10.0.2.2:3000';
      }
    } catch (_) {}

    return 'http://127.0.0.1:3000';
  }

  /// รายการ Candidate URLs สำหรับกรณีต้องการ Fallback (เช่นใน Admin Dashboard)
  static List<String> get adminCandidateUrls {
    if (_definedBaseUrl.isNotEmpty) {
      final base = _definedBaseUrl.endsWith('/')
          ? _definedBaseUrl.substring(0, _definedBaseUrl.length - 1)
          : _definedBaseUrl;
      return ['$base/api/admin'];
    }

    if (kIsWeb) {
      return [
        'http://127.0.0.1:3000/api/admin',
        'http://localhost:3000/api/admin',
      ];
    }

    try {
      if (!kIsWeb && Platform.isAndroid) {
        return [
          'http://10.0.2.2:3000/api/admin',
          'http://127.0.0.1:3000/api/admin',
          'http://localhost:3000/api/admin',
        ];
      }
    } catch (_) {}

    return [
      'http://127.0.0.1:3000/api/admin',
      'http://localhost:3000/api/admin',
    ];
  }
}
