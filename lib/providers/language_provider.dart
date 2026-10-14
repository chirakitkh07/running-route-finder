import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/push_service.dart';

/// Supported languages
enum AppLanguage { th, en }

/// Provides app-wide language toggle with persistence.
class LanguageProvider extends ChangeNotifier {
  static const _prefKey = 'app_language';

  AppLanguage _lang = AppLanguage.th;

  /// ภาษาปัจจุบันแบบ static — ให้ service/model ที่ไม่มี BuildContext ใช้ผ่าน [tr]
  static bool isThaiNow = true;

  AppLanguage get language => _lang;
  bool get isThai => _lang == AppLanguage.th;

  @override
  void notifyListeners() {
    isThaiNow = _lang == AppLanguage.th;
    PushService.syncLanguage();
    super.notifyListeners();
  }

  LanguageProvider() {
    _loadFromPrefs();
  }

  Future<void> _loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefKey);
    if (saved == 'en') {
      _lang = AppLanguage.en;
    } else {
      _lang = AppLanguage.th;
    }
    notifyListeners();
  }

  Future<void> toggleLanguage() async {
    _lang = _lang == AppLanguage.th ? AppLanguage.en : AppLanguage.th;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, _lang == AppLanguage.th ? 'th' : 'en');
  }

  Future<void> setLanguage(AppLanguage lang) async {
    if (_lang == lang) return;
    _lang = lang;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, lang == AppLanguage.th ? 'th' : 'en');
  }
}
