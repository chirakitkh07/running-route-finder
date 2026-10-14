import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/activity.dart';
import '../models/incident_report.dart';
import '../models/route_data.dart';
import 'zone_popularity_service.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../l10n/tr.dart';

/// Service สำหรับอ่าน/เขียนข้อมูลกิจกรรมวิ่งใน Firestore
class FirestoreService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  /// Path: users/{uid}/activities (private per-user)
  CollectionReference<Map<String, dynamic>> _userActivitiesRef(String uid) =>
      _db.collection('users').doc(uid).collection('activities');

  /// Path: activities (top-level — สำหรับ community feed)
  CollectionReference<Map<String, dynamic>> get _globalActivitiesRef =>
      _db.collection('activities');

  /// Path: users/{uid} (user profile document)
  DocumentReference<Map<String, dynamic>> _userProfileRef(String uid) =>
      _db.collection('users').doc(uid);

  // ─── USER PROFILE ────────────────────────────────────────

  /// บันทึก/อัปเดต User Profile ลง Firestore เมื่อสมัครสมาชิกหรือ Sign-In ครั้งแรก
  /// ใช้ merge: true เพื่อไม่ทับข้อมูลเดิม
  Future<void> saveUserProfile(User user, {String? displayName}) async {
    try {
      final data = <String, dynamic>{
        'uid': user.uid,
        'email': user.email ?? '',
        'displayName': displayName ?? user.displayName ?? '',
        'photoUrl': user.photoURL ?? '',
        'updatedAt': FieldValue.serverTimestamp(),
      };

      // createdAt เซ็ตครั้งแรกเท่านั้น (ไม่ทับถ้ามีอยู่แล้ว)
      final docSnap = await _userProfileRef(user.uid).get();
      if (!docSnap.exists) {
        data['createdAt'] = FieldValue.serverTimestamp();
      }

      await _userProfileRef(user.uid).set(data, SetOptions(merge: true));
      debugPrint('[Firestore] ✅ saveUserProfile uid=${user.uid}');
    } catch (e) {
      debugPrint('[Firestore] ⚠️ saveUserProfile ล้มเหลว: $e');
      // non-blocking — ไม่ rethrow เพื่อให้แอปยังใช้งานได้
    }
  }

  /// ดึง User Profile จาก Firestore
  Future<Map<String, dynamic>?> getUserProfile(String uid) async {
    try {
      final snap = await _userProfileRef(uid).get();
      return snap.exists ? snap.data() : null;
    } catch (e) {
      debugPrint('[Firestore] ⚠️ getUserProfile ล้มเหลว: $e');
      return null;
    }
  }

  /// อัปเดตรูปโปรไฟล์ authorPhotoUrl ในกิจกรรมทั้งหมดของผู้ใช้ (ทั้ง user subcollection และ global)
  Future<void> updateUserActivitiesPhoto(String uid, String photoUrl) async {
    if (uid.isEmpty) return;
    try {
      // 1. อัปเดตใน user subcollection
      final userActivities = await _userActivitiesRef(uid).get();
      for (final doc in userActivities.docs) {
        await doc.reference.update({'authorPhotoUrl': photoUrl});
      }

      // 2. อัปเดตใน global activities
      final globalActivities =
          await _globalActivitiesRef.where('uid', isEqualTo: uid).get();
      for (final doc in globalActivities.docs) {
        await doc.reference.update({'authorPhotoUrl': photoUrl});
      }
      debugPrint('[Firestore] ✅ updateUserActivitiesPhoto สำเร็จ (${userActivities.docs.length} user docs, ${globalActivities.docs.length} global docs)');
    } catch (e) {
      debugPrint('[Firestore] ⚠️ updateUserActivitiesPhoto ล้มเหลว: $e');
    }
  }

  // ─── WRITE ──────────────────────────────────────────────

  /// บันทึกกิจกรรมใหม่ — เขียน user subcollection ก่อน แล้วค่อย global (best-effort)
  Future<void> saveActivity(Activity activity) async {
    debugPrint('[Firestore] saveActivity → uid=${activity.uid}');
    debugPrint('[Firestore] path → users/${activity.uid}/activities');

    // 1. user subcollection (สำคัญสุด — profile/stats ของตัวเอง)
    final userRef = _userActivitiesRef(activity.uid).doc();
    try {
      await userRef.set(activity.toMap());
      debugPrint('[Firestore] ✅ save สำเร็จ docId=${userRef.id}');
    } catch (e) {
      debugPrint('[Firestore] ❌ save ล้มเหลว: $e');
      rethrow;
    }

    // 2. global collection (community feed — best effort ถ้า public)
    if (activity.isPublic) {
      try {
        final globalRef = _globalActivitiesRef.doc(userRef.id);
        await globalRef.set({...activity.toMap(), 'userActivityId': userRef.id});
        debugPrint('[Firestore] ✅ sync to global สำเร็จ');
      } catch (e) {
        debugPrint('[Firestore] ⚠️ global write ล้มเหลว (non-blocking): $e');
      }

      // 3. crowdsourced zone popularity stats (S_pop) — non-blocking
      if (activity.routePoints.isNotEmpty) {
        ZonePopularityService.recordActivityZones(activity)
            .catchError((e) => debugPrint('[Firestore] Zone popularity recording error: $e'));
      }
    }
  }

  /// toggle Public/Private ของกิจกรรม
  Future<void> setActivityPublic(
      String uid, String activityId, bool isPublic) async {
    // อัปเดต user subcollection
    await _userActivitiesRef(uid)
        .doc(activityId)
        .update({'isPublic': isPublic});

    // เพิ่ม/ลบใน global collection
    final globalRef = _globalActivitiesRef.doc(activityId);
    if (isPublic) {
      final snap = await _userActivitiesRef(uid).doc(activityId).get();
      if (snap.exists) {
        await globalRef.set({...snap.data()!, 'userActivityId': activityId});
      }
    } else {
      await globalRef.delete();
    }
  }

  /// แก้ไขกิจกรรมย้อนหลัง: ชื่อ / การมองเห็น / ระยะทาง / เวลา (เพซคำนวณใหม่)
  /// ไม่แตะ routePoints, startedAt, likes, comments — เส้นทางที่วิ่งไปแล้วคงเดิม
  /// ครั้งแรกที่แก้สถิติจะเก็บค่าจริงจาก GPS ไว้ใน `originalStats` (คืนค่าได้)
  Future<void> updateActivityDetails(
    String uid,
    String activityId, {
    required String title,
    required bool isPublic,
    required double distanceKm,
    required int durationSeconds,
  }) async {
    final userRef = _userActivitiesRef(uid).doc(activityId);
    final snap = await userRef.get();
    if (!snap.exists) {
      throw Exception(tr('ไม่พบกิจกรรมนี้', 'Activity not found'));
    }
    final old = snap.data()!;
    final pace = distanceKm > 0 ? durationSeconds / distanceKm : 0.0;
    final oldDist = (old['distanceKm'] as num?)?.toDouble() ?? 0;
    final oldDur = (old['durationSeconds'] as num?)?.toInt() ?? 0;
    final statsChanged =
        (oldDist - distanceKm).abs() > 0.0005 || oldDur != durationSeconds;

    final fields = <String, dynamic>{
      'title': title.trim(),
      'isPublic': isPublic,
      'distanceKm': distanceKm,
      'durationSeconds': durationSeconds,
      'avgPaceSecPerKm': pace,
      'editedAt': FieldValue.serverTimestamp(),
      if (statsChanged && old['originalStats'] == null)
        'originalStats': {
          'distanceKm': oldDist,
          'durationSeconds': oldDur,
          'avgPaceSecPerKm': (old['avgPaceSecPerKm'] as num?)?.toDouble() ?? 0,
        },
    };
    await userRef.update(fields);

    // global feed: สาธารณะ → อัปเดต/สร้าง, ส่วนตัว → ลบออกจากฟีด
    final globalRef = _globalActivitiesRef.doc(activityId);
    if (isPublic) {
      final globalSnap = await globalRef.get();
      if (globalSnap.exists) {
        // อัปเดตเฉพาะ field ที่แก้ (ไม่ทับ likes/comments ในฟีด)
        await globalRef.update(fields);
      } else {
        final fresh = await userRef.get();
        await globalRef.set({...fresh.data()!, 'userActivityId': activityId});
      }
    } else if (old['isPublic'] == true) {
      await globalRef.delete();
    }
  }

  /// Toggle Like — อัปเดต likedBy/likesCount ใน global collection (public)
  /// หรือ user subcollection (private)
  Future<void> toggleLike(
    String activityId,
    String currentUid,
    String activityOwnerUid, {
    bool isPublic = true,
  }) async {
    if (currentUid.isEmpty) {
      debugPrint('[Firestore] ⚠️ toggleLike: currentUid ว่างเปล่า!');
      return;
    }

    final globalRef = _globalActivitiesRef.doc(activityId);
    final userRef = _userActivitiesRef(activityOwnerUid).doc(activityId);

    Future<void> doToggle(DocumentReference<Map<String, dynamic>> ref) async {
      try {
        final snap = await ref.get();
        if (!snap.exists) {
          debugPrint('[Firestore] ⚠️ doToggle: ${ref.path} does not exist');
          return;
        }
        final data = snap.data() ?? {};
        final likedBy = List<String>.from(data['likedBy'] ?? []);
        if (likedBy.contains(currentUid)) {
          likedBy.remove(currentUid);
        } else {
          likedBy.add(currentUid);
        }
        await ref.update({'likedBy': likedBy, 'likesCount': likedBy.length});
        debugPrint('[Firestore] ✅ toggleLike updated ${ref.path} (likes: ${likedBy.length})');
      } catch (e) {
        debugPrint('[Firestore] ⚠️ direct update failed on ${ref.path}, trying transaction: $e');
        await _db.runTransaction((tx) async {
          final snap = await tx.get(ref);
          if (!snap.exists) return;
          final data = snap.data() ?? {};
          final likedBy = List<String>.from(data['likedBy'] ?? []);
          if (likedBy.contains(currentUid)) {
            likedBy.remove(currentUid);
          } else {
            likedBy.add(currentUid);
          }
          tx.update(ref, {'likedBy': likedBy, 'likesCount': likedBy.length});
        });
      }
    }

    if (isPublic) {
      await doToggle(globalRef);
      // sync user subcollection ด้วย (best effort)
      try { await doToggle(userRef); } catch (_) {}
    } else {
      await doToggle(userRef);
    }
  }

  /// เพิ่ม comment ตาม isPublic และอัปเดตจำนวน commentsCount
  Future<void> addComment(
    String activityId,
    ActivityComment comment, {
    String? ownerUid,
    bool isPublic = true,
  }) async {
    if (isPublic) {
      final globalDoc = _globalActivitiesRef.doc(activityId);
      await globalDoc.collection('comments').add(comment.toMap());
      await globalDoc.update({'commentsCount': FieldValue.increment(1)});
      if (ownerUid != null) {
        try {
          await _userActivitiesRef(ownerUid)
              .doc(activityId)
              .update({'commentsCount': FieldValue.increment(1)});
        } catch (_) {}
      }
    } else if (ownerUid != null) {
      final userDoc = _userActivitiesRef(ownerUid).doc(activityId);
      await userDoc.collection('comments').add(comment.toMap());
      await userDoc.update({'commentsCount': FieldValue.increment(1)});
    } else {
      throw Exception(tr('ไม่พบกิจกรรมนี้', 'Activity not found'));
    }
  }

  /// Stream comments ของกิจกรรม (รองรับทั้ง global และ user subcollection)
  Stream<List<ActivityComment>> getComments(
    String activityId, {
    String? ownerUid,
    bool isPublic = true,
  }) {
    final ref = (isPublic || ownerUid == null)
        ? _globalActivitiesRef.doc(activityId)
        : _userActivitiesRef(ownerUid).doc(activityId);

    return ref
        .collection('comments')
        .orderBy('createdAt', descending: false)
        .snapshots()
        .map((snap) => snap.docs
            .map((d) => ActivityComment.fromMap(d.data(), d.id))
            .toList());
  }

  // ─── READ ───────────────────────────────────────────────

  /// Stream กิจกรรมล่าสุดทั้งหมดของ user (realtime)
  Stream<List<Activity>> getUserActivities(String uid) {
    debugPrint('[Firestore] getUserActivities → uid="$uid"');
    if (uid.isEmpty) {
      debugPrint('[Firestore] ⚠️ uid ว่างเปล่า! จะไม่ได้ข้อมูล');
      return Stream.value([]);
    }
    return _userActivitiesRef(uid)
        .orderBy('startedAt', descending: true)
        .limit(20)
        .snapshots()
        .map((snap) {
          debugPrint('[Firestore] getUserActivities ✅ got ${snap.docs.length} docs');
          return snap.docs.map((d) => Activity.fromMap(d.data(), d.id)).toList();
        })
        .handleError((e) {
          debugPrint('[Firestore] getUserActivities ❌ error: $e');
        });
  }

  /// Sync กิจกรรมที่เป็นสาธารณะของ user เข้าสู่ global activities (สำหรับกิจกรรมเก่า)
  Future<void> syncUserPublicActivities(String uid) async {
    if (uid.isEmpty) return;
    try {
      final snap = await _userActivitiesRef(uid).get();
      for (final doc in snap.docs) {
        final data = doc.data();
        if (data['isPublic'] == true) {
          final globalRef = _globalActivitiesRef.doc(doc.id);
          final globalSnap = await globalRef.get();
          if (!globalSnap.exists) {
            await globalRef.set({...data, 'userActivityId': doc.id});
          }
        }
      }
    } catch (_) {}
  }

  /// Stream Community Feed — Public activities ทุกคน เรียงล่าสุด
  Stream<List<Activity>> getCommunityFeed({int limit = 20}) {
    return _globalActivitiesRef
        .orderBy('startedAt', descending: true)
        .limit(limit)
        .snapshots()
        .map((snap) =>
            snap.docs.map((d) => Activity.fromMap(d.data(), d.id)).toList());
  }

  /// Stream สถิติสัปดาห์นี้ (จันทร์–อาทิตย์)
  Stream<WeeklyStats> getWeeklyStats(String uid) {
    if (uid.isEmpty) return Stream.value(const WeeklyStats());
    final now = DateTime.now();
    final weekStart = DateTime(now.year, now.month, now.day)
        .subtract(Duration(days: now.weekday - 1));

    return _userActivitiesRef(uid)
        .where('startedAt',
            isGreaterThanOrEqualTo: Timestamp.fromDate(weekStart))
        .snapshots()
        .map((snap) {
      final activities =
          snap.docs.map((d) => Activity.fromMap(d.data(), d.id)).toList();
      return WeeklyStats.fromActivities(activities);
    });
  }

  /// Stream กิจกรรมแต่ละวันของสัปดาห์นี้ (สำหรับกราฟ)
  Stream<List<Activity>> getWeeklyActivities(String uid) {
    if (uid.isEmpty) return Stream.value([]);
    final now = DateTime.now();
    final weekStart = DateTime(now.year, now.month, now.day)
        .subtract(Duration(days: now.weekday - 1));
    return _userActivitiesRef(uid)
        .where('startedAt',
            isGreaterThanOrEqualTo: Timestamp.fromDate(weekStart))
        .orderBy('startedAt')
        .snapshots()
        .map((snap) =>
            snap.docs.map((d) => Activity.fromMap(d.data(), d.id)).toList());
  }

  /// Stream สถิติรวมทั้งหมด (สำหรับ Profile)
  Stream<AllTimeStats> getAllTimeStats(String uid) {
    if (uid.isEmpty) return Stream.value(const AllTimeStats());
    return _userActivitiesRef(uid).snapshots().map((snap) {
      final activities =
          snap.docs.map((d) => Activity.fromMap(d.data(), d.id)).toList();
      return AllTimeStats.fromActivities(activities);
    });
  }

  // ─── INCIDENT REPORTS (FR 8, 9, 10, 13, 14, 18) ───────────────

  CollectionReference<Map<String, dynamic>> get _incidentsRef =>
      _db.collection('incidents');

  /// สร้างรายงานเหตุการณ์ใหม่ (FR 8, 9)
  Future<void> createIncidentReport(IncidentReport report) async {
    try {
      final docRef = _incidentsRef.doc();
      await docRef.set(report.toMap());
      debugPrint('[Firestore] ✅ Incident report saved docId=${docRef.id}');
    } catch (e) {
      debugPrint('[Firestore] ❌ Incident report failed: $e');
      rethrow;
    }
  }

  /// Stream รายงานเหตุการณ์ที่ยังไม่หมดอายุ (FR 10, 13)
  Stream<List<IncidentReport>> streamActiveIncidents() {
    return _incidentsRef
        .where('status', isEqualTo: 'active')
        .snapshots()
        .map((snap) {
      // ใช้เวลาปัจจุบันทุกครั้งที่มี snapshot ใหม่ (เดิมจับเวลาไว้ครั้งเดียวตอนเริ่ม stream
      // ทำให้หมุดที่หมดอายุแล้วยังแสดงอยู่)
      final now = DateTime.now();
      return snap.docs
          .map((doc) => IncidentReport.fromMap(doc.data(), doc.id))
          .where((report) => report.expiresAt.isAfter(now))
          .toList();
    });
  }

  /// กลไกกำหนดอายุข้อมูล (TTL) — เปลี่ยนสถานะรายงานที่เลยเวลาหมดอายุเป็น 'expired'
  /// เรียกเป็นรอบ ๆ จากแอป (ทดแทนตัวจัดตารางงานฝั่งเซิร์ฟเวอร์) — คืนจำนวนรายการที่หมดอายุ
  Future<int> expireStaleIncidents() async {
    try {
      final now = DateTime.now();
      final snap = await _incidentsRef.where('status', isEqualTo: 'active').get();
      final stale = snap.docs.where((d) {
        final exp = d.data()['expiresAt'];
        final dt = exp is Timestamp ? exp.toDate() : null;
        return dt != null && dt.isBefore(now);
      }).toList();
      if (stale.isEmpty) return 0;
      final batch = _db.batch();
      for (final d in stale) {
        batch.update(d.reference, {'status': 'expired'});
      }
      await batch.commit();
      debugPrint('[Firestore] ✅ TTL expired ${stale.length} incident(s)');
      return stale.length;
    } catch (e) {
      debugPrint('[Firestore] ⚠️ expireStaleIncidents error: $e');
      return 0;
    }
  }

  /// ยืนยันเหตุการณ์ว่ายังอยู่ (Upvote) (FR 14)
  Future<void> confirmIncidentReport(String reportId, String userId) async {
    final docRef = _incidentsRef.doc(reportId);
    await _db.runTransaction((tx) async {
      final snap = await tx.get(docRef);
      if (!snap.exists) return;
      final data = snap.data() ?? {};
      final confirmedBy = List<String>.from(data['confirmedBy'] ?? []);
      final deniedBy = List<String>.from(data['deniedBy'] ?? []);

      if (!confirmedBy.contains(userId)) {
        confirmedBy.add(userId);
        deniedBy.remove(userId);
      }

      tx.update(docRef, {
        'confirmedBy': confirmedBy,
        'deniedBy': deniedBy,
        'confirmationsCount': confirmedBy.length,
        'denialsCount': deniedBy.length,
      });
    });
  }

  /// แจ้งเหตุการณ์ถูกแก้ไข/ไม่อยู่แล้ว (Resolve/Downvote) (FR 14, 18)
  Future<void> resolveIncidentReport(String reportId, String userId) async {
    final docRef = _incidentsRef.doc(reportId);
    await _db.runTransaction((tx) async {
      final snap = await tx.get(docRef);
      if (!snap.exists) return;
      final data = snap.data() ?? {};
      final confirmedBy = List<String>.from(data['confirmedBy'] ?? []);
      final deniedBy = List<String>.from(data['deniedBy'] ?? []);

      if (!deniedBy.contains(userId)) {
        deniedBy.add(userId);
        confirmedBy.remove(userId);
      }

      final newStatus = (deniedBy.length >= 3) ? 'resolved' : data['status'];

      tx.update(docRef, {
        'confirmedBy': confirmedBy,
        'deniedBy': deniedBy,
        'confirmationsCount': confirmedBy.length,
        'denialsCount': deniedBy.length,
        'status': newStatus,
      });
    });
  }

  /// ตรวจสอบความถูกต้องของรายงานเหตุ (FR18)
  /// คืนค่าเป็น Map: { verified: bool, score: double, reason: String, confirmations: int, denials: int }
  Future<Map<String, dynamic>> getIncidentVerification(String reportId) async {
    final docRef = _incidentsRef.doc(reportId);
    final snap = await docRef.get();
    if (!snap.exists) return {'verified': false, 'score': 0.0, 'reason': 'not_found', 'confirmations': 0, 'denials': 0};
    final data = snap.data() ?? {};

    final int confirmations = (data['confirmationsCount'] as int?) ?? (data['confirmedBy'] as List<dynamic>?)?.length ?? 0;
    final int denials = (data['denialsCount'] as int?) ?? (data['deniedBy'] as List<dynamic>?)?.length ?? 0;

    // Business rules:
    if (confirmations >= 3) return {'verified': true, 'score': 1.0, 'reason': 'community', 'confirmations': confirmations, 'denials': denials};
    if (denials >= 3) return {'verified': false, 'score': 0.0, 'reason': 'community_rejected', 'confirmations': confirmations, 'denials': denials};

    final int votes = confirmations - denials;
    final votesScore = (votes + 5) / 10; // normalize -5..+5 => 0..1
    // ใช้คะแนนความเชื่อมั่นจาก AI ที่บันทึกไว้ตอนสร้างรายงาน (UC-15) ถ้าไม่มีใช้ 0.5
    final aiScore = (data['aiConfidence'] as num?)?.toDouble() ?? 0.5;
    final score = double.parse(((0.6 * votesScore) + (0.4 * aiScore)).toStringAsFixed(2));
    final verified = score >= 0.6;
    final reason = verified ? 'threshold' : 'insufficient_evidence';

    return {'verified': verified, 'score': score, 'reason': reason, 'confirmations': confirmations, 'denials': denials};
  }

  // ─── UC-07: Remove Invalid Incident (Admin) ─────────────────

  /// ดึงรายการรายงานเหตุการณ์ทั้งหมดสำหรับ Admin (Normal Flow 1-2)
  Future<List<IncidentReport>> fetchAllIncidentsForAdmin({
    String? statusFilter, // 'active' | 'suspended' | 'resolved' | null=all
    int limit = 50,
  }) async {
    try {
      Query<Map<String, dynamic>> query = _incidentsRef
          .orderBy('createdAt', descending: true)
          .limit(limit);

      if (statusFilter == 'suspended') {
        // แท็บ "ระงับ/รอตรวจสอบ" รวมรายงาน pending จาก AI (UC-15 A1, E2)
        query = query.where('status', whereIn: ['suspended', 'pending']);
      } else if (statusFilter != null) {
        query = query.where('status', isEqualTo: statusFilter);
      }

      final snap = await query.get();
      return snap.docs
          .map((doc) => IncidentReport.fromMap(doc.data(), doc.id))
          .toList();
    } catch (e) {
      debugPrint('[Firestore] ⚠️ fetchAllIncidentsForAdmin error: $e');
      return [];
    }
  }

  /// ลบรายงานเหตุการณ์ถาวร (Normal Flow 3 — Admin กดลบและยืนยัน)
  /// ลบออกจากฐานข้อมูลและหมุดจะหายออกจากแผนที่ทันที
  Future<void> deleteIncidentReport(String reportId) async {
    try {
      await _incidentsRef.doc(reportId).delete();
      debugPrint('[Firestore] ✅ UC-07 deleteIncidentReport: $reportId');
    } catch (e) {
      debugPrint('[Firestore] ❌ UC-07 deleteIncidentReport error: $e');
      rethrow; // E1: ให้ caller แสดงข้อความแจ้งเตือน
    }
  }

  /// ระงับรายงานชั่วคราว (Alternative Flow A1 — เลือก "ระงับชั่วคราว")
  /// เปลี่ยน status → 'suspended' เพื่อรอตรวจสอบเพิ่มเติม
  Future<void> suspendIncidentReport(String reportId,
      {String reason = 'Suspended by admin'}) async {
    try {
      await _incidentsRef.doc(reportId).update({
        'status': 'suspended',
        'suspendedAt': FieldValue.serverTimestamp(),
        'suspendReason': reason,
      });
      debugPrint('[Firestore] ✅ UC-07 suspendIncidentReport: $reportId');
    } catch (e) {
      debugPrint('[Firestore] ❌ UC-07 suspendIncidentReport error: $e');
      rethrow;
    }
  }

  /// เรียกคืนรายงานที่ถูกระงับ (Restore from suspended → active)
  Future<void> restoreIncidentReport(String reportId) async {
    try {
      await _incidentsRef.doc(reportId).update({
        'status': 'active',
        'suspendedAt': null,
        'suspendReason': null,
      });
      debugPrint('[Firestore] ✅ UC-07 restoreIncidentReport: $reportId');
    } catch (e) {
      debugPrint('[Firestore] ❌ UC-07 restoreIncidentReport error: $e');
      rethrow;
    }
  }

  // ─── ROUTES (UC-08 Manage Route Data) ─────────────────────

  CollectionReference<Map<String, dynamic>> get _routesRef =>
      _db.collection('routes');

  /// ดึงข้อมูลเส้นทางทั้งหมด (Normal Flow 2)
  /// ดึงจาก Firestore ถ้ามี หรือ fallback ใช้ ChiangMaiRoutes.routes
  Future<List<RunningRoute>> fetchRoutes() async {
    try {
      final snap = await _routesRef.get();
      if (snap.docs.isEmpty) {
        // ครั้งแรกถ้าใน Firestore ยังไม่มี ให้ใช้ default routes
        return List<RunningRoute>.from(ChiangMaiRoutes.routes);
      }
      final loaded = snap.docs.map((doc) => RunningRoute.fromMap(doc.data(), doc.id)).toList();
      ChiangMaiRoutes.setRoutes(loaded);
      debugPrint('[Firestore] ✅ fetchRoutes loaded ${loaded.length} routes');
      return loaded;
    } catch (e) {
      debugPrint('[Firestore] ⚠️ fetchRoutes error: $e');
      return List<RunningRoute>.from(ChiangMaiRoutes.routes);
    }
  }

  /// บันทึกหรืออัปเดตเส้นทาง (Normal Flow 3.1 & 3.2)
  Future<void> saveRoute(RunningRoute route) async {
    try {
      final docRef = _routesRef.doc(route.id);
      await docRef.set(route.toMap(), SetOptions(merge: true));
      ChiangMaiRoutes.updateRoute(route);
      debugPrint('[Firestore] ✅ saveRoute success: ${route.id}');
    } catch (e) {
      debugPrint('[Firestore] ⚠️ saveRoute error: $e');
      rethrow; // UC-08 E1: ให้หน้าจอแจ้งเตือนและไม่ถือว่าบันทึกสำเร็จ
    }
  }

  /// ลบเส้นทาง (Normal Flow 3.3)
  Future<void> deleteRoute(String routeId) async {
    try {
      await _routesRef.doc(routeId).delete();
      ChiangMaiRoutes.deleteRoute(routeId);
      debugPrint('[Firestore] ✅ deleteRoute success: $routeId');
    } catch (e) {
      debugPrint('[Firestore] ⚠️ deleteRoute error: $e');
      rethrow; // UC-08 E1
    }
  }

  // ─── SIMULATION / ENVIRONMENT (ตาราง Simulation, AirQuality, Weather ใน ERD) ───

  /// บันทึกผลการจำลองการออกกำลังกายล่วงหน้า (ตาราง Simulation)
  Future<void> saveSimulation({
    required String userId,
    String? routeId,
    required Map<String, dynamic> simulation,
    int? safetyScore,
  }) async {
    try {
      await _db.collection('simulations').add({
        'userId': userId,
        'routeId': routeId,
        ...simulation,
        'safetyScore': ?safetyScore,
        'createdAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint('[Firestore] ⚠️ saveSimulation error: $e');
    }
  }

  /// บันทึกข้อมูลคุณภาพอากาศและสภาพอากาศตามช่วงเวลา (ตาราง AirQuality และ Weather)
  Future<void> saveEnvironmentSnapshot({
    String? routeId,
    required double latitude,
    required double longitude,
    required Map airQuality,
    required Map weather,
  }) async {
    try {
      final batch = _db.batch();
      batch.set(_db.collection('air_quality').doc(), {
        'routeId': routeId,
        'latitude': latitude,
        'longitude': longitude,
        'pm25': double.tryParse(airQuality['pm2_5']?.toString() ?? ''),
        'aqi': airQuality['us_aqi'],
        'recordedAt': FieldValue.serverTimestamp(),
      });
      batch.set(_db.collection('weather').doc(), {
        'routeId': routeId,
        'latitude': latitude,
        'longitude': longitude,
        'temperature': double.tryParse(weather['temperature']?.toString() ?? ''),
        'humidity': double.tryParse(weather['humidity']?.toString() ?? ''),
        'precipitation': double.tryParse(weather['precipitation']?.toString() ?? ''),
        'windSpeed': double.tryParse(weather['windspeed']?.toString() ?? ''),
        'recordedAt': FieldValue.serverTimestamp(),
      });
      await batch.commit();
    } catch (e) {
      debugPrint('[Firestore] ⚠️ saveEnvironmentSnapshot error: $e');
    }
  }
}


// ─── Stats Models ────────────────────────────────────────

class WeeklyStats {
  final double distanceKm;
  final int durationSeconds;
  final int count;
  final int elevationM;

  const WeeklyStats({
    this.distanceKm = 0,
    this.durationSeconds = 0,
    this.count = 0,
    this.elevationM = 0,
  });

  factory WeeklyStats.fromActivities(List<Activity> acts) {
    return WeeklyStats(
      distanceKm:
          acts.fold(0, (acc, a) => acc + a.distanceKm),
      durationSeconds:
          acts.fold(0, (acc, a) => acc + a.durationSeconds),
      count: acts.length,
      elevationM: acts.fold(0, (acc, a) => acc + a.elevationM),
    );
  }

  String get formattedDistance => distanceKm.toStringAsFixed(1);

  String get formattedDuration {
    final h = durationSeconds ~/ 3600;
    final m = (durationSeconds % 3600) ~/ 60;
    if (h > 0) return '${h}h ${m}m';
    return '${m}m';
  }
}

class AllTimeStats {
  final double distanceKm;
  final int durationSeconds;
  final int count;
  final int elevationM;
  final Activity? longestRun;
  final Activity? fastestPace;
  final Activity? highestClimb;
  final Activity? longestTime;
  final Set<String> activeDays; // "yyyy-MM-dd"

  const AllTimeStats({
    this.distanceKm = 0,
    this.durationSeconds = 0,
    this.count = 0,
    this.elevationM = 0,
    this.longestRun,
    this.fastestPace,
    this.highestClimb,
    this.longestTime,
    this.activeDays = const {},
  });

  factory AllTimeStats.fromActivities(List<Activity> acts) {
    if (acts.isEmpty) return const AllTimeStats();

    double totalDist = 0;
    int totalSecs = 0;
    int totalElev = 0;
    Activity? longest, fastest, highest, longestT;
    final days = <String>{};

    for (final a in acts) {
      totalDist += a.distanceKm;
      totalSecs += a.durationSeconds;
      totalElev += a.elevationM;
      days.add(
          '${a.startedAt.year}-${a.startedAt.month}-${a.startedAt.day}');

      if (longest == null || a.distanceKm > longest.distanceKm) {
        longest = a;
      }
      if (fastest == null ||
          (a.avgPaceSecPerKm > 0 &&
              (fastest.avgPaceSecPerKm == 0 ||
                  a.avgPaceSecPerKm < fastest.avgPaceSecPerKm))) {
        fastest = a;
      }
      if (highest == null || a.elevationM > highest.elevationM) {
        highest = a;
      }
      if (longestT == null || a.durationSeconds > longestT.durationSeconds) {
        longestT = a;
      }
    }

    return AllTimeStats(
      distanceKm: totalDist,
      durationSeconds: totalSecs,
      count: acts.length,
      elevationM: totalElev,
      longestRun: longest,
      fastestPace: fastest,
      highestClimb: highest,
      longestTime: longestT,
      activeDays: days,
    );
  }

  String get formattedDistance => distanceKm.toStringAsFixed(1);

  String get formattedDuration {
    final h = durationSeconds ~/ 3600;
    final m = (durationSeconds % 3600) ~/ 60;
    if (h > 0) return '${h}h ${m}m';
    return '${m}m';
  }

  /// ตรวจว่าวิ่ง 7 วันติดต่อกันหรือไม่
  bool get hasSevenDayStreak {
    if (activeDays.length < 7) return false;
    final now = DateTime.now();
    for (int i = 0; i < 7; i++) {
      final d = now.subtract(Duration(days: i));
      final key = '${d.year}-${d.month}-${d.day}';
      if (!activeDays.contains(key)) return false;
    }
    return true;
  }
}
