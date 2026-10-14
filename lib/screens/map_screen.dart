import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:provider/provider.dart';
import '../models/route_data.dart';
import '../models/running_zone.dart';
import '../models/incident_report.dart';
import 'record_screen.dart';
import '../services/ai_moderation_service.dart';
import '../services/api_service.dart';
import '../services/firestore_service.dart';
import '../services/routing_service.dart';
import '../services/zone_service.dart';
import '../services/zone_discovery_service.dart';
import '../services/zone_recommender.dart';
import '../services/safety_service.dart';
import '../services/safety_score_engine.dart';
import '../services/air_quality_service.dart';
import '../services/simulation_engine.dart';
import '../services/road_context_service.dart';
import '../utils/geo_utils.dart';
import '../utils/difficulty_utils.dart';
import '../services/safety_dijkstra_service.dart';
import '../services/location_helper.dart';
import '../providers/language_provider.dart';
import '../l10n/app_strings.dart';
import '../l10n/tr.dart';
import 'package:demo20426/providers/theme_provider.dart';

class MapScreen extends StatefulWidget {
  final RunningRoute? initialRoute;
  /// เปิดหน้าแผนที่แล้วเลือกโซนวิ่งนี้ทันที (จากการ์ดสถานที่วิ่งหน้าหลัก)
  final String? initialZoneId;
  final Function(RunningRoute)? onStartRun;
  const MapScreen({super.key, this.initialRoute, this.initialZoneId, this.onStartRun});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  /// สีพื้น/ตัวอักษรตามธีมปัจจุบัน
  AppPalette get pal => context.pal;

  bool get _isThai {
    try {
      return context.read<LanguageProvider>().isThai;
    } catch (_) {
      return true;
    }
  }

  AppStrings get _s => AppStrings(isThai: _isThai);

  // ศูนย์กลางเชียงใหม่ (Default)
  final LatLng _chiangMaiCenter = const LatLng(18.7883, 98.9853);
  final MapController _mapController = MapController();

  LatLng? _currentPosition;
  StreamSubscription<Position>? _positionStreamSub;

  bool _isLoading = false;
  Map<String, dynamic>? _simulationData;
  LatLng? _selectedPoint;
  RunningRoute? _selectedRoute;
  bool _showRouteList = false;
  List<LatLng>? _fetchedPath; // เส้นทางจริงจาก Routing API
  bool _isFetchingRoute = false;

  // ── Running Zones ──
  List<RunningZone> _zones = [];
  RunningZone? _selectedZone;
  String? _pendingZoneId; // โซนที่ต้องเลือกเมื่อโหลดเสร็จ (เปิดจากเส้นทางยอดนิยมหน้าหลัก)

  /// เส้นทางยอดนิยมเดิม (RunningRoute.id) → โซนที่ตรงกัน
  static const Map<String, String> _routeToZoneId = {
    'moat_loop': 'zone_moat',
    'buak_had': 'zone_buakhad',
    'huay_tueng_thao': 'zone_huaytueng',
    'cmu_campus': 'zone_cmu',
    'stadium_700': 'zone_700yr',
    'doi_suthep': 'zone_suthep',
  };

  /// เส้นทางยอดนิยมที่ตรงกับโซน (ถ้ามี) — ใช้ผูกปุ่มเส้นทางโปรดในการ์ดโซน
  RunningRoute? _popularRouteForZone(RunningZone zone) {
    for (final e in _routeToZoneId.entries) {
      if (e.value != zone.id) continue;
      for (final r in ChiangMaiRoutes.routes) {
        if (r.id == e.key) return r;
      }
    }
    return null;
  }

  /// พื้นที่โซน (ตร.ม.) — ใช้เลือกโซนที่เล็กที่สุดเมื่อแตะจุดที่โซนซ้อนกัน
  double _zoneAreaM2(RunningZone z) =>
      z.polygons.fold(0.0, (s, r) => s + GeoUtils.calculateShoelaceArea(r));

  /// เลือกโซนที่ตรงกับเส้นทางยอดนิยม (ถ้าโหลดโซนแล้ว)
  bool _trySelectPendingZone() {
    final id = _pendingZoneId;
    if (id == null) return false;
    for (final z in _zones) {
      if (z.id == id) {
        _pendingZoneId = null;
        _selectZone(z);
        return true;
      }
    }
    return false;
  }
  bool _isZoneCardExpanded = false;
  bool _isGeneratingLoop = false;
  int _selectedLaps = 1; // จำนวนรอบของเส้นทางมาตรฐานในโซน
  bool _isDiscoveringZones = false;

  // ── Route Planning Mode ──
  bool _isRoutePlanMode = false;
  LatLng? _routeStartPoint;
  LatLng? _routeEndPoint;
  List<LatLng>? _routePlanPath;
  bool _isFetchingRoutePlan = false;
  Map<String, dynamic>? _routeSafetyData;
  double? _routeDistanceKm;
  String? _routeEstimatedTime;
  LatLng? _routeMidPoint;

  // ── Safety-Aware Dijkstra ──
  bool _routeCardCollapsed = false;    // ย่อการ์ดผลวิเคราะห์เส้นทาง เพื่อให้เห็นเส้นทางบนแผนที่
  bool _useSafetyDijkstra = true;       // ใช้ Safety-Aware Dijkstra เป็นค่าเริ่มต้นโดยตรงเสมอ
  SafetyDijkstraResult? _dijkstraResult; // ผลลัพธ์จาก Dijkstra

  // ── Real-time Traffic Layer ──
  final double _trafficLayerOpacity = 0.75;
  // TomTom Traffic Flow Tiles (URL ที่ถูกต้อง — Key จาก developer.tomtom.com)
  // สีเขียว = ไหลดี | เหลือง = ช้า | แดง = ติดมาก
  static const String _tomtomKey = 'dQ9QXJC2t9eQVZ8k9RpLsddMXhEFuqCM';
  // แสดงสภาพจราจรแบบ Real-time บนแผนที่อัตโนมัติเสมอ (ไม่ต้องกดเปิด/ปิด)

  // Feature 3: Elevation Profile
  List<double> _elevationPoints = [];
  double? _elevationGainM;
  double? _elevationLossM;
  // UC-02 / UC-04: ประเภทกิจกรรม จังหวะเฉลี่ย และผลการจำลอง
  String _planActivityType = 'running'; // 'running' | 'cycling'
  double? _customPaceMinPerKm; // UC-04 A1: ผู้ใช้ปรับความเร็วเฉลี่ยเอง
  int? _routeCalories;
  String? _routeDifficulty;
  bool _routeCardExpanded = false; // การ์ดเส้นทางแนะนำ: ย่อไว้ก่อนเพื่อไม่บังแผนที่
  bool _isFetchingElevation = false;

  // Feature 7: PM2.5 ต่อเส้นทาง
  double? _routePm25;
  bool _isLoadingPm25 = false;

  // Feature 8 + 9: ฟิลเตอร์และเรียงเส้นทาง
  String _filterDifficulty = 'all'; // 'all' | 'easy' | 'moderate' | 'hard'
  double _filterMaxKm = 30;         // ระยะทางสูงสุด (km)
  bool _filterFavOnly = false;       // แสดงเฉพาะโปรด
  bool _sortByProximity = false;     // Feature 9: เรียงตามระยะใกล้-ไกล

  // Feature 12: AQI Circle บนแผนที่
  // ignore: unused_field
  bool _showAqiOverlay = false;
  // ignore: unused_field
  double? _currentAqiPm25;
  // ignore: unused_field
  bool _isFetchingAqi = false;

  // Feature 16: เส้นทางโปรด
  Set<String> _savedRouteIds = {};

  // FR 8, 9, 10, 13, 14: Incident Reporting State & Methods
  bool _isReportMode = false;
  List<IncidentReport> _activeIncidents = [];
  StreamSubscription<List<IncidentReport>>? _incidentsSub;
  final FirestoreService _firestoreService = FirestoreService();

  // ── Traffic Scoring State (TomTom + Intersections) ──
  double _trafficCongestionPct  = 0.0; // % ของเส้นทางที่รถติดสีแดง
  int    _trafficLightCount     = 0;   // จำนวนแยกสัญญาณไฟ
  List<List<LatLng>> _trafficSegments   = []; // segment รถติดสำหรับส่ง Dijkstra
  List<LatLng>       _trafficLightNodes = []; // จุดแยกไฟสำหรับส่ง Dijkstra

  Timer? _ttlTimer;

  void _listenActiveIncidents() {
    _incidentsSub = _firestoreService.streamActiveIncidents().listen((incidents) {
      if (mounted) {
        setState(() => _activeIncidents = incidents);
      }
    });
    // กลไกกำหนดอายุข้อมูล (TTL): ตรวจรายงานหมดอายุเมื่อเปิดหน้าแผนที่ และทุก 10 นาที
    _firestoreService.expireStaleIncidents();
    _ttlTimer?.cancel();
    _ttlTimer = Timer.periodic(const Duration(minutes: 10), (_) {
      _firestoreService.expireStaleIncidents();
      if (mounted) {
        final now = DateTime.now();
        setState(() => _activeIncidents =
            _activeIncidents.where((i) => i.expiresAt.isAfter(now)).toList());
      }
    });
  }

  Color _getIncidentColor(String type) {
    switch (type) {
      case 'dogs':
        return const Color(0xFFE67E22);
      case 'slippery':
        return const Color(0xFF3498DB);
      case 'construction':
        return const Color(0xFFF39C12);
      case 'lighting':
        return const Color(0xFF8E44AD);
      case 'flooding':
        return const Color(0xFF2980B9);
      case 'accident':
        return const Color(0xFFE74C3C);
      default:
        return const Color(0xFFFC4C02);
    }
  }

  String _getIncidentEmoji(String type) {
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

  void _handleReportPinTap(LatLng point) {
    _showIncidentReportModal(point);
  }

  void _showIncidentReportModal(LatLng point) {
    final descController = TextEditingController();
    String selectedType = 'dogs';
    int hoursToExpire = 24;
    bool isSubmitting = false; // loading state ระหว่างตรวจสอบ AI + บันทึก

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final isDark = Theme.of(context).brightness == Brightness.dark;
            final modalBg = pal.surface;
            final textPrimary = pal.text;
            final textSecondary = pal.textSub;

            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
              ),
              child: Container(
                decoration: BoxDecoration(
                  color: modalBg,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: isDark ? 0.4 : 0.15),
                      blurRadius: 16,
                      offset: const Offset(0, -4),
                    ),
                  ],
                ),
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: Container(
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                            color: isDark ? Colors.white24 : Colors.grey.shade300,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          // โลโก้น่าจิ้ม: วงกลม gradient + emoji แทน icon แบน
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                colors: [Color(0xFFFF6B6B), Color(0xFFFC4C02)],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFFFC4C02).withValues(alpha: 0.40),
                                  blurRadius: 10,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: const Center(
                              child: Text('📍', style: TextStyle(fontSize: 20)),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _s.reportIncident,
                                  style: TextStyle(
                                    color: textPrimary,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 0.2,
                                  ),
                                ),
                                Text(
                                  _s.reportSubtitle,
                                  style: TextStyle(
                                    color: textSecondary,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: Icon(Icons.close_rounded,
                                color: isDark ? Colors.white38 : Colors.grey.shade400,
                                size: 20),
                            onPressed: () => Navigator.pop(ctx),
                          ),
                        ],
                      ),
                      Text(
                        '${_s.incidentCoordinates}: ${point.latitude.toStringAsFixed(4)}, ${point.longitude.toStringAsFixed(4)}',
                        style: TextStyle(color: textSecondary, fontSize: 12),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _s.incidentType,
                        style: TextStyle(
                            color: textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          {'key': 'dogs', 'label': _isThai ? '🐶 สุนัขจรจัด/ดุร้าย' : '🐶 Stray Dogs'},
                          {'key': 'slippery', 'label': _isThai ? '🌧️ ทางลื่น' : '🌧️ Slippery Path'},
                          {'key': 'construction', 'label': _isThai ? '🚧 มีการก่อสร้าง' : '🚧 Construction'},
                          {'key': 'lighting', 'label': _isThai ? '🌙 ไฟส่องสว่างดับ' : '🌙 Lights Out'},
                          {'key': 'flooding', 'label': _isThai ? '🌊 น้ำท่วมขัง' : '🌊 Flooding'},
                          {'key': 'accident', 'label': _isThai ? '🚨 อุบัติเหตุ' : '🚨 Accident'},
                          {'key': 'other', 'label': _isThai ? '⚠️ อื่นๆ' : '⚠️ Other'},
                        ].map((item) {
                          final isSelected = selectedType == item['key'];
                          return ChoiceChip(
                            label: Text(
                              item['label']!,
                              style: TextStyle(
                                color: isSelected
                                    ? Colors.white
                                    : (isDark ? Colors.white : const Color(0xFF1E293B)),
                                fontSize: 12,
                                fontWeight: isSelected
                                    ? FontWeight.bold
                                    : FontWeight.w500,
                              ),
                            ),
                            selected: isSelected,
                            selectedColor: const Color(0xFFFC4C02),
                            color: WidgetStateProperty.resolveWith<Color?>((states) {
                              if (states.contains(WidgetState.selected)) {
                                return const Color(0xFFFC4C02);
                              }
                              return isDark
                                  ? const Color(0xFF222F55)
                                  : const Color(0xFFF1F5F9);
                            }),
                            side: WidgetStateBorderSide.resolveWith((states) {
                              if (states.contains(WidgetState.selected)) {
                                return const BorderSide(
                                    color: Color(0xFFFC4C02), width: 1.5);
                              }
                              return BorderSide(
                                color: isDark
                                    ? Colors.white24
                                    : const Color(0xFFCBD5E1),
                                width: 1,
                              );
                            }),
                            showCheckmark: isSelected,
                            checkmarkColor: Colors.white,
                            onSelected: (_) {
                              setModalState(() => selectedType = item['key']!);
                            },
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _s.incidentDetail,
                        style: TextStyle(
                            color: textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: descController,
                        style: TextStyle(color: textPrimary, fontSize: 14),
                        maxLines: 3,
                        decoration: InputDecoration(
                          hintText: _s.incidentHint,
                          hintStyle: TextStyle(
                              color: isDark ? Colors.white38 : Colors.grey.shade400,
                              fontSize: 13),
                          filled: true,
                          fillColor: isDark
                              ? Colors.white.withValues(alpha: 0.06)
                              : const Color(0xFFF8FAFC),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(
                              color: isDark
                                  ? Colors.transparent
                                  : const Color(0xFFCBD5E1),
                            ),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(
                              color: Color(0xFFFC4C02),
                              width: 1.5,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _s.reportDuration,
                        style: TextStyle(
                            color: textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [6, 12, 24].map((hrs) {
                          final isSel = hoursToExpire == hrs;
                          return Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 4),
                              child: OutlinedButton(
                                style: OutlinedButton.styleFrom(
                                  backgroundColor: isSel
                                      ? const Color(0xFF2ECC71).withValues(alpha: isDark ? 0.2 : 0.15)
                                      : Colors.transparent,
                                  side: BorderSide(
                                    color: isSel
                                        ? const Color(0xFF2ECC71)
                                        : (isDark ? Colors.white24 : const Color(0xFFCBD5E1)),
                                  ),
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10)),
                                ),
                                onPressed: () =>
                                    setModalState(() => hoursToExpire = hrs),
                                child: Text(
                                  '$hrs ${_s.hoursSuffix}',
                                  style: TextStyle(
                                    color: isSel
                                        ? (isDark ? const Color(0xFF2ECC71) : const Color(0xFF16A34A))
                                        : (isDark ? Colors.white70 : const Color(0xFF475569)),
                                    fontWeight: isSel
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                  ),
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 20),
                      SizedBox(
                        width: double.infinity,
                        height: 48,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFFC4C02),
                            disabledBackgroundColor: const Color(0xFF8B3200),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          icon: isSubmitting
                              ? const SizedBox(
                                  width: 18, height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                              : const Icon(Icons.send_rounded, color: Colors.white),
                          label: Text(
                            isSubmitting ? _s.aiModerationWait : _s.sendIncidentReport,
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
                          ),
                          onPressed: isSubmitting
                              ? null
                              : () async {
                                  final currentUser = FirebaseAuth.instance.currentUser;
                                  final userName = currentUser?.displayName ?? currentUser?.email?.split('@').first ?? (_isThai ? 'นักวิ่ง Safety Runner' : 'Safety Runner');
                                  final userId = currentUser?.uid ?? 'anonymous_user';
                                  final typeLabelTh = IncidentReport.getTypeLabelTh(selectedType);

                                  setModalState(() => isSubmitting = true);

                                  // ─── UC-05 Normal Flow Step 3: AI Validate Report Content ───
                                  final moderation = await AiModerationService.validateReport(
                                    incidentType: selectedType,
                                    description: descController.text.trim(),
                                    typeLabelTh: typeLabelTh,
                                  );

                                  // UC-05 E1: ไม่ผ่าน AI Moderation → บันทึก log + แจ้งเตือนด้วย Dialog
                                  // (กรณี AI ไม่ตอบสนอง = UC-15 E2 → ไม่ปฏิเสธ แต่เก็บเป็น pending ด้านล่าง)
                                  if (!moderation.isValid && !moderation.isApiError) {
                                    setModalState(() => isSubmitting = false);

                                    // บันทึก log ลง Firestore (ไม่ต้องรอ)
                                    FirebaseFirestore.instance
                                        .collection('ai_moderation_logs')
                                        .add({
                                          'userId': userId,
                                          'userName': userName,
                                          'incidentType': selectedType,
                                          'typeLabelTh': typeLabelTh,
                                          'content': descController.text.trim(),
                                          'action': moderation.isApiError ? 'api_error' : 'rejected',
                                          'reason': moderation.reason,
                                          'userMessage': moderation.userMessage,
                                          'confidence': moderation.confidence,
                                          'createdAt': FieldValue.serverTimestamp(),
                                        })
                                        .then((_) {}, onError: (e) => debugPrint('[AiModeration] Log write error: $e'));

                                    if (ctx.mounted) {
                                      final isApiErr = moderation.isApiError;
                                      showDialog(
                                        context: ctx,
                                        barrierDismissible: false,
                                        builder: (dialogCtx) => AlertDialog(
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(20),
                                          ),
                                          contentPadding: EdgeInsets.zero,
                                          content: Container(
                                            decoration: BoxDecoration(
                                              borderRadius: BorderRadius.circular(20),
                                              color: Theme.of(context).cardColor,
                                            ),
                                            child: Column(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                // ─── Header ───
                                                Container(
                                                  width: double.infinity,
                                                  padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 20),
                                                  decoration: BoxDecoration(
                                                    borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                                                    color: isApiErr
                                                        ? const Color(0xFFF57C00)
                                                        : const Color(0xFFE53935),
                                                  ),
                                                  child: Column(
                                                    children: [
                                                      Container(
                                                        width: 60,
                                                        height: 60,
                                                        decoration: BoxDecoration(
                                                          color: Colors.white.withValues(alpha: 0.2),
                                                          shape: BoxShape.circle,
                                                        ),
                                                        child: Icon(
                                                          isApiErr
                                                              ? Icons.wifi_off_rounded
                                                              : Icons.smart_toy_rounded,
                                                          color: Colors.white,
                                                          size: 32,
                                                        ),
                                                      ),
                                                      const SizedBox(height: 12),
                                                      Text(
                                                        isApiErr ? tr('ระบบตรวจสอบมีปัญหา', 'Moderation service problem') : _s.aiDetectedIssue,
                                                        style: const TextStyle(
                                                          color: Colors.white,
                                                          fontWeight: FontWeight.bold,
                                                          fontSize: 18,
                                                        ),
                                                        textAlign: TextAlign.center,
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                                // ─── Body ───
                                                Padding(
                                                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                                                  child: Text(
                                                    moderation.userMessage,
                                                    style: TextStyle(
                                                      fontSize: 15,
                                                      color: Theme.of(context).textTheme.bodyMedium?.color,
                                                      height: 1.5,
                                                    ),
                                                    textAlign: TextAlign.center,
                                                  ),
                                                ),
                                                if (!isApiErr)
                                                  Padding(
                                                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                                                    child: Text(
                                                      tr('กรุณาแก้ไขข้อมูลและลองส่งใหม่อีกครั้ง', 'Please edit your report and try again'),
                                                      style: TextStyle(
                                                        fontSize: 13,
                                                        color: Theme.of(context).textTheme.bodySmall?.color,
                                                      ),
                                                      textAlign: TextAlign.center,
                                                    ),
                                                  ),
                                                // ─── Button ───
                                                Padding(
                                                  padding: const EdgeInsets.all(16),
                                                  child: SizedBox(
                                                    width: double.infinity,
                                                    child: ElevatedButton(
                                                      style: ElevatedButton.styleFrom(
                                                        backgroundColor: isApiErr
                                                            ? const Color(0xFFF57C00)
                                                            : const Color(0xFFE53935),
                                                        foregroundColor: Colors.white,
                                                        padding: const EdgeInsets.symmetric(vertical: 14),
                                                        shape: RoundedRectangleBorder(
                                                          borderRadius: BorderRadius.circular(12),
                                                        ),
                                                      ),
                                                      onPressed: () => Navigator.of(dialogCtx).pop(),
                                                      child: Text(
                                                        isApiErr ? tr('ปิด', 'Close') : tr('แก้ไขข้อมูล', 'Edit report'),
                                                        style: const TextStyle(
                                                          fontWeight: FontWeight.bold,
                                                          fontSize: 16,
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      );
                                    }
                                    return;
                                  }

                                  // UC-15 A1 / E2: ความเชื่อมั่นปานกลาง หรือ AI ไม่ตอบสนอง → รอผู้ดูแลตรวจสอบ
                                  final needsReview = moderation.needsAdminReview;

                                  // บันทึก log ลง Firestore พร้อมคะแนนความเชื่อมั่นจริงจาก AI (UC-09)
                                  FirebaseFirestore.instance
                                      .collection('ai_moderation_logs')
                                      .add({
                                        'userId': userId,
                                        'userName': userName,
                                        'incidentType': selectedType,
                                        'typeLabelTh': typeLabelTh,
                                        'content': descController.text.trim(),
                                        'action': moderation.isApiError
                                            ? 'api_error'
                                            : needsReview ? 'review' : 'passed',
                                        'reason': moderation.reason.isNotEmpty
                                            ? moderation.reason
                                            : 'Content passed AI moderation',
                                        'userMessage': moderation.userMessage,
                                        'confidence': moderation.confidence,
                                        'createdAt': FieldValue.serverTimestamp(),
                                      })
                                      .then((_) {}, onError: (e) => debugPrint('[AiModeration] Log write error: $e'));

                                  // ─── UC-05 Normal Flow Step 4: บันทึกลงฐานข้อมูล ───
                                  final report = IncidentReport(
                                    id: '',
                                    userId: userId,
                                    userName: userName,
                                    type: selectedType,
                                    title: typeLabelTh,
                                    description: descController.text.trim(),
                                    latitude: point.latitude,
                                    longitude: point.longitude,
                                    createdAt: DateTime.now(),
                                    expiresAt: DateTime.now().add(Duration(hours: hoursToExpire)),
                                    status: needsReview ? 'pending' : 'active',
                                    aiConfidence: moderation.isApiError ? null : moderation.confidence,
                                  );

                                  try {
                                    await _firestoreService.createIncidentReport(report);
                                    if (ctx.mounted) Navigator.pop(ctx);
                                    if (mounted) {
                                      setState(() => _isReportMode = false);
                                      // UC-05 Normal Flow Step 5: ยืนยันว่าส่งรายงานสำเร็จ
                                      ScaffoldMessenger.of(this.context).showSnackBar(
                                        SnackBar(
                                          content: Row(
                                            children: [
                                              const Icon(Icons.check_circle, color: Colors.white),
                                              const SizedBox(width: 8),
                                              Expanded(
                                                child: Text(needsReview
                                                    ? (_isThai
                                                        ? 'ส่งรายงานแล้ว — รอผู้ดูแลระบบตรวจสอบก่อนแสดงบนแผนที่'
                                                        : 'Report sent — awaiting admin review before it appears on the map')
                                                    : _s.reportSuccess),
                                              ),
                                            ],
                                          ),
                                          backgroundColor: const Color(0xFF2ECC71),
                                          behavior: SnackBarBehavior.floating,
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                        ),
                                      );
                                    }
                                  } catch (e) {
                                    setModalState(() => isSubmitting = false);
                                    if (mounted) {
                                      ScaffoldMessenger.of(this.context).showSnackBar(
                                        SnackBar(content: Text('${_s.reportFailed}: $e'), backgroundColor: Colors.red),
                                      );
                                    }
                                  }
                                },
                        ),
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


  void _showIncidentDetailsModal(IncidentReport inc) {
    final currentUser = FirebaseAuth.instance.currentUser;
    final userId = currentUser?.uid ?? 'anonymous';

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        // ─── State สำหรับ live update ภายใน modal ───
        bool isVoting = false;
        bool localConfirmed = inc.confirmedBy.contains(userId);
        bool localDenied = inc.deniedBy.contains(userId);
        int localConfirmCount = inc.confirmationsCount;
        int localDenialCount = inc.denialsCount;
        bool localResolved = inc.status == 'resolved';

        return StatefulBuilder(
          builder: (ctx2, setModalState) {
            return Container(
              decoration: BoxDecoration(
                color: pal.surface,
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Handle bar ──
                  Center(
                    child: Container(
                      width: 40, height: 4,
                      decoration: BoxDecoration(color: pal.border, borderRadius: BorderRadius.circular(2)),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // ── Resolved banner ──
                  if (localResolved) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF2ECC71).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFF2ECC71).withValues(alpha: 0.4)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.check_circle, color: Color(0xFF2ECC71), size: 18),
                          const SizedBox(width: 8),
                          Text(
                            _isThai ? 'เหตุการณ์นี้ถูกแจ้งว่าหมดไปแล้ว' : 'This incident has been resolved',
                            style: const TextStyle(color: Color(0xFF2ECC71), fontSize: 13, fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                  ],

                  // ── Header row ──
                  Row(
                    children: [
                      Container(
                        width: 44, height: 44,
                        decoration: BoxDecoration(
                          color: _getIncidentColor(inc.type).withValues(alpha: 0.2),
                          shape: BoxShape.circle,
                          border: Border.all(color: _getIncidentColor(inc.type)),
                        ),
                        child: Center(child: Text(_getIncidentEmoji(inc.type), style: const TextStyle(fontSize: 22))),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(inc.displayTitle, style: TextStyle(color: pal.text, fontSize: 16, fontWeight: FontWeight.bold)),
                            Row(children: [
                              Expanded(child: Text('${_isThai ? "รายงานโดย" : "Reported by"}: ${inc.userName}', style: TextStyle(color: pal.textSub, fontSize: 12))),
                              IconButton(
                                tooltip: _isThai ? 'ตรวจสอบความถูกต้อง' : 'Verify Accuracy',
                                icon: Icon(Icons.verified_outlined, color: pal.textSub, size: 18),
                                onPressed: () async {
                                  try {
                                    final res = await _firestoreService.getIncidentVerification(inc.id);
                                    if (!mounted) return;
                                    showDialog(
                                      context: context,
                                      builder: (dCtx) => AlertDialog(
                                        title: Text(_s.verificationResult),
                                        content: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text('${_isThai ? "สถานะ" : "Status"}: ${res['verified'] == true ? _s.verified : _s.unverified}'),
                                            const SizedBox(height: 8),
                                            Text('${_s.scoreLabel}: ${(res['score'] as num).toStringAsFixed(2)}'),
                                            const SizedBox(height: 8),
                                            Text('${_s.reasonLabel}: ${res['reason']}'),
                                            const SizedBox(height: 8),
                                            Text('${_s.confirmedByCount}: ${res['confirmations']} ${_s.peopleCount}'),
                                            Text('${_s.deniedByCount}: ${res['denials']} ${_s.peopleCount}'),
                                          ],
                                        ),
                                        actions: [
                                          TextButton(onPressed: () => Navigator.pop(dCtx), child: Text(_s.close)),
                                        ],
                                      ),
                                    );
                                  } catch (e) {
                                    if (!mounted) return;
                                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${_isThai ? "ไม่สามารถตรวจสอบได้" : "Unable to verify"}: $e')));
                                  }
                                },
                              ),
                            ]),
                          ],
                        ),
                      ),
                    ],
                  ),

                  // ── Description ──
                  if (inc.description.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: pal.surface2,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(inc.description, style: TextStyle(color: pal.text, fontSize: 14)),
                    ),
                  ],
                  const SizedBox(height: 14),

                  // ── Live vote counter ──
                  Row(
                    children: [
                      const Icon(Icons.thumb_up_alt_outlined, color: Color(0xFF2ECC71), size: 16),
                      const SizedBox(width: 4),
                      Text('$localConfirmCount', style: const TextStyle(color: Color(0xFF2ECC71), fontSize: 12, fontWeight: FontWeight.w700)),
                      const SizedBox(width: 12),
                      const Icon(Icons.thumb_down_alt_outlined, color: Color(0xFFE74C3C), size: 16),
                      const SizedBox(width: 4),
                      Text('$localDenialCount', style: const TextStyle(color: Color(0xFFE74C3C), fontSize: 12, fontWeight: FontWeight.w700)),
                      const Spacer(),
                      Icon(Icons.timer_outlined, color: pal.textSub, size: 16),
                      const SizedBox(width: 4),
                      Text(
                        '${_isThai ? "หมดในอีก" : "Expires in"} ${inc.expiresAt.difference(DateTime.now()).inHours.clamp(0, 99)} ${_s.hoursSuffix}',
                        style: TextStyle(color: pal.textSub, fontSize: 12),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // ── Action buttons ──
                  if (isVoting)
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: CircularProgressIndicator(color: Color(0xFF2ECC71), strokeWidth: 2.5),
                      ),
                    )
                  else
                    Row(
                      children: [
                        // ── ยืนยันว่ายังอยู่ ──
                        Expanded(
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: localConfirmed
                                  ? const Color(0xFF2ECC71)
                                  : const Color(0xFF2ECC71).withValues(alpha: 0.2),
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            icon: Icon(
                              localConfirmed ? Icons.thumb_up_alt : Icons.thumb_up_alt_outlined,
                              size: 16,
                            ),
                            label: Text(
                              localConfirmed
                                  ? (_isThai ? '✓ ยืนยันแล้ว' : '✓ Confirmed')
                                  : _s.stillThere,
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                            onPressed: (currentUser == null || localConfirmed) ? null : () async {
                              setModalState(() => isVoting = true);
                              try {
                                await _firestoreService.confirmIncidentReport(inc.id, userId);
                                setModalState(() {
                                  localConfirmed = true;
                                  localDenied = false;
                                  localConfirmCount++;
                                  isVoting = false;
                                });
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Row(
                                        children: [
                                          const Icon(Icons.check_circle, color: Color(0xFF2ECC71)),
                                          const SizedBox(width: 8),
                                          Text(_s.incidentStillThereSuccess),
                                        ],
                                      ),
                                      backgroundColor: const Color(0xFF1A2A3A),
                                      behavior: SnackBarBehavior.floating,
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                    ),
                                  );
                                }
                              } catch (e) {
                                setModalState(() => isVoting = false);
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text('${_isThai ? "เกิดข้อผิดพลาด" : "Error"}: $e'),
                                      backgroundColor: Colors.red,
                                    ),
                                  );
                                }
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 10),

                        // ── ไม่อยู่แล้ว ──
                        Expanded(
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: localDenied ? const Color(0xFFE74C3C) : pal.textSub,
                              side: BorderSide(
                                color: localDenied ? const Color(0xFFE74C3C) : pal.border,
                              ),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            icon: Icon(
                              localDenied ? Icons.check_circle : Icons.check_circle_outline,
                              size: 16,
                            ),
                            label: Text(
                              localDenied
                                  ? (_isThai ? '✓ แจ้งแล้ว' : '✓ Reported')
                                  : _s.goneAlready,
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                            onPressed: (currentUser == null || localDenied) ? null : () async {
                              setModalState(() => isVoting = true);
                              try {
                                await _firestoreService.resolveIncidentReport(inc.id, userId);
                                final newDenialCount = localDenialCount + 1;
                                setModalState(() {
                                  localDenied = true;
                                  localConfirmed = false;
                                  localDenialCount = newDenialCount;
                                  if (newDenialCount >= 3) localResolved = true;
                                  isVoting = false;
                                });
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Row(
                                        children: [
                                          const Icon(Icons.check_circle, color: Color(0xFF2ECC71)),
                                          const SizedBox(width: 8),
                                          Expanded(child: Text(
                                            newDenialCount >= 3
                                                ? (_isThai ? '✅ เหตุการณ์ถูกยืนยันว่าหมดไปแล้ว!' : '✅ Incident marked as resolved!')
                                                : _s.incidentGoneSuccess,
                                          )),
                                        ],
                                      ),
                                      backgroundColor: const Color(0xFF1A2A3A),
                                      behavior: SnackBarBehavior.floating,
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                    ),
                                  );
                                }
                              } catch (e) {
                                setModalState(() => isVoting = false);
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text('${_isThai ? "เกิดข้อผิดพลาด" : "Error"}: $e'),
                                      backgroundColor: Colors.red,
                                    ),
                                  );
                                }
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  void initState() {
    super.initState();
    _loadFavorites();
    // บน Web: Safari / Chrome บล็อกการขอ Location Prompt อัตโนมัติใน initState
    // จะขอตำแหน่งเมื่อผู้ใช้กดปุ่มระบุตำแหน่ง หรือเริ่มใช้งานแผนที่
    if (!kIsWeb) {
      _getCurrentLocation();
    }
    _listenActiveIncidents();
    if (widget.initialZoneId != null) _pendingZoneId = widget.initialZoneId;
    _loadZones();
    if (widget.initialRoute != null) {
      // เส้นทางยอดนิยมจากหน้าหลัก → แสดงเป็นโซน (วงกลมสีตามคะแนน) แทนเส้นทางวาดมือ
      final zoneId = _routeToZoneId[widget.initialRoute!.id];
      if (zoneId != null) {
        _pendingZoneId = zoneId;
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _selectRoute(widget.initialRoute!);
        });
      }
    }
  }

  @override
  void dispose() {
    _positionStreamSub?.cancel();
    _incidentsSub?.cancel();
    _ttlTimer?.cancel();
    super.dispose();
  }

  bool get _isCurrentPosValid =>
      _currentPosition != null &&
      _currentPosition!.latitude.isFinite &&
      _currentPosition!.longitude.isFinite;

  Future<void> _getCurrentLocation({bool showDialogs = false}) async {
    try {
      final ok = await LocationHelper.checkAndRequestPermission(
        context: context,
        showDialogs: showDialogs,
      );
      if (!ok) return;

      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );

      if (mounted && pos.latitude.isFinite && pos.longitude.isFinite) {
        final newPos = LatLng(pos.latitude, pos.longitude);
        setState(() {
          _currentPosition = newPos;
        });
        if (widget.initialRoute == null) {
          _mapController.move(newPos, 15.0);
        }
      }

      // Stream position updates
      _positionStreamSub?.cancel();
      _positionStreamSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 5,
        ),
      ).listen((Position position) {
        if (mounted && position.latitude.isFinite && position.longitude.isFinite) {
          setState(() {
            _currentPosition = LatLng(position.latitude, position.longitude);
          });
        }
      });
    } catch (e) {
      debugPrint('Error getting user location: $e');
    }
  }

  /// คีย์แคชเส้นทางโปรดในเครื่อง แยกตามบัญชี (กันเส้นทางโปรดของบัญชีอื่นในเครื่องเดียวกันปนกัน)
  static String _favoritesKey(String? uid) => uid == null ? 'savedRoutes' : 'savedRoutes_$uid';

  Future<void> _loadFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    final uid = FirebaseAuth.instance.currentUser?.uid;
    var saved = prefs.getStringList(_favoritesKey(uid));
    if (saved == null && uid != null) {
      // ย้ายแคชรุ่นเก่า (ไม่แยกบัญชี) มาเป็นของบัญชีที่ล็อกอินอยู่ครั้งเดียว
      saved = prefs.getStringList('savedRoutes');
      await prefs.remove('savedRoutes');
    }
    saved ??= [];
    if (mounted) setState(() => _savedRouteIds = saved!.toSet());
    // IT-08: เส้นทางโปรดในบัญชีเป็นหลัก (เปลี่ยนเครื่อง/ติดตั้งใหม่ก็ยังอยู่)
    if (uid == null) return;
    List<String>? cloud;
    try {
      cloud = await _firestoreService.getSavedRoutes(uid);
    } catch (e) {
      debugPrint('[Favorites] ดึงเส้นทางโปรดจากบัญชีไม่สำเร็จ ใช้ข้อมูลในเครื่อง: $e');
      return;
    }
    if (cloud == null) {
      // บัญชียังไม่เคยซิงก์ → อัปโหลดรายการในเครื่องขึ้นบัญชี
      if (saved.isNotEmpty) _firestoreService.setSavedRoutes(uid, saved);
      return;
    }
    await prefs.setStringList(_favoritesKey(uid), cloud);
    if (mounted) setState(() => _savedRouteIds = cloud!.toSet());
  }

  Future<void> _toggleFavorite(String routeId) async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      if (_savedRouteIds.contains(routeId)) {
        _savedRouteIds.remove(routeId);
      } else {
        _savedRouteIds.add(routeId);
      }
    });
    final uid = FirebaseAuth.instance.currentUser?.uid;
    await prefs.setStringList(_favoritesKey(uid), _savedRouteIds.toList());
    // IT-08: บันทึกเส้นทางโปรดเข้าบัญชีส่วนตัว
    if (uid != null) _firestoreService.setSavedRoutes(uid, _savedRouteIds.toList());
  }

  Future<void> _fetchRoutePm25(RunningRoute route) async {
    if (route.path.isEmpty) return;
    setState(() => _isLoadingPm25 = true);
    try {
      final mid = route.path[route.path.length ~/ 2];
      final data = await ApiService.getPreRunSimulation(mid.latitude, mid.longitude);
      final pm25 = double.tryParse(data['airQuality']['pm2_5']?.toString() ?? '0') ?? 0;
      if (!mounted) return;
      setState(() { _routePm25 = pm25; _isLoadingPm25 = false; });
      if (pm25 > 75) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Row(children: [const Icon(Icons.warning_amber_rounded, color: Colors.white), const SizedBox(width: 8),
            Expanded(child: Text(_isThai ? '⚠️ PM2.5 สูงมาก (${pm25.toStringAsFixed(0)} μg) ไม่เหมาะออกกำลังกายกลางแจ้ง!' : '⚠️ Very high PM2.5 (${pm25.toStringAsFixed(0)} μg) Outdoor run not advised!'))]),
          backgroundColor: const Color(0xFFE74C3C), behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          duration: const Duration(seconds: 4),
        ));
      } else if (pm25 > 35) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Row(children: [const Icon(Icons.blur_on, color: Colors.white), const SizedBox(width: 8),
            Expanded(child: Text(_isThai ? '🟡 PM2.5 ปานกลาง (${pm25.toStringAsFixed(0)} μg) ควรใส่หน้ากากตอนวิ่ง' : '🟡 Moderate PM2.5 (${pm25.toStringAsFixed(0)} μg) Wear a mask while running'))]),
          backgroundColor: const Color(0xFFF39C12), behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          duration: const Duration(seconds: 3),
        ));
      }
    } catch (_) {
      if (mounted) setState(() => _isLoadingPm25 = false);
    }
  }

  // Waypoint icon mapping
  IconData _getWaypointIcon(String type) {
    switch (type) {
      case 'rest':
        return Icons.weekend;
      case 'water':
        return Icons.water_drop;
      case 'cafe':
        return Icons.coffee;
      case 'toilet':
        return Icons.wc;
      case 'viewpoint':
        return Icons.photo_camera;
      case 'park':
        return Icons.park;
      case 'danger':
        return Icons.warning_amber_rounded;
      default:
        return Icons.location_on;
    }
  }

  Color _getWaypointColor(String type) {
    switch (type) {
      case 'rest':
        return const Color(0xFF3498DB);
      case 'water':
        return const Color(0xFF00BCD4);
      case 'cafe':
        return const Color(0xFF795548);
      case 'toilet':
        return const Color(0xFF9C27B0);
      case 'viewpoint':
        return const Color(0xFFF1C40F);
      case 'park':
        return const Color(0xFF2ECC71);
      case 'danger':
        return const Color(0xFFE74C3C);
      default:
        return const Color(0xFFFC4C02);
    }
  }

  Color _getDifficultyColor(String difficulty) => getDifficultyColor(difficulty);

  String _getDifficultyLabel(String difficulty) {
    switch (difficulty) {
      case 'easy':
        return _s.easyDifficulty;
      case 'moderate':
        return _s.moderateDifficulty;
      case 'hard':
        return _s.hardDifficulty;
      default:
        return getDifficultyLabel(difficulty, thai: _isThai);
    }
  }

  /// นับรายงานเหตุการณ์ที่ยังไม่หมดอายุภายในรัศมี [radiusM] จากเส้นทาง (ใช้คำนวณ S_inc)
  int _countActiveIncidentsNear(List<LatLng> pts, {double radiusM = 60}) {
    if (pts.isEmpty) return 0;
    final now = DateTime.now();
    final step = (pts.length / 200).ceil().clamp(1, pts.length);
    int count = 0;
    for (final inc in _activeIncidents) {
      if (inc.expiresAt.isBefore(now) || inc.status != 'active') continue;
      for (int i = 0; i < pts.length; i += step) {
        final d = Geolocator.distanceBetween(
            pts[i].latitude, pts[i].longitude, inc.latitude, inc.longitude);
        if (d <= radiusM) {
          count++;
          break;
        }
      }
    }
    return count;
  }

  /// UC-04: คำนวณผลการจำลอง (เวลา แคลอรี ระดับความยาก) จากระยะทางและความสูงสะสม
  void _updateRouteSimulation() {
    final km = _routeDistanceKm;
    if (km == null) return;
    final sim = SimulationEngine.runSimulation(
      distanceKm: km,
      elevationGainM: _elevationGainM ?? 0,
      paceMinPerKm: _customPaceMinPerKm,
      activityType: _planActivityType,
    );
    _routeEstimatedTime = sim.durationLabel;
    _routeCalories = sim.calories;
    _routeDifficulty = _elevationGainM != null ? sim.difficulty : null;
  }

  /// UC-04 A1: ให้ผู้ใช้ปรับความเร็วเฉลี่ย (นาที/กม.) เอง
  Future<void> _showPaceDialog() async {
    double pace = _customPaceMinPerKm ?? SimulationEngine.defaultPace(_planActivityType);
    final result = await showDialog<double>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(_isThai ? 'ปรับความเร็วเฉลี่ย' : 'Adjust average pace'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${pace.floor()}:${((pace - pace.floor()) * 60).round().toString().padLeft(2, '0')} ${_isThai ? "นาที/กม." : "min/km"}',
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
              Slider(
                value: pace,
                min: _planActivityType == 'cycling' ? 1.5 : 3.0,
                max: _planActivityType == 'cycling' ? 6.0 : 12.0,
                divisions: _planActivityType == 'cycling' ? 18 : 36,
                onChanged: (v) => setD(() => pace = v),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(_isThai ? 'ยกเลิก' : 'Cancel')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, pace), child: Text(_isThai ? 'ตกลง' : 'OK')),
          ],
        ),
      ),
    );
    if (result != null && mounted) {
      setState(() {
        _customPaceMinPerKm = result;
        _updateRouteSimulation();
      });
    }
  }

  void _selectRoute(RunningRoute route) {
    setState(() {
      _selectedRoute = route;
      _routeCardExpanded = false;
      _showRouteList = false;
      _fetchedPath = null;
      _routePm25 = null;
    });
    _fetchRouteGeometry(route);
    _fitMapToPath(route.path);
    _fetchRoutePm25(route); // Feature 7
    if (SafetyService.shouldWarn(route.safetyScore)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _showNightWarning(route));
    }
  }

  void _showNightWarning(RunningRoute route) {
    final effective = SafetyService.getTimedSafetyScore(route.safetyScore);
    final isNight = SafetyScoreEngine.isNight();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Row(
          children: [
            Text(isNight ? '🌙' : '⚠️', style: const TextStyle(fontSize: 28)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                isNight ? _s.nightRiskTitle : _s.lowSafetyTitle,
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
        content: Text(
          isNight
            ? _s.nightRiskBody(effective)
            : _s.lowSafetyBody(effective),
          style: TextStyle(height: 1.6, fontSize: 14, color: pal.textSub),
        ),
        actions: [
          // UC-13 A1: เลือกดูเส้นทางอื่น
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'other'),
            child: Text(tr('ดูเส้นทางอื่น', 'View other routes')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'ack'),
            child: Text(_s.acknowledge, style: const TextStyle(fontWeight: FontWeight.w700, color: Color(0xFFE53935))),
          ),
        ],
      ),
    ).then((choice) {
      // UC-13 E1: บันทึกการแจ้งเตือนไว้เป็นหลักฐาน (รวมกรณีผู้ใช้ไม่ตอบสนอง/ปิดหน้าต่าง)
      _logRiskWarning(effective, const [], 'popular_route',
          choice is String ? choice : 'dismissed', routeName: route.nameEn);
      if (choice == 'other' && mounted) {
        _clearRoute();
        setState(() => _showRouteList = true);
      }
    });
  }

  /// UC-13: แสดงคำเตือนความเสี่ยงแบบป๊อปอัปพร้อมเหตุผล เมื่อคะแนนความปลอดภัยต่ำกว่าเกณฑ์ (0–39)
  /// ใช้กับเส้นทางที่ผู้ใช้วางเอง และเส้นทางวงรอบในโซน
  void _showRouteRiskWarning(Map<String, dynamic>? safety, {required String source}) {
    final s = safety?['safety'];
    if (s is! Map) return;
    final score = (s['score'] as num?)?.toInt();
    if (score == null || !SafetyScoreEngine.shouldWarn(score)) return;
    final reasons = ((s['alerts'] as List?) ?? const [])
        .map((e) => e.toString())
        .where((a) => !a.startsWith('⛔'))
        .take(4)
        .toList();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final choice = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          title: Row(
            children: [
              const Text('⛔', style: TextStyle(fontSize: 26)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  tr('เส้นทางนี้มีความเสี่ยงสูง ($score/100)', 'High-risk route ($score/100)'),
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr('คะแนนความปลอดภัยต่ำกว่า ${SafetyScoreEngine.cautionThreshold} ควรพิจารณาก่อนออกกำลังกาย เนื่องจาก:',
                      'The safety score is below ${SafetyScoreEngine.cautionThreshold}. Please consider these factors:'),
                  style: TextStyle(height: 1.5, fontSize: 14, color: pal.textSub),
                ),
                const SizedBox(height: 8),
                if (reasons.isEmpty)
                  Text(tr('• หลายปัจจัยรวมกันทำให้คะแนนต่ำ', '• Several factors combined lower the score'),
                      style: TextStyle(fontSize: 13, color: pal.text))
                else
                  ...reasons.map((r) => Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(r, style: TextStyle(fontSize: 13, height: 1.4, color: pal.text)),
                      )),
              ],
            ),
          ),
          actions: [
            // UC-13 A1: ดูเส้นทางอื่น → กลับไปเลือกจุดค้นหาเส้นทางใหม่
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'other'),
              child: Text(tr('ดูเส้นทางอื่น', 'View other routes')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'ack'),
              child: Text(_s.acknowledge,
                  style: const TextStyle(fontWeight: FontWeight.w700, color: Color(0xFFE53935))),
            ),
          ],
        ),
      );
      // UC-13 E1: ไม่ว่าผู้ใช้จะตอบสนองหรือไม่ ยังใช้เส้นทางต่อได้ แต่บันทึกการแจ้งเตือนไว้เป็นหลักฐาน
      _logRiskWarning(score, reasons, source, choice ?? 'dismissed');
      if (choice == 'other' && mounted) {
        if (source == 'zone_loop') {
          _clearRoutePlan();
          setState(() => _isRoutePlanMode = false);
        } else {
          _clearRoutePlan();
        }
      }
    });
  }

  void _logRiskWarning(int score, List<String> reasons, String source, String response,
      {String? routeName}) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    _firestoreService.logRiskWarning(
      userId: uid,
      score: score,
      reasons: reasons,
      source: source,
      response: response,
      routeName: routeName,
    );
  }

  Future<void> _fetchRouteGeometry(RunningRoute route) async {
    if (!mounted) return;
    // เส้นทางในแอปถูกสร้างจาก Routing API ไว้แล้ว (อยู่บนถนน/ทางเดินจริง) → แสดงได้เลย
    if (ChiangMaiRoutes.hasRoadPath(route)) {
      setState(() {
        _fetchedPath = route.path;
        _isFetchingRoute = false;
      });
      return;
    }
    setState(() => _isFetchingRoute = true);
    try {
      final path = (await RoutingService.fetchRoute(route.path))
          .where((p) => p.latitude.isFinite && p.longitude.isFinite)
          .toList();
      if (mounted && path.length >= 2) {
        setState(() {
          _fetchedPath = path;
          _isFetchingRoute = false;
        });
        _fitMapToPath(path);
      } else {
        if (mounted) setState(() => _isFetchingRoute = false);
      }
    } catch (_) {
      if (mounted) setState(() => _isFetchingRoute = false);
    }
  }

  // แผนที่พร้อมใช้งานหรือยัง — ถ้ายังไม่ layout (ขนาด 0) แล้วเรียก fitCamera
  // จะคำนวณได้ LatLng(NaN, NaN) → "Exception: LatLng is not finite"
  bool _mapReady = false;
  List<LatLng>? _pendingFitPath;

  void _onMapReady() {
    _mapReady = true;
    final pending = _pendingFitPath;
    _pendingFitPath = null;
    if (pending != null) _fitMapToPath(pending);
  }

  void _fitMapToPath(List<LatLng> path) {
    final validPoints = path.where((p) => p.latitude.isFinite && p.longitude.isFinite).toList();
    if (validPoints.isEmpty) return;
    if (!_mapReady) {
      _pendingFitPath = validPoints; // รอจน onMapReady
      return;
    }

    double minLat = validPoints.first.latitude;
    double maxLat = validPoints.first.latitude;
    double minLng = validPoints.first.longitude;
    double maxLng = validPoints.first.longitude;
    for (final p in validPoints) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    if (minLat.isFinite && maxLat.isFinite && minLng.isFinite && maxLng.isFinite) {
      final center = LatLng((minLat + maxLat) / 2, (minLng + maxLng) / 2);
      try {
        final size = _mapController.camera.nonRotatedSize;
        // padding ต้องเล็กกว่าครึ่งของขนาดแผนที่ ไม่งั้นพื้นที่เหลือติดลบ → zoom/center เป็น NaN
        if (!size.width.isFinite || !size.height.isFinite || size.width < 40 || size.height < 40) {
          _mapController.move(center, 14.0);
          return;
        }
        final pad = math.min(40.0, math.min(size.width, size.height) / 6);
        // เว้นที่ด้านบนให้ AppBar และด้านล่างให้การ์ดเส้นทาง เพื่อให้เส้นทางอยู่ในส่วนที่มองเห็น
        final hasBottomCard = _selectedRoute != null || _isRoutePlanMode;
        final topPad = math.min(pad + 90, size.height * 0.25);
        final bottomPad = hasBottomCard ? math.min(size.height * 0.42, 330.0) : pad;
        final safeBottom = (topPad + bottomPad < size.height - 80) ? bottomPad : pad;
        _mapController.fitCamera(
          CameraFit.bounds(
            bounds: LatLngBounds(
              LatLng(minLat - 0.001, minLng - 0.001),
              LatLng(maxLat + 0.001, maxLng + 0.001),
            ),
            padding: EdgeInsets.fromLTRB(pad, topPad, pad, safeBottom),
          ),
        );
        final c = _mapController.camera.center;
        if (!c.latitude.isFinite || !c.longitude.isFinite || !_mapController.camera.zoom.isFinite) {
          _mapController.move(center, 14.0);
        }
      } catch (e) {
        debugPrint('[Map] fitMapToPath error: $e');
        try {
          _mapController.move(center, 14.0);
        } catch (_) {}
      }
    }
  }

  void _clearRoute() {
    setState(() {
      _selectedRoute = null;
      _selectedPoint = null;
      _simulationData = null;
      _fetchedPath = null;
      _isFetchingRoute = false;
      _routePm25 = null;
      _isLoadingPm25 = false;
    });
  }

  // ─── Zone Management Methods ────────────────────────────────
  Future<void> _loadZones() async {
    try {
      // 1) แสดงทุกโซนทันที (รูปทรงสำรอง/แคช) ไม่ต้องรอ Overpass
      final zones = await ZoneService.loadPresetZonesFast();
      if (!mounted) return;
      setState(() => _zones = List<RunningZone>.from(zones));
      _trySelectPendingZone();

      // 2) ดึงขอบเขตจริง + คะแนนความปลอดภัยทีละโซนใน background (พร้อมกันครั้งละ 3)
      final queue = List<RunningZone>.from(zones);
      Future<void> worker() async {
        while (queue.isNotEmpty && mounted) {
          final z = queue.removeAt(0);
          await _resolveAndScoreZone(z);
        }
      }

      await Future.wait([worker(), worker(), worker()]);

      // 3) ค้นหาโซนวิ่งรอบตัวผู้ใช้เพิ่มเติมอัตโนมัติ (Phase 2 Discovery)
      _discoverNearbyZones();
    } catch (e) {
      debugPrint('[MapScreen._loadZones] error: $e');
    }
  }

  /// แทนที่โซนใน [_zones] ตาม id (ลำดับรายการอาจเปลี่ยนจากการจัดเรียง)
  void _replaceZone(RunningZone z) {
    if (!mounted) return;
    setState(() {
      final idx = _zones.indexWhere((e) => e.id == z.id);
      if (idx >= 0) {
        _zones[idx] = z;
      } else {
        _zones.add(z);
      }
      if (_selectedZone?.id == z.id) _selectedZone = z;
    });
  }

  Future<void> _resolveAndScoreZone(RunningZone zone) async {
    var z = zone;
    try {
      if (ZoneService.needsGeometry(z)) {
        z = await ZoneService.resolvePresetGeometry(z);
        if (!identical(z, zone)) _replaceZone(z);
      }
    } catch (e) {
      debugPrint('[MapScreen] geometry ${zone.id}: $e');
    }
    try {
      final userCenter = _isCurrentPosValid ? _currentPosition! : _chiangMaiCenter;
      const distCalc = Distance();
      final scored = await ZoneService.scoreZone(z, incidents: _activeIncidents);
      final distKm = distCalc.as(LengthUnit.Meter, userCenter, scored.center) / 1000.0;
      final aqiData = scored.scoreComponents?['airQuality'] as Map<String, dynamic>?;
      final pm25 = (aqiData?['pm2_5'] as num?)?.toDouble();

      final rScore = ZoneRecommender.calculateRecommendationScore(
        safetyScore: (scored.safetyScore ?? 70).toDouble(),
        distanceKm: distKm,
        radiusKm: 5.0,
        walkableLengthKm: scored.walkableLengthKm,
      );
      final reasons = ZoneRecommender.generateReasons(scored, userDistKm: distKm, pm25: pm25);
      _replaceZone(scored.copyWith(
        recommendationScore: rScore,
        recommendationReasons: reasons,
      ));
    } catch (e) {
      debugPrint('[MapScreen] score ${zone.id}: $e');
    }
  }

  Future<void> _discoverNearbyZones() async {
    if (!mounted) return;
    setState(() => _isDiscoveringZones = true);
    try {
      final center = _isCurrentPosValid ? _currentPosition! : _chiangMaiCenter;
      final discovered = await ZoneDiscoveryService.discover(
        center,
        radiusKm: 5.0,
        presetZones: _zones,
        incidents: _activeIncidents,
      );
      if (!mounted) return;
      if (discovered.isNotEmpty) {
        setState(() {
          final existingIds = _zones.map((z) => z.id).toSet();
          for (final d in discovered) {
            if (!existingIds.contains(d.id)) {
              _zones.add(d);
              existingIds.add(d.id);
            }
          }
          // จัดเรียงตามคะแนนแนะนำ R มากไปน้อย
          _zones.sort((a, b) {
            final rA = a.recommendationScore ?? (a.safetyScore?.toDouble() ?? 0.0);
            final rB = b.recommendationScore ?? (b.safetyScore?.toDouble() ?? 0.0);
            return rB.compareTo(rA);
          });
        });
      }
    } catch (e) {
      debugPrint('[MapScreen._discoverNearbyZones] error: $e');
    } finally {
      if (mounted) setState(() => _isDiscoveringZones = false);
    }
  }

  void _selectZone(RunningZone zone) {
    final lapOpts = RoutingService.lapOptions(zone);
    setState(() {
      _selectedZone = zone;
      _selectedLaps = lapOpts.first;
      _selectedRoute = null;
      _isRoutePlanMode = false;
      _showRouteList = false;
      _isZoneCardExpanded = false;
    });
    // ซูมให้เห็นทั้งรูปทรงของโซน
    final pts = [for (final ring in zone.polygons) ...ring];
    _fitMapToPath(pts.isNotEmpty ? pts : [zone.center]);
    // คำนวณเส้นทางมาตรฐานบนถนน/ทางเดินจริงไว้ล่วงหน้า → การ์ดแสดงระยะต่อรอบที่ถูกต้อง
    if (!ZoneService.needsGeometry(zone) && RoutingService.cachedCourse(zone) == null) { // โซนที่ไม่มีเส้นทางในแอป
      RoutingService.zoneCourse(zone).then((_) {
        if (mounted && _selectedZone?.id == zone.id) setState(() {});
      });
    }
  }

  void _clearZone() {
    setState(() {
      _selectedZone = null;
      _isZoneCardExpanded = false;
      _isGeneratingLoop = false;
    });
  }

  Future<void> _generateLoopInZone(RunningZone zone, int laps) async {
    setState(() => _isGeneratingLoop = true);
    try {
      // ต้องมีขอบเขตจริงของสถานที่ก่อน — รูปทรงสำรองเป็นค่าประมาณ ใช้เป็นเส้นทางวิ่งไม่ได้
      if (ZoneService.needsGeometry(zone) && !RoutingService.hasBuiltInCourse(zone)) {
        final resolved = await ZoneService.resolvePresetGeometry(zone);
        if (!mounted) return;
        if (ZoneService.needsGeometry(resolved)) {
          setState(() => _isGeneratingLoop = false);
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(tr(
              'โหลดขอบเขตจริงของสถานที่ไม่สำเร็จ (ตรวจสอบอินเทอร์เน็ต) แล้วลองอีกครั้ง',
              'Could not load the real boundary of this place (check internet). Please try again.',
            )),
          ));
          return;
        }
        zone = resolved;
        _replaceZone(resolved);
      }
      final userPos = _isCurrentPosValid ? _currentPosition! : zone.center;
      // เส้นทางมาตรฐานของโซน (ขอบจริงของสถานที่ แนบกับถนน/ทางเดินจริงด้วย Routing API) × จำนวนรอบ
      final loopPath = await RoutingService.fixedCourse(zone, userPos, laps);
      if (!mounted) return;
      if (loopPath == null || loopPath.length < 2) {
        setState(() => _isGeneratingLoop = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr(
            'สร้างเส้นทางตามถนน/ทางเดินจริงไม่สำเร็จ (ตรวจสอบอินเทอร์เน็ต หรือบริเวณนี้ไม่มีข้อมูลทางเดินในแผนที่)',
            'Could not build a route along real roads/paths (check internet, or this area has no path data on the map).',
          )),
        ));
        return;
      }
      if (RoutingService.cachedCourse(zone)?.onRoads == false) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr(
            'รอบสนามนี้ไม่มีข้อมูลทางเดินในแผนที่ — แสดงเส้นตามขอบสนามจริงแทน',
            'No path data around this field on the map — showing the real field outline instead.',
          )),
        ));
      }
      final targetKm = RoutingService.fixedCourseLapKm(zone) * laps;

      final isNight = SafetyScoreEngine.isNight();
      final dijkstraResult = SafetyDijkstraService.run(
        osrmPath: loopPath,
        incidents: _activeIncidents,
        isNight: isNight,
        trafficSegments: _trafficSegments,
        trafficLightNodes: _trafficLightNodes,
      );
      final activePath = dijkstraResult.path.isNotEmpty ? dijkstraResult.path : loopPath;

      double safeTotalKm = 0;
      if (activePath.length >= 2) {
        for (int i = 0; i < activePath.length - 1; i++) {
          safeTotalKm += Geolocator.distanceBetween(
            activePath[i].latitude, activePath[i].longitude,
            activePath[i + 1].latitude, activePath[i + 1].longitude,
          ) / 1000.0;
        }
      }

      final road = await RoadContextService.fetch(activePath);
      final mid = activePath.isNotEmpty ? activePath[activePath.length ~/ 2] : zone.center;
      final safety = await ApiService.getPreRunSimulation(
        mid.latitude,
        mid.longitude,
        road: road,
        trafficCongestionPct: _trafficCongestionPct,
        trafficLightCount: _trafficLightCount,
        activeIncidentCount: _countActiveIncidentsNear(activePath),
      );

      if (mounted) {
        setState(() {
          _isGeneratingLoop = false;
          _routePlanPath = activePath;
          _dijkstraResult = dijkstraResult;
          _useSafetyDijkstra = true;
          _routeDistanceKm = safeTotalKm > 0 ? safeTotalKm : targetKm;
          _updateRouteSimulation();
          _routeMidPoint = mid;
          _routeSafetyData = safety;
          _routeCardCollapsed = false;
          _selectedZone = null;
          _isRoutePlanMode = true;
        });
        _fitMapToPath(activePath);
        _showRouteRiskWarning(safety, source: 'zone_loop'); // UC-13
      }
    } catch (e) {
      if (mounted) setState(() => _isGeneratingLoop = false);
      debugPrint('[MapScreen._generateLoopInZone] Error: $e');
    }
  }

  // ─── Route Planning Mode ────────────────────────────────────
  void _handleRoutePlanTap(LatLng point) {
    if (_routeStartPoint == null) {
      setState(() => _routeStartPoint = point);
    } else if (_routeEndPoint == null) {
      setState(() => _routeEndPoint = point);
      _fetchRoutePlan();
    }
  }

  Future<void> _fetchRoutePlan() async {
    if (_routeStartPoint == null || _routeEndPoint == null) return;
    setState(() {
      _isFetchingRoutePlan = true;
      _routePlanPath = null;
      _routeSafetyData = null;
      _dijkstraResult = null;
      _elevationPoints = [];
      _elevationGainM = null;
      _elevationLossM = null;
      // รีเซ็ต traffic state
      _trafficCongestionPct  = 0.0;
      _trafficLightCount     = 0;
      _trafficSegments       = [];
      _trafficLightNodes     = [];
    });

    try {
      // ดึงเส้นทางจริงตามถนน — ขอเส้นทางทางเลือกหลายเส้นเพื่อให้ Dijkstra เปรียบเทียบความปลอดภัย
      final candidates = await RoutingService.fetchRouteAlternatives(_routeStartPoint!, _routeEndPoint!);
      final isNightNow = SafetyScoreEngine.isNight();
      // เลือกเส้นทางที่มีค่าน้ำหนักความปลอดภัยสะสมต่ำที่สุด (ปลอดภัยที่สุด ไม่ใช่สั้นที่สุด)
      List<LatLng> path = candidates.first;
      if (path.length < 2) {
        throw tr('บริการคำนวณเส้นทางไม่ตอบกลับ ลองใหม่อีกครั้ง', 'the routing service did not respond, please try again');
      }
      if (candidates.length > 1) {
        double best = double.infinity;
        for (final c in candidates) {
          final r = SafetyDijkstraService.run(
            osrmPath: c,
            incidents: _activeIncidents,
            isNight: isNightNow,
          );
          if (r.totalSafetyWeight < best) {
            best = r.totalSafetyWeight;
            path = c;
          }
        }
      }

      // คำนวณระยะทาง
      double totalKm = 0;
      if (path.length >= 2) {
        for (int i = 0; i < path.length - 1; i++) {
          final meters = Geolocator.distanceBetween(
            path[i].latitude, path[i].longitude,
            path[i + 1].latitude, path[i + 1].longitude,
          );
          totalKm += meters / 1000.0;
        }
      }

      // ── ประเมินสภาพรถติดและแยกไฟแดงจากเส้นทาง OSRM ──
      // (ใช้ active incidents ประเภท 'accident' และ angle เป็น proxy ของแยก)
      _estimateTrafficData(path);

      // ── Safety-Aware Dijkstra ──────────────────────────────────────────
      final isNight = SafetyScoreEngine.isNight();
      final dijkstraResult = SafetyDijkstraService.run(
        osrmPath: path,
        incidents: _activeIncidents,
        isNight: isNight,
        trafficSegments:   _trafficSegments,
        trafficLightNodes: _trafficLightNodes,
      );

      // ลักษณะถนนจริงจาก OSM (ถนนสายหลัก / ทางเท้า / ไฟส่องสว่าง / แยกไฟ) — ทำให้คะแนนต่างกันตามเส้นทาง
      final road = await RoadContextService.fetch(
          dijkstraResult.path.isNotEmpty ? dijkstraResult.path : path);

      // ดึง Safety Score: สภาพอากาศจากจุดกลาง, ฝุ่นจากจุดต้น/กลาง/ปลาย (ใช้ค่าแย่สุด)
      final mid = path.isNotEmpty ? path[path.length ~/ 2] : _routeEndPoint!;
      final safety = await ApiService.getPreRunSimulation(
        mid.latitude,
        mid.longitude,
        road: road,
        airSamplePoints: path.isEmpty
            ? const []
            : [
                (lat: path.first.latitude, lng: path.first.longitude),
                (lat: mid.latitude, lng: mid.longitude),
                (lat: path.last.latitude, lng: path.last.longitude),
              ],
        trafficCongestionPct: _trafficCongestionPct,
        trafficLightCount: _trafficLightCount,
        activeIncidentCount: _countActiveIncidentsNear(
            dijkstraResult.path.isNotEmpty ? dijkstraResult.path : path),
      );

      // ใช้เส้นทาง Safety Dijkstra โดยตรงเสมอ
      final activePath = dijkstraResult.path.isNotEmpty ? dijkstraResult.path : path;

      // คำนวณระยะทางจากเส้นทางปลอดภัย
      double safeTotalKm = 0;
      if (activePath.length >= 2) {
        for (int i = 0; i < activePath.length - 1; i++) {
          final meters = Geolocator.distanceBetween(
            activePath[i].latitude, activePath[i].longitude,
            activePath[i + 1].latitude, activePath[i + 1].longitude,
          );
          safeTotalKm += meters / 1000.0;
        }
      }

      if (mounted) {
        setState(() {
          _routePlanPath = activePath;
          _dijkstraResult = dijkstraResult;
          _useSafetyDijkstra = true;
          _routeDistanceKm = safeTotalKm > 0 ? safeTotalKm : totalKm;
          _updateRouteSimulation(); // UC-04: เวลา + แคลอรี (ปรับอีกครั้งเมื่อได้ความสูง)
          _routeMidPoint = activePath.isNotEmpty ? activePath[activePath.length ~/ 2] : null;
          _routeSafetyData = safety;
          _routeCardCollapsed = false;
          _isFetchingRoutePlan = false;
        });
        if (activePath.isNotEmpty) _fitMapToPath(activePath);
        _showRouteRiskWarning(safety, source: 'plan'); // UC-13
        // บันทึกข้อมูลคุณภาพอากาศ/สภาพอากาศ ณ เวลานั้น (ตาราง AirQuality, Weather ใน ERD)
        // บันทึกเฉพาะค่าที่ดึงสดจริง (ไม่บันทึกค่าประมาณ/ค่าจากแคช)
        final safetyMeta = safety['safety'] as Map;
        if (safetyMeta['isEstimate'] != true &&
            ((safetyMeta['usedCache'] as List?)?.isEmpty ?? true)) {
          _firestoreService.saveEnvironmentSnapshot(
            latitude: mid.latitude,
            longitude: mid.longitude,
            airQuality: safety['airQuality'] as Map,
            weather: safety['weather'] as Map,
          );
        }
        await _fetchElevation(activePath);
        // บันทึกผลการจำลอง (ตาราง Simulation ใน ERD)
        final uid = FirebaseAuth.instance.currentUser?.uid;
        if (uid != null && _routeDistanceKm != null && mounted) {
          _firestoreService.saveSimulation(
            userId: uid,
            simulation: SimulationEngine.runSimulation(
              distanceKm: _routeDistanceKm!,
              elevationGainM: _elevationGainM ?? 0,
              paceMinPerKm: _customPaceMinPerKm,
              activityType: _planActivityType,
            ).toMap()
              ..['activityType'] = _planActivityType,
            safetyScore: (safety['safety'] as Map)['score'] as int?,
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isFetchingRoutePlan = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${_s.unableCalculateRoute}: $e'),
            backgroundColor: const Color(0xFFE74C3C),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
    }
  }

  /// ประเมินสภาพรถติดและจำนวนแยกสัญญาณไฟจากเส้นทาง OSRM
  ///
  /// - **Traffic congestion**: นับ segment ที่มี incident ประเภท accident/flooding/construction
  ///   อยู่ใกล้ (<80m) เป็น "congested segment" — ใช้แทน TomTom tile data ที่ parse ไม่ได้ฝั่ง client
  /// - **Traffic lights**: ตรวจจุดเปลี่ยนทิศทาง (turn angle > 60°) บนเส้นทาง
  ///   ซึ่งมักตรงกับสี่แยกสัญญาณไฟในถนนเมือง
  void _estimateTrafficData(List<LatLng> path) {
    if (path.length < 2) return;

    const double incidentCongestionRadiusM = 80.0;
    const double lightAngleDeg = 60.0;
    const double lightMinDistM = 50.0; // ระยะขั้นต่ำระหว่างแยก (กันนับซ้ำ)

    int congestedSegments = 0;
    final List<List<LatLng>> segments = [];
    final List<LatLng> lightNodes = [];
    LatLng? lastLightNode;

    for (int i = 0; i < path.length - 1; i++) {
      final u = path[i];
      final v = path[i + 1];
      final mid = LatLng((u.latitude + v.latitude) / 2, (u.longitude + v.longitude) / 2);

      // ตรวจ incident ใกล้ segment (proxy สำหรับรถติด)
      final hasCongestion = _activeIncidents.any((inc) {
        if (!['accident', 'flooding', 'construction'].contains(inc.type)) return false;
        return Geolocator.distanceBetween(
              mid.latitude, mid.longitude, inc.latitude, inc.longitude)
            <= incidentCongestionRadiusM;
      });
      if (hasCongestion) {
        congestedSegments++;
        segments.add([u, v]);
      }

      // ตรวจมุมเลี้ยว (proxy สำหรับแยกสัญญาณไฟ)
      if (i > 0 && i < path.length - 1) {
        final prev = path[i - 1];
        double bear1 = _bearing(prev, u);
        double bear2 = _bearing(u, v);
        double diff = (bear2 - bear1).abs() % 360;
        double turn = diff > 180 ? 360 - diff : diff;
        if (turn > lightAngleDeg) {
          // กันนับแยกเดิมซ้ำ
          bool tooClose = lastLightNode != null &&
              Geolocator.distanceBetween(
                    u.latitude, u.longitude,
                    lastLightNode.latitude, lastLightNode.longitude) <
                  lightMinDistM;
          if (!tooClose) {
            lightNodes.add(u);
            lastLightNode = u;
          }
        }
      }
    }

    final totalSegments = path.length - 1;
    setState(() {
      _trafficCongestionPct = totalSegments > 0
          ? (congestedSegments / totalSegments * 100).clamp(0, 100)
          : 0.0;
      _trafficLightCount    = lightNodes.length;
      _trafficSegments      = segments;
      _trafficLightNodes    = lightNodes;
    });
  }

  /// คำนวณมุมทิศทาง (bearing) ระหว่างสองจุด
  static double _bearing(LatLng a, LatLng b) {
    final deg2rad = math.pi / 180;
    final lat1 = a.latitude  * deg2rad;
    final lat2 = b.latitude  * deg2rad;
    final dLng = (b.longitude - a.longitude) * deg2rad;
    return math.atan2(
          math.sin(dLng) * math.cos(lat2),
          math.cos(lat1) * math.sin(lat2) -
              math.sin(lat1) * math.cos(lat2) * math.cos(dLng)) *
        180 / math.pi;
  }



  /// Feature 3: ดึงข้อมูล Elevation จาก Open-Meteo Elevation API
  Future<void> _fetchElevation(List<LatLng> path) async {
    if (path.isEmpty || !mounted) return;
    setState(() => _isFetchingElevation = true);
    try {
      // สุ่มเลือกสูงสุด 20 จุดกระจายตลอดเส้นทางเพื่อไม่เกิน API limit
      final step = (path.length / 20).ceil().clamp(1, path.length);
      final sampled = <LatLng>[];
      for (int i = 0; i < path.length; i += step) {
        sampled.add(path[i]);
      }
      if (sampled.last != path.last) sampled.add(path.last);

      final lats = sampled.map((p) => p.latitude.toStringAsFixed(5)).join(',');
      final lngs = sampled.map((p) => p.longitude.toStringAsFixed(5)).join(',');
      final url = 'https://api.open-meteo.com/v1/elevation?latitude=$lats&longitude=$lngs';

      final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final data = json.decode(res.body) as Map<String, dynamic>;
        final raw = data['elevation'] as List?;
        if (raw != null && raw.isNotEmpty) {
          final elevations = raw.map((e) => (e as num).toDouble()).toList();

          // คำนวณ Gain / Loss (SimulationEngine.calculateElevationProfile)
          final prof = SimulationEngine.calculateElevationProfile(elevations);

          if (mounted) {
            setState(() {
              _elevationPoints = elevations;
              _elevationGainM = prof.gain;
              _elevationLossM = prof.loss;
              _updateRouteSimulation(); // ปรับเวลา/แคลอรี/ระดับความยากตามความชัน
            });
          }
        }
      }
    } catch (_) {
      // Elevation fetch failed silently — ไม่กระทบการใช้งานหลัก
    } finally {
      if (mounted) setState(() => _isFetchingElevation = false);
    }
  }

  void _clearRoutePlan() {
    setState(() {
      _routeCardCollapsed = false;
      _routeStartPoint = null;
      _routeEndPoint = null;
      _routePlanPath = null;
      _routeSafetyData = null;
      _dijkstraResult = null;
      _routeDistanceKm = null;
      _routeEstimatedTime = null;
      _routeCalories = null;
      _routeDifficulty = null;
      _routeMidPoint = null;
      _isFetchingRoutePlan = false;
      _useSafetyDijkstra = true;
      _elevationPoints = [];
      _elevationGainM = null;
      _elevationLossM = null;
      // รีเซ็ต traffic state
      _trafficCongestionPct  = 0.0;
      _trafficLightCount     = 0;
      _trafficSegments       = [];
      _trafficLightNodes     = [];
    });
  }

  // ─── Feature 12: AQI Circle Overlay ─────────────────────────────────────
  // ignore: unused_element
  Future<void> _toggleAqiOverlay() async {
    if (_showAqiOverlay) {
      setState(() => _showAqiOverlay = false);
      return;
    }
    // ต้องมี GPS ก่อน
    if (!_isCurrentPosValid) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_s.waitingGpsSignal),
          backgroundColor: Colors.orange.shade700,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
      return;
    }
    setState(() => _isFetchingAqi = true);
    try {
      final lat = _currentPosition!.latitude;
      final lng = _currentPosition!.longitude;
      final res = await http.get(Uri.parse(
        'https://air-quality-api.open-meteo.com/v1/air-quality'
        '?latitude=$lat&longitude=$lng&current=pm2_5&timezone=Asia/Bangkok',
      )).timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final pm25 = (data['current']['pm2_5'] as num?)?.toDouble() ?? 0;
        if (mounted) {
          setState(() {
            _currentAqiPm25 = pm25;
            _showAqiOverlay = true;
          });
        }
      }
    } catch (_) {
      // silently fail
    } finally {
      if (mounted) setState(() => _isFetchingAqi = false);
    }
  }

  // ignore: unused_element
  Color _aqiColor(double pm25) {
    if (pm25 > 75) return const Color(0xFFE74C3C);
    if (pm25 > 35) return const Color(0xFFF39C12);
    return const Color(0xFF2ECC71);
  }

  // ignore: unused_element
  String _aqiLabel(double pm25) {
    if (pm25 > 75) return _s.dangerous;
    if (pm25 > 35) return _s.moderateAir;
    return _s.goodAir;
  }

  void _showScoreBreakdown(int score, List alerts, Map weather, Map airQuality) {
    final isNight = SafetyScoreEngine.isNight();
    final pm25 = double.tryParse(airQuality['pm2_5']?.toString() ?? '0') ?? 0;
    final aqi = (airQuality['us_aqi'] as num?)?.toInt() ?? AirQualityService.calculateAQI(pm25);
    final temp = double.tryParse(weather['temperature']?.toString() ?? '0') ?? 0;
    final wind = double.tryParse(weather['windspeed']?.toString() ?? '0') ?? 0;
    final humidity = double.tryParse(weather['humidity']?.toString() ?? '0') ?? 0;
    final rain = double.tryParse(weather['precipitation']?.toString() ?? '0') ?? 0;

    // ข้อมูลการจราจร / เหตุการณ์ที่ใช้คำนวณ
    final trafficMap = (_routeSafetyData != null && _routeSafetyData!['traffic'] is Map)
        ? (_routeSafetyData!['traffic'] as Map<String, dynamic>)
        : null;
    final congestionPct = (trafficMap?['congestionPct'] as num?)?.toDouble() ?? _trafficCongestionPct;
    final lightCount = (trafficMap?['lightCount'] as num?)?.toInt() ?? _trafficLightCount;
    final incidentMap = (_routeSafetyData != null && _routeSafetyData!['incidents'] is Map)
        ? (_routeSafetyData!['incidents'] as Map<String, dynamic>)
        : null;
    final incidentCount = (incidentMap?['activeCount'] as num?)?.toInt() ?? 0;
    final roadMap = (_routeSafetyData != null && _routeSafetyData!['road'] is Map)
        ? (_routeSafetyData!['road'] as Map)
        : null;
    final majorShare = (roadMap?['majorRoadShare'] as num?)?.toDouble() ?? 0;
    final protShare = (roadMap?['protectedShare'] as num?)?.toDouble() ?? 0;
    final litShare = (roadMap?['litShare'] as num?)?.toDouble();

    // คะแนนย่อยตามสมการที่ (3.1)
    final r = SafetyScoreEngine.calculateSafetyScore(
      majorRoadShare: majorShare,
      protectedShare: protShare,
      litShare: litShare,
      aqi: aqi,
      temperatureC: temp,
      precipitationMm: rain,
      humidityPct: humidity,
      windKmh: wind,
      congestionPct: congestionPct,
      trafficLightCount: lightCount,
      activeIncidentCount: incidentCount,
    );

    Color subColor(double v) => SafetyScoreEngine.scoreColor(v.round());

    final factors = <Map<String, dynamic>>[
      {
        'icon': '🌫️',
        'label': _isThai ? 'คุณภาพอากาศ' : 'Air quality',
        'value': 'AQI $aqi · PM2.5 ${pm25.toStringAsFixed(1)} μg/m³',
        'sub': r.sAir,
        'weight': SafetyScoreEngine.wAir,
      },
      {
        'icon': '🌡️',
        'label': _isThai ? 'สภาพอากาศ' : 'Weather',
        'value': '${temp.toStringAsFixed(1)}°C · ${_isThai ? "ฝน" : "rain"} ${rain.toStringAsFixed(1)} mm · ${_isThai ? "ความชื้น" : "humidity"} ${humidity.toStringAsFixed(0)}%',
        'sub': r.sWx,
        'weight': SafetyScoreEngine.wWeather,
      },
      {
        'icon': '🚗',
        'label': _isThai ? 'การจราจร' : 'Traffic',
        'value': roadMap != null
            ? tr('ถนนสายหลัก ${(majorShare * 100).round()}% · ทางเท้า/ทางจักรยาน ${(protShare * 100).round()}% · ไฟแดง $lightCount แยก',
                'Main roads ${(majorShare * 100).round()}% · sidewalk/bike lane ${(protShare * 100).round()}% · $lightCount signals')
            : '${_s.trafficCongestionValue(congestionPct)} · ${_s.trafficLightValue(lightCount)}',
        'sub': r.sTrf,
        'weight': SafetyScoreEngine.wTraffic,
      },
      {
        'icon': '📍',
        'label': _isThai ? 'เหตุการณ์บนเส้นทาง' : 'Incidents',
        'value': _isThai ? '$incidentCount รายการที่ยังไม่หมดอายุ' : '$incidentCount active report(s)',
        'sub': r.sInc,
        'weight': SafetyScoreEngine.wIncident,
      },
    ];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        decoration: BoxDecoration(
          color: pal.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Handle
              Center(
                child: Container(
                  width: 40, height: 4,
                  decoration: BoxDecoration(
                    color: pal.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // Title
              Row(children: [
                const Icon(Icons.shield_outlined, color: Color(0xFF2ECC71), size: 22),
                const SizedBox(width: 8),
                Text(_s.safetyScore,
                    style: TextStyle(color: pal.text, fontSize: 17, fontWeight: FontWeight.w800)),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: SafetyScoreEngine.scoreColor(score).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text('$score / 100',
                      style: TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 16,
                        color: SafetyScoreEngine.scoreColor(score),
                      )),
                ),
              ]),
              const SizedBox(height: 6),
              Text(_s.startScoreDesc,
                  style: TextStyle(fontSize: 12, color: pal.textSub)),
              const SizedBox(height: 16),
              // Factor rows (คะแนนย่อย × ค่าน้ำหนัก)
              ...factors.map((f) {
                final sub = f['sub'] as double;
                final w = f['weight'] as double;
                final c = subColor(sub);
                return Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: pal.surface2,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: c.withValues(alpha: 0.3)),
                  ),
                  child: Row(children: [
                    Text(f['icon'] as String, style: const TextStyle(fontSize: 20)),
                    const SizedBox(width: 12),
                    Expanded(child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(f['label'] as String,
                            style: TextStyle(color: pal.text, fontWeight: FontWeight.w700, fontSize: 13)),
                        Text(f['value'] as String,
                            style: TextStyle(color: pal.textSub, fontSize: 11)),
                      ],
                    )),
                    const SizedBox(width: 8),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text('${sub.round()}',
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: c)),
                        Text(tr('น้ำหนัก ${(w * 100).round()}%', 'weight ${(w * 100).round()}%'),
                            style: TextStyle(fontSize: 10, color: pal.textSub)),
                      ],
                    ),
                  ]),
                );
              }),
              Divider(color: pal.border, height: 20),
              // S_base และ T(t)
              Row(children: [
                Expanded(
                  child: Text(tr('คะแนนก่อนปรับตามเวลา ${r.baseScore.toStringAsFixed(1)}', 'Before time adjustment ${r.baseScore.toStringAsFixed(1)}'),
                      style: TextStyle(color: pal.textSub, fontSize: 13, fontWeight: FontWeight.w600)),
                ),
                Text(
                  isNight
                          ? tr('🌙 กลางคืน ลด ${((1 - r.timeFactor) * 100).round()}%', '🌙 Night −${((1 - r.timeFactor) * 100).round()}%')
                          : tr('☀️ กลางวัน ไม่ปรับลด', '☀️ Daytime, no reduction'),
                  style: TextStyle(
                    color: isNight ? const Color(0xFFF39C12) : const Color(0xFF2ECC71),
                    fontSize: 13, fontWeight: FontWeight.w700),
                ),
              ]),
                  const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRoutePlanCard() {
    final safety = _routeSafetyData!['safety'];
    final weather = _routeSafetyData!['weather'];
    final airQuality = _routeSafetyData!['airQuality'];
    final score = safety['score'] as int;
    final alerts = safety['alerts'] as List;
    final pm25 = double.tryParse(airQuality['pm2_5']?.toString() ?? '0') ?? 0;

    Color scoreColor;
    String scoreLabel;
    // ตารางที่ 3.16: 70–100 ปลอดภัย / 40–69 ควรระวัง / 0–39 เสี่ยงสูง
    final level = SafetyScoreEngine.getSafetyLevel(score);
    scoreColor = SafetyScoreEngine.levelColor(level);
    scoreLabel = level == SafetyLevel.safe
        ? _s.safe
        : level == SafetyLevel.caution
            ? _s.caution
            : _s.notRecommended;

    // การ์ดแบบย่อ: แสดงเฉพาะคะแนน ระยะทาง และเวลา — แตะเพื่อขยาย
    if (_routeCardCollapsed) {
      final distText = _routeDistanceKm != null ? '${_routeDistanceKm!.toStringAsFixed(1)} km' : '-';
      final timeText = _routeEstimatedTime ?? '--';
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _routeCardCollapsed = false),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: pal.surface.withValues(alpha: 0.97),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 20)],
          ),
          child: Row(
            children: [
              Container(
                width: 40, height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: scoreColor, width: 2),
                  color: scoreColor.withValues(alpha: 0.1),
                ),
                child: Text('$score', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: scoreColor)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(scoreLabel, style: TextStyle(color: scoreColor, fontSize: 13, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text('$distText · $timeText',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: pal.textSub, fontSize: 12)),
                  ],
                ),
              ),
              Text(tr('ดูรายละเอียด', 'Details'), style: TextStyle(color: pal.textSub, fontSize: 12)),
              Icon(Icons.keyboard_arrow_up, color: pal.text, size: 24),
              const SizedBox(width: 6),
              GestureDetector(
                onTap: _clearRoutePlan,
                child: Icon(Icons.close, color: pal.textSub, size: 20),
              ),
            ],
          ),
        ),
      );
    }

    Color pm25Color = pm25 > 75
        ? const Color(0xFFE74C3C)
        : pm25 > 35
            ? const Color(0xFFF39C12)
            : const Color(0xFF2ECC71);

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: pal.surface.withValues(alpha: 0.97),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 20)],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header
          Row(
            children: [
              const Icon(Icons.alt_route, color: Color(0xFF2ECC71), size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(_s.routeAnalysisResult,
                    style: TextStyle(color: pal.text, fontSize: 15, fontWeight: FontWeight.w700)),
              ),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _routeCardCollapsed = true),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Tooltip(
                    message: tr('ย่อการ์ดเพื่อดูเส้นทาง', 'Collapse to see the route'),
                    child: Icon(Icons.keyboard_arrow_down, color: pal.text, size: 26),
                  ),
                ),
              ),
              GestureDetector(
                onTap: _clearRoutePlan,
                child: Icon(Icons.close, color: pal.text, size: 20),
              ),
            ],
          ),
          const SizedBox(height: 14),
          // Stats row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              // Safety Score
              GestureDetector(
                onTap: () => _showScoreBreakdown(score, safety['alerts'] as List, weather, airQuality),
                child: Column(children: [
                  Stack(
                    alignment: Alignment.bottomRight,
                    children: [
                      Container(
                        width: 56, height: 56,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: scoreColor, width: 2.5),
                          color: scoreColor.withValues(alpha: 0.1),
                        ),
                        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                          Text('$score', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: scoreColor)),
                        ]),
                      ),
                      Container(
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          color: pal.surface, shape: BoxShape.circle,
                        ),
                        child: Icon(Icons.info_outline, size: 13, color: pal.textSub),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(scoreLabel, style: TextStyle(fontSize: 11, color: scoreColor, fontWeight: FontWeight.w600)),
                  Text(tr('ความปลอดภัย', 'Safety'), style: TextStyle(fontSize: 11, color: pal.text, fontWeight: FontWeight.w500)),
                ]),
              ),
              Container(width: 1, height: 60, color: pal.border),
              // Distance
              Column(children: [
                const Icon(Icons.straighten, color: Color(0xFFFF6B35), size: 26),
                const SizedBox(height: 4),
                Text(
                  _routeDistanceKm != null ? '${_routeDistanceKm!.toStringAsFixed(1)} km' : '-',
                  style: TextStyle(color: pal.text, fontSize: 15, fontWeight: FontWeight.w700),
                ),
                Text(_s.distance, style: TextStyle(fontSize: 11, color: pal.text, fontWeight: FontWeight.w500)),
              ]),
              Container(width: 1, height: 60, color: pal.border),
              // PM2.5
              Column(children: [
                Icon(Icons.blur_on, color: pm25Color, size: 26),
                const SizedBox(height: 4),
                Text('${pm25.toStringAsFixed(0)} μg',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: pm25Color)),
                Text('PM2.5', style: TextStyle(fontSize: 11, color: pal.text, fontWeight: FontWeight.w500)),
              ]),
              Container(width: 1, height: 60, color: pal.border),
              // Estimated Time (FR11)
              Column(children: [
                const Icon(Icons.timer, color: Color(0xFFFF6B35), size: 26),
                const SizedBox(height: 4),
                Text(_routeEstimatedTime ?? '--', style: TextStyle(color: pal.text, fontSize: 15, fontWeight: FontWeight.w700)),
                Text(_s.estimatedTime, style: TextStyle(fontSize: 11, color: pal.text, fontWeight: FontWeight.w500)),
              ]),
            ],
          ),
          // Alerts
          if (alerts.isNotEmpty) ...[
            const SizedBox(height: 12),
            ...alerts.take(2).map((alert) => Container(
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFFF39C12).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFF39C12).withValues(alpha: 0.3)),
              ),
              child: Row(children: [
                const Icon(Icons.warning_amber_rounded, color: Color(0xFFF39C12), size: 16),
                const SizedBox(width: 8),
                Expanded(child: Text(alert.toString(),
                    style: const TextStyle(fontSize: 12, color: Color(0xFFF39C12)))),
              ]),
            )),
          ] else ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF2ECC71).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFF2ECC71).withValues(alpha: 0.3)),
              ),
              child: Row(children: [
                const Icon(Icons.check_circle, color: Color(0xFF2ECC71), size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_s.routeSafePrompt,
                      style: const TextStyle(fontSize: 12, color: Color(0xFF2ECC71))),
                ),
              ]),
            ),
          ],

          // ─── Feature 3: Elevation Profile ───────────────────────
          const SizedBox(height: 14),
          // Distance + Gain / Loss row
          Row(children: [
            _buildElevBadge(
              Icons.straighten,
              _routeDistanceKm != null
                  ? '${_routeDistanceKm!.toStringAsFixed(2)} km'
                  : '--',
              const Color(0xFFFF6B35),
              '',
            ),
            const SizedBox(width: 8),
            _buildElevBadge(Icons.trending_up, '${_elevationGainM?.round() ?? '--'} m', const Color(0xFF2ECC71), '↑'),
            const SizedBox(width: 8),
            _buildElevBadge(Icons.trending_down, '${_elevationLossM?.round() ?? '--'} m', const Color(0xFFE74C3C), '↓'),
            const Spacer(),
            if (_isFetchingElevation)
              SizedBox(
                width: 14, height: 14,
                child: CircularProgressIndicator(strokeWidth: 2, color: pal.textSub),
              ),
          ]),
          // ─── UC-04: ผลการจำลอง (ประเภทกิจกรรม / แคลอรี / จังหวะ / ระดับความยาก) ───
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
            // UC-02: เลือกประเภทกิจกรรม วิ่ง/ปั่นจักรยาน
            GestureDetector(
              onTap: () => setState(() {
                _planActivityType = _planActivityType == 'running' ? 'cycling' : 'running';
                _customPaceMinPerKm = null;
                _updateRouteSimulation();
              }),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: pal.surface2,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(_planActivityType == 'cycling' ? Icons.directions_bike : Icons.directions_run,
                      color: pal.text, size: 16),
                  const SizedBox(width: 4),
                  Text(_planActivityType == 'cycling'
                          ? (_isThai ? 'ปั่นจักรยาน' : 'Cycling')
                          : (_isThai ? 'วิ่ง' : 'Running'),
                      style: TextStyle(color: pal.text, fontSize: 12, fontWeight: FontWeight.w600)),
                ]),
              ),
            ),
            _buildElevBadge(Icons.local_fire_department, '${_routeCalories ?? '--'} kcal', const Color(0xFFFF6B35), ''),
            // UC-04 A1: ปรับความเร็วเฉลี่ยเอง
            GestureDetector(
              onTap: _showPaceDialog,
              child: _buildElevBadge(
                Icons.speed,
                () {
                  final p = _customPaceMinPerKm ?? SimulationEngine.defaultPace(_planActivityType);
                  return "${p.floor()}:${((p - p.floor()) * 60).round().toString().padLeft(2, '0')}/km";
                }(),
                const Color(0xFF3498DB),
                '',
              ),
            ),
            if (_routeDifficulty != null)
              Text(_getDifficultyLabel(_routeDifficulty!),
                  style: TextStyle(color: _getDifficultyColor(_routeDifficulty!), fontSize: 12, fontWeight: FontWeight.w700)),
          ]),
          // UC-04 E1: ไม่มีข้อมูลความชัน → ผลการจำลองอาจไม่สมบูรณ์
          if (!_isFetchingElevation && _elevationGainM == null && _routeDistanceKm != null) ...[
            const SizedBox(height: 6),
            Text(_isThai ? 'ไม่มีข้อมูลความสูง — แคลอรี่และเวลาเป็นค่าประมาณ' : 'No elevation data — calories and time are estimates',
                style: const TextStyle(color: Color(0xFFF39C12), fontSize: 11)),
          ],
          const SizedBox(height: 10),
          // Elevation mini-chart
          _buildElevationChart(),


          // ─── Safety-Aware Dijkstra (คำนวณและเปิดใช้อัตโนมัติ ไม่ต้องกดสลับโหมด) ───
          if (_dijkstraResult != null) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF1A6BA0), Color(0xFF2E86C1)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFF3498DB), width: 1.5),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF1A6BA0).withValues(alpha: 0.35),
                    blurRadius: 8,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withValues(alpha: 0.2),
                    ),
                    child: const Icon(
                      Icons.shield_rounded,
                      size: 20,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            // Flexible กัน RIGHT OVERFLOWED (22–100 px) เมื่อชื่อยาว + ป้าย "ใช้งานอยู่"
                            Flexible(
                              child: Text(
                                _isThai ? 'เส้นทางปลอดภัยที่สุด' : 'Safest route',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: const Color(0xFF2ECC71),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                tr('ใช้งานอยู่', 'ACTIVE'),
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 9,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _isThai
                              ? 'เลี่ยงจุดเสี่ยงและเลือกถนนที่มีแสงสว่างให้อัตโนมัติ'
                              : 'Automatically avoids risk spots and prefers well-lit roads',
                          style: const TextStyle(color: Colors.white70, fontSize: 10.5),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // สรุปจุดอันตรายที่ตรวจพบ
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: _dijkstraResult!.highRiskSegments.isEmpty
                    ? const Color(0xFF2ECC71).withValues(alpha: 0.08)
                    : const Color(0xFFE74C3C).withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _dijkstraResult!.highRiskSegments.isEmpty
                      ? const Color(0xFF2ECC71).withValues(alpha: 0.3)
                      : const Color(0xFFE74C3C).withValues(alpha: 0.3),
                ),
              ),
              child: Row(children: [
                Icon(
                  _dijkstraResult!.highRiskSegments.isEmpty ? Icons.verified_outlined : Icons.warning_amber_rounded,
                  size: 16,
                  color: _dijkstraResult!.highRiskSegments.isEmpty ? const Color(0xFF2ECC71) : const Color(0xFFE74C3C),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _dijkstraResult!.highRiskSegments.isEmpty
                        ? (_isThai ? 'ไม่พบจุดอันตรายในเส้นทางนี้' : 'No hazard zones detected on this route')
                        : (_isThai
                            ? 'ตรวจพบ ${_dijkstraResult!.highRiskSegments.length} จุดเสี่ยง (${_dijkstraResult!.avoidedIncidents} หมุดอันตราย) — ปรับเส้นทางเลี่ยงสำเร็จ'
                            : 'Found ${_dijkstraResult!.highRiskSegments.length} risk zones (${_dijkstraResult!.avoidedIncidents} incidents) — Route safely adjusted'),
                    style: TextStyle(
                      fontSize: 11.5,
                      color: _dijkstraResult!.highRiskSegments.isEmpty ? const Color(0xFF2ECC71) : const Color(0xFFE74C3C),
                    ),
                  ),
                ),
              ]),
            ),

            // Legend
            const SizedBox(height: 6),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              _buildLegendDot(const Color(0xFF3498DB), _isThai ? 'เส้นทางปลอดภัย' : 'Safe Route'),
              if (_dijkstraResult!.highRiskSegments.isNotEmpty) ...[
                const SizedBox(width: 14),
                _buildLegendDot(const Color(0xFFE74C3C), _isThai ? 'จุดเสี่ยงที่เลี่ยง' : 'Avoided Risk Zone'),
              ],
            ]),
          ],

          const SizedBox(height: 12),
          // Action buttons
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _clearRoutePlan,
                icon: Icon(Icons.refresh, size: 16, color: pal.text),
                label: Text(_s.selectNew, style: TextStyle(color: pal.text, fontWeight: FontWeight.w600)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: pal.text,
                  side: BorderSide(color: pal.textSub),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
            if (widget.onStartRun != null) ...[
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () {
                    final customRoute = RunningRoute(
                      id: 'custom_${DateTime.now().millisecondsSinceEpoch}',
                      name: _isThai ? 'เส้นทางปลอดภัย' : 'Safe route',
                      nameEn: 'Custom Safe Route',
                      description: _isThai ? 'เส้นทางที่เลี่ยงจุดเสี่ยงให้อัตโนมัติ' : 'Route optimized to avoid risk spots',
                      distanceKm: double.parse((_routeDistanceKm ?? 0.0).toStringAsFixed(2)),
                      difficulty: _routeDifficulty ?? classifyDifficultyFromElevation(_elevationGainM ?? 0),
                      elevationGainM: (_elevationGainM ?? 0).round(),
                      estimatedTime: _routeEstimatedTime ?? '30 min',
                      // เก็บคะแนนพื้นฐาน S_base (ก่อนคูณ T(t)) เพราะตอนแสดงผลจะปรับตามเวลาอีกครั้ง
                      safetyScore: ((_routeSafetyData?['safety']?['components']?['baseScore']) as num?)?.toInt()
                          ?? ((_routeSafetyData?['safety']?['score']) as num?)?.toInt() ?? 0,
                      path: _routePlanPath!,
                      waypoints: const [],
                    );
                    widget.onStartRun?.call(customRoute);
                  },
                  icon: const Icon(Icons.play_arrow_rounded, size: 20),
                  label: Text(_isThai ? 'เริ่มวิ่งเส้นทางนี้' : 'Start Safe Run', style: const TextStyle(fontWeight: FontWeight.w700)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFC4C02),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
            ],
          ]),

        ],
      ),
    );
  }

  Widget _buildElevBadge(IconData icon, String value, Color color, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Text('$label $value',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: color)),
      ]),
    );
  }

  Widget _buildLegendDot(Color color, String label) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 12, height: 4,
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
      ),
      const SizedBox(width: 5),
      Text(label, style: TextStyle(fontSize: 10, color: pal.textSub)),
    ]);
  }


  Widget _buildElevationChart() {
    if (_elevationPoints.length < 2) {
      return Container(
        height: 56,
        decoration: BoxDecoration(
          color: pal.surface2,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Center(
          child: Text(
            _isFetchingElevation ? _s.loadingElevation : _s.noElevationData,
            style: TextStyle(fontSize: 11, color: pal.textMute),
          ),
        ),
      );
    }

    final minElev = _elevationPoints.reduce((a, b) => a < b ? a : b);
    final maxElev = _elevationPoints.reduce((a, b) => a > b ? a : b);
    final range = (maxElev - minElev).clamp(1.0, double.infinity);

    return Container(
      height: 64,
      decoration: BoxDecoration(
        color: pal.surface2,
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: Column(
        children: [
          Expanded(
            child: CustomPaint(
              painter: _ElevationChartPainter(
                elevations: _elevationPoints,
                minElev: minElev,
                range: range,
              ),
              child: Container(),
            ),
          ),
          const SizedBox(height: 3),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('${minElev.round()} m', style: TextStyle(fontSize: 9, color: pal.textMute)),
              Text(_s.elevationProfile, style: TextStyle(fontSize: 9, color: pal.textMute)),
              Text('${maxElev.round()} m', style: TextStyle(fontSize: 9, color: pal.textMute)),
            ],
          ),
        ],
      ),
    );
  }

  // ────────────────────────────────────────────────────────────

  Future<void> _fetchPreRunSimulation(LatLng pos) async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _selectedPoint = pos;
    });
    try {
      final data = await ApiService.getPreRunSimulation(
        pos.latitude,
        pos.longitude,
        activeIncidentCount: _countActiveIncidentsNear([pos], radiusM: 200),
      );
      if (!mounted) return;
      setState(() => _simulationData = data);
      _showSafetyScoreModal();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$e'),
          backgroundColor: const Color(0xFFE74C3C),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showWaypointInfo(Waypoint wp) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) {
        return Container(
          decoration: BoxDecoration(
            color: pal.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: pal.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: _getWaypointColor(wp.type).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: _getWaypointColor(
                          wp.type,
                        ).withValues(alpha: 0.4),
                      ),
                    ),
                    child: Icon(
                      _getWaypointIcon(wp.type),
                      color: _getWaypointColor(wp.type),
                      size: 26,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          wp.displayName,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: _getWaypointColor(
                              wp.type,
                            ).withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            wp.type.toUpperCase(),
                            style: TextStyle(
                              fontSize: 10,
                              color: _getWaypointColor(wp.type),
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (wp.description != null) ...[
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: pal.surface2,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    wp.displayDescription!,
                    style: TextStyle(
                      color: pal.textSub,
                      fontSize: 14,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }

  void _showSafetyScoreModal() {
    if (_simulationData == null) return;
    final safety = _simulationData!['safety'];
    final weather = _simulationData!['weather'];
    final airQuality = _simulationData!['airQuality'];
    final score = safety['score'];

    final Color scoreColor = SafetyScoreEngine.scoreColor((score as num).toInt());

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) {
        return Container(
          decoration: BoxDecoration(
            color: pal.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: pal.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 24),
              Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      scoreColor.withValues(alpha: 0.3),
                      scoreColor.withValues(alpha: 0.05),
                    ],
                  ),
                  border: Border.all(color: scoreColor, width: 3),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      '$score',
                      style: TextStyle(
                        fontSize: 40,
                        fontWeight: FontWeight.w800,
                        color: scoreColor,
                      ),
                    ),
                    Text(
                      tr('ความปลอดภัย', 'Safety'),
                      style: TextStyle(
                        fontSize: 12,
                        color: scoreColor.withValues(alpha: 0.7),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: pal.surface2,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _buildInfoItem(
                      Icons.thermostat,
                      '${weather['temperature']}°C',
                      tr('อุณหภูมิ', 'Temp'),
                    ),
                    Container(width: 1, height: 40, color: pal.border),
                    _buildInfoItem(
                      Icons.air,
                      '${weather['windspeed']} km/h',
                      tr('ลม', 'Wind'),
                    ),
                    Container(width: 1, height: 40, color: pal.border),
                    _buildPm25Item(airQuality['pm2_5']?.toString() ?? '-'),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              if (safety['alerts'] != null &&
                  (safety['alerts'] as List).isNotEmpty)
                ...List.generate(
                  (safety['alerts'] as List).length,
                  (i) => Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF39C12).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: const Color(0xFFF39C12).withValues(alpha: 0.3),
                      ),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.warning_amber_rounded,
                          color: Color(0xFFF39C12),
                          size: 20,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            safety['alerts'][i],
                            style: const TextStyle(
                              color: Color(0xFFF39C12),
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              else
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2ECC71).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: const Color(0xFF2ECC71).withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.check_circle,
                        color: Color(0xFF2ECC71),
                        size: 20,
                      ),
                      SizedBox(width: 10),
                      Text(
                        tr('สภาพเหมาะกับการวิ่ง!', 'Great conditions for running!'),
                        style: TextStyle(
                          color: Color(0xFF2ECC71),
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFC4C02),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    elevation: 0,
                  ),
                  child: Text(
                    tr('เริ่มวิ่งที่นี่', 'Start Run Here'),
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Widget _buildInfoItem(IconData icon, String value, String label) {
    return Column(
      children: [
        Icon(icon, color: const Color(0xFFFC4C02), size: 22),
        const SizedBox(height: 6),
        Text(
          value,
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: pal.textSub,
          ),
        ),
      ],
    );
  }

  Widget _buildPm25Item(String pm25Str) {
    final pm25 = double.tryParse(pm25Str) ?? 0.0;
    Color color;
    String aqiLabel;
    if (pm25 > 75) {
      color = const Color(0xFFE74C3C);
      aqiLabel = _s.dangerous;
    } else if (pm25 > 35) {
      color = const Color(0xFFF39C12);
      aqiLabel = _s.moderateAir;
    } else {
      color = const Color(0xFF2ECC71);
      aqiLabel = _s.goodAir;
    }
    return Column(
      children: [
        Icon(Icons.blur_on, color: color, size: 22),
        const SizedBox(height: 6),
        Text(
          '$pm25Str μg',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: color),
        ),
        const SizedBox(height: 2),
        Text(
          'PM2.5 • $aqiLabel',
          style: TextStyle(fontSize: 10, color: color.withValues(alpha: 0.8)),
        ),
      ],
    );
  }


  @override
  Widget build(BuildContext context) {
    final s = AppStrings(isThai: context.watch<LanguageProvider>().isThai);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: pal.surface.withValues(alpha: 0.92),
        // ตัวอักษร/ไอคอนบน AppBar สีขาว — เดิมใช้สีตามธีมสว่าง (เข้ม) บนพื้นเข้ม อ่านไม่ออก
        foregroundColor: pal.text,
        titleTextStyle: TextStyle(color: pal.text, fontSize: 20, fontWeight: FontWeight.w700),
        iconTheme: IconThemeData(color: pal.text),
        titleSpacing: 0,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.explore, color: Color(0xFFFC4C02), size: 22),
            const SizedBox(width: 8),
            // Flexible + ellipsis กัน "RIGHT OVERFLOWED" เมื่อมีปุ่ม ✕ เพิ่มใน actions
            Flexible(
              child: Text(
                s.isThai ? 'สำรวจเชียงใหม่' : 'Explore Chiang Mai',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        actions: [
          if (_selectedRoute != null || _selectedZone != null)
            IconButton(
              icon: Icon(Icons.close, color: pal.textSub),
              onPressed: () {
                _clearRoute();
                _clearZone();
              },
            ),
          IconButton(
            icon: Icon(
              Icons.my_location,
              color: _isCurrentPosValid ? const Color(0xFF3498DB) : pal.textSub,
            ),
            onPressed: () {
              if (_isCurrentPosValid) {
                _mapController.move(_currentPosition!, 15.0);
              } else {
                _getCurrentLocation(showDialogs: true);
                _mapController.move(_chiangMaiCenter, 14.0);
              }
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          // Map
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _isCurrentPosValid ? _currentPosition! : _chiangMaiCenter,
              initialZoom: 13.0,
              onMapReady: _onMapReady,
              onTap: (tapPosition, point) {
                if (_isReportMode) {
                  _handleReportPinTap(point);
                } else if (_isRoutePlanMode) {
                  _handleRoutePlanTap(point);
                } else {
                  // แตะภายในรูปทรงโซน — ถ้าซ้อนกันหลายโซน เลือกโซนที่เล็กที่สุด
                  RunningZone? tapped;
                  double tappedA = double.infinity;
                  for (final z in _zones) {
                    if (!ZoneService.pointInZone(point, z)) continue;
                    final a = _zoneAreaM2(z);
                    if (a < tappedA) {
                      tapped = z;
                      tappedA = a;
                    }
                  }
                  if (tapped != null) {
                    _selectZone(tapped);
                  } else if (_selectedZone != null) {
                    _clearZone();
                  } else {
                    _fetchPreRunSimulation(point);
                  }
                }
              },
            ),
            children: [
              // Base map tile (MapTiler Streets)
              TileLayer(
                urlTemplate:
                    'https://api.maptiler.com/maps/${pal.isDark ? 'streets-v2-dark' : 'streets-v2'}/256/{z}/{x}/{y}@2x.png?key=KPAM4YzsLppPleBVLffd',
                userAgentPackageName: 'com.example.routefinder',
                maxZoom: 19,
              ),

              // ── Real-time Traffic Overlay (TomTom) ──
              // แสดงสภาพการจราจรแบบ Real-time บนแผนที่เสมออัตโนมัติ (ไม่ต้องกดเปิด/ปิด)
              if (_tomtomKey.isNotEmpty)
                Opacity(
                  opacity: _trafficLayerOpacity,
                  child: TileLayer(
                    // TomTom Traffic Flow Tiles
                    urlTemplate:
                        'https://api.tomtom.com/traffic/map/4/tile/flow/relative0/{z}/{x}/{y}.png?key=$_tomtomKey',
                    userAgentPackageName: 'com.example.routefinder',
                    maxZoom: 22,
                  ),
                ),

              // Fallback Incident Heatmap (แสดงเฉพาะกรณีไม่มี TomTom key)
              if (_tomtomKey.isEmpty && _activeIncidents.isNotEmpty)
                MarkerLayer(
                  markers: _activeIncidents.map((inc) {
                    // คำนวณขนาดวง ตามยอดยืนยัน (confirmationsCount)
                    final votes = (inc.confirmationsCount).clamp(1, 20);
                    final radius = 20.0 + (votes * 3.0);
                    final heatColor = inc.type == 'accident'
                        ? const Color(0xFFE74C3C)   // อุบัติเหตุ — แดง
                        : inc.type == 'construction' || inc.type == 'flooding'
                            ? const Color(0xFFF39C12) // ขวางทาง — เหลือง
                            : const Color(0xFFE67E22); // อื่นๆ — ส้ม
                    return Marker(
                      point: inc.position,
                      width: radius * 2,
                      height: radius * 2,
                      child: Opacity(
                        opacity: 0.45,
                        child: Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(
                              colors: [
                                heatColor,
                                heatColor.withValues(alpha: 0.0),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),

              // Current User Location Marker
              if (_isCurrentPosValid)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: _currentPosition!,
                      width: 44,
                      height: 44,
                      child: Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(0xFF2980B9).withValues(alpha: 0.25),
                        ),
                        child: Center(
                          child: Container(
                            width: 22,
                            height: 22,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: const Color(0xFF3498DB),
                              border: Border.all(color: Colors.white, width: 3),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFF3498DB).withValues(alpha: 0.6),
                                  blurRadius: 10,
                                  spreadRadius: 2,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),

              // ── Running Zones: รูปทรงจริงของสถานที่ สีจางตามระดับความปลอดภัย ไม่มีเส้นขอบหนา ──
              if (_zones.isNotEmpty)
                PolygonLayer(
                  polygons: [
                    for (int i = 0; i < _zones.length; i++)
                      for (final ring in _zones[i].polygons)
                        if (ring.length >= 3)
                          () {
                            final z = _zones[i];
                            final isTop5 = i < 5;
                            final isSelected = _selectedZone?.id == z.id;
                            final color = z.safetyScore != null
                                ? SafetyScoreEngine.scoreColor(z.safetyScore!)
                                : const Color(0xFF95A5A6);
                            return Polygon(
                              points: ring,
                              color: color.withValues(
                                  alpha: isSelected ? 0.30 : (isTop5 ? 0.18 : 0.10)),
                              // ขอบบางมาก สีเดียวกับพื้น ช่วยให้เห็นขอบเขตโดยไม่เป็นเส้นหนา
                              borderColor: color.withValues(alpha: isSelected ? 0.6 : 0.35),
                              borderStrokeWidth: isSelected ? 1.2 : 0.8,
                            );
                          }(),
                  ],
                ),

              // ── Zone Markers & Labels at center ──
              if (_zones.isNotEmpty && !_isRoutePlanMode)
                MarkerLayer(
                  markers: () {
                    final markerList = <Marker>[];
                    for (int i = 0; i < _zones.length; i++) {
                      final z = _zones[i];
                      final isTop5 = i < 5;
                      final isSelected = _selectedZone?.id == z.id;
                      final score = z.safetyScore;
                      final color = score != null
                          ? SafetyScoreEngine.scoreColor(score)
                          : const Color(0xFF95A5A6);

                      markerList.add(Marker(
                        point: z.center,
                        width: isTop5 || isSelected ? 144 : 110,
                        height: 38,
                        child: GestureDetector(
                          onTap: () => _selectZone(z),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: pal.surface.withValues(
                                  alpha: isSelected ? 0.95 : (isTop5 ? 0.88 : 0.65)),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: color.withValues(
                                    alpha: isSelected ? 1.0 : (isTop5 ? 0.85 : 0.40)),
                                width: isSelected ? 2.5 : (isTop5 ? 1.5 : 1.0),
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(
                                      alpha: isTop5 || isSelected ? 0.15 : 0.06),
                                  blurRadius: 6,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: color,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 5),
                                Flexible(
                                  child: Text(
                                    z.displayName,
                                    style: TextStyle(
                                      fontSize: isTop5 || isSelected ? 11 : 10,
                                      fontWeight: isTop5 || isSelected
                                          ? FontWeight.w700
                                          : FontWeight.w600,
                                      color: pal.text,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  score != null ? '$score' : '…',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w800,
                                    color: color,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ));
                    }
                    return markerList;
                  }(),
                ),

              // Route polyline (preset routes)
              if (_selectedRoute != null && _fetchedPath != null)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: _fetchedPath!,
                      strokeWidth: 5.0,
                      color: const Color(0xFFFC4C02),
                    ),
                  ],
                ),

              // Route Plan polylines (Safety-Aware Dijkstra เป็นเส้นหลักเสมอ)
              if (_routePlanPath != null && _routePlanPath!.isNotEmpty)
                PolylineLayer(
                  polylines: [
                    // เส้นทางปลอดภัย (สีน้ำเงินสด Stroke 6.0)
                    Polyline(
                      points: _routePlanPath!,
                      strokeWidth: 6.0,
                      color: const Color(0xFF3498DB),
                      strokeCap: StrokeCap.round,
                    ),
                  ],
                ),

              // High-Risk Segments highlight (แดง — จุดอันตรายที่ Dijkstra ตรวจพบ)
              if (_useSafetyDijkstra &&
                  _dijkstraResult != null &&
                  _dijkstraResult!.highRiskSegments.isNotEmpty)
                PolylineLayer(
                  polylines: _dijkstraResult!.highRiskSegments.map((seg) {
                    final riskColor = seg.riskLevel == 3
                        ? const Color(0xFFE74C3C)   // สูงมาก — แดง
                        : seg.riskLevel == 2
                            ? const Color(0xFFE67E22) // สูง — ส้ม
                            : const Color(0xFFF1C40F); // ปานกลาง — เหลือง
                    return Polyline(
                      points: [seg.start, seg.end],
                      strokeWidth: 8.0,
                      color: riskColor.withValues(alpha: 0.75),
                      strokeCap: StrokeCap.round,
                    );
                  }).toList(),
                ),

              // Waypoint markers
              if (_selectedRoute != null)
                MarkerLayer(
                  markers: _selectedRoute!.waypoints.map((wp) {
                    return Marker(
                      point: wp.position,
                      width: 40,
                      height: 40,
                      child: GestureDetector(
                        onTap: () => _showWaypointInfo(wp),
                        child: Container(
                          decoration: BoxDecoration(
                            color: _getWaypointColor(wp.type),
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: _getWaypointColor(
                                  wp.type,
                                ).withValues(alpha: 0.4),
                                blurRadius: 8,
                              ),
                            ],
                          ),
                          child: Icon(
                            _getWaypointIcon(wp.type),
                            color: Colors.white,
                            size: 20,
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),

              // Route Plan Start/End Markers
              if (_isRoutePlanMode)
                MarkerLayer(
                  markers: [
                    if (_routeStartPoint != null)
                      Marker(
                        point: _routeStartPoint!,
                        width: 44,
                        height: 44,
                        child: Container(
                          decoration: BoxDecoration(
                            color: const Color(0xFF2ECC71),
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 2),
                            boxShadow: [BoxShadow(color: const Color(0xFF2ECC71).withValues(alpha: 0.5), blurRadius: 10)],
                          ),
                          child: const Icon(Icons.trip_origin, color: Colors.white, size: 22),
                        ),
                      ),
                    if (_routeEndPoint != null)
                      Marker(
                        point: _routeEndPoint!,
                        width: 44,
                        height: 44,
                        child: Container(
                          decoration: BoxDecoration(
                            color: const Color(0xFFE74C3C),
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 2),
                            boxShadow: [BoxShadow(color: const Color(0xFFE74C3C).withValues(alpha: 0.5), blurRadius: 10)],
                          ),
                          child: const Icon(Icons.location_on, color: Colors.white, size: 22),
                        ),
                      ),
                    // Midpoint safety badge for planned route
                    if (_routeMidPoint != null && _routeSafetyData != null)
                      Marker(
                        point: _routeMidPoint!,
                        width: 54,
                        height: 54,
                        child: GestureDetector(
                          onTap: () => _showScoreBreakdown(
                              (_routeSafetyData!['safety']['score'] as int),
                              (_routeSafetyData!['safety']['alerts'] as List),
                              _routeSafetyData!['weather'],
                              _routeSafetyData!['airQuality']),
                          child: Container(
                            decoration: BoxDecoration(
                              color: SafetyScoreEngine.scoreColor(
                                      _routeSafetyData!['safety']['score'] as int)
                                  .withValues(alpha: 0.18),
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 2.5),
                              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.2), blurRadius: 8)],
                            ),
                            child: Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.shield, color: Colors.white, size: 18),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${_routeSafetyData!['safety']['score']}',
                                    style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w800),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),

              // Tapped point marker
              if (_selectedPoint != null && _selectedRoute == null && !_isRoutePlanMode)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: _selectedPoint!,
                      width: 50,
                      height: 50,
                      child: Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFFFC4C02).withValues(alpha: 0.3),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: const Color(0xFFFC4C02),
                            width: 2,
                          ),
                        ),
                        child: const Icon(
                          Icons.location_on,
                          color: Color(0xFFFC4C02),
                          size: 28,
                        ),
                      ),
                    ),
                  ],
                ),

              // FR 8 & 10: Live Active Incident Markers Layer
              if (_activeIncidents.isNotEmpty)
                MarkerLayer(
                  markers: _activeIncidents.map((inc) {
                    return Marker(
                      point: inc.position,
                      width: 44,
                      height: 44,
                      child: GestureDetector(
                        onTap: () => _showIncidentDetailsModal(inc),
                        child: Container(
                          decoration: BoxDecoration(
                            color: _getIncidentColor(inc.type),
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 2.5),
                            boxShadow: [
                              BoxShadow(
                                color: _getIncidentColor(inc.type).withValues(alpha: 0.5),
                                blurRadius: 10,
                                spreadRadius: 1,
                              ),
                            ],
                          ),
                          child: Center(
                            child: Text(
                              _getIncidentEmoji(inc.type),
                              style: const TextStyle(fontSize: 20),
                            ),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
            ],
          ),


          // Incident Report Floating Button (FR 8)
          Positioned(
            top: 100,
            right: 16,
            child: FloatingActionButton.small(
              heroTag: 'incidentReportFab',
              backgroundColor: _isReportMode ? const Color(0xFFE74C3C) : pal.surface.withValues(alpha: 0.9),
              foregroundColor: Colors.white,
              elevation: 4,
              onPressed: () {
                setState(() {
                  _isReportMode = !_isReportMode;
                  if (_isReportMode) _isRoutePlanMode = false;
                });
              },
              child: Icon(
                _isReportMode ? Icons.close : Icons.add_location_alt_outlined,
                color: _isReportMode ? Colors.white : const Color(0xFFE74C3C),
              ),
            ),
          ),

          // Report Mode Banner (FR 8)
          if (_isReportMode)
            Positioned(
              top: 96,
              left: 16,
              right: 70,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFFE74C3C),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 10)],
                ),
                child: Row(
                  children: [
                    const Icon(Icons.touch_app, color: Colors.white, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _s.tapMapPinReport,
                        style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                    ),
                    GestureDetector(
                      onTap: () => setState(() => _isReportMode = false),
                      child: const Icon(Icons.close, color: Colors.white, size: 18),
                    ),
                  ],
                ),
              ),
            ),

          // Loading overlay
          if (_isLoading)
            Container(
              color: Colors.black26,
              child: const Center(
                child: CircularProgressIndicator(color: Color(0xFFFC4C02)),
              ),
            ),

          // Fetching route indicator
          if (_isFetchingRoute)
            Positioned(
              top: 100,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: pal.surface.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 14, height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color(0xFFFC4C02),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(_s.loadingRealRoute, style: TextStyle(color: pal.text, fontSize: 12)),
                    ],
                  ),
                ),
              ),
            ),

          // Zone Selection Panel (when a running zone is selected)
          if (_selectedZone != null)
            Positioned(
              bottom: 24 + MediaQuery.of(context).padding.bottom,
              left: 16,
              right: 16,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.65),
                child: SingleChildScrollView(child: _buildSelectedZoneCard()),
              ),
            ),

          // Route Selection Panel (when a route is selected)
          if (_selectedRoute != null)
            Positioned(
              // เว้นระยะแถบนำทางของระบบ + จำกัดความสูง กันการ์ดล้นจอ
              bottom: 24 + MediaQuery.of(context).padding.bottom,
              left: 16,
              right: 16,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.62),
                child: SingleChildScrollView(child: _buildSelectedRouteCard()),
              ),
            ),

          // Route Plan loading overlay
          if (_isFetchingRoutePlan)
            Positioned(
              top: 100, left: 0, right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: pal.surface.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF2ECC71))),
                      const SizedBox(width: 8),
                      Text(_s.calculatingRoute, style: TextStyle(color: pal.text, fontSize: 12)),
                    ],
                  ),
                ),
              ),
            ),

          // Route Plan Card
          if (_isRoutePlanMode && _routeSafetyData != null)
            Positioned(
              bottom: 24 + MediaQuery.of(context).padding.bottom, left: 16, right: 16,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.62),
                child: SingleChildScrollView(child: _buildRoutePlanCard()),
              ),
            ),

          // Route Plan instructions (no end point yet)
          if (_isRoutePlanMode && _routeSafetyData == null)
            Positioned(
              bottom: 24, left: 16, right: 16,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Instruction bar
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: pal.surface.withValues(alpha: 0.95),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 36, height: 36,
                          decoration: BoxDecoration(
                            color: _routeStartPoint == null
                                ? const Color(0xFF2ECC71).withValues(alpha: 0.2)
                                : const Color(0xFFE74C3C).withValues(alpha: 0.2),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            _routeStartPoint == null ? Icons.trip_origin : Icons.location_on,
                            color: _routeStartPoint == null ? const Color(0xFF2ECC71) : const Color(0xFFE74C3C),
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _routeStartPoint == null
                                    ? _s.tapMapSelectStart
                                    : _s.tapMapSelectDest,
                                style: TextStyle(color: pal.text, fontSize: 14, fontWeight: FontWeight.w600),
                              ),
                              if (_routeStartPoint == null && _isCurrentPosValid)
                                Padding(
                                  padding: const EdgeInsets.only(top: 6),
                                  child: GestureDetector(
                                    onTap: () => setState(() {
                                      _routeStartPoint = _currentPosition;
                                      if (_routeEndPoint != null) _fetchRoutePlan();
                                    }),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF2ECC71).withValues(alpha: 0.12),
                                        borderRadius: BorderRadius.circular(10),
                                        border: Border.all(color: const Color(0xFF2ECC71).withValues(alpha: 0.25)),
                                      ),
                                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                                        const Icon(Icons.my_location, size: 14, color: Color(0xFF2ECC71)),
                                        const SizedBox(width: 6),
                                        Flexible(child: Text(_s.useCurrentLocationAsStart, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Color(0xFF2ECC71), fontSize: 12, fontWeight: FontWeight.w700))),
                                      ]),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        if (_routeStartPoint != null)
                          GestureDetector(
                            onTap: _clearRoutePlan,
                            child: Icon(Icons.refresh, color: pal.text, size: 22),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  // Cancel button
                  GestureDetector(
                    onTap: () => setState(() {
                      _isRoutePlanMode = false;
                      _clearRoutePlan();
                    }),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      decoration: BoxDecoration(
                        color: pal.surface.withValues(alpha: 0.9),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: pal.textSub),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.arrow_back_rounded, color: pal.text, size: 18),
                          const SizedBox(width: 8),
                          Text(_s.cancelPlanning,
                              style: TextStyle(color: pal.text, fontSize: 14, fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),

          // Bottom bar: Two premium buttons
          if (_selectedRoute == null && _selectedZone == null && !_isRoutePlanMode)
            Positioned(
              bottom: 24,
              left: 16,
              right: 16,
              child: Row(
                children: [
                  // ปุ่มโซนแนะนำ
                  Expanded(
                    child: GestureDetector(
                      onTap: () => setState(() => _showRouteList = true),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 18),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFFFC4C02), Color(0xFFFF7043)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFFFC4C02).withValues(alpha: 0.45),
                              blurRadius: 18,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.shield_rounded, color: Colors.white, size: 28),
                            const SizedBox(height: 6),
                            Text(
                              _s.recommendedZones,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.3,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _s.popularRoutes,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // ปุ่มวางแผนเส้นทาง
                  Expanded(
                    child: GestureDetector(
                      onTap: () => setState(() {
                        _isRoutePlanMode = true;
                        _clearRoutePlan();
                      }),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 18),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFF11998e), Color(0xFF38ef7d)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF11998e).withValues(alpha: 0.45),
                              blurRadius: 18,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.alt_route, color: Colors.white, size: 28),
                            const SizedBox(height: 6),
                            Text(
                              _s.planRoute,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.3,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _s.pickStartEnd,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

          // Route List Bottom Sheet
          if (_showRouteList) _buildRouteListOverlay(),
        ],
      ),
    );
  }

  Widget _buildSelectedZoneCard() {
    final zone = _selectedZone!;
    final score = zone.safetyScore;
    final scoreColor = score != null ? SafetyScoreEngine.scoreColor(score) : const Color(0xFF95A5A6);
    final level = score != null ? SafetyScoreEngine.getSafetyLevel(score) : null;
    final levelLabel = level == SafetyLevel.safe
        ? _s.safe
        : (level == SafetyLevel.caution ? _s.caution : _s.notRecommended);

    double? distFromUserM;
    if (_isCurrentPosValid) {
      distFromUserM = Geolocator.distanceBetween(
        _currentPosition!.latitude, _currentPosition!.longitude,
        zone.center.latitude, zone.center.longitude,
      );
    }
    final distLabel = distFromUserM != null
        ? (distFromUserM < 1000
            ? '${distFromUserM.round()} m'
            : '${(distFromUserM / 1000).toStringAsFixed(1)} km')
        : null;

    final road = zone.scoreComponents?['road'] as Map?;
    final pm25 = zone.scoreComponents?['pm25'];

    return Container(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 16),
      decoration: BoxDecoration(
        color: pal.surface.withValues(alpha: 0.97),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 20,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drag handle / expand toggle
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _isZoneCardExpanded = !_isZoneCardExpanded),
            child: SizedBox(
              width: double.infinity,
              height: 24,
              child: Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: pal.textMute,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
          ),

          // Header: Zone Name & Close
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      zone.displayName,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: pal.text,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Icon(Icons.category_rounded, size: 13, color: pal.textSub),
                        const SizedBox(width: 4),
                        Text(
                          _zoneCategoryLabel(zone.category),
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: pal.textSub,
                          ),
                        ),
                        if (distLabel != null) ...[
                          const SizedBox(width: 6),
                          Text('•', style: TextStyle(color: pal.textMute, fontSize: 10)),
                          const SizedBox(width: 6),
                          const Icon(Icons.near_me_rounded, size: 12, color: Color(0xFF3498DB)),
                          const SizedBox(width: 3),
                          Text(
                            distLabel,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFF3498DB),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              // ❤️ เส้นทางโปรด (IT-08) — โซนที่ตรงกับเส้นทางยอดนิยม ใช้คีย์เดียวกับการ์ดเส้นทาง
              if (_popularRouteForZone(zone) case final route?) ...[
                GestureDetector(
                  onTap: () => _toggleFavorite(route.nameEn),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(
                      color: _savedRouteIds.contains(route.nameEn)
                          ? const Color(0xFFE74C3C).withValues(alpha: 0.15)
                          : pal.surface2,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      _savedRouteIds.contains(route.nameEn)
                          ? Icons.favorite_rounded
                          : Icons.favorite_border_rounded,
                      color: _savedRouteIds.contains(route.nameEn)
                          ? const Color(0xFFE74C3C)
                          : pal.textMute,
                      size: 16,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              // Close button
              GestureDetector(
                onTap: _clearZone,
                child: Container(
                  padding: const EdgeInsets.all(5),
                  decoration: BoxDecoration(
                    color: pal.surface2,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.close_rounded, color: pal.textSub, size: 16),
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),

          // Key metrics row (Score, Level chip, PM2.5) — ห่อด้วย Flexible+Wrap กันล้นบนจอแคบ
          Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: scoreColor.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: scoreColor, width: 1.5),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.shield_rounded, color: scoreColor, size: 16),
                    const SizedBox(width: 6),
                    Text(
                      score != null ? '$score' : _s.assessingZone,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: scoreColor,
                      ),
                    ),
                    if (score != null) ...[
                      const SizedBox(width: 4),
                      Text(
                        '· $levelLabel',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: scoreColor,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (pm25 != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                  decoration: BoxDecoration(
                    color: pal.surface2,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.air_rounded, color: pal.textSub, size: 14),
                      const SizedBox(width: 4),
                      Text(
                        'AQI $pm25',
                        style: TextStyle(color: pal.textSub, fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),

                  ],
                ),
              ),
              const SizedBox(width: 8),

              GestureDetector(
                onTap: () => setState(() => _isZoneCardExpanded = !_isZoneCardExpanded),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _isZoneCardExpanded ? tr('ย่อ', 'Less') : tr('เพิ่มเติม', 'Details'),
                      style: const TextStyle(color: Color(0xFF3498DB), fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                    Icon(
                      _isZoneCardExpanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                      color: const Color(0xFF3498DB),
                      size: 18,
                    ),
                  ],
                ),
              ),
            ],
          ),

          // ─── Recommendation Reasons (เหตุผลแนะนำ 2–3 ข้อ) ───
          if (zone.recommendationReasons.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 5,
              children: zone.recommendationReasons.map((reason) {
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                  decoration: BoxDecoration(
                    color: pal.surface2,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: pal.border),
                  ),
                  child: Text(
                    reason,
                    style: TextStyle(
                      fontSize: 11,
                      color: pal.text,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                );
              }).toList(),
            ),
          ],

          // ─── Expanded Section ───
          if (_isZoneCardExpanded) ...[
            const SizedBox(height: 12),
            Divider(color: pal.border, height: 1),
            const SizedBox(height: 10),

            Text(
              zone.displayDescription,
              style: TextStyle(fontSize: 13, color: pal.textSub, height: 1.4),
            ),
            const SizedBox(height: 10),

            if (zone.scoreComponents != null) ...[
              Text(
                _s.zoneSafetyFactors,
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: pal.text),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _buildFactorChip(tr('อากาศ', 'Air'), '${zone.scoreComponents!['sAir'] ?? '-'}/100'),
                  _buildFactorChip(tr('สภาพอากาศ', 'Weather'), '${zone.scoreComponents!['sWx'] ?? '-'}/100'),
                  _buildFactorChip(tr('จราจร', 'Traffic'), '${zone.scoreComponents!['sTrf'] ?? '-'}/100'),
                  _buildFactorChip(tr('เหตุการณ์', 'Incidents'), '${zone.scoreComponents!['sInc'] ?? '-'}/100'),
                  _buildFactorChip(tr('ช่วงเวลา', 'Time'), _timeFactorLabel(zone.scoreComponents!['timeFactor'])),
                ],
              ),
              const SizedBox(height: 8),

              if (road != null) ...[
                if ((road['majorRoadShare'] as num? ?? 0) == 0)
                  _buildReasonRow(Icons.check_circle_rounded, const Color(0xFF2ECC71), tr('ไม่มีถนนสายหลักในโซน', 'No major roads in zone')),
                if ((road['protectedShare'] as num? ?? 0) > 0.5)
                  _buildReasonRow(Icons.check_circle_rounded, const Color(0xFF2ECC71), tr('มีทางเท้า/ทางแยกปลอดภัย ${((road['protectedShare'] as num) * 100).round()}%', 'Protected sidewalk ${((road['protectedShare'] as num) * 100).round()}%')),
                if (road['litShare'] != null && (road['litShare'] as num) > 0.5)
                  _buildReasonRow(Icons.lightbulb_rounded, const Color(0xFFF1C40F), tr('ไฟส่องสว่าง ${((road['litShare'] as num) * 100).round()}%', 'Street lighting ${((road['litShare'] as num) * 100).round()}%')),
              ],
            ],

            if (zone.waypoints.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: zone.waypoints.map((wp) {
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: pal.surface2,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '• ${wp.displayName}',
                      style: TextStyle(fontSize: 11, color: pal.textSub),
                    ),
                  );
                }).toList(),
              ),
            ],
            const SizedBox(height: 12),
          ],

          const SizedBox(height: 14),

          // ─── เส้นทางมาตรฐานของโซน: เลือกจำนวนรอบ ───
          Builder(builder: (context) {
            final lapKm = RoutingService.fixedCourseLapKm(zone);
            final opts = RoutingService.lapOptions(zone);
            final linear = RoutingService.isLinearCourse(zone);
            if (!opts.contains(_selectedLaps)) _selectedLaps = opts.first;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  linear
                      ? tr('เส้นทางมาตรฐาน · ${lapKm.toStringAsFixed(1)} กม. (ทางเดียว)',
                          'Standard course · ${lapKm.toStringAsFixed(1)} km (one way)')
                      : tr('เส้นทางมาตรฐาน · 1 รอบ = ${lapKm.toStringAsFixed(2)} กม.',
                          'Standard course · 1 lap = ${lapKm.toStringAsFixed(2)} km'),
                  style: TextStyle(color: pal.textSub, fontSize: 12, fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    for (int k = 0; k < opts.length; k++) ...[
                      if (k > 0) const SizedBox(width: 6),
                      Expanded(
                        child: GestureDetector(
                          onTap: () => setState(() => _selectedLaps = opts[k]),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            height: 40,
                            alignment: Alignment.center,
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            decoration: BoxDecoration(
                              color: _selectedLaps == opts[k]
                                  ? const Color(0xFF3498DB)
                                  : pal.surface2,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: _selectedLaps == opts[k]
                                    ? const Color(0xFF3498DB)
                                    : pal.border,
                              ),
                            ),
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    linear
                                        ? tr('ทางเดียว', 'One way')
                                        : tr('${opts[k]} รอบ', '${opts[k]} ${opts[k] == 1 ? 'lap' : 'laps'}'),
                                    style: TextStyle(
                                      color: _selectedLaps == opts[k] ? Colors.white : pal.textSub,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  Text(
                                    tr('${(lapKm * opts[k]).toStringAsFixed(1)} กม.',
                                        '${(lapKm * opts[k]).toStringAsFixed(1)} km'),
                                    style: TextStyle(
                                      color: _selectedLaps == opts[k] ? Colors.white70 : pal.textMute,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            );
          }),

          const SizedBox(height: 12),

          // ─── Main Action Buttons ───
          Row(
            children: [
              // Button 1: Free Run in this Zone
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => RecordScreen(selectedZone: zone),
                      ),
                    );
                  },
                  icon: const Icon(Icons.directions_run_rounded, size: 18),
                  // FittedBox: ย่อตัวอักษรให้พอดีปุ่ม แทนการตัดคำ ("สร้างเส้นทางวงรอ…")
                  label: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      _s.freeRunInZone,
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                      maxLines: 1,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2ECC71),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                ),
              ),
              const SizedBox(width: 10),

              // Button 2: Create Loop Route
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _isGeneratingLoop
                      ? null
                      : () => _generateLoopInZone(zone, _selectedLaps),
                  icon: _isGeneratingLoop
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.alt_route_rounded, size: 18),
                  // FittedBox: ย่อตัวอักษรให้พอดีปุ่ม แทนการตัดคำ ("สร้างเส้นทางวงรอ…")
                  label: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      _isGeneratingLoop ? tr('กำลังสร้าง…', 'Generating…') : _s.createLoopRoute,
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                      maxLines: 1,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFC4C02),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// ชื่อหมวดของโซนตามภาษา (เดิมแสดงเป็น "PARK" ภาษาอังกฤษตัวพิมพ์ใหญ่ทุกโหมด)
  String _zoneCategoryLabel(String category) {
    switch (category) {
      case 'moat':
        return tr('คูเมือง', 'Moat');
      case 'park':
        return tr('สวนสาธารณะ', 'Park');
      case 'stadium':
        return tr('สนามกีฬา', 'Stadium');
      case 'campus':
        return tr('มหาวิทยาลัย', 'Campus');
      case 'reservoir':
        return tr('อ่างเก็บน้ำ', 'Reservoir');
      case 'track':
        return tr('ลู่วิ่ง', 'Running track');
      case 'trail':
        return tr('เส้นทางเทรล', 'Trail');
      default:
        return tr('พื้นที่วิ่ง', 'Running area');
    }
  }

  Widget _buildFactorChip(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: pal.surface2,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '$label: $value',
        style: TextStyle(color: pal.textSub, fontSize: 10, fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _buildReasonRow(IconData icon, Color color, String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 11, color: pal.textSub),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSelectedRouteCard() {
    final route = _selectedRoute!;
    final diffColor = _getDifficultyColor(route.difficulty);

    return Container(
      padding: const EdgeInsets.fromLTRB(18, 6, 18, 14),
      decoration: BoxDecoration(
        color: pal.surface.withValues(alpha: 0.97),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 20),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // แถบดึง/แตะเพื่อย่อ-ขยายการ์ด (ค่าเริ่มต้นย่อ ไม่บังแผนที่)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _routeCardExpanded = !_routeCardExpanded),
            onVerticalDragEnd: (d) {
              final v = d.primaryVelocity ?? 0;
              if (v < -200 && !_routeCardExpanded) setState(() => _routeCardExpanded = true);
              if (v > 200 && _routeCardExpanded) setState(() => _routeCardExpanded = false);
            },
            child: SizedBox(
              width: double.infinity,
              height: 26,
              child: Center(
                child: Icon(
                  _routeCardExpanded ? Icons.keyboard_arrow_down_rounded : Icons.keyboard_arrow_up_rounded,
                  color: pal.textSub,
                  size: 26,
                ),
              ),
            ),
          ),
          // Route name + badges
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _isThai
                          ? (route.name.isNotEmpty ? route.name : route.nameEn)
                          : (route.nameEn.trim().isNotEmpty ? route.nameEn : route.name),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      // ระบุสีขาวเอง — เดิมไม่ระบุ ทำให้ธีมสว่างแสดงตัวอักษรสีเข้มบนการ์ดสีเข้ม (อ่านไม่ออก)
                      style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: pal.text),
                    ),
                    // (เดิมแสดงชื่ออีกภาษาเป็นบรรทัดรอง — ตัดออกให้แสดงภาษาเดียวตามโหมด)
                  ],
                ),
              ),
              // ❤️ Heart / Favorite button
              GestureDetector(
                onTap: () => _toggleFavorite(route.nameEn),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: _savedRouteIds.contains(route.nameEn)
                        ? const Color(0xFFE74C3C).withValues(alpha: 0.15)
                        : pal.surface2,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    _savedRouteIds.contains(route.nameEn)
                        ? Icons.favorite_rounded
                        : Icons.favorite_border_rounded,
                    color: _savedRouteIds.contains(route.nameEn)
                        ? const Color(0xFFE74C3C)
                        : pal.textMute,
                    size: 22,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: diffColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: diffColor.withValues(alpha: 0.4)),
                ),
                child: Text(_getDifficultyLabel(route.difficulty),
                    maxLines: 1,
                    style: TextStyle(color: diffColor, fontSize: 12, fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // Stats row — ใช้ Wrap แทน Row (เดิม RIGHT OVERFLOWED 8–10 px บนจอแคบ)
          Wrap(
            spacing: 16,
            runSpacing: 8,
            children: [
              _buildRouteStat(Icons.straighten, '${route.distanceKm.toStringAsFixed(1)} km'),
              _buildRouteStat(Icons.timer_outlined, route.estimatedTime),
              _buildRouteStat(Icons.terrain, '${route.elevationGainM} m'),
              _buildRouteStat(
                Icons.shield,
                '${route.safetyScore}',
                color: SafetyScoreEngine.scoreColor(route.safetyScore),
              ),
              // ตอนย่อการ์ด แสดง PM2.5 แบบย่อในแถวสถิติแทนแบนเนอร์
              if (!_routeCardExpanded && _routePm25 != null)
                _buildRouteStat(
                  Icons.blur_on,
                  'PM2.5 ${_routePm25!.toStringAsFixed(0)}',
                  color: _routePm25! > 75
                      ? const Color(0xFFE74C3C)
                      : _routePm25! > 35 ? const Color(0xFFF39C12) : const Color(0xFF2ECC71),
                ),
            ],
          ),
          const SizedBox(height: 12),

          if (_routeCardExpanded) ...[
          // Description
          Text(
            route.displayDescription,
            style: TextStyle(
              fontSize: 13,
              color: pal.textSub,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 14),

          // Waypoint chips
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: route.waypoints.map((wp) {
              return GestureDetector(
                onTap: () => _showWaypointInfo(wp),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: _getWaypointColor(wp.type).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: _getWaypointColor(wp.type).withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _getWaypointIcon(wp.type),
                        size: 14,
                        color: _getWaypointColor(wp.type),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        wp.displayName,
                        style: TextStyle(
                          fontSize: 11,
                          color: _getWaypointColor(wp.type),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 16),

          // PM2.5 Banner (Feature 7)
          if (_isLoadingPm25)
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: pal.surface2,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(children: [
                const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFFC4C02))),
                const SizedBox(width: 8),
                Text(_s.checkingAirQuality, style: TextStyle(color: pal.textSub, fontSize: 12)),
              ]),
            )
          else if (_routePm25 != null) Builder(builder: (context) {
            final pm25 = _routePm25!;
            final Color pm25Color = pm25 > 75
                ? const Color(0xFFE74C3C)
                : pm25 > 35 ? const Color(0xFFF39C12) : const Color(0xFF2ECC71);
            final String pm25Label = pm25 > 75 ? _s.dangerous : pm25 > 35 ? _s.wearMask : _s.safe;
            return Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: pm25Color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: pm25Color.withValues(alpha: 0.3)),
              ),
              child: Row(children: [
                Icon(Icons.blur_on, color: pm25Color, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('PM2.5: ${pm25.toStringAsFixed(0)} μg/m³ — $pm25Label',
                      style: TextStyle(color: pm25Color, fontSize: 13, fontWeight: FontWeight.w600)),
                ),
              ]),
            );
          }),
          ],

          // Start Run
          Container(
            width: double.infinity,
            height: 50,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFFFC4C02), Color(0xFFFF6B35)],
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
              ),
              borderRadius: BorderRadius.circular(18),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFFFC4C02).withValues(alpha: 0.5),
                  blurRadius: 20,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: () {
                  if (_selectedRoute != null) {
                    widget.onStartRun?.call(_fetchedPath != null
                        ? _selectedRoute!.copyWith(path: _fetchedPath)
                        : _selectedRoute!);
                  }
                },
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.directions_run_rounded, color: Colors.white, size: 26),
                    const SizedBox(width: 10),
                    Text(
                      _s.startRoutePrompt,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 17,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// ตัวคูณช่วงเวลา (1.0 = กลางวัน) → ข้อความที่ผู้ใช้อ่านเข้าใจ
  String _timeFactorLabel(dynamic raw) {
    final tf = num.tryParse('$raw')?.toDouble();
    if (tf == null) return '-';
    final cut = ((1 - tf) * 100).round();
    return cut <= 0 ? tr('ไม่ปรับลด', 'No reduction') : tr('ลด $cut%', '−$cut%');
  }

  Widget _buildRouteStat(IconData icon, String value, {Color? color}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color ?? const Color(0xFFFC4C02)),
        const SizedBox(width: 4),
        Text(
          value,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: color ?? pal.text,
          ),
        ),
      ],
    );
  }

  Widget _buildRouteListOverlay() {
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _showRouteList = false),
        child: Container(
          color: Colors.black54,
          child: Align(
            alignment: Alignment.bottomCenter,
            child: GestureDetector(
              onTap: () {},
              child: Container(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.75,
                ),
                decoration: BoxDecoration(
                  color: pal.bg,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Handle
                    Padding(
                      padding: const EdgeInsets.only(top: 12, bottom: 4),
                      child: Container(
                        width: 44,
                        height: 5,
                        decoration: BoxDecoration(
                          color: pal.border,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                    // Title
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFC4C02).withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Icon(Icons.shield_rounded, color: Color(0xFFFC4C02), size: 22),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _s.zonesInChiangMai,
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                                color: pal.text,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          GestureDetector(
                            onTap: () => setState(() => _showRouteList = false),
                            child: Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: pal.surface2,
                                shape: BoxShape.circle,
                              ),
                              child: Icon(Icons.close, color: pal.textSub, size: 18),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Divider(height: 1, color: pal.border),

                    // ─── FR8: Filter Bar ─────────────────────────────────────
                    Container(
                      color: pal.surface,
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Difficulty chips
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(children: [
                              _filterChip(_s.allLabel, _filterDifficulty == 'all',
                                  () => setState(() => _filterDifficulty = 'all'),
                                  pal.textSub),
                              const SizedBox(width: 8),
                              _filterChip('🟢 ${_s.easyDifficulty}', _filterDifficulty == 'easy',
                                  () => setState(() => _filterDifficulty = 'easy'),
                                  const Color(0xFF2ECC71)),
                              const SizedBox(width: 8),
                              _filterChip('🟡 ${_s.moderateDifficulty}', _filterDifficulty == 'moderate',
                                  () => setState(() => _filterDifficulty = 'moderate'),
                                  const Color(0xFFF39C12)),
                              const SizedBox(width: 8),
                              _filterChip('🔴 ${_s.hardDifficulty}', _filterDifficulty == 'hard',
                                  () => setState(() => _filterDifficulty = 'hard'),
                                  const Color(0xFFE74C3C)),
                              const SizedBox(width: 8),
                              // FR9: Sort by proximity toggle
                              GestureDetector(
                                onTap: () => setState(() => _sortByProximity = !_sortByProximity),
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 200),
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: _sortByProximity
                                        ? const Color(0xFF3498DB).withValues(alpha: 0.12)
                                        : pal.surface2,
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(
                                      color: _sortByProximity ? const Color(0xFF3498DB) : pal.border,
                                      width: _sortByProximity ? 1.5 : 1,
                                    ),
                                  ),
                                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                                    Icon(
                                      Icons.near_me_rounded,
                                      size: 13,
                                      color: _sortByProximity ? const Color(0xFF3498DB) : pal.textMute,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(_s.nearMe,
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: _sortByProximity ? FontWeight.w700 : FontWeight.w500,
                                          color: _sortByProximity ? const Color(0xFF3498DB) : pal.textSub,
                                        )),
                                  ]),
                                ),
                              ),
                              const SizedBox(width: 8),
                              // Fav toggle
                              GestureDetector(
                                onTap: () => setState(() => _filterFavOnly = !_filterFavOnly),
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 200),
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: _filterFavOnly
                                        ? const Color(0xFFE74C3C).withValues(alpha: 0.12)
                                        : pal.surface2,
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(
                                      color: _filterFavOnly
                                          ? const Color(0xFFE74C3C)
                                          : pal.border,
                                    ),
                                  ),
                                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                                    Icon(
                                      _filterFavOnly ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                                      size: 14,
                                      color: _filterFavOnly ? const Color(0xFFE74C3C) : pal.textMute,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(_s.favorite,
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                          color: _filterFavOnly ? const Color(0xFFE74C3C) : pal.textSub,
                                        )),
                                  ]),
                                ),
                              ),
                            ]),
                          ),
                          const SizedBox(height: 8),
                          // Distance slider
                          Row(children: [
                            Icon(Icons.straighten, size: 14, color: pal.textMute),
                            const SizedBox(width: 6),
                            Text('${_s.maxDistance} ≤ ${_filterMaxKm.round()} km',
                                style: TextStyle(fontSize: 12, color: pal.textSub, fontWeight: FontWeight.w600)),
                            Expanded(
                              child: SliderTheme(
                                data: SliderTheme.of(context).copyWith(
                                  trackHeight: 3,
                                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                                  activeTrackColor: const Color(0xFFFC4C02),
                                  inactiveTrackColor: pal.surface2,
                                  thumbColor: const Color(0xFFFC4C02),
                                ),
                                child: Slider(
                                  value: _filterMaxKm,
                                  min: 1,
                                  max: 30,
                                  divisions: 29,
                                  onChanged: (v) => setState(() => _filterMaxKm = v),
                                ),
                              ),
                            ),
                          ]),
                        ],
                      ),
                    ),
                    Divider(height: 1, color: pal.border),

                    // Route List (filtered)

                    Builder(builder: (context) {
                      // Apply filters
                      final filtered = ChiangMaiRoutes.routes.where((r) {
                        if (_filterDifficulty != 'all' && r.difficulty != _filterDifficulty) return false;
                        if (r.distanceKm > _filterMaxKm) return false;
                        if (_filterFavOnly && !_savedRouteIds.contains(r.nameEn)) return false;
                        return true;
                      }).toList();

                      // FR9: Sort by proximity to current GPS position
                      if (_sortByProximity && _isCurrentPosValid) {
                        filtered.sort((a, b) {
                          final dA = Geolocator.distanceBetween(
                            _currentPosition!.latitude, _currentPosition!.longitude,
                            a.path.first.latitude, a.path.first.longitude,
                          );
                          final dB = Geolocator.distanceBetween(
                            _currentPosition!.latitude, _currentPosition!.longitude,
                            b.path.first.latitude, b.path.first.longitude,
                          );
                          return dA.compareTo(dB);
                        });
                      }

                    if (_zones.isNotEmpty) {
                      final sortedZones = List<RunningZone>.from(_zones)
                        ..sort((a, b) {
                          final rA = a.recommendationScore ?? (a.safetyScore?.toDouble() ?? 0.0);
                          final rB = b.recommendationScore ?? (b.safetyScore?.toDouble() ?? 0.0);
                          return rB.compareTo(rA);
                        });
                      return Flexible(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_isDiscoveringZones)
                              Container(
                                margin: const EdgeInsets.fromLTRB(16, 6, 16, 8),
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF3498DB).withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: const Color(0xFF3498DB).withValues(alpha: 0.3)),
                                ),
                                child: Row(
                                  children: [
                                    const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF3498DB)),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        _s.searchingNearbyZones,
                                        style: const TextStyle(fontSize: 12, color: Color(0xFF2980B9), fontWeight: FontWeight.w600),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            Expanded(
                              child: ListView.builder(
                                shrinkWrap: true,
                                padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
                                itemCount: sortedZones.length,
                                itemBuilder: (context, index) {
                                  final zone = sortedZones[index];
                                  final score = zone.safetyScore;
                                  final zoneColor = score != null
                                      ? SafetyScoreEngine.scoreColor(score)
                                      : const Color(0xFF95A5A6);
                                  final level = score != null
                                      ? SafetyScoreEngine.getSafetyLevel(score)
                                      : null;
                                  final levelLabel = level == SafetyLevel.safe
                                      ? _s.safe
                                      : (level == SafetyLevel.caution ? _s.caution : _s.notRecommended);

                                  double? distM;
                                  if (_isCurrentPosValid) {
                                    distM = Geolocator.distanceBetween(
                                      _currentPosition!.latitude, _currentPosition!.longitude,
                                      zone.center.latitude, zone.center.longitude,
                                    );
                                  }
                                  final distText = distM != null
                                      ? (distM < 1000 ? '${distM.round()} m' : '${(distM / 1000).toStringAsFixed(1)} km')
                                      : null;

                                  final isTop5 = index < 5;

                                  return GestureDetector(
                                    onTap: () {
                                      setState(() => _showRouteList = false);
                                      _selectZone(zone);
                                    },
                                    child: Container(
                                      margin: const EdgeInsets.only(bottom: 12),
                                      decoration: BoxDecoration(
                                        color: pal.surface,
                                        borderRadius: BorderRadius.circular(18),
                                        border: Border(
                                          left: BorderSide(color: zoneColor, width: isTop5 ? 6 : 4),
                                        ),
                                        boxShadow: [
                                          BoxShadow(
                                            color: Colors.black.withValues(alpha: isTop5 ? 0.08 : 0.04),
                                            blurRadius: 10,
                                            offset: const Offset(0, 3),
                                          ),
                                        ],
                                      ),
                                      child: Padding(
                                        padding: const EdgeInsets.all(16),
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Container(
                                                  width: 48,
                                                  height: 48,
                                                  decoration: BoxDecoration(
                                                    color: zoneColor.withValues(alpha: 0.12),
                                                    borderRadius: BorderRadius.circular(14),
                                                  ),
                                                  child: Icon(
                                                    zone.category == 'moat'
                                                        ? Icons.water_rounded
                                                        : (zone.category == 'park'
                                                            ? Icons.park_rounded
                                                            : (zone.category == 'stadium'
                                                                ? Icons.stadium_rounded
                                                                : (zone.category == 'campus'
                                                                    ? Icons.school_rounded
                                                                    : Icons.shield_rounded))),
                                                    color: zoneColor,
                                                    size: 26,
                                                  ),
                                                ),
                                                const SizedBox(width: 14),
                                                Expanded(
                                                  child: Column(
                                                    crossAxisAlignment: CrossAxisAlignment.start,
                                                    children: [
                                                      Row(
                                                        children: [
                                                          if (isTop5) ...[
                                                            Container(
                                                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                                              margin: const EdgeInsets.only(right: 6),
                                                              decoration: BoxDecoration(
                                                                color: const Color(0xFFFC4C02).withValues(alpha: 0.12),
                                                                borderRadius: BorderRadius.circular(6),
                                                                border: Border.all(color: const Color(0xFFFC4C02).withValues(alpha: 0.4)),
                                                              ),
                                                              child: Text(
                                                                '#${index + 1}',
                                                                style: const TextStyle(
                                                                  fontSize: 10,
                                                                  fontWeight: FontWeight.w800,
                                                                  color: Color(0xFFFC4C02),
                                                                ),
                                                              ),
                                                            ),
                                                          ],
                                                          Expanded(
                                                            child: Text(
                                                              zone.displayName,
                                                              style: TextStyle(
                                                                fontWeight: FontWeight.w800,
                                                                fontSize: 16,
                                                                color: pal.text,
                                                              ),
                                                              maxLines: 1,
                                                              overflow: TextOverflow.ellipsis,
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                      const SizedBox(height: 4),
                                                      Wrap(
                                                        spacing: 8,
                                                        runSpacing: 4,
                                                        children: [
                                                          _infoChip(Icons.straighten, '${zone.walkableLengthKm.toStringAsFixed(1)} km', pal.textSub),
                                                          if (distText != null)
                                                            _infoChip(Icons.near_me_rounded, _isThai ? 'ห่าง $distText' : '$distText away', const Color(0xFF3498DB)),
                                                          _infoChip(Icons.category_outlined, _zoneCategoryLabel(zone.category), pal.textSub),
                                                        ],
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                                const SizedBox(width: 8),
                                                Container(
                                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                                  decoration: BoxDecoration(
                                                    color: zoneColor.withValues(alpha: 0.12),
                                                    borderRadius: BorderRadius.circular(12),
                                                    border: Border.all(color: zoneColor.withValues(alpha: 0.5)),
                                                  ),
                                                  child: Column(
                                                    mainAxisSize: MainAxisSize.min,
                                                    children: [
                                                      Text(
                                                        score != null ? '$score' : '…',
                                                        style: TextStyle(
                                                          fontSize: 16,
                                                          fontWeight: FontWeight.w800,
                                                          color: zoneColor,
                                                        ),
                                                      ),
                                                      if (score != null)
                                                        Text(
                                                          levelLabel,
                                                          style: TextStyle(
                                                            fontSize: 10,
                                                            fontWeight: FontWeight.w600,
                                                            color: zoneColor,
                                                          ),
                                                        ),
                                                    ],
                                                  ),
                                                ),
                                              ],
                                            ),

                                            // ── เหตุผลแนะนำ (2-3 ข้อ) ──
                                            if (zone.recommendationReasons.isNotEmpty) ...[
                                              const SizedBox(height: 10),
                                              Wrap(
                                                spacing: 6,
                                                runSpacing: 4,
                                                children: zone.recommendationReasons.map((reason) {
                                                  return Container(
                                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                                    decoration: BoxDecoration(
                                                      color: pal.surface2,
                                                      borderRadius: BorderRadius.circular(8),
                                                      border: Border.all(color: pal.border),
                                                    ),
                                                    child: Text(
                                                      reason,
                                                      style: TextStyle(
                                                        fontSize: 11,
                                                        color: pal.text,
                                                        fontWeight: FontWeight.w500,
                                                      ),
                                                    ),
                                                  );
                                                }).toList(),
                                              ),
                                            ],
                                          ],
                                        ),
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

                    return Flexible(
                      child: filtered.isEmpty
                          ? Padding(
                              padding: const EdgeInsets.symmetric(vertical: 40),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.search_off_rounded, size: 48, color: pal.border),
                                  const SizedBox(height: 12),
                                  Text(_s.noRoutesMatched,
                                      style: TextStyle(fontSize: 14, color: pal.textMute)),
                                  const SizedBox(height: 6),
                                  TextButton(
                                    onPressed: () => setState(() {
                                      _filterDifficulty = 'all';
                                      _filterMaxKm = 30;
                                      _filterFavOnly = false;
                                    }),
                                    child: Text(_s.clearFilters, style: const TextStyle(color: Color(0xFFFC4C02))),
                                  ),
                                ],
                              ),
                            )
                          : ListView.builder(
                              shrinkWrap: true,
                              padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                              itemCount: filtered.length,
                              itemBuilder: (context, index) {
                              final route = filtered[index];

                          final diffColor = _getDifficultyColor(route.difficulty);
                          final diffLabel = _getDifficultyLabel(route.difficulty);

                          // FR9: คำนวณระยะห่างจากผู้ใช้ถึงจุดเริ่มเส้นทาง
                          double? distFromUserM;
                          if (_isCurrentPosValid && route.path.isNotEmpty) {
                            distFromUserM = Geolocator.distanceBetween(
                              _currentPosition!.latitude, _currentPosition!.longitude,
                              route.path.first.latitude, route.path.first.longitude,
                            );
                          }
                          final distLabel = distFromUserM != null
                              ? distFromUserM < 1000
                                  ? '${distFromUserM.round()} m'
                                  : '${(distFromUserM / 1000).toStringAsFixed(1)} km'
                              : null;
                          final isNearby = distFromUserM != null && distFromUserM < 2000;

                          return GestureDetector(
                            onTap: () => _selectRoute(route),
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 12),
                              decoration: BoxDecoration(
                                color: pal.surface,
                                borderRadius: BorderRadius.circular(18),
                                border: Border(
                                  left: BorderSide(color: diffColor, width: 5),
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.07),
                                    blurRadius: 10,
                                    offset: const Offset(0, 3),
                                  ),
                                ],
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Row(
                                  children: [
                                    // Icon
                                    Container(
                                      width: 54,
                                      height: 54,
                                      decoration: BoxDecoration(
                                        color: diffColor.withValues(alpha: 0.12),
                                        borderRadius: BorderRadius.circular(14),
                                      ),
                                      child: Icon(Icons.route_rounded, color: diffColor, size: 28),
                                    ),
                                    const SizedBox(width: 14),
                                    // Info
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          // Route name + nearby badge
                                          Row(
                                            children: [
                                              Expanded(
                                                child: Text(
                                                  _isThai
                                                      ? (route.name.isNotEmpty ? route.name : route.nameEn)
                                                      : (route.nameEn.trim().isNotEmpty ? route.nameEn : route.name),
                                                  style: TextStyle(
                                                    fontWeight: FontWeight.w800,
                                                    fontSize: 16,
                                                    color: pal.text,
                                                  ),
                                                ),
                                              ),
                                              if (isNearby) ...[
                                                const SizedBox(width: 6),
                                                Container(
                                                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                                                  decoration: BoxDecoration(
                                                    color: const Color(0xFF3498DB).withValues(alpha: 0.12),
                                                    borderRadius: BorderRadius.circular(10),
                                                    border: Border.all(color: const Color(0xFF3498DB).withValues(alpha: 0.4)),
                                                  ),
                                                  child: Text(_s.nearYou,
                                                      style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Color(0xFF3498DB))),
                                                ),
                                              ],
                                            ],
                                          ),
                                          const SizedBox(height: 6),
                                          Wrap(
                                            spacing: 8,
                                            runSpacing: 4,
                                            children: [
                                              _infoChip(Icons.straighten, '${route.distanceKm.toStringAsFixed(1)} km', pal.textSub),
                                              _infoChip(Icons.timer_outlined, route.estimatedTime, pal.textSub),
                                              _infoChip(Icons.terrain, '${route.elevationGainM}m', pal.textSub),
                                              if (distLabel != null)
                                                _infoChip(Icons.near_me_rounded, _isThai ? 'ห่าง $distLabel' : '$distLabel away', const Color(0xFF3498DB)),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                     // Difficulty + Safety + Favorite
                                    Column(
                                      crossAxisAlignment: CrossAxisAlignment.end,
                                      children: [
                                        Row(
                                          children: [
                                            GestureDetector(
                                              onTap: () => _toggleFavorite(route.nameEn),
                                              child: Icon(
                                                _savedRouteIds.contains(route.nameEn)
                                                    ? Icons.favorite_rounded
                                                    : Icons.favorite_border_rounded,
                                                color: _savedRouteIds.contains(route.nameEn)
                                                    ? const Color(0xFFE74C3C)
                                                    : pal.textMute,
                                                size: 20,
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                              decoration: BoxDecoration(
                                                color: diffColor,
                                                borderRadius: BorderRadius.circular(20),
                                              ),
                                              child: Text(diffLabel,
                                                  style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w800)),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 6),
                                        Row(
                                          children: [
                                            Icon(Icons.shield_rounded, size: 15,
                                              color: SafetyScoreEngine.scoreColor(route.safetyScore)),
                                            const SizedBox(width: 3),
                                            Text('${route.safetyScore}',
                                              style: TextStyle(
                                                fontSize: 13,
                                                fontWeight: FontWeight.w700,
                                                color: SafetyScoreEngine.scoreColor(route.safetyScore),
                                              )),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                              },
                            ),
                    );
                    }), // end Builder
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _filterChip(String label, bool selected, VoidCallback onTap, Color color) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.12) : pal.surface2,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? color : pal.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? color : pal.textSub,
          ),
        ),
      ),
    );
  }

  Widget _infoChip(IconData icon, String label, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 3),
        Text(label, style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600)),
      ],
    );
  }
}

// ─── Elevation Chart Painter ────────────────────────────────────────────────
class _ElevationChartPainter extends CustomPainter {
  final List<double> elevations;
  final double minElev;
  final double range;

  const _ElevationChartPainter({
    required this.elevations,
    required this.minElev,
    required this.range,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (elevations.length < 2) return;

    final fillPaint = Paint()
      ..shader = ui.Gradient.linear(
        Offset(0, 0),
        Offset(0, size.height),
        [
          const Color(0xFF3498DB).withValues(alpha: 0.55),
          const Color(0xFF3498DB).withValues(alpha: 0.04),
        ],
      )
      ..style = PaintingStyle.fill;

    final linePaint = Paint()
      ..color = const Color(0xFF3498DB)
      ..strokeWidth = 1.8
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;

    final n = elevations.length;
    double xAt(int i) => i / (n - 1) * size.width;
    double yAt(double elev) =>
        size.height - ((elev - minElev) / range * size.height * 0.88) - 2;

    // Use ui.Path explicitly to avoid conflict with flutter_map's Path
    final linePath = ui.Path();
    final fillPath = ui.Path();

    fillPath.moveTo(xAt(0), size.height);
    fillPath.lineTo(xAt(0), yAt(elevations[0]));
    linePath.moveTo(xAt(0), yAt(elevations[0]));

    for (int i = 1; i < n; i++) {
      final prevX = xAt(i - 1);
      final currX = xAt(i);
      final prevY = yAt(elevations[i - 1]);
      final currY = yAt(elevations[i]);
      final cpX = (prevX + currX) / 2;

      linePath.cubicTo(cpX, prevY, cpX, currY, currX, currY);
      fillPath.cubicTo(cpX, prevY, cpX, currY, currX, currY);
    }

    fillPath.lineTo(xAt(n - 1), size.height);
    fillPath.close();

    canvas.drawPath(fillPath, fillPaint);
    canvas.drawPath(linePath, linePaint);
  }

  @override
  bool shouldRepaint(_ElevationChartPainter old) =>
      old.elevations != elevations;
}
