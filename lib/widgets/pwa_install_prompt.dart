import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// วิดเจ็ตแบนเนอร์แนะนำการติดตั้ง PWA
///
/// - ตรวจสอบว่ารันบน Web (kIsWeb) หรือไม่
/// - ถ้าผู้ใช้อยู่ในโหมด Standalone (ติดตั้งเป็น PWA แล้ว) จะไม่แสดง
/// - ถ้าผู้ใช้เคยกดปิด (dismiss) ไปแล้ว จะไม่แสดงซ้ำ
/// - บน iOS Safari: แสดงคำแนะนำการแตะปุ่ม "แชร์" -> "เพิ่มไปยังหน้าจอโฮม"
/// - บน Android / Chrome Desktop: แสดงปุ่มติดตั้ง
class PwaInstallPrompt extends StatefulWidget {
  const PwaInstallPrompt({super.key});

  @override
  State<PwaInstallPrompt> createState() => _PwaInstallPromptState();
}

class _PwaInstallPromptState extends State<PwaInstallPrompt> {
  static const String _prefDismissedKey = 'pwa_install_prompt_dismissed';
  bool _isVisible = false;
  bool _isIos = false;

  @override
  void initState() {
    super.initState();
    _checkVisibility();
  }

  Future<void> _checkVisibility() async {
    if (!kIsWeb) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final dismissed = prefs.getBool(_prefDismissedKey) ?? false;
      if (dismissed) return;

      // ตรวจสอบแพลตฟอร์มว่าเข้าจาก iOS หรือเบราว์เซอร์อื่น
      final isIosPlatform = defaultTargetPlatform == TargetPlatform.iOS;

      if (mounted) {
        setState(() {
          _isIos = isIosPlatform;
          _isVisible = true;
        });
      }
    } catch (_) {}
  }

  Future<void> _dismiss() async {
    setState(() => _isVisible = false);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefDismissedKey, true);
    } catch (_) {}
  }

  void _showIosInstructions() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      backgroundColor: const Color(0xFF1E1E1E),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                const Row(
                  children: [
                    Icon(Icons.add_to_home_screen_rounded, color: Color(0xFFFC4C02), size: 28),
                    SizedBox(width: 12),
                    Text(
                      'ติดตั้งบนหน้าจอ iPhone',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _buildStep(
                  number: '1',
                  icon: Icons.ios_share_rounded,
                  text: 'แตะปุ่ม "แชร์" (Share) ที่แถบเมนูด้านล่างของ Safari',
                ),
                const SizedBox(height: 12),
                _buildStep(
                  number: '2',
                  icon: Icons.add_box_outlined,
                  text: 'เลื่อนลงมาแล้วเลือก "เพิ่มไปยังหน้าจอโฮม" (Add to Home Screen)',
                ),
                const SizedBox(height: 12),
                _buildStep(
                  number: '3',
                  icon: Icons.check_circle_outline_rounded,
                  text: 'แตะ "เพิ่ม" (Add) เพื่อเปิดใช้งานแบบเต็มจอเหมือนแอปจริง',
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _dismiss();
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFC4C02),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: const Text('เข้าใจแล้ว', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildStep({required String number, required IconData icon, required String text}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 26,
          height: 26,
          decoration: const BoxDecoration(
            color: Color(0xFF2C2C2C),
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Text(
            number,
            style: const TextStyle(
              color: Color(0xFFFC4C02),
              fontSize: 13,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Icon(icon, size: 20, color: Colors.white70),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(fontSize: 14, color: Colors.white70, height: 1.35),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_isVisible) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFFC4C02).withValues(alpha: 0.35)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFFFC4C02).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.install_mobile_rounded,
              color: Color(0xFFFC4C02),
              size: 22,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'ติดตั้งแอป Running Finder',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                Text(
                  _isIos
                      ? 'เพิ่มลงหน้าจอโฮมเพื่อใช้งานเต็มจอ'
                      : 'ติดตั้งลงอุปกรณ์เพื่อเปิดได้สะดวกรวดเร็ว',
                  style: const TextStyle(color: Colors.white60, fontSize: 11),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: _isIos ? _showIosInstructions : _dismiss,
            style: TextButton.styleFrom(
              backgroundColor: const Color(0xFFFC4C02),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: Text(
              _isIos ? 'ดูวิธี' : 'ติดตั้ง',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 18, color: Colors.white54),
            onPressed: _dismiss,
            splashRadius: 18,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }
}
