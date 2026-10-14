import 'dart:math' as math;
import 'package:latlong2/latlong.dart';
import 'running_zone.dart';
import 'route_data.dart';

/// ฟังก์ชันคำนวณแถบขอบเขต (buffer) รอบเส้นทาง polyline
///
/// คืนรูปหลายเหลี่ยม (closed polygon ring) โดยขยายไปทางซ้ายและขวาของเส้นทาง
/// ตามระยะ [meters] เมตริก ผลลัพธ์ที่ได้จะมีจำนวนจุดเท่ากับ 2 × n จุดเสมอ
List<LatLng> bufferPolyline(List<LatLng> points, double meters) {
  if (points.isEmpty) return const [];
  if (points.length == 1) {
    // กรณีจุดเดียว สร้างสี่เหลี่ยมรอบจุด
    const mPerDegLat = 111320.0;
    final lat = points.first.latitude;
    final lng = points.first.longitude;
    final latRad = lat * math.pi / 180.0;
    final mPerDegLng = 111320.0 * math.cos(latRad);
    final dLat = meters / mPerDegLat;
    final dLng = meters / (mPerDegLng.abs() < 1 ? 111320.0 : mPerDegLng);
    return [
      LatLng(lat + dLat, lng - dLng),
      LatLng(lat + dLat, lng + dLng),
      LatLng(lat - dLat, lng + dLng),
      LatLng(lat - dLat, lng - dLng),
    ];
  }

  const mPerDegLat = 111320.0;
  final n = points.length;
  final leftPoints = <LatLng>[];
  final rightPoints = <LatLng>[];

  for (int i = 0; i < n; i++) {
    final cur = points[i];
    final latRad = cur.latitude * math.pi / 180.0;
    final cosLat = math.cos(latRad);
    final mPerDegLng = 111320.0 * (cosLat.abs() < 1e-4 ? 1e-4 : cosLat);

    // ทิศทางของเส้น (dx, dy ในพิกัดเมตร)
    double dxM;
    double dyM;

    if (i == 0) {
      final next = points[1];
      dxM = (next.longitude - cur.longitude) * mPerDegLng;
      dyM = (next.latitude - cur.latitude) * mPerDegLat;
    } else if (i == n - 1) {
      final prev = points[n - 2];
      dxM = (cur.longitude - prev.longitude) * mPerDegLng;
      dyM = (cur.latitude - prev.latitude) * mPerDegLat;
    } else {
      final prev = points[i - 1];
      final next = points[i + 1];
      dxM = (next.longitude - prev.longitude) * mPerDegLng;
      dyM = (next.latitude - prev.latitude) * mPerDegLat;
    }

    final len = math.sqrt(dxM * dxM + dyM * dyM);
    final safeLen = len < 1e-6 ? 1.0 : len;

    // Normal vector หมุน 90 องศาทวนเข็มนาฬิกา (-dy, dx)
    final nxM = -dyM / safeLen;
    final nyM = dxM / safeLen;

    final offLat = (nyM * meters) / mPerDegLat;
    final offLng = (nxM * meters) / mPerDegLng;

    leftPoints.add(LatLng(cur.latitude + offLat, cur.longitude + offLng));
    rightPoints.add(LatLng(cur.latitude - offLat, cur.longitude - offLng));
  }

  // รวมฝั่งซ้าย (0..n-1) และฝั่งขวาย้อนกลับ (n-1..0) ให้ได้รอบวง 2 * n จุด
  return [...leftPoints, ...rightPoints.reversed];
}

/// รูปทรงสำรองของโซนจากเส้นทางเดิม: เส้นทางวงปิดใช้ตัววงเป็นขอบโซน, เส้นทางทางเดียวใช้แถบรอบเส้น
List<LatLng> zoneShapeFromPath(List<LatLng> path, double bufferMeters) {
  final closed = path.length >= 4 &&
      (path.first.latitude - path.last.latitude).abs() < 1e-5 &&
      (path.first.longitude - path.last.longitude).abs() < 1e-5;
  return closed ? path.sublist(0, path.length - 1) : bufferPolyline(path, bufferMeters);
}

/// รูปหลายเหลี่ยมประมาณวงกลม (ใช้เป็นค่าสำรองเมื่อดึงขอบเขตจริงจาก OSM ไม่ได้)
List<LatLng> circlePolygon(LatLng center, double radiusM, {int sides = 32}) {
  const mPerDegLat = 111320.0;
  final mPerDegLng = 111320.0 * math.cos(center.latitude * math.pi / 180.0);
  return [
    for (int i = 0; i < sides; i++)
      LatLng(
        center.latitude + (radiusM * math.sin(2 * math.pi * i / sides)) / mPerDegLat,
        center.longitude + (radiusM * math.cos(2 * math.pi * i / sides)) / mPerDegLng,
      ),
  ];
}

/// วิธีค้นหาขอบเขตจริงของโซนใน OpenStreetMap
/// - [tagFilter] ตัวกรองแท็ก Overpass เช่น `["leisure"="park"]`
/// - [center] จุดที่อยู่ภายในสถานที่ (ใช้เลือก polygon ที่ครอบจุดนี้)
/// - [radiusM] รัศมีค้นหารอบ [center]
class PresetZoneOsmSpec {
  final String tagFilter;
  final LatLng center;
  final double radiusM;
  const PresetZoneOsmSpec(this.tagFilter, this.center, this.radiusM);
}

/// ข้อมูลโซนเริ่มต้นของเชียงใหม่ (แทนเส้นทางเดิม + สถานที่ออกกำลังกายยอดนิยม)
class PresetZones {
  /// เวอร์ชันของวิธีดึงรูปทรง — เปลี่ยนเลขเมื่อแก้วิธีดึง เพื่อให้แคชเก่าใน Firestore ถูกดึงใหม่
  static const int geometryVersion = 3;

  static const String _parkFilter = '["leisure"~"^(park|garden)\$"]';
  static const String _sportsFilter = '["leisure"~"^(stadium|sports_centre|track|pitch)\$"]';

  /// ตารางค้นหาขอบเขตจริงจาก OSM (โซนที่ไม่มีในตารางใช้รูปทรงที่กำหนดในโค้ด)
  static const Map<String, PresetZoneOsmSpec> osmSpecs = {
    'zone_buakhad': PresetZoneOsmSpec(_parkFilter, LatLng(18.7822, 98.9795), 350),
    'zone_cmu': PresetZoneOsmSpec('["amenity"="university"]', LatLng(18.8020, 98.9530), 800),
    'zone_700yr': PresetZoneOsmSpec(_sportsFilter, LatLng(18.8410, 98.9640), 600),
    'zone_huaytueng': PresetZoneOsmSpec('["natural"="water"]', LatLng(18.8685, 98.9402), 1500),
    'zone_railway_park': PresetZoneOsmSpec(_parkFilter, LatLng(18.7880, 99.0157), 400),
    'zone_rajapruek': PresetZoneOsmSpec('["leisure"~"^(park|garden)\$"]', LatLng(18.7503, 98.9230), 1200),
    'zone_pao_park': PresetZoneOsmSpec(_parkFilter, LatLng(18.8317, 98.9681), 400),
    'zone_lanna_rama9': PresetZoneOsmSpec(_parkFilter, LatLng(18.8206, 98.9782), 400),
    'zone_payap_stadium': PresetZoneOsmSpec(_sportsFilter, LatLng(18.7983, 99.0309), 300),
    'zone_rmutl_doisaket_stadium': PresetZoneOsmSpec(_sportsFilter, LatLng(18.8569, 99.1779), 300),
    'zone_cm_municipal_stadium': PresetZoneOsmSpec(_sportsFilter, LatLng(18.8008, 98.9895), 400),
  };

  /// ดึงข้อมูลเส้นทางเดิมจาก ChiangMaiRoutes มาอ้างอิง waypoints / คำอธิบาย
  static RunningRoute? _findOldRoute(String id) {
    try {
      return ChiangMaiRoutes.routes.firstWhere((r) => r.id == id);
    } catch (_) {
      return null;
    }
  }

  static List<RunningZone> get defaultZones {
    final moatRoute = _findOldRoute('moat_loop');
    final buakhadRoute = _findOldRoute('buak_had');
    final huaytuengRoute = _findOldRoute('huay_tueng_thao');
    final cmuRoute = _findOldRoute('cmu_campus');
    final stadiumRoute = _findOldRoute('stadium_700');
    final suthepRoute = _findOldRoute('doi_suthep');

    // 1. รอบคูเมืองเชียงใหม่
    // แนวกลางคูเมืองจริง (สี่เหลี่ยม ~1.6 × 1.6 กม. เอียงเล็กน้อย) วัดจากแผนที่ OSM
    // — เดิมเป็นสี่เหลี่ยมตั้งฉากที่เยื้องออกนอกคูฝั่งตะวันออก ~60 ม. ทำให้เส้นทางหลุดเข้าซอย
    final moatPolygon = <LatLng>[
      const LatLng(18.79573, 98.9780), // แจ่งหัวริน NW
      const LatLng(18.79546, 98.9935), // แจ่งศรีภูมิ NE
      const LatLng(18.78105, 98.9929), // แจ่งขะต๊ำ SE
      const LatLng(18.78139, 98.9778), // แจ่งกู่เฮือง SW
    ];

    // 2. สวนบวกหาด
    final buakhadPath = buakhadRoute?.path ?? [
      const LatLng(18.7817, 98.9791),
      const LatLng(18.7820, 98.9803),
      const LatLng(18.7817, 98.9814),
      const LatLng(18.7808, 98.9813),
      const LatLng(18.7804, 98.9803),
      const LatLng(18.7810, 98.9790),
    ];
    final buakhadPolygon = zoneShapeFromPath(buakhadPath, 25.0);

    // 3. อ่างเก็บน้ำห้วยตึงเฒ่า
    final huaytuengPath = huaytuengRoute?.path ?? [
      const LatLng(18.8618, 98.9371),
      const LatLng(18.8645, 98.9400),
      const LatLng(18.8680, 98.9468),
      const LatLng(18.8678, 98.9512),
      const LatLng(18.8630, 98.9522),
      const LatLng(18.8598, 98.9448),
      const LatLng(18.8618, 98.9371),
    ];
    final huaytuengPolygon = zoneShapeFromPath(huaytuengPath, 35.0);

    // 4. มหาวิทยาลัยเชียงใหม่
    final cmuPath = cmuRoute?.path ?? [
      const LatLng(18.8037, 98.9535),
      const LatLng(18.8068, 98.9504),
      const LatLng(18.8050, 98.9472),
      const LatLng(18.7975, 98.9492),
      const LatLng(18.7930, 98.9558),
      const LatLng(18.7985, 98.9558),
      const LatLng(18.8037, 98.9535),
    ];
    final cmuPolygon = zoneShapeFromPath(cmuPath, 30.0);

    // 5. สนามกีฬา 700 ปี
    final stadiumPath = stadiumRoute?.path ?? [
      const LatLng(18.8400, 98.9622),
      const LatLng(18.8430, 98.9628),
      const LatLng(18.8433, 98.9650),
      const LatLng(18.8418, 98.9665),
      const LatLng(18.8384, 98.9652),
      const LatLng(18.8390, 98.9623),
      const LatLng(18.8400, 98.9622),
    ];
    final stadiumPolygon = zoneShapeFromPath(stadiumPath, 25.0);

    // 6. เส้นทาง Doi Suthep Trail (ยังเป็นแนว trail ขยาย buffer 30 ม.)
    final suthepPath = suthepRoute?.path ?? [
      const LatLng(18.8105, 98.9460),
      const LatLng(18.8080, 98.9408),
      const LatLng(18.8050, 98.9315),
      const LatLng(18.8062, 98.9245),
      const LatLng(18.8048, 98.9215),
    ];
    final suthepPolygon = bufferPolyline(suthepPath, 30.0);

    return [
      RunningZone(
        id: 'zone_moat',
        name: moatRoute?.name ?? 'รอบคูเมืองเชียงใหม่',
        nameEn: moatRoute?.nameEn ?? 'Old City Moat Loop',
        description: moatRoute?.description ??
            'วิ่งรอบคูเมืองเก่า ร่มรื่นด้วยต้นไม้ใหญ่ มีทางเท้ากว้าง ปลอดภัยจากรถยนต์',
        descriptionEn: moatRoute?.descriptionEn ??
            'Run around the old city moat, shaded by big trees with wide sidewalks away from cars',
        category: 'moat',
        polygons: [moatPolygon],
        center: const LatLng(18.7883, 98.9853),
        walkableLengthKm: moatRoute?.distanceKm ?? 6.4,
        waypoints: moatRoute?.waypoints ?? const [],
        source: 'preset',
        osmRef: 'relation/moat',
        safetyScore: 90,
      ),
      RunningZone(
        id: 'zone_buakhad',
        name: buakhadRoute?.name ?? 'สวนบวกหาด',
        nameEn: buakhadRoute?.nameEn ?? 'Buak Had Park Loop',
        description: buakhadRoute?.description ??
            'วิ่งวนในสวนสาธารณะ เหมาะสำหรับครอบครัวและมือใหม่ มีทางเรียบ ร่มรื่น',
        descriptionEn: buakhadRoute?.descriptionEn ??
            'Loop inside a public park, great for families and beginners, flat and shady',
        category: 'park',
        polygons: [buakhadPolygon],
        center: const LatLng(18.7815, 98.9803),
        walkableLengthKm: buakhadRoute?.distanceKm ?? 2.5,
        waypoints: buakhadRoute?.waypoints ?? const [],
        source: 'preset',
        osmRef: 'way/buakhad',
        safetyScore: 95,
      ),
      RunningZone(
        id: 'zone_huaytueng',
        name: huaytuengRoute?.name ?? 'อ่างเก็บน้ำห้วยตึงเฒ่า',
        nameEn: huaytuengRoute?.nameEn ?? 'Huay Tueng Thao Reservoir',
        description: huaytuengRoute?.description ??
            'เส้นทางธรรมชาติรอบอ่างเก็บน้ำ วิวสวย อากาศดี เหมาะวิ่ง Trail',
        descriptionEn: huaytuengRoute?.descriptionEn ??
            'Nature trail around the reservoir with great views and fresh air, ideal for trail running',
        category: 'reservoir',
        polygons: [huaytuengPolygon],
        center: const LatLng(18.8645, 98.9450),
        walkableLengthKm: huaytuengRoute?.distanceKm ?? 5.0,
        waypoints: huaytuengRoute?.waypoints ?? const [],
        source: 'preset',
        osmRef: 'way/huaytueng',
        safetyScore: 82,
      ),
      RunningZone(
        id: 'zone_cmu',
        name: cmuRoute?.name ?? 'มหาวิทยาลัยเชียงใหม่',
        nameEn: cmuRoute?.nameEn ?? 'CMU Campus Run',
        description: cmuRoute?.description ??
            'วิ่งในมหาวิทยาลัยเชียงใหม่ ร่มรื่น ผ่านอ่างแก้ว ทางราบเรียบ',
        descriptionEn: cmuRoute?.descriptionEn ??
            'Run through Chiang Mai University, shady and flat, passing Ang Kaew reservoir',
        category: 'campus',
        polygons: [cmuPolygon],
        center: const LatLng(18.8000, 98.9520),
        walkableLengthKm: cmuRoute?.distanceKm ?? 7.2,
        waypoints: cmuRoute?.waypoints ?? const [],
        source: 'preset',
        osmRef: 'way/cmu',
        safetyScore: 88,
      ),
      RunningZone(
        id: 'zone_700yr',
        name: stadiumRoute?.name ?? 'สนามกีฬา 700 ปี',
        nameEn: stadiumRoute?.nameEn ?? '700 Year Stadium',
        description: stadiumRoute?.description ??
            'สนามวิ่งมาตรฐาน มีลู่วิ่ง 400 เมตร พร้อมสวนรอบสนาม ไฟส่องสว่างดี',
        descriptionEn: stadiumRoute?.descriptionEn ??
            'Standard stadium with a 400 m track, surrounding park and good lighting',
        category: 'stadium',
        polygons: [stadiumPolygon],
        center: const LatLng(18.8410, 98.9640),
        walkableLengthKm: stadiumRoute?.distanceKm ?? 4.0,
        waypoints: stadiumRoute?.waypoints ?? const [],
        source: 'preset',
        osmRef: 'way/700yr',
        safetyScore: 93,
      ),
      RunningZone(
        id: 'zone_suthep',
        name: suthepRoute?.name ?? 'เส้นทาง Doi Suthep Trail',
        nameEn: suthepRoute?.nameEn ?? 'Doi Suthep Trail Run',
        description: suthepRoute?.description ??
            'Trail Run ขึ้นดอยสุเทพ ท้าทาย ชันมาก แต่วิวสวยสุดยอด สำหรับนักวิ่งขั้นสูง',
        descriptionEn: suthepRoute?.descriptionEn ??
            'Challenging, very steep trail run up Doi Suthep with amazing views, for advanced runners',
        category: 'other',
        polygons: [suthepPolygon],
        center: const LatLng(18.8075, 98.9335),
        walkableLengthKm: suthepRoute?.distanceKm ?? 11.0,
        waypoints: suthepRoute?.waypoints ?? const [],
        source: 'preset',
        osmRef: 'way/doisuthep',
        safetyScore: 65,
      ),
      // ─── สถานที่ออกกำลังกายเพิ่มเติม (ขอบเขตจริงดึงจาก OSM, ค่าสำรองเป็นวงกลมรัศมีประมาณ) ───
      RunningZone(
        id: 'zone_railway_park',
        name: 'สวนสาธารณะรถไฟเชียงใหม่',
        nameEn: 'Chiang Mai Railway Park',
        description: 'สวนสาธารณะข้างสถานีรถไฟเชียงใหม่ มีลู่วิ่งรอบสวนประมาณ 1 กม. ลานกว้าง และเครื่องออกกำลังกาย',
        descriptionEn: 'Public park next to Chiang Mai railway station with a ~1 km running loop, open lawns and outdoor gym',
        category: 'park',
        polygons: [circlePolygon(const LatLng(18.7880, 99.0157), 220)],
        center: const LatLng(18.7880, 99.0157),
        walkableLengthKm: 1.0,
        source: 'preset',
        osmRef: 'search/leisure=park',
      ),
      RunningZone(
        id: 'zone_rajapruek',
        name: 'อุทยานหลวงราชพฤกษ์ (พืชสวนโลก)',
        nameEn: 'Royal Park Rajapruek',
        description: 'สวนขนาดใหญ่ (พื้นที่จัดงานพืชสวนโลก) ทางเดินกว้าง ร่มรื่น เหมาะวิ่งระยะยาว เปิดช่วงกลางวัน',
        descriptionEn: 'Large royal garden (former flora expo site) with wide shady paths, good for long runs; open daytime',
        category: 'park',
        polygons: [circlePolygon(const LatLng(18.7503, 98.9230), 650)],
        center: const LatLng(18.7503, 98.9230),
        walkableLengthKm: 5.0,
        source: 'preset',
        osmRef: 'search/leisure=park',
      ),
      RunningZone(
        id: 'zone_pao_park',
        name: 'สวนสาธารณะ อบจ.เชียงใหม่',
        nameEn: 'Chiang Mai PAO Public Park',
        description: 'สวนริมอ่างเก็บน้ำ วิวดอยสุเทพ ทางวิ่งรอบสวนประมาณ 1.4 กม. เปิด 24 ชั่วโมง',
        descriptionEn: 'Lakeside park with Doi Suthep views and a ~1.4 km jogging loop, open 24 hours',
        category: 'park',
        polygons: [circlePolygon(const LatLng(18.8317, 98.9681), 300)],
        center: const LatLng(18.8317, 98.9681),
        walkableLengthKm: 1.4,
        source: 'preset',
        osmRef: 'search/leisure=park',
      ),
      RunningZone(
        id: 'zone_lanna_rama9',
        name: 'สวนสาธารณะล้านนา ร.9',
        nameEn: 'Rama IX Lanna Park',
        description: 'สวนสาธารณะเงียบสงบ มีทางเดินรอบสระน้ำ เครื่องออกกำลังกาย และที่จอดรถ',
        descriptionEn: 'Quiet public park with paths around the ponds, exercise equipment and parking',
        category: 'park',
        polygons: [circlePolygon(const LatLng(18.8206, 98.9782), 350)],
        center: const LatLng(18.8206, 98.9782),
        walkableLengthKm: 2.0,
        source: 'preset',
        osmRef: 'search/leisure=park',
      ),
      RunningZone(
        id: 'zone_payap_stadium',
        name: 'สนามกีฬา มหาวิทยาลัยพายัพ',
        nameEn: 'Payap University Stadium',
        description: 'สนามกีฬากลาง มหาวิทยาลัยพายัพ วิทยาเขตแม่คาว มีลู่วิ่งรอบสนาม',
        descriptionEn: 'Central stadium of Payap University (Mae Khao campus) with a track around the field',
        category: 'stadium',
        polygons: [circlePolygon(const LatLng(18.7983, 99.0309), 120)],
        center: const LatLng(18.7983, 99.0309),
        walkableLengthKm: 0.4,
        source: 'preset',
        osmRef: 'search/leisure=stadium',
      ),
      RunningZone(
        id: 'zone_rmutl_doisaket_stadium',
        name: 'สนามกีฬา มทร.ล้านนา ดอยสะเก็ด',
        nameEn: 'RMUTL Doi Saket Stadium',
        description: 'สนามกีฬาในมหาวิทยาลัยเทคโนโลยีราชมงคลล้านนา ดอยสะเก็ด ล้อมรอบด้วยภูเขา อากาศดี',
        descriptionEn: 'Stadium inside RMUTL Doi Saket campus, surrounded by mountains with fresh air',
        category: 'stadium',
        polygons: [circlePolygon(const LatLng(18.8569, 99.1779), 120)],
        center: const LatLng(18.8569, 99.1779),
        walkableLengthKm: 0.4,
        source: 'preset',
        osmRef: 'search/leisure=stadium',
      ),
      RunningZone(
        id: 'zone_cm_municipal_stadium',
        name: 'สนามกีฬาเทศบาลนครเชียงใหม่',
        nameEn: 'Chiang Mai Municipal Stadium',
        description: 'ลู่วิ่งมาตรฐาน 400 ม. ในสนาม และทางวิ่งรอบสนามประมาณ 600 ม.–1 กม. มีห้องน้ำ เปิดเช้ามืดถึงค่ำ',
        descriptionEn: '400 m track inside plus a 600 m–1 km loop around the stadium, toilets available, open early to late',
        category: 'stadium',
        polygons: [circlePolygon(const LatLng(18.8008, 98.9895), 180)],
        center: const LatLng(18.8008, 98.9895),
        walkableLengthKm: 1.0,
        source: 'preset',
        osmRef: 'search/leisure=stadium',
      ),
    ];
  }
}
