import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:provider/provider.dart';
import 'firebase_options.dart';
import 'providers/theme_provider.dart';
import 'providers/language_provider.dart';
import 'providers/notification_provider.dart';
import 'services/auth_service.dart';
import 'services/push_service.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'widgets/suspension_guard.dart';
String? _firebaseError;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  } on FirebaseException catch (e) {
    if (e.code != 'duplicate-app') _firebaseError = 'FirebaseException: ${e.message}';
  } catch (e) {
    _firebaseError = e.toString();
  }
  if (_firebaseError == null) {
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    await PushService.init();
  }
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider(create: (_) => LanguageProvider()),
        ChangeNotifierProvider(create: (_) => NotificationProvider()),
      ],
      child: Consumer<ThemeProvider>(
        builder: (context, themeProvider, _) {
          // Sync system status bar icons with current brightness
          SystemChrome.setSystemUIOverlayStyle(
            themeProvider.isDark
                ? const SystemUiOverlayStyle(
                    statusBarColor: Colors.transparent,
                    statusBarIconBrightness: Brightness.light,
                    systemNavigationBarColor: AppColors.dkSurface,
                    systemNavigationBarIconBrightness: Brightness.light,
                  )
                : const SystemUiOverlayStyle(
                    statusBarColor: Colors.transparent,
                    statusBarIconBrightness: Brightness.dark,
                    systemNavigationBarColor: AppColors.ltSurface,
                    systemNavigationBarIconBrightness: Brightness.dark,
                  ),
          );
          return MaterialApp(
            title: 'Running Route Finder',
            debugShowCheckedModeBanner: false,
            theme: themeProvider.lightTheme,
            darkTheme: themeProvider.darkTheme,
            themeMode: themeProvider.isDark ? ThemeMode.dark : ThemeMode.light,
            home: const AuthGate(),
          );
        },
      ),
    );
  }
}


/// Listens to Firebase auth state and routes to Login or Home accordingly.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    // If Firebase failed to initialize, show error
    if (_firebaseError != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, color: Colors.red, size: 64),
                const SizedBox(height: 16),
                const Text(
                  'Firebase Init Error',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                Text(
                  _firebaseError!,
                  style: TextStyle(color: context.pal.textSub, fontSize: 14),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      );
    }

    // LoginScreen อยู่ตำแหน่งเดิมในต้นไม้วิดเจ็ตเสมอ (StreamBuilder → ValueListenableBuilder)
    // ระหว่างตรวจสอบการเข้าสู่ระบบ state ของฟอร์ม/ข้อความแจ้งเตือนจึงไม่หาย
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        // Show loading while checking auth state
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(
              child: CircularProgressIndicator(
                color: AppColors.primary,
              ),
            ),
          );
        }
        return ValueListenableBuilder<bool>(
          valueListenable: AuthService.authInProgress,
          builder: (context, inProgress, _) {
            final user = snapshot.data;
            if (user != null && !inProgress) {
              // บัญชีที่ยังไม่ยืนยันอีเมล (เช่น ปิดแอประหว่างตรวจสอบ) → ออกจากระบบ
              if (AuthService.requiresEmailVerification(user)) {
                WidgetsBinding.instance
                    .addPostFrameCallback((_) => FirebaseAuth.instance.signOut());
                return const LoginScreen();
              }
              // บัญชีที่ผู้ดูแลระบบระงับ → แสดงหน้าแจ้งระงับแทน (Manage User Accounts)
              return SuspensionGuard(key: ValueKey(user.uid), user: user, child: const HomeScreen());
            }
            return const LoginScreen();
          },
        );
      },
    );
  }
}
