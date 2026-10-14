import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';
import '../providers/theme_provider.dart';
import '../providers/language_provider.dart';
import '../l10n/app_strings.dart';
import '../models/activity.dart';
import '../services/auth_service.dart';
import '../services/firestore_service.dart';
import '../services/emergency_contact_service.dart';
import '../services/safety_service.dart';
import 'admin_dashboard_screen.dart';
import 'admin_routes_screen.dart';
import 'admin_zones_screen.dart';
import '../services/update_service.dart';
import '../l10n/tr.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  /// สีพื้น/ตัวอักษรตามธีมปัจจุบัน
  AppPalette get pal => context.pal;

  // index ของ distance badge ที่เลือกโชว์ใน slot แรก (0–5)
  int _selectedDistanceBadgeIndex = 0;
  String _displayName = 'Runner';
  String _emergencyName = '';
  String _emergencyPhone = '';
  String? _photoUrl;
  bool _isUpdatingPhoto = false;

  @override
  void initState() {
    super.initState();
    _displayName = FirebaseAuth.instance.currentUser?.displayName ?? 'Runner';
    _photoUrl = FirebaseAuth.instance.currentUser?.photoURL;
    _loadEmergencyContact();
    _loadProfilePhoto();
  }

  Future<void> _loadProfilePhoto() async {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isEmpty) return;

    // 1. SharedPreferences (เร็วที่สุด)
    try {
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString('profile_photo_$uid');
      if (cached != null && cached.isNotEmpty && mounted) {
        setState(() => _photoUrl = cached);
        return;
      }
    } catch (_) {}

    // 2. Firestore
    try {
      final doc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
      if (doc.exists && mounted) {
        final remotePhoto = doc.data()?['photoUrl'] as String?;
        if (remotePhoto != null && remotePhoto.isNotEmpty) {
          setState(() => _photoUrl = remotePhoto);
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('profile_photo_$uid', remotePhoto);
        }
      }
    } catch (_) {}
  }

  Future<void> _saveProfilePhoto(String photoData) async {
    final user = FirebaseAuth.instance.currentUser;
    final uid = user?.uid ?? '';

    // บันทึกลง SharedPreferences
    if (uid.isNotEmpty) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('profile_photo_$uid', photoData);
      } catch (_) {}
    }

    // บันทึกลง Firestore
    if (uid.isNotEmpty) {
      try {
        await FirebaseFirestore.instance.collection('users').doc(uid).set({
          'photoUrl': photoData,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      } catch (e) {
        debugPrint('[Profile] Firestore photo update failed: $e');
      }
    }

    // ถ้าเป็น HTTP URL ให้อัปเดตที่ FirebaseAuth ด้วย
    if (photoData.startsWith('http://') || photoData.startsWith('https://')) {
      try {
        await user?.updatePhotoURL(photoData);
        await user?.reload();
      } catch (e) {
        debugPrint('[Profile] FirebaseAuth updatePhotoURL failed: $e');
      }
    }

    // อัปเดตรูปในกิจกรรมทั้งหมดของผู้ใช้ใน Firestore ด้วย (ทั้ง Community และ My Activities)
    if (uid.isNotEmpty) {
      FirestoreService().updateUserActivitiesPhoto(uid, photoData);
    }

    if (mounted) {
      setState(() => _photoUrl = photoData);
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final picker = ImagePicker();
      final pickedFile = await picker.pickImage(
        source: source,
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 75,
      );
      if (pickedFile == null) return;

      setState(() => _isUpdatingPhoto = true);

      final bytes = await pickedFile.readAsBytes();
      final base64String = 'data:image/jpeg;base64,${base64Encode(bytes)}';

      await _saveProfilePhoto(base64String);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppStrings(isThai: context.read<LanguageProvider>().isThai).photoUpdated),
            backgroundColor: const Color(0xFFFC4C02),
          ),
        );
      }
    } catch (e) {
      debugPrint('[Profile] Error picking image: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${AppStrings(isThai: context.read<LanguageProvider>().isThai).errorPickingPhoto}$e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isUpdatingPhoto = false);
      }
    }
  }

  Future<void> _removeProfilePhoto() async {
    final user = FirebaseAuth.instance.currentUser;
    final uid = user?.uid ?? '';

    if (uid.isNotEmpty) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('profile_photo_$uid');
      } catch (_) {}

      try {
        await FirebaseFirestore.instance.collection('users').doc(uid).set({
          'photoUrl': '',
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      } catch (_) {}
    }

    try {
      await user?.updatePhotoURL(null);
      await user?.reload();
    } catch (_) {}

    if (uid.isNotEmpty) {
      FirestoreService().updateUserActivitiesPhoto(uid, '');
    }

    if (mounted) {
      setState(() => _photoUrl = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppStrings(isThai: context.read<LanguageProvider>().isThai).photoRemoved),
          backgroundColor: const Color(0xFF888888),
        ),
      );
    }
  }

  void _showChangePhotoBottomSheet() {
    final cs = Theme.of(context).colorScheme;
    final s = AppStrings(isThai: context.read<LanguageProvider>().isThai);

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.15),
              blurRadius: 20,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: cs.onSurface.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFC4C02).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.account_circle_rounded,
                        color: Color(0xFFFC4C02), size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          s.changePhoto,
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            color: cs.onSurface,
                          ),
                        ),
                        Text(
                          s.selectImageCommunity,
                          style: TextStyle(
                            fontSize: 12,
                            color: cs.onSurface.withValues(alpha: 0.5),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.pop(ctx),
                    color: cs.onSurface.withValues(alpha: 0.5),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              _buildPhotoOptionTile(
                icon: Icons.camera_alt_rounded,
                iconColor: const Color(0xFFFC4C02),
                title: s.takePhoto,
                subtitle: s.openCameraPhoto,
                onTap: () {
                  Navigator.pop(ctx);
                  _pickImage(ImageSource.camera);
                },
              ),
              const SizedBox(height: 10),
              _buildPhotoOptionTile(
                icon: Icons.photo_library_rounded,
                iconColor: const Color(0xFF3498DB),
                title: s.chooseGallery,
                subtitle: s.pickGalleryPhoto,
                onTap: () {
                  Navigator.pop(ctx);
                  _pickImage(ImageSource.gallery);
                },
              ),
              const SizedBox(height: 10),
              _buildPhotoOptionTile(
                icon: Icons.sports_score_rounded,
                iconColor: const Color(0xFF2ECC71),
                title: s.chooseAvatar,
                subtitle: s.chooseAvatarSubtitle,
                onTap: () {
                  Navigator.pop(ctx);
                  _showPresetAvatarsDialog();
                },
              ),
              const SizedBox(height: 10),
              _buildPhotoOptionTile(
                icon: Icons.link_rounded,
                iconColor: const Color(0xFF9B59B6),
                title: s.enterImageUrl,
                subtitle: s.enterImageUrlSubtitle,
                onTap: () {
                  Navigator.pop(ctx);
                  _showUrlInputDialog();
                },
              ),
              if (_photoUrl != null && _photoUrl!.isNotEmpty) ...[
                const SizedBox(height: 10),
                _buildPhotoOptionTile(
                  icon: Icons.delete_outline_rounded,
                  iconColor: Colors.red,
                  title: s.removePhoto,
                  subtitle: s.revertDefaultIcon,
                  isDestructive: true,
                  onTap: () {
                    Navigator.pop(ctx);
                    _removeProfilePhoto();
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPhotoOptionTile({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool isDestructive = false,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: isDestructive
                ? Colors.red.withValues(alpha: 0.06)
                : cs.surface.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isDestructive
                  ? Colors.red.withValues(alpha: 0.25)
                  : cs.outline.withValues(alpha: 0.5),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: iconColor, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: isDestructive ? Colors.red : cs.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        color: isDestructive
                            ? Colors.red.withValues(alpha: 0.7)
                            : cs.onSurface.withValues(alpha: 0.5),
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: isDestructive
                    ? Colors.red.withValues(alpha: 0.5)
                    : cs.onSurface.withValues(alpha: 0.3),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showPresetAvatarsDialog() {
    final presets = [
      {
        'title': 'Runner 1',
        'url': 'https://images.unsplash.com/photo-1534528741775-53994a69daeb?w=400&auto=format&fit=crop&q=80',
      },
      {
        'title': 'Runner 2',
        'url': 'https://images.unsplash.com/photo-1507003211169-0a1dd7228f2d?w=400&auto=format&fit=crop&q=80',
      },
      {
        'title': 'Runner 3',
        'url': 'https://images.unsplash.com/photo-1494790108377-be9c29b29330?w=400&auto=format&fit=crop&q=80',
      },
      {
        'title': 'Runner 4',
        'url': 'https://images.unsplash.com/photo-1500648767791-00dcc994a43e?w=400&auto=format&fit=crop&q=80',
      },
      {
        'title': 'Runner 5',
        'url': 'https://images.unsplash.com/photo-1517841905240-472988babdf9?w=400&auto=format&fit=crop&q=80',
      },
      {
        'title': 'Runner 6',
        'url': 'https://images.unsplash.com/photo-1539571696357-5a69c17a67c6?w=400&auto=format&fit=crop&q=80',
      },
      {
        'title': 'Runner 7',
        'url': 'https://images.unsplash.com/photo-1524504388940-b1c1722653e1?w=400&auto=format&fit=crop&q=80',
      },
      {
        'title': 'Runner 8',
        'url': 'https://images.unsplash.com/photo-1438761681033-6461ffad8d80?w=400&auto=format&fit=crop&q=80',
      },
    ];

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        final cs = Theme.of(context).colorScheme;
        return Container(
          height: MediaQuery.of(context).size.height * 0.60,
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: Column(
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: cs.onSurface.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Text(
                    AppStrings(isThai: context.read<LanguageProvider>().isThai).chooseAvatar,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: cs.onSurface,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Expanded(
                child: GridView.builder(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    crossAxisSpacing: 14,
                    mainAxisSpacing: 14,
                    childAspectRatio: 1,
                  ),
                  itemCount: presets.length,
                  itemBuilder: (_, i) {
                    final item = presets[i];
                    final isSelected = _photoUrl == item['url'];
                    return GestureDetector(
                      onTap: () async {
                        Navigator.pop(ctx);
                        setState(() => _isUpdatingPhoto = true);
                        try {
                          await _saveProfilePhoto(item['url']!);
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(AppStrings(isThai: context.read<LanguageProvider>().isThai).photoUpdated),
                                backgroundColor: const Color(0xFFFC4C02),
                              ),
                            );
                          }
                        } finally {
                          if (mounted) {
                            setState(() => _isUpdatingPhoto = false);
                          }
                        }
                      },
                      child: Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: isSelected
                                ? const Color(0xFFFC4C02)
                                : Colors.transparent,
                            width: 3,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.1),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: ClipOval(
                          child: Image.network(
                            item['url']!,
                            fit: BoxFit.cover,
                            loadingBuilder: (_, child, progress) {
                              if (progress == null) return child;
                              return const Center(
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Color(0xFFFC4C02),
                                ),
                              );
                            },
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
      },
    );
  }

  Future<void> _showUrlInputDialog() async {
    final s = AppStrings(isThai: context.read<LanguageProvider>().isThai);
    final controller = TextEditingController();

    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          s.enterImageUrl,
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 18),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              s.enterImageUrlHint,
              style: TextStyle(fontSize: 13, color: pal.textMute),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                hintText: 'https://...',
                prefixIcon: const Icon(Icons.link_rounded, color: Color(0xFFFC4C02)),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Color(0xFFFC4C02), width: 2),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(s.cancel, style: TextStyle(color: pal.textMute)),
          ),
          ElevatedButton(
            onPressed: () {
              final text = controller.text.trim();
              if (text.isNotEmpty) Navigator.pop(ctx, text);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFC4C02),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: Text(s.save,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );

    if (url != null && url.isNotEmpty) {
      setState(() => _isUpdatingPhoto = true);
      try {
        await _saveProfilePhoto(url);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(s.photoUpdated),
              backgroundColor: const Color(0xFFFC4C02),
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${s.errorPrefix}$e')),
          );
        }
      } finally {
        if (mounted) {
          setState(() => _isUpdatingPhoto = false);
        }
      }
    }
  }

  Widget _buildAvatarImage(String? photoSource) {
    if (photoSource != null && photoSource.isNotEmpty) {
      if (photoSource.startsWith('data:image')) {
        try {
          final base64Part = photoSource.contains(',')
              ? photoSource.split(',').last
              : photoSource;
          final bytes = base64Decode(base64Part);
          return ClipOval(
            child: Image.memory(
              bytes,
              width: 90,
              height: 90,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => Icon(
                Icons.person,
                color: Theme.of(context).colorScheme.surface,
                size: 48,
              ),
            ),
          );
        } catch (_) {}
      } else if (photoSource.startsWith('http://') ||
          photoSource.startsWith('https://')) {
        return ClipOval(
          child: Image.network(
            photoSource,
            width: 90,
            height: 90,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) => Icon(
              Icons.person,
              color: Theme.of(context).colorScheme.surface,
              size: 48,
            ),
          ),
        );
      }
    }
    return Icon(
      Icons.person,
      color: Theme.of(context).colorScheme.surface,
      size: 48,
    );
  }

  Future<void> _loadEmergencyContact() async {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isEmpty) return;
    final contact = await EmergencyContactService.load(uid: uid);
    if (contact != null && mounted) {
      setState(() {
        _emergencyName = contact.name;
        _emergencyPhone = contact.phone;
      });
    }
  }

  Future<void> _showEditNicknameDialog() async {
    final s = AppStrings(isThai: context.read<LanguageProvider>().isThai);
    final controller = TextEditingController(text: _displayName);
    String? result;
    try {
      result = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text(s.editNickname,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLength: 30,
            decoration: InputDecoration(
              hintText: s.nicknameHint,
              counterText: '',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFFFC4C02), width: 2),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(s.cancel,
                  style: TextStyle(color: pal.textMute)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFC4C02),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              child: Text(s.save,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      );
    } finally {
      // dispose หลัง frame ถัดไป — ป้องกัน _dependents.isEmpty assertion
      // ขณะที่ dialog กำลัง animate ออก TextField ยังใช้ controller อยู่
      WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    }

    if (result != null && result.isNotEmpty) {
      try {
        await FirebaseAuth.instance.currentUser?.updateDisplayName(result);
        await FirebaseAuth.instance.currentUser?.reload();
        if (mounted) {
          setState(() => _displayName = result!);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(AppStrings(isThai: context.read<LanguageProvider>().isThai).nicknameUpdated),
              backgroundColor: const Color(0xFFFC4C02),
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${AppStrings(isThai: context.read<LanguageProvider>().isThai).errorPrefix}$e')),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final User? user = FirebaseAuth.instance.currentUser;
    final String email = user?.email ?? '';
    final String? photoUrl = _photoUrl ?? user?.photoURL;
    final String uid = user?.uid ?? '';
    final svc = FirestoreService();
    final lp = context.watch<LanguageProvider>();
    final s = AppStrings(isThai: lp.isThai);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // 🖼️ Wallpaper Background for Profile/Stats
          Positioned.fill(
            child: Image.asset(
              'assets/images/propic3.jpg',
              fit: BoxFit.cover,
              errorBuilder: (ctx, err, stack) =>
                  Container(color: pal.bg),
            ),
          ),
          // 🌫️ Soft Light Overlay (Reduced opacity to make image vivid)
          Positioned.fill(
            child: Container(
              color: pal.bg.withValues(alpha: pal.isDark ? 0.88 : 0.55),
            ),
          ),
          // 📱 Foreground Profile & Stats Content
          CustomScrollView(
            slivers: [
              // ─── Profile Header ──────────────────────────────
              SliverToBoxAdapter(
                child: Container(
                  padding: const EdgeInsets.fromLTRB(20, 60, 20, 24),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.5),
                  ),
                  child: Column(
                    children: [
                      // Avatar with Camera Edit Button
                      GestureDetector(
                        onTap: _showChangePhotoBottomSheet,
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Container(
                              width: 90,
                              height: 90,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: const LinearGradient(
                                    colors: [Color(0xFFFC4C02), Color(0xFFFF6B35)]),
                                boxShadow: [
                                  BoxShadow(
                                    color:
                                        const Color(0xFFFC4C02).withValues(alpha: 0.25),
                                    blurRadius: 20,
                                  ),
                                ],
                              ),
                              child: _isUpdatingPhoto
                                  ? const Center(
                                      child: SizedBox(
                                        width: 28,
                                        height: 28,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 3,
                                          color: Colors.white,
                                        ),
                                      ),
                                    )
                                  : _buildAvatarImage(photoUrl),
                            ),
                            Positioned(
                              right: -2,
                              bottom: -2,
                              child: Container(
                                width: 30,
                                height: 30,
                                decoration: BoxDecoration(
                                  color: const Color(0xFFFC4C02),
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: Theme.of(context).colorScheme.surface,
                                    width: 2.5,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(alpha: 0.2),
                                      blurRadius: 6,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: const Icon(
                                  Icons.camera_alt_rounded,
                                  size: 15,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_displayName,
                              style: TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.w800,
                                  color: Theme.of(context).colorScheme.onSurface)),
                          const SizedBox(width: 8),
                          GestureDetector(
                            onTap: _showEditNicknameDialog,
                            child: Container(
                              padding: const EdgeInsets.all(5),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFC4C02).withValues(alpha: 0.1),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.edit_rounded,
                                  size: 15, color: Color(0xFFFC4C02)),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(email,
                          style: TextStyle(
                              color: pal.textSub, fontSize: 14)),
                    ],
                  ),
                ),
              ),

              // ─── Weekly Stats (Firestore) ────────────────────
              SliverToBoxAdapter(
                child: StreamBuilder<WeeklyStats>(
                  stream: svc.getWeeklyStats(uid),
                  builder: (ctx, snap) {
                    final stats = snap.data ?? const WeeklyStats();
                    return _buildWeeklyStats(context, stats, uid, svc);
                  },
                ),
              ),

              // ─── All-Time Stats (Firestore) ──────────────────
              SliverToBoxAdapter(
                child: StreamBuilder<AllTimeStats>(
                  stream: svc.getAllTimeStats(uid),
                  builder: (ctx, snap) {
                    final stats = snap.data ?? const AllTimeStats();
                    return _buildAllTimeStats(stats);
                  },
                ),
              ),

              // ─── Achievements (Firestore) ────────────────────
              SliverToBoxAdapter(
                child: StreamBuilder<AllTimeStats>(
                  stream: svc.getAllTimeStats(uid),
                  builder: (ctx, snap) {
                    final stats = snap.data ?? const AllTimeStats();
                    return _buildAchievements(stats);
                  },
                ),
              ),

              // ─── Personal Records (Firestore) ────────────────
              SliverToBoxAdapter(
                child: StreamBuilder<AllTimeStats>(
                  stream: svc.getAllTimeStats(uid),
                  builder: (ctx, snap) {
                    final stats = snap.data ?? const AllTimeStats();
                    return _buildPersonalRecords(stats);
                  },
                ),
              ),

              // ─── Emergency Contact ───────────────────────────
              SliverToBoxAdapter(
                child: _buildEmergencyContactSection(),
              ),

              // ─── Admin Section (เฉพาะ admin) ──────────
              if (AuthService.isUserAdmin(email))
                SliverToBoxAdapter(
                  child: Container(
                    margin: const EdgeInsets.fromLTRB(16, 20, 16, 0),
                    child: Column(
                      children: [
                        ElevatedButton.icon(
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => const AdminDashboardScreen()),
                            );
                          },
                          icon: const Icon(Icons.admin_panel_settings, size: 20),
                          label: Text(s.adminDashboard,
                              style: const TextStyle(
                                  fontFamily: 'Inter',
                                  fontWeight: FontWeight.w600,
                                  fontSize: 15)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Theme.of(context).colorScheme.surface.withValues(alpha: 0.95),
                            foregroundColor: const Color(0xFFFC4C02),
                            minimumSize: const Size.fromHeight(50),
                            side: const BorderSide(
                                color: Color(0xFFFC4C02), width: 1.5),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16)),
                          ),
                        ),
                        const SizedBox(height: 10),
                        ElevatedButton.icon(
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => const AdminRoutesScreen()),
                            );
                          },
                          icon: const Icon(Icons.edit_road, size: 20),
                          label: Text(tr('จัดการข้อมูลเส้นทาง', 'Manage Route Data'),
                              style: TextStyle(
                                  fontFamily: 'Inter',
                                  fontWeight: FontWeight.w600,
                                  fontSize: 15)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Theme.of(context).colorScheme.surface.withValues(alpha: 0.95),
                            foregroundColor: const Color(0xFF27AE60),
                            minimumSize: const Size.fromHeight(50),
                            side: const BorderSide(
                                color: Color(0xFF27AE60), width: 1.5),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16)),
                          ),
                        ),
                        const SizedBox(height: 10),
                        ElevatedButton.icon(
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => const AdminZonesScreen()),
                            );
                          },
                          icon: const Icon(Icons.map_outlined, size: 20),
                          label: Text(tr('จัดการข้อมูลโซนวิ่ง', 'Manage Running Zones'),
                              style: const TextStyle(
                                  fontFamily: 'Inter',
                                  fontWeight: FontWeight.w600,
                                  fontSize: 15)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Theme.of(context).colorScheme.surface.withValues(alpha: 0.95),
                            foregroundColor: const Color(0xFF3498DB),
                            minimumSize: const Size.fromHeight(50),
                            side: const BorderSide(
                                color: Color(0xFF3498DB), width: 1.5),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

              // ─── Theme Toggle ─────────────────────────────────
              SliverToBoxAdapter(
                child: Consumer<ThemeProvider>(
                  builder: (context, tp, _) {
                    final cs = Theme.of(context).colorScheme;
                    return Container(
                      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                      decoration: BoxDecoration(
                        color: cs.surface,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: cs.outline),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: const Color(0xFFFC4C02).withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(
                              tp.isDark ? Icons.dark_mode_rounded : Icons.light_mode_rounded,
                              color: const Color(0xFFFC4C02),
                              size: 20,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  tp.isDark ? s.darkMode : s.lightMode,
                                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: cs.onSurface),
                                ),
                                Text(
                                  tp.isDark ? s.switchToLight : s.switchToDark,
                                  style: TextStyle(fontSize: 12, color: cs.onSurface.withValues(alpha: 0.5)),
                                ),
                              ],
                            ),
                          ),
                          Switch(
                            value: tp.isDark,
                            onChanged: (_) => tp.toggleTheme(),
                            activeThumbColor: const Color(0xFFFC4C02),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),

              // ─── Sign Out Button ──────────────────────────────
              SliverToBoxAdapter(
                child: Container(
                  margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      await AuthService().signOut();
                    },
                    icon: const Icon(Icons.logout_rounded, size: 20),
                    label: Text(s.signOut,
                        style: const TextStyle(
                            fontFamily: 'Inter',
                            fontWeight: FontWeight.w600,
                            fontSize: 15)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.surface.withValues(alpha: 0.95),
                      foregroundColor: Colors.red,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      side: BorderSide(
                          color: Colors.red.withValues(alpha: 0.5), width: 1.5),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                     ),
                  ),
                ),
              ),

              // ─── App Version Info ──────────────────────────────
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(top: 18, bottom: 8),
                  child: Center(
                    child: Text(
                      'Running Finder v${UpdateService.currentAppVersion}',
                      style: TextStyle(
                        fontSize: 12,
                        color: pal.textMute,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                ),
              ),

              const SliverToBoxAdapter(child: SizedBox(height: 100)),
            ],
          ),
          // 🌐 Language Switch Button — top-right overlay
          Positioned(
            top: MediaQuery.of(context).padding.top + 12,
            right: 14,
            child: _buildLanguageToggle(lp, s),
          ),
        ],
      ),
    );
  }

  // ─── Widgets ────────────────────────────────────────────

  Widget _buildLanguageToggle(LanguageProvider lp, AppStrings s) {
    final isThai = lp.isThai;
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => lp.toggleLanguage(),
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: cs.surface.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: const Color(0xFFFC4C02).withValues(alpha: 0.35),
              width: 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.language_rounded, size: 16, color: Color(0xFFFC4C02)),
              const SizedBox(width: 5),
              Text(
                isThai ? 'TH' : 'EN',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFFFC4C02),
                ),
              ),
              const SizedBox(width: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFFFC4C02).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  isThai ? 'ไทย' : 'ENG',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface.withValues(alpha: 0.85),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmergencyContactSection() {
    final s = AppStrings(isThai: context.read<LanguageProvider>().isThai);
    final hasContact = _emergencyName.isNotEmpty && _emergencyPhone.isNotEmpty;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: hasContact ? const Color(0xFFE53935).withValues(alpha: 0.4) : pal.border,
          width: hasContact ? 1.5 : 1,
        ),
        boxShadow: [
          BoxShadow(
            color: hasContact
                ? const Color(0xFFE53935).withValues(alpha: 0.08)
                : Colors.black.withValues(alpha: 0.04),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE53935).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.shield_rounded, color: Color(0xFFE53935), size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(s.emergencyContact,
                          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: Theme.of(context).colorScheme.onSurface)),
                      Text(s.emergencySubtitle,
                          style: TextStyle(fontSize: 12, color: pal.textMute)),
                    ],
                  ),
                ),
                GestureDetector(
                  onTap: _showEmergencyContactDialog,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE53935).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      hasContact ? s.edit : s.setup,
                      style: const TextStyle(color: Color(0xFFE53935), fontWeight: FontWeight.w700, fontSize: 13),
                    ),
                  ),
                ),
              ],
            ),
            if (hasContact) ...[
              const SizedBox(height: 16),
              Divider(color: pal.border),
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(Icons.person_rounded, color: pal.textSub, size: 18),
                  const SizedBox(width: 8),
                  Text(_emergencyName, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Theme.of(context).colorScheme.onSurface)),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.phone_rounded, color: pal.textSub, size: 18),
                  const SizedBox(width: 8),
                  Text(_emergencyPhone, style: TextStyle(fontSize: 15, color: pal.text)),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => SafetyService.callNumber(_emergencyPhone),
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF43A047).withValues(alpha: 0.12),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.call_rounded, color: Color(0xFF43A047), size: 20),
                    ),
                  ),
                ],
              ),
            ] else ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF57C00).withValues(alpha: pal.isDark ? 0.16 : 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded, color: Color(0xFFF57C00), size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(s.noEmergencyContact,
                        style: TextStyle(fontSize: 12, color: pal.isDark ? const Color(0xFFFFB74D) : const Color(0xFFE65100), height: 1.4)),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _showEmergencyContactDialog() async {
    final s = AppStrings(isThai: context.read<LanguageProvider>().isThai);
    final result = await showDialog<({String name, String phone, bool isDeleted})>(
      context: context,
      builder: (_) => _EmergencyContactDialog(
        initialName: _emergencyName,
        initialPhone: _emergencyPhone,
        isThai: s.isThai,
      ),
    );

    if (result == null) return;

    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';

    if (result.isDeleted) {
      await EmergencyContactService.clear(uid: uid);
      if (mounted) {
        setState(() {
          _emergencyName = '';
          _emergencyPhone = '';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(s.contactDeleted),
            backgroundColor: const Color(0xFFE53935),
          ),
        );
      }
      return;
    }

    final name = result.name;
    final phone = result.phone;
    if (name.isNotEmpty && phone.isNotEmpty) {
      await EmergencyContactService.save(name, phone, uid: uid);
      if (mounted) {
        setState(() {
          _emergencyName = name;
          _emergencyPhone = phone;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(s.contactSaved),
            backgroundColor: const Color(0xFF43A047),
          ),
        );
      }
    }
  }

  // ─── Weekly Stats ───────────────────────────────────────

  Widget _buildWeeklyStats(BuildContext context, WeeklyStats stats, String uid, FirestoreService svc) {
    final s = AppStrings(isThai: context.read<LanguageProvider>().isThai);
    return GestureDetector(
      onTap: () => _showWeeklyStatsModal(context, uid, svc),
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [pal.surface, pal.surface, pal.surface2],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFFFC4C02).withValues(alpha: 0.18),
              blurRadius: 20,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Stack(
          children: [
            // decorative circle
            Positioned(
              right: -20, top: -20,
              child: Container(
                width: 120, height: 120,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFFFC4C02).withValues(alpha: 0.07),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header row
                  Row(
                    children: [
                      Text(s.weeklyStats,
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: pal.textSub,
                              letterSpacing: 0.5)),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                        decoration: BoxDecoration(
                          color: pal.surface2,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(s.viewChart,
                                style: TextStyle(color: pal.textSub, fontSize: 11, fontWeight: FontWeight.w600)),
                            const SizedBox(width: 3),
                            Icon(Icons.bar_chart_rounded, size: 12, color: pal.textMute),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // Hero distance
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        stats.formattedDistance,
                        style: TextStyle(
                          fontSize: 48,
                          fontWeight: FontWeight.w900,
                          color: pal.text,
                          height: 1.0,
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.only(bottom: 8, left: 4),
                        child: Text('km',
                            style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFFFC4C02))),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  // Stats chips row
                  Row(
                    children: [
                      _buildHeroStatChip(Icons.timer_outlined,
                          stats.durationSeconds > 0 ? stats.formattedDuration : '0m'),
                      const SizedBox(width: 8),
                      _buildHeroStatChip(Icons.fitness_center, '${stats.count} ${s.times}'),
                      const SizedBox(width: 8),
                      _buildHeroStatChip(Icons.terrain, '${stats.elevationM}m'),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeroStatChip(IconData icon, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: pal.surface2,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: pal.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: pal.textSub),
          const SizedBox(width: 5),
          Text(value,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: pal.textSub)),
        ],
      ),
    );
  }

  // ─── Weekly Stats Modal ─────────────────────────────────

  void _showWeeklyStatsModal(BuildContext context, String uid, FirestoreService svc) {
    final s = AppStrings(isThai: context.read<LanguageProvider>().isThai);
    final dayNames = s.dayNamesShort;
    final dayNamesFull = s.dayNamesFull;
    final today = DateTime.now().weekday;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        height: MediaQuery.of(context).size.height * 0.82,
        decoration: BoxDecoration(
          color: pal.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: StreamBuilder<List<Activity>>(
          stream: svc.getWeeklyActivities(uid),
          builder: (ctx, snap) {
            final loading = snap.connectionState == ConnectionState.waiting;
            final activities = snap.data ?? [];

            final distByDay = {for (int i = 1; i <= 7; i++) i: 0.0};
            final secsByDay = {for (int i = 1; i <= 7; i++) i: 0};
            for (final a in activities) {
              final d = a.startedAt.weekday;
              distByDay[d] = distByDay[d]! + a.distanceKm;
              secsByDay[d] = secsByDay[d]! + a.durationSeconds;
            }
            final maxDist = distByDay.values.fold(0.0, (a, b) => a > b ? a : b);
            final totalDist = activities.fold(0.0, (a, b) => a + b.distanceKm);
            final totalSecs = activities.fold(0, (a, b) => a + b.durationSeconds);
            final activeDays = distByDay.values.where((d) => d > 0).length;

            return Column(
              children: [
                Center(child: Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Container(width: 40, height: 4,
                      decoration: BoxDecoration(color: pal.border, borderRadius: BorderRadius.circular(2))),
                )),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                  child: Row(
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(s.weeklyStatsTitle,
                              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: pal.text)),
                          Text(s.monToSun,
                              style: TextStyle(fontSize: 12, color: pal.textMute)),
                        ],
                      ),
                      const Spacer(),
                      _buildModalStatChip('${activities.length} ${s.times}', Icons.fitness_center),
                      const SizedBox(width: 8),
                      _buildModalStatChip('${totalDist.toStringAsFixed(1)} km', Icons.straighten),
                    ],
                  ),
                ),
                Divider(height: 1, color: pal.border),
                Expanded(
                  child: loading
                      ? const Center(child: CircularProgressIndicator(color: Color(0xFFFC4C02)))
                      : SingleChildScrollView(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Bar Chart
                              Container(
                                padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                                decoration: BoxDecoration(
                                  color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.04),
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(color: pal.border),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(s.dailyDistanceKm,
                                        style: TextStyle(fontSize: 11, color: pal.textMute, fontWeight: FontWeight.w600)),
                                    const SizedBox(height: 12),
                                    SizedBox(
                                      height: 160,
                                      child: Row(
                                        crossAxisAlignment: CrossAxisAlignment.end,
                                        children: List.generate(7, (i) {
                                          final dow = i + 1;
                                          final dist = distByDay[dow] ?? 0.0;
                                          final isToday = dow == today;
                                          final hasRun = dist > 0;
                                          final barH = maxDist > 0
                                              ? (dist / maxDist * 110).clamp(4.0, 110.0)
                                              : 0.0;
                                          return Expanded(
                                            child: Column(
                                              mainAxisAlignment: MainAxisAlignment.end,
                                              children: [
                                                if (hasRun)
                                                  Padding(
                                                    padding: const EdgeInsets.only(bottom: 3),
                                                    child: Text(
                                                      dist.toStringAsFixed(1),
                                                      style: TextStyle(fontSize: 9,
                                                          color: isToday ? const Color(0xFFFF6A2F) : pal.textMute,
                                                          fontWeight: FontWeight.w700),
                                                    ),
                                                  ),
                                                const Spacer(),
                                                AnimatedContainer(
                                                  duration: const Duration(milliseconds: 700),
                                                  curve: Curves.easeOut,
                                                  height: barH == 0 ? 4 : barH,
                                                  margin: const EdgeInsets.symmetric(horizontal: 5),
                                                  decoration: BoxDecoration(
                                                    gradient: LinearGradient(
                                                      begin: Alignment.topCenter,
                                                      end: Alignment.bottomCenter,
                                                      colors: isToday
                                                          ? [const Color(0xFFFF6A2F), const Color(0xFFFC4C02)]
                                                          : hasRun
                                                              ? [const Color(0xFF74B9FF), const Color(0xFF3498DB)]
                                                              : [pal.surface2, pal.surface2],
                                                    ),
                                                    borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
                                                  ),
                                                ),
                                                const SizedBox(height: 8),
                                                Text(dayNames[i],
                                                    style: TextStyle(
                                                        fontSize: 12,
                                                        fontWeight: isToday ? FontWeight.w800 : FontWeight.w500,
                                                        color: isToday ? const Color(0xFFFC4C02) : pal.textMute)),
                                                Container(
                                                  width: 4, height: 4,
                                                  margin: const EdgeInsets.only(top: 3),
                                                  decoration: BoxDecoration(
                                                    color: isToday ? const Color(0xFFFC4C02) : Colors.transparent,
                                                    shape: BoxShape.circle,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          );
                                        }),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 16),
                              // Summary Cards
                              Row(
                                children: [
                                  Expanded(child: _buildWeekCard(s.totalDistance, '${totalDist.toStringAsFixed(2)} km', Icons.straighten, const Color(0xFFFC4C02))),
                                  const SizedBox(width: 12),
                                  Expanded(child: _buildWeekCard(s.totalTime, _formatDuration(totalSecs), Icons.timer_outlined, const Color(0xFF3498DB))),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  Expanded(child: _buildWeekCard(s.activitiesLabel, '${activities.length} ${s.times}', Icons.fitness_center, const Color(0xFF2ECC71))),
                                  const SizedBox(width: 12),
                                  Expanded(child: _buildWeekCard(s.runDays, '$activeDays/7 ${s.days}', Icons.calendar_today_outlined, const Color(0xFF9B59B6))),
                                ],
                              ),
                              const SizedBox(height: 20),
                              // Daily Detail
                              if (activities.isNotEmpty) ...[
                                Text(s.dailyDetail,
                                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: pal.textSub)),
                                const SizedBox(height: 12),
                                ...List.generate(7, (i) {
                                  final dow = i + 1;
                                  final dist = distByDay[dow] ?? 0.0;
                                  final secs = secsByDay[dow] ?? 0;
                                  if (dist == 0) return const SizedBox.shrink();
                                  final isToday = dow == today;
                                  return Container(
                                    margin: const EdgeInsets.only(bottom: 8),
                                    padding: const EdgeInsets.all(14),
                                    decoration: BoxDecoration(
                                      color: isToday
                                          ? const Color(0xFFFC4C02).withValues(alpha: 0.1)
                                          : pal.surface2,
                                      borderRadius: BorderRadius.circular(14),
                                      border: Border.all(
                                        color: isToday
                                            ? const Color(0xFFFC4C02).withValues(alpha: 0.4)
                                            : pal.border),
                                    ),
                                    child: Row(
                                      children: [
                                        Container(
                                          width: 40, height: 40,
                                          decoration: BoxDecoration(
                                            color: isToday
                                                ? const Color(0xFFFC4C02).withValues(alpha: 0.2)
                                                : pal.surface2,
                                            borderRadius: BorderRadius.circular(10),
                                          ),
                                          child: Center(
                                            child: Text(dayNames[i],
                                                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800,
                                                    color: isToday ? const Color(0xFFFC4C02) : pal.textSub)),
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(isToday ? s.today : dayNamesFull[i],
                                                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                                                      color: isToday ? const Color(0xFFFC4C02) : pal.textSub)),
                                              const SizedBox(height: 2),
                                              Text('${dist.toStringAsFixed(2)} km • ${_formatDuration(secs)}',
                                                  style: TextStyle(fontSize: 12, color: pal.textMute)),
                                            ],
                                          ),
                                        ),
                                        // Mini progress bar
                                        Container(
                                          width: 60, height: 6,
                                          decoration: BoxDecoration(
                                            borderRadius: BorderRadius.circular(3),
                                            color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.08),
                                          ),
                                          child: FractionallySizedBox(
                                            alignment: Alignment.centerLeft,
                                            widthFactor: maxDist > 0 ? (dist / maxDist).clamp(0.05, 1.0) : 0.0,
                                            child: Container(
                                              decoration: BoxDecoration(
                                                borderRadius: BorderRadius.circular(3),
                                                color: isToday ? const Color(0xFFFC4C02) : const Color(0xFF3498DB),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                }),
                              ] else
                                SizedBox(
                                  width: double.infinity,
                                  child: Column(
                                    children: [
                                      const SizedBox(height: 32),
                                      Icon(Icons.fitness_center, size: 56,
                                          color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.12)),
                                      const SizedBox(height: 12),
                                      Text(s.noActivitiesWeek,
                                          style: TextStyle(color: pal.textMute, fontSize: 15)),
                                      const SizedBox(height: 4),
                                      Text(s.goRunNow,
                                          style: TextStyle(color: pal.textMute, fontSize: 12)),
                                      const SizedBox(height: 32),
                                    ],
                                  ),
                                ),
                              const SizedBox(height: 16),
                            ],
                          ),
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildModalStatChip(String text, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: pal.textMute),
          const SizedBox(width: 4),
          Text(text, style: TextStyle(fontSize: 12, color: pal.textSub, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _buildWeekCard(String label, String value, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(height: 8),
          Text(value, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: color)),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(fontSize: 11, color: pal.textMute)),
        ],
      ),
    );
  }

  String _formatDuration(int secs) {
    final h = secs ~/ 3600;
    final m = (secs % 3600) ~/ 60;
    if (h > 0) return '${h}h ${m}m';
    if (m > 0) return '${m}m';
    return '${secs}s';
  }

  Widget _buildAllTimeStats(AllTimeStats stats) {
    final s = AppStrings(isThai: context.read<LanguageProvider>().isThai);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: pal.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(s.yourStats,
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: Theme.of(context).colorScheme.onSurface)),
              Text(s.allTime,
                  style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFFFC4C02),
                      fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 20),
          if (stats.count == 0)
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(s.noData,
                    textAlign: TextAlign.center,
                    style:
                        TextStyle(color: pal.textMute, height: 1.6)),
              ),
            )
          else ...[
            Row(
              children: [
                Expanded(
                    child: _buildBigStat(
                        stats.formattedDistance, 'km', s.totalDistance)),
                Expanded(
                    child: _buildBigStat(
                        '${stats.count}', '', s.totalRuns)),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                    child: _buildBigStat(
                        stats.formattedDuration, '', s.totalTime)),
                Expanded(
                    child: _buildBigStat(
                        '${stats.elevationM}', 'm', s.totalElevation)),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBigStat(String value, String unit, String label) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        RichText(
          text: TextSpan(children: [
            TextSpan(
                text: value,
                style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    color: Theme.of(context).colorScheme.onSurface)),
            if (unit.isNotEmpty)
              TextSpan(
                  text: ' $unit',
                  style: TextStyle(
                      fontSize: 13, color: pal.textSub)),
          ]),
        ),
        const SizedBox(height: 4),
        Text(label,
            style:
                TextStyle(fontSize: 12, color: pal.textSub)),
      ],
    );
  }

  // ─── Distance badges (6 อัน) ───────────────────────────
  List<Map<String, Object>> _distanceBadges(AllTimeStats stats) {
    final s = AppStrings(isThai: context.read<LanguageProvider>().isThai);
    return [
      {
        'image': 'assets/images/achievement_3km.webp',
        'label': '3 km',
        'desc': s.badge3kmDesc,
        'earned': stats.longestRun != null && stats.longestRun!.distanceKm >= 3.0,
      },
      {
        'image': 'assets/images/achievement_5km.webp',
        'label': '5 km',
        'desc': s.badge5kmDesc,
        'earned': stats.longestRun != null && stats.longestRun!.distanceKm >= 5.0,
      },
      {
        'image': 'assets/images/achievement_10km.webp',
        'label': '10 km',
        'desc': s.badge10kmDesc,
        'earned': stats.longestRun != null && stats.longestRun!.distanceKm >= 10.0,
      },
      {
        'image': 'assets/images/achievement_25km.webp',
        'label': '25 km',
        'desc': s.badge25kmDesc,
        'earned': stats.longestRun != null && stats.longestRun!.distanceKm >= 25.0,
      },
      {
        'image': 'assets/images/achievement_50km.webp',
        'label': '50 km',
        'desc': s.badge50kmDesc,
        'earned': stats.longestRun != null && stats.longestRun!.distanceKm >= 50.0,
      },
      {
        'image': 'assets/images/achievement_100km.webp',
        'label': '100 km',
        'desc': s.badge100kmDesc,
        'earned': stats.longestRun != null && stats.longestRun!.distanceKm >= 100.0,
      },
    ];
  }

  Widget _buildAchievements(AllTimeStats stats) {
    final s = AppStrings(isThai: context.read<LanguageProvider>().isThai);
    final distanceBadges = _distanceBadges(stats);
    final selected = distanceBadges[_selectedDistanceBadgeIndex];
    final selectedEarned = selected['earned'] as bool;
    final earnedCount = distanceBadges.where((b) => b['earned'] as bool).length;

    // 4 slots: 1 distance + 3 icon-based
    final iconBadges = [
      {
        'icon': Icons.local_fire_department,
        'label': s.sevenDayStreak,
        'color': const Color(0xFFFC4C02),
        'earned': stats.hasSevenDayStreak,
        'hint': s.sevenDayHint,
      },
      {
        'icon': Icons.speed,
        'label': s.speedDemon,
        'color': const Color(0xFF3498DB),
        'earned': stats.fastestPace != null &&
            stats.fastestPace!.avgPaceSecPerKm > 0 &&
            stats.fastestPace!.avgPaceSecPerKm < 300,
        'hint': s.speedHint,
      },
      {
        'icon': Icons.terrain,
        'label': s.hillClimber,
        'color': const Color(0xFF2ECC71),
        'earned': stats.elevationM >= 100,
        'hint': s.hillHint,
      },
    ];

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: pal.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(s.achievements,
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: Theme.of(context).colorScheme.onSurface)),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFFFC4C02).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '$earnedCount / ${distanceBadges.length}',
                  style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFFFC4C02),
                      fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Row: 1 distance slot + 3 icon slots
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              // ── Slot 1: Distance badge (กดเพื่อดู popup) ──
              GestureDetector(
                onTap: () => _showDistanceBadgesPopup(context, distanceBadges),
                child: Column(
                  children: [
                    Stack(
                      alignment: Alignment.center,
                      children: [
                        Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: selectedEarned
                                ? const Color(0xFFFC4C02).withValues(alpha: 0.1)
                                : pal.surface2,
                            border: Border.all(
                              color: selectedEarned
                                  ? const Color(0xFFFC4C02).withValues(alpha: 0.4)
                                  : pal.border,
                              width: 1.5,
                            ),
                          ),
                          child: ClipOval(
                            child: Padding(
                              padding: const EdgeInsets.all(3.0),
                              child: ColorFiltered(
                                colorFilter: selectedEarned
                                    ? const ColorFilter.mode(
                                        Colors.transparent, BlendMode.multiply)
                                    : const ColorFilter.matrix([
                                        0.2126, 0.7152, 0.0722, 0, 0,
                                        0.2126, 0.7152, 0.0722, 0, 0,
                                        0.2126, 0.7152, 0.0722, 0, 0,
                                        0,      0,      0,      1, 0,
                                      ]),
                                child: Opacity(
                                  opacity: selectedEarned ? 1.0 : 0.35,
                                  child: Image.asset(
                                    selected['image'] as String,
                                    fit: BoxFit.cover,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (!selectedEarned)
                          Container(
                            width: 64,
                            height: 64,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.black.withValues(alpha: 0.25),
                            ),
                            child: Icon(
                              Icons.lock_rounded,
                              color: Theme.of(context).colorScheme.surface,
                              size: 22,
                            ),
                          ),
                        // badge count chip
                        Positioned(
                          top: 0,
                          right: 0,
                          child: Container(
                            padding: const EdgeInsets.all(3),
                            decoration: const BoxDecoration(
                              color: Color(0xFFFC4C02),
                              shape: BoxShape.circle,
                            ),
                            child: Text(
                              '$earnedCount',
                              style: TextStyle(
                                  fontSize: 9,
                                  color: Theme.of(context).colorScheme.surface,
                                  fontWeight: FontWeight.w800),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      selected['label'] as String,
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: selectedEarned
                              ? pal.text
                              : pal.textMute),
                    ),
                    Text(s.tapToView,
                        style: TextStyle(fontSize: 9, color: pal.textMute)),
                  ],
                ),
              ),

              // ── Slots 2–4: Icon achievements ──
              ...iconBadges.map((b) {
                final earned = b['earned'] as bool;
                final color = b['color'] as Color;
                return Tooltip(
                  message: b['hint'] as String,
                  child: Column(
                    children: [
                      Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: earned
                              ? color.withValues(alpha: 0.15)
                              : pal.surface2,
                          border: Border.all(
                            color: earned
                                ? color.withValues(alpha: 0.5)
                                : pal.border,
                            width: 1.5,
                          ),
                        ),
                        child: Icon(b['icon'] as IconData,
                            color: earned ? color : pal.textMute,
                            size: 28),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        b['label'] as String,
                        style: TextStyle(
                            fontSize: 11,
                            color: earned
                                ? pal.text
                                : pal.textMute,
                            fontWeight: earned
                                ? FontWeight.w600
                                : FontWeight.w400),
                        textAlign: TextAlign.center,
                      ),
                      if (!earned)
                        const Text('🔒',
                            style: TextStyle(fontSize: 10)),
                    ],
                  ),
                );
              }),
            ],
          ),
        ],
      ),
    );
  }

  // ── Popup แสดง distance badge ทั้ง 6 อัน ──────────────────
  void _showDistanceBadgesPopup(
      BuildContext context, List<Map<String, Object>> badges) {
    final s = AppStrings(isThai: context.read<LanguageProvider>().isThai);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          ),
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Handle bar
              Container(
                width: 40, height: 4,
                decoration: BoxDecoration(
                  color: pal.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 20),
              Text(s.distanceBadges,
                  style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: Theme.of(context).colorScheme.onSurface)),
              const SizedBox(height: 6),
              Text(s.tapToSelectBadge,
                  style: TextStyle(fontSize: 13, color: pal.textMute)),
              const SizedBox(height: 20),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                  childAspectRatio: 0.82,
                ),
                itemCount: badges.length,
                itemBuilder: (_, index) {
                  final badge = badges[index];
                  final isEarned = badge['earned'] as bool;
                  final isSelected = _selectedDistanceBadgeIndex == index;
                  return GestureDetector(
                    onTap: () {
                      setState(() => _selectedDistanceBadgeIndex = index);
                      setSheetState(() {});
                      Navigator.pop(ctx);
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? const Color(0xFFFC4C02).withValues(alpha: 0.08)
                            : isEarned
                                ? pal.surface2
                                : pal.surface2,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: isSelected
                              ? const Color(0xFFFC4C02)
                              : isEarned
                                  ? const Color(0xFFFC4C02).withValues(alpha: 0.3)
                                  : pal.border,
                          width: isSelected ? 2.5 : 1.5,
                        ),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SizedBox(
                            width: 56,
                            height: 56,
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                ColorFiltered(
                                  colorFilter: isEarned
                                      ? const ColorFilter.mode(
                                          Colors.transparent, BlendMode.multiply)
                                      : const ColorFilter.matrix([
                                          0.2126, 0.7152, 0.0722, 0, 0,
                                          0.2126, 0.7152, 0.0722, 0, 0,
                                          0.2126, 0.7152, 0.0722, 0, 0,
                                          0,      0,      0,      1, 0,
                                        ]),
                                  child: Opacity(
                                    opacity: isEarned ? 1.0 : 0.3,
                                    child: Image.asset(
                                      badge['image'] as String,
                                      fit: BoxFit.contain,
                                    ),
                                  ),
                                ),
                                if (!isEarned)
                                  Icon(Icons.lock_rounded,
                                      color: pal.textMute, size: 18),
                              ],
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            badge['label'] as String,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: isEarned
                                  ? pal.text
                                  : pal.textMute,
                            ),
                          ),
                          if (isSelected)
                            Text(s.showing,
                                style: const TextStyle(
                                    fontSize: 9,
                                    color: Color(0xFFFC4C02),
                                    fontWeight: FontWeight.w700)),
                          if (!isEarned && !isSelected)
                            Text(
                              badge['desc'] as String,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  fontSize: 8,
                                  color: pal.textMute),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }




  Widget _buildPersonalRecords(AllTimeStats stats) {
    final s = AppStrings(isThai: context.read<LanguageProvider>().isThai);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: pal.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(s.personalRecords,
              style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: Theme.of(context).colorScheme.onSurface)),
          const SizedBox(height: 16),
          if (stats.count == 0)
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(s.firstRunPrompt,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: pal.textMute, fontSize: 13)),
              ),
            )
          else ...[
            if (stats.longestRun != null)
              _buildRecordRow(
                Icons.straighten,
                s.longestRun,
                '${stats.longestRun!.distanceKm.toStringAsFixed(2)} km',
                stats.longestRun!.formattedDate,
              ),
            if (stats.fastestPace != null &&
                stats.fastestPace!.avgPaceSecPerKm > 0)
              _buildRecordRow(
                Icons.speed,
                s.bestPace,
                stats.fastestPace!.formattedPace,
                stats.fastestPace!.formattedDate,
              ),
            if (stats.highestClimb != null)
              _buildRecordRow(
                Icons.terrain,
                s.highestClimb,
                '${stats.highestClimb!.elevationM} m',
                stats.highestClimb!.formattedDate,
              ),
            if (stats.longestTime != null)
              _buildRecordRow(
                Icons.timer,
                s.longestTime,
                stats.longestTime!.formattedDuration,
                stats.longestTime!.formattedDate,
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildRecordRow(
      IconData icon, String title, String value, String date) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: const Color(0xFFFC4C02).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: const Color(0xFFFC4C02), size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                        color: Theme.of(context).colorScheme.onSurface)),
                Text(date,
                    style: TextStyle(
                        fontSize: 11, color: pal.textMute)),
              ],
            ),
          ),
          Text(value,
              style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                  color: Color(0xFFFC4C02))),
        ],
      ),
    );
  }
}

class _EmergencyContactDialog extends StatefulWidget {
  final String initialName;
  final String initialPhone;
  final bool isThai;

  const _EmergencyContactDialog({
    required this.initialName,
    required this.initialPhone,
    required this.isThai,
  });

  @override
  State<_EmergencyContactDialog> createState() => _EmergencyContactDialogState();
}

class _EmergencyContactDialogState extends State<_EmergencyContactDialog> {
  /// สีพื้น/ตัวอักษรตามธีมปัจจุบัน
  AppPalette get pal => context.pal;

  late final TextEditingController _nameCtrl;
  late final TextEditingController _phoneCtrl;
  String? _nameError;
  String? _phoneError;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.initialName);
    _phoneCtrl = TextEditingController(text: widget.initialPhone);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final s = AppStrings(isThai: widget.isThai);
    final name = _nameCtrl.text.trim();
    final phone = _phoneCtrl.text.trim();
    setState(() {
      _nameError = name.isEmpty ? s.enterName : null;
      _phoneError = phone.isEmpty ? s.enterPhone : null;
    });
    if (name.isNotEmpty && phone.isNotEmpty) {
      Navigator.pop(context, (name: name, phone: phone, isDeleted: false));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings(isThai: widget.isThai);
    final hasExisting = widget.initialName.isNotEmpty && widget.initialPhone.isNotEmpty;

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: Row(
        children: [
          const Icon(Icons.shield_rounded, color: Color(0xFFE53935), size: 24),
          const SizedBox(width: 10),
          Expanded(child: Text(s.emergencyContactTitle, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18))),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameCtrl,
              decoration: InputDecoration(
                labelText: s.contactName,
                errorText: _nameError,
                prefixIcon: const Icon(Icons.person_rounded),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Color(0xFFE53935), width: 2),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _phoneCtrl,
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(
                labelText: s.phoneNumber,
                errorText: _phoneError,
                prefixIcon: const Icon(Icons.phone_rounded),
                hintText: s.phoneHint,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Color(0xFFE53935), width: 2),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (hasExisting)
          TextButton(
            onPressed: () => Navigator.pop(context, (name: '', phone: '', isDeleted: true)),
            child: Text(s.deleteData, style: const TextStyle(color: Color(0xFFE53935))),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(s.cancel, style: TextStyle(color: pal.textMute)),
        ),
        ElevatedButton(
          onPressed: _submit,
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFE53935),
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: Text(s.save, style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.white)),
        ),
      ],
    );
  }
}
