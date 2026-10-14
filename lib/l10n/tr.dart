import '../providers/language_provider.dart';

/// เลือกข้อความตามภาษาปัจจุบันของแอป (ไทย/อังกฤษ)
///
/// ใช้กับข้อความที่ไม่ได้อยู่ใน [AppStrings] เช่น ใน service, model และหน้าจอผู้ดูแลระบบ
/// วิดเจ็ตที่เรียกต้อง rebuild เมื่อเปลี่ยนภาษา (`context.watch<LanguageProvider>()`)
String tr(String th, String en) => LanguageProvider.isThaiNow ? th : en;
