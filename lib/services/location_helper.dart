import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import '../l10n/app_strings.dart';

/// ตัวจัดการสิทธิ์และการเปิดใช้งาน GPS (Location Service & Permissions)
class LocationHelper {
  /// ตรวจสอบและขอสิทธิ์การเข้าถึงตำแหน่ง GPS
  /// [showDialogs] ถ้าเป็น true จะแสดง Popup/Dialog คำอธิบายเมื่อผู้ใช้ปิด GPS หรือปฏิเสธสิทธิ์
  static Future<bool> checkAndRequestPermission({
    BuildContext? context,
    bool showDialogs = true,
  }) async {
    try {
      // 1. ตรวจสอบว่าเปิดบริการตำแหน่ง (Location Service/GPS) ในเครื่องหรือยัง
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (context != null && context.mounted && showDialogs) {
          await _showEnableGpsDialog(context);
        }
        return false;
      }

      // 2. ตรวจสอบสถานะ Permission ปัจจุบัน
      LocationPermission permission = await Geolocator.checkPermission();

      // ถ้ายังไม่เคยขอ หรือเคยปฏิเสธครั้งแรก ให้ขอสิทธิ์ผ่าน System Dialog ทันที
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          if (context != null && context.mounted && showDialogs) {
            final s = AppStrings.of(context);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Row(
                  children: [
                    const Icon(Icons.location_off, color: Colors.white, size: 20),
                    const SizedBox(width: 8),
                    Expanded(child: Text(s.gpsPermissionRequired)),
                  ],
                ),
                backgroundColor: const Color(0xFFE74C3C),
                behavior: SnackBarBehavior.floating,
                duration: const Duration(seconds: 4),
              ),
            );
          }
          return false;
        }
      }

      // 3. กรณีปฏิเสธถาวร (Don't ask again) ให้แสดง Dialog นำไปที่ App Settings
      if (permission == LocationPermission.deniedForever) {
        if (context != null && context.mounted && showDialogs) {
          await _showPermissionSettingsDialog(context);
        }
        return false;
      }

      return permission == LocationPermission.whileInUse ||
          permission == LocationPermission.always;
    } catch (e) {
      debugPrint('[LocationHelper] Error checking location permission: $e');
      return false;
    }
  }

  /// ตรวจสอบว่ามีสิทธิ์ GPS หรือไม่ (ไม่แสดง popup ใดๆ)
  static Future<bool> hasPermission() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return false;
      final permission = await Geolocator.checkPermission();
      return permission == LocationPermission.whileInUse ||
          permission == LocationPermission.always;
    } catch (_) {
      return false;
    }
  }

  /// Dialog แนะนำให้เปิด GPS ในระบบโทรศัพท์
  static Future<void> _showEnableGpsDialog(BuildContext context) async {
    final s = AppStrings.of(context);
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            const Icon(Icons.location_disabled_rounded, color: Color(0xFFFC4C02)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                s.pleaseEnableGps,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: Text(
          s.isThai
              ? 'กรุณาเปิดบริการตำแหน่งที่ตั้ง (GPS) ในโทรศัพท์ เพื่อให้แอปสามารถติดตามการวิ่งและค้นหาเส้นทางรอบตัวคุณได้'
              : 'Please enable Location Services (GPS) in your device settings to track your runs and find nearby routes.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(s.cancel, style: const TextStyle(color: Color(0xFF888888))),
          ),
          ElevatedButton.icon(
            onPressed: () async {
              Navigator.pop(ctx);
              await Geolocator.openLocationSettings();
            },
            icon: const Icon(Icons.settings_suggest_rounded, size: 18),
            label: Text(s.isThai ? 'เปิดการตั้งค่า GPS' : 'Open GPS Settings'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFC4C02),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ],
      ),
    );
  }

  /// Dialog แนะนำให้เปิดสิทธิ์ใน App Settings เมื่อถูกปฏิเสธถาวร
  static Future<void> _showPermissionSettingsDialog(BuildContext context) async {
    final s = AppStrings.of(context);
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            const Icon(Icons.location_off_rounded, color: Color(0xFFE74C3C)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                s.gpsBlocked,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: Text(s.gpsBlockedPrompt),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(s.cancel, style: const TextStyle(color: Color(0xFF888888))),
          ),
          ElevatedButton.icon(
            onPressed: () async {
              Navigator.pop(ctx);
              await Geolocator.openAppSettings();
            },
            icon: const Icon(Icons.settings, size: 18),
            label: Text(s.goToSettings),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFC4C02),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ],
      ),
    );
  }
}
