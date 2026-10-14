import 'dart:convert';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import '../l10n/tr.dart';

/// ข้อมูลคุณภาพอากาศและสภาพอากาศ
class AirQualityData {
  final double pm25;
  final double pm10;
  final double ozone;
  final double temperature;
  final double humidity;
  final double windSpeedKmh;
  final double visibilityKm;
  final int aqi;
  final String aqiLabel;
  final double latitude;
  final double longitude;
  final DateTime fetchedAt;

  AirQualityData({
    required this.pm25,
    required this.pm10,
    required this.ozone,
    required this.temperature,
    required this.humidity,
    required this.windSpeedKmh,
    required this.visibilityKm,
    required this.aqi,
    required this.aqiLabel,
    required this.latitude,
    required this.longitude,
    required this.fetchedAt,
  });

  /// สีตาม AQI
  int get aqiColorValue {
    if (aqi <= 50) return 0xFF2ECC71;   // เขียว - ดี
    if (aqi <= 100) return 0xFFF39C12;  // เหลือง - ปานกลาง
    if (aqi <= 150) return 0xFFE67E22;  // ส้ม - ไม่ดีสำหรับกลุ่มเสี่ยง
    if (aqi <= 200) return 0xFFE74C3C;  // แดง - ไม่ดี
    return 0xFF8E44AD;                   // ม่วง - อันตราย
  }

  bool get isGoodForRunning => aqi <= 100;
  bool get needsMask => aqi > 150;

  String get pm25Label {
    if (pm25 <= 12) return tr('ดีมาก', 'Very good');
    if (pm25 <= 35.4) return tr('ดี', 'Good');
    if (pm25 <= 55.4) return tr('ปานกลาง', 'Moderate');
    return tr('ไม่ดี', 'Poor');
  }

  List<String> get runningRecommendations {
    if (aqi <= 50) {
      return [
        tr('เหมาะสำหรับการวิ่งทุกระดับ', 'Suitable for runners of all levels'),
        tr('ไม่จำเป็นต้องสวมหน้ากาก', 'No mask needed'),
        tr('อากาศดี เหมาะวิ่งระยะไกล', 'Clean air, great for long runs'),
      ];
    } else if (aqi <= 100) {
      return [
        tr('เหมาะสำหรับคนทั่วไป', 'Fine for most people'),
        tr('กลุ่มเสี่ยง (หอบหืด/โรคหัวใจ) ควรระวัง', 'Sensitive groups (asthma/heart disease) should take care'),
        tr('แนะนำวิ่งช่วงเช้า-เย็น', 'Run in the morning or evening'),
      ];
    } else if (aqi <= 150) {
      return [
        tr('กลุ่มเสี่ยงควรหลีกเลี่ยงการวิ่งกลางแจ้ง', 'Sensitive groups should avoid outdoor running'),
        tr('คนทั่วไปควรลดความเข้มข้น', 'Others should reduce intensity'),
        tr('แนะนำสวมหน้ากาก N95', 'Wear an N95 mask'),
      ];
    } else {
      return [
        tr('ไม่แนะนำวิ่งกลางแจ้ง', 'Outdoor running not recommended'),
        tr('ควรวิ่งในสถานที่ปิด/มีเครื่องฟอกอากาศ', 'Run indoors or where air is purified'),
        tr('สวมหน้ากาก N95 หากจำเป็น', 'Wear an N95 mask if you must go out'),
      ];
    }
  }
}

class AirQualityService {
  /// คำนวณ AQI จาก PM2.5 (สูตร US EPA)
  static int calculateAQI(double pm25) {
    if (pm25 < 0) return 0;
    if (pm25 <= 12.0) return _aqiLinear(50, 0, 12.0, 0.0, pm25);
    if (pm25 <= 35.4) return _aqiLinear(100, 51, 35.4, 12.1, pm25);
    if (pm25 <= 55.4) return _aqiLinear(150, 101, 55.4, 35.5, pm25);
    if (pm25 <= 150.4) return _aqiLinear(200, 151, 150.4, 55.5, pm25);
    if (pm25 <= 250.4) return _aqiLinear(300, 201, 250.4, 150.5, pm25);
    return 301;
  }

  static int _aqiLinear(int hi, int lo, double cHi, double cLo, double c) {
    return ((hi - lo) / (cHi - cLo) * (c - cLo) + lo).round();
  }

  static String aqiLabel(int aqi) {
    if (aqi <= 50) return tr('ดี', 'Good');
    if (aqi <= 100) return tr('ปานกลาง', 'Moderate');
    if (aqi <= 150) return tr('ไม่ดีสำหรับกลุ่มเสี่ยง', 'Unhealthy for sensitive groups');
    if (aqi <= 200) return tr('ไม่ดี', 'Unhealthy');
    return tr('อันตราย', 'Hazardous');
  }

  /// ดึงตำแหน่ง GPS ปัจจุบัน, fallback เป็นเชียงใหม่
  static Future<({double lat, double lng})> _getCoords() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return (lat: 18.7883, lng: 98.9853);

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return (lat: 18.7883, lng: 98.9853);
      }

      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.low,
          timeLimit: Duration(seconds: 8),
        ),
      );
      return (lat: pos.latitude, lng: pos.longitude);
    } catch (_) {
      return (lat: 18.7883, lng: 98.9853); // Chiang Mai fallback
    }
  }

  /// ดึงข้อมูลคุณภาพอากาศและสภาพอากาศจาก Open-Meteo (ฟรี ไม่ต้อง Key)
  static Future<AirQualityData> fetchAirQuality() async {
    final coords = await _getCoords();
    final lat = coords.lat;
    final lng = coords.lng;

    final aqUri = Uri.parse(
      'https://air-quality-api.open-meteo.com/v1/air-quality'
      '?latitude=$lat&longitude=$lng'
      '&current=pm2_5,pm10,ozone',
    );

    final weatherUri = Uri.parse(
      'https://api.open-meteo.com/v1/forecast'
      '?latitude=$lat&longitude=$lng'
      '&current=temperature_2m,relative_humidity_2m,wind_speed_10m,visibility',
    );

    final results = await Future.wait([
      http.get(aqUri).timeout(const Duration(seconds: 10)),
      http.get(weatherUri).timeout(const Duration(seconds: 10)),
    ]);

    if (results[0].statusCode != 200 || results[1].statusCode != 200) {
      throw Exception(tr('ไม่สามารถดึงข้อมูลได้', 'Unable to fetch data'));
    }

    final aqCurrent = json.decode(results[0].body)['current'] as Map<String, dynamic>;
    final wCurrent = json.decode(results[1].body)['current'] as Map<String, dynamic>;

    final pm25 = (aqCurrent['pm2_5'] ?? 0).toDouble();
    final pm10 = (aqCurrent['pm10'] ?? 0).toDouble();
    final ozone = (aqCurrent['ozone'] ?? 0).toDouble();
    final temp = (wCurrent['temperature_2m'] ?? 0).toDouble();
    final humidity = (wCurrent['relative_humidity_2m'] ?? 0).toDouble();
    final wind = (wCurrent['wind_speed_10m'] ?? 0).toDouble();
    final visM = (wCurrent['visibility'] ?? 0).toDouble();

    final aqi = calculateAQI(pm25);

    return AirQualityData(
      pm25: pm25,
      pm10: pm10,
      ozone: ozone,
      temperature: temp,
      humidity: humidity,
      windSpeedKmh: wind,
      visibilityKm: visM / 1000,
      aqi: aqi,
      aqiLabel: aqiLabel(aqi),
      latitude: lat,
      longitude: lng,
      fetchedAt: DateTime.now(),
    );
  }
}
