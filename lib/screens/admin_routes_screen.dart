import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import '../models/route_data.dart';
import '../services/firestore_service.dart';
import '../services/safety_score_engine.dart';
import '../l10n/tr.dart';
import 'package:provider/provider.dart';
import '../providers/language_provider.dart';
import 'package:demo20426/providers/theme_provider.dart';

/// UC-08: จัดการข้อมูลเส้นทาง (Manage Route Data)
/// อนุญาตให้ Admin เพิ่ม แก้ไข และลบ/ซ่อน ข้อมูลเส้นทางมาตรฐานในระบบ
class AdminRoutesScreen extends StatefulWidget {
  const AdminRoutesScreen({super.key});

  @override
  State<AdminRoutesScreen> createState() => _AdminRoutesScreenState();
}

class _AdminRoutesScreenState extends State<AdminRoutesScreen> {
  final FirestoreService _firestoreService = FirestoreService();
  bool _isLoading = true;
  List<RunningRoute> _routes = [];
  String _searchQuery = '';
  String _selectedDifficulty = 'all'; // 'all' | 'easy' | 'moderate' | 'hard'

  @override
  void initState() {
    super.initState();
    _loadRoutes();
  }

  Future<void> _loadRoutes() async {
    setState(() => _isLoading = true);
    try {
      final loaded = await _firestoreService.fetchRoutes();
      if (mounted) {
        setState(() {
          _routes = List.from(loaded);
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _routes = List.from(ChiangMaiRoutes.routes);
          _isLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(tr('เชื่อมต่อไม่ได้ — แสดงข้อมูลเส้นทางที่บันทึกไว้ในเครื่อง', 'Offline — showing routes saved on this device')),
            backgroundColor: Colors.orange,
          ),
        );
      }
    }
  }

  List<RunningRoute> get _filteredRoutes {
    return _routes.where((r) {
      if (_selectedDifficulty != 'all' && r.difficulty.toLowerCase() != _selectedDifficulty) {
        return false;
      }
      if (_searchQuery.isNotEmpty) {
        final q = _searchQuery.toLowerCase();
        final matchThai = r.name.toLowerCase().contains(q);
        final matchEn = r.nameEn.toLowerCase().contains(q);
        final matchDesc = r.description.toLowerCase().contains(q);
        if (!matchThai && !matchEn && !matchDesc) return false;
      }
      return true;
    }).toList();
  }

  // ─── Normal Flow 3.1 & 3.2: Add / Edit Route Dialog ───────
  Future<void> _openRouteFormDialog({RunningRoute? initialRoute}) async {
    final isEditing = initialRoute != null;
    final formKey = GlobalKey<FormState>();

    final nameController = TextEditingController(text: initialRoute?.name ?? '');
    final nameEnController = TextEditingController(text: initialRoute?.nameEn ?? '');
    final descController = TextEditingController(text: initialRoute?.description ?? '');
    final descEnController = TextEditingController(text: initialRoute?.descriptionEn ?? '');
    final distanceController = TextEditingController(
        text: initialRoute != null ? initialRoute.distanceKm.toString() : '');
    final elevController = TextEditingController(
        text: initialRoute != null ? initialRoute.elevationGainM.toString() : '0');
    final timeController = TextEditingController(
        text: initialRoute?.estimatedTime ?? '30-45 min');
    final safetyScoreController = TextEditingController(
        text: initialRoute != null ? initialRoute.safetyScore.toString() : '85');

    String difficulty = initialRoute?.difficulty ?? 'easy';

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (modalCtx, setModalState) {
            return Container(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(modalCtx).viewInsets.bottom + 24,
                top: 20,
                left: 20,
                right: 20,
              ),
              decoration: BoxDecoration(
                color: Theme.of(context).scaffoldBackgroundColor,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: SingleChildScrollView(
                child: Form(
                  key: formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Header
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFFC4C02).withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Icon(
                                  isEditing ? Icons.edit_road : Icons.add_road,
                                  color: const Color(0xFFFC4C02),
                                  size: 22,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Text(
                                isEditing ? tr('แก้ไขข้อมูลเส้นทาง', 'Edit route') : tr('เพิ่มเส้นทางใหม่', 'Add new route'),
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          // A1: ยกเลิกก่อนยืนยัน
                          IconButton(
                            icon: const Icon(Icons.close),
                            onPressed: () => Navigator.pop(ctx),
                            tooltip: tr('ยกเลิก', 'Cancel'),
                          ),
                        ],
                      ),
                      const Divider(height: 24),

                      // ชื่อภาษาไทย (จำเป็น)
                      TextFormField(
                        controller: nameController,
                        decoration: InputDecoration(
                          labelText: tr('ชื่อเส้นทาง (ภาษาไทย) *', 'Route name (Thai) *'),
                          hintText: tr('เช่น สวนบวกหาด, รอบคูเมือง', 'e.g. Buak Haad Park, Old City Moat'),
                          prefixIcon: const Icon(Icons.route, size: 20),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return tr('กรุณากรอกชื่อเส้นทางภาษาไทย (E1)', 'Please enter the Thai route name (E1)');
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 14),

                      // ชื่อภาษาอังกฤษ
                      TextFormField(
                        controller: nameEnController,
                        decoration: InputDecoration(
                          labelText: tr('ชื่อเส้นทาง (English) *', 'Route name (English) *'),
                          hintText: tr('เช่น Buak Haad Park Loop', 'e.g. Buak Hard Park Loop'),
                          prefixIcon: const Icon(Icons.language, size: 20),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return tr('กรุณากรอกชื่อภาษาอังกฤษ (E1)', 'Please enter the English name (E1)');
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 14),

                      // ระยะทาง & ความยาก
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: distanceController,
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              decoration: InputDecoration(
                                labelText: tr('ระยะทาง (km) *', 'Distance (km) *'),
                                hintText: tr('เช่น 5.2', 'e.g. 5.2'),
                                prefixIcon: const Icon(Icons.straighten, size: 20),
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                              validator: (value) {
                                if (value == null || value.trim().isEmpty) {
                                  return tr('ระบุระยะทาง', 'Enter distance');
                                }
                                final parsed = double.tryParse(value);
                                if (parsed == null || parsed <= 0) {
                                  return tr('ต้องมากกว่า 0', 'Must be greater than 0');
                                }
                                return null;
                              },
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              initialValue: difficulty,
                              decoration: InputDecoration(
                                labelText: tr('ระดับความยาก', 'Difficulty'),
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                              items: [
                                DropdownMenuItem(value: 'easy', child: Text(tr('ง่าย', 'Easy'))),
                                DropdownMenuItem(value: 'moderate', child: Text(tr('ปานกลาง', 'Moderate'))),
                                DropdownMenuItem(value: 'hard', child: Text(tr('ท้าทาย', 'Hard'))),
                              ],
                              onChanged: (val) {
                                if (val != null) {
                                  setModalState(() => difficulty = val);
                                }
                              },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),

                      // Safety Score & เวลาโดยประมาณ
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: safetyScoreController,
                              keyboardType: TextInputType.number,
                              decoration: InputDecoration(
                                labelText: tr('คะแนนความปลอดภัย (0-100)', 'Safety Score (0-100)'),
                                hintText: '85',
                                prefixIcon: const Icon(Icons.shield, size: 20),
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                              validator: (value) {
                                if (value != null && value.isNotEmpty) {
                                  final n = int.tryParse(value);
                                  if (n == null || n < 0 || n > 100) {
                                    return tr('0 - 100 เท่านั้น', '0 - 100 only');
                                  }
                                }
                                return null;
                              },
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: TextFormField(
                              controller: timeController,
                              decoration: InputDecoration(
                                labelText: tr('เวลาโดยประมาณ', 'Estimated time'),
                                hintText: tr('เช่น 30-45 min', 'e.g. 30-45 min'),
                                prefixIcon: const Icon(Icons.timer_outlined, size: 20),
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),

                      // Elevation Gain
                      TextFormField(
                        controller: elevController,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: tr('ความสูงสะสม Elevation Gain (เมตร)', 'Elevation gain (m)'),
                          hintText: tr('เช่น 15', 'e.g. 15'),
                          prefixIcon: const Icon(Icons.landscape, size: 20),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                      const SizedBox(height: 14),

                      // คำอธิบาย
                      TextFormField(
                        controller: descController,
                        maxLines: 2,
                        decoration: InputDecoration(
                          labelText: tr('รายละเอียดเส้นทาง (ภาษาไทย)', 'Route details (Thai)'),
                          hintText: tr('บรรยายจุดเด่น สภาพพื้นผิว แสงสว่าง หรือความปลอดภัย', 'Describe highlights, surface, lighting or safety'),
                          alignLabelWithHint: true,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                      const SizedBox(height: 14),
                      // คำอธิบายภาษาอังกฤษ (แสดงในโหมดภาษาอังกฤษ)
                      TextFormField(
                        controller: descEnController,
                        maxLines: 2,
                        decoration: InputDecoration(
                          labelText: tr('รายละเอียดเส้นทาง (English)', 'Route details (English)'),
                          alignLabelWithHint: true,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                      const SizedBox(height: 22),

                      // ปุ่มควบคุม (บันทึก / ยกเลิก)
                      Row(
                        children: [
                          // A1: ปุ่มยกเลิก
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () => Navigator.pop(ctx),
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                              child: Text(tr('ยกเลิก', 'Cancel')),
                            ),
                          ),
                          const SizedBox(width: 12),
                          // Normal Flow 4-5: บันทึกข้อมูล
                          Expanded(
                            flex: 2,
                            child: ElevatedButton(
                              onPressed: () async {
                                if (!formKey.currentState!.validate()) {
                                  return; // E1: แจ้งเตือนข้อผิดพลาด
                                }

                                final dist = double.parse(distanceController.text.trim());
                                final elev = int.tryParse(elevController.text.trim()) ?? 0;
                                final score = int.tryParse(safetyScoreController.text.trim()) ?? 80;

                                // ใช้ path เดิม หรือพิกัดเริ่มต้นเชียงใหม่
                                final path = initialRoute?.path ?? [
                                  const LatLng(18.7883, 98.9853),
                                  const LatLng(18.7900, 98.9880),
                                ];
                                final waypoints = initialRoute?.waypoints ?? [
                                  Waypoint(
                                    name: tr('จุดเริ่มต้น', 'Start point'),
                                    type: 'rest',
                                    position: path.first,
                                    description: tr('จุดรวมตัวนักวิ่ง', 'Runner meeting point'),
                                  ),
                                ];

                                final routeId = initialRoute?.id ??
                                    'route_${DateTime.now().millisecondsSinceEpoch}';

                                final updatedRoute = RunningRoute(
                                  id: routeId,
                                  name: nameController.text.trim(),
                                  nameEn: nameEnController.text.trim(),
                                  description: descController.text.trim(),
                                  descriptionEn: descEnController.text.trim(),
                                  distanceKm: dist,
                                  difficulty: difficulty,
                                  elevationGainM: elev,
                                  estimatedTime: timeController.text.trim(),
                                  path: path,
                                  waypoints: waypoints,
                                  safetyScore: score,
                                );

                                Navigator.pop(ctx);

                                // Save to Firestore & State
                                setState(() => _isLoading = true);
                                try {
                                  await _firestoreService.saveRoute(updatedRoute);
                                } catch (e) {
                                  // UC-08 E1: บันทึกไม่สำเร็จ → แจ้งเตือนและไม่บันทึก
                                  if (mounted) {
                                    setState(() => _isLoading = false);
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(tr('❌ บันทึกเส้นทางไม่สำเร็จ: $e', '❌ Failed to save route: $e')),
                                        backgroundColor: Colors.red.shade700,
                                      ),
                                    );
                                  }
                                  return;
                                }
                                await _loadRoutes();

                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(isEditing
                                          ? tr('✅ แก้ไขเส้นทาง "${updatedRoute.name}" สำเร็จ', '✅ Route "${updatedRoute.name}" updated')
                                          : tr('✅ เพิ่มเส้นทางใหม่ "${updatedRoute.name}" สำเร็จ', '✅ Route "${updatedRoute.name}" added')),
                                      backgroundColor: const Color(0xFF27AE60),
                                      behavior: SnackBarBehavior.floating,
                                    ),
                                  );
                                }
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFFFC4C02),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                              child: Text(
                                isEditing ? tr('บันทึกการแก้ไข', 'Save changes') : tr('ยืนยันเพิ่มเส้นทาง', 'Add route'),
                                style: const TextStyle(fontWeight: FontWeight.bold),
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
          },
        );
      },
    );
  }

  // ─── Normal Flow 3.3 & E2: Delete Route Confirmation ─────
  Future<void> _confirmDeleteRoute(RunningRoute route) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.delete_outline, color: Colors.red, size: 24),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(tr('ยืนยันลบเส้นทาง?', 'Delete this route?'))),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr('คุณต้องการลบเส้นทาง "${route.name}" (${route.nameEn}) หรือไม่?', 'Delete route "${route.name}" (${route.nameEn})?')),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.amber.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.amber.shade700.withValues(alpha: 0.4)),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline, color: Colors.amber.shade800, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      tr('การลบเส้นทางจะมีผลกับผู้ใช้งานทุกคนทันที (E2)', 'Deleting a route affects all users immediately (E2)'),
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false), // A1: ยกเลิก
            child: Text(tr('ยกเลิก', 'Cancel')),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true), // ยืนยันลบ
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: Text(tr('ลบเส้นทาง', 'Delete route')),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      setState(() => _isLoading = true);
      try {
        await _firestoreService.deleteRoute(route.id);
      } catch (e) {
        // UC-08 E1
        if (mounted) {
          setState(() => _isLoading = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(tr('❌ ลบเส้นทางไม่สำเร็จ: $e', '❌ Failed to delete route: $e')),
              backgroundColor: Colors.red.shade700,
            ),
          );
        }
        return;
      }
      await _loadRoutes();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(tr('🗑️ ลบเส้นทาง "${route.name}" เรียบร้อยแล้ว', '🗑️ Route "${route.name}" deleted')),
            backgroundColor: Colors.red.shade700,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Color _getDifficultyColor(String diff) {
    switch (diff.toLowerCase()) {
      case 'easy':
        return const Color(0xFF27AE60);
      case 'moderate':
        return const Color(0xFFF39C12);
      case 'hard':
        return const Color(0xFFE74C3C);
      default:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    context.watch<LanguageProvider>(); // rebuild เมื่อสลับภาษา
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final filtered = _filteredRoutes;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          tr('จัดการข้อมูลเส้นทาง', 'Manage Route Data'),
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadRoutes,
            tooltip: tr('รีเฟรชข้อมูล', 'Refresh data'),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openRouteFormDialog(),
        icon: const Icon(Icons.add, color: Colors.white),
        label: Text(tr('เพิ่มเส้นทางใหม่', 'Add new route'), style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: const Color(0xFFFC4C02),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFFFC4C02)))
          : Column(
              children: [
                // Top Search & Filter Bar
                Container(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  decoration: BoxDecoration(
                    color: cs.surface,
                    border: Border(bottom: BorderSide(color: cs.outline.withValues(alpha: 0.2))),
                  ),
                  child: Column(
                    children: [
                      // Search field
                      TextField(
                        onChanged: (val) => setState(() => _searchQuery = val),
                        decoration: InputDecoration(
                          hintText: tr('ค้นหาเส้นทาง (ชื่อ, รายละเอียด)...', 'Search routes (name, details)...'),
                          prefixIcon: const Icon(Icons.search, size: 20),
                          suffixIcon: _searchQuery.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.clear, size: 18),
                                  onPressed: () => setState(() => _searchQuery = ''),
                                )
                              : null,
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          filled: true,
                          fillColor: context.pal.surface2,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),

                      // Difficulty Filter Chips
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            Text(
                              tr('ระดับความยาก: ', 'Difficulty: '),
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: cs.onSurface.withValues(alpha: 0.7),
                              ),
                            ),
                            const SizedBox(width: 6),
                            _buildFilterChip('all', tr('ทั้งหมด (${_routes.length})', 'All (${_routes.length})')),
                            const SizedBox(width: 6),
                            _buildFilterChip('easy', tr('ง่าย', 'Easy')),
                            const SizedBox(width: 6),
                            _buildFilterChip('moderate', tr('ปานกลาง', 'Moderate')),
                            const SizedBox(width: 6),
                            _buildFilterChip('hard', tr('ยาก', 'Hard')),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                // Summary Stats Row
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        tr('พบ ${filtered.length} เส้นทาง', 'Found ${filtered.length} routes'),
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: cs.onSurface.withValues(alpha: 0.7),
                        ),
                      ),
                      Row(
                        children: [
                          Icon(Icons.shield_outlined, size: 16, color: Colors.green.shade600),
                          const SizedBox(width: 4),
                          Text(
                            tr('คะแนนเฉลี่ย: ${(filtered.fold(0, (acc, r) => acc + r.safetyScore) / (filtered.isNotEmpty ? filtered.length : 1)).toStringAsFixed(0)}/100', 'Average score: ${(filtered.fold(0, (acc, r) => acc + r.safetyScore) / (filtered.isNotEmpty ? filtered.length : 1)).toStringAsFixed(0)}/100'),
                            style: TextStyle(
                              fontSize: 12,
                              color: cs.onSurface.withValues(alpha: 0.7),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                // Routes List (Normal Flow 2)
                Expanded(
                  child: filtered.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.route_outlined, size: 56, color: context.pal.textMute),
                              const SizedBox(height: 12),
                              Text(
                                tr('ไม่พบข้อมูลเส้นทางที่ค้นหา', 'No routes match your search'),
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w500,
                                  color: cs.onSurface.withValues(alpha: 0.6),
                                ),
                              ),
                              const SizedBox(height: 8),
                              OutlinedButton(
                                onPressed: () {
                                  setState(() {
                                    _searchQuery = '';
                                    _selectedDifficulty = 'all';
                                  });
                                },
                                child: Text(tr('ล้างตัวกรอง', 'Clear filter')),
                              ),
                            ],
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 90),
                          itemCount: filtered.length,
                          separatorBuilder: (context, index) => const SizedBox(height: 12),
                          itemBuilder: (context, index) {
                            final route = filtered[index];
                            final diffColor = _getDifficultyColor(route.difficulty);

                            return Container(
                              decoration: BoxDecoration(
                                color: cs.surface,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: cs.outline.withValues(alpha: isDark ? 0.25 : 0.15),
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.04),
                                    blurRadius: 8,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    // Row 1: Name and Badges
                                    Row(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                route.name,
                                                style: const TextStyle(
                                                  fontSize: 16,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                              if (route.nameEn.isNotEmpty)
                                                Text(
                                                  route.nameEn,
                                                  style: TextStyle(
                                                    fontSize: 13,
                                                    color: cs.onSurface.withValues(alpha: 0.6),
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
                                        // Difficulty badge
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                          decoration: BoxDecoration(
                                            color: diffColor.withValues(alpha: 0.15),
                                            borderRadius: BorderRadius.circular(8),
                                            border: Border.all(color: diffColor.withValues(alpha: 0.4)),
                                          ),
                                          child: Text(
                                            route.difficulty.toUpperCase(),
                                            style: TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.bold,
                                              color: diffColor,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),

                                    const SizedBox(height: 10),

                                    // Description
                                    if (route.description.isNotEmpty)
                                      Text(
                                        route.displayDescription,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 13,
                                          color: cs.onSurface.withValues(alpha: 0.75),
                                          height: 1.3,
                                        ),
                                      ),

                                    const SizedBox(height: 12),

                                    // Info pills (Distance, Safety, Time, Waypoints)
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 6,
                                      children: [
                                        _buildInfoPill(
                                          Icons.straighten,
                                          '${route.distanceKm.toStringAsFixed(1)} km',
                                          const Color(0xFFFC4C02),
                                        ),
                                        _buildInfoPill(
                                          Icons.shield,
                                          tr('ความปลอดภัย ${route.safetyScore}%', 'Safety ${route.safetyScore}%'),
                                          SafetyScoreEngine.scoreColor(route.safetyScore),
                                        ),
                                        if (route.estimatedTime.isNotEmpty)
                                          _buildInfoPill(
                                            Icons.timer_outlined,
                                            route.estimatedTime,
                                            Colors.blue,
                                          ),
                                        _buildInfoPill(
                                          Icons.location_on_outlined,
                                          tr('${route.waypoints.length} จุดพัก', '${route.waypoints.length} stops'),
                                          Colors.purple,
                                        ),
                                      ],
                                    ),

                                    const Divider(height: 20),

                                    // Actions: Edit and Delete buttons (Normal Flow 3.2 & 3.3)
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.end,
                                      children: [
                                        // Edit Button
                                        OutlinedButton.icon(
                                          onPressed: () => _openRouteFormDialog(initialRoute: route),
                                          icon: const Icon(Icons.edit, size: 16),
                                          label: Text(tr('แก้ไข', 'Edit')),
                                          style: OutlinedButton.styleFrom(
                                            foregroundColor: const Color(0xFFFC4C02),
                                            side: const BorderSide(color: Color(0xFFFC4C02), width: 1.2),
                                            shape: RoundedRectangleBorder(
                                              borderRadius: BorderRadius.circular(10),
                                            ),
                                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        // Delete Button
                                        IconButton(
                                          icon: const Icon(Icons.delete_outline, color: Colors.red),
                                          tooltip: tr('ลบเส้นทาง', 'Delete route'),
                                          onPressed: () => _confirmDeleteRoute(route),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }

  Widget _buildFilterChip(String value, String label) {
    final isSelected = _selectedDifficulty == value;
    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      selectedColor: const Color(0xFFFC4C02),
      labelStyle: TextStyle(
        fontSize: 12,
        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        color: isSelected ? Colors.white : null,
      ),
      onSelected: (selected) {
        if (selected) {
          setState(() => _selectedDifficulty = value);
        }
      },
    );
  }

  Widget _buildInfoPill(IconData icon, String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
