import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import '../providers/language_provider.dart';

/// Centralised string table for Thai / English.
///
/// Usage:
///   final s = AppStrings.of(context); // requires LanguageProvider in scope
///   Text(s.weeklyStats)
///
/// Or directly:
///   AppStrings.get(isThai: lp.isThai).weeklyStats
class AppStrings {
  final bool isThai;
  const AppStrings({required this.isThai});

  /// Factory helper to obtain AppStrings from context
  static AppStrings of(BuildContext context) {
    try {
      final isThai = Provider.of<LanguageProvider>(context, listen: false).isThai;
      return AppStrings(isThai: isThai);
    } catch (_) {
      return const AppStrings(isThai: true);
    }
  }

  /// Helper to obtain AppStrings from boolean
  static AppStrings get({required bool isThai}) => AppStrings(isThai: isThai);

  // ─── helpers ───────────────────────────────────────────────
  String _t(String th, String en) => isThai ? th : en;

  // ─── Navigation ────────────────────────────────────────────
  String get navHome       => _t('หน้าหลัก',  'Home');
  String get navExplore    => _t('สำรวจ',     'Explore');
  String get navStats      => _t('สถิติ',     'Stats');

  // ─── Profile screen ────────────────────────────────────────
  String get profileTitle      => _t('โปรไฟล์',         'Profile');
  String get signOut           => _t('ออกจากระบบ',      'Sign Out');
  String get darkMode          => _t('โหมดกลางคืน',     'Dark Mode');
  String get lightMode         => _t('โหมดกลางวัน',     'Light Mode');
  String get switchToDark      => _t('เปลี่ยนเป็นโหมดมืด',  'Switch to Dark');
  String get switchToLight     => _t('เปลี่ยนเป็นโหมดสว่าง','Switch to Light');
  String get adminDashboard    => _t('แดชบอร์ดผู้ดูแล', 'Admin Dashboard');
  String get changePhoto       => _t('เปลี่ยนรูปโปรไฟล์', 'Change Photo');
  String get takePhoto         => _t('ถ่ายภาพ',           'Take Photo');
  String get chooseGallery     => _t('เลือกจากแกลเลอรี', 'Choose from Gallery');
  String get removePhoto       => _t('ลบรูปโปรไฟล์',     'Remove Photo');
  String get cancel            => _t('ยกเลิก',            'Cancel');
  String get editNickname      => _t('แก้ไขชื่อเล่น',    'Edit Nickname');
  String get save              => _t('บันทึก',            'Save');
  String get deleteData        => _t('ลบข้อมูล',          'Delete');
  String get photoUpdated      => _t('✅ อัปเดตรูปโปรไฟล์เรียบร้อยแล้ว', '✅ Profile photo updated');
  String get photoRemoved      => _t('🗑️ ลบรูปโปรไฟล์แล้ว', '🗑️ Photo removed');
  String get nicknameUpdated   => _t('✅ อัปเดตชื่อเล่นเรียบร้อยแล้ว', '✅ Nickname updated');
  String get errorPrefix       => _t('เกิดข้อผิดพลาด: ', 'Error: ');
  String get errorPickingPhoto => _t('เกิดข้อผิดพลาดในการเลือกรูปภาพ: ', 'Error picking photo: ');

  // ─── Weekly stats card ─────────────────────────────────────
  String get weeklyStats       => _t('สัปดาห์นี้',     'This Week');
  String get viewChart         => _t('ดูกราฟ',          'View Chart');
  String get times             => _t('ครั้ง',           'runs');

  // ─── Weekly stats modal ────────────────────────────────────
  String get weeklyStatsTitle  => _t('สัปดาห์นี้',     'This Week');
  String get monToSun          => _t('จันทร์ – อาทิตย์', 'Mon – Sun');
  String get dailyDistanceKm   => _t('ระยะทางรายวัน (km)', 'Daily Distance (km)');
  String get totalDistance     => _t('ระยะทางรวม',     'Total Distance');
  String get totalTime         => _t('เวลารวม',         'Total Time');
  String get activitiesLabel   => _t('กิจกรรม',         'Activities');
  String get runDays           => _t('วันที่วิ่ง',      'Run Days');
  String get dailyDetail       => _t('รายละเอียดรายวัน', 'Daily Detail');
  String get noActivitiesWeek  => _t('ยังไม่มีกิจกรรมสัปดาห์นี้', 'No activities this week');
  String get goRunNow          => _t('ออกไปบันทึกกิจกรรมแล้วเอามาไว้เลย! 💪', 'Go for a run and log it here! 💪');
  String get today             => _t('วันนี้',          'Today');
  // Day names
  List<String> get dayNamesShort => isThai
      ? ['จ', 'อ', 'พ', 'พฤ', 'ศ', 'ส', 'อา']
      : ['M', 'T', 'W', 'Th', 'F', 'Sa', 'Su'];
  List<String> get dayNamesFull => isThai
      ? ['จันทร์', 'อังคาร', 'พุธ', 'พฤหัส', 'ศุกร์', 'เสาร์', 'อาทิตย์']
      : ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
  String get days              => _t('วัน', 'days');

  // ─── All-time stats card ────────────────────────────────────
  String get yourStats         => _t('สถิติของคุณ',     'Your Stats');
  String get allTime           => _t('ทั้งหมด',         'All Time');
  String get noData            => _t('ยังไม่มีข้อมูล\nเริ่มวิ่งแล้วสถิติจะปรากฏที่นี่',
                                      'No data yet.\nStart running to see your stats here.');
  String get totalRuns         => _t('วิ่งทั้งหมด',     'Total Runs');
  String get totalElevation    => _t('ความสูงรวม',      'Total Elevation');

  // ─── Achievements card ──────────────────────────────────────
  String get achievements      => _t('ความสำเร็จ',      'Achievements');
  String get tapToView         => _t('🏅 กดเพื่อดู',   '🏅 Tap to view');
  String get distanceBadges    => _t('เหรียญระยะทาง',  'Distance Badges');
  String get tapToSelectBadge  => _t('แตะเลือกเหรียญที่ต้องการแสดง', 'Tap to select a badge to display');
  String get showing           => _t('✓ โชว์อยู่',      '✓ Showing');
  String get sevenDayStreak    => _t('วิ่ง 7 วันติด',  '7-Day Streak');
  String get sevenDayHint      => _t('วิ่ง 7 วันติดต่อกัน', 'Run 7 days in a row');
  String get speedDemon        => _t('เร็วมาก!',        'Speed Demon');
  String get speedHint         => _t('เพซดีกว่า 5:00/km', 'Pace better than 5:00/km');
  String get hillClimber       => _t('นักปีนเขา',       'Hill Climber');
  String get hillHint          => _t('ขึ้นสูงรวม ≥ 100 m', 'Total elevation ≥ 100 m');

  // ─── Personal Records card ─────────────────────────────────
  String get personalRecords   => _t('สถิติส่วนตัว',    'Personal Records');
  String get firstRunPrompt    => _t('วิ่งครั้งแรกเพื่อสร้างสถิติแรกของคุณ! 🏅',
                                      'Go for your first run to set a record! 🏅');
  String get longestRun        => _t('วิ่งไกลที่สุด',   'Longest Run');
  String get bestPace          => _t('เพซดีที่สุด',     'Best Pace');
  String get highestClimb      => _t('ขึ้นสูงที่สุด',   'Highest Climb');
  String get longestTime       => _t('วิ่งนานที่สุด',   'Longest Time');

  // ─── Emergency Contact card ────────────────────────────────
  String get emergencyContact  => _t('ผู้ติดต่อฉุกเฉิน', 'Emergency Contact');
  String get emergencySubtitle => _t('แจ้งเตือนเมื่อเกิดเหตุฉุกเฉินระหว่างวิ่ง',
                                      'Alert during running emergency');
  String get edit              => _t('แก้ไข',            'Edit');
  String get setup             => _t('ตั้งค่า',           'Set Up');
  String get noEmergencyContact => _t(
      'ยังไม่ได้ตั้งค่าผู้ติดต่อฉุกเฉิน\nกรุณาตั้งค่าเพื่อความปลอดภัยระหว่างวิ่ง',
      'No emergency contact set.\nPlease set one for safety during runs.');
  String get emergencyContactTitle => _t('ผู้ติดต่อฉุกเฉิน', 'Emergency Contact');
  String get contactName       => _t('ชื่อผู้ติดต่อ',    'Contact Name');
  String get phoneNumber       => _t('เบอร์โทรศัพท์',   'Phone Number');
  String get phoneHint         => _t('เช่น 0812345678',  'e.g. 0812345678');
  String get enterName         => _t('กรุณากรอกชื่อ',    'Please enter a name');
  String get enterPhone        => _t('กรุณากรอกเบอร์โทร', 'Please enter a phone number');
  String get contactSaved      => _t('✅ บันทึกผู้ติดต่อฉุกเฉินเรียบร้อยแล้ว',
                                      '✅ Emergency contact saved');
  String get contactDeleted    => _t('🗑️ ลบข้อมูลผู้ติดต่อฉุกเฉินแล้ว',
                                      '🗑️ Emergency contact deleted');

  // ─── Language switch button ────────────────────────────────
  String get language          => _t('ภาษา',            'Language');
  String get languageName      => isThai ? 'ไทย' : 'English';
  String get languageOther     => isThai ? 'English' : 'ไทย';
  String get switchLanguage    => _t('เปลี่ยนภาษาเป็น English', 'Switch to ภาษาไทย');

  // ─── Avatar & Photo Picker ─────────────────────────────────
  String get chooseAvatar      => _t('เลือกอวาตาร์นักวิ่ง', 'Choose Runner Avatar');
  String get chooseAvatarSubtitle => _t('เลือกภาพโปรไฟล์นักวิ่งสำเร็จรูปเท่ๆ', 'Choose ready-made runner avatar');
  String get enterImageUrl     => _t('ใส่ URL รูปภาพ', 'Enter Image URL');
  String get enterImageUrlSubtitle => _t('วางลิงก์รูปภาพจากอินเทอร์เน็ต', 'Paste an image link from internet');
  String get enterImageUrlHint => _t('วางลิงก์รูปภาพ (เช่น https://example.com/photo.jpg)', 'Paste image link (e.g. https://example.com/photo.jpg)');
  String get revertDefaultIcon => _t('เปลี่ยนกลับเป็นไอคอนเริ่มต้น', 'Revert to default icon');
  String get selectImageCommunity => _t('เลือกรูปภาพเพื่อแสดงในแอปและชุมชน', 'Select an image to show in app and community');
  String get openCameraPhoto   => _t('เปิดกล้องเพื่อถ่ายภาพใหม่', 'Open camera to take a new photo');
  String get pickGalleryPhoto  => _t('เลือกรูปถ่ายจากคลังภาพในเครื่อง', 'Pick a photo from your gallery');
  String get nicknameHint      => _t('ชื่อเล่นของคุณ', 'Your nickname');

  // ─── Distance Badge Descriptions ───────────────────────────
  String get badge3kmDesc      => _t('วิ่งครบ 3 กิโลเมตรในครั้งเดียว', 'Run 3 km in a single run');
  String get badge5kmDesc      => _t('วิ่งครบ 5 กิโลเมตรในครั้งเดียว', 'Run 5 km in a single run');
  String get badge10kmDesc     => _t('วิ่งครบ 10 กิโลเมตรในครั้งเดียว', 'Run 10 km in a single run');
  String get badge25kmDesc     => _t('วิ่งครบ 25 กิโลเมตรในครั้งเดียว', 'Run 25 km in a single run');
  String get badge50kmDesc     => _t('วิ่งครบ 50 กิโลเมตรในครั้งเดียว', 'Run 50 km in a single run');
  String get badge100kmDesc    => _t('วิ่งครบ 100 กิโลเมตรในครั้งเดียว', 'Run 100 km in a single run');

  // ─── Feed screen ───────────────────────────────────────────
  String get feedTitle         => _t('Route Finder',    'Route Finder');
  String get notifications     => _t('การแจ้งเตือน',     'Notifications');
  String get noNotifications   => _t('ไม่มีการแจ้งเตือนใหม่', 'No new notifications');
  String get popularRoutes     => _t('เส้นทางยอดนิยม',  'Popular Routes');
  String get publicCommunity   => _t('สาธารณะ',         'Community');
  String get myActivities      => _t('กิจกรรมของฉัน',   'My Activities');
  String get noPublicActivities=> _t('ยังไม่มีกิจกรรมสาธารณะ', 'No public activities yet');
  String get publicPrompt      => _t('บันทึกการวิ่งและเลือก "สาธารณะ"\nเพื่อแชร์ให้คนอื่นเห็น', 'Record a run and select "Public"\nto share with others');
  String get noMyActivities    => _t('ยังไม่มีกิจกรรมของคุณ', 'No activities yet');
  String get myActivitiesPrompt=> _t('ออกไปวิ่งและบันทึกกิจกรรมแรกของคุณเลย! 🏃', 'Go for a run and record your first activity! 🏃');
  String get showMore          => _t('ดูเพิ่มเติม (Show More)', 'Show More');
  String get showLess          => _t('ย่อเก็บ (Show Less)', 'Show Less');
  String get latestBadge       => _t('ล่าสุด',          'Latest');
  String get justFinished      => _t('เพิ่งจบ',         'Just finished');
  String get runLabel          => _t('วิ่ง',            'Run');
  String get rideLabel         => _t('ปั่น',            'Ride');
  String get distance          => _t('ระยะทาง',         'Distance');
  String get pace              => _t('เพซ',             'Pace');
  String get duration          => _t('เวลา',            'Duration');
  String get noGpsData         => _t('ไม่มีข้อมูล GPS',  'No GPS Data');
  String get currentAqiTitle   => _t('คุณภาพอากาศตำแหน่งปัจจุบัน', 'Current Air Quality');
  String get loadingAqi        => _t('กำลังโหลด...',     'Loading...');
  String get errorLoadingData  => _t('ไม่สามารถโหลดข้อมูลได้', 'Unable to load data');
  String get checkInternetConn => _t('กรุณาตรวจสอบการเชื่อมต่ออินเทอร์เน็ต', 'Please check your internet connection');
  String get temperature       => _t('อุณหภูมิ',        'Temperature');
  String get humidity          => _t('ความชื้น',        'Humidity');
  String get wind              => _t('ลม',              'Wind');
  String get visibility        => _t('ทัศนวิสัย',       'Visibility');
  String get runRecommendations=> _t('คำแนะนำสำหรับการวิ่ง', 'Running Advice');
  String get exploreMap        => _t('ดูบนแผนที่',      'View on Map');
  String get markAllRead       => _t('อ่านทั้งหมด',     'Mark all read');

  // ─── Map & Explore ─────────────────────────────────────────
  String get searchRouteHint   => _t('ค้นหาเส้นทาง...',  'Search routes...');
  String get filterRoutes      => _t('กรองเส้นทาง',      'Filter Routes');
  String get maxDistance       => _t('ระยะทางสูงสุด',    'Max Distance');
  String get favoritesOnly     => _t('เฉพาะที่ชอบ',      'Favorites Only');
  String get sortByNear        => _t('เรียงตามใกล้-ไกล', 'Sort by Distance');
  String get startRunning      => _t('เริ่มวิ่ง',         'Start Run');
  String get reportIncident    => _t('รายงานเหตุการณ์',  'Report Incident');
  String get reportSubtitle    => _t('แจ้งสิ่งกีดขวางหรืออันตรายบนเส้นทาง', 'Report obstacle or hazard on route');
  String get incidentCoordinates => _t('พิกัด',         'Coordinates');
  String get incidentType      => _t('ประเภทเหตุการณ์',  'Incident Type');
  String get incidentDetail    => _t('รายละเอียดเหตุการณ์', 'Incident Details');
  String get incidentHint      => _t('เช่น สุนัขดุร้าย 3 ตัววิ่งไล่ผู้คน ใกล้สะพาน...', 'e.g. 3 aggressive dogs near bridge...');
  String get reportDuration    => _t('ระยะเวลาการแสดงรายงาน', 'Report display duration');
  String get hoursSuffix       => _t('ชม.',             'hrs');
  String get sendReport        => _t('ส่งรายงาน',        'Submit Report');
  String get sendIncidentReport=> _t('ส่งรายงานเหตุการณ์', 'Submit Incident Report');
  String get reportSuccess     => _t('ส่งรายงานเหตุการณ์เรียบร้อยแล้ว!', 'Incident reported successfully!');
  String get reportFailed      => _t('ส่งรายงานไม่สำเร็จ', 'Report submission failed');
  String get aiModerationWait  => _t('กำลังตรวจสอบ AI...', 'Checking AI...');
  String get aiDetectedIssue   => _t('ระบบ AI ตรวจพบปัญหา', 'AI Detected an Issue');
  String get recommendedMap    => _t('แผนที่แนะนำ',      'Recommended');
  String get recommendedZones  => _t('โซนแนะนำ',        'Recommended Zones');
  String get zonesInChiangMai  => _t('โซนวิ่งในเชียงใหม่', 'Running Zones in Chiang Mai');
  String get freeRunInZone     => _t('วิ่งอิสระในโซนนี้',  'Free Run in Zone');
  String get createLoopRoute   => _t('สร้างเส้นทางวงรอบ',  'Create Loop Route');
  String get assessingZone     => _t('กำลังประเมิน…',     'Assessing…');
  String get selectLoopDistance=> _t('เลือกระยะทางวงรอบ',  'Select Loop Distance');
  String get outOfZoneAlert    => _t('⚠️ คุณกำลังวิ่งออกนอกโซน', '⚠️ You are running outside the zone');
  String get zoneSafetyFactors => _t('ปัจจัยคะแนนความปลอดภัย', 'Safety Score Factors');
  String get searchingNearbyZones => _t('กำลังค้นหาที่วิ่งใกล้คุณ…', 'Searching running zones near you…');
  String get topRecommendedZones => _t('โซนแนะนำ 5 อันดับแรก', 'Top 5 Recommended Zones');
  String get recommendationScore => _t('คะแนนแนะนำ', 'Recommendation Score');
  String get recommendationReasons => _t('เหตุผลแนะนำ', 'Why recommended');
  String get planRoute         => _t('วางแผนเส้นทาง',    'Plan Route');
  String get pickStartEnd      => _t('เลือกจุดเริ่ม-ปลาย', 'Pick Start & End');
  String get useCurrentLocationAsStart => _t('ใช้ตำแหน่งปัจจุบันเป็นจุดเริ่มต้น', 'Use current location as start');
  String get cancelPlanning    => _t('ยกเลิกการวางแผน',   'Cancel Planning');
  String get tapMapSelectStart => _t('แตะบนแผนที่เพื่อเลือก จุดเริ่มต้น 🟢', 'Tap map to choose Start Point 🟢');
  String get tapMapSelectDest  => _t('แตะบนแผนที่เพื่อเลือก จุดปลายทาง 🔴', 'Tap map to choose Destination 🔴');
  String get tapMapPinReport   => _t('แตะพิกัดบนแผนที่เพื่อปักหมุดรายงาน 📍', 'Tap on map to pin report 📍');
  String get loadingRealRoute  => _t('กำลังโหลดเส้นทางจริง...', 'Loading route...');
  String get calculatingRoute  => _t('กำลังคำนวณเส้นทาง...', 'Calculating route...');
  String get routesInChiangMai => _t('เส้นทางวิ่งในเชียงใหม่', 'Running Routes in Chiang Mai');
  String get allLabel          => _t('ทั้งหมด',          'All');
  String get nearMe            => _t('ใกล้ฉัน',          'Near Me');
  String get nearYou           => _t('ใกล้คุณ',          'Near You');
  String get favorite          => _t('โปรด',            'Favorites');
  String get noRoutesMatched   => _t('ไม่พบเส้นทางที่ตรงเงื่อนไข', 'No routes match criteria');
  String get clearFilters      => _t('ล้างตัวกรอง',       'Clear Filters');
  String get startRoutePrompt  => _t('เริ่มวิ่งเส้นทางนี้  ▶', 'Start This Route  ▶');
  String get checkingAirQuality=> _t('กำลังตรวจคุณภาพอากาศ...', 'Checking air quality...');
  String get dangerous         => _t('อันตราย',         'Hazardous');
  String get wearMask          => _t('ควรใส่หน้ากาก',    'Wear Mask');
  String get safe              => _t('ปลอดภัย',          'Safe');
  String get caution           => _t('ระวัง',            'Caution');
  String get notRecommended    => _t('ไม่แนะนำ',         'Not Recommended');
  String get goodAir           => _t('ดี',               'Good');
  String get moderateAir       => _t('ปานกลาง',         'Moderate');
  String get routeAnalysisResult => _t('ผลการวิเคราะห์เส้นทาง', 'Route Safety Analysis');
  String get safetyScore       => _t('คะแนนความปลอดภัย',  'Safety Score');
  String get startScoreDesc    => _t('คิดจาก 4 ปัจจัยตามน้ำหนัก แล้วปรับตามช่วงเวลา (กลางคืนคะแนนลดลงตามแสงสว่างของเส้นทาง)', 'Weighted from four factors, then adjusted for time of day (lower at night, depending on street lighting)');
  // ─── Traffic scoring strings ──────────────────────────────────────────────
  String get trafficCongestionLabel  => _t('สภาพการจราจร',        'Traffic');
  String get trafficLightLabel       => _t('แยกสัญญาณไฟ',        'Intersections');
  String trafficCongestionValue(double pct) =>
      _t('รถติด ${pct.toStringAsFixed(0)}% ของเส้นทาง', '${pct.toStringAsFixed(0)}% congested');
  String trafficLightValue(int count) =>
      _t('ผ่าน $count แยกสัญญาณไฟ', '$count traffic light(s)');
  String trafficCongestionStatus(int deduct) =>
      deduct >= 10 ? _t('ติดหนาแน่น', 'Heavy') :
      deduct >= 5  ? _t('ชะลอตัว',  'Moderate') :
                     _t('โล่ง',      'Clear');
  String trafficLightStatus(int deduct) =>
      deduct >= 10 ? _t('บ่อยมาก', 'Heavy') :
      deduct >= 5  ? _t('ปานกลาง', 'Moderate') :
                     _t('น้อย',    'Minimal');
  String get estimatedTime     => _t('เวลาประมาณ',      'Est. Time');
  String get routeSafePrompt   => _t('เส้นทางนี้ปลอดภัยสำหรับการวิ่ง! 🏃', 'This route is safe for running! 🏃');
  String get selectNew         => _t('เลือกใหม่',        'Select New');
  String get loadingElevation  => _t('กำลังโหลดกราฟความสูง...', 'Loading elevation...');
  String get noElevationData   => _t('ไม่มีข้อมูลความสูง', 'No elevation data');
  String get elevationProfile  => _t('ความสูงตลอดเส้นทาง', 'Elevation Profile');
  String get distanceAway      => _t('ห่าง',             '');
  String get nightRiskTitle    => _t('เส้นทางนี้เสี่ยงกลางคืน', 'Night Run Warning');
  String get lowSafetyTitle    => _t('ความปลอดภัยต่ำ',    'Low Safety Score');
  String nightRiskBody(int score) => _t(
      'เส้นทางนี้มีคะแนนความปลอดภัยเพียง $score/100 ในช่วงกลางคืน\n\n• แนะนำให้รอถึงเช้า\n• หากต้องวิ่ง ให้แจ้งคนที่บ้านก่อน\n• ตั้งค่าผู้ติดต่อฉุกเฉินที่หน้าโปรไฟล์',
      'This route has a safety score of only $score/100 at night.\n\n• Consider waiting until morning\n• If running, inform family/friends\n• Ensure emergency contacts are set up in Profile');
  String lowSafetyBody(int score) => _t(
      'เส้นทางนี้มีคะแนนความปลอดภัยต่ำ ($score/100)\n\nโปรดระวังและเตรียมตัวให้พร้อม',
      'This route has a low safety score ($score/100).\n\nPlease exercise caution and stay prepared.');
  String get acknowledge       => _t('รับทราบ',          'Acknowledge');
  String get waitingGpsSignal  => _t('กำลังรอสัญญาณ GPS...', 'Waiting for GPS signal...');
  String get unableCalculateRoute => _t('ไม่สามารถคำนวณเส้นทางได้', 'Unable to calculate route');
  String get verificationResult => _t('ผลการตรวจสอบ',   'Verification Result');
  String get verified          => _t('ยืนยัน',           'Verified');
  String get unverified        => _t('ยังไม่ยืนยัน',      'Unverified');
  String get scoreLabel        => _t('คะแนน',           'Score');
  String get reasonLabel       => _t('เหตุผล',           'Reason');
  String get confirmedByCount  => _t('ยืนยันโดย',       'Confirmed by');
  String get deniedByCount     => _t('ปฏิเสธโดย',       'Denied by');
  String get peopleCount       => _t('คน',              'people');
  String get stillThere        => _t('ยังเจออยู่',        'Still There');
  String get confirmedAlready  => _t('ยืนยันแล้ว',       'Confirmed');
  String get goneAlready       => _t('ไม่อยู่แล้ว',       'Cleared');
  String get pleaseLoginFirst  => _t('กรุณาเข้าสู่ระบบก่อนทำรายการ', 'Please sign in first');
  String get incidentStillThereSuccess => _t('ยืนยันว่ายังพบเหตุการณ์เรียบร้อยแล้ว', 'Confirmed incident is still active');
  String get incidentGoneSuccess => _t('แจ้งว่าเหตุการณ์ไม่อยู่แล้วเรียบร้อย', 'Reported incident is no longer there');

  // ─── Record screen ─────────────────────────────────────────
  String get startRunPrompt    => _t('พร้อมวิ่งหรือยัง?', 'Ready to run?');
  String get pause             => _t('หยุดชั่วคราว',    'Pause');
  String get resume            => _t('วิ่งต่อ',           'Resume');
  String get finishRun         => _t('จบกิจกรรม',       'Finish Run');
  String get discardRun        => _t('ยกเลิกการวิ่ง',    'Discard Run');
  String get runSummary        => _t('สรุปผลการวิ่ง',    'Run Summary');
  String get saveActivity      => _t('บันทึกกิจกรรม',    'Save Activity');
  String get discardConfirm    => _t('ต้องการยกเลิกการวิ่งนี้หรือไม่?', 'Do you want to discard this run?');
  String get pleaseEnableGps   => _t('กรุณาเปิด GPS บนอุปกรณ์ก่อนนะครับ', 'Please turn on GPS on your device');
  String get gpsPermissionRequired => _t('ต้องอนุญาต GPS เพื่อติดตามการวิ่ง', 'GPS permission required to track runs');
  String get gpsBlocked        => _t('GPS ถูกปิดกั้น',    'GPS Blocked');
  String get gpsBlockedPrompt  => _t(
      'แอปนี้ต้องใช้ GPS เพื่อติดตามเส้นทาง\n\nกรุณาไปที่ การตั้งค่า → แอป → สิทธิ์ → ตำแหน่งที่ตั้ง\nแล้วเลือก "อนุญาตตลอดเวลา" หรือ "อนุญาตขณะใช้งาน"',
      'This app requires GPS to track your route.\n\nPlease go to Settings → Apps → Permissions → Location\nand choose "Allow all the time" or "Allow while using app"');
  String get goToSettings      => _t('ไปตั้งค่า',         'Settings');
  String get finishRideTitle   => _t('จบการปั่น!',       'Ride Finished!');
  String get finishRunTitle    => _t('จบการวิ่ง!',       'Run Finished!');
  String get activityNameLabel => _t('ชื่อกิจกรรม',      'Activity Name');
  String get timeLabel         => _t('เวลา',            'Time');
  String get avgPace           => _t('เพซเฉลี่ย',        'Avg Pace');
  String get currentPace       => _t('เพซปัจจุบัน',      'Current Pace');
  String get elevationGain     => _t('ขึ้นสูง',           'Elevation');
  String get calories          => _t('แคลอรี่',          'Calories');
  String get publicDesc        => _t('ผู้ใช้อื่นในแอปเห็นได้', 'Visible to community');
  String get privateDesc       => _t('เห็นเฉพาะคุณเท่านั้น', 'Only visible to you');
  String get savedAndShared    => _t('บันทึกและแชร์ในชุมชนแล้ว! 🎉', 'Saved and shared to Community! 🎉');
  String get savedActivitySuccess => _t('บันทึกกิจกรรมเรียบร้อยแล้ว! 🎉', 'Activity saved successfully! 🎉');
  String get saveError         => _t('บันทึกไม่สำเร็จ',   'Failed to save');
  String get syncError         => _t('ซิงค์ข้อมูลไม่สำเร็จ', 'Failed to sync');
  String get saveButton        => _t('บันทึก 💾',        'Save 💾');
  String get startPointMarker  => _t('จุดเริ่ม',         'Start');
  String get endPointMarker    => _t('จุดจบ',           'End');
  String get gpsPointsSuffix   => _t('จุด GPS',         'GPS points');
  String get noEmergencySetPrompt => _t('⚠️ ยังไม่ได้ตั้งผู้ติดต่อฉุกเฉิน\nไปตั้งค่าที่หน้าโปรไฟล์ก่อนนะครับ', '⚠️ No emergency contact set.\nPlease set one up on your profile page first');
  String get selectActivityType=> _t('เลือกประเภทกิจกรรม', 'Select Activity Type');
  String get back              => _t('กลับ',            'Back');
  String get pausedStatus      => _t('หยุดพัก',          'Paused');
  String get runningStatus     => _t('กำลังวิ่ง',        'Running');
  String get cyclingStatus     => _t('กำลังปั่น',        'Cycling');
  String get readyToRunStatus  => _t('พร้อมวิ่ง',        'Ready to Run');
  String get readyToCycleStatus=> _t('พร้อมปั่น',        'Ready to Cycle');
  String get trackingStatus    => _t('ติดตาม',          'Tracking');
  String get waitingGpsStatus  => _t('รอสัญญาณ',        'Waiting for GPS');
  String get routeProgress     => _t('ความคืบหน้าเส้นทาง', 'Route Progress');
  String get getReadyPrompt    => _t('เตรียมพร้อม!',      'Get Ready!');
  String get cancelBackToRoute => _t('ยกเลิก — กลับเลือกเส้นทาง', 'Cancel — Back to Routes');
  String get areYouOkayPrompt  => _t('คุณโอเคไหม?',      'Are you okay?');
  String get noMovementPrompt  => _t('ไม่มีการเคลื่อนไหวมากกว่า 5 นาที', 'No movement for over 5 minutes');
  String get imSafe            => _t('โอเค ฉันปลอดภัย',  "I'm OK, I'm safe");
  String get sendSos           => _t('🆘 ส่ง SOS',       '🆘 Send SOS');
  String get startRunBtn       => _t('เริ่มวิ่ง',         'Start Run');
  String get startRideBtn      => _t('เริ่มปั่น',         'Start Ride');

  // ─── General & Feed helpers ────────────────────────────────
  String get speedLabel        => _t('ความเร็ว',        'Speed');
  String get publicLabel       => _t('สาธารณะ',         'Public');
  String get privateLabel      => _t('ส่วนตัว',         'Private');
  String get commentsLabel     => _t('คอมเมนต์',        'Comments');
  String get noCommentsYet     => _t('ยังไม่มีคอมเมนต์', 'No comments yet');
  String get beFirstToComment  => _t('เป็นคนแรกที่แสดงความเห็น!', 'Be the first to comment!');
  String get writeCommentHint  => _t('เขียนคอมเมนต์...',  'Write a comment...');
  String get swipeToDeleteNotification => _t('เลื่อนซ้ายเพื่อลบการแจ้งเตือน', 'Swipe left to delete notification');
  String get easyDifficulty    => _t('ง่าย',             'Easy');
  String get moderateDifficulty=> _t('ปานกลาง',         'Moderate');
  String get hardDifficulty    => _t('ยาก',             'Hard');
  String get close             => _t('ปิด',              'Close');
  String get chiangMaiCity     => _t('เชียงใหม่',        'Chiang Mai');
  String get pressRecordToStart=> _t('กด "บันทึก" เพื่อเริ่มกิจกรรม', 'Press "Record" to start activity');
  String get cyclingLabel      => _t('ปั่นจักรยาน',      'Cycling');
  String get runningLabel      => _t('วิ่ง',            'Running');
  String get runner            => _t('นักวิ่ง',          'Runner');
  String get newItems          => _t('ใหม่',             'new');
}


