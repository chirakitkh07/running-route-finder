import 'package:latlong2/latlong.dart';
import '../l10n/tr.dart';
import 'popular_route_paths.dart';

class Waypoint {
  final String name;
  final String type;
  final LatLng position;
  final String? description;
  final String? nameEn;
  final String? descriptionEn;

  const Waypoint({
    required this.name,
    required this.type,
    required this.position,
    this.description,
    this.nameEn,
    this.descriptionEn,
  });

  /// ชื่อ/คำอธิบายตามภาษาปัจจุบัน (ถ้าไม่มีภาษาอังกฤษใช้ภาษาไทย)
  String get displayName => tr(name, (nameEn?.trim().isNotEmpty ?? false) ? nameEn! : name);
  String? get displayDescription => description == null
      ? null
      : tr(description!, (descriptionEn?.trim().isNotEmpty ?? false) ? descriptionEn! : description!);

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'type': type,
      'lat': position.latitude,
      'lng': position.longitude,
      'description': description,
      if (nameEn != null) 'nameEn': nameEn,
      if (descriptionEn != null) 'descriptionEn': descriptionEn,
    };
  }

  factory Waypoint.fromMap(Map<String, dynamic> map) {
    return Waypoint(
      name: map['name']?.toString() ?? '',
      type: map['type']?.toString() ?? 'park',
      position: LatLng(
        (map['lat'] as num?)?.toDouble() ?? 0.0,
        (map['lng'] as num?)?.toDouble() ?? 0.0,
      ),
      description: map['description']?.toString(),
      nameEn: map['nameEn']?.toString(),
      descriptionEn: map['descriptionEn']?.toString(),
    );
  }
}

class RunningRoute {
  final String id;
  final String name;
  final String nameEn;
  final String description;
  final String descriptionEn;
  final double distanceKm;
  final String difficulty;
  final int elevationGainM;
  final String estimatedTime;
  final List<LatLng> path;
  final List<Waypoint> waypoints;
  final int safetyScore;

  const RunningRoute({
    required this.id,
    required this.name,
    required this.nameEn,
    required this.description,
    this.descriptionEn = '',
    required this.distanceKm,
    required this.difficulty,
    required this.elevationGainM,
    required this.estimatedTime,
    required this.path,
    required this.waypoints,
    required this.safetyScore,
  });

  /// ชื่อ/คำอธิบายตามภาษาปัจจุบัน
  String get displayName => tr(
      name.isNotEmpty ? name : nameEn, nameEn.trim().isNotEmpty ? nameEn : name);
  String get displayDescription =>
      tr(description, descriptionEn.trim().isNotEmpty ? descriptionEn : description);

  RunningRoute copyWith({
    String? id,
    String? name,
    String? nameEn,
    String? description,
    String? descriptionEn,
    double? distanceKm,
    String? difficulty,
    int? elevationGainM,
    String? estimatedTime,
    List<LatLng>? path,
    List<Waypoint>? waypoints,
    int? safetyScore,
  }) {
    return RunningRoute(
      id: id ?? this.id,
      name: name ?? this.name,
      nameEn: nameEn ?? this.nameEn,
      description: description ?? this.description,
      descriptionEn: descriptionEn ?? this.descriptionEn,
      distanceKm: distanceKm ?? this.distanceKm,
      difficulty: difficulty ?? this.difficulty,
      elevationGainM: elevationGainM ?? this.elevationGainM,
      estimatedTime: estimatedTime ?? this.estimatedTime,
      path: path ?? this.path,
      waypoints: waypoints ?? this.waypoints,
      safetyScore: safetyScore ?? this.safetyScore,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'nameEn': nameEn,
      'description': description,
      'descriptionEn': descriptionEn,
      'distanceKm': distanceKm,
      'difficulty': difficulty,
      'elevationGainM': elevationGainM,
      'estimatedTime': estimatedTime,
      'path': path.map((p) => {'lat': p.latitude, 'lng': p.longitude}).toList(),
      'waypoints': waypoints.map((w) => w.toMap()).toList(),
      'safetyScore': safetyScore,
    };
  }

  factory RunningRoute.fromMap(Map<String, dynamic> map, [String? docId]) {
    final rawPath = map['path'] as List<dynamic>? ?? [];
    final parsedPath = rawPath.map((item) {
      if (item is Map) {
        final lat = (item['lat'] as num?)?.toDouble() ?? 0.0;
        final lng = (item['lng'] as num?)?.toDouble() ?? 0.0;
        return LatLng(lat, lng);
      }
      return const LatLng(0, 0);
    }).where((p) => p.latitude != 0 || p.longitude != 0).toList();

    final rawWaypoints = map['waypoints'] as List<dynamic>? ?? [];
    final parsedWaypoints = rawWaypoints
        .whereType<Map<String, dynamic>>()
        .map((w) => Waypoint.fromMap(w))
        .toList();

    return RunningRoute(
      id: docId ?? map['id']?.toString() ?? '',
      name: map['name']?.toString() ?? '',
      nameEn: map['nameEn']?.toString() ?? '',
      description: map['description']?.toString() ?? '',
      descriptionEn: map['descriptionEn']?.toString() ?? '',
      distanceKm: (map['distanceKm'] as num?)?.toDouble() ?? 0.0,
      difficulty: map['difficulty']?.toString() ?? 'easy',
      elevationGainM: (map['elevationGainM'] as num?)?.toInt() ?? 0,
      estimatedTime: map['estimatedTime']?.toString() ?? '',
      path: parsedPath,
      waypoints: parsedWaypoints,
      safetyScore: (map['safetyScore'] as num?)?.toInt() ?? 80,
    );
  }
}

class ChiangMaiRoutes {
  /// เส้นทางในแอป: path สร้างจาก Routing API (OSRM เดินเท้า) จึงอยู่บนถนน/ทางเดินจริงใน OSM
  /// — ดู [PopularRoutePaths] (สร้างใหม่ด้วย tool/route_check_test.dart)
  static final Map<String, List<LatLng>> _roadPaths = {
    'moat_loop': PopularRoutePaths.moatLoop,
    'buak_had': PopularRoutePaths.buakHad,
    'huay_tueng_thao': PopularRoutePaths.huayTuengThao,
    'cmu_campus': PopularRoutePaths.cmuCampus,
    'stadium_700': PopularRoutePaths.stadium700,
    'doi_suthep': PopularRoutePaths.doiSuthep,
  };

  /// ระยะทางเดิมของเส้นทางวาดมือ (ก่อนแนบถนน) — ใช้ตรวจว่าค่าใน Firestore ยังเป็นค่าเก่าหรือไม่
  static const Map<String, double> _legacyDistanceKm = {
    'moat_loop': 6.4,
    'buak_had': 2.5,
    'huay_tueng_thao': 5.0,
    'cmu_campus': 7.2,
    'stadium_700': 4.0,
    'doi_suthep': 11.0,
  };

  /// true ถ้า path ของเส้นทางนี้เป็นเส้นที่สร้างจาก Routing API แล้ว (แสดงได้โดยไม่ต้องขอเส้นทางใหม่)
  static bool hasRoadPath(RunningRoute route) =>
      route.path.length >= 2 && identical(route.path, _roadPaths[route.id]);

  static final List<RunningRoute> routes = [
    // 1. รอบคูเมืองเชียงใหม่
    RunningRoute(
      id: 'moat_loop',
      name: 'รอบคูเมืองเชียงใหม่',
      nameEn: 'Old City Moat Loop',
      description: 'วิ่งรอบคูเมืองเก่า ร่มรื่นด้วยต้นไม้ใหญ่ มีทางเท้ากว้าง ปลอดภัยจากรถยนต์',
      descriptionEn: 'Run around the old city moat, shaded by big trees with wide sidewalks away from cars',
      distanceKm: 6.7,
      difficulty: 'easy',
      elevationGainM: 15,
      estimatedTime: '35-45 min',
      safetyScore: 90,
      path: PopularRoutePaths.moatLoop,
      waypoints: [
        Waypoint(name: 'ประตูช้างเผือก', type: 'rest', position: LatLng(18.7962, 98.9874), description: 'จุดเริ่มต้นยอดนิยม มีน้ำดื่มขาย', nameEn: 'Chang Phueak Gate', descriptionEn: 'Popular starting point, drinks sold here'),
        Waypoint(name: 'สวนบวกหาด', type: 'park', position: LatLng(18.7818, 98.9795), description: 'สวนสาธารณะ มีน้ำดื่ม ห้องน้ำ', nameEn: 'Buak Haad Park', descriptionEn: 'Public park with drinking water and toilets'),
        Waypoint(name: 'ประตูท่าแพ', type: 'viewpoint', position: LatLng(18.7877, 98.9937), description: 'Landmark เชียงใหม่ จุดถ่ายรูป', nameEn: 'Tha Phae Gate', descriptionEn: 'Chiang Mai landmark, photo spot'),
        Waypoint(name: 'ประตูสวนดอก', type: 'cafe', position: LatLng(18.7885, 98.9790), description: 'ร้านกาแฟและจุดพักผ่อนฝั่งตะวันตก', nameEn: 'Suan Dok Gate', descriptionEn: 'Cafés and rest spot on the west side'),
        Waypoint(name: 'แจ่งศรีภูมิ', type: 'toilet', position: LatLng(18.7959, 98.9937), description: 'ห้องน้ำใกล้มุมคูเมือง NE', nameEn: 'Jaeng Si Phum', descriptionEn: 'Toilets near the NE moat corner'),
      ],
    ),

    // 2. สวนบวกหาด
    RunningRoute(
      id: 'buak_had',
      name: 'สวนบวกหาด',
      nameEn: 'Buak Had Park Loop',
      description: 'วิ่งวนในสวนสาธารณะ เหมาะสำหรับครอบครัวและมือใหม่ มีทางเรียบ ร่มรื่น',
      descriptionEn: 'Loop inside a public park, great for families and beginners, flat and shady',
      distanceKm: 0.62,
      difficulty: 'easy',
      elevationGainM: 5,
      estimatedTime: '4-6 min',
      safetyScore: 95,
      path: PopularRoutePaths.buakHad,
      waypoints: [
        Waypoint(name: 'ทางเข้าสวน', type: 'rest', position: LatLng(18.7817, 98.9791), description: 'ทางเข้าหลัก มีที่จอดรถ', nameEn: 'Park Entrance', descriptionEn: 'Main entrance with parking'),
        Waypoint(name: 'จุดน้ำดื่ม', type: 'water', position: LatLng(18.7815, 98.9802), description: 'ตู้น้ำดื่ม ฟรี', nameEn: 'Water Point', descriptionEn: 'Free drinking water dispenser'),
        Waypoint(name: 'ห้องน้ำสวน', type: 'toilet', position: LatLng(18.7810, 98.9800), description: 'ห้องน้ำสะอาด', nameEn: 'Park Toilets', descriptionEn: 'Clean toilets'),
      ],
    ),

    // 3. อ่างเก็บน้ำห้วยตึงเฒ่า
    RunningRoute(
      id: 'huay_tueng_thao',
      name: 'อ่างเก็บน้ำห้วยตึงเฒ่า',
      nameEn: 'Huay Tueng Thao Reservoir',
      description: 'เส้นทางธรรมชาติรอบอ่างเก็บน้ำ วิวสวย อากาศดี เหมาะวิ่ง Trail',
      descriptionEn: 'Nature trail around the reservoir with great views and fresh air, ideal for trail running',
      distanceKm: 4.05,
      difficulty: 'moderate',
      elevationGainM: 80,
      estimatedTime: '25-35 min',
      safetyScore: 82,
      path: PopularRoutePaths.huayTuengThao,
      waypoints: [
        Waypoint(name: 'ทางเข้าอ่างเก็บน้ำ', type: 'rest', position: LatLng(18.8618, 98.9371), description: 'จุดเริ่ม มีร้านค้า ค่าเข้า 20 บาท', nameEn: 'Reservoir Entrance', descriptionEn: 'Start point with shops, entry fee 20 THB'),
        Waypoint(name: 'จุดชมวิว', type: 'viewpoint', position: LatLng(18.8680, 98.9468), description: 'วิวอ่างเก็บน้ำ+ดอยสุเทพ', nameEn: 'Viewpoint', descriptionEn: 'View of the reservoir and Doi Suthep'),
        Waypoint(name: 'ร้านอาหาร', type: 'cafe', position: LatLng(18.8665, 98.9528), description: 'ร้านอาหารริมน้ำ', nameEn: 'Restaurant', descriptionEn: 'Waterside restaurant'),
        Waypoint(name: '⚠️ ทางลื่น', type: 'danger', position: LatLng(18.8618, 98.9508), description: 'ทางลูกรัง อาจลื่นช่วงฝน', nameEn: '⚠️ Slippery Path', descriptionEn: 'Gravel path, may be slippery when raining'),
      ],
    ),

    // 4. มหาวิทยาลัยเชียงใหม่
    RunningRoute(
      id: 'cmu_campus',
      name: 'มหาวิทยาลัยเชียงใหม่',
      nameEn: 'CMU Campus Run',
      description: 'วิ่งในมหาวิทยาลัยเชียงใหม่ ร่มรื่น ผ่านอ่างแก้ว ทางราบเรียบ',
      descriptionEn: 'Run through Chiang Mai University, shady and flat, passing Ang Kaew reservoir',
      distanceKm: 8.27,
      difficulty: 'moderate',
      elevationGainM: 35,
      estimatedTime: '50-60 min',
      safetyScore: 88,
      path: PopularRoutePaths.cmuCampus,
      waypoints: [
        Waypoint(name: 'ประตูหน้า มช.', type: 'rest', position: LatLng(18.8037, 98.9535), description: 'ทางเข้าหลัก มีที่จอดรถ', nameEn: 'CMU Front Gate', descriptionEn: 'Main entrance with parking'),
        Waypoint(name: 'อ่างแก้ว', type: 'viewpoint', position: LatLng(18.8068, 98.9504), description: 'อ่างแก้ว สวยมากตอนเช้า', nameEn: 'Ang Kaew', descriptionEn: 'Ang Kaew reservoir, beautiful in the morning'),
        Waypoint(name: 'ร้านกาแฟ มช.', type: 'cafe', position: LatLng(18.7952, 98.9530), description: 'ร้านกาแฟนักศึกษา ราคาถูก', nameEn: 'CMU Café', descriptionEn: 'Cheap student café'),
        Waypoint(name: 'จุดน้ำดื่ม', type: 'water', position: LatLng(18.8010, 98.9470), description: 'ตู้น้ำดื่มใกล้คณะวิทย์', nameEn: 'Water Point', descriptionEn: 'Drinking water near the Faculty of Science'),
        Waypoint(name: 'ห้องน้ำ', type: 'toilet', position: LatLng(18.7905, 98.9555), description: 'อาคารกิจกรรม', nameEn: 'Toilets', descriptionEn: 'Activity building'),
      ],
    ),

    // 5. สนามกีฬา 700 ปี
    RunningRoute(
      id: 'stadium_700',
      name: 'สนามกีฬา 700 ปี',
      nameEn: '700 Year Stadium',
      description: 'สนามวิ่งมาตรฐาน มีลู่วิ่ง 400 เมตร พร้อมสวนรอบสนาม ไฟส่องสว่างดี',
      descriptionEn: 'Standard stadium with a 400 m track, surrounding park and good lighting',
      distanceKm: 3.07,
      difficulty: 'easy',
      elevationGainM: 10,
      estimatedTime: '18-25 min',
      safetyScore: 93,
      path: PopularRoutePaths.stadium700,
      waypoints: [
        Waypoint(name: 'ทางเข้าสนาม', type: 'rest', position: LatLng(18.8400, 98.9622), description: 'ทางเข้าหลัก จอดรถฟรี', nameEn: 'Stadium Entrance', descriptionEn: 'Main entrance, free parking'),
        Waypoint(name: 'จุดน้ำดื่ม', type: 'water', position: LatLng(18.8435, 98.9638), description: 'ตู้น้ำดื่มฟรี', nameEn: 'Water Point', descriptionEn: 'Free drinking water dispenser'),
        Waypoint(name: 'ห้องน้ำ', type: 'toilet', position: LatLng(18.8428, 98.9660), description: 'ห้องน้ำสะอาด ใกล้อัฒจันทร์', nameEn: 'Toilets', descriptionEn: 'Clean toilets near the grandstand'),
      ],
    ),

    // 6. ดอยสุเทพ Trail
    RunningRoute(
      id: 'doi_suthep',
      name: 'เส้นทาง Doi Suthep Trail',
      nameEn: 'Doi Suthep Trail Run',
      description: 'Trail Run ขึ้นดอยสุเทพ ท้าทาย ชันมาก แต่วิวสวยสุดยอด สำหรับนักวิ่งขั้นสูง',
      descriptionEn: 'Challenging, very steep trail run up Doi Suthep with amazing views, for advanced runners',
      distanceKm: 5.57,
      difficulty: 'hard',
      elevationGainM: 680,
      estimatedTime: '1h 30m - 2h',
      safetyScore: 65,
      path: PopularRoutePaths.doiSuthep,
      waypoints: [
        Waypoint(name: 'จุดเริ่ม (สวนสัตว์)', type: 'rest', position: LatLng(18.810335, 98.946177), description: 'ใกล้สวนสัตว์เชียงใหม่', nameEn: 'Start (Zoo)', descriptionEn: 'Near Chiang Mai Zoo'),
        Waypoint(name: 'วัดผาลาด', type: 'viewpoint', position: LatLng(18.7997, 98.9338), description: 'พักดื่มน้ำ ชมวัดผาลาดกลางป่า', nameEn: 'Wat Pha Lat', descriptionEn: 'Water break at the jungle temple'),
        Waypoint(name: '⚠️ ทางชัน', type: 'danger', position: LatLng(18.801473, 98.926222), description: 'ทางชันมาก ระวังหัวเข่า', nameEn: '⚠️ Steep Section', descriptionEn: 'Very steep, mind your knees'),
        Waypoint(name: 'วัดพระธาตุดอยสุเทพ', type: 'viewpoint', position: LatLng(18.804799, 98.921501), description: 'จุดหมาย! วิว 360° ของเชียงใหม่', nameEn: 'Wat Phra That Doi Suthep', descriptionEn: 'Finish! 360° view of Chiang Mai'),
      ],
    ),
  ];

  /// เพิ่มเส้นทางใหม่ (Normal Flow 3.1)
  static void addRoute(RunningRoute route) {
    // ใส่ไว้หน้าสุดเพื่อให้เห็นเส้นทางใหม่ทันที
    routes.insert(0, route);
  }

  /// แก้ไขข้อมูลเส้นทาง (Normal Flow 3.2)
  static void updateRoute(RunningRoute updated) {
    final idx = routes.indexWhere((r) => r.id == updated.id);
    if (idx != -1) {
      routes[idx] = updated;
    } else {
      routes.add(updated);
    }
  }

  /// ลบเส้นทาง (Normal Flow 3.3)
  static bool deleteRoute(String id) {
    final initialLen = routes.length;
    routes.removeWhere((r) => r.id == id);
    return routes.length < initialLen;
  }

  /// อัปเดตรายการเส้นทางทั้งหมดจากฐานข้อมูล
  static void setRoutes(List<RunningRoute> newRoutes) {
    // เส้นทางที่เคยบันทึกลง Firestore ก่อนมีฟิลด์ภาษาอังกฤษ → เติมคำอธิบาย/ชื่อจุดพักภาษาอังกฤษจากข้อมูลเดิม
    final known = {for (final r in routes) r.id: r};
    final merged = newRoutes.map((r) {
      final old = known[r.id];
      if (old == null) return r;
      // เส้นทางในแอปที่เก็บใน Firestore ยังเป็นพิกัดวาดมือ (ไม่ตรงถนน) → ใช้ path ที่แนบถนนแล้วแทน
      final roadPath = _roadPaths[r.id];
      if (roadPath != null && roadPath.length >= 2) {
        r = r.copyWith(
          path: roadPath,
          distanceKm: r.distanceKm == _legacyDistanceKm[r.id] ? old.distanceKm : r.distanceKm,
        );
      }
      final wps = r.waypoints.map((w) {
        if (w.nameEn != null && w.nameEn!.isNotEmpty) return w;
        Waypoint? match;
        for (final o in old.waypoints) {
          if (o.name == w.name) {
            match = o;
            break;
          }
        }
        if (match == null) return w;
        return Waypoint(
          name: w.name,
          type: w.type,
          position: w.position,
          description: w.description,
          nameEn: match.nameEn,
          descriptionEn: w.description == match.description ? match.descriptionEn : null,
        );
      }).toList();
      return r.copyWith(
        descriptionEn: r.descriptionEn.isNotEmpty || r.description != old.description
            ? r.descriptionEn
            : old.descriptionEn,
        waypoints: wps,
      );
    }).toList();
    routes.clear();
    routes.addAll(merged);
  }
}

