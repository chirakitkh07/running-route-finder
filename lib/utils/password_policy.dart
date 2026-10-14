import '../l10n/tr.dart';

/// มาตรฐานรหัสผ่านของแอป (อิงแนวทาง OWASP / NIST SP 800-63B)
/// - ยาว 8–64 ตัวอักษร
/// - มีตัวพิมพ์เล็ก ตัวพิมพ์ใหญ่ ตัวเลข และอักขระพิเศษ อย่างละ 1 ตัว
/// - ไม่มีช่องว่าง, ไม่ใช่รหัสที่ใช้กันบ่อย, ไม่มีชื่อหรืออีเมลของผู้ใช้อยู่ในรหัส
class PasswordPolicy {
  static const int minLength = 8;
  static const int maxLength = 64;

  /// รหัสผ่านยอดนิยมที่ถูกเดาง่าย (เทียบแบบไม่สนตัวพิมพ์เล็ก/ใหญ่)
  static const Set<String> _common = {
    'password', 'password1', 'password123', 'passw0rd', 'p@ssw0rd', 'p@ssword1',
    '12345678', '123456789', '1234567890', '87654321', '11111111', '00000000',
    'qwerty123', 'qwertyuiop', '1q2w3e4r', '1qaz2wsx', 'abc12345', 'abcd1234',
    'iloveyou', 'admin123', 'welcome1', 'letmein1', 'sunshine', 'football',
    'aa123456', 'asdf1234', 'zxcvbnm1', 'qwer1234', 'test1234', 'changeme',
  };

  static bool hasLower(String p) => RegExp(r'[a-z]').hasMatch(p);
  static bool hasUpper(String p) => RegExp(r'[A-Z]').hasMatch(p);
  static bool hasDigit(String p) => RegExp(r'[0-9]').hasMatch(p);
  static bool hasSpecial(String p) =>
      RegExp(r'''[!@#$%^&*()_+\-=\[\]{};':"\\|,.<>/?`~]''').hasMatch(p);
  static bool hasLength(String p) =>
      p.length >= minLength && p.length <= maxLength;
  static bool hasWhitespace(String p) => RegExp(r'\s').hasMatch(p);

  static bool isCommon(String p) => _common.contains(p.toLowerCase());

  /// รหัสผ่านมีชื่อผู้ใช้หรือส่วนหน้าของอีเมล (ยาว ≥ 3 ตัว) อยู่ข้างใน
  static bool containsPersonalInfo(String p, {String? email, String? name}) {
    final lower = p.toLowerCase();
    final parts = <String>[
      if (email != null && email.contains('@')) email.split('@').first,
      if (name != null) ...name.split(RegExp(r'\s+')),
    ];
    for (final part in parts) {
      final s = part.trim().toLowerCase();
      if (s.length >= 3 && lower.contains(s)) return true;
    }
    return false;
  }

  /// คืนข้อความผิดพลาดข้อแรกที่พบ หรือ null ถ้าผ่านทุกข้อ
  static String? validate(String? password, {String? email, String? name}) {
    final p = password ?? '';
    if (p.isEmpty) return tr('กรุณากรอกรหัสผ่าน', 'Please enter your password');
    if (hasWhitespace(p)) {
      return tr('รหัสผ่านห้ามมีช่องว่าง', 'Password must not contain spaces');
    }
    if (p.length < minLength) {
      return tr('รหัสผ่านต้องมีอย่างน้อย $minLength ตัวอักษร',
          'Password must be at least $minLength characters');
    }
    if (p.length > maxLength) {
      return tr('รหัสผ่านยาวได้ไม่เกิน $maxLength ตัวอักษร',
          'Password must be at most $maxLength characters');
    }
    if (!hasLower(p) || !hasUpper(p)) {
      return tr('ต้องมีทั้งตัวพิมพ์เล็กและตัวพิมพ์ใหญ่ (a-z, A-Z)',
          'Must include both lowercase and uppercase letters');
    }
    if (!hasDigit(p)) return tr('ต้องมีตัวเลขอย่างน้อย 1 ตัว', 'Must include a number');
    if (!hasSpecial(p)) {
      return tr('ต้องมีอักขระพิเศษอย่างน้อย 1 ตัว เช่น ! @ # \$ %',
          'Must include a special character, e.g. ! @ # \$ %');
    }
    if (isCommon(p)) {
      return tr('รหัสผ่านนี้ถูกใช้บ่อยและเดาง่าย กรุณาตั้งใหม่',
          'This password is too common. Please choose another');
    }
    if (containsPersonalInfo(p, email: email, name: name)) {
      return tr('รหัสผ่านไม่ควรมีชื่อหรืออีเมลของคุณ',
          'Password must not contain your name or email');
    }
    return null;
  }

  /// ความแข็งแรง 0–4 สำหรับแถบแสดงผล (0 = ว่าง/อ่อนมาก, 4 = แข็งแรงมาก)
  static int strength(String p) {
    if (p.isEmpty) return 0;
    var classes = 0;
    if (hasLower(p)) classes++;
    if (hasUpper(p)) classes++;
    if (hasDigit(p)) classes++;
    if (hasSpecial(p)) classes++;
    if (p.length < minLength || isCommon(p)) return 1;
    if (classes <= 2) return 1;
    if (classes == 3) return 2;
    return p.length >= 12 ? 4 : 3;
  }
}

/// กันการเดารหัสผ่าน (brute force) ฝั่งแอป: ผิดครบ [freeAttempts] ครั้ง → ล็อก
/// 30 วินาที แล้วเพิ่มเป็น 2 เท่าทุกครั้งที่ผิดต่อ สูงสุด 15 นาที
/// (Firebase Auth ก็จำกัดฝั่งเซิร์ฟเวอร์อีกชั้นด้วย error `too-many-requests`)
class LoginThrottle {
  static const int freeAttempts = 5;
  static const Duration baseLock = Duration(seconds: 30);
  static const Duration maxLock = Duration(minutes: 15);

  static Duration lockFor(int failures) {
    if (failures < freeAttempts) return Duration.zero;
    final exp = (failures - freeAttempts).clamp(0, 10);
    final secs = baseLock.inSeconds * (1 << exp);
    return secs >= maxLock.inSeconds ? maxLock : Duration(seconds: secs);
  }
}
