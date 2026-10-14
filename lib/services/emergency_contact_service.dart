import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class EmergencyContactService {
  static final _db = FirebaseFirestore.instance;

  static DocumentReference _doc(String uid) =>
      _db.collection('users').doc(uid).collection('settings').doc('emergency_contact');

  /// บันทึกลง SharedPreferences เสมอ (Offline-first) และพยายามซิงค์ขึ้น Firestore
  static Future<void> save(String name, String phone, {required String uid}) async {
    // 1. บันทึกลงเครื่องเสมอ ให้ใช้งานได้ทันที แม้ Firestore ปิดสิทธิ์หรือ offline
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('emergency_name_$uid', name);
      await prefs.setString('emergency_phone_$uid', phone);
    } catch (e) {
      debugPrint('[EmergencyContactService] local save error: $e');
    }

    // 2. พยายามซิงค์ขึ้น Firestore (ถ้ามี uid)
    if (uid.isNotEmpty) {
      try {
        await _doc(uid).set({'name': name, 'phone': phone});
      } catch (e) {
        debugPrint('[EmergencyContactService] Firestore sync warning (saved locally): $e');
      }
    }
  }

  /// โหลดข้อมูล — ลองจาก Firestore ก่อน หากติด permission หรือไม่มีเน็ต ให้ดึงจาก SharedPreferences
  static Future<({String name, String phone})?> load({required String uid}) async {
    // โหลดข้อมูล local สำรองไว้ก่อน
    String localName = '';
    String localPhone = '';
    try {
      final prefs = await SharedPreferences.getInstance();
      localName = prefs.getString('emergency_name_$uid') ?? '';
      localPhone = prefs.getString('emergency_phone_$uid') ?? '';
    } catch (_) {}

    if (uid.isNotEmpty) {
      try {
        final snap = await _doc(uid).get();
        if (snap.exists) {
          final data = snap.data() as Map<String, dynamic>?;
          final name = data?['name'] as String? ?? '';
          final phone = data?['phone'] as String? ?? '';
          if (name.isNotEmpty && phone.isNotEmpty) {
            // อัปเดตข้อมูลใน local prefs ด้วย
            try {
              final prefs = await SharedPreferences.getInstance();
              await prefs.setString('emergency_name_$uid', name);
              await prefs.setString('emergency_phone_$uid', phone);
            } catch (_) {}
            return (name: name, phone: phone);
          }
        }
      } catch (e) {
        debugPrint('[EmergencyContactService] Firestore load warning: $e');
      }
    }

    if (localName.isNotEmpty && localPhone.isNotEmpty) {
      return (name: localName, phone: localPhone);
    }

    return null;
  }

  /// ลบข้อมูลทั้งใน SharedPreferences และ Firestore
  static Future<void> clear({required String uid}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('emergency_name_$uid');
      await prefs.remove('emergency_phone_$uid');
    } catch (_) {}

    if (uid.isNotEmpty) {
      try {
        await _doc(uid).delete();
      } catch (e) {
        debugPrint('[EmergencyContactService] Firestore delete warning: $e');
      }
    }
  }
}

