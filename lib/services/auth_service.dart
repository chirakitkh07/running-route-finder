import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kIsWeb, ValueNotifier;
import 'package:google_sign_in/google_sign_in.dart';
import 'firestore_service.dart';
import 'push_service.dart';

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final GoogleSignIn _googleSignIn = GoogleSignIn();
  final FirestoreService _firestoreService = FirestoreService();

  /// รายชื่ออีเมลผู้ดูแลระบบ (Admin)
  static const Set<String> adminEmails = {
    'kittaphon.nk@gmail.com',
    'hkmknas@gmail.com',
  };

  /// ตรวจสอบว่าอีเมลนี้เป็น Admin หรือไม่
  static bool isUserAdmin(String? email) {
    if (email == null || email.trim().isEmpty) return false;
    return adminEmails.contains(email.trim().toLowerCase());
  }

  /// ตัวแจ้งเตือนสถานะการสมัครสมาชิก เพื่อป้องกัน AuthGate นำทางก่อนล็อกอินจริง
  static final ValueNotifier<bool> isRegistering = ValueNotifier<bool>(false);

  // Stream of auth state changes
  Stream<User?> get authStateChanges => _auth.authStateChanges();

  // Current user
  User? get currentUser => _auth.currentUser;

  // ─── Email / Password ─────────────────────────────────────────────────────

  /// UC-01 Normal Flow: เข้าสู่ระบบด้วย Email และ Password
  /// Throws [FirebaseAuthException] with codes:
  ///   'user-not-found' | 'wrong-password' | 'invalid-credential' → E1
  Future<UserCredential> signInWithEmailAndPassword(
      String email, String password) async {
    return await _auth.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
  }

  /// UC-01 Normal Flow: สมัครสมาชิกด้วย Email และ Password
  /// หลังสมัครและบันทึกโปรไฟล์เสร็จแล้ว จะทำการ Sign-Out เพื่อให้ผู้ใช้ล็อกอินอีกครั้งก่อนเข้าแอป
  /// Throws [FirebaseAuthException] with codes:
  ///   'email-already-in-use' → E2
  ///   'weak-password'        → แจ้งเตือนรหัสผ่านไม่ปลอดภัย
  Future<UserCredential> registerWithEmailAndPassword(
      String email, String password, String displayName) async {
    isRegistering.value = true;
    try {
      final credential = await _auth.createUserWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      // บันทึกชื่อผู้ใช้หลังสมัครสำเร็จ
      await credential.user?.updateDisplayName(displayName.trim());
      // บันทึก User Profile ลง Firestore
      if (credential.user != null) {
        await _firestoreService.saveUserProfile(
          credential.user!,
          displayName: displayName.trim(),
        );
      }
      // ออกจากระบบทันที เพื่อให้ผู้ใช้ต้องล็อกอินอีกรอบก่อนเข้าแอป
      await _auth.signOut();
      return credential;
    } finally {
      isRegistering.value = false;
    }
  }

  /// UC-01 Alternative Flow A1: ลืมรหัสผ่าน → ส่งลิงก์รีเซ็ตทางอีเมล
  Future<void> sendPasswordResetEmail(String email) async {
    await _auth.sendPasswordResetEmail(email: email.trim());
  }

  // ─── Google Sign-In ───────────────────────────────────────────────────────

  /// Sign in with Google (รองรับทั้ง Web และ Native)
  Future<UserCredential?> signInWithGoogle() async {
    try {
      if (kIsWeb) {
        final GoogleAuthProvider googleProvider = GoogleAuthProvider();
        googleProvider.addScope('email');
        googleProvider.addScope('profile');
        return await _auth.signInWithPopup(googleProvider);
      } else {
        // Native Google Sign-In for Android / iOS
        final GoogleSignInAccount? googleUser = await _googleSignIn.signIn();
        if (googleUser == null) return null;

        final GoogleSignInAuthentication googleAuth =
            await googleUser.authentication;

        final AuthCredential credential = GoogleAuthProvider.credential(
          accessToken: googleAuth.accessToken,
          idToken: googleAuth.idToken,
        );

        final result = await _auth.signInWithCredential(credential);
        // บันทึก/อัปเดต Profile ลง Firestore (ครั้งแรกหรืออัปเดตทุกครั้ง)
        if (result.user != null) {
          await _firestoreService.saveUserProfile(result.user!);
        }
        return result;
      }
    } catch (e) {
      rethrow;
    }
  }

  // ─── Anonymous ────────────────────────────────────────────────────────────

  // Sign in as Guest / Anonymous
  Future<UserCredential?> signInAnonymously() async {
    return await _auth.signInAnonymously();
  }

  // ─── Sign Out ─────────────────────────────────────────────────────────────

  Future<void> signOut() async {
    await PushService.unregisterUser();
    try {
      if (!kIsWeb) {
        await _googleSignIn.signOut();
      }
    } catch (_) {}
    await _auth.signOut();
  }
}
