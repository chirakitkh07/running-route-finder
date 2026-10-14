import 'dart:math' as math;
import 'package:latlong2/latlong.dart';
import '../services/zone_service.dart';

/// ยูทิลิตี้สำหรับคำนวณทางภูมิศาสตร์ (Geographical calculations)
/// สำหรับระบบค้นหาและวิเคราะห์โซนวิ่ง
class GeoUtils {
  static const double earthRadiusMeters = 6378137.0; // WGS84
  static const String _base32 = '0123456789bcdefghjkmnpqrstuvwxyz';

  /// คำนวณพื้นที่รูปหลายเหลี่ยม (Polygon Area) เป็นตารางเมตร ด้วย Shoelace Algorithm
  ///
  /// โดยแปลงพิกัด LatLng เป็นระนาบเมตร (Equirectangular projection)
  /// รองรับการคำนวณพื้นที่จริงบนพื้นโลก
  static double calculateShoelaceArea(List<LatLng> polygon) {
    if (polygon.length < 3) return 0.0;

    // กรองพิกัดที่ไม่สมบูรณ์
    final validPoints = polygon.where((p) => p.latitude.isFinite && p.longitude.isFinite).toList();
    if (validPoints.length < 3) return 0.0;

    // คำนวณศูนย์กลางเพื่อใช้เป็นระนาบอ้างอิง
    double sumLat = 0.0;
    double sumLng = 0.0;
    for (final p in validPoints) {
      sumLat += p.latitude;
      sumLng += p.longitude;
    }
    final centerLat = sumLat / validPoints.length;
    final centerLatRad = centerLat * (math.pi / 180.0);

    // แปลงจุดเป็นหน่วยเมตร (x, y)
    final pointsInMeters = validPoints.map((p) {
      final dLatRad = (p.latitude - centerLat) * (math.pi / 180.0);
      final dLngRad = (p.longitude - (sumLng / validPoints.length)) * (math.pi / 180.0);
      final x = earthRadiusMeters * math.cos(centerLatRad) * dLngRad;
      final y = earthRadiusMeters * dLatRad;
      return math.Point<double>(x, y);
    }).toList();

    // Shoelace Formula: 0.5 * |sum(x_i * y_{i+1} - x_{i+1} * y_i)|
    double sum = 0.0;
    final n = pointsInMeters.length;
    for (int i = 0; i < n; i++) {
      final p1 = pointsInMeters[i];
      final p2 = pointsInMeters[(i + 1) % n];
      sum += (p1.x * p2.y) - (p2.x * p1.y);
    }

    return (sum.abs() * 0.5);
  }

  /// คำนวณสัดส่วนการซ้อนทับกันของ Polygon 2 รูป (Overlap Fraction: 0.0 - 1.0)
  ///
  /// คืนค่าอัตราส่วนของพื้นที่ที่ทับซ้อนกันเทียบกับพื้นที่รูปที่เล็กกว่า
  /// หากซ้อนทับกันเกินเกณฑ์ (เช่น 0.60 หรือ 60%) สามารถใช้ตัดรูปที่เล็กกว่าออกได้
  static double calculatePolygonOverlap(List<LatLng> polyA, List<LatLng> polyB) {
    if (polyA.length < 3 || polyB.length < 3) return 0.0;

    // 1. ตรวจสอบ Bounding Box ก่อน หากไม่ชนกันเลย ให้คืนค่า 0 ทันที
    double minLatA = double.infinity, maxLatA = -double.infinity;
    double minLngA = double.infinity, maxLngA = -double.infinity;
    for (final p in polyA) {
      if (p.latitude < minLatA) minLatA = p.latitude;
      if (p.latitude > maxLatA) maxLatA = p.latitude;
      if (p.longitude < minLngA) minLngA = p.longitude;
      if (p.longitude > maxLngA) maxLngA = p.longitude;
    }

    double minLatB = double.infinity, maxLatB = -double.infinity;
    double minLngB = double.infinity, maxLngB = -double.infinity;
    for (final p in polyB) {
      if (p.latitude < minLatB) minLatB = p.latitude;
      if (p.latitude > maxLatB) maxLatB = p.latitude;
      if (p.longitude < minLngB) minLngB = p.longitude;
      if (p.longitude > maxLngB) maxLngB = p.longitude;
    }

    if (maxLatA < minLatB || minLatA > maxLatB || maxLngA < minLngB || minLngA > maxLngB) {
      return 0.0;
    }

    // 2. คำนวณพื้นที่โดยประมาณ
    final areaA = calculateShoelaceArea(polyA);
    final areaB = calculateShoelaceArea(polyB);
    if (areaA <= 0 || areaB <= 0) return 0.0;

    // กำหนดรูปที่เล็กกว่าเป็นเป้าหมายในการสุ่มตัวอย่าง
    final smallerPoly = areaA <= areaB ? polyA : polyB;
    final largerPoly = areaA <= areaB ? polyB : polyA;
    final minLat = areaA <= areaB ? minLatA : minLatB;
    final maxLat = areaA <= areaB ? maxLatA : maxLatB;
    final minLng = areaA <= areaB ? minLngA : minLngB;
    final maxLng = areaA <= areaB ? maxLngA : maxLngB;

    // 3. สุ่มตัวอย่างแบบตาราง (Grid Sampling) 8x8 = 64 จุดใน BBox ของรูปเล็ก
    int totalInsideSmaller = 0;
    int bothInside = 0;
    const int steps = 8;
    final stepLat = (maxLat - minLat) / (steps + 1);
    final stepLng = (maxLng - minLng) / (steps + 1);

    for (int i = 1; i <= steps; i++) {
      for (int j = 1; j <= steps; j++) {
        final samplePt = LatLng(minLat + (i * stepLat), minLng + (j * stepLng));
        if (ZoneService.pointInPolygon(samplePt, smallerPoly)) {
          totalInsideSmaller++;
          if (ZoneService.pointInPolygon(samplePt, largerPoly)) {
            bothInside++;
          }
        }
      }
    }

    // ตรวจสอบเวอร์เท็กซ์ของ smallerPoly ร่วมด้วยเพื่อความแม่นยำ
    for (final v in smallerPoly) {
      totalInsideSmaller++;
      if (ZoneService.pointInPolygon(v, largerPoly)) {
        bothInside++;
      }
    }

    if (totalInsideSmaller == 0) return 0.0;
    return bothInside / totalInsideSmaller;
  }

  /// เข้ารหัส Geohash 5 หลัก (ความละเอียดประมาณ 4.9 กม. x 4.9 กม.)
  static String encodeGeohash5(double lat, double lng) {
    return _encodeGeohash(lat, lng, 5);
  }

  static String _encodeGeohash(double latitude, double longitude, int precision) {
    double minLat = -90.0, maxLat = 90.0;
    double minLng = -180.0, maxLng = 180.0;
    final buffer = StringBuffer();
    bool isEven = true;
    int bit = 0;
    int ch = 0;

    while (buffer.length < precision) {
      if (isEven) {
        final mid = (minLng + maxLng) / 2.0;
        if (longitude >= mid) {
          ch |= (1 << (4 - bit));
          minLng = mid;
        } else {
          maxLng = mid;
        }
      } else {
        final mid = (minLat + maxLat) / 2.0;
        if (latitude >= mid) {
          ch |= (1 << (4 - bit));
          minLat = mid;
        } else {
          maxLat = mid;
        }
      }

      isEven = !isEven;
      if (bit < 4) {
        bit++;
      } else {
        buffer.write(_base32[ch]);
        bit = 0;
        ch = 0;
      }
    }

    return buffer.toString();
  }

  /// ถอดรหัส Geohash คืนขอบเขต (Bounding Box) [minLat, maxLat, minLng, maxLng]
  static List<double> decodeGeohashBBox(String geohash) {
    double minLat = -90.0, maxLat = 90.0;
    double minLng = -180.0, maxLng = 180.0;
    bool isEven = true;

    for (int i = 0; i < geohash.length; i++) {
      final c = geohash[i];
      final cd = _base32.indexOf(c);
      if (cd == -1) continue;

      for (int mask = 16; mask > 0; mask >>= 1) {
        if (isEven) {
          final mid = (minLng + maxLng) / 2.0;
          if ((cd & mask) != 0) {
            minLng = mid;
          } else {
            maxLng = mid;
          }
        } else {
          final mid = (minLat + maxLat) / 2.0;
          if ((cd & mask) != 0) {
            minLat = mid;
          } else {
            maxLat = mid;
          }
        }
        isEven = !isEven;
      }
    }

    return [minLat, maxLat, minLng, maxLng];
  }

  /// คืนรายการ Geohash ข้างเคียงทั้ง 8 ทิศ + ช่องตัวเอง (รวม 9 ช่อง)
  static List<String> getGeohashNeighbors(String geohash) {
    if (geohash.isEmpty) return [];
    final bbox = decodeGeohashBBox(geohash);
    final minLat = bbox[0];
    final maxLat = bbox[1];
    final minLng = bbox[2];
    final maxLng = bbox[3];

    final latHeight = maxLat - minLat;
    final lngWidth = maxLng - minLng;
    final centerLat = (minLat + maxLat) / 2.0;
    final centerLng = (minLng + maxLng) / 2.0;

    final results = <String>{};
    for (int dx = -1; dx <= 1; dx++) {
      for (int dy = -1; dy <= 1; dy++) {
        final neighborLat = centerLat + (dy * latHeight);
        final neighborLng = centerLng + (dx * lngWidth);
        results.add(_encodeGeohash(neighborLat, neighborLng, geohash.length));
      }
    }

    return results.toList();
  }
}
