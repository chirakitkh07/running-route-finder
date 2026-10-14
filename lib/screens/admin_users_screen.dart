import 'package:flutter/material.dart';
import '../l10n/tr.dart';
import '../services/auth_service.dart';
import '../services/firestore_service.dart';
import 'package:demo20426/providers/theme_provider.dart';

/// จัดการบัญชีผู้ใช้งาน (Manage User Accounts) — รูปที่ 3.8 ระบบบริหารจัดการสำหรับผู้ดูแลระบบ
/// ผู้ดูแลระบบตรวจสอบข้อมูลผู้ใช้ และระงับ/คืนสิทธิ์บัญชีที่ละเมิดข้อกำหนดได้
class AdminUsersScreen extends StatefulWidget {
  const AdminUsersScreen({super.key});

  @override
  State<AdminUsersScreen> createState() => _AdminUsersScreenState();
}

class _AdminUsersScreenState extends State<AdminUsersScreen> {
  final FirestoreService _service = FirestoreService();
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _users = [];
  String _query = '';
  bool _suspendedOnly = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await _service.fetchUsersForAdmin();
      list.sort((a, b) => (a['displayName'] ?? a['email'] ?? '')
          .toString()
          .toLowerCase()
          .compareTo((b['displayName'] ?? b['email'] ?? '').toString().toLowerCase()));
      if (mounted) setState(() => _users = list);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<Map<String, dynamic>> get _filtered {
    final q = _query.trim().toLowerCase();
    return _users.where((u) {
      if (_suspendedOnly && u['suspended'] != true) return false;
      if (q.isEmpty) return true;
      return '${u['displayName'] ?? ''} ${u['email'] ?? ''} ${u['uid']}'.toLowerCase().contains(q);
    }).toList();
  }

  Future<void> _toggleSuspend(Map<String, dynamic> u) async {
    final uid = u['uid'] as String;
    final suspend = u['suspended'] != true;
    if (AuthService.isUserAdmin(u['email']?.toString())) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr('ระงับบัญชีผู้ดูแลระบบไม่ได้', 'Admin accounts cannot be suspended'))));
      return;
    }
    final reasonCtrl = TextEditingController(text: suspend ? tr('ละเมิดข้อกำหนดการใช้งาน', 'Violated terms of use') : '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(suspend ? tr('ระงับบัญชีผู้ใช้?', 'Suspend this account?') : tr('คืนสิทธิ์บัญชีผู้ใช้?', 'Restore this account?')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${u['displayName'] ?? ''}\n${u['email'] ?? uid}'),
            if (suspend) ...[
              const SizedBox(height: 12),
              TextField(
                controller: reasonCtrl,
                decoration: InputDecoration(labelText: tr('เหตุผล', 'Reason')),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('ยกเลิก', 'Cancel'))),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: suspend ? Colors.red : const Color(0xFF2ECC71),
              foregroundColor: Colors.white,
            ),
            child: Text(suspend ? tr('ระงับ', 'Suspend') : tr('คืนสิทธิ์', 'Restore')),
          ),
        ],
      ),
    );
    final reason = reasonCtrl.text.trim();
    reasonCtrl.dispose();
    if (ok != true || !mounted) return;
    try {
      await _service.setUserSuspended(uid, suspend, reason: reason);
      if (!mounted) return;
      setState(() {
        u['suspended'] = suspend;
        u['suspendReason'] = suspend ? reason : null;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(suspend ? tr('ระงับบัญชีแล้ว', 'Account suspended') : tr('คืนสิทธิ์บัญชีแล้ว', 'Account restored')),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: Colors.red.shade700,
        content: Text(tr('บันทึกไม่สำเร็จ (ตรวจสอบว่า deploy firestore.rules ล่าสุดแล้ว): $e',
            'Save failed (make sure the latest firestore.rules is deployed): $e')),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final list = _filtered;
    final suspendedCount = _users.where((u) => u['suspended'] == true).length;
    return Scaffold(
      backgroundColor: pal.bg,
      appBar: AppBar(
        title: Text(tr('จัดการบัญชีผู้ใช้', 'Manage Users')),
        actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh_rounded))],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: tr('ค้นหาชื่อ / อีเมล', 'Search name / email'),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                isDense: true,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    tr('ผู้ใช้ ${_users.length} คน · ถูกระงับ $suspendedCount คน',
                        '${_users.length} users · $suspendedCount suspended'),
                    style: TextStyle(color: pal.textSub, fontSize: 13),
                  ),
                ),
                FilterChip(
                  label: Text(tr('เฉพาะที่ถูกระงับ', 'Suspended only')),
                  selected: _suspendedOnly,
                  onSelected: (v) => setState(() => _suspendedOnly = v),
                ),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(tr('โหลดรายชื่อผู้ใช้ไม่สำเร็จ', 'Failed to load users'),
                                  style: TextStyle(color: pal.text, fontWeight: FontWeight.w700)),
                              const SizedBox(height: 6),
                              Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: pal.textSub, fontSize: 12)),
                              const SizedBox(height: 12),
                              OutlinedButton(onPressed: _load, child: Text(tr('ลองใหม่', 'Retry'))),
                            ],
                          ),
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView.separated(
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                          itemCount: list.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 6),
                          itemBuilder: (_, i) {
                            final u = list[i];
                            final suspended = u['suspended'] == true;
                            final isAdmin = AuthService.isUserAdmin(u['email']?.toString());
                            final name = (u['displayName'] ?? '').toString();
                            return Card(
                              color: pal.surface,
                              child: ListTile(
                                leading: CircleAvatar(
                                  backgroundColor: suspended ? Colors.red.shade100 : const Color(0x22FC4C02),
                                  child: Icon(
                                    suspended ? Icons.block_rounded : (isAdmin ? Icons.admin_panel_settings : Icons.person),
                                    color: suspended ? Colors.red : const Color(0xFFFC4C02),
                                  ),
                                ),
                                title: Text(name.isEmpty ? tr('(ไม่มีชื่อ)', '(no name)') : name,
                                    style: TextStyle(color: pal.text, fontWeight: FontWeight.w700)),
                                subtitle: Text(
                                  [
                                    (u['email'] ?? u['uid']).toString(),
                                    if (suspended && (u['suspendReason'] ?? '').toString().isNotEmpty)
                                      tr('ระงับ: ${u['suspendReason']}', 'Suspended: ${u['suspendReason']}'),
                                  ].join('\n'),
                                  style: TextStyle(color: pal.textSub, fontSize: 12),
                                ),
                                isThreeLine: suspended,
                                trailing: isAdmin
                                    ? Text(tr('แอดมิน', 'Admin'), style: TextStyle(color: pal.textMute, fontSize: 12))
                                    : TextButton(
                                        onPressed: () => _toggleSuspend(u),
                                        child: Text(
                                          suspended ? tr('คืนสิทธิ์', 'Restore') : tr('ระงับ', 'Suspend'),
                                          style: TextStyle(color: suspended ? const Color(0xFF2ECC71) : Colors.red),
                                        ),
                                      ),
                              ),
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}
