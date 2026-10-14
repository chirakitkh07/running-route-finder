import 'package:flutter/material.dart';
import '../models/incident_report.dart';
import '../services/firestore_service.dart';
import '../l10n/tr.dart';
import 'package:provider/provider.dart';
import '../providers/language_provider.dart';
import 'package:demo20426/providers/theme_provider.dart';

/// UC-07: Remove Invalid Incident
/// ให้ Admin ตรวจสอบและลบ/ระงับรายงานเหตุการณ์ที่ไม่ถูกต้องหรือไม่เหมาะสม
class AdminIncidentsScreen extends StatefulWidget {
  const AdminIncidentsScreen({super.key});

  @override
  State<AdminIncidentsScreen> createState() => _AdminIncidentsScreenState();
}

class _AdminIncidentsScreenState extends State<AdminIncidentsScreen>
    with TickerProviderStateMixin {
  final FirestoreService _service = FirestoreService();

  bool _isLoading = true;
  List<IncidentReport> _incidents = [];
  String _statusFilter = 'all'; // 'all' | 'active' | 'suspended' (รวม pending) | 'resolved'
  String _searchQuery = '';

  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) {
        setState(() {
          switch (_tabController.index) {
            case 0:
              _statusFilter = 'active';
              break;
            case 1:
              _statusFilter = 'suspended';
              break;
            case 2:
              _statusFilter = 'all';
              break;
          }
        });
        _loadIncidents();
      }
    });
    _loadIncidents();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadIncidents() async {
    setState(() => _isLoading = true);
    try {
      final result = await _service.fetchAllIncidentsForAdmin(
        statusFilter: _statusFilter == 'all' ? null : _statusFilter,
        limit: 100,
      );
      if (mounted) {
        setState(() {
          _incidents = result;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        // E1: แจ้งเตือนเมื่อโหลดล้มเหลว
        _showErrorSnackBar(tr('โหลดรายการล้มเหลว: $e', 'Failed to load list: $e'));
      }
    }
  }

  List<IncidentReport> get _filtered {
    if (_searchQuery.isEmpty) return _incidents;
    final q = _searchQuery.toLowerCase();
    return _incidents.where((r) {
      return r.title.toLowerCase().contains(q) ||
          r.description.toLowerCase().contains(q) ||
          r.userName.toLowerCase().contains(q) ||
          r.type.toLowerCase().contains(q);
    }).toList();
  }

  // ─── Normal Flow 3: ลบรายงาน (กดลบ → ยืนยัน → ลบ) ────────
  Future<void> _confirmDeleteIncident(IncidentReport inc) async {
    final confirmed = await _showConfirmDialog(
      title: tr('ยืนยันลบรายงาน', 'Confirm delete report'),
      icon: Icons.delete_forever,
      iconColor: Colors.red,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr('คุณต้องการลบรายงานนี้ออกจากระบบหรือไม่?', 'Do you want to delete this report from the system?'),
          ),
          const SizedBox(height: 10),
          _buildIncidentSummaryCard(inc),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.red.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: Colors.red, size: 18),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    tr('การลบถาวร: หมุดจะหายออกจากแผนที่ทันที ไม่สามารถกู้คืนได้', 'Permanent delete: the pin is removed from the map immediately and cannot be restored'),
                    style: TextStyle(fontSize: 12, color: Colors.red),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      confirmText: tr('ลบถาวร', 'Delete permanently'),
      confirmColor: Colors.red,
    );

    if (!confirmed) return;

    setState(() => _isLoading = true);
    try {
      await _service.deleteIncidentReport(inc.id);
      _incidents.removeWhere((r) => r.id == inc.id);
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.check_circle, color: Colors.white, size: 18),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(
                        tr('🗑️ ลบรายงาน "${inc.displayTitle}" เรียบร้อยแล้ว', '🗑️ Report "${inc.displayTitle}" deleted'))),
              ],
            ),
            backgroundColor: Colors.red.shade700,
            behavior: SnackBarBehavior.floating,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
    } catch (e) {
      // E1: การลบล้มเหลว — แจ้งเตือนและให้ลองใหม่
      if (mounted) {
        setState(() => _isLoading = false);
        _showErrorSnackBar(tr('ลบล้มเหลว กรุณาลองใหม่: $e', 'Delete failed, please retry: $e'), onRetry: () {
          _confirmDeleteIncident(inc);
        });
      }
    }
  }

  // ─── Alternative Flow A1: ระงับชั่วคราว ──────────────────────
  Future<void> _confirmSuspendIncident(IncidentReport inc) async {
    final reasonCtrl = TextEditingController(text: tr('ข้อมูลไม่ถูกต้อง รอตรวจสอบ', 'Invalid information, pending review'));

    final confirmed = await _showConfirmDialog(
      title: tr('ระงับชั่วคราว', 'Suspend'),
      icon: Icons.pause_circle_outline,
      iconColor: Colors.orange,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr('รายงานจะถูกซ่อนจากแผนที่ชั่วคราวเพื่อรอตรวจสอบ', 'The report will be hidden from the map pending review'),
          ),
          const SizedBox(height: 10),
          _buildIncidentSummaryCard(inc),
          const SizedBox(height: 12),
          TextField(
            controller: reasonCtrl,
            decoration: InputDecoration(
              labelText: tr('เหตุผลในการระงับ', 'Reason for suspension'),
              hintText: tr('ระบุเหตุผล...', 'Enter a reason...'),
              prefixIcon:
                  const Icon(Icons.note_alt_outlined, size: 18),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10)),
              isDense: true,
            ),
            maxLines: 2,
          ),
        ],
      ),
      confirmText: tr('ระงับชั่วคราว', 'Suspend'),
      confirmColor: Colors.orange,
    );

    if (!confirmed) return;

    setState(() => _isLoading = true);
    try {
      await _service.suspendIncidentReport(inc.id,
          reason: reasonCtrl.text.trim().isNotEmpty
              ? reasonCtrl.text.trim()
              : 'Suspended by admin');
      if (mounted) {
        final messenger = ScaffoldMessenger.of(context);
        await _loadIncidents();
        messenger.showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.pause_circle, color: Colors.white, size: 18),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(
                        tr('⏸️ ระงับรายงาน "${inc.displayTitle}" ชั่วคราวแล้ว', '⏸️ Report "${inc.displayTitle}" suspended'))),
              ],
            ),
            backgroundColor: Colors.orange.shade800,
            behavior: SnackBarBehavior.floating,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        _showErrorSnackBar(tr('ระงับล้มเหลว: $e', 'Suspend failed: $e'), onRetry: () {
          _confirmSuspendIncident(inc);
        });
      }
    }
  }

  // ─── Restore: เรียกคืนรายงานที่ถูกระงับ ───────────────────────
  Future<void> _restoreIncident(IncidentReport inc) async {
    setState(() => _isLoading = true);
    try {
      await _service.restoreIncidentReport(inc.id);
      if (mounted) {
        final messenger = ScaffoldMessenger.of(context);
        await _loadIncidents();
        messenger.showSnackBar(
          SnackBar(
            content: Text(tr('✅ เรียกคืนรายงาน "${inc.displayTitle}" แล้ว', '✅ Report "${inc.displayTitle}" restored')),
            backgroundColor: Colors.green.shade700,
            behavior: SnackBarBehavior.floating,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        _showErrorSnackBar(tr('เรียกคืนล้มเหลว: $e', 'Restore failed: $e'));
      }
    }
  }

  // ─── Shared Confirm Dialog ─────────────────────────────────
  Future<bool> _showConfirmDialog({
    required String title,
    required IconData icon,
    required Color iconColor,
    required Widget content,
    required String confirmText,
    required Color confirmColor,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: iconColor, size: 22),
            ),
            const SizedBox(width: 10),
            Text(title, style: const TextStyle(fontSize: 16)),
          ],
        ),
        content: SingleChildScrollView(child: content),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('ยกเลิก', 'Cancel')),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: confirmColor,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: Text(confirmText),
          ),
        ],
      ),
    );
    return result == true;
  }

  void _showErrorSnackBar(String message, {VoidCallback? onRetry}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.error_outline, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            Expanded(child: Text(message)),
          ],
        ),
        backgroundColor: Colors.red.shade800,
        behavior: SnackBarBehavior.floating,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        action: onRetry != null
            ? SnackBarAction(
                label: tr('ลองใหม่', 'Retry'),
                textColor: Colors.white,
                onPressed: onRetry,
              )
            : null,
      ),
    );
  }

  // ─── Summary card for dialog ───────────────────────────────
  Widget _buildIncidentSummaryCard(IncidentReport inc) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.grey.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            IncidentReport.getTypeLabel(inc.type),
            style:
                const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
          ),
          Text(
            inc.displayTitle,
            style: const TextStyle(fontSize: 13),
          ),
          if (inc.description.isNotEmpty)
            Text(
              inc.description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          Text(
            tr('โดย: ${inc.userName} • ${_formatDate(inc.createdAt)}', 'By: ${inc.userName} • ${_formatDate(inc.createdAt)}'),
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime dt) {
    final d = dt.day.toString().padLeft(2, '0');
    final mo = dt.month.toString().padLeft(2, '0');
    final y = dt.year;
    final h = dt.hour.toString().padLeft(2, '0');
    final mi = dt.minute.toString().padLeft(2, '0');
    return '$d/$mo/$y $h:$mi';
  }

  @override
  Widget build(BuildContext context) {
    context.watch<LanguageProvider>(); // rebuild เมื่อสลับภาษา
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tr('จัดการรายงานเหตุการณ์', 'Manage Incident Reports'),
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            Text(
              tr('ลบรายงานเหตุการณ์ที่ไม่ถูกต้อง', 'Remove Invalid Incident'),
              style: TextStyle(
                  fontSize: 11,
                  color: cs.onSurface.withValues(alpha: 0.55)),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadIncidents,
            tooltip: tr('รีเฟรช', 'Refresh'),
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(text: tr('ใช้งานอยู่', 'Active')),
            Tab(text: tr('ระงับ/รอตรวจ', 'Suspended')),
            Tab(text: tr('ทั้งหมด', 'All')),
          ],
          labelColor: const Color(0xFFFC4C02),
          unselectedLabelColor: Colors.grey,
          indicatorColor: const Color(0xFFFC4C02),
        ),
      ),
      body: Column(
        children: [
          // Search Bar
          Container(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
            color: cs.surface,
            child: TextField(
              onChanged: (v) => setState(() => _searchQuery = v),
              decoration: InputDecoration(
                hintText: tr('ค้นหา รายงาน, ประเภท, ชื่อผู้ใช้...', 'Search reports, types, usernames...'),
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () =>
                            setState(() => _searchQuery = ''),
                      )
                    : null,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 12),
                filled: true,
                fillColor: context.pal.surface2,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),

          // Stats summary
          if (!_isLoading)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              color: cs.surface,
              child: Row(
                children: [
                  Text(
                    tr('พบ ${_filtered.length} รายการ', 'Found ${_filtered.length} items'),
                    style: TextStyle(
                      fontSize: 12,
                      color: cs.onSurface.withValues(alpha: 0.6),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(width: 12),
                  _buildStatusPill(
                    '${tr('ใช้งานอยู่', 'Active')}: ${_incidents.where((r) => r.status == 'active').length}',
                    Colors.green,
                  ),
                  const SizedBox(width: 6),
                  _buildStatusPill(
                    '${tr('ระงับ/รอตรวจ', 'Suspended/Pending')}: ${_incidents.where((r) => r.status == 'suspended' || r.status == 'pending').length}',
                    Colors.orange,
                  ),
                ],
              ),
            ),

          const Divider(height: 1),

          // Incident List
          Expanded(
            child: _isLoading
                ? const Center(
                    child: CircularProgressIndicator(
                        color: Color(0xFFFC4C02)))
                : TabBarView(
                    controller: _tabController,
                    children: [
                      // Tab 0: Active
                      _buildList(
                        _filtered
                            .where((r) => r.status == 'active')
                            .toList(),
                        cs,
                        isDark,
                      ),
                      // Tab 1: Suspended
                      _buildList(
                        _filtered
                            .where((r) => r.status == 'suspended' || r.status == 'pending')
                            .toList(),
                        cs,
                        isDark,
                      ),
                      // Tab 2: All
                      _buildList(_filtered, cs, isDark),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildList(
      List<IncidentReport> items, ColorScheme cs, bool isDark) {
    if (items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_outline,
                size: 56, color: Colors.green.shade300),
            const SizedBox(height: 12),
            Text(
              tr('ไม่พบรายงานที่ต้องตรวจสอบ', 'No reports to review'),
              style: TextStyle(
                  fontSize: 15,
                  color: cs.onSurface.withValues(alpha: 0.55)),
            ),
            const SizedBox(height: 6),
            OutlinedButton.icon(
              onPressed: _loadIncidents,
              icon: const Icon(Icons.refresh, size: 16),
              label: Text(tr('โหลดใหม่', 'Reload')),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFFFC4C02),
                side: const BorderSide(color: Color(0xFFFC4C02)),
              ),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
      itemCount: items.length,
      separatorBuilder: (context, index) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        return _buildIncidentCard(items[index], cs, isDark);
      },
    );
  }

  Widget _buildIncidentCard(
      IncidentReport inc, ColorScheme cs, bool isDark) {
    final statusColor = _getStatusColor(inc.status);
    // 'pending' = รอผู้ดูแลตรวจสอบ (UC-15 A1/E2) — จัดการเหมือนรายงานที่ถูกระงับ
    final isSuspended = inc.status == 'suspended' || inc.status == 'pending';
    final isExpired = inc.isExpired;

    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isSuspended
              ? Colors.orange.withValues(alpha: 0.4)
              : cs.outline.withValues(alpha: isDark ? 0.25 : 0.15),
          width: isSuspended ? 1.5 : 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header row
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Type badge
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    _getTypeEmoji(inc.type),
                    style: const TextStyle(fontSize: 18),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        inc.displayTitle,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.bold),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        IncidentReport.getTypeLabel(inc.type),
                        style: TextStyle(
                            fontSize: 12,
                            color: cs.onSurface.withValues(alpha: 0.55)),
                      ),
                    ],
                  ),
                ),
                // Status badge
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: statusColor.withValues(alpha: 0.35)),
                  ),
                  child: Text(
                    _getStatusLabel(inc.status),
                    style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: statusColor),
                  ),
                ),
              ],
            ),

            if (inc.description.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                '"${inc.description}"',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontStyle: FontStyle.italic,
                  fontSize: 12.5,
                  color: cs.onSurface.withValues(alpha: 0.75),
                ),
              ),
            ],

            const SizedBox(height: 10),

            // Info chips row
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                _buildInfoChip(Icons.person_outline, inc.userName,
                    Colors.blue),
                _buildInfoChip(
                    Icons.access_time_outlined,
                    _formatDate(inc.createdAt),
                    context.pal.textSub),
                _buildInfoChip(
                    Icons.thumb_up_outlined,
                    '${inc.confirmationsCount}',
                    Colors.green.shade600),
                _buildInfoChip(
                    Icons.thumb_down_outlined,
                    '${inc.denialsCount}',
                    Colors.red.shade600),
                if (isExpired)
                  _buildInfoChip(Icons.timer_off_outlined, tr('หมดอายุแล้ว', 'Expired'),
                      Colors.grey),
              ],
            ),

            const Divider(height: 16),

            // Action buttons (Normal Flow 3 + A1)
            Row(
              children: [
                // View detail (Normal Flow 2)
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () =>
                        _showIncidentDetailSheet(inc, cs, isDark),
                    icon: const Icon(Icons.info_outline, size: 15),
                    label: Text(tr('รายละเอียด', 'Details')),
                    style: OutlinedButton.styleFrom(
                      foregroundColor:
                          cs.onSurface.withValues(alpha: 0.75),
                      side: BorderSide(
                          color: cs.outline.withValues(alpha: 0.4)),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(vertical: 8),
                    ),
                  ),
                ),
                const SizedBox(width: 8),

                // A1: ระงับ/เรียกคืน
                if (isSuspended)
                  ElevatedButton.icon(
                    onPressed: () => _restoreIncident(inc),
                    icon: const Icon(Icons.restore, size: 15,
                        color: Colors.white),
                    label: Text(tr('เรียกคืน', 'Restore'),
                        style: TextStyle(color: Colors.white)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green.shade600,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                    ),
                  )
                else
                  IconButton(
                    onPressed: () => _confirmSuspendIncident(inc),
                    icon: const Icon(Icons.pause_circle_outline),
                    color: Colors.orange,
                    tooltip: tr('ระงับชั่วคราว (A1)', 'Suspend temporarily (A1)'),
                  ),

                // Normal Flow 3: ลบ
                IconButton(
                  onPressed: () => _confirmDeleteIncident(inc),
                  icon: const Icon(Icons.delete_outline),
                  color: Colors.red,
                  tooltip: tr('ลบถาวร', 'Delete permanently'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ─── Normal Flow 2: ดูรายละเอียดรายงาน ────────────────────────
  void _showIncidentDetailSheet(
      IncidentReport inc, ColorScheme cs, bool isDark) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
          top: 20,
          left: 20,
          right: 20,
        ),
        decoration: BoxDecoration(
          color: Theme.of(ctx).scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Handle bar
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: context.pal.textMute,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Header
              Row(
                children: [
                  Text(
                    _getTypeEmoji(inc.type),
                    style: const TextStyle(fontSize: 28),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          inc.displayTitle,
                          style: const TextStyle(
                              fontSize: 17, fontWeight: FontWeight.bold),
                        ),
                        Text(
                          IncidentReport.getTypeLabel(inc.type),
                          style: TextStyle(
                              fontSize: 13,
                              color: cs.onSurface.withValues(alpha: 0.55)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 18),

              _buildDetailRow(tr('สถานะ', 'Status'),
                  _getStatusLabel(inc.status), _getStatusColor(inc.status)),
              _buildDetailRow(tr('ผู้รายงาน', 'Reporter'), inc.userName, Colors.blue),
              _buildDetailRow(tr('วันที่รายงาน', 'Reported on'),
                  _formatDate(inc.createdAt), context.pal.textSub),
              _buildDetailRow(tr('หมดอายุ', 'Expires'),
                  _formatDate(inc.expiresAt),
                  inc.isExpired ? Colors.red : Colors.green),
              _buildDetailRow(tr('ความเชื่อมั่น AI', 'AI confidence'),
                  inc.aiConfidence != null
                      ? '${(inc.aiConfidence! * 100).toStringAsFixed(0)}%'
                      : '-',
                  Colors.teal),
              _buildDetailRow(tr('ยืนยัน', 'Confirmed'), tr('${inc.confirmationsCount} ครั้ง', '${inc.confirmationsCount} times'),
                  Colors.green.shade600),
              _buildDetailRow(tr('ปฏิเสธ', 'Denied'), tr('${inc.denialsCount} ครั้ง', '${inc.denialsCount} times'),
                  Colors.red.shade600),
              _buildDetailRow(tr('พิกัด', 'Coordinates'),
                  '${inc.latitude.toStringAsFixed(5)}, ${inc.longitude.toStringAsFixed(5)}',
                  Colors.purple),

              if (inc.description.isNotEmpty) ...[
                const SizedBox(height: 14),
                Text(tr('คำอธิบาย:', 'Description:'),
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: cs.onSurface.withValues(alpha: 0.7))),
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: cs.surface,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: cs.outline.withValues(alpha: 0.3)),
                  ),
                  child: Text(
                    inc.description,
                    style: const TextStyle(fontSize: 13, height: 1.5),
                  ),
                ),
              ],

              const SizedBox(height: 22),

              // Actions
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _confirmSuspendIncident(inc);
                      },
                      icon: const Icon(Icons.pause_circle_outline, size: 16),
                      label: Text(tr('ระงับชั่วคราว (A1)', 'Suspend temporarily (A1)')),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.orange,
                        side: const BorderSide(color: Colors.orange),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _confirmDeleteIncident(inc);
                      },
                      icon: const Icon(Icons.delete_forever,
                          size: 16, color: Colors.white),
                      label: Text(tr('ลบถาวร', 'Delete permanently'),
                          style: TextStyle(color: Colors.white)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDetailRow(String label, String value, Color valueColor) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.55),
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: valueColor,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoChip(IconData icon, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 3),
          Text(label,
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: color)),
        ],
      ),
    );
  }

  Widget _buildStatusPill(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: color)),
    );
  }

  Color _getStatusColor(String status) {
    switch (status) {
      case 'active':
        return Colors.green;
      case 'suspended':
        return Colors.orange;
      case 'pending':
        return Colors.amber;
      case 'resolved':
        return Colors.blue;
      case 'expired':
        return Colors.grey;
      default:
        return Colors.grey;
    }
  }

  String _getStatusLabel(String status) {
    switch (status) {
      case 'active':
        return tr('ใช้งานอยู่', 'ACTIVE');
      case 'suspended':
        return tr('ระงับ', 'SUSPENDED');
      case 'pending':
        return tr('รอตรวจสอบ', 'PENDING REVIEW');
      case 'resolved':
        return tr('คลี่คลายแล้ว', 'RESOLVED');
      default:
        return status.toUpperCase();
    }
  }

  String _getTypeEmoji(String type) {
    switch (type) {
      case 'dogs':
        return '🐶';
      case 'slippery':
        return '🌧️';
      case 'construction':
        return '🚧';
      case 'lighting':
        return '🌙';
      case 'flooding':
        return '🌊';
      case 'accident':
        return '🚨';
      default:
        return '⚠️';
    }
  }
}
