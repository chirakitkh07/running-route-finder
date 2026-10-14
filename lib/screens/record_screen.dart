import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:math' as math;
import 'package:geolocator/geolocator.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import '../models/activity.dart';
import '../models/last_run_summary.dart';
import '../models/route_data.dart';
import '../models/running_zone.dart';
import '../services/firestore_service.dart';
import '../services/safety_service.dart';
import '../services/emergency_contact_service.dart';
import '../services/location_helper.dart';
import '../services/off_route_monitor.dart';
import '../services/push_service.dart';
import '../providers/language_provider.dart';
import '../l10n/app_strings.dart';
import '../l10n/tr.dart';
import 'package:demo20426/providers/theme_provider.dart';

class RecordScreen extends StatefulWidget {
  final RunningRoute? selectedRoute;
  final RunningZone? selectedZone;
  final bool autoStart;
  final VoidCallback? onCancel;
  /// เรียกหลังจากบันทึกการวิ่งเสร็จ — ส่งข้อมูลสรุปไปยัง HomeScreen
  final void Function(LastRunSummary)? onRunFinished;
  const RecordScreen({
    super.key,
    this.selectedRoute,
    this.selectedZone,
    this.autoStart = false,
    this.onCancel,
    this.onRunFinished,
  });

  @override
  State<RecordScreen> createState() => _RecordScreenState();
}

class _RecordScreenState extends State<RecordScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  bool get _isThai {
    try {
      return context.read<LanguageProvider>().isThai;
    } catch (_) {
      return true;
    }
  }

  AppStrings get _s => AppStrings(isThai: _isThai);

  // ─── State ───────────────────────────────────────────────
  bool _isRunning = false;
  bool _isPaused = false;
  bool _isSaving = false;
  String _activityType = 'running'; // 'running' | 'cycling'


  // Timer — wall-clock based (ทำงานถูกต้องแม้ app ไป background)
  int _seconds = 0;
  Timer? _timer;
  Duration _pausedDuration = Duration.zero; // เวลาที่สะสมจาก pause
  DateTime? _pauseStartedAt;               // เริ่ม pause ล่าสุดเมื่อไร

  // GPS
  StreamSubscription<Position>? _positionSub;
  double _distanceKm = 0;
  double _totalElevationGain = 0;

  // ─── Pace (แยกเป็น 2 ค่าชัดเจน) ────────────────────────
  /// Current Pace: สะท้อนความเร็วช่วงปัจจุบัน (Sliding Window จาก GPS ล่าสุด)
  double _currentPaceSecPerKm = 0;
  /// Average Pace: เฉลี่ยจาก totalTime / totalDistance ล้วนๆ
  double _avgPaceSecPerKm = 0;
  /// Sliding window ของ instant pace 5 segment ล่าสุด (ลด noise)
  final List<double> _paceWindow = [];
  static const int _paceWindowSize = 5;

  Position? _lastPosition;
  /// ตำแหน่ง GPS ล่าสุดสำหรับแสดงจุดบนแผนที่/ระดับสัญญาณ (ไม่ถูก reset ตอนเริ่ม/หยุด/พัก)
  Position? _gpsFix;
  /// GPS แบบประหยัดสำหรับแสดงจุดตำแหน่งก่อนเริ่มวิ่ง
  StreamSubscription<Position>? _previewSub;
  double? _lastAltitude;
  DateTime? _startedAt;
  // เส้นทาง GPS ทั้งหมด
  final List<LatLng> _routePoints = [];

  // แผนที่ระหว่างวิ่ง
  final MapController _mapController = MapController();
  bool _liveMapReady = false;
  bool _followUser = true;

  // Animation
  late AnimationController _pulseController;

  // Services
  final FirestoreService _firestoreService = FirestoreService();

  // ─── Countdown & Waypoints ───────────────────────────────
  int _countdown = 0;
  Timer? _countdownTimer;
  final Set<String> _notifiedWaypoints = {};

  // ─── Safety & SOS ────────────────────────────────────
  String _emergencyName = '';
  String _emergencyPhone = '';
  DateTime? _lastMovedAt;
  Timer? _noMovementTimer;
  bool _showNoMovementAlert = false;

  // ─── Active Route & Zone (dismissable) ──────────────────────
  RunningRoute? _activeRoute;
  RunningZone? _activeZone;

  // ─── แจ้งเตือนออกนอกเส้นทาง (เส้นทางยอดนิยม / วางแผนเส้นทาง / วงรอบในโซน) ──
  OffRouteMonitor? _offRoute;
  bool _offRouteMuted = false;
  static const String _offRouteTag = 'off_route';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this); // รับ lifecycle events
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _activeRoute = widget.selectedRoute; // copy เพื่อให้ dismiss ได้
    _activeZone = widget.selectedZone;
    if (widget.autoStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _startCountdown());
    }
    _loadEmergencyContact();
    // ขอสิทธิ์ GPS ทันทีที่เข้าหน้าจอ (หากยังไม่เคยขอ) เพื่อให้พร้อมเริ่มวิ่ง
    WidgetsBinding.instance.addPostFrameCallback((_) => _initGps());
  }

  /// ตรวจสอบและขอสิทธิ์ GPS ทันทีที่เปิดหน้าจอ เพื่อเตรียมพร้อมก่อนเริ่มวิ่ง
  Future<void> _initGps() async {
    final hasPerm = await LocationHelper.checkAndRequestPermission(
      context: context,
      showDialogs: false,
    );
    if (hasPerm && mounted) {
      try {
        final pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium),
        ).timeout(const Duration(seconds: 4));
        if (mounted) {
          setState(() {
            _lastPosition = pos;
            _gpsFix = pos;
          });
          if (!_isRunning) _fitPlannedRoute();
        }
      } catch (_) {}
      _startPreviewGps();
    }
  }

  /// ติดตามตำแหน่งก่อนเริ่มวิ่ง เพื่อแสดงจุดตำแหน่งปัจจุบันและระดับสัญญาณ GPS
  Future<void> _startPreviewGps() async {
    if (_previewSub != null || _isRunning || !mounted) return;
    try {
      if (_gpsFix == null) {
        final last = await Geolocator.getLastKnownPosition();
        if (last != null && mounted && _gpsFix == null) {
          setState(() => _gpsFix = last);
          if (!_isRunning) _fitPlannedRoute();
        }
      }
      if (_previewSub != null || _isRunning || !mounted) return;
      bool first = true;
      _previewSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 2,
        ),
      ).listen((pos) {
        if (!mounted || _isRunning) return;
        setState(() => _gpsFix = pos);
        if (first) {
          first = false;
          _fitPlannedRoute();
        } else if (_plannedPath.isEmpty) {
          _followCamera(pos); // มีเส้นทางวางแผน → คงมุมมองทั้งเส้นไว้จนกว่าจะเริ่มวิ่ง
        }
      }, onError: (_) {});
    } catch (_) {}
  }

  void _stopPreviewGps() {
    _previewSub?.cancel();
    _previewSub = null;
  }

  // เมื่อ app กลับมา foreground — คำนวณเวลาที่หายไปใน background
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // ยังไม่ได้วิ่ง: ปิด GPS แสดงตำแหน่งเมื่อแอปไปอยู่เบื้องหลัง เพื่อประหยัดแบต
    if (!_isRunning) {
      if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
        _stopPreviewGps();
      } else if (state == AppLifecycleState.resumed) {
        _startPreviewGps();
      }
      return;
    }
    if (_isPaused) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      // บันทึกเวลาที่ app ออกไป background
      _pauseStartedAt = DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      // กลับมา — คำนวณช่วงเวลาที่อยู่ background แล้วหัก
      if (_pauseStartedAt != null) {
        // ไม่ต้องทำอะไร เพราะ _startTimer() คำนวณจาก DateTime.now() - _startedAt - _pausedDuration อยู่แล้ว
        _pauseStartedAt = null;
      }
      // อัปเดต UI ทันที
      if (mounted) {
        setState(() {
          if (_startedAt != null) {
            _seconds = (DateTime.now().difference(_startedAt!) - _pausedDuration)
                .inSeconds
                .clamp(0, 99 * 3600);
          }
        });
      }
    }
  }

  Future<void> _loadEmergencyContact() async {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isEmpty) return;
    final c = await EmergencyContactService.load(uid: uid);
    if (c != null && mounted) {
      setState(() { _emergencyName = c.name; _emergencyPhone = c.phone; });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _positionSub?.cancel();
    _pulseController.dispose();
    _countdownTimer?.cancel();
    _noMovementTimer?.cancel();
    _previewSub?.cancel();
    _mapController.dispose();
    if (_offRoute != null) PushService.cancelSystemNotification(_offRouteTag);
    super.dispose();
  }

  // ─── Countdown ───────────────────────────────────────────
  void _startCountdown() {
    if (!mounted) return;
    setState(() => _countdown = 3);
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) { t.cancel(); return; }
      if (_countdown > 1) {
        setState(() => _countdown--);
      } else {
        t.cancel();
        setState(() => _countdown = 0);
        _startRun();
      }
    });
  }

  // ─── GPS Permission ──────────────────────────────────────

  Future<bool> _requestLocationPermission() async {
    return await LocationHelper.checkAndRequestPermission(
      context: context,
      showDialogs: true,
    );
  }

  // ─── Run Controls ────────────────────────────────────────

  Future<void> _startRun() async {
    final hasPermission = await _requestLocationPermission();
    if (!hasPermission) return;

    _startedAt = DateTime.now();
    _pausedDuration = Duration.zero;
    _pauseStartedAt = null;
    setState(() {
      _isRunning = true;
      _isPaused = false;
      _distanceKm = 0;
      _totalElevationGain = 0;
      _avgPaceSecPerKm = 0;
      _currentPaceSecPerKm = 0;
      _paceWindow.clear();
      _seconds = 0;
      _lastPosition = null;
      _lastAltitude = null;
      _routePoints.clear();
      _offRouteMuted = false;
      final planned = _plannedPath;
      _offRoute = planned.length >= 2 ? OffRouteMonitor(planned) : null;
    });

    _stopPreviewGps();
    _startTimer();
    _startLocationTracking();
    _startNoMovementTimer();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        // คำนวณเวลาจาก wall-clock จริง — ไม่หายแม้ app ไป background
        if (_startedAt != null) {
          _seconds = (DateTime.now().difference(_startedAt!) - _pausedDuration)
              .inSeconds
              .clamp(0, 99 * 3600);
        }
        // ─── Average Pace: คำนวณตรงๆ จาก totalTime / totalDistance ────
        if (_distanceKm > 0.01 && _seconds > 0) {
          _avgPaceSecPerKm = _seconds / _distanceKm;
        }
        // ─── Current Pace Decay ──────────────────────────────────────────
        // ถ้า GPS ไม่ส่งค่าใหม่มานาน (> 3 วินาที) → ลบ element เก่าออก
        // ทำให้ pace ค่อยๆ ลดลงแทนที่จะค้างค่าเดิม
        final gpsStale = _lastMovedAt != null &&
            DateTime.now().difference(_lastMovedAt!).inSeconds > 3;
        if (gpsStale && _paceWindow.isNotEmpty) {
          _paceWindow.removeAt(0);
          if (_paceWindow.isEmpty) _currentPaceSecPerKm = 0;
        }
      });
    });
  }


  void _startLocationTracking() {
    late final LocationSettings settings;
    if (defaultTargetPlatform == TargetPlatform.android) {
      settings = AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation, // เพิ่มจาก high → bestForNavigation
        distanceFilter: 0,
        forceLocationManager: false,
        // intervalDuration: บังคับให้ OS ส่ง GPS ทุก 1 วินาทีเสมอ
        // (ป้องกัน Doze Mode batching บน Android 6+)
        intervalDuration: const Duration(seconds: 1),
        foregroundNotificationConfig: ForegroundNotificationConfig(
          notificationText: _activityType == 'cycling'
              ? (_isThai ? 'กำลังบันทึกการปั่นและคำนวณความเร็วแบบเรียลไทม์...' : 'Tracking ride in real-time...')
              : (_isThai ? 'กำลังบันทึกการวิ่งและคำนวณ Pace แบบเรียลไทม์...' : 'Tracking run in real-time...'),
          notificationTitle: _isThai ? '🏃‍♂️ กำลังบันทึกกิจกรรมในพื้นหลัง' : '🏃‍♂️ Tracking in background',
          enableWakeLock: true,   // ป้องกัน CPU sleep ระหว่างวิ่ง
          setOngoing: true,        // notification ลบไม่ได้ (ค้างตลอด session)
        ),
      );
    } else if (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS) {
      settings = AppleSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
        activityType: ActivityType.fitness,
        pauseLocationUpdatesAutomatically: false,
        showBackgroundLocationIndicator: true,
        allowBackgroundLocationUpdates: true,
      );
    } else {
      settings = const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
      );
    }

    _positionSub = Geolocator.getPositionStream(locationSettings: settings)
        .listen(
          (Position pos) {
            // อัปเดตจุดตำแหน่ง/ระดับสัญญาณเสมอ (แม้พักหรือความแม่นยำต่ำ)
            if (mounted) setState(() => _gpsFix = pos);
            _followCamera(pos);
            if (_isPaused) return; // GPS ยังรับอยู่แม้ app ใน background แต่ไม่บันทึกตอน pause

            // ─── GPS Accuracy Filter ───────────────────────────────────────────
            // ถ้า accuracy แย่กว่า 40m → skip เพื่อไม่ให้ noise เข้ามาบิด pace
            if (pos.accuracy > 40.0) return;

            // ─── คำนวณ Instant Pace (Current Pace) จาก GPS ────────────────────
            double? instantPaceSecPerKm;

            // วิธีที่ 1: ใช้ speed จาก GPS (m/s) → แม่นยำมากถ้ามีค่า
            // speed > 0.3 m/s (~1 km/h) คือ valid; ไม่ใช่ noise จากยืนนิ่ง
            // speedAccuracy < 5.0 (ผ่อนจาก 3.0) — GPS ส่วนใหญ่มี speedAccuracy ~2-4 m/s
            // บน Android รุ่นเก่า speedAccuracy อาจเป็น 0.0 (ไม่รู้ = ถือว่าดี)
            final speedAccOk = pos.speedAccuracy <= 0.0 || pos.speedAccuracy < 5.0;
            if (pos.speed > 0.3 && speedAccOk) {
              final pace = 1000.0 / pos.speed; // sec/km
              if (pace >= 60 && pace <= 1800) {
                instantPaceSecPerKm = pace;
              }
            }

            // วิธีที่ 2: คำนวณจาก segment distance / segment time
            // ใช้เป็น fallback เมื่อ speed ไม่มีหรือไม่น่าเชื่อถือ
            if (instantPaceSecPerKm == null && _lastPosition != null) {
              final segmentM = Geolocator.distanceBetween(
                _lastPosition!.latitude, _lastPosition!.longitude,
                pos.latitude, pos.longitude,
              );
              // คำนวณ segment time จาก timestamp ของ GPS position
              final segmentSec = pos.timestamp
                  .difference(_lastPosition!.timestamp)
                  .inMilliseconds / 1000.0;

              if (segmentM > 1.0 && segmentSec > 0.5 && segmentM < 50) {
                final pace = (segmentSec / segmentM) * 1000.0; // sec/km
                if (pace >= 60 && pace <= 1800) {
                  instantPaceSecPerKm = pace;
                }
              }
            }

            // ─── Sliding Window สำหรับ Current Pace ────────────────────────────
            // เก็บ 5 instant pace ล่าสุดแล้วเฉลี่ย → smooth โดยไม่ delay มาก
            if (instantPaceSecPerKm != null) {
              _paceWindow.add(instantPaceSecPerKm);
              if (_paceWindow.length > _paceWindowSize) {
                _paceWindow.removeAt(0); // เอา element เก่าออก
              }
            }

            // ─── อัปเดต State ─────────────────────────────────────────────────
            setState(() {
              // คำนวณ Current Pace จาก sliding window
              if (_paceWindow.isNotEmpty) {
                final windowAvg =
                    _paceWindow.reduce((a, b) => a + b) / _paceWindow.length;
                _currentPaceSecPerKm = windowAvg;
              } else if (!_isRunning || _isPaused) {
                _currentPaceSecPerKm = 0;
              }
              // หมายเหตุ: _avgPaceSecPerKm ถูกคำนวณใน _startTimer() จาก totalTime/totalDist

              // ─── คำนวณระยะทาง (กรอง GPS noise) ──────────────────────────────
              if (_lastPosition != null) {
                final segmentM = Geolocator.distanceBetween(
                  _lastPosition!.latitude, _lastPosition!.longitude,
                  pos.latitude, pos.longitude,
                );
                // กรอง: ต้องเดิน > 1m แต่ < 50m ต่อ update (ป้องกัน GPS กระโดด)
                if (segmentM > 1.0 && segmentM < 50.0) {
                  _distanceKm += segmentM / 1000.0;
                }
                // คำนวณ elevation gain (ขาขึ้นเท่านั้น)
                if (_lastAltitude != null && pos.altitude > _lastAltitude!) {
                  _totalElevationGain += pos.altitude - _lastAltitude!;
                }
              }

              _lastPosition = pos;
              _lastAltitude = pos.altitude;
              // เก็บ GPS point สำหรับเส้นทาง
              _routePoints.add(LatLng(pos.latitude, pos.longitude));
            });

            // ─── No-movement detection ──────────────────
            _lastMovedAt = DateTime.now();
            if (_showNoMovementAlert) setState(() => _showNoMovementAlert = false);
            // ─── Waypoint proximity check ───────────────
            if (widget.selectedRoute != null) {
              for (final wp in widget.selectedRoute!.waypoints) {
                final d = Geolocator.distanceBetween(
                  pos.latitude, pos.longitude,
                  wp.position.latitude, wp.position.longitude,
                );
                if (d < 100 && !_notifiedWaypoints.contains(wp.name)) {
                  _notifiedWaypoints.add(wp.name);
                  _showWaypointNotification(wp);
                }
              }
            }
            // ─── Off-route check ────────────────────────
            _checkOffRoute(pos);
          },
          onError: (_) {
            // GPS error — ยังวิ่งต่อได้
          },
        );
  }

  void _pauseRun() {
    _timer?.cancel();
    _timer = null;
    // ไม่ cancel _positionSub ตอน pause —
    // GPS stream และ foreground notification ต้องทำงานต่อเนื่อง
    // เพื่อรักษา background location privilege บน Android
    // การบล็อกการบันทึก segment ใช้ flag _isPaused ใน listener แทน
    _noMovementTimer?.cancel();
    _pauseStartedAt = DateTime.now();
    setState(() {
      _isPaused = true;
      _currentPaceSecPerKm = 0;
      _paceWindow.clear();
    });
  }

  void _resumeRun() {
    if (_pauseStartedAt != null) {
      _pausedDuration += DateTime.now().difference(_pauseStartedAt!);
      _pauseStartedAt = null;
    }
    _timer?.cancel();
    _timer = null;
    setState(() {
      _isPaused = false;
      _lastPosition = null; // reset lastPosition เพื่อไม่ให้คำนวณ segment ข้ามช่วง pause
    });
    _offRoute?.resetStreak();
    _startTimer();
    // GPS stream ยังรันอยู่แล้ว — ไม่ต้อง _startLocationTracking() ใหม่
    // (เริ่มใหม่เฉพาะกรณีที่ stream ถูก cancel ไปก่อนหน้า)
    if (_positionSub == null) _startLocationTracking();
    _startNoMovementTimer();
  }


  Future<void> _stopRun() async {
    _timer?.cancel();
    _noMovementTimer?.cancel();
    await _positionSub?.cancel();
    _positionSub = null;
    _startPreviewGps();

    final secs = _seconds;
    final distKm = _distanceKm;
    final elev = _totalElevationGain.round();
    // ใช้ Average Pace จริงสำหรับ summary (totalTime / totalDist)
    final pace = (distKm > 0.01 && secs > 0) ? secs / distKm : _avgPaceSecPerKm;
    final started = _startedAt ?? DateTime.now();
    final savedRoute = List<LatLng>.from(_routePoints); // snapshot ก่อน clear

    setState(() {
      _isRunning = false;
      _isPaused = false;
      _seconds = 0;
      _distanceKm = 0;
      _totalElevationGain = 0;
      _avgPaceSecPerKm = 0;
      _currentPaceSecPerKm = 0;
      _paceWindow.clear();
      _lastPosition = null;
      _routePoints.clear();
      if (_offRoute != null) PushService.cancelSystemNotification(_offRouteTag);
      _offRoute = null;
    });

    if (secs < 10) return; // ไม่บันทึกถ้าวิ่งน้อยกว่า 10 วินาที

    if (mounted) {
      await _showSummaryDialog(
        seconds: secs,
        distanceKm: distKm,
        elevationM: elev,
        paceSecPerKm: pace,
        startedAt: started,
        routePoints: savedRoute,
      );
    }
  }

  // ─── Off-route alerts ────────────────────────────────────

  void _checkOffRoute(Position pos) {
    final m = _offRoute;
    if (m == null || _activeRoute == null || !_isRunning || _isPaused) return;
    final ev = m.update(LatLng(pos.latitude, pos.longitude), accuracyM: pos.accuracy);
    switch (ev) {
      case OffRouteEvent.joined:
        HapticFeedback.mediumImpact();
        _showSnack(tr('เข้าสู่เส้นทางแล้ว — ระบบจะเตือนเมื่อคุณออกนอกเส้นทาง',
            'You are on the route — you will be alerted if you go off it'));
        break;
      case OffRouteEvent.wentOff:
      case OffRouteEvent.stillOff:
        if (!_offRouteMuted) _alertOffRoute(pos, repeat: ev == OffRouteEvent.stillOff);
        break;
      case OffRouteEvent.backOn:
        HapticFeedback.mediumImpact();
        PushService.cancelSystemNotification(_offRouteTag);
        _showSnack(tr('✅ กลับเข้าเส้นทางแล้ว', '✅ Back on route'));
        break;
      case OffRouteEvent.none:
        break;
    }
    if (ev != OffRouteEvent.none && mounted) setState(() {});
  }

  /// ข้อความบอกทางกลับเข้าเส้นทาง เช่น "ทางขวา (ทิศตะวันออก)"
  String _wayBackText(Position? pos) {
    final m = _offRoute;
    final target = m?.nearestPoint;
    if (pos == null || target == null) return '';
    final brg = OffRouteMonitor.bearing(LatLng(pos.latitude, pos.longitude), target);
    const th = ['เหนือ', 'ตะวันออกเฉียงเหนือ', 'ตะวันออก', 'ตะวันออกเฉียงใต้',
        'ใต้', 'ตะวันตกเฉียงใต้', 'ตะวันตก', 'ตะวันตกเฉียงเหนือ'];
    const en = ['north', 'north-east', 'east', 'south-east',
        'south', 'south-west', 'west', 'north-west'];
    final i = ((brg + 22.5) % 360 ~/ 45).toInt();
    final compass = tr('ทิศ${th[i]}', en[i]);
    // มีทิศการเคลื่อนที่ (กำลังวิ่ง) → บอกซ้าย/ขวาเทียบกับทิศที่วิ่งอยู่
    if (pos.speed > 1.0 && pos.heading.isFinite && pos.heading >= 0) {
      final diff = ((brg - pos.heading + 540) % 360) - 180;
      final String rel;
      if (diff.abs() <= 30) {
        rel = tr('ตรงไปข้างหน้า', 'straight ahead');
      } else if (diff.abs() >= 150) {
        rel = tr('หันกลับหลัง', 'turn around');
      } else if (diff > 0) {
        rel = tr('ไปทางขวา', 'to your right');
      } else {
        rel = tr('ไปทางซ้าย', 'to your left');
      }
      return '$rel ($compass)';
    }
    return tr('ไปทาง$compass', 'head $compass');
  }

  void _alertOffRoute(Position pos, {required bool repeat}) {
    final dist = (_offRoute?.distanceM ?? 0).round();
    final way = _wayBackText(pos);
    // สั่น 2 ครั้ง
    HapticFeedback.vibrate();
    Future.delayed(const Duration(milliseconds: 350), HapticFeedback.vibrate);
    // แจ้งเตือนบนแถบแจ้งเตือน (มีเสียง และเห็นได้แม้ล็อกหน้าจอ/ใส่มือถือในกระเป๋า)
    PushService.showSystemNotification(
      tag: _offRouteTag,
      title: repeat
          ? tr('⚠️ ยังอยู่นอกเส้นทาง', '⚠️ Still off route')
          : tr('⚠️ คุณออกนอกเส้นทางแล้ว', '⚠️ You are off route'),
      body: tr('ห่างจากเส้นทาง $dist ม. — กลับเข้าเส้นทาง$way',
          '$dist m from the route — get back $way'),
    );
  }

  // ─── Summary Dialog ──────────────────────────────────────

  Future<void> _showSummaryDialog({
    required int seconds,
    required double distanceKm,
    required int elevationM,
    required double paceSecPerKm,
    required DateTime startedAt,
    List<LatLng> routePoints = const [],
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final titleCtrl = TextEditingController(text: _defaultTitle(startedAt));
    bool isPublic = false; // default Private

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDState) => AlertDialog(
          backgroundColor: pal.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          title: Row(
            children: [
              const Icon(Icons.flag_rounded, color: Color(0xFFFC4C02)),
              const SizedBox(width: 10),
              Text(
                _activityType == 'cycling' ? _s.finishRideTitle : _s.finishRunTitle,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: pal.text,
                ),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ─── แผนที่เส้นทาง ────────────────────────────
                if (routePoints.length >= 2) ..._buildRouteMapWidget(routePoints),

                // ชื่อกิจกรรม
                TextField(
                  controller: titleCtrl,
                  decoration: InputDecoration(
                    labelText: _s.activityNameLabel,
                    labelStyle: TextStyle(color: pal.textMute),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(
                        color: Color(0xFFFC4C02),
                        width: 2,
                      ),
                    ),
                  ),
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: pal.text,
                  ),
                ),
                const SizedBox(height: 20),

                // Stats
                _summaryStatRow('⏱ ${_s.duration}', _formatTime(seconds)),
                _summaryStatRow(
                  '📏 ${_s.distance}',
                  '${distanceKm.toStringAsFixed(2)} km',
                ),
                _summaryStatRow('⚡ ${_s.avgPace}', _formatPace(paceSecPerKm)),
                _summaryStatRow('⛰ ${_s.elevationGain}', '$elevationM m'),

                const SizedBox(height: 16),
                const Divider(),
                const SizedBox(height: 8),

                // ─── Privacy Toggle ─────────────────────────
                Row(
                  children: [
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 250),
                      child: Icon(
                        isPublic ? Icons.public_rounded : Icons.lock_rounded,
                        key: ValueKey(isPublic),
                        color: isPublic
                            ? const Color(0xFFFC4C02)
                            : pal.textMute,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            isPublic ? _s.publicLabel : _s.privateLabel,
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                              color: isPublic
                                  ? const Color(0xFFFC4C02)
                                  : pal.text,
                            ),
                          ),
                          Text(
                            isPublic
                                ? _s.publicDesc
                                : _s.privateDesc,
                            style: TextStyle(
                              fontSize: 11,
                              color: pal.textMute,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Switch(
                      value: isPublic,
                      onChanged: (v) => setDState(() => isPublic = v),
                      activeThumbColor: const Color(0xFFFC4C02),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: _isSaving ? null : () => Navigator.pop(ctx),
              child: Text(
                _s.cancel,
                style: TextStyle(color: pal.textMute),
              ),
            ),
            ElevatedButton(
              onPressed: _isSaving
                  ? null
                  : () async {
                      setDState(() => _isSaving = true);
                      try {
                        String? authorPhoto = user.photoURL;
                        try {
                          final prefs = await SharedPreferences.getInstance();
                          final localPhoto = prefs.getString('profile_photo_${user.uid}');
                          if (localPhoto != null && localPhoto.isNotEmpty) {
                            authorPhoto = localPhoto;
                          }
                        } catch (_) {}

                        final activity = Activity(
                          uid: user.uid,
                          title: titleCtrl.text.trim().isEmpty
                              ? _defaultTitle(startedAt)
                              : titleCtrl.text.trim(),
                          distanceKm: distanceKm,
                          durationSeconds: seconds,
                          avgPaceSecPerKm: paceSecPerKm,
                          elevationM: elevationM,
                          activityType: _activityType,
                          startedAt: startedAt,
                          isPublic: isPublic,
                          authorName: user.displayName ?? _s.runner,
                          authorPhotoUrl: authorPhoto,
                          routePoints: routePoints
                              .map((p) => {'lat': p.latitude, 'lng': p.longitude})
                              .toList(),
                        );

                        // เริ่ม save (ไม่ await — ปล่อยให้ sync ใน background)
                        final saveFuture = _firestoreService.saveActivity(
                          activity,
                        );

                        // ปิด dialog ทันที (optimistic — ข้อมูลอยู่ใน local cache แล้ว)
                        if (ctx.mounted) Navigator.pop(ctx);

                        // เปิดแบบ push (วิ่งอิสระในโซน) ไม่มี HomeScreen รับผล → กลับหน้าก่อนหน้า
                        if (widget.onRunFinished == null && mounted && _isPushed) {
                          Navigator.of(context).pop();
                        }

                        // แจ้ง HomeScreen พร้อมข้อมูลสรุปการวิ่ง
                        widget.onRunFinished?.call(
                          LastRunSummary(
                            title: titleCtrl.text.trim().isEmpty
                                ? _defaultTitle(startedAt)
                                : titleCtrl.text.trim(),
                            distanceKm: distanceKm,
                            durationSeconds: seconds,
                            paceSecPerKm: paceSecPerKm,
                            routePoints: routePoints,
                            finishedAt: DateTime.now(),
                            activityType: _activityType,
                          ),
                        );

                        if (mounted) {
                          _showSnack(
                            isPublic
                                ? _s.savedAndShared
                                : _s.savedActivitySuccess,
                          );
                        }

                        // ถ้า server sync fail ใน background → แสดง error เงียบๆ
                        saveFuture.catchError((e) {
                          if (mounted) {
                            _showSnack(
                              '${_s.syncError}: $e',
                              isError: true,
                            );
                          }
                        });
                      } catch (e) {
                        setDState(() => _isSaving = false);
                        if (mounted) {
                          _showSnack('${_s.saveError}: $e', isError: true);
                        }
                      }
                    },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFC4C02),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: _isSaving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Text(
                      _s.saveButton,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
            ),
          ],
        ),
      ),
    );
    _isSaving = false;
  }

  // ─── Route Map Widget ────────────────────────────────────

  List<Widget> _buildRouteMapWidget(List<LatLng> points) {
    // คำนวณ bounds เพื่อ fit แผนที่
    double minLat = points.first.latitude;
    double maxLat = points.first.latitude;
    double minLng = points.first.longitude;
    double maxLng = points.first.longitude;
    for (final p in points) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    final centerLat = (minLat + maxLat) / 2;
    final centerLng = (minLng + maxLng) / 2;

    // คำนวณ zoom ให้พอดี (approximate)
    final latDiff = (maxLat - minLat).abs();
    final lngDiff = (maxLng - minLng).abs();
    final maxDiff = latDiff > lngDiff ? latDiff : lngDiff;
    double zoom;
    if (maxDiff < 0.002) {
      zoom = 16.0;
    } else if (maxDiff < 0.005) {
      zoom = 15.0;
    } else if (maxDiff < 0.01) {
      zoom = 14.0;
    } else if (maxDiff < 0.05) {
      zoom = 13.0;
    } else if (maxDiff < 0.1) {
      zoom = 12.0;
    } else {
      zoom = 11.0;
    }

    return [
      ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: SizedBox(
          height: 200,
          child: FlutterMap(
            options: MapOptions(
              initialCenter: LatLng(centerLat, centerLng),
              initialZoom: zoom,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.none, // ปิด gesture ใน dialog
              ),
            ),
            children: [
              // Base tile
              TileLayer(
                urlTemplate:
                    'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.demo20426',
              ),
              // เส้นทาง Polyline
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: points,
                    color: const Color(0xFFFC4C02),
                    strokeWidth: 4.0,
                  ),
                ],
              ),
              // Markers: จุดเริ่ม (เขียว) และจุดจบ (แดง)
              MarkerLayer(
                markers: [
                  Marker(
                    point: points.first,
                    width: 24,
                    height: 24,
                    child: Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF1A9950),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2.5),
                        boxShadow: const [
                          BoxShadow(
                            color: Colors.black26,
                            blurRadius: 4,
                            offset: Offset(0, 2),
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.play_arrow_rounded,
                        color: Colors.white,
                        size: 12,
                      ),
                    ),
                  ),
                  Marker(
                    point: points.last,
                    width: 24,
                    height: 24,
                    child: Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFFFC4C02),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2.5),
                        boxShadow: const [
                          BoxShadow(
                            color: Colors.black26,
                            blurRadius: 4,
                            offset: Offset(0, 2),
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.flag_rounded,
                        color: Colors.white,
                        size: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      // Legend
      Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 4),
        child: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: const BoxDecoration(
                color: Color(0xFF1A9950),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              _s.startPointMarker,
              style: TextStyle(fontSize: 11, color: pal.textMute),
            ),
            const SizedBox(width: 12),
            Container(
              width: 10,
              height: 10,
              decoration: const BoxDecoration(
                color: Color(0xFFFC4C02),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              _s.endPointMarker,
              style: TextStyle(fontSize: 11, color: pal.textMute),
            ),
            const Spacer(),
            Text(
              '${points.length} ${_s.gpsPointsSuffix}',
              style: TextStyle(fontSize: 11, color: pal.textMute),
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
    ];
  }

  // ─── Helpers ─────────────────────────────────────────────

  String _defaultTitle(DateTime dt) {
    final h = dt.hour;
    if (_isThai) {
      final label = _activityType == 'cycling' ? 'ปั่น' : 'วิ่ง';
      if (h < 6) return '$labelกลางคืน';
      if (h < 12) return '$labelเช้า';
      if (h < 17) return '$labelกลางวัน';
      return '$labelเย็น';
    } else {
      final label = _activityType == 'cycling' ? 'Ride' : 'Run';
      if (h < 6) return 'Night $label';
      if (h < 12) return 'Morning $label';
      if (h < 17) return 'Afternoon $label';
      return 'Evening $label';
    }
  }

  String _formatTime(int totalSeconds) {
    final h = totalSeconds ~/ 3600;
    final m = (totalSeconds % 3600) ~/ 60;
    final s = totalSeconds % 60;
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  String _formatPace(double secPerKm) {
    if (secPerKm <= 0) return '--:--';
    final m = secPerKm ~/ 60;
    final s = (secPerKm % 60).round();
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}/km';
  }

  void _showSnack(String msg, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: isError ? Colors.red.shade700 : const Color(0xFF1A9950),
      ),
    );
  }

  // ─── No-Movement Timer ─────────────────────────────────
  void _startNoMovementTimer() {
    _noMovementTimer?.cancel();
    _lastMovedAt = DateTime.now();
    _noMovementTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted || !_isRunning || _isPaused) return;
      final since = DateTime.now().difference(_lastMovedAt ?? DateTime.now());
      if (since.inMinutes >= 5) {
        setState(() => _showNoMovementAlert = true);
      }
    });
  }

  // ─── SOS ─────────────────────────────────────────────
  Future<void> _triggerSOS() async {
    final pos = _lastPosition ?? _gpsFix;
    if (_emergencyPhone.isEmpty) {
      _showSnack(_s.noEmergencySetPrompt, isError: true);
      return;
    }
    if (pos != null) {
      await SafetyService.sendSOSSms(
        _emergencyPhone, pos.latitude, pos.longitude,
        _emergencyName.isEmpty ? _s.runner : _emergencyName,
      );
    } else {
      await SafetyService.callNumber(_emergencyPhone);
    }
  }


  void _showWaypointNotification(Waypoint wp) {
    const icons = {'water': '💧', 'rest': '🪑', 'cafe': '☕', 'toilet': '🚻', 'viewpoint': '📸', 'park': '🌳', 'danger': '⚠️'};
    final emoji = icons[wp.type] ?? '📍';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(children: [
        Text(emoji, style: const TextStyle(fontSize: 20)),
        const SizedBox(width: 10),
        Expanded(child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(wp.displayName, style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.white)),
            if (wp.description != null)
              Text(wp.displayDescription!, style: const TextStyle(fontSize: 11, color: Colors.white70)),
          ],
        )),
      ]),
      backgroundColor: const Color(0xFFFC4C02),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      duration: const Duration(seconds: 4),
    ));
  }

  // ─── Activity Type Picker ────────────────────────────────

  void _showActivityTypePicker() {
    if (_isRunning) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: pal.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 48),
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
            Text(
              _s.selectActivityType,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: pal.text,
              ),
            ),
            const SizedBox(height: 20),
            _activityTypeOption(
              'running',
              Icons.directions_run,
              _s.runningLabel,
              _isThai ? 'บันทึกการวิ่ง' : 'Track a run',
              ctx,
            ),
            const SizedBox(height: 12),
            _activityTypeOption(
              'cycling',
              Icons.directions_bike,
              _s.cyclingLabel,
              _isThai ? 'บันทึกการปั่นจักรยาน' : 'Track a bike ride',
              ctx,
            ),
          ],
        ),
      ),
    );
  }

  Widget _activityTypeOption(
    String type,
    IconData icon,
    String label,
    String sub,
    BuildContext ctx,
  ) {
    final selected = _activityType == type;
    return GestureDetector(
      onTap: () {
        setState(() => _activityType = type);
        Navigator.pop(ctx);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFFFC4C02).withValues(alpha: 0.07)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? const Color(0xFFFC4C02) : pal.border,
            width: selected ? 2 : 1.5,
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: selected
                    ? const Color(0xFFFC4C02).withValues(alpha: 0.12)
                    : pal.surface2,
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                color: selected
                    ? const Color(0xFFFC4C02)
                    : pal.textMute,
                size: 22,
              ),
            ),
            const SizedBox(width: 16),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected
                        ? const Color(0xFFFC4C02)
                        : pal.text,
                  ),
                ),
                Text(
                  sub,
                  style: TextStyle(
                    fontSize: 12,
                    color: pal.textMute,
                  ),
                ),
              ],
            ),
            const Spacer(),
            if (selected)
              const Icon(
                Icons.check_circle_rounded,
                color: Color(0xFFFC4C02),
                size: 22,
              ),
          ],
        ),
      ),
    );
  }

  // ─── Build ───────────────────────────────────────────────

  /// สีพื้น/ตัวอักษรตามธีมปัจจุบัน
  AppPalette get pal => context.pal;

  /// เปิดหน้านี้แบบ push (เช่น "วิ่งอิสระในโซนนี้") หรือมาจากแผนที่พร้อมเส้นทาง → แสดงปุ่มกลับ
  bool get _isPushed => widget.onRunFinished == null && Navigator.of(context).canPop();

  bool get _canGoBack =>
      !_isRunning && (_isPushed || (widget.selectedRoute != null && widget.onCancel != null));

  void _goBack() {
    if (_isRunning) return;
    if (_isPushed) {
      Navigator.of(context).pop();
    } else {
      widget.onCancel?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    context.watch<LanguageProvider>();
    // กันปุ่มย้อนกลับของระบบปิดหน้าระหว่างวิ่ง (ข้อมูลการวิ่งจะหาย)
    return PopScope(
      canPop: !_isRunning,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _isRunning) {
          _showSnack(tr('กดหยุดการวิ่งก่อน แล้วจึงย้อนกลับ', 'Stop the run before going back'));
        }
      },
      child: _buildScaffold(context),
    );
  }

  Widget _buildScaffold(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // 🖼️ Wallpaper Background
          Positioned.fill(
            child: Image.asset(
              'assets/images/propic1.jpg',
              fit: BoxFit.cover,
              errorBuilder: (ctx, err, stack) =>
                  Container(color: pal.bg),
            ),
          ),
          // 🌫️ White Overlay (Reduced opacity to make image vivid)
          Positioned.fill(
            child: Container(color: pal.bg.withValues(alpha: pal.isDark ? 0.86 : 0.50)),
          ),
          // 📱 Foreground Record Content
          // เลย์เอาต์แบบแอปวิ่งทั่วไป: ตัวเลขด้านบน — แผนที่ (เส้นทางที่วางแผน + เส้นที่วิ่งจริง) ตรงกลาง — ปุ่มด้านล่าง
          SafeArea(
            child: Column(
              children: [
                // Header
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.radio_button_checked,
                        color: Color(0xFFFC4C02),
                        size: 22,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _s.saveActivity,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            color: pal.text,
                          ),
                        ),
                      ),
                      // ปุ่มกลับ (แสดงเฉพาะเมื่อมาจากแมพ และยังไม่ได้วิ่ง)
                      if (_canGoBack) ...[
                        GestureDetector(
                          onTap: _goBack,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            margin: const EdgeInsets.only(right: 8),
                            decoration: BoxDecoration(
                              color: pal.border,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.arrow_back_ios_rounded, size: 13, color: pal.textSub),
                                const SizedBox(width: 2),
                                Text(_s.back, style: TextStyle(fontSize: 12, color: pal.textSub, fontWeight: FontWeight.w600)),
                              ],
                            ),
                          ),
                        ),
                      ],
                      GestureDetector(
                        onTap: _isRunning ? null : _showActivityTypePicker,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: pal.surface2,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                _activityType == 'cycling'
                                    ? Icons.directions_bike
                                    : Icons.directions_run,
                                size: 16,
                                color: const Color(0xFFFC4C02),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                _activityType == 'cycling'
                                    ? _s.cyclingLabel
                                    : _s.runningLabel,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: pal.text,
                                ),
                              ),
                              if (!_isRunning) ...[
                                const SizedBox(width: 4),
                                const Icon(
                                  Icons.keyboard_arrow_down_rounded,
                                  size: 16,
                                  color: Color(0xFFFC4C02),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 6),

                // Timer
                Text(
                  _formatTime(_seconds),
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 52,
                    fontWeight: FontWeight.w200,
                    letterSpacing: 4,
                    color: pal.text,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _isRunning
                      ? (_isPaused
                            ? _s.pausedStatus
                            : (_activityType == 'cycling'
                                  ? _s.cyclingStatus
                                  : _s.runningStatus))
                      : (_activityType == 'cycling'
                            ? _s.readyToCycleStatus
                            : _s.readyToRunStatus),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    // letterSpacing แยกสระ/วรรณยุกต์ไทยออกจากพยัญชนะ ("ก ำ ล ั ง") → ใช้เฉพาะภาษาอังกฤษ
                    letterSpacing: _isThai ? 0 : 3,
                    color: _isRunning
                        ? (_isPaused
                              ? const Color(0xFFFC4C02)
                              : const Color(0xFFFC4C02))
                        : pal.textMute,
                  ),
                ),

                const SizedBox(height: 8),

                // Live Stats
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 20),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  decoration: BoxDecoration(
                    color: pal.surface.withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: pal.border),
                  ),
                  child: Row(
                    children: [
                      _buildLiveStat(
                        _s.distance,
                        _distanceKm.toStringAsFixed(2),
                        'km',
                      ),
                      _buildLiveStatDivider(),
                      // ─── Current Pace (real-time จาก GPS window) ───
                      _buildLiveStat(
                        _s.currentPace,
                        _formatPaceShort(_currentPaceSecPerKm),
                        '/km',
                      ),
                      _buildLiveStatDivider(),
                      _buildLiveStat(
                        _s.calories,
                        (_distanceKm * (_activityType == 'cycling' ? 35 : 65))
                            .round()
                            .toString(),
                        'kcal',
                      ),
                    ],
                  ),
                ),
                _buildSubStatsRow(),
                const SizedBox(height: 8),

                // ─── Live Map ─────────────────────────────
                Expanded(child: _buildLiveMap()),

                // Control Buttons
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
                  child: _isRunning
                      ? _buildRunningControls()
                      : _buildStartButton(),
                ),
              ],
            ),
          ),
        // ─── Countdown Overlay ───────────────────────
        if (_countdown > 0)
          Positioned.fill(
            child: Container(
              color: Colors.black.withValues(alpha: 0.80),
              child: Stack(
                children: [
                  // ปุ่มยกเลิก (บนขวา)
                  Positioned(
                    top: 48,
                    right: 20,
                    child: GestureDetector(
                      onTap: () {
                        _countdownTimer?.cancel();
                        setState(() => _countdown = 0);
                        widget.onCancel?.call();
                      },
                      child: Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.15),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.close_rounded, color: Colors.white, size: 24),
                      ),
                    ),
                  ),
                  // เนื้อหา countdown — Center ทั้งแนวนอนและแนวตั้ง
                  Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        if (widget.selectedRoute != null) ...[
                          const Icon(Icons.route, color: Colors.white54, size: 28),
                          const SizedBox(height: 8),
                          Text(
                            _isThai
                                ? widget.selectedRoute!.name
                                : (widget.selectedRoute!.nameEn.isNotEmpty
                                    ? widget.selectedRoute!.nameEn
                                    : widget.selectedRoute!.name),
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white70, fontSize: 18, fontWeight: FontWeight.w600)),
                          const SizedBox(height: 32),
                        ],
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 300),
                          transitionBuilder: (child, anim) =>
                              ScaleTransition(scale: anim, child: child),
                          child: Text('$_countdown',
                            key: ValueKey(_countdown),
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 120, color: Colors.white, fontWeight: FontWeight.w900, height: 1)),
                        ),
                        const SizedBox(height: 24),
                        Text(_s.getReadyPrompt,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white60, fontSize: 18, letterSpacing: _isThai ? 0 : 4)),
                        const SizedBox(height: 32),
                        // ปุ่มยกเลิกด้านล่าง
                        TextButton.icon(
                          onPressed: () {
                            _countdownTimer?.cancel();
                            setState(() => _countdown = 0);
                            widget.onCancel?.call();
                          },
                          icon: const Icon(Icons.arrow_back_rounded, color: Colors.white60, size: 18),
                          label: Text(_s.cancelBackToRoute,
                            style: const TextStyle(color: Colors.white60, fontSize: 14)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

        // ─── SOS button (แสดงระหว่างวิ่ง) ────────
        if (_isRunning && !_isPaused && _countdown == 0)
          Positioned(
            bottom: 120,
            right: 20,
            child: GestureDetector(
              onLongPress: _triggerSOS,
              child: Container(
                width: 56, height: 56,
                decoration: BoxDecoration(
                  color: const Color(0xFFE53935),
                  shape: BoxShape.circle,
                  boxShadow: [BoxShadow(color: const Color(0xFFE53935).withValues(alpha: 0.6), blurRadius: 16, spreadRadius: 2)],
                ),
                child: const Center(
                  child: Text('SOS', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 14, letterSpacing: 1)),
                ),
              ),
            ),
          ),

        // ─── No-Movement Alert ────────────────────────────
        if (_showNoMovementAlert)
          Positioned.fill(
            child: Container(
              color: Colors.black.withValues(alpha: 0.75),
              child: Center(
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 32),
                  padding: const EdgeInsets.all(28),
                  decoration: BoxDecoration(
                    color: pal.surface,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('⚠️', style: TextStyle(fontSize: 48)),
                      const SizedBox(height: 12),
                      Text(_s.areYouOkayPrompt,
                        style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: pal.text)),
                      const SizedBox(height: 8),
                      Text(_s.noMovementPrompt,
                        style: TextStyle(fontSize: 14, color: pal.textSub), textAlign: TextAlign.center),
                      const SizedBox(height: 24),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton(
                              onPressed: () {
                                setState(() => _showNoMovementAlert = false);
                                _lastMovedAt = DateTime.now();
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF43A047),
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                                padding: const EdgeInsets.symmetric(vertical: 14),
                              ),
                              child: Text(_s.imSafe, style: const TextStyle(fontWeight: FontWeight.w700)),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: ElevatedButton(
                              onPressed: _triggerSOS,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFFE53935),
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                                padding: const EdgeInsets.symmetric(vertical: 14),
                              ),
                              child: Text(_s.sendSos, style: const TextStyle(fontWeight: FontWeight.w700)),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Off-route banner ────────────────────────────────────

  Widget _buildOffRouteBanner() {
    final m = _offRoute!;
    final dist = m.distanceM;
    if (m.state == RouteFollowState.onRoute || dist == null) {
      return const SizedBox.shrink();
    }
    final isOff = m.state == RouteFollowState.offRoute;
    final color = isOff ? const Color(0xFFE53935) : const Color(0xFF1E88E5);
    final title = isOff
        ? tr('ออกนอกเส้นทาง ${dist.round()} ม.', 'Off route by ${dist.round()} m')
        : tr('กำลังไปยังเส้นทาง · อีก ${dist.round()} ม.',
            'Heading to the route · ${dist.round()} m away');
    final sub = isOff
        ? tr('กลับเข้าเส้นทาง${_wayBackText(_gpsFix)}', 'Get back ${_wayBackText(_gpsFix)}')
        : tr('เริ่มเตือนเมื่อคุณเข้าสู่เส้นทางแล้ว', 'Alerts start once you reach the route');
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 8, 10, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [BoxShadow(color: color.withValues(alpha: 0.35), blurRadius: 10)],
      ),
      child: Row(children: [
        Icon(isOff ? Icons.wrong_location_rounded : Icons.near_me_rounded,
            color: Colors.white, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title,
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w800, fontSize: 14)),
              Text(sub,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 12)),
            ],
          ),
        ),
        if (isOff)
          GestureDetector(
            onTap: () {
              setState(() => _offRouteMuted = !_offRouteMuted);
              if (_offRouteMuted) PushService.cancelSystemNotification(_offRouteTag);
            },
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                shape: BoxShape.circle,
              ),
              child: Icon(
                _offRouteMuted
                    ? Icons.notifications_off_rounded
                    : Icons.notifications_active_rounded,
                color: Colors.white,
                size: 16,
              ),
            ),
          ),
      ]),
    );
  }

  // ─── Live Map (แผนที่ระหว่างวิ่ง) ─────────────────────────
  static const LatLng _defaultCenter = LatLng(18.7883, 98.9853);

  List<LatLng> get _plannedPath => (_activeRoute?.path ?? const <LatLng>[])
      .where((p) => p.latitude.isFinite && p.longitude.isFinite)
      .toList();

  LatLng? get _myLatLng {
    final p = _gpsFix ?? _lastPosition;
    if (p == null || !p.latitude.isFinite || !p.longitude.isFinite) return null;
    return LatLng(p.latitude, p.longitude);
  }

  void _onLiveMapReady() {
    _liveMapReady = true;
    _fitPlannedRoute();
  }

  /// ซูมให้เห็นเส้นทางที่วางแผนทั้งเส้น (และตำแหน่งผู้ใช้) — กันค่า NaN เมื่อแผนที่เล็ก
  void _fitPlannedRoute() {
    if (!_liveMapReady) return;
    final pts = <LatLng>[..._plannedPath];
    if (pts.isEmpty && _activeZone != null && _activeZone!.polygons.isNotEmpty) {
      pts.addAll(_activeZone!.polygons.first);
    }
    final me = _myLatLng;
    if (me != null) pts.add(me);
    if (pts.isEmpty) return;
    try {
      if (pts.length < 2) {
        _mapController.move(pts.first, 16);
        return;
      }
      double minLat = pts.first.latitude, maxLat = minLat;
      double minLng = pts.first.longitude, maxLng = minLng;
      for (final p in pts) {
        if (p.latitude < minLat) minLat = p.latitude;
        if (p.latitude > maxLat) maxLat = p.latitude;
        if (p.longitude < minLng) minLng = p.longitude;
        if (p.longitude > maxLng) maxLng = p.longitude;
      }
      final center = LatLng((minLat + maxLat) / 2, (minLng + maxLng) / 2);
      final size = _mapController.camera.nonRotatedSize;
      if (!size.width.isFinite || !size.height.isFinite || size.width < 80 || size.height < 80) {
        _mapController.move(center, 15);
        return;
      }
      final pad = math.min(30.0, math.min(size.width, size.height) / 6);
      final topPad = math.min(pad + 60, size.height * 0.3);
      _mapController.fitCamera(CameraFit.bounds(
        bounds: LatLngBounds(
          LatLng(minLat - 0.0005, minLng - 0.0005),
          LatLng(maxLat + 0.0005, maxLng + 0.0005),
        ),
        padding: EdgeInsets.fromLTRB(pad, topPad, pad, pad),
        maxZoom: 17,
      ));
      final c = _mapController.camera.center;
      if (!c.latitude.isFinite || !c.longitude.isFinite || !_mapController.camera.zoom.isFinite) {
        _mapController.move(center, 15);
      }
    } catch (_) {}
  }

  /// ให้กล้องตามผู้วิ่ง (ปิดเองเมื่อผู้ใช้เลื่อนแผนที่ กดปุ่มตำแหน่งเพื่อเปิดอีกครั้ง)
  void _followCamera(Position pos) {
    if (!_liveMapReady || !_followUser) return;
    try {
      final z = _mapController.camera.zoom;
      _mapController.move(LatLng(pos.latitude, pos.longitude), z.isFinite && z >= 15 ? z : 16.5);
    } catch (_) {}
  }

  Future<void> _onGpsTap() async {
    final ok = await LocationHelper.checkAndRequestPermission(
      context: context,
      showDialogs: true,
    );
    if (ok && mounted) {
      _showSnack(tr('สัญญาณ GPS พร้อมใช้งาน', 'GPS Signal Ready'));
      try {
        final pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
        ).timeout(const Duration(seconds: 4));
        if (mounted) {
          setState(() {
            _lastPosition ??= pos;
            _gpsFix = pos;
          });
          _followCamera(pos);
        }
      } catch (_) {}
    }
  }

  Widget _mapPin(Color color, IconData icon) => Container(
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2.5),
          boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2))],
        ),
        child: Icon(icon, color: Colors.white, size: 12),
      );

  Widget _mapButton(IconData icon, VoidCallback onTap, {bool active = false}) => Material(
        color: pal.surface,
        shape: const CircleBorder(),
        elevation: 3,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(9),
            child: Icon(icon, size: 20,
                color: active ? const Color(0xFF1E88E5) : pal.textSub),
          ),
        ),
      );

  Widget _buildLiveMap() {
    final planned = _plannedPath;
    final me = _myLatLng;
    final initial = me ??
        (planned.isNotEmpty ? planned.first : (_activeZone?.center ?? _defaultCenter));
    final showLoopEnd = planned.length >= 2 &&
        Geolocator.distanceBetween(planned.first.latitude, planned.first.longitude,
                planned.last.latitude, planned.last.longitude) > 30;
    final hasOverlayProgress = _activeRoute != null && _isRunning;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Stack(
          children: [
            Positioned.fill(
              child: FlutterMap(
                mapController: _mapController,
                options: MapOptions(
                  initialCenter: initial,
                  initialZoom: 16,
                  onMapReady: _onLiveMapReady,
                  onPositionChanged: (camera, hasGesture) {
                    if (hasGesture && _followUser) setState(() => _followUser = false);
                  },
                  interactionOptions: const InteractionOptions(
                    flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                  ),
                ),
                children: [
                  TileLayer(
                    urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'com.example.demo20426',
                  ),
                  if (_activeZone != null && _activeZone!.polygons.isNotEmpty)
                    PolygonLayer(polygons: [
                      for (final ring in _activeZone!.polygons)
                        if (ring.length >= 3)
                          Polygon(
                            points: ring,
                            color: const Color(0xFF3498DB).withValues(alpha: 0.15),
                            borderColor: const Color(0xFF3498DB).withValues(alpha: 0.5),
                            borderStrokeWidth: 1.2,
                          ),
                    ]),
                  // เส้นทางที่วางแผนไว้ (ให้วิ่งตาม)
                  if (planned.length >= 2)
                    PolylineLayer(polylines: [
                      Polyline(
                        points: planned,
                        color: const Color(0xFFFC4C02).withValues(alpha: 0.8),
                        strokeWidth: 6,
                        borderColor: Colors.white,
                        borderStrokeWidth: 1.5,
                      ),
                    ]),
                  // เส้นที่วิ่งไปแล้วจริง (GPS)
                  if (_routePoints.length >= 2)
                    PolylineLayer(polylines: [
                      Polyline(
                        points: List<LatLng>.of(_routePoints),
                        color: const Color(0xFF1E88E5),
                        strokeWidth: 5,
                      ),
                    ]),
                  // เส้นประชี้ทางกลับเข้าเส้นทาง (เมื่อออกนอกเส้นทาง)
                  if (me != null &&
                      _offRoute?.state == RouteFollowState.offRoute &&
                      _offRoute?.nearestPoint != null)
                    PolylineLayer(polylines: [
                      Polyline(
                        points: [me, _offRoute!.nearestPoint!],
                        color: const Color(0xFFE53935),
                        strokeWidth: 4,
                        pattern: StrokePattern.dashed(segments: const [10, 8]),
                      ),
                    ]),
                  // วงความแม่นยำ GPS รอบจุดตำแหน่งปัจจุบัน
                  if (me != null && _gpsFix != null && _gpsFix!.accuracy > 0 && _gpsFix!.accuracy < 150)
                    CircleLayer(circles: [
                      CircleMarker(
                        point: me,
                        radius: _gpsFix!.accuracy,
                        useRadiusInMeter: true,
                        color: const Color(0xFF1E88E5).withValues(alpha: 0.12),
                        borderColor: const Color(0xFF1E88E5).withValues(alpha: 0.35),
                        borderStrokeWidth: 1,
                      ),
                    ]),
                  MarkerLayer(markers: [
                    if (planned.isNotEmpty)
                      Marker(
                        point: planned.first,
                        width: 22,
                        height: 22,
                        child: _mapPin(const Color(0xFF1A9950), Icons.play_arrow_rounded),
                      ),
                    if (showLoopEnd)
                      Marker(
                        point: planned.last,
                        width: 22,
                        height: 22,
                        child: _mapPin(const Color(0xFFFC4C02), Icons.flag_rounded),
                      ),
                    if (me != null)
                      Marker(
                        point: me,
                        width: 22,
                        height: 22,
                        child: Container(
                          decoration: BoxDecoration(
                            color: const Color(0xFF1E88E5),
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 3),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(0xFF1E88E5).withValues(alpha: 0.4),
                                blurRadius: 8,
                                spreadRadius: 2,
                              ),
                            ],
                          ),
                        ),
                      ),
                  ]),
                ],
              ),
            ),

            // ชื่อเส้นทาง / โซน (ด้านบนแผนที่)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                // ─── Route Banner ───────────────────────
                if (_activeRoute != null)
                  Container(
                    margin: const EdgeInsets.fromLTRB(10, 10, 10, 0),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(colors: [Color(0xFFFC4C02), Color(0xFFE8430A)]),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(children: [
                      const Icon(Icons.route, color: Colors.white, size: 18),
                      const SizedBox(width: 10),
                      Expanded(child: Text(
                        _isThai
                            ? _activeRoute!.name
                            : (_activeRoute!.nameEn.isNotEmpty ? _activeRoute!.nameEn : _activeRoute!.name),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14))),
                      const SizedBox(width: 8),
                      Text('${_activeRoute!.distanceKm.toStringAsFixed(2)} km',
                        style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600)),
                      const SizedBox(width: 8),
                      // ✕ ปุ่ม dismiss route
                      GestureDetector(
                        onTap: () {
                          if (_offRoute != null) PushService.cancelSystemNotification(_offRouteTag);
                          setState(() {
                            _activeRoute = null;
                            _offRoute = null;
                          });
                        },
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.2),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.close_rounded, color: Colors.white, size: 14),
                        ),
                      ),
                    ]),
                  ),

                // ─── Off-route / approaching banner ─────
                if (_offRoute != null && _activeRoute != null && _isRunning)
                  _buildOffRouteBanner(),

                // ─── Zone Banner ───────────────────────
                if (_activeZone != null)
                  Container(
                    margin: const EdgeInsets.fromLTRB(10, 8, 10, 0),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(colors: [Color(0xFF2980B9), Color(0xFF3498DB)]),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(children: [
                      const Icon(Icons.shield_outlined, color: Colors.white, size: 18),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _activeZone!.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14),
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (_activeZone!.safetyScore != null)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.25),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '🛡️ ${_activeZone!.safetyScore}',
                            style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                        ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: () => setState(() => _activeZone = null),
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.2),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.close_rounded, color: Colors.white, size: 14),
                        ),
                      ),
                    ]),
                  ),

                ],
              ),
            ),

            // แถบความคืบหน้าเส้นทาง (ด้านล่างแผนที่)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                // ─── Progress Bar ───────────────────────
                if (_activeRoute != null && _isRunning)
                  Container(
                    color: pal.surface.withValues(alpha: 0.92),
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(_s.routeProgress,
                              style: TextStyle(fontSize: 11, color: pal.textMute)),
                            Text(
                              '${_distanceKm.toStringAsFixed(2)} / ${_activeRoute!.distanceKm.toStringAsFixed(2)} km',
                              style: TextStyle(fontSize: 11, color: pal.textMute, fontWeight: FontWeight.w600)),
                          ],
                        ),
                        const SizedBox(height: 6),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: LinearProgressIndicator(
                            value: (_distanceKm / _activeRoute!.distanceKm).clamp(0.0, 1.0),
                            backgroundColor: pal.border,
                            valueColor: const AlwaysStoppedAnimation(Color(0xFFFC4C02)),
                            minHeight: 8,
                          ),
                        ),
                      ],
                    ),
                  ),

                ],
              ),
            ),

            // ปุ่มตำแหน่งฉัน / ดูทั้งเส้นทาง (ซ้ายล่าง — ขวาล่างเป็นปุ่ม SOS)
            Positioned(
              left: 10,
              bottom: hasOverlayProgress ? 64 : 10,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (planned.length >= 2 || _activeZone != null) ...[
                    _mapButton(Icons.zoom_out_map_rounded, () {
                      setState(() => _followUser = false);
                      _fitPlannedRoute();
                    }),
                    const SizedBox(height: 8),
                  ],
                  _mapButton(Icons.my_location_rounded, () {
                    setState(() => _followUser = true);
                    final p = _myLatLng;
                    if (p != null && _liveMapReady) {
                      try {
                        _mapController.move(p, 16.5);
                      } catch (_) {}
                    } else {
                      _onGpsTap();
                    }
                  }, active: _followUser),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// แถวสถิติรอง: เพซเฉลี่ย / ความสูงสะสม / สถานะ GPS
  /// ระดับสัญญาณ GPS 0–3 ขีด จากความแม่นยำ (เมตร)
  int get _gpsBars {
    final p = _gpsFix;
    if (p == null) return 0;
    final acc = p.accuracy;
    if (acc <= 10) return 3;
    if (acc <= 25) return 2;
    if (acc <= 60) return 1;
    return 0;
  }

  Widget _buildGpsSignal() {
    final bars = _gpsBars;
    final color = bars >= 2
        ? const Color(0xFF2ECC71)
        : (bars == 1 ? const Color(0xFFF39C12) : pal.textMute);
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text('GPS',
            style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 1, color: color)),
        const SizedBox(width: 5),
        for (int i = 0; i < 3; i++) ...[
          Container(
            width: 4,
            height: 5.0 + i * 4,
            margin: const EdgeInsets.only(bottom: 2),
            decoration: BoxDecoration(
              color: i < bars ? color : pal.border,
              borderRadius: BorderRadius.circular(1),
            ),
          ),
          if (i < 2) const SizedBox(width: 2),
        ],
      ],
    );
  }

  /// แถวสถิติรอง: เพซเฉลี่ย / ความสูงสะสม / สถานะ GPS
  Widget _buildSubStatsRow() {
    Widget item(IconData icon, Color color, String text) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
            Flexible(
              child: Text(text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600, color: pal.text)),
            ),
          ],
        );

    return Container(
      margin: const EdgeInsets.fromLTRB(20, 6, 20, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: pal.surface.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: pal.border),
      ),
      child: Row(
        children: [
          Expanded(child: item(Icons.show_chart, pal.textMute,
              '${_s.avgPace} ${_formatPace(_avgPaceSecPerKm)}')),
          Expanded(child: item(Icons.terrain, const Color(0xFFFC4C02),
              '\u2191${_totalElevationGain.round()} m')),
          GestureDetector(
            onTap: _onGpsTap,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.only(left: 6),
              child: _buildGpsSignal(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStartButton() {
    return AnimatedBuilder(
      animation: _pulseController,
      builder: (context, child) {
        final scale = 1.0 + (_pulseController.value * 0.05);
        return Transform.scale(
          scale: scale,
          child: GestureDetector(
            onTap: _startRun,
            child: Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFFFC4C02), Color(0xFFFF6B35)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFFC4C02).withValues(alpha: 0.35),
                    blurRadius: 30,
                    spreadRadius: 5,
                  ),
                ],
              ),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 36,
                    ),
                    Text(
                      _activityType == 'cycling' ? _s.startRideBtn : _s.startRunBtn,
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                        letterSpacing: _isThai ? 0 : 1,
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

  Widget _buildRunningControls() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Stop Button
        GestureDetector(
          onTap: _stopRun,
          child: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFFFC4C02).withValues(alpha: 0.1),
              border: Border.all(color: const Color(0xFFFC4C02), width: 2),
            ),
            child: const Icon(
              Icons.stop_rounded,
              color: Color(0xFFFC4C02),
              size: 30,
            ),
          ),
        ),
        const SizedBox(width: 40),
        // Pause/Resume Button
        GestureDetector(
          onTap: _isPaused ? _resumeRun : _pauseRun,
          child: Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFFFC4C02), Color(0xFFFF6B35)],
              ),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFFFC4C02).withValues(alpha: 0.35),
                  blurRadius: 20,
                ),
              ],
            ),
            child: Icon(
              _isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
              color: Colors.white,
              size: 40,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLiveStat(String label, String value, String unit) {
    return Expanded(
      child: Column(
        children: [
          RichText(
            text: TextSpan(
              children: [
                TextSpan(
                  text: value,
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: pal.text,
                  ),
                ),
                TextSpan(
                  text: ' $unit',
                  style: TextStyle(
                    fontSize: 11,
                    color: pal.textMute,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(fontSize: 11, color: pal.textMute),
          ),
        ],
      ),
    );
  }

  Widget _buildLiveStatDivider() =>
      Container(height: 40, width: 1, color: pal.border);

  Widget _summaryStatRow(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(fontSize: 14, color: pal.textSub),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: pal.text,
          ),
        ),
      ],
    ),
  );

  String _formatPaceShort(double secPerKm) {
    if (secPerKm <= 0) return '--:--';
    final m = secPerKm ~/ 60;
    final s = (secPerKm % 60).round();
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}
