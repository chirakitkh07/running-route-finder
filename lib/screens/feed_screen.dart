import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../models/last_run_summary.dart';
import '../models/route_data.dart';
import '../models/running_zone.dart';
import '../models/preset_zones.dart';
import '../models/activity.dart';
import '../models/app_notification.dart';
import '../services/firestore_service.dart';
import '../services/safety_score_engine.dart';
import '../services/air_quality_service.dart';
import '../widgets/activity_edit_sheet.dart';
import 'package:provider/provider.dart';
import '../providers/language_provider.dart';
import '../providers/notification_provider.dart';
import '../l10n/app_strings.dart';
import 'map_screen.dart';
import '../l10n/tr.dart';
import '../widgets/pwa_install_prompt.dart';
import 'package:demo20426/providers/theme_provider.dart';

class FeedScreen extends StatefulWidget {
  /// ข้อมูลการวิ่งล่าสุด — ส่งมาจาก HomeScreen หลัง Stop วิ่ง
  final LastRunSummary? lastRun;
  final VoidCallback? onNavigateToProfile;
  /// Callback ที่เรียกเมื่อต้องการ navigate ไปหน้า Map (index 1)
  final VoidCallback? onNavigateToMap;
  const FeedScreen({super.key, this.lastRun, this.onNavigateToProfile, this.onNavigateToMap});

  @override
  State<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends State<FeedScreen> {
  /// สีพื้น/ตัวอักษรตามธีมปัจจุบัน
  AppPalette get pal => context.pal;

  AirQualityData? _airData;
  bool _loadingAir = true;
  String? _airError;
  int _myActivitiesLimit = 3;
  String? _currentUserPhoto;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _userProfileSub;

  // ─── Services (instance variables — ไม่สร้างใหม่ทุก build) ──
  final FirestoreService _svc = FirestoreService();

  @override
  void initState() {
    super.initState();
    _loadAirQuality();
    _initCurrentUserPhoto();
  }

  @override
  void dispose() {
    _userProfileSub?.cancel();
    super.dispose();
  }

  Future<void> _initCurrentUserPhoto() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final uid = user.uid;

    // 1. SharedPreferences (เร็วที่สุด)
    try {
      final prefs = await SharedPreferences.getInstance();
      final local = prefs.getString('profile_photo_$uid');
      if (local != null && local.isNotEmpty && mounted) {
        setState(() => _currentUserPhoto = local);
      }
    } catch (_) {}

    // 2. Fallback to auth photoURL
    if ((_currentUserPhoto == null || _currentUserPhoto!.isEmpty) &&
        user.photoURL != null &&
        user.photoURL!.isNotEmpty &&
        mounted) {
      setState(() => _currentUserPhoto = user.photoURL);
    }

    // 3. Realtime listener จาก Firestore users/{uid}
    _userProfileSub?.cancel();
    _userProfileSub = FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .snapshots()
        .listen((doc) {
      if (doc.exists && mounted) {
        final photo = doc.data()?['photoUrl'] as String?;
        if (photo != null && photo != _currentUserPhoto) {
          setState(() => _currentUserPhoto = photo);
        }
      }
    });
  }

  Widget _buildCurrentUserAvatarWidget() {
    if (_currentUserPhoto != null && _currentUserPhoto!.isNotEmpty) {
      if (_currentUserPhoto!.startsWith('data:image')) {
        try {
          final base64Part = _currentUserPhoto!.contains(',')
              ? _currentUserPhoto!.split(',').last
              : _currentUserPhoto!;
          final bytes = base64Decode(base64Part);
          return Image.memory(
            bytes,
            fit: BoxFit.cover,
            width: 36,
            height: 36,
            errorBuilder: (context, error, stackTrace) =>
                const Icon(Icons.person, color: Colors.white, size: 20),
          );
        } catch (_) {}
      } else if (_currentUserPhoto!.startsWith('http://') ||
          _currentUserPhoto!.startsWith('https://')) {
        return Image.network(
          _currentUserPhoto!,
          fit: BoxFit.cover,
          width: 36,
          height: 36,
          errorBuilder: (context, error, stackTrace) =>
              const Icon(Icons.person, color: Colors.white, size: 20),
        );
      }
    }
    return const Icon(Icons.person, color: Colors.white, size: 20);
  }

  Future<void> _loadAirQuality() async {
    try {
      final data = await AirQualityService.fetchAirQuality();
      if (mounted) {
        setState(() { _airData = data; _loadingAir = false; });
        try {
          context.read<NotificationProvider>().updateAirQuality(data);
        } catch (_) {}
        if (data.fromCache) {
          // UC-10/11 A1: บริการภายนอกไม่ตอบสนอง ใช้ข้อมูลล่าสุดที่แคชไว้
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(tr(
                'ไม่สามารถดึงข้อมูลอากาศล่าสุดได้ — แสดงข้อมูลที่บันทึกไว้เมื่อ ${data.fetchedAt.hour.toString().padLeft(2, '0')}:${data.fetchedAt.minute.toString().padLeft(2, '0')} น.',
                'Could not fetch the latest air data — showing data saved at ${data.fetchedAt.hour.toString().padLeft(2, '0')}:${data.fetchedAt.minute.toString().padLeft(2, '0')}')),
          ));
        } else {
          // IT-04: บันทึกค่าฝุ่น/สภาพอากาศ ณ พิกัดปัจจุบันลงตาราง AirQuality และ Weather
          _svc.saveEnvironmentSnapshot(
            latitude: data.latitude,
            longitude: data.longitude,
            airQuality: {'pm2_5': data.pm25, 'us_aqi': data.aqi},
            weather: {
              'temperature': data.temperature,
              'humidity': data.humidity,
              'windspeed': data.windSpeedKmh,
            },
          );
        }
      }
    } catch (e) {
      if (mounted) setState(() { _airError = e.toString(); _loadingAir = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, authSnap) {
        // รอ auth โหลดเสร็จก่อน — ป้องกัน Firestore ได้รับ uid ว่าง
        if (authSnap.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            backgroundColor: Colors.transparent,
            body: Center(
              child: CircularProgressIndicator(color: Color(0xFFFC4C02)),
            ),
          );
        }
        final uid = authSnap.data?.uid ?? '';
        if (uid.isNotEmpty) {
          _svc.syncUserPublicActivities(uid);
        }
        return _buildScaffold(context, uid);
      },
    );
  }

  Widget _buildScaffold(BuildContext context, String uid) {
    final s = AppStrings(isThai: context.watch<LanguageProvider>().isThai);
    final svc = _svc;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          // ─── AppBar ─────────────────────────────────────
          SliverAppBar(
            floating: true,
            snap: true,
            backgroundColor: cs.surface,
            surfaceTintColor: Colors.transparent,
            title: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                            colors: [Color(0xFFFC4C02), Color(0xFFFF6B35)]),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(Icons.directions_run,
                          color: Colors.white, size: 20),
                    ),
                    const SizedBox(width: 10),
                    Flexible(child: Text(s.feedTitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: cs.onSurface, fontWeight: FontWeight.bold, fontSize: 18))),
                  ],
                ),
                actions: [
                  Stack(
                    children: [
                      IconButton(
                        icon: Icon(Icons.notifications_none_rounded, color: cs.onSurface),
                        onPressed: () => _showNotificationsModal(context),
                      ),
                      Consumer<NotificationProvider>(
                        builder: (context, notifProv, _) {
                          final count = notifProv.unreadCount;
                          if (count <= 0) return const SizedBox.shrink();
                          return Positioned(
                            right: 8,
                            top: 8,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                              constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                              decoration: const BoxDecoration(
                                color: Color(0xFFFC4C02),
                                shape: BoxShape.circle,
                              ),
                              child: Center(
                                child: Text(
                                  count > 99 ? '99+' : '$count',
                                  style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                  // ─── Profile Avatar Button ─────────────────────
                  Padding(
                    padding: const EdgeInsets.only(right: 14, left: 4),
                    child: GestureDetector(
                      onTap: () => widget.onNavigateToProfile?.call(),
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: const LinearGradient(
                            colors: [Color(0xFFFC4C02), Color(0xFFFF6B35)],
                          ),
                          border: Border.all(
                            color: const Color(0xFFFC4C02),
                            width: 1.5,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFFFC4C02).withValues(alpha: 0.25),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: ClipOval(
                          child: _buildCurrentUserAvatarWidget(),
                        ),
                      ),
                    ),
                  ),
                ],
              ),

              // ─── PWA Install Prompt (สำหรับ Web / iOS Safari) ─────────
              const SliverToBoxAdapter(child: PwaInstallPrompt()),

              // ─── Last Run Card ────────────────────────────────
              if (widget.lastRun != null)
                SliverToBoxAdapter(child: _buildLastRunCard(widget.lastRun!)),

              // ─── Safety Banner ───────────────────────────────
              SliverToBoxAdapter(child: _buildSafetyBanner(context)),

              // ─── Popular Routes Header ───────────────────────
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 28, 20, 12),
                  child: Row(
                    children: [
                      Container(
                        width: 4, height: 20,
                        decoration: BoxDecoration(
                          color: const Color(0xFFFC4C02),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(s.popularRoutes,
                          style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                              color: Theme.of(context).colorScheme.onSurface)),
                      const Spacer(),
                      Text(s.chiangMaiCity,
                          style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4))),
                    ],
                  ),
                ),
              ),

              // ─── Popular Route Cards ─────────────────────────
              SliverToBoxAdapter(
                child: SizedBox(
                  height: 160,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    itemCount: ChiangMaiRoutes.routes.length + _extraZones.length,
                    itemBuilder: (ctx, i) => i < ChiangMaiRoutes.routes.length
                        ? _buildPopularRouteCard(ChiangMaiRoutes.routes[i])
                        : _buildZonePlaceCard(
                            _extraZones[i - ChiangMaiRoutes.routes.length]),
                  ),
                ),
              ),

              // ─── Community Feed Header ──────────────────────
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 28, 20, 12),
                  child: Row(
                    children: [
                      Container(
                        width: 4, height: 20,
                        decoration: BoxDecoration(
                          color: const Color(0xFF3498DB),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(tr('ชุมชน', 'Community'),
                          style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                              color: cs.onSurface)),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: const Color(0xFF3498DB).withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(s.publicLabel,
                            style: const TextStyle(
                                fontSize: 11,
                                color: Color(0xFF3498DB),
                                fontWeight: FontWeight.w700)),
                      ),
                    ],
                  ),
                ),
              ),

              // ─── Community Feed (public activities) ──────────
              SliverToBoxAdapter(
                child: StreamBuilder<List<Activity>>(
                  stream: svc.getCommunityFeed(),
                  builder: (ctx, snap) {
                    if (snap.connectionState == ConnectionState.waiting) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Center(
                            child: CircularProgressIndicator(
                                color: Color(0xFFFC4C02))),
                      );
                    }
                    final feed = snap.data ?? [];
                    if (feed.isEmpty) {
                      return Container(
                        margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                        padding: const EdgeInsets.symmetric(
                            vertical: 28, horizontal: 20),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.95),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                              color: const Color(0xFFFC4C02)
                                  .withValues(alpha: 0.15)),
                        ),
                        child: Column(
                          children: [
                            Icon(Icons.people_outline_rounded,
                                size: 36, color: pal.textMute),
                            const SizedBox(height: 10),
                            Text(s.noPublicActivities,
                                style: TextStyle(
                                    color: pal.textMute,
                                    fontWeight: FontWeight.w600)),
                            const SizedBox(height: 4),
                            Text(
                                s.publicPrompt,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    fontSize: 12, color: pal.textMute)),
                          ],
                        ),
                      );
                    }
                    return Column(
                      children: feed
                          .map((a) => _buildCommunityCard(a, uid, svc))
                          .toList(),
                    );
                  },
                ),
              ),

              // ─── My Activities Header ─────────────────────────
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 24, 20, 4),
                  child: Text(s.myActivities,
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: cs.onSurface)),
                ),
              ),

              // ─── My Activities (Firestore realtime) ───────────
              SliverToBoxAdapter(
                child: StreamBuilder<List<Activity>>(
                  stream: svc.getUserActivities(uid),
                  builder: (ctx, snap) {
                    if (snap.connectionState == ConnectionState.waiting) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 40),
                        child: Center(
                            child: CircularProgressIndicator(
                                color: Color(0xFFFC4C02))),
                      );
                    }
                    final activities = snap.data ?? [];
                    if (activities.isEmpty) {
                      return _buildEmptyActivities();
                    }

                    final displayedActivities =
                        activities.take(_myActivitiesLimit).toList();
                    final hasMore = activities.length > _myActivitiesLimit;

                    return Column(
                      children: [
                        ...displayedActivities.map((a) => _buildActivityCard(a,
                            ownerUid: uid, svc: svc)),
                        if (hasMore)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                            child: InkWell(
                              onTap: () {
                                setState(() {
                                  _myActivitiesLimit += 3;
                                });
                              },
                              borderRadius: BorderRadius.circular(16),
                              child: Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(
                                    vertical: 14, horizontal: 20),
                                decoration: BoxDecoration(
                                  color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.90),
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: const Color(0xFFFC4C02)
                                        .withValues(alpha: 0.3),
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(alpha: 0.03),
                                      blurRadius: 8,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Text(
                                      s.showMore,
                                      style: const TextStyle(
                                        color: Color(0xFFFC4C02),
                                        fontWeight: FontWeight.w700,
                                        fontSize: 14,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    const Icon(
                                      Icons.keyboard_arrow_down_rounded,
                                      color: Color(0xFFFC4C02),
                                      size: 20,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          )
                        else if (activities.length > 3)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                            child: TextButton.icon(
                              onPressed: () {
                                setState(() {
                                  _myActivitiesLimit = 3;
                                });
                              },
                              icon: Icon(Icons.keyboard_arrow_up_rounded,
                                  size: 18, color: pal.textMute),
                              label: Text(
                                s.showLess,
                                style: TextStyle(
                                  color: pal.textMute,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),


              const SliverToBoxAdapter(child: SizedBox(height: 100)),
            ],
          ),
        );
      }


  // ─── Last Run Card ──────────────────────────────────────

  String _formatTime(int totalSeconds) {
    final h = totalSeconds ~/ 3600;
    final m = (totalSeconds % 3600) ~/ 60;
    final s = totalSeconds % 60;
    if (h > 0) {
      return '${h}h ${m.toString().padLeft(2, '0')}m';
    }
    return '${m.toString().padLeft(2, '0')}m ${s.toString().padLeft(2, '0')}s';
  }

  String _formatPace(double secPerKm) {
    if (secPerKm <= 0) return '--:--';
    final m = secPerKm ~/ 60;
    final s = (secPerKm % 60).round();
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  Widget _buildLastRunCard(LastRunSummary run) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // คำนวณ center + zoom สำหรับ FlutterMap
    LatLng mapCenter = const LatLng(18.7883, 98.9853);
    double mapZoom = 14.0;
    if (run.routePoints.length >= 2) {
      double minLat = run.routePoints.first.latitude;
      double maxLat = run.routePoints.first.latitude;
      double minLng = run.routePoints.first.longitude;
      double maxLng = run.routePoints.first.longitude;
      for (final p in run.routePoints) {
        if (p.latitude < minLat) minLat = p.latitude;
        if (p.latitude > maxLat) maxLat = p.latitude;
        if (p.longitude < minLng) minLng = p.longitude;
        if (p.longitude > maxLng) maxLng = p.longitude;
      }
      mapCenter = LatLng((minLat + maxLat) / 2, (minLng + maxLng) / 2);
      final maxDiff = ((maxLat - minLat) > (maxLng - minLng))
          ? (maxLat - minLat)
          : (maxLng - minLng);
      if (maxDiff < 0.002) { mapZoom = 16.0; }
      else if (maxDiff < 0.005) { mapZoom = 15.0; }
      else if (maxDiff < 0.01) { mapZoom = 14.0; }
      else if (maxDiff < 0.05) { mapZoom = 13.0; }
      else if (maxDiff < 0.1) { mapZoom = 12.0; }
      else { mapZoom = 11.0; }
    }

    final s = AppStrings(isThai: context.read<LanguageProvider>().isThai);
    final isRunning = run.activityType == 'running';
    final actIcon = isRunning ? Icons.directions_run : Icons.directions_bike;
    final actLabel = isRunning ? s.runLabel : s.rideLabel;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFFC4C02).withValues(alpha: isDark ? 0.25 : 0.18),
            blurRadius: 20,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header gradient ─────────────────────────────
            Container(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFFFC4C02), Color(0xFFFF7043)],
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(actIcon, color: Colors.white, size: 18),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          run.title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            fontSize: 15,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          '$actLabel • ${s.justFinished}',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.8),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // badge "ล่าสุด"
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.22),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      s.latestBadge,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // ── Stats Row ────────────────────────────────────
            Container(
              color: pal.surface,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
              child: IntrinsicHeight(
                child: Row(
                  children: [
                    _lastRunStat(
                      s.distance,
                      run.distanceKm.toStringAsFixed(2),
                      'km',
                    ),
                    VerticalDivider(
                      color: pal.border,
                      thickness: 1,
                      indent: 6,
                      endIndent: 6,
                    ),
                    _lastRunStat(
                      s.pace,
                      _formatPace(run.paceSecPerKm),
                      '/km',
                    ),
                    VerticalDivider(
                      color: pal.border,
                      thickness: 1,
                      indent: 6,
                      endIndent: 6,
                    ),
                    _lastRunStat(
                      s.duration,
                      _formatTime(run.durationSeconds),
                      '',
                    ),
                  ],
                ),
              ),
            ),

            // ── Map ─────────────────────────────────────────
            if (run.routePoints.length >= 2)
              SizedBox(
                height: 200,
                child: FlutterMap(
                  options: MapOptions(
                    initialCenter: mapCenter,
                    initialZoom: mapZoom,
                    interactionOptions: const InteractionOptions(
                      flags: InteractiveFlag.pinchZoom | InteractiveFlag.drag,
                    ),
                  ),
                  children: [
                    TileLayer(
                      urlTemplate:
                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.example.demo20426',
                    ),
                    PolylineLayer(
                      polylines: [
                        Polyline(
                          points: run.routePoints,
                          color: const Color(0xFFFC4C02),
                          strokeWidth: 4.5,
                          strokeJoin: StrokeJoin.round,
                          strokeCap: StrokeCap.round,
                        ),
                      ],
                    ),
                    MarkerLayer(
                      markers: [
                        // จุดเริ่ม (เขียว)
                        Marker(
                          point: run.routePoints.first,
                          width: 26,
                          height: 26,
                          child: Container(
                            decoration: BoxDecoration(
                              color: const Color(0xFF1A9950),
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 2.5),
                              boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
                            ),
                            child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 13),
                          ),
                        ),
                        // จุดจบ (ส้ม)
                        Marker(
                          point: run.routePoints.last,
                          width: 26,
                          height: 26,
                          child: Container(
                            decoration: BoxDecoration(
                              color: const Color(0xFFFC4C02),
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 2.5),
                              boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
                            ),
                            child: const Icon(Icons.flag_rounded, color: Colors.white, size: 13),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              )
            else
              // ไม่มี GPS — แสดง placeholder
              Container(
                height: 100,
                color: pal.surface2,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.location_off_rounded, color: pal.textMute, size: 28),
                      const SizedBox(height: 6),
                      Text(s.noGpsData, style: TextStyle(color: pal.textMute, fontSize: 12)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }


  Widget _lastRunStat(String label, String value, String unit) {
    return Expanded(
      child: Column(
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              color: pal.textMute,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 2),
          RichText(
            text: TextSpan(
              children: [
                TextSpan(
                  text: value,
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    color: pal.text,
                  ),
                ),
                if (unit.isNotEmpty)
                  TextSpan(
                    text: ' $unit',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: pal.textSub,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─── Safety Banner ─────────────────────────────────────

  void _showAirQualityModal(BuildContext context) {
    final s = AppStrings(isThai: context.read<LanguageProvider>().isThai);
    final d = _airData;
    final aqiColor = d != null ? Color(d.aqiColorValue) : const Color(0xFF2ECC71);
    final now = d?.fetchedAt;
    final timeStr = now != null
        ? '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}'
        : '--:--';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) {
        return SingleChildScrollView(
          child: Container(
            decoration: BoxDecoration(
              color: pal.surface,
              borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            ),
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Handle bar
                Center(
                  child: Container(
                    width: 40, height: 4,
                    decoration: BoxDecoration(
                      color: pal.border,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                // Title
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: aqiColor.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(Icons.air, color: aqiColor, size: 24),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(s.currentAqiTitle,
                              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: Theme.of(context).colorScheme.onSurface)),
                          Text(
                            _loadingAir
                                ? s.loadingAqi
                                : '${s.isThai ? "ข้อมูลจาก" : "Source:"} Open-Meteo • ${s.isThai ? "อัปเดต" : "Updated"} $timeStr ${s.isThai ? "น." : ""}',
                            style: TextStyle(fontSize: 12, color: pal.textSub),
                          ),
                        ],
                      ),
                    ),
                    // Refresh button
                    GestureDetector(
                      onTap: () {
                        Navigator.pop(context);
                        setState(() { _loadingAir = true; _airError = null; });
                        _loadAirQuality();
                      },
                      child: Icon(Icons.refresh, color: pal.textMute, size: 22),
                    ),
                  ],
                ),
                const SizedBox(height: 24),

                if (_loadingAir)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.all(40),
                      child: CircularProgressIndicator(color: Color(0xFF2ECC71)),
                    ),
                  )
                else if (_airError != null)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        children: [
                          Icon(Icons.wifi_off, color: pal.textMute, size: 48),
                          const SizedBox(height: 12),
                          Text(s.errorLoadingData, style: TextStyle(color: pal.textSub, fontSize: 15)),
                          const SizedBox(height: 8),
                          Text(s.checkInternetConn,
                              style: TextStyle(color: pal.textMute, fontSize: 12)),
                        ],
                      ),
                    ),
                  )

                else ...[
                  // AQI Gauge
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          aqiColor.withValues(alpha: 0.15),
                          aqiColor.withValues(alpha: 0.03),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: aqiColor.withValues(alpha: 0.35)),
                    ),
                    child: Column(
                      children: [
                        Text(tr('AQI (สหรัฐฯ)', 'AQI (US)'), style: TextStyle(fontSize: 12, color: aqiColor.withValues(alpha: 0.7), fontWeight: FontWeight.w600)),
                        const SizedBox(height: 4),
                        Text('${d!.aqi}', style: TextStyle(fontSize: 56, fontWeight: FontWeight.w900, color: aqiColor)),
                        const SizedBox(height: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                          decoration: BoxDecoration(
                            color: aqiColor.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(d.aqiLabel, style: TextStyle(color: aqiColor, fontWeight: FontWeight.w700, fontSize: 13)),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'GPS: ${d.latitude.toStringAsFixed(4)}, ${d.longitude.toStringAsFixed(4)}',
                          style: TextStyle(fontSize: 10, color: pal.textMute),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Pollutant Details
                  Row(
                    children: [
                      Expanded(child: _buildPollutantCard('PM2.5', d.pm25.toStringAsFixed(1), 'µg/m³', Color(d.aqiColorValue))),
                      const SizedBox(width: 10),
                      Expanded(child: _buildPollutantCard('PM10', d.pm10.toStringAsFixed(1), 'µg/m³', const Color(0xFF3498DB))),
                      const SizedBox(width: 10),
                      Expanded(child: _buildPollutantCard('O₃', d.ozone.toStringAsFixed(1), 'µg/m³', const Color(0xFF9B59B6))),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Weather Details
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _buildWeatherItem(Icons.thermostat_rounded, '${d.temperature.toStringAsFixed(1)}°C', s.temperature),
                        _buildWeatherDivider(),
                        _buildWeatherItem(Icons.water_drop_outlined, '${d.humidity.toStringAsFixed(0)}%', s.humidity),
                        _buildWeatherDivider(),
                        _buildWeatherItem(Icons.air_rounded, '${d.windSpeedKmh.toStringAsFixed(1)} km/h', s.wind),
                        _buildWeatherDivider(),
                        _buildWeatherItem(Icons.visibility_rounded, '${d.visibilityKm.toStringAsFixed(1)} km', s.visibility),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Running Recommendation
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: aqiColor.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: aqiColor.withValues(alpha: 0.25)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.directions_run, color: aqiColor, size: 20),
                            const SizedBox(width: 8),
                            Text(s.runRecommendations,
                                style: TextStyle(color: aqiColor, fontWeight: FontWeight.w700, fontSize: 14)),
                          ],
                        ),
                        const SizedBox(height: 10),
                        ...d.runningRecommendations.map((rec) =>
                            _buildRecommendationItem(
                              d.needsMask ? Icons.warning_amber_rounded : Icons.check_circle,
                              rec,
                              color: d.needsMask ? const Color(0xFFE74C3C) : aqiColor,
                            )
                        ),
                        if (d.needsMask)
                          _buildRecommendationItem(
                            Icons.masks,
                            s.isThai ? 'แนะนำสวมหน้ากาก N95' : 'N95 mask recommended',
                            color: const Color(0xFFE74C3C),
                          ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 20),

                // Close Button
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(context),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFC4C02),
                      foregroundColor: Theme.of(context).colorScheme.surface,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      elevation: 0,
                    ),
                    child: Text(s.close, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                  ),
                ),

              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildPollutantCard(String name, String value, String unit, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Column(
        children: [
          Text(name, style: TextStyle(fontSize: 11, color: color.withValues(alpha: 0.8), fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: color)),
          Text(unit, style: TextStyle(fontSize: 10, color: pal.textMute)),
        ],
      ),
    );
  }

  Widget _buildWeatherItem(IconData icon, String value, String label) {
    return Column(
      children: [
        Icon(icon, color: pal.textSub, size: 22),
        const SizedBox(height: 6),
        Text(value, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: pal.text)),
        const SizedBox(height: 2),
        Text(label, style: TextStyle(fontSize: 10, color: pal.textMute)),
      ],
    );
  }

  Widget _buildWeatherDivider() =>
      Container(height: 36, width: 1, color: pal.border);

  Widget _buildRecommendationItem(IconData icon, String text, {Color? color}) {
    final c = color ?? const Color(0xFF2ECC71);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Icon(icon, size: 16, color: c),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(fontSize: 13, color: c.withValues(alpha: 0.85)))),
        ],
      ),
    );
  }

  Widget _buildSafetyBanner(BuildContext context) {
    final s = AppStrings(isThai: context.read<LanguageProvider>().isThai);
    final d = _airData;
    final aqiColor = d != null ? Color(d.aqiColorValue) : const Color(0xFF2ECC71);
    final titleText = _loadingAir
        ? (s.isThai ? 'กำลังโหลดข้อมูลอากาศ...' : 'Loading air quality data...')
        : _airError != null
            ? (s.isThai ? 'คุณภาพอากาศ: ไม่สามารถโหลดได้' : 'Air quality: Unable to load')
            : (s.isThai ? 'คุณภาพอากาศ: ${d!.aqiLabel}' : 'Air Quality: ${d!.aqiLabel}');
    final subtitleText = _loadingAir
        ? (s.isThai ? 'กำลังดึงข้อมูลตามตำแหน่งของคุณ' : 'Fetching data for your location')
        : _airError != null
            ? (s.isThai ? 'แตะเพื่อลองใหม่' : 'Tap to retry')
            : (s.isThai
                ? 'PM2.5: ${d!.pm25.toStringAsFixed(1)} µg/m³ • AQI: ${d.aqi} • แตะเพื่อดูรายละเอียด'
                : 'PM2.5: ${d!.pm25.toStringAsFixed(1)} µg/m³ • AQI: ${d.aqi} • Tap for details');

    return GestureDetector(
      onTap: _airError != null
          ? () {
              setState(() { _loadingAir = true; _airError = null; });
              _loadAirQuality();
            }
          : () => _showAirQualityModal(context),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 400),
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: aqiColor.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: aqiColor.withValues(alpha: 0.5), width: 1.5),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: aqiColor.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(12),
              ),
              child: _loadingAir
                  ? SizedBox(
                      width: 22, height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.5, color: aqiColor),
                    )
                  : Icon(
                      _airError != null ? Icons.wifi_off_rounded : Icons.air_rounded,
                      color: aqiColor, size: 22,
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(titleText,
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                          color: _airError != null
                              ? const Color(0xFFE67E22)
                              : Color(d?.aqiColorValue ?? 0xFF1A7A40))),
                  const SizedBox(height: 2),
                  Text(subtitleText,
                      style: TextStyle(fontSize: 11, color: pal.textSub)),
                ],
              ),
            ),
            Icon(
              _airError != null ? Icons.refresh_rounded : Icons.chevron_right,
              color: aqiColor,
            ),
          ],
        ),
      ),
    );
  }



  // ─── สถานที่วิ่งเพิ่มเติม (โซนที่ไม่มีเส้นทางยอดนิยมเดิม) ─────
  static const Set<String> _legacyRouteZoneIds = {
    'zone_moat', 'zone_buakhad', 'zone_huaytueng',
    'zone_cmu', 'zone_700yr', 'zone_suthep',
  };
  static final List<RunningZone> _extraZones = PresetZones.defaultZones
      .where((z) => !_legacyRouteZoneIds.contains(z.id))
      .toList();

  Widget _buildZonePlaceCard(RunningZone zone) {
    final s = AppStrings(isThai: context.read<LanguageProvider>().isThai);
    final cs = Theme.of(context).colorScheme;
    final isStadium = zone.category == 'stadium' || zone.category == 'track';
    final catLabel = isStadium ? tr('สนามกีฬา', 'Stadium') : tr('สวนสาธารณะ', 'Park');
    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => MapScreen(initialZoneId: zone.id),
          ),
        );
      },
      child: Container(
        width: 260,
        margin: const EdgeInsets.only(right: 12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
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
                  width: 32, height: 32,
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A9950).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(isStadium ? Icons.stadium : Icons.park,
                      color: const Color(0xFF1A9950), size: 18),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(zone.displayName,
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13.5,
                          color: cs.onSurface),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),
                const Icon(Icons.arrow_forward_ios_rounded,
                    size: 12, color: Color(0xFFFC4C02)),
              ],
            ),
            const SizedBox(height: 8),
            Text(zone.displayDescription,
                style: TextStyle(fontSize: 11, color: cs.onSurface.withValues(alpha: 0.55), height: 1.3),
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
            const Spacer(),
            Row(
              children: [
                _buildMiniStat(Icons.straighten,
                    '${zone.walkableLengthKm.toStringAsFixed(1)} km'),
                const SizedBox(width: 8),
                Flexible(child: _buildMiniStat(Icons.place_outlined, catLabel)),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFC4C02).withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.map_rounded, size: 11, color: Color(0xFFFC4C02)),
                      const SizedBox(width: 3),
                      Text(s.exploreMap,
                          style: const TextStyle(
                              fontSize: 10,
                              color: Color(0xFFFC4C02),
                              fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ─── Popular Route Card ─────────────────────────────────

  Widget _buildPopularRouteCard(RunningRoute route) {
    final s = AppStrings(isThai: context.read<LanguageProvider>().isThai);
    Color diffColor;
    String diffLabel;
    switch (route.difficulty) {
      case 'easy':
        diffColor = const Color(0xFF1A9950);
        diffLabel = s.easyDifficulty;
        break;
      case 'moderate':
        diffColor = const Color(0xFFD4881A);
        diffLabel = s.moderateDifficulty;
        break;
      case 'hard':
        diffColor = const Color(0xFFCC3333);
        diffLabel = s.hardDifficulty;
        break;
      default:
        diffColor = pal.textMute;
        diffLabel = route.difficulty;
    }

    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => MapScreen(initialRoute: route),
          ),
        );
      },
      child: Container(
        width: 260,
        margin: const EdgeInsets.only(right: 12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
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
                  width: 32, height: 32,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFC4C02).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.route,
                      color: Color(0xFFFC4C02), size: 18),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(s.isThai ? route.name : route.nameEn,
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13.5,
                          color: Theme.of(context).colorScheme.onSurface),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),
                const Icon(Icons.arrow_forward_ios_rounded,
                    size: 12, color: Color(0xFFFC4C02)),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                _buildMiniStat(Icons.straighten, '${route.distanceKm.toStringAsFixed(1)} km'),
                const SizedBox(width: 8),
                _buildMiniStat(Icons.timer_outlined, route.estimatedTime),
                const SizedBox(width: 8),
                _buildMiniStat(Icons.terrain, '\u2191${route.elevationGainM}m'),
              ],
            ),
            const Spacer(),
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                  decoration: BoxDecoration(
                    color: diffColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(diffLabel,
                      style: TextStyle(
                          fontSize: 10.5,
                          color: diffColor,
                          fontWeight: FontWeight.w700)),
                ),
                const SizedBox(width: 6),
                Icon(Icons.shield,
                    size: 13,
                    color: SafetyScoreEngine.scoreColor(route.safetyScore)),
                const SizedBox(width: 2),
                Text('${route.safetyScore}',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: SafetyScoreEngine.scoreColor(route.safetyScore))),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFC4C02).withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.map_rounded, size: 11, color: Color(0xFFFC4C02)),
                      const SizedBox(width: 3),
                      Text(s.exploreMap,
                          style: const TextStyle(
                              fontSize: 10,
                              color: Color(0xFFFC4C02),
                              fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMiniStat(IconData icon, String value) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: pal.textMute),
          const SizedBox(width: 3),
          Text(
            value,
            style: TextStyle(fontSize: 11, color: pal.textSub),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      );

  // ─── Empty State ────────────────────────────────────────

  Widget _buildEmptyActivities() {
    final s = AppStrings(isThai: context.read<LanguageProvider>().isThai);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Theme.of(context).colorScheme.outline),
      ),
      child: Column(
        children: [
          // Animated runner icon
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFFFC4C02).withValues(alpha: 0.08),
            ),
            child: const Icon(Icons.fitness_center,
                size: 44, color: Color(0xFFFC4C02)),
          ),
          const SizedBox(height: 20),
          Text(
            s.noMyActivities,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            s.myActivitiesPrompt,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: pal.textSub,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 24),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFFFC4C02),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.play_arrow_rounded,
                    color: Colors.white, size: 18),
                const SizedBox(width: 6),
                Text(s.pressRecordToStart,
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 13)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatPill(IconData icon, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 5),
          Text(value,
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w700, color: color)),
        ],
      ),
    );
  }

  Widget _buildTypeChip(String? type) {
    final s = AppStrings(isThai: context.read<LanguageProvider>().isThai);
    final isCycling = type == 'cycling';
    final color = isCycling ? const Color(0xFF27AE60) : const Color(0xFFFC4C02);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isCycling ? Icons.directions_bike : Icons.directions_run,
            size: 11,
            color: color,
          ),
          const SizedBox(width: 3),
          Text(
            isCycling ? s.cyclingLabel : s.runningLabel,
            style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: color),
          ),
        ],
      ),
    );
  }


  // ─── Route Map Preview (shared by Community & Activity cards) ──

  Widget _buildRouteMapPreview(List<Map<String, double>> rawPoints) {
    // แปลงจาก [{lat, lng}] → List<LatLng>
    final points = rawPoints
        .map((p) => LatLng(p['lat']!, p['lng']!))
        .toList();

    // คำนวณ center + zoom
    double minLat = points.first.latitude, maxLat = points.first.latitude;
    double minLng = points.first.longitude, maxLng = points.first.longitude;
    for (final p in points) {
      if (p.latitude < minLat) { minLat = p.latitude; }
      else if (p.latitude > maxLat) { maxLat = p.latitude; }
      if (p.longitude < minLng) { minLng = p.longitude; }
      else if (p.longitude > maxLng) { maxLng = p.longitude; }
    }
    final center = LatLng((minLat + maxLat) / 2, (minLng + maxLng) / 2);
    final maxDiff = (maxLat - minLat) > (maxLng - minLng)
        ? (maxLat - minLat)
        : (maxLng - minLng);
    double zoom;
    if (maxDiff < 0.002) { zoom = 16.0; }
    else if (maxDiff < 0.005) { zoom = 15.0; }
    else if (maxDiff < 0.01) { zoom = 14.0; }
    else if (maxDiff < 0.05) { zoom = 13.0; }
    else if (maxDiff < 0.1) { zoom = 12.0; }
    else { zoom = 11.0; }

    return ClipRRect(
      borderRadius: BorderRadius.zero,
      child: SizedBox(
        height: 180,
        child: FlutterMap(
          options: MapOptions(
            initialCenter: center,
            initialZoom: zoom,
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.pinchZoom | InteractiveFlag.drag,
            ),
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.example.demo20426',
            ),
            PolylineLayer(
              polylines: [
                Polyline(
                  points: points,
                  color: const Color(0xFFFC4C02),
                  strokeWidth: 4.0,
                  strokeJoin: StrokeJoin.round,
                  strokeCap: StrokeCap.round,
                ),
              ],
            ),
            MarkerLayer(
              markers: [
                // จุดเริ่ม (เขียว)
                Marker(
                  point: points.first,
                  width: 22, height: 22,
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF1A9950),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                      boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 3)],
                    ),
                    child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 11),
                  ),
                ),
                // จุดจบ (ส้ม)
                Marker(
                  point: points.last,
                  width: 22, height: 22,
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFFFC4C02),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                      boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 3)],
                    ),
                    child: const Icon(Icons.flag_rounded, color: Colors.white, size: 11),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ─── Community Card ─────────────────────────────────────

  Widget _buildCommunityCard(
      Activity a, String currentUid, FirestoreService svc) {
    final s = AppStrings(isThai: context.read<LanguageProvider>().isThai);

    final isOwner = a.uid == currentUid;
    final effectivePhoto = (isOwner && (_currentUserPhoto?.isNotEmpty ?? false))
        ? _currentUserPhoto
        : a.authorPhotoUrl;
    final showInitials = (effectivePhoto == null || effectivePhoto.isEmpty);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 14,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: const Color(0xFFFC4C02),
                  backgroundImage: _getAvatarImageProvider(effectivePhoto),
                  child: showInitials
                      ? Text(
                          (a.authorName?.isNotEmpty == true)
                              ? a.authorName![0].toUpperCase()
                              : 'R',
                          style: const TextStyle(
                              color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14))
                      : null,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        a.authorName ?? s.runner,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                            color: Theme.of(context).colorScheme.onSurface),
                      ),
                      Text(
                        a.isEdited
                            ? '${a.formattedDate} · ${tr('แก้ไขแล้ว', 'Edited')}'
                            : a.formattedDate,
                        style: TextStyle(fontSize: 11, color: pal.textMute),
                      ),
                    ],
                  ),
                ),
                if (isOwner)
                  GestureDetector(
                    onTap: () async {
                      if (a.id != null) {
                        await svc.setActivityPublic(a.uid, a.id!, !a.isPublic);
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFC4C02).withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(Icons.public_rounded,
                          size: 14, color: Color(0xFFFC4C02)),
                    ),
                  ),
                if (isOwner && a.id != null) ...[
                  const SizedBox(width: 6),
                  _editActivityButton(a, const Color(0xFFFC4C02)),
                ],
              ],
            ),
          ),

          // Title + type
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                Expanded(
                  child: Text(a.title,
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                          color: Theme.of(context).colorScheme.onSurface)),
                ),
                const SizedBox(width: 8),
                _buildTypeChip(a.activityType),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Stats pills
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                _buildStatPill(Icons.straighten_rounded,
                    '${a.distanceKm.toStringAsFixed(2)} km', const Color(0xFFFC4C02)),
                const SizedBox(width: 6),
                _buildStatPill(Icons.timer_outlined,
                    a.formattedDuration, const Color(0xFF3498DB)),
                const SizedBox(width: 6),
                _buildStatPill(Icons.speed_rounded,
                    a.formattedSpeed, const Color(0xFF9B59B6)),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // ─── Route Map Preview ─────────────────────
          if (a.routePoints.length >= 2)
            _buildRouteMapPreview(a.routePoints),

          // Like / Comment row
          StreamBuilder<List<ActivityComment>>(
            stream: a.id != null
                ? svc.getComments(a.id!, ownerUid: a.uid, isPublic: true)
                : const Stream.empty(),
            builder: (context, snap) {
              final count = snap.data?.length ?? a.commentsCount;
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(
                      color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.5),
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    _ActivityLikeButton(
                      activity: a,
                      currentUid: currentUid,
                      svc: svc,
                      isPublic: true,
                      iconSize: 18,
                      fontSize: 13,
                    ),
                    const SizedBox(width: 18),
                    GestureDetector(
                      onTap: () => _showCommentsModal(context, a, currentUid, svc),
                      child: Row(
                        children: [
                          Icon(Icons.chat_bubble_outline_rounded,
                              size: 17, color: pal.textMute),
                          const SizedBox(width: 5),
                          Text(count > 0 ? '$count' : s.commentsLabel,
                              style: TextStyle(
                                  color: pal.textMute, fontSize: 13, fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  // --- Activity Card (My Activities) ---

  /// ปุ่มแก้ไขกิจกรรมของตัวเอง (ชื่อ / การมองเห็น / ระยะทาง / เวลา)
  Widget _editActivityButton(Activity a, Color color) {
    return Tooltip(
      message: tr('แก้ไขกิจกรรม', 'Edit activity'),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => showActivityEditSheet(context, a),
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(Icons.edit_rounded, size: 14, color: color),
        ),
      ),
    );
  }

  Widget _buildActivityCard(Activity a,
      {String? ownerUid, FirestoreService? svc}) {
    final s = AppStrings(isThai: context.read<LanguageProvider>().isThai);
    final currentUid = ownerUid ?? a.uid;
    final isCycling = a.activityType == 'cycling';
    final accentColor = isCycling ? const Color(0xFF27AE60) : const Color(0xFFFC4C02);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: 4,
              decoration: BoxDecoration(
                color: accentColor,
                borderRadius: const BorderRadius.horizontal(left: Radius.circular(18)),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 14, 14, 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(a.title,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 15,
                                      color: Theme.of(context).colorScheme.onSurface)),
                              const SizedBox(height: 3),
                              Text(
                                  a.isEdited
                                      ? '${a.formattedDate} · ${tr('แก้ไขแล้ว', 'Edited')}'
                                      : a.formattedDate,
                                  style: TextStyle(
                                      fontSize: 11, color: pal.textMute)),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        _buildTypeChip(a.activityType),
                        const SizedBox(width: 8),
                        GestureDetector(
                          onTap: (svc != null && a.id != null)
                              ? () async {
                                  await svc.setActivityPublic(a.uid, a.id!, !a.isPublic);
                                }
                              : null,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                            decoration: BoxDecoration(
                              color: a.isPublic
                                  ? accentColor.withValues(alpha: 0.08)
                                  : pal.surface2,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  a.isPublic ? Icons.public_rounded : Icons.lock_rounded,
                                  size: 11,
                                  color: a.isPublic ? accentColor : pal.textMute,
                                ),
                                const SizedBox(width: 3),
                                Text(
                                  a.isPublic ? s.publicLabel : s.privateLabel,
                                  style: TextStyle(
                                      fontSize: 10,
                                      color: a.isPublic ? accentColor : pal.textMute,
                                      fontWeight: FontWeight.w600),
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (svc != null && a.id != null) ...[
                          const SizedBox(width: 4),
                          _editActivityButton(a, accentColor),
                        ],
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          a.distanceKm.toStringAsFixed(2),
                          style: TextStyle(
                              fontSize: 32,
                              fontWeight: FontWeight.w900,
                              color: accentColor,
                              height: 1.0),
                        ),
                        Padding(
                          padding: EdgeInsets.only(bottom: 4, left: 3),
                          child: Text('km',
                              style: TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w600,
                                  color: pal.textMute)),
                        ),
                        const Spacer(),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(a.formattedDuration,
                                style: TextStyle(
                                    fontSize: 14, fontWeight: FontWeight.w700,
                                    color: pal.textSub)),
                            Text(s.duration,
                                style: TextStyle(
                                    fontSize: 10, color: pal.textMute)),
                          ],
                        ),
                        const SizedBox(width: 16),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(a.formattedSpeed,
                                style: TextStyle(
                                    fontSize: 14, fontWeight: FontWeight.w700,
                                    color: pal.textSub)),
                            Text(s.speedLabel,
                                style: TextStyle(
                                    fontSize: 10, color: pal.textMute)),
                          ],
                        ),
                      ],
                    ),
                  ),

                  // ─── Route Map Preview ─────────────────────
                  if (a.routePoints.length >= 2)
                    _buildRouteMapPreview(a.routePoints),

                  StreamBuilder<List<ActivityComment>>(
                    stream: (a.isPublic && svc != null && a.id != null)
                        ? svc.getComments(a.id!, ownerUid: a.uid, isPublic: a.isPublic)
                        : const Stream.empty(),
                    builder: (context, snap) {
                      final count = snap.data?.length ?? a.commentsCount;
                      return Container(
                        margin: const EdgeInsets.only(top: 10),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                        decoration: BoxDecoration(
                          border: Border(
                            top: BorderSide(
                              color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.5),
                            ),
                          ),
                        ),
                        child: Row(
                          children: [
                            _ActivityLikeButton(
                              activity: a,
                              currentUid: currentUid,
                              svc: svc,
                              isPublic: a.isPublic,
                              iconSize: 17,
                              fontSize: 12,
                            ),
                            const SizedBox(width: 16),
                            GestureDetector(
                              onTap: a.isPublic && svc != null
                                  ? () => _showCommentsModal(context, a, currentUid, svc)
                                  : null,
                              child: Row(
                                children: [
                                  Icon(Icons.chat_bubble_outline_rounded,
                                      size: 16,
                                      color: a.isPublic ? pal.textMute : pal.border),
                                  const SizedBox(width: 4),
                                  Text(
                                    a.isPublic
                                        ? (count > 0 ? '$count' : s.commentsLabel)
                                        : s.privateLabel,
                                    style: TextStyle(
                                        color: a.isPublic ? pal.textMute : pal.border,
                                        fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }



  // ─── Comments Modal ──────────────────────────────────────

  void _showCommentsModal(BuildContext context, Activity activity,
      String currentUid, FirestoreService svc) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _CommentsModal(
        activity: activity,
        currentUid: currentUid,
        currentUserPhoto: _currentUserPhoto,
        svc: svc,
      ),
    );
  }



  // ─── Notifications Modal ────────────────────────────────

  void _showNotificationsModal(BuildContext context) {
    final s = AppStrings(isThai: context.read<LanguageProvider>().isThai);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => Consumer<NotificationProvider>(
        builder: (ctx, notifProv, _) {
          final notifications = notifProv.notifications;
          final unread = notifProv.unreadCount;
          return Container(
            height: MediaQuery.of(context).size.height * 0.75,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            ),
            child: Column(
              children: [
                // Handle bar
                Center(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 12, bottom: 4),
                    child: Container(
                      width: 40, height: 4,
                      decoration: BoxDecoration(
                        color: Colors.black12,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),

                // Header
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 8, 8),
                  child: Row(
                    children: [
                      Text(
                        s.notifications,
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                      if (unread > 0) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFC4C02),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            '$unread ${s.newItems}',
                            style: TextStyle(color: Theme.of(context).colorScheme.surface, fontSize: 12, fontWeight: FontWeight.w700),
                          ),
                        ),
                      ],
                      const Spacer(),
                      TextButton(
                        onPressed: () {
                          notifProv.markAllAsRead();
                        },
                        child: Text(
                          s.markAllRead,
                          style: const TextStyle(color: Color(0xFFFC4C02), fontSize: 13, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),

                Divider(height: 1, color: pal.border),

                // Notification List
                Expanded(
                  child: notifications.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.notifications_off_outlined, size: 64, color: pal.textMute),
                              const SizedBox(height: 16),
                              Text(s.noNotifications,
                                  style: TextStyle(fontSize: 16, color: pal.textMute, fontWeight: FontWeight.w600)),
                            ],
                          ),
                        )
                      : ListView.separated(
                          padding: EdgeInsets.zero,
                          itemCount: notifications.length,
                          separatorBuilder: (_, _) => Divider(height: 1, indent: 68, color: pal.border),
                          itemBuilder: (_, i) {
                            final n = notifications[i];
                            return Dismissible(
                              key: Key(n.id),
                              direction: DismissDirection.endToStart,
                              background: Container(
                                color: const Color(0xFFE74C3C),
                                alignment: Alignment.centerRight,
                                padding: const EdgeInsets.only(right: 20),
                                child: const Icon(Icons.delete_outline, color: Colors.white),
                              ),
                              onDismissed: (_) {
                                notifProv.removeNotification(n.id);
                              },
                              child: InkWell(
                                onTap: () {
                                  notifProv.markAsRead(n.id);
                                  // ถ้าเป็น incident notification หรือ route → ปิด modal แล้ว navigate ไปหน้า Map
                                  if (n.incidentReport != null || n.type == NotificationType.incident) {
                                    Navigator.pop(context);
                                    widget.onNavigateToMap?.call();
                                  } else if (n.type == NotificationType.route) {
                                    Navigator.pop(context);
                                    widget.onNavigateToMap?.call();
                                  }
                                },
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 300),
                                  color: n.isRead
                                      ? Colors.transparent
                                      : (Theme.of(context).brightness == Brightness.dark
                                          ? const Color(0xFFFC4C02).withValues(alpha: 0.12)
                                          : const Color(0xFFFC4C02).withValues(alpha: 0.05)),
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                                  child: Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      // Icon
                                      Container(
                                        width: 44,
                                        height: 44,
                                        decoration: BoxDecoration(
                                          color: n.iconColor.withValues(alpha: 0.12),
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                        child: Icon(n.icon, color: n.iconColor, size: 22),
                                      ),
                                      const SizedBox(width: 12),
                                      // Text
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              children: [
                                                Expanded(
                                                  child: Text(
                                                    n.getTitle(s.isThai),
                                                    style: TextStyle(
                                                      fontSize: 14,
                                                      fontWeight: n.isRead ? FontWeight.w500 : FontWeight.w700,
                                                      color: Theme.of(context).colorScheme.onSurface,
                                                    ),
                                                  ),
                                                ),
                                                if (!n.isRead)
                                                  Container(
                                                    width: 8, height: 8,
                                                    decoration: const BoxDecoration(
                                                      color: Color(0xFFFC4C02),
                                                      shape: BoxShape.circle,
                                                    ),
                                                  ),
                                              ],
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              n.getSubtitle(s.isThai),
                                              style: TextStyle(fontSize: 12, color: pal.textSub, height: 1.4),
                                            ),
                                            const SizedBox(height: 6),
                                            Text(
                                              n.getTime(s.isThai),
                                              style: TextStyle(fontSize: 11, color: pal.textMute),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                ),

                // Footer hint
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                  child: Text(
                    s.swipeToDeleteNotification,
                    style: TextStyle(fontSize: 11, color: pal.textMute),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

}

// ─── Avatar Image Provider Helper ─────────────────────────

ImageProvider? _getAvatarImageProvider(String? photoUrl) {
  if (photoUrl == null || photoUrl.isEmpty) return null;
  if (photoUrl.startsWith('data:image')) {
    try {
      final base64String =
          photoUrl.contains(',') ? photoUrl.split(',').last : photoUrl;
      return MemoryImage(base64Decode(base64String));
    } catch (_) {
      return null;
    }
  }
  if (photoUrl.startsWith('http://') || photoUrl.startsWith('https://')) {
    return NetworkImage(photoUrl);
  }
  return null;
}


// ─── Comments Modal Widget ────────────────────────────────

class _CommentsModal extends StatefulWidget {
  final Activity activity;
  final String currentUid;
  final String? currentUserPhoto;
  final FirestoreService svc;

  const _CommentsModal({
    required this.activity,
    required this.currentUid,
    this.currentUserPhoto,
    required this.svc,
  });

  @override
  State<_CommentsModal> createState() => _CommentsModalState();
}

class _CommentsModalState extends State<_CommentsModal> {
  /// สีพื้น/ตัวอักษรตามธีมปัจจุบัน
  AppPalette get pal => context.pal;

  final _commentCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  bool _isSending = false;

  @override
  void dispose() {
    _commentCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _sendComment() async {
    final text = _commentCtrl.text.trim();
    if (text.isEmpty || widget.activity.id == null || _isSending) return;

    setState(() => _isSending = true);
    _commentCtrl.clear();

    final s = AppStrings(isThai: context.read<LanguageProvider>().isThai);
    final user = FirebaseAuth.instance.currentUser;
    final comment = ActivityComment(
      uid: widget.currentUid,
      authorName: user?.displayName ?? s.runner,
      authorPhotoUrl: (widget.currentUserPhoto?.isNotEmpty ?? false)
          ? widget.currentUserPhoto
          : user?.photoURL,
      text: text,
      createdAt: DateTime.now(),
    );

    try {
      await widget.svc.addComment(
        widget.activity.id!,
        comment,
        ownerUid: widget.activity.uid,
        isPublic: widget.activity.isPublic,
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollCtrl.hasClients) {
          _scrollCtrl.animateTo(
            _scrollCtrl.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${s.isThai ? "ส่งไม่สำเร็จ" : "Failed to send"}: $e'),
            backgroundColor: Colors.red,
          ),
        );
        _commentCtrl.text = text;
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings(isThai: context.read<LanguageProvider>().isThai);
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      minChildSize: 0.4,
      builder: (ctx, _) => Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Column(
          children: [
            Center(
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 12),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.black12,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Row(
                children: [
                  Text(s.commentsLabel,
                      style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: Theme.of(context).colorScheme.onSurface)),
                  const Spacer(),
                  IconButton(
                    icon: Icon(Icons.close, color: pal.textMute),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: StreamBuilder<List<ActivityComment>>(
                stream: widget.activity.id != null
                    ? widget.svc.getComments(
                        widget.activity.id!,
                        ownerUid: widget.activity.uid,
                        isPublic: widget.activity.isPublic,
                      )
                    : const Stream.empty(),
                builder: (ctx, snap) {
                  if (snap.connectionState == ConnectionState.waiting) {
                    return const Center(
                      child: CircularProgressIndicator(
                          color: Color(0xFFFC4C02)),
                    );
                  }
                  if (snap.hasError) {
                    return Center(
                      child: Text(tr('เกิดข้อผิดพลาด กรุณาลองอีกครั้ง', 'Error:\n${snap.error}'),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: Colors.red, fontSize: 12)),
                    );
                  }
                  final comments = snap.data ?? [];
                  if (comments.isEmpty) {
                    // SingleChildScrollView: เมื่อคีย์บอร์ดเปิด พื้นที่เหลือน้อย → เดิม BOTTOM OVERFLOWED 20 px
                    return Center(
                      child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.chat_bubble_outline,
                              size: 48, color: pal.border),
                          const SizedBox(height: 12),
                          Text(s.noCommentsYet,
                              style: TextStyle(
                                  color: pal.textMute,
                                  fontWeight: FontWeight.w600)),
                          const SizedBox(height: 4),
                          Text(s.beFirstToComment,
                              style: TextStyle(
                                  fontSize: 12, color: pal.textMute)),
                        ],
                      ),
                      ),
                    );
                  }
                  return ListView.separated(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    itemCount: comments.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemBuilder: (_, i) {
                      final c = comments[i];
                      final isCurrent = c.uid == widget.currentUid;
                      final effectiveCommentPhoto = (isCurrent && (widget.currentUserPhoto?.isNotEmpty ?? false))
                          ? widget.currentUserPhoto
                          : c.authorPhotoUrl;
                      final showCommentInitials = (effectiveCommentPhoto == null || effectiveCommentPhoto.isEmpty);

                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          CircleAvatar(
                            radius: 16,
                            backgroundColor: const Color(0xFFFC4C02),
                            backgroundImage: _getAvatarImageProvider(effectiveCommentPhoto),
                            child: showCommentInitials
                                ? Text(
                                    c.authorName.isNotEmpty
                                        ? c.authorName[0].toUpperCase()
                                        : 'R',
                                    style: TextStyle(color: Theme.of(context).colorScheme.surface,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700),
                                  )
                                : null,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 8),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.surface,
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(c.authorName,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                                fontWeight: FontWeight.w700,
                                                fontSize: 13,
                                                color: Theme.of(context).colorScheme.onSurface)),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(c.timeAgo,
                                          style: TextStyle(
                                              fontSize: 10,
                                              color: pal.textMute)),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Text(c.text,
                                      style: TextStyle(
                                          fontSize: 13,
                                          color: pal.text)),
                                ],
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  );
                },
              ),
            ),
            Builder(
              builder: (bCtx) => Container(
                padding: EdgeInsets.only(
                  left: 16,
                  right: 16,
                  top: 8,
                  bottom: MediaQuery.of(bCtx).viewInsets.bottom + 16,
                ),
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: pal.border)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _commentCtrl,
                        decoration: InputDecoration(
                          hintText: s.writeCommentHint,
                          hintStyle:
                              TextStyle(color: pal.textMute),
                          filled: true,
                          fillColor: Theme.of(context).colorScheme.surface,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 10),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(24),
                            borderSide: BorderSide.none,
                          ),
                        ),
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _sendComment(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: _sendComment,
                      child: Container(
                        width: 42,
                        height: 42,
                        decoration: const BoxDecoration(
                          color: Color(0xFFFC4C02),
                          shape: BoxShape.circle,
                        ),
                        child: _isSending
                            ? const Padding(
                                padding: EdgeInsets.all(11),
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              )
                            : const Icon(Icons.send_rounded,
                                color: Colors.white, size: 20),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Interactive Optimistic Like Button ──────────────────────

class _ActivityLikeButton extends StatefulWidget {
  final Activity activity;
  final String currentUid;
  final FirestoreService? svc;
  final bool isPublic;
  final double iconSize;
  final double fontSize;

  const _ActivityLikeButton({
    required this.activity,
    required this.currentUid,
    required this.svc,
    this.isPublic = true,
    this.iconSize = 18,
    this.fontSize = 13,
  });

  @override
  State<_ActivityLikeButton> createState() => _ActivityLikeButtonState();
}

class _ActivityLikeButtonState extends State<_ActivityLikeButton>
    with SingleTickerProviderStateMixin {
  /// สีพื้น/ตัวอักษรตามธีมปัจจุบัน
  AppPalette get pal => context.pal;

  late bool _isLiked;
  late int _likesCount;
  bool _isToggling = false;
  late AnimationController _animController;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _isLiked = widget.activity.likedBy.contains(widget.currentUid);
    _likesCount = widget.activity.likesCount;
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _scaleAnimation = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.35), weight: 50),
      TweenSequenceItem(tween: Tween(begin: 1.35, end: 1.0), weight: 50),
    ]).animate(CurvedAnimation(parent: _animController, curve: Curves.easeInOut));
  }

  @override
  void didUpdateWidget(covariant _ActivityLikeButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_isToggling) {
      _isLiked = widget.activity.likedBy.contains(widget.currentUid);
      _likesCount = widget.activity.likesCount;
    }
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  Future<void> _handleTap() async {
    if (widget.currentUid.isEmpty) {
      final isThai = context.read<LanguageProvider>().isThai;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(isThai ? 'กรุณาเข้าสู่ระบบก่อนกดถูกใจ' : 'Please sign in to like'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }

    if (widget.svc == null || widget.activity.id == null || _isToggling) return;

    HapticFeedback.lightImpact();

    final prevLiked = _isLiked;
    final prevCount = _likesCount;

    setState(() {
      _isToggling = true;
      _isLiked = !_isLiked;
      _likesCount = _isLiked ? _likesCount + 1 : (_likesCount > 0 ? _likesCount - 1 : 0);
    });

    _animController.forward(from: 0.0);

    try {
      await widget.svc!.toggleLike(
        widget.activity.id!,
        widget.currentUid,
        widget.activity.uid,
        isPublic: widget.isPublic,
      );
    } catch (e) {
      debugPrint('[LikeButton] Error toggling like: $e');
      if (mounted) {
        setState(() {
          _isLiked = prevLiked;
          _likesCount = prevCount;
        });
        final isThai = context.read<LanguageProvider>().isThai;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(isThai ? 'กดถูกใจไม่สำเร็จ: $e' : 'Failed to like: $e'),
            backgroundColor: Colors.red.shade700,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isToggling = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _handleTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ScaleTransition(
              scale: _scaleAnimation,
              child: Icon(
                _isLiked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                size: widget.iconSize,
                color: _isLiked ? const Color(0xFFE74C3C) : pal.textMute,
              ),
            ),
            const SizedBox(width: 5),
            Text(
              '$_likesCount',
              style: TextStyle(
                color: _isLiked ? const Color(0xFFE74C3C) : pal.textMute,
                fontSize: widget.fontSize,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
