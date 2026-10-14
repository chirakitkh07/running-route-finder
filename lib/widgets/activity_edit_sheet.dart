import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/tr.dart';
import '../models/activity.dart';
import '../providers/theme_provider.dart';
import '../services/firestore_service.dart';

const _accent = Color(0xFFFC4C02);

/// เปิดหน้าต่างแก้ไขกิจกรรมของตัวเอง — คืน true เมื่อบันทึกสำเร็จ
Future<bool> showActivityEditSheet(BuildContext context, Activity activity) async {
  final saved = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => ActivityEditSheet(activity: activity),
  );
  return saved == true;
}

/// แก้ชื่อ / การมองเห็น / ระยะทาง / เวลา / เพซ ของกิจกรรมย้อนหลัง
/// เส้นทาง GPS ที่บันทึกไว้ไม่ถูกแก้ไข
class ActivityEditSheet extends StatefulWidget {
  final Activity activity;
  const ActivityEditSheet({super.key, required this.activity});

  @override
  State<ActivityEditSheet> createState() => _ActivityEditSheetState();
}

class _ActivityEditSheetState extends State<ActivityEditSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _title;
  late final TextEditingController _dist;
  late final TextEditingController _h, _m, _s;
  late final TextEditingController _paceM, _paceS;
  late bool _isPublic;
  bool _saving = false;
  bool _syncing = false; // กัน onChanged วนกันเองตอนคำนวณช่องอื่น

  Activity get a => widget.activity;
  bool get _isCycling => a.activityType == 'cycling';

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: a.title);
    _dist = TextEditingController(text: a.distanceKm.toStringAsFixed(2));
    _h = TextEditingController();
    _m = TextEditingController();
    _s = TextEditingController();
    _paceM = TextEditingController();
    _paceS = TextEditingController();
    _isPublic = a.isPublic;
    _setDuration(a.durationSeconds);
    _recalcPace();
  }

  @override
  void dispose() {
    for (final c in [_title, _dist, _h, _m, _s, _paceM, _paceS]) {
      c.dispose();
    }
    super.dispose();
  }

  // ─── ค่าในฟอร์ม ──────────────────────────────────────────

  double? get _distanceKm =>
      double.tryParse(_dist.text.trim().replaceAll(',', '.'));

  int get _durationSec =>
      (int.tryParse(_h.text) ?? 0) * 3600 +
      (int.tryParse(_m.text) ?? 0) * 60 +
      (int.tryParse(_s.text) ?? 0);

  int get _paceSec => (int.tryParse(_paceM.text) ?? 0) * 60 + (int.tryParse(_paceS.text) ?? 0);

  void _setDuration(int secs) {
    _syncing = true;
    _h.text = '${secs ~/ 3600}';
    _m.text = '${(secs % 3600) ~/ 60}'.padLeft(2, '0');
    _s.text = '${secs % 60}'.padLeft(2, '0');
    _syncing = false;
  }

  /// แก้ระยะทางหรือเวลา → คำนวณเพซใหม่
  void _recalcPace() {
    if (_syncing) return;
    final d = _distanceKm;
    final t = _durationSec;
    _syncing = true;
    if (d != null && d > 0 && t > 0) {
      final pace = (t / d).round();
      _paceM.text = '${pace ~/ 60}';
      _paceS.text = '${pace % 60}'.padLeft(2, '0');
    }
    _syncing = false;
    setState(() {});
  }

  /// แก้เพซ → คำนวณเวลาใหม่ (ระยะทางคงเดิม)
  void _recalcDurationFromPace() {
    if (_syncing) return;
    final d = _distanceKm;
    final p = _paceSec;
    if (d != null && d > 0 && p > 0) _setDuration((p * d).round());
    setState(() {});
  }

  void _restoreOriginal() {
    final o = a.originalStats;
    if (o == null) return;
    _syncing = true;
    _dist.text = (o['distanceKm'] ?? 0).toDouble().toStringAsFixed(2);
    _syncing = false;
    _setDuration((o['durationSeconds'] ?? 0).toInt());
    _recalcPace();
  }

  // ─── ตรวจค่า ──────────────────────────────────────────────

  String? _validateDistance(String? v) {
    final d = double.tryParse((v ?? '').trim().replaceAll(',', '.'));
    if (d == null) return tr('กรอกระยะทางเป็นตัวเลข', 'Enter a number');
    if (d < 0.01) return tr('ระยะทางต้องมากกว่า 0', 'Distance must be above 0');
    if (d > 300) return tr('ระยะทางมากเกินไป (สูงสุด 300 กม.)', 'Too far (max 300 km)');
    return null;
  }

  String? _durationError() {
    final t = _durationSec;
    if (t <= 0) return tr('เวลาต้องมากกว่า 0', 'Duration must be above 0');
    if (t > 48 * 3600) return tr('เวลานานเกินไป (สูงสุด 48 ชม.)', 'Too long (max 48 h)');
    if ((int.tryParse(_m.text) ?? 0) > 59 || (int.tryParse(_s.text) ?? 0) > 59) {
      return tr('นาที/วินาที ต้องไม่เกิน 59', 'Minutes/seconds must be 0–59');
    }
    final d = _distanceKm;
    if (d != null && d > 0) {
      final pace = t / d;
      final minPace = _isCycling ? 45 : 120; // เร็วสุด: ปั่น 80 กม./ชม., วิ่ง 2:00 /กม.
      if (pace < minPace) {
        return tr('ความเร็วสูงเกินจริงสำหรับ${_isCycling ? 'การปั่น' : 'การวิ่ง'} กรุณาตรวจระยะทาง/เวลา',
            'Speed is unrealistically high for ${_isCycling ? 'cycling' : 'running'}. Check distance/time');
      }
      if (pace > 3600) {
        return tr('ช้าเกินไป (เกิน 60 นาที/กม.) กรุณาตรวจระยะทาง/เวลา',
            'Too slow (over 60 min/km). Check distance/time');
      }
    }
    return null;
  }

  Future<void> _save() async {
    final durErr = _durationError();
    final ok = _formKey.currentState!.validate();
    setState(() {});
    if (!ok || durErr != null || a.id == null) return;
    setState(() => _saving = true);
    try {
      await FirestoreService().updateActivityDetails(
        a.uid,
        a.id!,
        title: _title.text.trim(),
        isPublic: _isPublic,
        distanceKm: double.parse(_distanceKm!.toStringAsFixed(3)),
        durationSeconds: _durationSec,
      );
      if (!mounted) return;
      Navigator.pop(context, true);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr('บันทึกการแก้ไขแล้ว', 'Changes saved')),
        backgroundColor: const Color(0xFF2E7D32),
        behavior: SnackBarBehavior.floating,
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr('บันทึกไม่สำเร็จ กรุณาลองอีกครั้ง', 'Could not save. Please try again')),
        backgroundColor: const Color(0xFFE53935),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  // ─── UI ──────────────────────────────────────────────────

  InputDecoration _dec(String label, {String? suffix, String? hint}) {
    final pal = context.pal;
    return InputDecoration(
      labelText: label,
      hintText: hint,
      suffixText: suffix,
      isDense: true,
      counterText: '',
      labelStyle: TextStyle(color: pal.textMute),
      filled: true,
      fillColor: pal.surface2,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: pal.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: pal.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: _accent, width: 1.5),
      ),
    );
  }

  Widget _numField(TextEditingController c, String label,
      {required VoidCallback onChanged, int maxLen = 2}) {
    return TextField(
      controller: c,
      textAlign: TextAlign.center,
      keyboardType: TextInputType.number,
      maxLength: maxLen,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      style: TextStyle(color: context.pal.text, fontWeight: FontWeight.w700),
      decoration: _dec(label),
      onChanged: (_) => onChanged(),
    );
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text,
            style: TextStyle(
                fontSize: 13, fontWeight: FontWeight.w700, color: context.pal.textSub)),
      );

  Widget _visibilityChip(bool public) {
    final pal = context.pal;
    final selected = _isPublic == public;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _isPublic = public),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: selected ? _accent.withValues(alpha: 0.12) : pal.surface2,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: selected ? _accent : pal.border, width: selected ? 1.5 : 1),
          ),
          child: Column(children: [
            Icon(public ? Icons.public_rounded : Icons.lock_rounded,
                color: selected ? _accent : pal.textMute, size: 20),
            const SizedBox(height: 4),
            Text(public ? tr('สาธารณะ', 'Public') : tr('ส่วนตัว', 'Private'),
                style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: selected ? _accent : pal.textSub)),
            Text(
                public
                    ? tr('ทุกคนเห็นในฟีดชุมชน', 'Shown in community feed')
                    : tr('เห็นเฉพาะคุณ', 'Only you can see'),
                style: TextStyle(fontSize: 10, color: pal.textMute)),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final durErr = _durationError();
    final d = _distanceKm;
    final t = _durationSec;
    final speed = (d != null && d > 0 && t > 0) ? d / (t / 3600) : 0.0;
    final gpsKm = a.gpsTrackKm;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.9),
        decoration: BoxDecoration(
          color: pal.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                          color: pal.border, borderRadius: BorderRadius.circular(2)),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(children: [
                    const Icon(Icons.edit_rounded, color: _accent),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(tr('แก้ไขกิจกรรม', 'Edit activity'),
                          style: TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w800, color: pal.text)),
                    ),
                    Text(a.formattedDate,
                        style: TextStyle(fontSize: 12, color: pal.textMute)),
                  ]),
                  const SizedBox(height: 18),

                  // ชื่อ
                  TextFormField(
                    controller: _title,
                    maxLength: 60,
                    style: TextStyle(color: pal.text),
                    decoration: _dec(tr('ชื่อกิจกรรม', 'Activity name')),
                    validator: (v) => (v == null || v.trim().isEmpty)
                        ? tr('กรุณากรอกชื่อกิจกรรม', 'Please enter a name')
                        : null,
                  ),
                  const SizedBox(height: 16),

                  // การมองเห็น
                  _sectionLabel(tr('การมองเห็น', 'Visibility')),
                  Row(children: [
                    _visibilityChip(true),
                    const SizedBox(width: 10),
                    _visibilityChip(false),
                  ]),
                  const SizedBox(height: 18),

                  // สถิติ
                  Row(children: [
                    Expanded(child: _sectionLabel(tr('สถิติ', 'Stats'))),
                    if (a.originalStats != null)
                      TextButton.icon(
                        onPressed: _restoreOriginal,
                        icon: const Icon(Icons.restore_rounded, size: 16, color: _accent),
                        label: Text(tr('คืนค่าจาก GPS', 'Restore GPS values'),
                            style: const TextStyle(color: _accent, fontSize: 12)),
                      ),
                  ]),
                  TextFormField(
                    controller: _dist,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
                    maxLength: 7,
                    style: TextStyle(color: pal.text, fontWeight: FontWeight.w700),
                    decoration: _dec(tr('ระยะทาง', 'Distance'), suffix: 'km'),
                    validator: _validateDistance,
                    onChanged: (_) => _recalcPace(),
                  ),
                  if (gpsKm > 0.01)
                    Padding(
                      padding: const EdgeInsets.only(top: 4, left: 4),
                      child: Text(
                          tr('ระยะตามเส้นทาง GPS ที่บันทึก: ${gpsKm.toStringAsFixed(2)} km',
                              'Recorded GPS track: ${gpsKm.toStringAsFixed(2)} km'),
                          style: TextStyle(fontSize: 11, color: pal.textMute)),
                    ),
                  const SizedBox(height: 14),
                  Text(tr('เวลา (ชม. : นาที : วินาที)', 'Time (h : min : s)'),
                      style: TextStyle(fontSize: 12, color: pal.textMute)),
                  const SizedBox(height: 6),
                  Row(children: [
                    Expanded(child: _numField(_h, tr('ชม.', 'h'), onChanged: _recalcPace)),
                    const SizedBox(width: 8),
                    Expanded(child: _numField(_m, tr('นาที', 'min'), onChanged: _recalcPace)),
                    const SizedBox(width: 8),
                    Expanded(child: _numField(_s, tr('วินาที', 's'), onChanged: _recalcPace)),
                  ]),
                  const SizedBox(height: 14),
                  Text(tr('เพซเฉลี่ย (นาที : วินาที ต่อ กม.) — แก้แล้วเวลาจะคำนวณใหม่',
                          'Avg pace (min : s per km) — editing it recalculates time'),
                      style: TextStyle(fontSize: 12, color: pal.textMute)),
                  const SizedBox(height: 6),
                  Row(children: [
                    Expanded(
                        child: _numField(_paceM, tr('นาที', 'min'),
                            onChanged: _recalcDurationFromPace)),
                    const SizedBox(width: 8),
                    Expanded(
                        child: _numField(_paceS, tr('วินาที', 's'),
                            onChanged: _recalcDurationFromPace)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        decoration: BoxDecoration(
                          color: _accent.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(children: [
                          Text(speed.toStringAsFixed(1),
                              style: const TextStyle(
                                  fontWeight: FontWeight.w800, color: _accent)),
                          Text('km/h', style: TextStyle(fontSize: 10, color: pal.textMute)),
                        ]),
                      ),
                    ),
                  ]),
                  if (durErr != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6, left: 4),
                      child: Text(durErr,
                          style: const TextStyle(color: Color(0xFFE53935), fontSize: 12)),
                    ),
                  const SizedBox(height: 16),

                  // แจ้งว่าเส้นทางไม่ถูกแก้
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: pal.surface2,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: pal.border),
                    ),
                    child: Row(children: [
                      Icon(Icons.route_rounded, size: 18, color: pal.textSub),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          tr('เส้นทาง GPS และวันเวลาที่วิ่งจะไม่ถูกเปลี่ยน — แก้ได้เฉพาะชื่อ การมองเห็น และสถิติ',
                              'The GPS route and date are kept as recorded — only name, visibility and stats change'),
                          style: TextStyle(fontSize: 12, color: pal.textSub, height: 1.4),
                        ),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 18),

                  SizedBox(
                    height: 50,
                    child: ElevatedButton(
                      onPressed: _saving ? null : _save,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _accent,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                      child: _saving
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2.5, color: Colors.white))
                          : Text(tr('บันทึกการแก้ไข', 'Save changes'),
                              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
