import 'package:flutter/material.dart';

/// ฟังก์ชันระดับความยากของเส้นทาง (ใช้ร่วมกันหลายหน้าจอ และทดสอบใน UT-17 ถึง UT-23)

/// คืนค่าสีตามระดับความยาก: easy = เขียว, moderate = ส้ม/เหลือง, hard = แดง, อื่น ๆ = ขาว
Color getDifficultyColor(String difficulty) {
  switch (difficulty) {
    case 'easy':
      return const Color(0xFF2ECC71);
    case 'moderate':
      return const Color(0xFFF39C12);
    case 'hard':
      return const Color(0xFFE74C3C);
    default:
      return Colors.white;
  }
}

/// คืนข้อความระดับความยาก (ค่าเริ่มต้นภาษาไทย)
String getDifficultyLabel(String difficulty, {bool thai = true}) {
  switch (difficulty) {
    case 'easy':
      return thai ? 'ง่าย' : 'Easy';
    case 'moderate':
      return thai ? 'ปานกลาง' : 'Moderate';
    case 'hard':
      return thai ? 'ยาก' : 'Hard';
    default:
      return difficulty;
  }
}

/// เกณฑ์ความสูงสะสม (เมตร)
const int easyMaxElevationGainM = 30; // < 30 m = ง่าย
const int moderateMaxElevationGainM = 200; // 30–199 m = ปานกลาง, ≥ 200 m = ยาก

/// จำแนกระดับความยากจากค่าความสูงสะสม (Elevation Gain)
String classifyDifficultyFromElevation(num elevationGainM) {
  if (elevationGainM < easyMaxElevationGainM) return 'easy';
  if (elevationGainM < moderateMaxElevationGainM) return 'moderate';
  return 'hard';
}
