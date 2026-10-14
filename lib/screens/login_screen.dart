import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/auth_service.dart';
import '../utils/password_policy.dart';
import '../l10n/tr.dart';
import 'package:provider/provider.dart';
import '../providers/language_provider.dart';
import 'package:demo20426/providers/theme_provider.dart';

// ─── Main Screen ──────────────────────────────────────────────────────────────

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with TickerProviderStateMixin {
  final AuthService _authService = AuthService();

  // Tab: 0 = Login, 1 = Register
  int _tabIndex = 0;
  bool _isLoading = false;
  String? _prefilledEmail;
  DateTime? _lastResetEmailAt; // กันกด "ลืมรหัสผ่าน" ถี่ ๆ

  // ─── Animation Controllers ────────────────────────────────────────────────
  late AnimationController _bgController;
  late AnimationController _entryController;
  late AnimationController _pulseController;
  late AnimationController _orbitController;
  late AnimationController _tabController;

  late Animation<double> _fadeAnim;
  late Animation<Offset> _slideAnim;
  late Animation<double> _scaleAnim;
  late Animation<double> _pulseAnim;
  late Animation<double> _orbitAnim;
  late Animation<double> _formFade;

  @override
  void initState() {
    super.initState();

    _bgController =
        AnimationController(vsync: this, duration: const Duration(seconds: 8))
          ..repeat(reverse: true);

    _entryController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1400));

    _pulseController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 2000))
      ..repeat(reverse: true);

    _orbitController =
        AnimationController(vsync: this, duration: const Duration(seconds: 12))
          ..repeat();

    _tabController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 300));

    _fadeAnim = CurvedAnimation(
      parent: _entryController,
      curve: const Interval(0.0, 0.7, curve: Curves.easeOut),
    );
    _slideAnim =
        Tween<Offset>(begin: const Offset(0, 0.08), end: Offset.zero).animate(
      CurvedAnimation(
          parent: _entryController,
          curve: const Interval(0.1, 0.8, curve: Curves.easeOutCubic)),
    );
    _scaleAnim = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(
          parent: _entryController,
          curve: const Interval(0.0, 0.6, curve: Curves.easeOutBack)),
    );
    _pulseAnim = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _orbitAnim = Tween<double>(begin: 0, end: 2 * math.pi).animate(
      CurvedAnimation(parent: _orbitController, curve: Curves.linear),
    );
    _formFade = CurvedAnimation(parent: _tabController, curve: Curves.easeOut);

    _entryController.forward();
    _tabController.forward();
  }

  @override
  void dispose() {
    _bgController.dispose();
    _entryController.dispose();
    _pulseController.dispose();
    _orbitController.dispose();
    _tabController.dispose();
    super.dispose();
  }

  // ─── Tab Switch ───────────────────────────────────────────────────────────

  void _switchTab(int index) {
    if (_tabIndex == index) return;
    _tabController.reverse().then((_) {
      setState(() => _tabIndex = index);
      _tabController.forward();
    });
  }

  // ─── Auth Handlers ────────────────────────────────────────────────────────

  Future<void> _handleGoogleSignIn() async {
    setState(() => _isLoading = true);
    try {
      final result = await _authService.signInWithGoogle();
      if (result == null && mounted) {
        _showSnack(tr('ยกเลิกการเข้าสู่ระบบ', 'Sign-in cancelled'), isError: false);
      }
    } catch (e) {
      if (mounted) _showSnack(tr('เข้าสู่ระบบไม่สำเร็จ กรุณาลองอีกครั้ง', 'Sign-in failed. Please try again'), isError: true);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _handleEmailLogin(String email, String password) async {
    setState(() => _isLoading = true);
    try {
      await _authService.signInWithEmailAndPassword(email, password);
    } on LoginLockedException catch (e) {
      if (mounted) _showLockedSnack(e.remaining);
    } on EmailNotVerifiedException catch (e) {
      if (mounted) await _showVerifyEmailDialog(e.email, password, resent: e.resent);
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      // E1: กรอกอีเมลหรือรหัสผ่านไม่ถูกต้อง (ไม่บอกว่าผิดช่องไหน กันการเดาบัญชี)
      if (e.code == 'user-not-found' ||
          e.code == 'wrong-password' ||
          e.code == 'invalid-credential' ||
          e.code == 'invalid-email') {
        _showSnack(tr('กรอกอีเมลหรือรหัสผ่านไม่ถูกต้อง กรุณากรอกใหม่', 'Incorrect email or password. Please try again'), isError: true);
      } else if (e.code == 'too-many-requests') {
        _showSnack(tr('มีการพยายามเข้าสู่ระบบหลายครั้งเกินไป ระบบระงับชั่วคราว กรุณาลองใหม่ภายหลัง หรือรีเซ็ตรหัสผ่าน',
            'Too many attempts. Access is temporarily blocked. Try again later or reset your password'), isError: true);
      } else if (e.code == 'user-disabled') {
        _showSnack(tr('บัญชีนี้ถูกระงับการใช้งาน', 'This account has been disabled'), isError: true);
      } else if (e.code == 'network-request-failed') {
        _showSnack(tr('เชื่อมต่ออินเทอร์เน็ตไม่ได้ กรุณาตรวจสอบเครือข่าย', 'No internet connection. Please check your network'), isError: true);
      } else {
        _showSnack(tr('เข้าสู่ระบบไม่สำเร็จ กรุณาลองอีกครั้ง', 'Sign-in failed. Please try again'), isError: true);
      }
    } catch (e) {
      if (mounted) _showSnack(tr('เกิดข้อผิดพลาด กรุณาลองอีกครั้ง', 'Something went wrong. Please try again'), isError: true);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showLockedSnack(Duration remaining) {
    final secs = remaining.inSeconds + 1;
    final text = secs >= 60
        ? tr('${(secs / 60).ceil()} นาที', '${(secs / 60).ceil()} min')
        : tr('$secs วินาที', '$secs s');
    _showSnack(
      tr('กรอกรหัสผ่านผิดหลายครั้ง เพื่อความปลอดภัยกรุณารอ $text แล้วลองใหม่ หรือกด "ลืมรหัสผ่าน?"',
          'Too many wrong passwords. For your security, wait $text and try again, or tap "Forgot password?"'),
      isError: true,
    );
  }

  /// ยังไม่ได้ยืนยันอีเมล — แจ้งให้เปิดลิงก์ในอีเมล และให้ส่งลิงก์ใหม่ได้
  Future<void> _showVerifyEmailDialog(String email, String password,
      {required bool resent}) async {
    final pal = context.pal;
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        var sending = false;
        return StatefulBuilder(
          builder: (ctx, setD) => AlertDialog(
            backgroundColor: pal.surface,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: Row(children: [
              const Icon(Icons.mark_email_unread_outlined, color: Color(0xFFFC4C02)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(tr('กรุณายืนยันอีเมล', 'Verify your email'),
                    style: TextStyle(color: pal.text, fontWeight: FontWeight.w800)),
              ),
            ]),
            content: Text(
              resent
                  ? tr('เราส่งลิงก์ยืนยันไปที่ $email แล้ว\nกดลิงก์ในอีเมล (ดูในกล่องจดหมายขยะด้วย) แล้วกลับมาเข้าสู่ระบบอีกครั้ง',
                      'We sent a verification link to $email.\nOpen the link (check your spam folder too), then sign in again.')
                  : tr('บัญชี $email ยังไม่ได้ยืนยันอีเมล\nกดลิงก์ที่เราส่งไปก่อนหน้า แล้วกลับมาเข้าสู่ระบบอีกครั้ง',
                      'The account $email is not verified yet.\nOpen the link we sent earlier, then sign in again.'),
              style: TextStyle(color: pal.textSub, height: 1.5),
            ),
            actions: [
              TextButton(
                onPressed: sending
                    ? null
                    : () async {
                        setD(() => sending = true);
                        try {
                          await _authService.resendVerificationEmail(email, password);
                          if (ctx.mounted) Navigator.pop(ctx);
                          if (mounted) {
                            _showSnack(tr('ส่งลิงก์ยืนยันใหม่ไปที่ $email แล้ว', 'A new verification link was sent to $email'), isError: false);
                          }
                        } catch (_) {
                          if (ctx.mounted) Navigator.pop(ctx);
                          if (mounted) {
                            _showSnack(tr('ส่งอีเมลไม่สำเร็จ (ส่งถี่เกินไป) กรุณารอสักครู่แล้วลองใหม่', 'Could not send (too many requests). Please wait and try again'), isError: true);
                          }
                        }
                      },
                child: Text(tr('ส่งลิงก์อีกครั้ง', 'Resend link'),
                    style: const TextStyle(color: Color(0xFFFC4C02))),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFC4C02),
                  foregroundColor: Colors.white,
                ),
                child: Text(tr('ตกลง', 'OK')),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _handleRegister(
      String name, String email, String password) async {
    setState(() => _isLoading = true);
    try {
      await _authService.registerWithEmailAndPassword(email, password, name);
      if (!mounted) return;
      setState(() {
        _prefilledEmail = email.trim();
      });
      // สลับกลับมาหน้าจอเข้าสู่ระบบ
      _switchTab(0);
      _showSnack(
        tr('สมัครสมาชิกสำเร็จ! เราส่งลิงก์ยืนยันไปที่ ${email.trim()} แล้ว กรุณากดยืนยันก่อนเข้าสู่ระบบ',
            'Registration successful! We sent a verification link to ${email.trim()}. Please verify before signing in'),
        isError: false,
      );
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      if (e.code == 'email-already-in-use') {
        // E2: อีเมลนี้ถูกใช้งานแล้ว
        _showSnack(tr('อีเมลนี้ถูกใช้งานแล้ว', 'This email is already in use'), isError: true);
      } else if (e.code == 'weak-password' ||
          e.code == 'password-does-not-meet-requirements') {
        _showSnack(tr('รหัสผ่านไม่ปลอดภัยพอ กรุณาตั้งตามเงื่อนไขที่แสดง', 'Password is not strong enough. Please follow the requirements shown'), isError: true);
      } else if (e.code == 'too-many-requests') {
        _showSnack(tr('มีการสมัครจากเครื่องนี้ถี่เกินไป กรุณารอสักครู่', 'Too many sign-ups from this device. Please wait a moment'), isError: true);
      } else if (e.code == 'invalid-email') {
        _showSnack(tr('รูปแบบอีเมลไม่ถูกต้อง', 'Invalid email format'), isError: true);
      } else {
        _showSnack(tr('สมัครสมาชิกไม่สำเร็จ กรุณาลองอีกครั้ง', 'Registration failed. Please try again'), isError: true);
      }
    } catch (e) {
      if (mounted) _showSnack(tr('เกิดข้อผิดพลาด กรุณาลองอีกครั้ง', 'Something went wrong. Please try again'), isError: true);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // Alternative Flow A1: ลืมรหัสผ่าน
  // แจ้งผลแบบเดียวกันเสมอไม่ว่ามีบัญชีหรือไม่ (กันการใช้หน้านี้ตรวจว่าอีเมลไหนมีบัญชี)
  Future<void> _handleForgotPassword(String email) async {
    final e = email.trim();
    if (e.isEmpty) {
      _showSnack(tr('กรุณากรอกอีเมลก่อนกด "ลืมรหัสผ่าน"', 'Please enter your email before tapping "Forgot password"'), isError: true);
      return;
    }
    if (!isValidEmail(e)) {
      _showSnack(tr('รูปแบบอีเมลไม่ถูกต้อง', 'Invalid email format'), isError: true);
      return;
    }
    final last = _lastResetEmailAt;
    if (last != null && DateTime.now().difference(last) < const Duration(seconds: 60)) {
      final wait = 60 - DateTime.now().difference(last).inSeconds;
      _showSnack(tr('เพิ่งส่งลิงก์ไปแล้ว กรุณารอ $wait วินาทีก่อนส่งใหม่', 'Link just sent. Please wait $wait s before sending again'), isError: true);
      return;
    }
    _lastResetEmailAt = DateTime.now();
    try {
      await _authService.sendPasswordResetEmail(e);
    } on FirebaseAuthException catch (err) {
      if (err.code == 'network-request-failed' || err.code == 'too-many-requests') {
        _lastResetEmailAt = null;
        if (mounted) {
          _showSnack(tr('ส่งอีเมลไม่สำเร็จ กรุณาลองอีกครั้ง', 'Could not send email. Please try again'), isError: true);
        }
        return;
      }
      // user-not-found ฯลฯ → แสดงข้อความเดียวกับสำเร็จ
    } catch (_) {}
    if (mounted) {
      _showSnack(tr('ถ้ามีบัญชีที่ใช้อีเมล $e ระบบจะส่งลิงก์รีเซ็ตรหัสผ่านไปให้ภายในไม่กี่นาที',
          'If an account exists for $e, a password reset link will arrive in a few minutes'), isError: false);
    }
  }

  void _showSnack(String message, {required bool isError}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message,
          style: GoogleFonts.inter(
              color: Colors.white, fontWeight: FontWeight.w500)),
      backgroundColor:
          isError ? const Color(0xFFE53935) : const Color(0xFF2E7D32),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: const EdgeInsets.all(16),
      duration: const Duration(seconds: 4),
    ));
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    context.watch<LanguageProvider>(); // rebuild เมื่อสลับภาษา
    final pal = context.pal;
    // ไล่สีพื้นหลัง 3 จุด (ต้น → ปลาย ของแอนิเมชัน) ตามธีม
    final bgFrom = pal.isDark
        ? const [Color(0xFF0A0A0F), Color(0xFF12080E), Color(0xFF1A0A06)]
        : const [Color(0xFFFAFAF7), Color(0xFFF8F3EE), Color(0xFFFFEDE3)];
    final bgTo = pal.isDark
        ? const [Color(0xFF0F0A1A), Color(0xFF0D0D18), Color(0xFF180808)]
        : const [Color(0xFFF5F5F0), Color(0xFFFBF1EA), Color(0xFFFFE6D8)];
    return Scaffold(
      body: AnimatedBuilder(
        animation: _bgController,
        builder: (context, child) => Container(
          width: double.infinity,
          height: double.infinity,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                for (int i = 0; i < 3; i++)
                  Color.lerp(bgFrom[i], bgTo[i], _bgController.value)!,
              ],
              stops: const [0.0, 0.5, 1.0],
            ),
          ),
          child: child,
        ),
        child: Stack(
          children: [
            _blob(
                left: -80,
                top: size.height * 0.05,
                sz: 320,
                color: const Color(0xFFFC4C02).withValues(alpha: 0.12)),
            _blob(
                right: -100,
                top: size.height * 0.3,
                sz: 280,
                color: const Color(0xFFFF6B35).withValues(alpha: 0.08)),
            _blob(
                left: size.width * 0.2,
                bottom: 0,
                sz: 350,
                color: const Color(0xFFFC4C02).withValues(alpha: 0.07)),
            ..._particles(size),
            SafeArea(
              child: FadeTransition(
                opacity: _fadeAnim,
                child: SlideTransition(
                  position: _slideAnim,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 28),
                    child: Column(
                      children: [
                        const SizedBox(height: 32),
                        _buildLogo(),
                        const SizedBox(height: 24),
                        _buildAppTitle(),
                        const SizedBox(height: 32),
                        _buildTabBar(),
                        const SizedBox(height: 24),
                        FadeTransition(
                          opacity: _formFade,
                          child: _tabIndex == 0
                              ? _LoginForm(
                                  isLoading: _isLoading,
                                  initialEmail: _prefilledEmail,
                                  onLogin: _handleEmailLogin,
                                  onForgotPassword: _handleForgotPassword,
                                  onGoogleSignIn: _handleGoogleSignIn,
                                )
                              : _RegisterForm(
                                  isLoading: _isLoading,
                                  onRegister: _handleRegister,
                                  onGoogleSignIn: _handleGoogleSignIn,
                                ),
                        ),
                        const SizedBox(height: 20),
                        Text(
                          tr('การเข้าสู่ระบบถือว่าคุณยอมรับ Terms of Service\nและ Privacy Policy ของเรา', 'By signing in you agree to our Terms of Service\nand Privacy Policy'),
                          textAlign: TextAlign.center,
                          style: GoogleFonts.inter(
                              fontSize: 11.5,
                              color: pal.textMute,
                              height: 1.6),
                        ),
                        const SizedBox(height: 24),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Sub-Widgets ──────────────────────────────────────────────────────────

  Widget _blob(
      {double? left,
      double? right,
      double? top,
      double? bottom,
      required double sz,
      required Color color}) {
    return Positioned(
      left: left,
      right: right,
      top: top,
      bottom: bottom,
      child: Container(
          width: sz,
          height: sz,
          decoration:
              BoxDecoration(shape: BoxShape.circle, color: color)),
    );
  }

  List<Widget> _particles(Size size) {
    final rng = math.Random(42);
    return List.generate(18, (i) {
      final x = rng.nextDouble() * size.width;
      final y = rng.nextDouble() * size.height;
      final ps = rng.nextDouble() * 3 + 1;
      final op = rng.nextDouble() * 0.4 + 0.1;
      return Positioned(
        left: x,
        top: y,
        child: AnimatedBuilder(
          animation: _orbitAnim,
          builder: (_, child) => Transform.translate(
            offset: Offset(0, math.sin(_orbitAnim.value + i * 0.7) * 6),
            child: Container(
              width: ps,
              height: ps,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFFFC4C02).withValues(alpha: op),
              ),
            ),
          ),
        ),
      );
    });
  }

  Widget _buildLogo() {
    return ScaleTransition(
      scale: _scaleAnim,
      child: AnimatedBuilder(
        animation: _pulseAnim,
        builder: (_, child) => Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFFC4C02)
                    .withValues(alpha: 0.5 * _pulseAnim.value),
                blurRadius: 60 * _pulseAnim.value,
                spreadRadius: 10 * _pulseAnim.value,
              ),
              BoxShadow(
                  color: const Color(0xFFFF6B35).withValues(alpha: 0.3),
                  blurRadius: 30,
                  spreadRadius: 2),
            ],
          ),
          child: child,
        ),
        child: AnimatedBuilder(
          animation: _orbitAnim,
          builder: (_, child) => Stack(
            alignment: Alignment.center,
            children: [
              CustomPaint(
                painter: _OrbitRingPainter(
                    angle: _orbitAnim.value,
                    radius: 72,
                    color:
                        const Color(0xFFFC4C02).withValues(alpha: 0.25)),
                size: const Size(160, 160),
              ),
              CustomPaint(
                painter: _OrbitRingPainter(
                    angle: -_orbitAnim.value * 1.5,
                    radius: 56,
                    color:
                        const Color(0xFFFF6B35).withValues(alpha: 0.2)),
                size: const Size(160, 160),
              ),
              child!,
            ],
          ),
          child: Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFFFF7043),
                  Color(0xFFFC4C02),
                  Color(0xFFD84315)
                ],
              ),
              border: Border.all(
                  color: const Color(0xFFFF6B35).withValues(alpha: 0.4),
                  width: 1.5),
            ),
            child: const Icon(Icons.directions_run_rounded,
                color: Colors.white, size: 40),
          ),
        ),
      ),
    );
  }

  Widget _buildAppTitle() {
    final lang = context.read<LanguageProvider>();
    final pal = context.pal;
    return Column(
      children: [
        // สลับภาษาได้ตั้งแต่หน้าเข้าสู่ระบบ
        Align(
          alignment: Alignment.centerRight,
          child: GestureDetector(
            onTap: lang.toggleLanguage,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: pal.surface2,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: pal.border),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.language, size: 14, color: pal.textSub),
                const SizedBox(width: 6),
                Text(lang.isThai ? 'ไทย · EN' : 'EN · ไทย',
                    style: TextStyle(color: pal.textSub, fontSize: 12, fontWeight: FontWeight.w600)),
              ]),
            ),
          ),
        ),
        const SizedBox(height: 8),
        ShaderMask(
          shaderCallback: (bounds) => LinearGradient(
            colors: [pal.text, pal.textSub],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ).createShader(bounds),
          child: Text(
            'Running Route Finder',
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
                fontSize: 28,
                fontWeight: FontWeight.w800,
                color: Colors.white,
                height: 1.15,
                letterSpacing: -0.5),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          tr('ค้นหาเส้นทางวิ่งที่ดีที่สุดในเชียงใหม่', 'Find the best running routes in Chiang Mai'),
          textAlign: TextAlign.center,
          style: GoogleFonts.inter(
              fontSize: 13, color: pal.textSub, height: 1.6),
        ),
      ],
    );
  }

  Widget _buildTabBar() {
    final pal = context.pal;
    return Container(
      height: 48,
      decoration: BoxDecoration(
        color: pal.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: pal.border),
      ),
      child: Row(
        children: [
          _tabItem(0, tr('เข้าสู่ระบบ', 'Sign In'), Icons.login_rounded),
          _tabItem(1, tr('สมัครสมาชิก', 'Sign Up'), Icons.person_add_rounded),
        ],
      ),
    );
  }

  Widget _tabItem(int index, String label, IconData icon) {
    final isActive = _tabIndex == index;
    final idle = context.pal.textMute;
    return Expanded(
      child: GestureDetector(
        onTap: () => _switchTab(index),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeInOut,
          margin: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: isActive ? const Color(0xFFFC4C02) : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            boxShadow: isActive
                ? [
                    BoxShadow(
                        color: const Color(0xFFFC4C02).withValues(alpha: 0.4),
                        blurRadius: 12,
                        offset: const Offset(0, 4))
                  ]
                : [],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon,
                  size: 16,
                  color:
                      isActive ? Colors.white : idle),
              const SizedBox(width: 6),
              Text(
                label,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight:
                      isActive ? FontWeight.w700 : FontWeight.w500,
                  color: isActive
                      ? Colors.white
                      : idle,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Login Form ───────────────────────────────────────────────────────────────

class _LoginForm extends StatefulWidget {
  final bool isLoading;
  final String? initialEmail;
  final Future<void> Function(String email, String password) onLogin;
  final Future<void> Function(String email) onForgotPassword;
  final Future<void> Function() onGoogleSignIn;

  const _LoginForm({
    required this.isLoading,
    this.initialEmail,
    required this.onLogin,
    required this.onForgotPassword,
    required this.onGoogleSignIn,
  });

  @override
  State<_LoginForm> createState() => _LoginFormState();
}

class _LoginFormState extends State<_LoginForm> {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _obscurePass = true;

  @override
  void initState() {
    super.initState();
    if (widget.initialEmail != null && widget.initialEmail!.isNotEmpty) {
      _emailCtrl.text = widget.initialEmail!;
    }
  }

  @override
  void didUpdateWidget(_LoginForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialEmail != null &&
        widget.initialEmail != oldWidget.initialEmail) {
      _emailCtrl.text = widget.initialEmail!;
    }
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState!.validate()) {
      widget.onLogin(_emailCtrl.text.trim().toLowerCase(), _passCtrl.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Email Field
          _AuthField(
            controller: _emailCtrl,
            label: tr('อีเมล', 'Email'),
            hint: 'example@email.com',
            icon: Icons.email_outlined,
            keyboardType: TextInputType.emailAddress,
            maxLength: 254,
            autofillHints: const [AutofillHints.email],
            validator: _validateEmail,
          ),
          const SizedBox(height: 16),

          // Password Field
          _AuthField(
            controller: _passCtrl,
            label: tr('รหัสผ่าน', 'Password'),
            hint: '••••••••',
            icon: Icons.lock_outline_rounded,
            obscureText: _obscurePass,
            suffixIcon: IconButton(
              icon: Icon(
                _obscurePass
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
                color: context.pal.textMute,
                size: 20,
              ),
              onPressed: () => setState(() => _obscurePass = !_obscurePass),
            ),
            maxLength: PasswordPolicy.maxLength,
            autofillHints: const [AutofillHints.password],
            onSubmitted: (_) => _submit(),
            validator: (v) {
              if (v == null || v.isEmpty) return tr('กรุณากรอกรหัสผ่าน', 'Please enter your password');
              return null;
            },
          ),
          const SizedBox(height: 10),

          // Forgot Password — Alternative Flow A1
          Align(
            alignment: Alignment.centerRight,
            child: GestureDetector(
              onTap: () => widget.onForgotPassword(_emailCtrl.text),
              child: Text(
                tr('ลืมรหัสผ่าน?', 'Forgot password?'),
                style: GoogleFonts.inter(
                  fontSize: 13,
                  color: const Color(0xFFFC4C02),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),

          // Login Button
          _AuthButton(
            label: tr('เข้าสู่ระบบ', 'Sign In'),
            isLoading: widget.isLoading,
            onTap: _submit,
            isPrimary: true,
          ),
          const SizedBox(height: 24),

          // Divider
          _orDivider(context),
          const SizedBox(height: 20),

          // Google Sign-In
          _GoogleButton(
            label: tr('เข้าสู่ระบบด้วย Google', 'Sign in with Google'),
            isLoading: widget.isLoading,
            onTap: widget.onGoogleSignIn,
          ),
        ],
      ),
    );
  }
}

// ─── Register Form ────────────────────────────────────────────────────────────

class _RegisterForm extends StatefulWidget {
  final bool isLoading;
  final Future<void> Function(String name, String email, String password)
      onRegister;
  final Future<void> Function() onGoogleSignIn;

  const _RegisterForm({
    required this.isLoading,
    required this.onRegister,
    required this.onGoogleSignIn,
  });

  @override
  State<_RegisterForm> createState() => _RegisterFormState();
}

class _RegisterFormState extends State<_RegisterForm> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _confirmPassCtrl = TextEditingController();
  bool _obscurePass = true;
  bool _obscureConfirm = true;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _passCtrl.dispose();
    _confirmPassCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState!.validate()) {
      widget.onRegister(_nameCtrl.text.trim(), _emailCtrl.text.trim().toLowerCase(), _passCtrl.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Name Field
          _AuthField(
            controller: _nameCtrl,
            label: tr('ชื่อผู้ใช้', 'Username'),
            hint: tr('ชื่อที่แสดงในแอป', 'Display name in the app'),
            icon: Icons.person_outline_rounded,
            maxLength: 30,
            autofillHints: const [AutofillHints.name],
            validator: (v) {
              if (v == null || v.trim().isEmpty) return tr('กรุณากรอกชื่อผู้ใช้', 'Please enter a username');
              if (v.trim().length < 2) return tr('ชื่อต้องมีอย่างน้อย 2 ตัวอักษร', 'Name must be at least 2 characters');
              if (v.trim().length > 30) return tr('ชื่อยาวได้ไม่เกิน 30 ตัวอักษร', 'Name must be at most 30 characters');
              if (RegExp(r'[<>{}\\/"`\u0000-\u001F]').hasMatch(v)) {
                return tr('ชื่อมีอักขระที่ไม่อนุญาต (< > { } / \\ " `)', 'Name contains characters that are not allowed (< > { } / \\ " `)');
              }
              return null;
            },
          ),
          const SizedBox(height: 16),

          // Email Field
          _AuthField(
            controller: _emailCtrl,
            label: tr('อีเมล', 'Email'),
            hint: 'example@email.com',
            icon: Icons.email_outlined,
            keyboardType: TextInputType.emailAddress,
            maxLength: 254,
            autofillHints: const [AutofillHints.email],
            validator: _validateEmail,
          ),
          const SizedBox(height: 16),

          // Password Field
          _AuthField(
            controller: _passCtrl,
            label: tr('รหัสผ่าน', 'Password'),
            hint: tr('อย่างน้อย 8 ตัว มี A-z 0-9 และสัญลักษณ์', '8+ chars with A-z, 0-9 and a symbol'),
            icon: Icons.lock_outline_rounded,
            obscureText: _obscurePass,
            suffixIcon: IconButton(
              icon: Icon(
                _obscurePass
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
                color: context.pal.textMute,
                size: 20,
              ),
              onPressed: () => setState(() => _obscurePass = !_obscurePass),
            ),
            maxLength: PasswordPolicy.maxLength,
            autofillHints: const [AutofillHints.newPassword],
            onChanged: (_) => setState(() {}),
            validator: (v) => PasswordPolicy.validate(v,
                email: _emailCtrl.text, name: _nameCtrl.text),
          ),
          const SizedBox(height: 10),
          _PasswordStrength(password: _passCtrl.text),
          const SizedBox(height: 16),

          // Confirm Password Field
          _AuthField(
            controller: _confirmPassCtrl,
            label: tr('ยืนยันรหัสผ่าน', 'Confirm password'),
            hint: tr('กรอกรหัสผ่านอีกครั้ง', 'Re-enter your password'),
            icon: Icons.lock_person_outlined,
            obscureText: _obscureConfirm,
            suffixIcon: IconButton(
              icon: Icon(
                _obscureConfirm
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
                color: context.pal.textMute,
                size: 20,
              ),
              onPressed: () =>
                  setState(() => _obscureConfirm = !_obscureConfirm),
            ),
            maxLength: PasswordPolicy.maxLength,
            autofillHints: const [AutofillHints.newPassword],
            validator: (v) {
              if (v == null || v.isEmpty) return tr('กรุณายืนยันรหัสผ่าน', 'Please confirm your password');
              if (v != _passCtrl.text) return tr('รหัสผ่านไม่ตรงกัน', 'Passwords do not match');
              return null;
            },
          ),
          const SizedBox(height: 28),

          // Register Button
          _AuthButton(
            label: tr('สมัครสมาชิก', 'Sign Up'),
            isLoading: widget.isLoading,
            onTap: _submit,
            isPrimary: true,
          ),
          const SizedBox(height: 24),

          // Divider
          _orDivider(context),
          const SizedBox(height: 20),

          // Google Sign-In
          _GoogleButton(
            label: tr('สมัครด้วย Google', 'Sign up with Google'),
            isLoading: widget.isLoading,
            onTap: widget.onGoogleSignIn,
          ),
        ],
      ),
    );
  }
}

// ─── Shared Widgets ───────────────────────────────────────────────────────────

Widget _orDivider(BuildContext context) {
  final pal = context.pal;
  return Row(
    children: [
      Expanded(
          child: Container(
              height: 1,
              decoration: BoxDecoration(
                  gradient: LinearGradient(
                      colors: [pal.border.withValues(alpha: 0), pal.border])))),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text(tr('หรือ', 'or'),
            style: GoogleFonts.inter(
                fontSize: 12,
                color: pal.textMute,
                fontWeight: FontWeight.w500)),
      ),
      Expanded(
          child: Container(
              height: 1,
              decoration: BoxDecoration(
                  gradient: LinearGradient(
                      colors: [pal.border, pal.border.withValues(alpha: 0)])))),
    ],
  );
}

// ─── Auth Input Field ─────────────────────────────────────────────────────────

class _AuthField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String hint;
  final IconData icon;
  final bool obscureText;
  final Widget? suffixIcon;
  final TextInputType? keyboardType;
  final String? Function(String?)? validator;
  final int? maxLength;
  final Iterable<String>? autofillHints;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  const _AuthField({
    required this.controller,
    required this.label,
    required this.hint,
    required this.icon,
    this.obscureText = false,
    this.suffixIcon,
    this.keyboardType,
    this.validator,
    this.maxLength,
    this.autofillHints,
    this.onChanged,
    this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: pal.textSub,
            )),
        const SizedBox(height: 8),
        TextFormField(
          controller: controller,
          obscureText: obscureText,
          keyboardType: keyboardType,
          validator: validator,
          autofillHints: autofillHints,
          onChanged: onChanged,
          onFieldSubmitted: onSubmitted,
          // ช่องรหัสผ่าน: ไม่ให้คีย์บอร์ดจำ/แนะนำคำ
          autocorrect: !obscureText && keyboardType != TextInputType.emailAddress,
          enableSuggestions: !obscureText,
          inputFormatters: [
            if (maxLength != null) LengthLimitingTextInputFormatter(maxLength),
            if (obscureText || keyboardType == TextInputType.emailAddress)
              FilteringTextInputFormatter.deny(RegExp(r'\s')),
          ],
          style: GoogleFonts.inter(
              color: pal.text, fontSize: 14, fontWeight: FontWeight.w500),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: GoogleFonts.inter(
                color: pal.textMute, fontSize: 14),
            prefixIcon: Icon(icon, color: pal.textMute, size: 20),
            suffixIcon: suffixIcon,
            filled: true,
            fillColor: pal.surface,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: pal.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: pal.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide:
                  const BorderSide(color: Color(0xFFFC4C02), width: 1.5),
            ),
            errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide:
                  const BorderSide(color: Color(0xFFE53935), width: 1.5),
            ),
            focusedErrorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide:
                  const BorderSide(color: Color(0xFFE53935), width: 1.5),
            ),
            errorStyle: GoogleFonts.inter(
                color: const Color(0xFFE53935), fontSize: 12),
          ),
        ),
      ],
    );
  }
}

// ─── Primary Action Button ────────────────────────────────────────────────────

class _AuthButton extends StatefulWidget {
  final String label;
  final bool isLoading;
  final VoidCallback onTap;
  final bool isPrimary;

  const _AuthButton({
    required this.label,
    required this.isLoading,
    required this.onTap,
    this.isPrimary = true,
  });

  @override
  State<_AuthButton> createState() => _AuthButtonState();
}

class _AuthButtonState extends State<_AuthButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 110));
  late final Animation<double> _scale = Tween<double>(begin: 1.0, end: 0.97)
      .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _ctrl.forward(),
      onTapUp: (_) {
        _ctrl.reverse();
        if (!widget.isLoading) widget.onTap();
      },
      onTapCancel: () => _ctrl.reverse(),
      child: ScaleTransition(
        scale: _scale,
        child: Container(
          height: 54,
          decoration: BoxDecoration(
            gradient: widget.isPrimary
                ? const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFFFF6B35), Color(0xFFFC4C02), Color(0xFFD84315)],
                  )
                : null,
            color: widget.isPrimary ? null : context.pal.surface,
            borderRadius: BorderRadius.circular(14),
            border: widget.isPrimary
                ? null
                : Border.all(color: context.pal.border),
            boxShadow: widget.isPrimary
                ? [
                    BoxShadow(
                        color: const Color(0xFFFC4C02).withValues(alpha: 0.4),
                        blurRadius: 20,
                        offset: const Offset(0, 8))
                  ]
                : [
                    BoxShadow(
                        color: context.pal.shadow,
                        blurRadius: 12,
                        offset: const Offset(0, 4))
                  ],
          ),
          child: Center(
            child: widget.isLoading
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.5, color: Colors.white))
                : Text(
                    widget.label,
                    style: GoogleFonts.inter(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        letterSpacing: 0.3),
                  ),
          ),
        ),
      ),
    );
  }
}

// ─── Google Button ────────────────────────────────────────────────────────────

class _GoogleButton extends StatefulWidget {
  final String label;
  final bool isLoading;
  final Future<void> Function() onTap;

  const _GoogleButton({
    required this.label,
    required this.isLoading,
    required this.onTap,
  });

  @override
  State<_GoogleButton> createState() => _GoogleButtonState();
}

class _GoogleButtonState extends State<_GoogleButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 110));
  late final Animation<double> _scale = Tween<double>(begin: 1.0, end: 0.97)
      .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _ctrl.forward(),
      onTapUp: (_) {
        _ctrl.reverse();
        if (!widget.isLoading) widget.onTap();
      },
      onTapCancel: () => _ctrl.reverse(),
      child: ScaleTransition(
        scale: _scale,
        child: Container(
          height: 54,
          decoration: BoxDecoration(
            color: context.pal.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: context.pal.border),
            boxShadow: [
              BoxShadow(
                  color: context.pal.shadow,
                  blurRadius: 16,
                  offset: const Offset(0, 6))
            ],
          ),
          child: widget.isLoading
              ? const Center(
                  child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                          strokeWidth: 2.5, color: Color(0xFFFC4C02))))
              : Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _GoogleLogo(hole: context.pal.surface),
                    const SizedBox(width: 12),
                    Text(
                      widget.label,
                      style: GoogleFonts.inter(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: context.pal.text,
                          letterSpacing: 0.2),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

// ─── Google Logo (CustomPainter) ──────────────────────────────────────────────

class _GoogleLogo extends StatelessWidget {
  /// สีพื้นของปุ่ม (ใช้ระบายรูตรงกลางตัว G)
  final Color hole;
  const _GoogleLogo({required this.hole});
  @override
  Widget build(BuildContext context) =>
      SizedBox(width: 22, height: 22, child: CustomPaint(painter: _GoogleLogoPainter(hole)));
}

class _GoogleLogoPainter extends CustomPainter {
  final Color hole;
  _GoogleLogoPainter(this.hole);
  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2;
    final colors = [
      const Color(0xFF4285F4),
      const Color(0xFF34A853),
      const Color(0xFFFBBC05),
      const Color(0xFFEA4335)
    ];
    final starts = [
      -math.pi * 0.25,
      math.pi * 0.25,
      math.pi * 0.75,
      math.pi * 1.25
    ];
    for (int i = 0; i < 4; i++) {
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: r * 0.72),
        starts[i],
        math.pi * 0.5,
        false,
        Paint()
          ..color = colors[i]
          ..style = PaintingStyle.stroke
          ..strokeWidth = size.width * 0.22
          ..strokeCap = StrokeCap.butt,
      );
    }
    canvas.drawCircle(c, r * 0.42, Paint()..color = hole);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH(c.dx, c.dy - size.height * 0.12, r * 0.72,
              size.height * 0.24),
          const Radius.circular(2)),
      Paint()..color = const Color(0xFF4285F4),
    );
  }

  @override
  bool shouldRepaint(_GoogleLogoPainter o) => o.hole != hole;
}

// ─── Orbit Ring Painter ───────────────────────────────────────────────────────

class _OrbitRingPainter extends CustomPainter {
  final double angle;
  final double radius;
  final Color color;
  const _OrbitRingPainter(
      {required this.angle, required this.radius, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    const n = 12;
    const step = math.pi * 2 / n;
    for (int i = 0; i < n; i++) {
      canvas.drawArc(
          Rect.fromCircle(center: c, radius: radius),
          angle + i * step,
          step * 0.6,
          false,
          p);
    }
    final dotX = c.dx + radius * math.cos(angle);
    final dotY = c.dy + radius * math.sin(angle);
    canvas.drawCircle(
        Offset(dotX, dotY),
        3,
        Paint()
          ..color = color.withValues(alpha: 0.9)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
  }

  @override
  bool shouldRepaint(_OrbitRingPainter o) => o.angle != angle;
}

// ─── Email validation ─────────────────────────────────────────────────────────

/// รูปแบบอีเมลมาตรฐาน (ส่วนหน้า@โดเมน.นามสกุล ≥ 2 ตัว) ยาวไม่เกิน 254 ตัว
bool isValidEmail(String email) {
  final e = email.trim();
  if (e.isEmpty || e.length > 254) return false;
  return RegExp(r"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*\.[A-Za-z]{2,}$")
      .hasMatch(e);
}

String? _validateEmail(String? v) {
  if (v == null || v.trim().isEmpty) return tr('กรุณากรอกอีเมล', 'Please enter your email');
  if (!isValidEmail(v)) return tr('รูปแบบอีเมลไม่ถูกต้อง', 'Invalid email format');
  return null;
}

// ─── Password strength meter + checklist ──────────────────────────────────────

class _PasswordStrength extends StatelessWidget {
  final String password;
  const _PasswordStrength({required this.password});

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final level = PasswordPolicy.strength(password);
    const colors = [
      Color(0xFFE53935), Color(0xFFE53935), Color(0xFFF39C12),
      Color(0xFF2ECC71), Color(0xFF1A9950),
    ];
    final labels = [
      tr('ยังไม่ได้กรอก', 'Empty'),
      tr('อ่อนมาก', 'Very weak'),
      tr('พอใช้', 'Fair'),
      tr('แข็งแรง', 'Strong'),
      tr('แข็งแรงมาก', 'Very strong'),
    ];
    final rules = <(bool, String)>[
      (PasswordPolicy.hasLength(password), tr('8–64 ตัวอักษร', '8–64 characters')),
      (PasswordPolicy.hasUpper(password) && PasswordPolicy.hasLower(password),
          tr('ตัวพิมพ์ใหญ่และเล็ก', 'Upper & lowercase')),
      (PasswordPolicy.hasDigit(password), tr('ตัวเลข', 'A number')),
      (PasswordPolicy.hasSpecial(password), tr('สัญลักษณ์ เช่น ! @ #', 'A symbol, e.g. ! @ #')),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          for (int i = 1; i <= 4; i++)
            Expanded(
              child: Container(
                height: 5,
                margin: EdgeInsets.only(right: i < 4 ? 4 : 0),
                decoration: BoxDecoration(
                  color: level >= i ? colors[level] : pal.border,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          const SizedBox(width: 10),
          Text(labels[level],
              style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: level == 0 ? pal.textMute : colors[level])),
        ]),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 4,
          children: [
            for (final r in rules)
              Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(r.$1 ? Icons.check_circle_rounded : Icons.radio_button_unchecked,
                    size: 14, color: r.$1 ? const Color(0xFF2ECC71) : pal.textMute),
                const SizedBox(width: 4),
                Text(r.$2,
                    style: GoogleFonts.inter(
                        fontSize: 11, color: r.$1 ? pal.textSub : pal.textMute)),
              ]),
          ],
        ),
      ],
    );
  }
}
