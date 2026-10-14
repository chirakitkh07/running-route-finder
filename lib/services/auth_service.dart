import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kIsWeb, ValueNotifier;
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/password_policy.dart';
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

  /// true ระหว่างสมัครสมาชิก/ตรวจสอบการเข้าสู่ระบบ — AuthGate จะค้างหน้า Login ไว้
  /// (กันไม่ให้เข้าแอปก่อนตรวจว่ายืนยันอีเมลแล้ว)
  static final ValueNotifier<bool> authInProgress = ValueNotifier<bool>(false);

  /// บัญชีอีเมลที่สมัครตั้งแต่วันนี้ต้องยืนยันอีเมลก่อนเข้าใช้
  /// (บัญชีเก่าที่สมัครก่อนมีระบบยืนยันยังเข้าได้ตามเดิม)
  static final DateTime emailVerificationSince = DateTime.utc(2026, 10, 14);

  /// บัญชีนี้ต้องยืนยันอีเมลก่อนเข้าแอปหรือไม่ (เฉพาะบัญชีอีเมล/รหัสผ่าน)
  static bool requiresEmailVerification(User user) {
    if (user.emailVerified || user.isAnonymous) return false;
    if (isUserAdmin(user.email)) return false;
    final isPasswordAccount =
        user.providerData.any((p) => p.providerId == 'password');
    if (!isPasswordAccount) return false;
    final created = user.metadata.creationTime;
    return created == null || !created.isBefore(emailVerificationSince);
  }

  // Stream of auth state changes
  Stream<User?> get authStateChanges => _auth.authStateChanges();

  // Current user
  User? get currentUser => _auth.currentUser;

  // ─── Email / Password ─────────────────────────────────────────────────────

  /// UC-01 Normal Flow: เข้าสู่ระบบด้วย Email และ Password
  /// Throws [FirebaseAuthException] with codes:
  ///   'user-not-found' | 'wrong-password' | 'invalid-credential' → E1
  ///   'too-many-requests' → Firebase ระงับชั่วคราว
  /// Throws [LoginLockedException] เมื่อกรอกผิดเกินกำหนด (ล็อกฝั่งแอป)
  /// Throws [EmailNotVerifiedException] เมื่อยังไม่ได้ยืนยันอีเมล (ส่งลิงก์ใหม่ให้แล้ว)
  Future<UserCredential> signInWithEmailAndPassword(
      String email, String password) async {
    final key = _throttleKey(email);
    final remaining = await lockRemaining(email);
    if (remaining > Duration.zero) throw LoginLockedException(remaining);

    authInProgress.value = true;
    try {
      final UserCredential credential;
      try {
        credential = await _auth.signInWithEmailAndPassword(
          email: email.trim(),
          password: password,
        );
      } on FirebaseAuthException catch (e) {
        if (_isCredentialError(e.code)) {
          final lock = await _recordFailure(key);
          if (lock > Duration.zero) throw LoginLockedException(lock);
        }
        rethrow;
      }
      await _clearFailures(key);

      final user = credential.user;
      if (user != null) {
        try {
          await user.reload();
        } catch (_) {}
        final fresh = _auth.currentUser ?? user;
        if (requiresEmailVerification(fresh)) {
          var sent = true;
          try {
            await fresh.sendEmailVerification();
          } catch (_) {
            sent = false; // ส่งถี่เกินไป — ลิงก์เดิมยังใช้ได้
          }
          await _auth.signOut();
          throw EmailNotVerifiedException(email.trim(), resent: sent);
        }
      }
      return credential;
    } finally {
      authInProgress.value = false;
    }
  }

  // ─── กันการเดารหัสผ่าน (เก็บในเครื่อง ต่ออีเมล) ───────────────────────────

  static bool _isCredentialError(String code) =>
      code == 'wrong-password' ||
      code == 'invalid-credential' ||
      code == 'user-not-found' ||
      code == 'INVALID_LOGIN_CREDENTIALS';

  static String _throttleKey(String email) =>
      'login_throttle_${email.trim().toLowerCase()}';

  /// เวลาที่ยังถูกล็อกอยู่สำหรับอีเมลนี้ (Duration.zero = เข้าได้)
  static Future<Duration> lockRemaining(String email) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final until = prefs.getInt('${_throttleKey(email)}_until') ?? 0;
      final left = until - DateTime.now().millisecondsSinceEpoch;
      return left > 0 ? Duration(milliseconds: left) : Duration.zero;
    } catch (_) {
      return Duration.zero;
    }
  }

  static Future<Duration> _recordFailure(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final failures = (prefs.getInt('${key}_count') ?? 0) + 1;
      await prefs.setInt('${key}_count', failures);
      final lock = LoginThrottle.lockFor(failures);
      if (lock > Duration.zero) {
        await prefs.setInt('${key}_until',
            DateTime.now().add(lock).millisecondsSinceEpoch);
      }
      return lock;
    } catch (_) {
      return Duration.zero;
    }
  }

  static Future<void> _clearFailures(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('${key}_count');
      await prefs.remove('${key}_until');
    } catch (_) {}
  }

  /// ส่งลิงก์ยืนยันอีเมลอีกครั้ง (ต้องเข้าสู่ระบบชั่วคราวเพื่อส่ง แล้วออกทันที)
  Future<void> resendVerificationEmail(String email, String password) async {
    authInProgress.value = true;
    try {
      final cred = await _auth.signInWithEmailAndPassword(
          email: email.trim(), password: password);
      await cred.user?.sendEmailVerification();
    } finally {
      await _auth.signOut();
      authInProgress.value = false;
    }
  }

  /// UC-01 Normal Flow: สมัครสมาชิกด้วย Email และ Password
  /// หลังสมัครและบันทึกโปรไฟล์เสร็จแล้ว จะทำการ Sign-Out เพื่อให้ผู้ใช้ล็อกอินอีกครั้งก่อนเข้าแอป
  /// Throws [FirebaseAuthException] with codes:
  ///   'email-already-in-use' → E2
  ///   'weak-password'        → แจ้งเตือนรหัสผ่านไม่ปลอดภัย
  Future<UserCredential> registerWithEmailAndPassword(
      String email, String password, String displayName) async {
    authInProgress.value = true;
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
        // ส่งลิงก์ยืนยันอีเมล — ต้องกดยืนยันก่อนจึงจะเข้าสู่ระบบได้
        try {
          await credential.user!.sendEmailVerification();
        } catch (_) {}
      }
      // ออกจากระบบทันที เพื่อให้ผู้ใช้ต้องล็อกอินอีกรอบก่อนเข้าแอป
      await _auth.signOut();
      return credential;
    } finally {
      authInProgress.value = false;
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

/// กรอกรหัสผ่านผิดเกินกำหนด — ต้องรอ [remaining] ก่อนลองใหม่
class LoginLockedException implements Exception {
  final Duration remaining;
  const LoginLockedException(this.remaining);
}

/// เข้าสู่ระบบด้วยรหัสถูกต้อง แต่ยังไม่ได้กดลิงก์ยืนยันอีเมล
class EmailNotVerifiedException implements Exception {
  final String email;
  final bool resent;
  const EmailNotVerifiedException(this.email, {this.resent = true});
}
