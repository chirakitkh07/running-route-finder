// Helper จัดการ Wake Lock สำหรับ Web PWA โดยไม่กระทบ Native
// รองรับทั้ง dart:io / Android / iOS / Web ด้วย conditional imports

import 'web_wake_lock_stub.dart'
    if (dart.library.js_interop) 'web_wake_lock_web.dart';

abstract class WebWakeLockHelper {
  /// ขอเปิด Screen Wake Lock (ป้องกันจอดับระหว่างบันทึกบนเบราว์เซอร์)
  static Future<void> requestWakeLock() => requestWebWakeLock();

  /// ปล่อย Screen Wake Lock เมื่อหยุดพักหรือจบกิจกรรม
  static Future<void> releaseWakeLock() => releaseWebWakeLock();
}
