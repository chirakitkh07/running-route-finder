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
import '../services/update_service.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/foundation.dart';

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
    UpdateService.instance.init();
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

          // ─── Web Update Banner (แถบ "มีเวอร์ชันใหม่ – แตะเพื่ออัปเดต") ─────────
          if (kIsWeb && _currentIndex != 2)
            ValueListenableBuilder<bool>(
              valueListenable: UpdateService.instance.hasWebUpdateNotifier,
              builder: (context, hasUpdate, _) {
                if (!hasUpdate) return const SizedBox.shrink();
                return SafeArea(
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: Container(
                      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFFFC4C02), Color(0xFFFF6B35)],
                        ),
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFFFC4C02).withValues(alpha: 0.35),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.system_update_alt_rounded, color: Colors.white, size: 20),
                          const SizedBox(width: 10),
                          const Expanded(
                            child: Text(
                              'มีเวอร์ชันใหม่ – แตะเพื่ออัปเดต',
                              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                            ),
                          ),
                          ElevatedButton(
                            onPressed: () => UpdateService.instance.triggerWebReload(),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.white,
                              foregroundColor: const Color(0xFFFC4C02),
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                            child: const Text('อัปเดต', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),

          // ─── Force Update Dialog (บังคับอัปเดตหากเวอร์ชันต่ำกว่า min_version) ────
          ValueListenableBuilder<ForceUpdateConfig?>(
            valueListenable: UpdateService.instance.forceUpdateNotifier,
            builder: (context, forceConfig, _) {
              if (forceConfig == null) return const SizedBox.shrink();
              return Container(
                color: Colors.black.withValues(alpha: 0.85),
                alignment: Alignment.center,
                padding: const EdgeInsets.all(24),
                child: Material(
                  color: const Color(0xFF1E1E1E),
                  borderRadius: BorderRadius.circular(24),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.upgrade_rounded, color: Color(0xFFFC4C02), size: 48),
                        const SizedBox(height: 16),
                        const Text(
                          'จำเป็นต้องอัปเดตแอป',
                          style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          forceConfig.message,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.4),
                        ),
                        const SizedBox(height: 24),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: () async {
                              if (kIsWeb) {
                                await UpdateService.instance.triggerWebReload();
                              } else if (forceConfig.latestApkUrl.isNotEmpty) {
                                final uri = Uri.parse(forceConfig.latestApkUrl);
                                if (await canLaunchUrl(uri)) {
                                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                                }
                              }
                            },
                            icon: Icon(kIsWeb ? Icons.refresh_rounded : Icons.download_rounded),
                            label: Text(kIsWeb ? 'รีโหลดแอปเดี๋ยวนี้' : 'ดาวน์โหลดเวอร์ชันใหม่'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFFC4C02),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
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

