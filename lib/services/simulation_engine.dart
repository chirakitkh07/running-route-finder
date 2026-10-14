import '../utils/difficulty_utils.dart';

/// ผลการจำลองการออกกำลังกายล่วงหน้า (UC-04)
class SimulationResult {
  final double distanceKm;
  final double elevationGainM;
  final double paceMinPerKm;
  final int durationMinutes;
  final int calories;
  final String difficulty;

  const SimulationResult({
    required this.distanceKm,
    required this.elevationGainM,
    required this.paceMinPerKm,
    required this.durationMinutes,
    required this.calories,
    required this.difficulty,
  });

  String get durationLabel {
    final h = durationMinutes ~/ 60;
    final m = durationMinutes % 60;
    return h > 0 ? '${h}h ${m}m' : '${m}m';
  }

  Map<String, dynamic> toMap() => {
        'distanceKm': double.parse(distanceKm.toStringAsFixed(2)),
        'elevationGainM': elevationGainM.round(),
        'paceMinPerKm': paceMinPerKm,
        'durationMinutes': durationMinutes,
        'calories': calories,
        'difficulty': difficulty,
      };
}

/// SimulationEngine — จำลองการออกกำลังกายล่วงหน้า (Pre-Run Simulation)
///
/// - ระยะเวลา = ระยะทาง × จังหวะเฉลี่ย (นาที/กม.) + เวลาเพิ่มจากความสูงสะสม
/// - แคลอรี = ระยะทาง × อัตราเผาผลาญต่อกิโลเมตร (+ ส่วนเพิ่มจากการขึ้นเนิน)
/// - ระดับความยาก = จำแนกจากความสูงสะสม
class SimulationEngine {
  /// จังหวะเฉลี่ยเริ่มต้น (ผู้ใช้ปรับเองได้ — UC-04 A1)
  static const double defaultRunPaceMinPerKm = 6.0; // ~10 กม./ชม.
  static const double defaultCyclePaceMinPerKm = 3.0; // ~20 กม./ชม.

  /// อัตราเผาผลาญโดยประมาณ (kcal/กม.) — ใช้ค่าเดียวกับหน้าบันทึกการวิ่ง
  static const double runKcalPerKm = 65;
  static const double cycleKcalPerKm = 35;

  static double defaultPace(String activityType) =>
      activityType == 'cycling' ? defaultCyclePaceMinPerKm : defaultRunPaceMinPerKm;

  /// ประมาณระยะเวลา (นาที)
  /// เพิ่มเวลา 1 นาทีต่อการขึ้นเนิน 10 เมตร (วิ่ง) หรือ 0.5 นาที (ปั่นจักรยาน)
  static int estimateDurationMinutes(
    double distanceKm, {
    double? paceMinPerKm,
    double elevationGainM = 0,
    String activityType = 'running',
  }) {
    if (distanceKm <= 0) return 0;
    final pace = (paceMinPerKm != null && paceMinPerKm > 0)
        ? paceMinPerKm
        : defaultPace(activityType);
    final climbPer10m = activityType == 'cycling' ? 0.5 : 1.0;
    final minutes = distanceKm * pace + (elevationGainM / 10.0) * climbPer10m;
    return minutes.round();
  }

  /// ประมาณแคลอรีที่เผาผลาญ (kcal)
  static int estimateCalories(
    double distanceKm, {
    double elevationGainM = 0,
    String activityType = 'running',
  }) {
    if (distanceKm <= 0) return 0;
    final perKm = activityType == 'cycling' ? cycleKcalPerKm : runKcalPerKm;
    final climbBonus = elevationGainM * 0.5; // ~0.5 kcal ต่อการขึ้น 1 เมตร
    return (distanceKm * perKm + climbBonus).round();
  }

  /// runSimulation() — รวมผลการจำลองทั้งหมด
  static SimulationResult runSimulation({
    required double distanceKm,
    double elevationGainM = 0,
    double? paceMinPerKm,
    String activityType = 'running',
  }) {
    final pace = (paceMinPerKm != null && paceMinPerKm > 0)
        ? paceMinPerKm
        : defaultPace(activityType);
    return SimulationResult(
      distanceKm: distanceKm,
      elevationGainM: elevationGainM,
      paceMinPerKm: pace,
      durationMinutes: estimateDurationMinutes(distanceKm,
          paceMinPerKm: pace, elevationGainM: elevationGainM, activityType: activityType),
      calories: estimateCalories(distanceKm,
          elevationGainM: elevationGainM, activityType: activityType),
      difficulty: classifyDifficultyFromElevation(elevationGainM),
    );
  }

  /// calculateElevationProfile() — คำนวณความสูงสะสมขึ้น/ลงจากรายการความสูง
  static ({double gain, double loss}) calculateElevationProfile(List<double> elevations) {
    double gain = 0, loss = 0;
    for (int i = 1; i < elevations.length; i++) {
      final diff = elevations[i] - elevations[i - 1];
      if (diff > 0) {
        gain += diff;
      } else {
        loss += diff.abs();
      }
    }
    return (gain: gain, loss: loss);
  }
}
