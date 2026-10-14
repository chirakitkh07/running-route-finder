import 'package:url_launcher/url_launcher.dart';
import 'safety_score_engine.dart';
import '../l10n/tr.dart';

class SafetyService {
  /// โทรหาเบอร์ฉุกเฉิน
  static Future<void> callNumber(String phone) async {
    final uri = Uri.parse('tel:$phone');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  /// ส่ง SMS พร้อม GPS link
  static Future<void> sendSOSSms(
      String phone, double lat, double lon, String runnerName) async {
    final mapsLink = 'https://maps.google.com/?q=$lat,$lon';
    final msg = Uri.encodeComponent(
      tr('🆘 SOS: $runnerName ต้องการความช่วยเหลือ!\n', '🆘 SOS: $runnerName needs help!\n') +
      tr('ตำแหน่งปัจจุบัน: $mapsLink\n', 'Current location: $mapsLink\n') +
      tr('ส่งโดยแอป Running Route Finder', 'Sent from the Running Route Finder app'),
    );
    final uri = Uri.parse('sms:$phone?body=$msg');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  /// แชร์ตำแหน่ง live ผ่าน Share Sheet
  static Future<void> shareLocation(double lat, double lon) async {
    final mapsLink = 'https://maps.google.com/?q=$lat,$lon';
    final uri = Uri.parse(
      'https://wa.me/?text=${Uri.encodeComponent('📍 ติดตามฉันได้ที่: $mapsLink')}',
    );
    // fallback to share maps link directly via url
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      final mapsUri = Uri.parse(mapsLink);
      if (await canLaunchUrl(mapsUri)) {
        await launchUrl(mapsUri, mode: LaunchMode.externalApplication);
      }
    }
  }

  /// คำนวณ safety score ตามเวลา — สมการที่ (3.2) S = S_base × T(t)
  /// T(t) = 1.0 กลางวัน, 0.7 กลางคืน (21:00–05:59)
  static int getTimedSafetyScore(int baseScore, {DateTime? now}) {
    final t = SafetyScoreEngine.timeFactor(now);
    return (baseScore * t).round().clamp(0, 100);
  }

  /// ตรวจสอบว่าควรแจ้งเตือนความปลอดภัยหรือไม่ (UC-13)
  /// แจ้งเตือนเมื่อคะแนนหลังปรับเวลาอยู่ในระดับเสี่ยงสูง (0–39) ตามตารางที่ 3.16
  static bool shouldWarn(int baseScore, {DateTime? now}) {
    final effective = getTimedSafetyScore(baseScore, now: now);
    return SafetyScoreEngine.shouldWarn(effective);
  }
}
