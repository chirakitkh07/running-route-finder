import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/running_zone.dart';
import '../models/preset_zones.dart';
import '../services/zone_service.dart';
import '../services/zone_popularity_service.dart';
import '../services/safety_score_engine.dart';
import '../l10n/tr.dart';
import 'package:demo20426/providers/theme_provider.dart';

/// UC-08: จัดการข้อมูลโซนวิ่ง (Admin Manage Running Zones)
///
/// หน้าจอสำหรับผู้ดูแลระบบในการควบคุมโซนวิ่ง:
/// - ซ่อน / แสดง (Toggle Hide/Show)
/// - ปักหมุด (Toggle Pin — ได้รับ +10 ใน R และแสดงเสมอ)
/// - แก้ไขชื่อและคำอธิบาย (ไทย / อังกฤษ)
/// - อนุมัติโซนจากชุมชน (Community Zones)
/// - สั่งคำนวณคะแนนใหม่ (Recalculate Zone Score)
/// - UC-08 E2: ป้องกันการลบโซนที่มีการใช้งาน (runs_4w > 0)
class AdminZonesScreen extends StatefulWidget {
  const AdminZonesScreen({super.key});

  @override
  State<AdminZonesScreen> createState() => _AdminZonesScreenState();
}

class _AdminZonesScreenState extends State<AdminZonesScreen> {
  bool _isLoading = true;
  List<RunningZone> _zones = [];
  String _filterSource = 'all'; // 'all' | 'preset' | 'osm' | 'community'
  String _filterStatus = 'all'; // 'all' | 'active' | 'hidden' | 'pinned' | 'pending'
  String _searchQuery = '';
  final Map<String, int> _runs4wCache = {};

  @override
  void initState() {
    super.initState();
    _loadAllZones();
  }

  Future<void> _loadAllZones() async {
    setState(() => _isLoading = true);
    try {
      final List<RunningZone> allZones = [];
      final seenIds = <String>{};

      // 1. ดึงโซนจาก Firestore
      final snapshot = await FirebaseFirestore.instance.collection('zones').get();
      for (final doc in snapshot.docs) {
        final zone = RunningZone.fromMap(doc.data(), doc.id);
        allZones.add(zone);
        seenIds.add(zone.id);
      }

      // 2. เติม Preset Zones หากยังไม่มีใน Firestore
      for (final pz in PresetZones.defaultZones) {
        if (!seenIds.contains(pz.id)) {
          allZones.add(pz);
          seenIds.add(pz.id);
        }
      }

      // 3. โหลดสถิติการใช้งาน runs_4w สำหรับทุกโซน
      for (final z in allZones) {
        final runs = await ZonePopularityService.getRuns4w(z.id);
        _runs4wCache[z.id] = runs;
      }

      if (mounted) {
        setState(() {
          _zones = allZones;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('[AdminZones] Error loading zones: $e');
      if (mounted) {
        setState(() {
          _zones = List.from(PresetZones.defaultZones);
          _isLoading = false;
        });
      }
    }
  }

  List<RunningZone> get _filteredZones {
    return _zones.where((z) {
      if (_filterSource != 'all' && z.source != _filterSource) return false;
      if (_filterStatus == 'hidden' && !z.hidden) return false;
      if (_filterStatus == 'pinned' && !z.pinned) return false;
      if (_filterStatus == 'active' && z.hidden) return false;
      if (_searchQuery.isNotEmpty) {
        final q = _searchQuery.toLowerCase();
        final matchTh = z.name.toLowerCase().contains(q);
        final matchEn = z.nameEn.toLowerCase().contains(q);
        final matchId = z.id.toLowerCase().contains(q);
        if (!matchTh && !matchEn && !matchId) return false;
      }
      return true;
    }).toList();
  }

  // ─── Actions ผู้ดูแลระบบ ──────────────────────────────────────────────────

  /// 1. ซ่อน / แสดง โซน
  Future<void> _toggleHideZone(RunningZone zone) async {
    final newHidden = !zone.hidden;
    try {
      await FirebaseFirestore.instance.collection('zones').doc(zone.id).set({
        ...zone.toMap(),
        'hidden': newHidden,
      }, SetOptions(merge: true));

      setState(() {
        final idx = _zones.indexWhere((z) => z.id == zone.id);
        if (idx != -1) {
          _zones[idx] = zone.copyWith(hidden: newHidden);
        }
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(newHidden
                ? tr('ซ่อนโซนเรียบร้อยแล้ว', 'Zone hidden successfully')
                : tr('เปิดแสดงโซนเรียบร้อยแล้ว', 'Zone visible now')),
            backgroundColor: newHidden ? Colors.orange : const Color(0xFF2ECC71),
          ),
        );
      }
    } catch (e) {
      _showErrorSnackBar(e.toString());
    }
  }

  /// 2. ปักหมุด / เลิกปักหมุด (+10 ในคะแนน R)
  Future<void> _togglePinZone(RunningZone zone) async {
    final newPinned = !zone.pinned;
    try {
      await FirebaseFirestore.instance.collection('zones').doc(zone.id).set({
        ...zone.toMap(),
        'pinned': newPinned,
      }, SetOptions(merge: true));

      setState(() {
        final idx = _zones.indexWhere((z) => z.id == zone.id);
        if (idx != -1) {
          _zones[idx] = zone.copyWith(pinned: newPinned);
        }
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(newPinned
                ? tr('📌 ปักหมุดโซนแล้ว (รับคะแนนแนะนำ +10)', '📌 Pinned zone (+10 Recommendation bonus)')
                : tr('เลิกปักหมุดโซนแล้ว', 'Unpinned zone')),
            backgroundColor: newPinned ? const Color(0xFF3498DB) : Colors.grey,
          ),
        );
      }
    } catch (e) {
      _showErrorSnackBar(e.toString());
    }
  }

  /// 3. แก้ไขชื่อและคำอธิบาย (ไทย / อังกฤษ)
  Future<void> _editZoneDialog(RunningZone zone) async {
    final nameThCtrl = TextEditingController(text: zone.name);
    final nameEnCtrl = TextEditingController(text: zone.nameEn);
    final descThCtrl = TextEditingController(text: zone.description);
    final descEnCtrl = TextEditingController(text: zone.descriptionEn);

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('แก้ไขข้อมูลโซน', 'Edit Zone Info')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameThCtrl,
                decoration: InputDecoration(
                  labelText: tr('ชื่อโซน (ภาษาไทย)', 'Zone Name (Thai)'),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: nameEnCtrl,
                decoration: InputDecoration(
                  labelText: tr('ชื่อโซน (ภาษาอังกฤษ)', 'Zone Name (English)'),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: descThCtrl,
                maxLines: 2,
                decoration: InputDecoration(
                  labelText: tr('คำอธิบาย (ภาษาไทย)', 'Description (Thai)'),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: descEnCtrl,
                maxLines: 2,
                decoration: InputDecoration(
                  labelText: tr('คำอธิบาย (ภาษาอังกฤษ)', 'Description (English)'),
                ),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.blue.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline, size: 16, color: Colors.blue),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        tr('หมายเหตุ: ห้ามแก้ไขรูปทรง Polygon ด้วยมือ หากผิดให้แก้ไขใน OSM แล้วกดคำนวณใหม่',
                            'Note: Cannot manually edit polygons. Update in OSM and recalculate.'),
                        style: const TextStyle(fontSize: 11, color: Colors.blue),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('ยกเลิก', 'Cancel')),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFC4C02),
              foregroundColor: Colors.white,
            ),
            child: Text(tr('บันทึก', 'Save')),
          ),
        ],
      ),
    );

    if (result == true) {
      final updatedZone = zone.copyWith(
        name: nameThCtrl.text.trim(),
        nameEn: nameEnCtrl.text.trim(),
        description: descThCtrl.text.trim(),
        descriptionEn: descEnCtrl.text.trim(),
      );

      try {
        await FirebaseFirestore.instance
            .collection('zones')
            .doc(zone.id)
            .set(updatedZone.toMap(), SetOptions(merge: true));

        setState(() {
          final idx = _zones.indexWhere((z) => z.id == zone.id);
          if (idx != -1) _zones[idx] = updatedZone;
        });

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(tr('บันทึกข้อมูลโซนเรียบร้อยแล้ว', 'Zone updated successfully')),
              backgroundColor: const Color(0xFF2ECC71),
            ),
          );
        }
      } catch (e) {
        _showErrorSnackBar(e.toString());
      }
    }
  }

  /// 4. สั่งคำนวณคะแนนใหม่ (Recalculate Zone Score)
  Future<void> _recalculateZoneScore(RunningZone zone) async {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(tr('กำลังคำนวณคะแนนโซนใหม่…', 'Recalculating zone score…')),
        duration: const Duration(seconds: 2),
      ),
    );

    try {
      final scored = await ZoneService.scoreZone(zone);
      await FirebaseFirestore.instance
          .collection('zones')
          .doc(zone.id)
          .set(scored.toMap(), SetOptions(merge: true));

      setState(() {
        final idx = _zones.indexWhere((z) => z.id == zone.id);
        if (idx != -1) _zones[idx] = scored;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(tr('คำนวณใหม่สำเร็จ: ${scored.safetyScore} คะแนน', 'Recalculated: ${scored.safetyScore} pts')),
            backgroundColor: const Color(0xFF2ECC71),
          ),
        );
      }
    } catch (e) {
      _showErrorSnackBar(e.toString());
    }
  }

  /// 5. UC-08 E2: ลบโซน (ตรวจสอบการใช้งาน runs_4w > 0 ห้ามลบ)
  Future<void> _deleteZone(RunningZone zone) async {
    final runs4w = _runs4wCache[zone.id] ?? 0;

    // UC-08 E2: ห้ามลบโซนที่มีการใช้งานใน 4 สัปดาห์ล่าสุด (ให้ซ่อนแทน)
    if (runs4w > 0) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Row(
            children: [
              const Icon(Icons.shield_outlined, color: Colors.orange),
              const SizedBox(width: 8),
              Expanded(child: Text(tr('ไม่สามารถลบโซนนี้ได้', 'Cannot delete this zone'))),
            ],
          ),
          content: Text(
            tr(
              'โซน "${zone.displayName}" มีประวัติการวิ่ง $runs4w ครั้งในช่วง 4 สัปดาห์ล่าสุด ระบบไม่อนุญาตให้ลบเพื่อรักษาความต่อเนื่องของข้อมูลสถิติ กรุณาใช้ฟังก์ชัน "ซ่อนโซน" แทน',
              'Zone "${zone.displayName}" has $runs4w runs recorded in the last 4 weeks. To protect historical statistics, deletion is prevented. Please hide the zone instead.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('เข้าใจแล้ว', 'Got it')),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(ctx);
                _toggleHideZone(zone);
              },
              style: ElevatedButton.styleFrom(backgroundColor: Colors.orange, foregroundColor: Colors.white),
              child: Text(tr('ซ่อนโซนนี้แทน', 'Hide Zone Instead')),
            ),
          ],
        ),
      );
      return;
    }

    // ยืนยันการลบกรณี runs_4w == 0
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('ยืนยันการลบโซน', 'Confirm Zone Deletion')),
        content: Text(tr('คุณแน่ใจหรือไม่ว่าต้องการลบโซน "${zone.displayName}"?', 'Are you sure you want to delete "${zone.displayName}"?')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('ยกเลิก', 'Cancel'))),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            child: Text(tr('ลบ', 'Delete')),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        await FirebaseFirestore.instance.collection('zones').doc(zone.id).delete();
        setState(() {
          _zones.removeWhere((z) => z.id == zone.id);
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(tr('ลบโซนเรียบร้อยแล้ว', 'Zone deleted successfully')),
              backgroundColor: Colors.red,
            ),
          );
        }
      } catch (e) {
        _showErrorSnackBar(e.toString());
      }
    }
  }

  void _showErrorSnackBar(String err) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${tr('เกิดข้อผิดพลาด', 'Error')}: $err'), backgroundColor: Colors.red),
    );
  }

  @override
  Widget build(BuildContext context) {

    return Scaffold(
      appBar: AppBar(
        title: Text(tr('จัดการข้อมูลโซนวิ่ง', 'Manage Running Zones')),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: tr('รีเฟรช', 'Refresh'),
            onPressed: _loadAllZones,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // ── Search & Filter Bar ──
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
                  child: TextField(
                    decoration: InputDecoration(
                      hintText: tr('ค้นหาชื่อโซน...', 'Search zone name...'),
                      prefixIcon: const Icon(Icons.search),
                      isDense: true,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onChanged: (v) => setState(() => _searchQuery = v.trim()),
                  ),
                ),

                // ── Filter Chips ──
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  child: Row(
                    children: [
                      _buildFilterChip('all', tr('ทั้งหมด', 'All')),
                      _buildFilterChip('preset', 'Preset (6 โซน)'),
                      _buildFilterChip('osm', tr('ค้นพบอัตโนมัติ', 'Auto-discovered')),
                      _buildFilterChip('community', 'Community'),
                      const SizedBox(width: 8),
                      const Text('|', style: TextStyle(color: Colors.grey)),
                      const SizedBox(width: 8),
                      _buildStatusChip('active', tr('เปิดใช้งาน', 'Active')),
                      _buildStatusChip('hidden', tr('ซ่อนอยู่', 'Hidden')),
                      _buildStatusChip('pinned', tr('ปักหมุด', 'Pinned')),
                    ],
                  ),
                ),

                const Divider(height: 1),

                // ── Zone List ──
                Expanded(
                  child: _filteredZones.isEmpty
                      ? Center(
                          child: Text(
                            tr('ไม่พบโซนที่ตรงกับเงื่อนไข', 'No zones match filter'),
                            style: const TextStyle(color: Colors.grey),
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.all(16),
                          itemCount: _filteredZones.length,
                          itemBuilder: (context, index) {
                            final zone = _filteredZones[index];
                            final runs4w = _runs4wCache[zone.id] ?? 0;
                            final score = zone.safetyScore;
                            final scoreColor = score != null
                                ? SafetyScoreEngine.scoreColor(score)
                                : const Color(0xFF95A5A6);

                            return Card(
                              margin: const EdgeInsets.only(bottom: 12),
                              elevation: 2,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                                side: BorderSide(
                                  color: zone.pinned
                                      ? const Color(0xFF3498DB)
                                      : (zone.hidden ? Colors.grey.shade400 : Colors.transparent),
                                  width: zone.pinned ? 2.0 : 1.0,
                                ),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    // Header: Name & Score Badge
                                    Row(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Row(
                                                children: [
                                                  if (zone.pinned) ...[
                                                    const Icon(Icons.push_pin, size: 16, color: Color(0xFF3498DB)),
                                                    const SizedBox(width: 4),
                                                  ],
                                                  if (zone.hidden) ...[
                                                    const Icon(Icons.visibility_off, size: 16, color: Colors.grey),
                                                    const SizedBox(width: 4),
                                                  ],
                                                  Expanded(
                                                    child: Text(
                                                      zone.displayName,
                                                      style: TextStyle(
                                                        fontSize: 16,
                                                        fontWeight: FontWeight.bold,
                                                        color: zone.hidden ? Colors.grey : null,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                              const SizedBox(height: 4),
                                              Text(
                                                'ID: ${zone.id} · แหล่งที่มา: ${zone.source.toUpperCase()}',
                                                style: TextStyle(fontSize: 11, color: context.pal.textSub),
                                              ),
                                            ],
                                          ),
                                        ),
                                        // Score Badge
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                          decoration: BoxDecoration(
                                            color: scoreColor.withValues(alpha: 0.15),
                                            borderRadius: BorderRadius.circular(12),
                                            border: Border.all(color: scoreColor.withValues(alpha: 0.6)),
                                          ),
                                          child: Column(
                                            children: [
                                              Text(
                                                score != null ? '$score' : '…',
                                                style: TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                  color: scoreColor,
                                                  fontSize: 16,
                                                ),
                                              ),
                                              Text(
                                                tr('ความปลอดภัย', 'Safety'),
                                                style: TextStyle(fontSize: 9, color: scoreColor),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),

                                    const SizedBox(height: 8),
                                    Text(
                                      zone.displayDescription,
                                      style: TextStyle(fontSize: 12, color: context.pal.textSub),
                                    ),

                                    const SizedBox(height: 10),
                                    // Info Chips (Walkable km, runs_4w)
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 4,
                                      children: [
                                        _badgeChip(Icons.straighten, '${zone.walkableLengthKm.toStringAsFixed(1)} km'),
                                        _badgeChip(Icons.directions_run, '$runs4w runs (4w)'),
                                        if (zone.pinned)
                                          _badgeChip(Icons.star, tr('แนะนำพิเศษ +10', 'Pinned +10'), color: const Color(0xFF3498DB)),
                                        if (zone.hidden)
                                          _badgeChip(Icons.visibility_off, tr('ซ่อนจากผู้ใช้', 'Hidden'), color: Colors.grey),
                                      ],
                                    ),

                                    const SizedBox(height: 12),
                                    const Divider(height: 1),
                                    const SizedBox(height: 8),

                                    // ── Action Buttons ──
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.end,
                                      children: [
                                        // ปักหมุด
                                        IconButton(
                                          icon: Icon(
                                            zone.pinned ? Icons.push_pin : Icons.push_pin_outlined,
                                            color: zone.pinned ? const Color(0xFF3498DB) : Colors.grey,
                                          ),
                                          tooltip: zone.pinned ? tr('เลิกปักหมุด', 'Unpin') : tr('ปักหมุด (+10 R)', 'Pin (+10 R)'),
                                          onPressed: () => _togglePinZone(zone),
                                        ),
                                        // ซ่อน / แสดง
                                        IconButton(
                                          icon: Icon(
                                            zone.hidden ? Icons.visibility_off : Icons.visibility,
                                            color: zone.hidden ? Colors.grey : const Color(0xFF2ECC71),
                                          ),
                                          tooltip: zone.hidden ? tr('แสดงผล', 'Show') : tr('ซ่อน', 'Hide'),
                                          onPressed: () => _toggleHideZone(zone),
                                        ),
                                        // คำนวณใหม่
                                        IconButton(
                                          icon: const Icon(Icons.sync, color: Color(0xFFE67E22)),
                                          tooltip: tr('คำนวณคะแนนใหม่', 'Recalculate Score'),
                                          onPressed: () => _recalculateZoneScore(zone),
                                        ),
                                        // แก้ไข
                                        IconButton(
                                          icon: const Icon(Icons.edit, color: Color(0xFF3498DB)),
                                          tooltip: tr('แก้ไขชื่อ/คำอธิบาย', 'Edit Name/Desc'),
                                          onPressed: () => _editZoneDialog(zone),
                                        ),
                                        // ลบ (มีตรวจ UC-08 E2)
                                        IconButton(
                                          icon: const Icon(Icons.delete_outline, color: Colors.red),
                                          tooltip: tr('ลบโซน', 'Delete Zone'),
                                          onPressed: () => _deleteZone(zone),
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
    final selected = _filterSource == value;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: FilterChip(
        selected: selected,
        label: Text(label),
        onSelected: (_) => setState(() => _filterSource = value),
      ),
    );
  }

  Widget _buildStatusChip(String value, String label) {
    final selected = _filterStatus == value;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: FilterChip(
        selected: selected,
        label: Text(label),
        onSelected: (_) => setState(() => _filterStatus = selected ? 'all' : value),
      ),
    );
  }

  Widget _badgeChip(IconData icon, String text, {Color? color}) {
    final chipColor = color ?? context.pal.textSub;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: chipColor.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: chipColor.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: chipColor),
          const SizedBox(width: 4),
          Text(text, style: TextStyle(fontSize: 11, color: chipColor, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
