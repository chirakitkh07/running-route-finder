import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─── Color Tokens ─────────────────────────────────────────────────────────────

class AppColors {
  // Shared accent
  static const primary    = Color(0xFFFC4C02);
  static const primaryLt  = Color(0xFFFF6B35);
  static const error      = Color(0xFFE53935);
  static const success    = Color(0xFF2ECC71);
  static const warning    = Color(0xFFF39C12);

  // Dark palette
  static const dkBg       = Color(0xFF0D0D0D);
  static const dkSurface  = Color(0xFF1A1A1A);
  static const dkSurface2 = Color(0xFF242424);
  static const dkBorder   = Color(0xFF383838);
  static const dkText     = Color(0xFFFFFFFF);
  static const dkTextSub  = Color(0xFFBDBDBD);
  static const dkTextMute = Color(0xFF8C8C8C);

  // Light palette
  static const ltBg       = Color(0xFFF5F5F0);
  static const ltSurface  = Color(0xFFFFFFFF);
  static const ltSurface2 = Color(0xFFF0F0EC);
  static const ltBorder   = Color(0xFFDADAD5);
  static const ltText     = Color(0xFF1A1A1A);
  static const ltTextSub  = Color(0xFF4A4A4A);
  static const ltTextMute = Color(0xFF737373);
}

// ─── Palette (สีกลางตามธีม) ────────────────────────────────────────────────────

/// ชุดสีพื้น/ตัวอักษรตามธีมปัจจุบัน — ทุกหน้าใช้ผ่าน `context.pal`
/// (สีเน้น เช่น ส้ม/เขียว/แดง ใช้ค่าเดิมได้ทั้งสองธีม)
class AppPalette {
  final bool isDark;

  /// พื้นหลังหน้า
  final Color bg;

  /// พื้นการ์ด / แผ่นลอย / dialog
  final Color surface;

  /// พื้นชั้นใน (ช่องกรอก, ชิป, แถวย่อยในการ์ด)
  final Color surface2;
  final Color border;

  /// ตัวอักษรหลัก / รอง / จาง (จางสุดยังอ่านได้บนพื้น [surface])
  final Color text;
  final Color textSub;
  final Color textMute;

  /// เงาใต้การ์ด/แผ่นลอย
  final Color shadow;

  const AppPalette._({
    required this.isDark,
    required this.bg,
    required this.surface,
    required this.surface2,
    required this.border,
    required this.text,
    required this.textSub,
    required this.textMute,
    required this.shadow,
  });

  static const dark = AppPalette._(
    isDark: true,
    bg: AppColors.dkBg,
    surface: AppColors.dkSurface,
    surface2: AppColors.dkSurface2,
    border: AppColors.dkBorder,
    text: AppColors.dkText,
    textSub: AppColors.dkTextSub,
    textMute: AppColors.dkTextMute,
    shadow: Color(0x73000000),
  );

  static const light = AppPalette._(
    isDark: false,
    bg: AppColors.ltBg,
    surface: AppColors.ltSurface,
    surface2: AppColors.ltSurface2,
    border: AppColors.ltBorder,
    text: AppColors.ltText,
    textSub: AppColors.ltTextSub,
    textMute: AppColors.ltTextMute,
    shadow: Color(0x24000000),
  );

  static AppPalette of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;
}

extension AppPaletteContext on BuildContext {
  AppPalette get pal => AppPalette.of(this);
}

// ─── ThemeProvider ────────────────────────────────────────────────────────────

class ThemeProvider extends ChangeNotifier {
  static const _prefKey = 'app_theme_dark';

  bool _isDark = true;

  bool get isDark => _isDark;

  ThemeProvider() {
    _loadFromPrefs();
  }

  Future<void> _loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    _isDark = prefs.getBool(_prefKey) ?? true;
    notifyListeners();
  }

  Future<void> toggleTheme() async {
    _isDark = !_isDark;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKey, _isDark);
  }

  ThemeData get currentTheme => _isDark ? darkTheme : lightTheme;

  // ─── Dark ThemeData ──────────────────────────────────────────────────────

  ThemeData get darkTheme {
    return ThemeData.dark().copyWith(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: AppColors.dkBg,
      colorScheme: const ColorScheme.dark(
        primary: AppColors.primary,
        secondary: AppColors.primaryLt,
        surface: AppColors.dkSurface,
        onPrimary: Colors.white,
        onSurface: AppColors.dkText,
        onSecondary: Colors.white,
        outline: AppColors.dkBorder,
        error: AppColors.error,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.dkBg,
        elevation: 0,
        centerTitle: false,
        surfaceTintColor: Colors.transparent,
        iconTheme: const IconThemeData(color: AppColors.dkText),
        titleTextStyle: GoogleFonts.inter(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.dkText),
      ),
      cardTheme: CardThemeData(
        color: AppColors.dkSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppColors.dkBorder),
        ),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: AppColors.dkSurface,
        selectedItemColor: AppColors.primary,
        unselectedItemColor: AppColors.dkTextMute,
        type: BottomNavigationBarType.fixed,
        showUnselectedLabels: true,
        elevation: 0,
      ),
      dividerColor: AppColors.dkBorder,
      dialogTheme: DialogThemeData(
        backgroundColor: AppColors.dkSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.dkSurface2,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.dkBorder)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.dkBorder)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.primary, width: 2)),
        hintStyle: const TextStyle(color: AppColors.dkTextMute),
      ),
      textTheme: _buildTextTheme(AppColors.dkText, AppColors.dkTextSub),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? AppColors.primary : AppColors.dkTextMute),
        trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? AppColors.primary.withValues(alpha: 0.4) : AppColors.dkBorder),
      ),
    );
  }

  // ─── Light ThemeData ─────────────────────────────────────────────────────

  ThemeData get lightTheme {
    return ThemeData.light().copyWith(
      brightness: Brightness.light,
      scaffoldBackgroundColor: AppColors.ltBg,
      colorScheme: const ColorScheme.light(
        primary: AppColors.primary,
        secondary: AppColors.primaryLt,
        surface: AppColors.ltSurface,
        onPrimary: Colors.white,
        onSurface: AppColors.ltText,
        onSecondary: Colors.white,
        outline: AppColors.ltBorder,
        error: AppColors.error,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.ltSurface,
        elevation: 0,
        centerTitle: false,
        surfaceTintColor: Colors.transparent,
        iconTheme: const IconThemeData(color: AppColors.ltText),
        titleTextStyle: GoogleFonts.inter(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.ltText),
      ),
      cardTheme: CardThemeData(
        color: AppColors.ltSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppColors.ltBorder),
        ),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: AppColors.ltSurface,
        selectedItemColor: AppColors.primary,
        unselectedItemColor: AppColors.ltTextMute,
        type: BottomNavigationBarType.fixed,
        showUnselectedLabels: true,
        elevation: 0,
      ),
      dividerColor: AppColors.ltBorder,
      dialogTheme: DialogThemeData(
        backgroundColor: AppColors.ltSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.ltSurface2,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.ltBorder)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.ltBorder)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.primary, width: 2)),
        hintStyle: const TextStyle(color: AppColors.ltTextMute),
      ),
      textTheme: _buildTextTheme(AppColors.ltText, AppColors.ltTextSub),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? AppColors.primary : AppColors.ltTextMute),
        trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? AppColors.primary.withValues(alpha: 0.4) : AppColors.ltBorder),
      ),
    );
  }

  TextTheme _buildTextTheme(Color primary, Color secondary) {
    return TextTheme(
      headlineLarge: GoogleFonts.inter(fontWeight: FontWeight.w800, color: primary),
      headlineMedium: GoogleFonts.inter(fontWeight: FontWeight.w700, color: primary),
      headlineSmall: GoogleFonts.inter(fontWeight: FontWeight.w600, color: primary),
      bodyLarge: GoogleFonts.inter(color: primary, fontSize: 16),
      bodyMedium: GoogleFonts.inter(color: primary, fontSize: 14),
      bodySmall: GoogleFonts.inter(color: secondary, fontSize: 12),
      labelLarge: GoogleFonts.inter(fontWeight: FontWeight.w600, color: primary),
      labelMedium: GoogleFonts.inter(fontWeight: FontWeight.w500, color: secondary),
    );
  }
}
