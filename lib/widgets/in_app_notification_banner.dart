import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_notification.dart';
import '../providers/notification_provider.dart';
import '../providers/language_provider.dart';
import 'package:demo20426/providers/theme_provider.dart';

/// Floating Heads-Up Banner ที่แสดงการแจ้งเตือน Real-time บนหัวหน้าจอ
class InAppNotificationBanner extends StatelessWidget {
  final Function(AppNotification notif)? onTapNotification;

  const InAppNotificationBanner({
    super.key,
    this.onTapNotification,
  });

  @override
  Widget build(BuildContext context) {
    final notifProvider = context.watch<NotificationProvider>();
    final notif = notifProvider.bannerNotification;
    final isVisible = notifProvider.showBanner && notif != null;
    final isThai = context.watch<LanguageProvider>().isThai;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return AnimatedPositioned(
      duration: const Duration(milliseconds: 380),
      curve: Curves.easeOutBack,
      top: isVisible ? MediaQuery.of(context).padding.top + 8 : -140,
      left: 12,
      right: 12,
      child: notif == null
          ? const SizedBox.shrink()
          : Material(
              color: Colors.transparent,
              child: GestureDetector(
                onVerticalDragEnd: (details) {
                  // ปัดขึ้นเพื่อปิดแบนเนอร์
                  if (details.primaryVelocity != null && details.primaryVelocity! < 0) {
                    notifProvider.dismissBanner();
                  }
                },
                child: Container(
                  decoration: BoxDecoration(
                    color: isDark
                        ? context.pal.surface2
                        : context.pal.surface,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: notif.iconColor.withValues(alpha: 0.35),
                      width: 1.5,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: notif.iconColor.withValues(alpha: isDark ? 0.25 : 0.18),
                        blurRadius: 24,
                        offset: const Offset(0, 8),
                      ),
                      BoxShadow(
                        color: Colors.black.withValues(alpha: isDark ? 0.4 : 0.08),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: InkWell(
                      onTap: () {
                        notifProvider.markAsRead(notif.id);
                        notifProvider.dismissBanner();
                        onTapNotification?.call(notif);
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            // Icon Box พร้อม Pulse Dot
                            Stack(
                              clipBehavior: Clip.none,
                              children: [
                                Container(
                                  width: 44,
                                  height: 44,
                                  decoration: BoxDecoration(
                                    color: notif.iconColor.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  child: Icon(
                                    notif.icon,
                                    color: notif.iconColor,
                                    size: 24,
                                  ),
                                ),
                                Positioned(
                                  top: -2,
                                  right: -2,
                                  child: Container(
                                    width: 10,
                                    height: 10,
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFFC4C02),
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: isDark ? context.pal.surface2 : context.pal.surface,
                                        width: 1.5,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(width: 12),

                            // Text Content
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          notif.getTitle(isThai),
                                          style: TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w700,
                                            color: cs.onSurface,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        isThai ? 'เมื่อกี้' : 'Now',
                                        style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w600,
                                          color: const Color(0xFFFC4C02),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    notif.getSubtitle(isThai),
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: cs.onSurface.withValues(alpha: 0.75),
                                      height: 1.3,
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),

                            // Action button or close
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                              icon: Icon(
                                Icons.close_rounded,
                                size: 18,
                                color: cs.onSurface.withValues(alpha: 0.45),
                              ),
                              onPressed: () => notifProvider.dismissBanner(),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}
