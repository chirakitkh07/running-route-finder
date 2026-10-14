import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'feed_screen.dart';
import 'map_screen.dart';
import 'record_screen.dart';
import 'profile_screen.dart';
import '../models/last_run_summary.dart';
import '../models/route_data.dart';
import '../providers/language_provider.dart';
import '../providers/notification_provider.dart';
import '../models/app_notification.dart';
import '../widgets/in_app_notification_banner.dart';
import '../l10n/app_strings.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;
  RunningRoute? _pendingRoute;
  int _recordKey = 0;
  LastRunSummary? _lastRun; // ข้อมูลการวิ่งล่าสุด (หลัง stop)
  late List<Widget> _screens;

  @override
  void initState() {
    super.initState();
    _rebuildScreens();
  }

  /// เรียกทุกครั้งที่ต้องสร้าง screen list ใหม่ (route เปลี่ยน / run จบ)
  void _rebuildScreens() {
    _screens = [
      FeedScreen(
        lastRun: _lastRun,
        onNavigateToProfile: () => setState(() => _currentIndex = 3),
        onNavigateToMap: () => setState(() => _currentIndex = 1),
      ),
      MapScreen(onStartRun: (route) {
        setState(() {
          _pendingRoute = route;
          _recordKey++;
          _rebuildScreens();
          _currentIndex = 2;
        });
      }),
      _buildRecordScreen(),
      const ProfileScreen(),
    ];
  }

  /// รับข้อมูลสรุปการวิ่ง → update UI → navigate กลับหน้า Home
  void _onRunFinished(LastRunSummary summary) {
    // แจ้งเตือนความสำเร็จแบบ Real-time ทันที
    try {
      context.read<NotificationProvider>().notifyRunCompleted(summary);
    } catch (_) {}

    setState(() {
      _lastRun = summary;
      _pendingRoute = null;
      _rebuildScreens();
      _currentIndex = 0; // กลับหน้า Home อัตโนมัติ
    });
  }

  Widget _buildRecordScreen() => RecordScreen(
        key: ValueKey(_recordKey),
        selectedRoute: _pendingRoute,
        autoStart: _pendingRoute != null,
        onCancel: () => setState(() {
          _pendingRoute = null;
          _currentIndex = 1;
        }),
        onRunFinished: _onRunFinished,
      );

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      body: Stack(
        children: [
          IndexedStack(
            index: _currentIndex,
            children: _screens,
          ),
          InAppNotificationBanner(
            onTapNotification: (notif) {
              if (notif.incidentReport != null || notif.type == NotificationType.incident) {
                setState(() => _currentIndex = 1); // Map tab
              } else if (notif.type == NotificationType.route) {
                setState(() => _currentIndex = 1); // Map tab
              } else {
                setState(() => _currentIndex = 0); // Feed tab
              }
            },
          ),
        ],
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: cs.surface,
          border: Border(
            top: BorderSide(color: cs.outline, width: 0.5),
          ),
          boxShadow: [
            BoxShadow(
              color: isDark
                  ? Colors.black.withValues(alpha: 0.4)
                  : Colors.black.withValues(alpha: 0.08),
              blurRadius: 20,
              offset: const Offset(0, -3),
            ),
          ],
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Consumer<LanguageProvider>(
              builder: (context, lp, _) {
                final s = AppStrings(isThai: lp.isThai);
                return Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _buildNavItem(Icons.home_rounded, s.navHome, 0),
                    _buildNavItem(Icons.explore_rounded, s.navExplore, 1),
                    _buildRecordButton(),
                    _buildNavItem(Icons.bar_chart_rounded, s.navStats, 3),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNavItem(IconData icon, String label, int index) {
    final isSelected = _currentIndex == index;
    final cs = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: () => setState(() => _currentIndex = index),
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: isSelected
              ? cs.primary.withValues(alpha: 0.12)
              : Colors.transparent,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              color: isSelected ? cs.primary : cs.onSurface.withValues(alpha: 0.4),
              size: 26,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: isSelected ? cs.primary : cs.onSurface.withValues(alpha: 0.4),
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRecordButton() {
    return GestureDetector(
      onTap: () => setState(() => _currentIndex = 2),
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFFFF7043), Color(0xFFFC4C02), Color(0xFFD84315)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: const Color(0xFFFC4C02).withValues(alpha: 0.45),
              blurRadius: 14,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 32),
      ),
    );
  }
}

