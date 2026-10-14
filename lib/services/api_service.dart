import 'dart:convert';
import 'package:http/http.dart' as http;
import 'air_quality_service.dart';
import 'safety_score_engine.dart';
import 'road_context_service.dart';
import '../l10n/tr.dart';

class ApiService {
  // ใช้ Open-Meteo API (ฟรี ไม่ต้อง backend / API key)
  static const String _weatherUrl = 'https://api.open-meteo.com/v1/forecast';
  static const String _aqiUrl = 'https://air-quality-api.open-meteo.com/v1/air-quality';

  // ─── UC-10/11 A1: แคชข้อมูลล่าสุดที่ดึงสำเร็จ ───────────────────
  static const Duration cacheMaxAge = Duration(hours: 1);
  static ({DateTime at, dynamic json})? _weatherCache;
  static ({DateTime at, dynamic json})? _aqiCache;

  /// สำหรับทดสอบ: ล้างแคช
  static void debugClearCache() {
    _weatherCache = null;
    _aqiCache = null;
  }

  static dynamic _freshCache(({DateTime at, dynamic json})? c) =>
      (c != null && DateTime.now().difference(c.at) <= cacheMaxAge) ? c.json : null;

  /// ดึง JSON จาก [uri] — ล้มเหลว/ช้าเกิน 8 วินาทีคืน null
  static Future<dynamic> _getJson(Uri uri) async {
    try {
      final res = await http.get(uri).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      return json.decode(res.body);
    } catch (_) {
      return null;
    }
  }

  /// (เดิม) การหักคะแนนจากสภาพรถติด — คงไว้เพื่อความเข้ากันได้ของ test เดิม
  /// คะแนนจริงใช้ [SafetyScoreEngine.trafficScore]
  static int trafficDeduction(double congestionPct) {
    if (congestionPct > 30) return 10;
    if (congestionPct > 10) return 5;
    return 0;
  }

  /// คำนวณการหักคะแนนจากจำนวนแยกสัญญาณไฟ (0–10 คะแนน)
  static int trafficLightDeduction(int lightCount) {
    if (lightCount >= 4) return 10;
    if (lightCount >= 2) return 5;
    return 0;
  }

  /// ดึง Safety Score + สภาพอากาศ + ค่าฝุ่น PM2.5 จาก Open-Meteo
  /// แล้วคำนวณคะแนนด้วย [SafetyScoreEngine] (SAW — สมการที่ 3.1 และ 3.2)
  ///
  /// [trafficCongestionPct] = % ของเส้นทางที่รถติด (0–100)
  /// [trafficLightCount]    = จำนวนแยกสัญญาณไฟจราจรตลอดเส้นทาง
  /// [activeIncidentCount]  = จำนวนรายงานเหตุการณ์ที่ยังไม่หมดอายุบนเส้นทาง
  static Future<Map<String, dynamic>> getPreRunSimulation(
    double lat,
    double lng, {
    double trafficCongestionPct = 0,
    int trafficLightCount = 0,
    int activeIncidentCount = 0,
    RoadContext? road,
    List<({double lat, double lng})> airSamplePoints = const [],
  }) async {
    try {
      // คุณภาพอากาศ: ถ้ามีจุดตัวอย่างตามเส้นทาง (ต้น/กลาง/ปลาย) ขอทีเดียวหลายพิกัด แล้วใช้ค่าที่แย่ที่สุด
      final aqPts = airSamplePoints.isNotEmpty ? airSamplePoints : [(lat: lat, lng: lng)];
      final aqLats = aqPts.map((p) => p.lat.toStringAsFixed(4)).join(',');
      final aqLngs = aqPts.map((p) => p.lng.toStringAsFixed(4)).join(',');
      // UC-10 + UC-11: เรียก 2 API พร้อมกัน
      final results = await Future.wait([
        _getJson(Uri.parse(
          '$_weatherUrl?latitude=$lat&longitude=$lng'
          '&current=temperature_2m,wind_speed_10m,relative_humidity_2m,precipitation'
          '&wind_speed_unit=kmh&timezone=Asia/Bangkok',
        )),
        _getJson(Uri.parse(
          '$_aqiUrl?latitude=$aqLats&longitude=$aqLngs'
          '&current=pm2_5,us_aqi&timezone=Asia/Bangkok',
        )),
      ]);

      // UC-10/11 A1: บริการใดล้มเหลว → ใช้ข้อมูลล่าสุดที่แคชไว้ (ไม่เกิน 1 ชม.)
      // UC-14 A1: ถ้ายังไม่มีข้อมูลบางตัวแปร → คำนวณจากตัวแปรที่มี และระบุว่าเป็นค่าประมาณ
      // UC-14 E1: ไม่ได้ข้อมูลจากแหล่งภายนอกเลย → แจ้งว่าคำนวณไม่ได้
      var weatherJson = results[0];
      var aqiJson = results[1];
      final usedCache = <String>[];
      final missing = <String>[];
      if (weatherJson != null) {
        _weatherCache = (at: DateTime.now(), json: weatherJson);
      } else if ((weatherJson = _freshCache(_weatherCache)) != null) {
        usedCache.add('weather');
      } else {
        missing.add('weather');
      }
      if (aqiJson != null) {
        _aqiCache = (at: DateTime.now(), json: aqiJson);
      } else if ((aqiJson = _freshCache(_aqiCache)) != null) {
        usedCache.add('airQuality');
      } else {
        missing.add('airQuality');
      }
      if (weatherJson == null && aqiJson == null) {
        throw Exception('API error: weather and air quality services unavailable');
      }

      final wCur = (weatherJson is Map && weatherJson['current'] is Map)
          ? weatherJson['current'] as Map
          : const {};
      final temp = (wCur['temperature_2m'] as num?)?.toDouble() ?? 30.0;
      final wind = (wCur['wind_speed_10m'] as num?)?.toDouble() ?? 0.0;
      final humidity = (wCur['relative_humidity_2m'] as num?)?.toDouble() ?? 0.0;
      final rain = (wCur['precipitation'] as num?)?.toDouble() ?? 0.0;
      // หลายพิกัด → Open-Meteo ตอบเป็น list
      final aqList = aqiJson is List ? aqiJson : (aqiJson == null ? const [] : [aqiJson]);
      double pm25 = 0.0;
      int? aqiMax;
      for (final item in aqList) {
        final cur = (item is Map) ? item['current'] : null;
        if (cur is! Map) continue;
        final p = (cur['pm2_5'] as num?)?.toDouble() ?? 0.0;
        if (p > pm25) pm25 = p;
        final a = (cur['us_aqi'] as num?)?.toInt();
        if (a != null && (aqiMax == null || a > aqiMax)) aqiMax = a;
      }
      // ไม่มีข้อมูลฝุ่น → ใช้ AQI 50 (ระดับดี) เป็นค่ากลาง แล้วระบุว่าคะแนนเป็นค่าประมาณ
      final aqi = missing.contains('airQuality')
          ? 50
          : (aqiMax ?? AirQualityService.calculateAQI(pm25));

      // UC-14: คำนวณคะแนนความปลอดภัย (SAW)
      final result = SafetyScoreEngine.calculateSafetyScore(
        aqi: aqi,
        temperatureC: temp,
        precipitationMm: rain,
        humidityPct: humidity,
        windKmh: wind,
        congestionPct: trafficCongestionPct,
        trafficLightCount: road?.trafficSignals ?? trafficLightCount,
        activeIncidentCount: activeIncidentCount,
        majorRoadShare: road?.majorRoadShare ?? 0,
        protectedShare: road?.protectedShare ?? 0,
        litShare: road?.litShare,
      );

      // ข้อความเตือนปัจจัยเสี่ยง (UC-13)
      final alerts = <String>[];
      if (pm25 > 75) {
        alerts.add(tr('⚠️ ฝุ่น PM2.5 สูงมาก (${pm25.toStringAsFixed(1)} μg/m³) — ไม่เหมาะออกกำลังกายกลางแจ้ง', '⚠️ Very high PM2.5 (${pm25.toStringAsFixed(1)} μg/m³) — not suitable for outdoor exercise'));
      } else if (pm25 > 35) {
        alerts.add(tr('🟡 ฝุ่น PM2.5 ปานกลาง (${pm25.toStringAsFixed(1)} μg/m³) — ควรใส่หน้ากาก', '🟡 Moderate PM2.5 (${pm25.toStringAsFixed(1)} μg/m³) — consider a mask'));
      }
      if (temp > 38) {
        alerts.add(tr('🌡️ อากาศร้อนมาก ($temp°C) — เสี่ยงเป็นลมแดด', '🌡️ Very hot ($temp°C) — heatstroke risk'));
      } else if (temp > 33) {
        alerts.add(tr('☀️ อากาศค่อนข้างร้อน ($temp°C) — ดื่มน้ำบ่อยๆ', '☀️ Quite hot ($temp°C) — drink water often'));
      }
      if (rain > 0.5) {
        alerts.add(tr('🌧️ มีฝนตก (${rain.toStringAsFixed(1)} มม.) — ระวังทางลื่น', '🌧️ Raining (${rain.toStringAsFixed(1)} mm) — watch for slippery paths'));
      }
      if (wind > 40) {
        alerts.add(tr('💨 ลมแรง (${wind.toStringAsFixed(0)} km/h) — ระวังการทรงตัว', '💨 Strong wind (${wind.toStringAsFixed(0)} km/h) — keep your balance'));
      }
      if (SafetyScoreEngine.isNight()) {
        final cut = ((1 - result.timeFactor) * 100).round();
        final litShare = road?.litShare;
        alerts.add(litShare != null
            ? tr('🌙 ช่วงกลางคืน — ไฟส่องสว่าง ${(litShare * 100).round()}% ของเส้นทาง ปรับลดคะแนน $cut%',
                '🌙 Night time — ${(litShare * 100).round()}% of route is lit, score reduced $cut%')
            : tr('🌙 ช่วงกลางคืน — ปรับลดคะแนน $cut% เพราะทัศนวิสัยต่ำ', '🌙 Night time — score reduced $cut% for low visibility'));
      }
      if (road != null && road.majorRoadShare >= 0.3) {
        alerts.add(tr('🛣️ ${(road.majorRoadShare * 100).round()}% ของเส้นทางอยู่บนถนนสายหลัก — รถเร็ว/หนาแน่น',
            '🛣️ ${(road.majorRoadShare * 100).round()}% of route is on main roads — fast/heavy traffic'));
      }
      if (trafficCongestionPct > 10) {
        alerts.add(tr('🚗 มีรถหนาแน่น (${trafficCongestionPct.toStringAsFixed(0)}% ของเส้นทาง) — ระวังไอเสีย', '🚗 Heavy traffic (${trafficCongestionPct.toStringAsFixed(0)}% of route) — watch for exhaust'));
      }
      final lights = road?.trafficSignals ?? trafficLightCount;
      if (lights >= 2) {
        alerts.add(tr('🚦 ผ่านแยกสัญญาณไฟ $lights จุด — ระวังรถเลี้ยวและทางข้าม', '🚦 Passes $lights traffic lights — watch turning cars and crossings'));
      }
      if (activeIncidentCount > 0) {
        alerts.add(tr('📍 มีรายงานเหตุการณ์บนเส้นทาง $activeIncidentCount รายการ', '📍 $activeIncidentCount incident report(s) on this route'));
      }
      if (missing.isNotEmpty) {
        final names = missing
            .map((m) => m == 'weather' ? tr('สภาพอากาศ', 'weather') : tr('คุณภาพอากาศ', 'air quality'))
            .join(', ');
        alerts.add(tr('ℹ️ คะแนนเป็นค่าประมาณ — ไม่สามารถดึงข้อมูล$names ได้ในขณะนี้',
            'ℹ️ Estimated score — $names data is unavailable right now'));
      } else if (usedCache.isNotEmpty) {
        alerts.add(tr('ℹ️ บริการข้อมูลภายนอกไม่ตอบสนอง — ใช้ข้อมูลล่าสุดที่บันทึกไว้ (ไม่เกิน 1 ชั่วโมง)',
            'ℹ️ External service not responding — using the latest saved data (≤ 1 hour old)'));
      }
      if (result.level == SafetyLevel.highRisk) {
        alerts.insert(0, tr('⛔ คะแนนความปลอดภัยต่ำกว่า ${SafetyScoreEngine.cautionThreshold} — เส้นทางมีความเสี่ยงสูง', '⛔ Safety score below ${SafetyScoreEngine.cautionThreshold} — high-risk route'));
      }

      return {
        'safety': {
          'score': result.score,
          'level': result.level.name,
          'alerts': alerts,
          'components': result.toMap(),
          'isEstimate': missing.isNotEmpty,
          'missing': missing,
          'usedCache': usedCache,
        },
        'weather': {
          'temperature': temp.toStringAsFixed(1),
          'windspeed': wind.toStringAsFixed(0),
          'humidity': humidity.toStringAsFixed(0),
          'precipitation': rain.toStringAsFixed(1),
        },
        'airQuality': {
          'pm2_5': pm25.toStringAsFixed(1),
          'us_aqi': aqi,
        },
        'traffic': {
          'congestionPct': trafficCongestionPct,
          'lightCount': lights,
        },
        if (road != null) 'road': road.toMap(),
        'incidents': {
          'activeCount': activeIncidentCount,
        },
      };
    } catch (e) {
      throw Exception(tr('ไม่สามารถดึงข้อมูลได้: $e', 'Unable to fetch data: $e'));
    }
  }

  /// Fetch active hazard reports (ยังใช้ backend — ถ้าไม่มีจะ return list ว่าง)
  static Future<List<dynamic>> getActiveReports() async {
    return [];
  }
}
