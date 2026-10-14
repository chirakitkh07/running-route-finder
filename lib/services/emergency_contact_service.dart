import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// บริการจัดการผู้ติดต่อฉุกเฉิน (Emergency Contact Service)
///
/// - เก็บข้อมูลใน users/{uid}/emergency_contacts/default และ users/{uid}/settings/emergency_contact
/// - เก็บสำเนาออฟไลน์ในเครื่องผ่าน SharedPreferences เสมอ
/// - ซิงค์ข้อมูลเก่าจากเครื่องขึ้น Firestore อัตโนมัติ (Auto-migration) ครั้งแรกที่เปิดแอป
class EmergencyContactService {
  static final _db = FirebaseFirestore.instance;

  static DocumentReference _contactDoc(String uid) =>
      _db.collection('users').doc(uid).collection('emergency_contacts').doc('default');

  static DocumentReference _legacySettingsDoc(String uid) =>
      _db.collection('users').doc(uid).collection('settings').doc('emergency_contact');

  /// บันทึกลง SharedPreferences เสมอ (Offline-first) และซิงค์ขึ้น Firestore
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
        final data = {
          'name': name,
          'phone': phone,
          'updatedAt': FieldValue.serverTimestamp(),
        };
        // บันทึกทั้ง collection ใหม่ และ legacy settings เพื่อความเข้ากันได้
        await Future.wait([
          _contactDoc(uid).set(data),
          _legacySettingsDoc(uid).set(data),
        ]);
      } catch (e) {
        debugPrint('[EmergencyContactService] Firestore sync warning (saved locally): $e');
      }
    }
  }

  /// โหลดข้อมูล — ลองจาก Firestore ก่อน หากติด permission หรือไม่มีเน็ต ให้ดึงจาก SharedPreferences
  /// หากมีข้อมูล local แต่ใน Firestore ยังไม่มี จะทำ auto-migration อัตโนมัติ
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
        // ลองดึงจาก collection ใหม่ก่อน
        DocumentSnapshot snap = await _contactDoc(uid).get();
        if (!snap.exists) {
          // fallback ไปดูที่ legacy settings doc
          snap = await _legacySettingsDoc(uid).get();
        }

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
        } else if (localName.isNotEmpty && localPhone.isNotEmpty) {
          // Auto-migration: มีข้อมูล local เก่า แต่ยังไม่เคยขึ้น Firestore -> ย้ายขึ้นทันที
          debugPrint('[EmergencyContactService] Auto-migrating local emergency contact to Firestore...');
          save(localName, localPhone, uid: uid);
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
        await Future.wait([
          _contactDoc(uid).delete(),
          _legacySettingsDoc(uid).delete(),
        ]);
      } catch (e) {
        debugPrint('[EmergencyContactService] Firestore delete warning: $e');
      }
    }
  }
}
