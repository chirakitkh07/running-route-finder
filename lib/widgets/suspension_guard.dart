import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../l10n/tr.dart';
import '../services/auth_service.dart';
import 'package:demo20426/providers/theme_provider.dart';

/// ตรวจสถานะบัญชีที่ผู้ดูแลระบบระงับ (Manage User Accounts)
///
/// ฟัง users/{uid}.suspended — ถ้าเป็น true จะแสดงหน้าแจ้งว่าบัญชีถูกระงับแทนแอป
/// ถ้าอ่านข้อมูลไม่ได้ / ยังไม่มีฟิลด์ / เป็นผู้ดูแลระบบ จะแสดงแอปตามปกติ (ไม่ขวางการใช้งานเดิม)
class SuspensionGuard extends StatefulWidget {
  final User user;
  final Widget child;
  const SuspensionGuard({super.key, required this.user, required this.child});

  @override
  State<SuspensionGuard> createState() => _SuspensionGuardState();
}

class _SuspensionGuardState extends State<SuspensionGuard> {
  late final Stream<DocumentSnapshot<Map<String, dynamic>>> _doc;

  @override
  void initState() {
    super.initState();
    _doc = FirebaseFirestore.instance.collection('users').doc(widget.user.uid).snapshots();
  }

  @override
  Widget build(BuildContext context) {
    if (AuthService.isUserAdmin(widget.user.email)) return widget.child;
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _doc,
      builder: (context, snap) {
        final data = snap.hasError ? null : snap.data?.data();
        if (data?['suspended'] != true) return widget.child;
        final reason = (data?['suspendReason'] ?? '').toString();
        final pal = context.pal;
        return Scaffold(
          backgroundColor: pal.bg,
          body: SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.block_rounded, size: 64, color: Color(0xFFE74C3C)),
                    const SizedBox(height: 16),
                    Text(tr('บัญชีนี้ถูกระงับการใช้งาน', 'This account has been suspended'),
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: pal.text)),
                    const SizedBox(height: 10),
                    Text(
                      reason.isNotEmpty
                          ? tr('เหตุผล: $reason', 'Reason: $reason')
                          : tr('กรุณาติดต่อผู้ดูแลระบบ', 'Please contact the administrator'),
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 14, color: pal.textSub),
                    ),
                    const SizedBox(height: 24),
                    ElevatedButton.icon(
                      onPressed: () => FirebaseAuth.instance.signOut(),
                      icon: const Icon(Icons.logout_rounded),
                      label: Text(tr('ออกจากระบบ', 'Sign out')),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFFC4C02),
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
