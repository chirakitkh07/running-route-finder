import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../config/api_config.dart';
import '../models/route_data.dart';
import 'admin_incidents_screen.dart';
import 'admin_routes_screen.dart';
import 'admin_zones_screen.dart';
import '../l10n/tr.dart';
import 'package:provider/provider.dart';
import '../providers/language_provider.dart';

class AdminDashboardScreen extends StatefulWidget {
  const AdminDashboardScreen({super.key});

  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen> {
  bool _isLoading = true;
  Map<String, dynamic>? _stats;
  List<dynamic>? _aiLogs;
  String _dataSource = tr('กำลังเชื่อมต่อ...', 'Connecting...');
  bool _isBackendConnected = false;

  // ── A1: Date Range Filter ──
  DateTime? _filterFrom;
  DateTime? _filterTo;
  String _selectedPeriod = 'all'; // 'today' | '7d' | '30d' | 'custom' | 'all'

  // ── UC-09 A1: กรองตามช่วงคะแนนความเชื่อมั่นของ AI ──
  bool _lowConfidenceOnly = false; // true = แสดงเฉพาะความเชื่อมั่น < 80%
  static const double _lowConfidenceThreshold = 0.80;

  DateTime? _extractDateTime(dynamic val) {
    if (val == null) return null;
    if (val is Timestamp) return val.toDate();
    if (val is DateTime) return val;
    if (val is String) return DateTime.tryParse(val);
    if (val is int) return DateTime.fromMillisecondsSinceEpoch(val);
    return null;
  }

  List<dynamic> get _filteredLogs {
    if (_aiLogs == null) return [];
    if (_filterFrom == null && _filterTo == null && !_lowConfidenceOnly) return _aiLogs!;
    return _aiLogs!.where((log) {
      if (log is! Map) return false;
      if (_lowConfidenceOnly) {
        final c = (log['confidence'] as num?)?.toDouble() ?? 1.0;
        if (c >= _lowConfidenceThreshold) return false;
      }
      if (_filterFrom == null && _filterTo == null) return true;
      final raw = log['createdAt'];
      final dt = _extractDateTime(raw);
      if (dt == null) return false;
      if (_filterFrom != null && dt.isBefore(_filterFrom!)) return false;
      if (_filterTo != null && dt.isAfter(_filterTo!)) return false;
      return true;
    }).toList();
  }

  int _getCountForPeriod(String period) {
    if (_aiLogs == null || _aiLogs!.isEmpty) return 0;
    if (period == 'all') return _aiLogs!.length;
    final now = DateTime.now();
    DateTime from;
    final to = DateTime(now.year, now.month, now.day, 23, 59, 59, 999);
    switch (period) {
      case 'today':
        from = DateTime(now.year, now.month, now.day, 0, 0, 0);
        break;
      case '7d':
        from = DateTime(now.year, now.month, now.day, 0, 0, 0)
            .subtract(const Duration(days: 7));
        break;
      case '30d':
        from = DateTime(now.year, now.month, now.day, 0, 0, 0)
            .subtract(const Duration(days: 30));
        break;
      default:
        return _aiLogs!.length;
    }
    return _aiLogs!.where((log) {
      if (log is! Map) return false;
      final dt = _extractDateTime(log['createdAt']);
      if (dt == null) return false;
      return !dt.isBefore(from) && !dt.isAfter(to);
    }).length;
  }

  void _applyPeriod(String period) {
    final now = DateTime.now();
    setState(() {
      _selectedPeriod = period;
      switch (period) {
        case 'today':
          _filterFrom = DateTime(now.year, now.month, now.day, 0, 0, 0);
          _filterTo = DateTime(now.year, now.month, now.day, 23, 59, 59, 999);
          break;
        case '7d':
          _filterFrom = DateTime(now.year, now.month, now.day, 0, 0, 0)
              .subtract(const Duration(days: 7));
          _filterTo = DateTime(now.year, now.month, now.day, 23, 59, 59, 999);
          break;
        case '30d':
          _filterFrom = DateTime(now.year, now.month, now.day, 0, 0, 0)
              .subtract(const Duration(days: 30));
          _filterTo = DateTime(now.year, now.month, now.day, 23, 59, 59, 999);
          break;
        case 'all':
        default:
          _filterFrom = null;
          _filterTo = null;
      }
    });
  }

  List<String> get _candidateUrls => ApiConfig.adminCandidateUrls;

  @override
  void initState() {
    super.initState();
    _fetchDashboardData();
  }

  Future<void> _fetchDashboardData() async {
    setState(() => _isLoading = true);

    // 1. Try Backend API first
    bool apiSuccess = false;
    for (final baseUrl in _candidateUrls) {
      try {
        final statsResponse = await http
            .get(Uri.parse('$baseUrl/dashboard'))
            .timeout(const Duration(milliseconds: 2500));
        final aiResponse = await http
            .get(Uri.parse('$baseUrl/ai-moderation'))
            .timeout(const Duration(milliseconds: 2500));

        if (statsResponse.statusCode == 200 && aiResponse.statusCode == 200) {
          final stats = json.decode(statsResponse.body) as Map<String, dynamic>;
          final aiLogs = json.decode(aiResponse.body) as List<dynamic>;

          if (mounted) {
            setState(() {
              _stats = stats;
              _aiLogs = aiLogs;
              _dataSource = tr('เซิร์ฟเวอร์หลังบ้าน', 'Backend server');
              _isBackendConnected = true;
              _isLoading = false;
            });
          }
          apiSuccess = true;
          break;
        }
      } catch (e) {
        debugPrint('[AdminDashboard] Backend $baseUrl unreachable: $e');
      }
    }

    // 2. If Backend is offline/unreachable, fallback to Cloud Firestore
    if (!apiSuccess) {
      await _fetchFromFirestore();
    }
  }

  Future<void> _fetchFromFirestore() async {
    try {
      final db = FirebaseFirestore.instance;

      // 1. Incident reports
      final activeIncidentsSnap = await db
          .collection('incidents')
          .where('status', isEqualTo: 'active')
          .get();
      final allIncidentsSnap = await db.collection('incidents').get();

      // 2. Users from activities
      final activitiesSnap = await db.collection('activities').limit(100).get();
      final userIds = <String>{};
      for (final doc in activitiesSnap.docs) {
        final uid = doc.data()['uid'];
        if (uid != null && uid.toString().isNotEmpty) {
          userIds.add(uid.toString());
        }
      }

      // 3. AI moderation logs — ดึงจาก collection ai_moderation_logs โดยตรง
      final aiLogsSnap = await FirebaseFirestore.instance
          .collection('ai_moderation_logs')
          .orderBy('createdAt', descending: true)
          .limit(100)
          .get();

      final List<Map<String, dynamic>> logs;
      if (aiLogsSnap.docs.isNotEmpty) {
        // ใช้ข้อมูลจาก ai_moderation_logs collection
        logs = aiLogsSnap.docs.map((doc) {
          final d = doc.data();
          return {
            'action': d['action'] ?? 'passed',
            'confidence': (d['confidence'] as num?)?.toDouble() ?? 0.95,
            'content': d['content'] ?? '',
            'type': d['incidentType'] ?? 'incident',
            'reason': d['reason'] ?? '',
            'userName': d['userName'] ?? '',
            'createdAt': d['createdAt'],
          };
        }).toList();
      } else {
        // fallback: สร้างจาก incidents (กรณียังไม่มี log collection)
        logs = allIncidentsSnap.docs.take(20).map((doc) {
          final d = doc.data();
          final desc = d['description'] ?? d['type'] ?? tr('ไม่มีรายละเอียด', 'No details');
          final status = d['status'] ?? 'active';
          final denials = (d['denialsCount'] as num?)?.toInt() ?? 0;
          final confs = (d['confirmationsCount'] as num?)?.toInt() ?? 0;
          final isFlagged = status == 'flagged' || denials >= 3;
          final conf = isFlagged ? 0.92 : (confs > 0 ? 0.95 : 0.82);
          return {
            'action': isFlagged ? 'flagged' : 'passed',
            'confidence': conf,
            'content': desc.toString(),
            'type': d['type'] ?? 'incident',
            'createdAt': d['createdAt'] ?? d['timestamp'] ?? d['reportedAt'],
          };
        }).toList();
      }

      if (mounted) {
        setState(() {
          _stats = {
            'users': userIds.isNotEmpty ? userIds.length : 1,
            'savedRoutes': ChiangMaiRoutes.routes.length,
            'activeReports': activeIncidentsSnap.docs.length,
            'totalReports': allIncidentsSnap.docs.length,
          };
          _aiLogs = logs;
          _dataSource = tr('ฐานข้อมูลคลาวด์ (เรียลไทม์)', 'Cloud database (real-time)');
          _isBackendConnected = false;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('[AdminDashboard] Firestore fallback error: $e');
      if (mounted) {
        setState(() {
          _stats = {
            'users': 1,
            'savedRoutes': ChiangMaiRoutes.routes.length,
            'activeReports': 0,
            'totalReports': 0,
          };
          _aiLogs = [];
          _dataSource = tr('แคชในเครื่อง', 'Local Cache');
          _isBackendConnected = false;
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    context.watch<LanguageProvider>(); // rebuild เมื่อสลับภาษา
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: Text(tr('แดชบอร์ดผู้ดูแลระบบ', 'Admin Dashboard')),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _fetchDashboardData,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFFFC4C02)),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Connection source badge
                  Container(
                    margin: const EdgeInsets.only(bottom: 18),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color:
                          (_isBackendConnected
                                  ? const Color(0xFF27AE60)
                                  : const Color(0xFF3498DB))
                              .withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color:
                            (_isBackendConnected
                                    ? const Color(0xFF27AE60)
                                    : const Color(0xFF3498DB))
                                .withValues(alpha: 0.35),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _isBackendConnected
                                ? const Color(0xFF2ECC71)
                                : const Color(0xFF3498DB),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          tr('แหล่งข้อมูล: $_dataSource', 'Data Source: $_dataSource'),
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: _isBackendConnected
                                ? const Color(0xFF2ECC71)
                                : const Color(0xFF3498DB),
                          ),
                        ),
                      ],
                    ),
                  ),

                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        tr('ภาพรวมระบบ', 'System Overview'),
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: cs.onSurface,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  // Quick Action buttons: UC-07 + UC-08
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        // UC-07: Manage Incidents
                        OutlinedButton.icon(
                          onPressed: () async {
                            await Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => const AdminIncidentsScreen(),
                              ),
                            );
                            _fetchDashboardData();
                          },
                          icon: const Icon(
                            Icons.report_problem_outlined,
                            size: 16,
                          ),
                          label: Text(tr('จัดการรายงาน', 'Manage Reports')),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.orange,
                            side: const BorderSide(color: Colors.orange),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        // UC-08: Manage Routes
                        OutlinedButton.icon(
                          onPressed: () async {
                            await Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => const AdminRoutesScreen(),
                              ),
                            );
                            _fetchDashboardData();
                          },
                          icon: const Icon(Icons.edit_road, size: 16),
                          label: Text(tr('จัดการเส้นทาง', 'Manage Routes')),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFFFC4C02),
                            side: const BorderSide(color: Color(0xFFFC4C02)),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        // UC-08: Manage Zones
                        OutlinedButton.icon(
                          onPressed: () async {
                            await Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => const AdminZonesScreen(),
                              ),
                            );
                            _fetchDashboardData();
                          },
                          icon: const Icon(Icons.map_outlined, size: 16),
                          label: Text(tr('จัดการโซนวิ่ง', 'Manage Zones')),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFF3498DB),
                            side: const BorderSide(color: Color(0xFF3498DB)),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _buildStatCard(
                          tr('ผู้ใช้งานทั้งหมด', 'Total Users'),
                          '${_stats?['users'] ?? 0}',
                          Icons.people,
                          Colors.blue,
                          cs,
                          isDark,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: _buildStatCard(
                          tr('เส้นทางที่บันทึก', 'Routes Saved'),
                          '${_stats?['savedRoutes'] ?? 0}',
                          Icons.map,
                          Colors.green,
                          cs,
                          isDark,
                          subtitle: tr('แตะเพื่อจัดการ', 'Tap to manage'),
                          onTap: () async {
                            await Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => const AdminRoutesScreen(),
                              ),
                            );
                            _fetchDashboardData();
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: _buildStatCard(
                          tr('รายงานที่ใช้งานอยู่', 'Active Reports'),
                          '${_stats?['activeReports'] ?? 0}',
                          Icons.warning,
                          Colors.orange,
                          cs,
                          isDark,
                          subtitle: tr('แตะเพื่อตรวจสอบ', 'Tap to review'),
                          onTap: () async {
                            await Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => const AdminIncidentsScreen(),
                              ),
                            );
                            _fetchDashboardData();
                          },
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: _buildStatCard(
                          tr('รายงานทั้งหมด', 'Total Reports'),
                          '${_stats?['totalReports'] ?? 0}',
                          Icons.analytics,
                          Colors.purple,
                          cs,
                          isDark,
                          subtitle: tr('ดูทั้งหมด', 'View all'),
                          onTap: () async {
                            await Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => const AdminIncidentsScreen(),
                              ),
                            );
                            _fetchDashboardData();
                          },
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 24),

                  // ── UC-06 Normal Flow 4: กราฟแสดงข้อมูลภาพรวม ──
                  _buildChartsSection(cs, isDark),

                  const SizedBox(height: 32),
                  Text(
                    tr('บันทึกการคัดกรองเนื้อหาด้วย AI', 'AI Moderation Logs'),
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: cs.onSurface,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    tr('ตรวจสอบรายละเอียดรายงานที่ไม่เหมาะสมหรือสแปม', 'Monitoring incident descriptions for toxicity/spam'),
                    style: TextStyle(
                      color: cs.onSurface.withValues(alpha: 0.6),
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 16),

                  // ── A1: Date Range Filter Row ──
                  _buildDateFilterRow(cs, isDark),
                  const SizedBox(height: 8),
                  // ── UC-09 A1: กรองเฉพาะรายการที่ความเชื่อมั่นต่ำ ──
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilterChip(
                      label: Text(
                          tr('เฉพาะความเชื่อมั่น < ${(_lowConfidenceThreshold * 100).round()}%', 'Confidence < ${(_lowConfidenceThreshold * 100).round()}% only')),
                      selected: _lowConfidenceOnly,
                      onSelected: (v) => setState(() => _lowConfidenceOnly = v),
                    ),
                  ),
                  const SizedBox(height: 16),

                  if (_filteredLogs.isEmpty)
                    Container(
                      padding: const EdgeInsets.all(24),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: cs.surface,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: cs.outline.withValues(alpha: 0.3),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(
                              alpha: isDark ? 0.3 : 0.04,
                            ),
                            blurRadius: 10,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Column(
                        children: [
                          Icon(
                            Icons.info_outline,
                            size: 36,
                            color: cs.onSurface.withValues(alpha: 0.35),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            _selectedPeriod != 'all'
                                ? tr('ไม่มีข้อมูลในช่วงเวลาที่เลือก', 'No data in the selected period')
                                : tr('ไม่พบบันทึกจาก AI', 'No AI logs found.'),
                            style: TextStyle(
                              color: cs.onSurface.withValues(alpha: 0.6),
                            ),
                          ),
                          // E1: แสดงปุ่มลองใหม่
                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                            onPressed: _fetchDashboardData,
                            icon: const Icon(Icons.refresh, size: 16),
                            label: Text(tr('ลองโหลดใหม่', 'Reload')),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFFFC4C02),
                              side: const BorderSide(color: Color(0xFFFC4C02)),
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    ..._filteredLogs.map(
                      (log) => _buildLogItem(
                        log is Map<String, dynamic>
                            ? log
                            : Map<String, dynamic>.from(log as Map),
                        cs,
                        isDark,
                      ),
                    ),
                ],
              ),
            ),
    );
  }

  // ── UC-06 Normal Flow 4: Chart Section ───────────────────
  Widget _buildChartsSection(ColorScheme cs, bool isDark) {
    final users = (_stats?['users'] as num?)?.toInt() ?? 0;
    final routes = (_stats?['savedRoutes'] as num?)?.toInt() ?? 0;
    final activeReports = (_stats?['activeReports'] as num?)?.toInt() ?? 0;
    final totalReports = (_stats?['totalReports'] as num?)?.toInt() ?? 0;

    final passedCount =
        _aiLogs
            ?.where((l) => (l is Map ? l['action'] : null) != 'flagged')
            .length ??
        0;
    final flaggedCount =
        _aiLogs
            ?.where((l) => (l is Map ? l['action'] : null) == 'flagged')
            .length ??
        0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          tr('ภาพรวมสถิติระบบ (กราฟ)', 'System Statistics Overview (Charts)'),
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: cs.onSurface,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          tr('แสดงข้อมูลสรุปในรูปแบบกราฟและตัวเลข', 'Summary shown as charts and figures'),
          style: TextStyle(
            fontSize: 12,
            color: cs.onSurface.withValues(alpha: 0.5),
          ),
        ),
        const SizedBox(height: 16),

        // Bar Chart card
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: cs.outline.withValues(alpha: 0.2)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.05),
                blurRadius: 12,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFC4C02).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.bar_chart,
                      color: Color(0xFFFC4C02),
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    tr('สถิติภาพรวม', 'Overview Statistics'),
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: cs.onSurface,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              _buildBarChart(
                isDark: isDark,
                cs: cs,
                bars: [
                  _BarData(
                    tr('ผู้ใช้งาน', 'Users'),
                    users.toDouble(),
                    Colors.blue,
                    Icons.people,
                  ),
                  _BarData(
                    tr('เส้นทาง', 'Routes'),
                    routes.toDouble(),
                    Colors.green,
                    Icons.map,
                  ),
                  _BarData(
                    tr('รายงาน\nทั้งหมด', 'Total\nReports'),
                    totalReports.toDouble(),
                    Colors.purple,
                    Icons.analytics,
                  ),
                  _BarData(
                    tr('รายงาน\nที่ยังมีผล', 'Active\nReports'),
                    activeReports.toDouble(),
                    Colors.orange,
                    Icons.warning,
                  ),
                ],
              ),
            ],
          ),
        ),

        const SizedBox(height: 16),

        // Row with Donut + Summary
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Donut chart: AI moderation
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: cs.surface,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: cs.outline.withValues(alpha: 0.2)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(
                        alpha: isDark ? 0.25 : 0.05,
                      ),
                      blurRadius: 12,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: Colors.purple.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Icon(
                            Icons.donut_large,
                            color: Colors.purple,
                            size: 18,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            tr('การคัดกรองด้วย AI', 'AI Moderation'),
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: cs.onSurface,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _buildDonutChart(
                      passed: passedCount,
                      flagged: flaggedCount,
                      isDark: isDark,
                      cs: cs,
                    ),
                    const SizedBox(height: 12),
                    _buildLegendRow(
                      Colors.green.shade600,
                      tr('ผ่าน', 'Passed'),
                      passedCount,
                    ),
                    const SizedBox(height: 4),
                    _buildLegendRow(
                      Colors.red.shade600,
                      tr('ถูกตีกลับ', 'Flagged'),
                      flaggedCount,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),

            // System health card
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: cs.surface,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: cs.outline.withValues(alpha: 0.2)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(
                        alpha: isDark ? 0.25 : 0.05,
                      ),
                      blurRadius: 12,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: Colors.teal.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Icon(
                            Icons.health_and_safety,
                            color: Colors.teal,
                            size: 18,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          tr('สถานะระบบ', 'System Health'),
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: cs.onSurface,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    _buildHealthRow(
                      tr('ความแม่นยำ AI', 'AI Accuracy'),
                      _aiLogs != null && _aiLogs!.isNotEmpty
                          ? passedCount / _aiLogs!.length
                          : 1.0,
                      Colors.teal,
                      cs,
                    ),
                    const SizedBox(height: 10),
                    _buildHealthRow(
                      tr('อัตราการรายงาน', 'Report Rate'),
                      totalReports > 0 && users > 0
                          ? (totalReports / (users * 2)).clamp(0.0, 1.0)
                          : 0.0,
                      Colors.orange,
                      cs,
                    ),
                    const SizedBox(height: 10),
                    _buildHealthRow(
                      tr('เส้นทางที่ใช้งาน', 'Active Routes'),
                      routes > 0 ? (routes / 10).clamp(0.0, 1.0) : 0.0,
                      Colors.green,
                      cs,
                    ),
                    const SizedBox(height: 10),
                    _buildHealthRow(
                      tr('อัตราการแก้ไข', 'Resolution Rate'),
                      totalReports > 0
                          ? ((totalReports - activeReports) / totalReports)
                                .clamp(0.0, 1.0)
                          : 1.0,
                      Colors.blue,
                      cs,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ── Bar Chart ─────────────────────────────────────────────
  Widget _buildBarChart({
    required List<_BarData> bars,
    required bool isDark,
    required ColorScheme cs,
  }) {
    final maxVal = bars.map((b) => b.value).fold(0.0, (a, b) => a > b ? a : b);
    if (maxVal == 0) {
      return Container(
        height: 120,
        alignment: Alignment.center,
        child: Text(
          tr('ยังไม่มีข้อมูล', 'No data yet'),
          style: TextStyle(color: cs.onSurface.withValues(alpha: 0.4)),
        ),
      );
    }

    const double labelHeight = 50.0; // icon + spacing + 2-line label
    const double maxBarHeight = 80.0;
    const double numHeight = 20.0; // value text
    const double totalHeight = numHeight + maxBarHeight + labelHeight + 8;

    return SizedBox(
      height: totalHeight,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: bars.map((bar) {
          final ratio = maxVal > 0 ? bar.value / maxVal : 0.0;
          final barH = (maxBarHeight * ratio).clamp(4.0, maxBarHeight);
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 5),
              child: Column(
                mainAxisSize: MainAxisSize.max,
                children: [
                  // ── Top: value number ──
                  SizedBox(
                    height: numHeight,
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: Text(
                        bar.value.toInt().toString(),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: bar.color,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  // ── Middle: bar ──
                  Expanded(
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 700),
                        curve: Curves.easeOut,
                        height: barH,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: [
                              bar.color,
                              bar.color.withValues(alpha: 0.5),
                            ],
                          ),
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(8),
                          ),
                        ),
                      ),
                    ),
                  ),
                  // ── Bottom: icon + label (fixed height) ──
                  SizedBox(
                    height: labelHeight,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(bar.icon, size: 14, color: bar.color),
                        const SizedBox(height: 3),
                        Flexible(
                          child: Text(
                            bar.label,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 9,
                              height: 1.2,
                              color: cs.onSurface.withValues(alpha: 0.6),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  // ── Donut Chart ───────────────────────────────────────────
  Widget _buildDonutChart({
    required int passed,
    required int flagged,
    required bool isDark,
    required ColorScheme cs,
  }) {
    final total = passed + flagged;
    return SizedBox(
      width: double.infinity,
      height: 110,
      child: CustomPaint(
        painter: _DonutPainter(
          passed: passed,
          flagged: flagged,
          total: total,
          isDark: isDark,
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                total.toString(),
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: cs.onSurface,
                ),
              ),
              Text(
                tr('รายการ', 'items'),
                style: TextStyle(
                  fontSize: 10,
                  color: cs.onSurface.withValues(alpha: 0.55),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLegendRow(Color color, String label, int count) {
    return Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(child: Text(label, style: const TextStyle(fontSize: 12))),
        Text(
          count.toString(),
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
        ),
      ],
    );
  }

  Widget _buildHealthRow(
    String label,
    double ratio,
    Color color,
    ColorScheme cs,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: cs.onSurface.withValues(alpha: 0.7),
              ),
            ),
            Text(
              '${(ratio * 100).toStringAsFixed(0)}%',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: ratio,
            backgroundColor: color.withValues(alpha: 0.12),
            valueColor: AlwaysStoppedAnimation<Color>(color),
            minHeight: 7,
          ),
        ),
      ],
    );
  }

  // ── A1: Date Range Filter Row Widget ──
  Widget _buildDateFilterRow(ColorScheme cs, bool isDark) {
    final periods = [
      ('all', tr('ทั้งหมด', 'All'), _getCountForPeriod('all')),
      ('today', tr('วันนี้', 'Today'), _getCountForPeriod('today')),
      ('7d', tr('7 วัน', '7 days'), _getCountForPeriod('7d')),
      ('30d', tr('30 วัน', '30 days'), _getCountForPeriod('30d')),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: periods.map((p) {
                    final isSelected = _selectedPeriod == p.$1;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: GestureDetector(
                        onTap: () => _applyPeriod(p.$1),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? const Color(0xFFFC4C02)
                                : cs.surface,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: isSelected
                                  ? const Color(0xFFFC4C02)
                                  : cs.outline.withValues(alpha: 0.4),
                            ),
                            boxShadow: isSelected
                                ? [
                                    BoxShadow(
                                      color: const Color(
                                        0xFFFC4C02,
                                      ).withValues(alpha: 0.3),
                                      blurRadius: 8,
                                      offset: const Offset(0, 2),
                                    ),
                                  ]
                                : [],
                          ),
                          child: Text(
                            '${p.$2} (${p.$3})',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: isSelected
                                  ? Colors.white
                                  : cs.onSurface.withValues(alpha: 0.7),
                            ),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
            // Custom date range picker
            GestureDetector(
              onTap: () async {
                final picked = await showDateRangePicker(
                  context: context,
                  firstDate: DateTime(2024),
                  lastDate: DateTime.now().add(const Duration(days: 1)),
                  initialDateRange: (_filterFrom != null && _filterTo != null)
                      ? DateTimeRange(start: _filterFrom!, end: _filterTo!)
                      : null,
                  builder: (context, child) {
                    return Theme(
                      data: Theme.of(context).copyWith(
                        colorScheme: Theme.of(context).colorScheme.copyWith(
                          primary: const Color(0xFFFC4C02),
                        ),
                      ),
                      child: child!,
                    );
                  },
                );
                if (picked != null) {
                  setState(() {
                    _selectedPeriod = 'custom';
                    _filterFrom = DateTime(
                        picked.start.year, picked.start.month, picked.start.day, 0, 0, 0);
                    _filterTo = DateTime(
                        picked.end.year, picked.end.month, picked.end.day, 23, 59, 59, 999);
                  });
                }
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: _selectedPeriod == 'custom'
                      ? const Color(0xFFFC4C02).withValues(alpha: 0.12)
                      : cs.surface,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: _selectedPeriod == 'custom'
                        ? const Color(0xFFFC4C02)
                        : cs.outline.withValues(alpha: 0.4),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.date_range_rounded,
                      size: 16,
                      color: _selectedPeriod == 'custom'
                          ? const Color(0xFFFC4C02)
                          : cs.onSurface.withValues(alpha: 0.6),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      tr('กำหนดเอง', 'Custom'),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: _selectedPeriod == 'custom'
                            ? const Color(0xFFFC4C02)
                            : cs.onSurface.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        // Show selected custom range
        if (_selectedPeriod == 'custom' &&
            _filterFrom != null &&
            _filterTo != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '📅 ${_filterFrom!.day}/${_filterFrom!.month}/${_filterFrom!.year} – ${_filterTo!.day}/${_filterTo!.month}/${_filterTo!.year}',
              style: TextStyle(
                fontSize: 12,
                color: const Color(0xFFFC4C02).withValues(alpha: 0.9),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 6, left: 2),
          child: Text(
            tr('แสดง ${_filteredLogs.length} จาก ${_aiLogs?.length ?? 0} รายการ', 'Showing ${_filteredLogs.length} of ${_aiLogs?.length ?? 0} items'),
            style: TextStyle(
              fontSize: 12,
              color: cs.onSurface.withValues(alpha: 0.55),
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStatCard(
    String title,
    String value,
    IconData icon,
    Color color,
    ColorScheme cs,
    bool isDark, {
    VoidCallback? onTap,
    String? subtitle,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: color.withValues(alpha: isDark ? 0.35 : 0.2),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.05),
                blurRadius: 10,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(icon, color: color, size: 24),
                  ),
                  if (onTap != null)
                    Icon(Icons.chevron_right, size: 18, color: color),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                value,
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: 2),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: cs.onSurface.withValues(alpha: 0.65),
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: color,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
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

  Widget _buildLogItem(Map<String, dynamic> log, ColorScheme cs, bool isDark) {
    // 'rejected' คือค่าที่แอปบันทึกจริงเมื่อ AI ไม่ผ่าน (เดิมเช็คเฉพาะ 'flagged' ทำให้แสดงเป็นสีเขียว)
    final bool isFlagged = log['action'] == 'flagged' || log['action'] == 'rejected';
    final double confidence = (log['confidence'] is num)
        ? (log['confidence'] as num).toDouble()
        : 0.85;
    final statusColor = isFlagged
        ? const Color(0xFFE74C3C)
        : const Color(0xFF27AE60);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.outline.withValues(alpha: 0.25)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  isFlagged ? tr('ถูกตีกลับ (ไม่เหมาะสม/สแปม)', 'FLAGGED (Toxicity/Spam)') : tr('ผ่าน', 'PASSED'),
                  style: TextStyle(
                    color: statusColor,
                    fontWeight: FontWeight.bold,
                    fontSize: 11,
                  ),
                ),
              ),
              Text(
                'Conf: ${(confidence * 100).toStringAsFixed(1)}%',
                style: TextStyle(
                  color: cs.onSurface.withValues(alpha: 0.6),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '"${log['content'] ?? ''}"',
            style: TextStyle(
              fontStyle: FontStyle.italic,
              color: cs.onSurface,
              fontSize: 13.5,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Data model for Bar Chart ─────────────────────────────────
class _BarData {
  final String label;
  final double value;
  final Color color;
  final IconData icon;

  const _BarData(this.label, this.value, this.color, this.icon);
}

// ─── Donut Chart CustomPainter ────────────────────────────────
class _DonutPainter extends CustomPainter {
  final int passed;
  final int flagged;
  final int total;
  final bool isDark;

  const _DonutPainter({
    required this.passed,
    required this.flagged,
    required this.total,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final radius = size.height * 0.42;
    final strokeWidth = size.height * 0.16;

    final rect = Rect.fromCircle(center: Offset(cx, cy), radius: radius);

    // Background ring
    final bgPaint = Paint()
      ..color = isDark
          ? Colors.white.withValues(alpha: 0.08)
          : Colors.grey.shade200
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    canvas.drawCircle(Offset(cx, cy), radius, bgPaint);

    if (total == 0) return;

    // Passed arc (green)
    if (passed > 0) {
      final passedAngle = (passed / total) * 2 * 3.14159265;
      final passedPaint = Paint()
        ..color = Colors.green.shade500
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(rect, -3.14159265 / 2, passedAngle, false, passedPaint);
    }

    // Flagged arc (red)
    if (flagged > 0) {
      final passedAngle = total > 0 ? (passed / total) * 2 * 3.14159265 : 0.0;
      final flaggedAngle = (flagged / total) * 2 * 3.14159265;
      final flaggedPaint = Paint()
        ..color = Colors.red.shade400
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth * 0.85
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(
        rect,
        (-3.14159265 / 2) + passedAngle,
        flaggedAngle,
        false,
        flaggedPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _DonutPainter old) =>
      old.passed != passed || old.flagged != flagged || old.isDark != isDark;
}
