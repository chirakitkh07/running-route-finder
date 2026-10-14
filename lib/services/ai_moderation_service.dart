import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import '../l10n/tr.dart';

/// ผลลัพธ์จาก AI Moderation
class ModerationResult {
  /// ผ่านการตรวจสอบหรือไม่
  final bool isValid;

  /// เหตุผลที่ไม่ผ่าน (ถ้ามี)
  final String reason;

  /// ข้อความแจ้งเตือนต่อผู้ใช้ (ภาษาไทย)
  final String userMessage;

  /// เกิดจาก API error หรือไม่ (ใช้แยก fail-safe vs rejected จริง)
  final bool isApiError;

  /// คะแนนความเชื่อมั่นของผลการตัดสินจาก AI (0–1) — UC-09 / UC-15
  final double confidence;

  /// เกณฑ์ความเชื่อมั่น: ผ่านแต่ต่ำกว่าค่านี้ → ส่งให้ผู้ดูแลตรวจสอบก่อนเผยแพร่ (UC-15 A1)
  static const double reviewThreshold = 0.80;

  const ModerationResult({
    required this.isValid,
    this.reason = '',
    this.userMessage = '',
    this.isApiError = false,
    this.confidence = 0.0,
  });

  /// ผ่านแต่ความเชื่อมั่นระดับปานกลาง หรือ AI ไม่ตอบสนอง → เก็บเป็น 'pending'
  bool get needsAdminReview =>
      isApiError || (isValid && confidence < reviewThreshold);

  /// ผ่านการตรวจสอบปกติ
  factory ModerationResult.passed({double confidence = 1.0, String reason = ''}) =>
      ModerationResult(isValid: true, confidence: confidence, reason: reason);

  /// ไม่ผ่าน — เนื้อหาไม่เหมาะสม
  factory ModerationResult.rejected(String reason, String userMessage,
          {double confidence = 1.0}) =>
      ModerationResult(
        isValid: false,
        reason: reason,
        userMessage: userMessage,
        confidence: confidence,
      );

  /// API พัง → UC-15 E2: เก็บรายงานไว้ในสถานะรอตรวจสอบชั่วคราว (pending)
  factory ModerationResult.apiError(String detail) => ModerationResult(
        isValid: false,
        reason: 'API Error: $detail',
        userMessage:
            tr('ระบบตรวจสอบเนื้อหาไม่ตอบสนอง รายงานของคุณถูกเก็บไว้ในสถานะรอตรวจสอบ และจะแสดงบนแผนที่เมื่อผู้ดูแลระบบอนุมัติ', 'The moderation service did not respond. Your report is pending and will appear on the map once an admin approves it'),
        isApiError: true,
        confidence: 0.0,
      );
}

/// UC-05 E1: AI Moderation Service
/// ใช้ Gemini REST API ตรวจสอบความถูกต้องของรายงานเหตุการณ์ก่อนบันทึกลงฐานข้อมูล
class AiModerationService {
  // ─── API Key ─────────────────────────────────────────────────────────────
  // ไม่ฝังคีย์ในโค้ด (repo เป็น public) — ส่งตอน build:
  //   flutter run/build ... --dart-define-from-file=.env.local.json
  // (.env.local.json อยู่ใน .gitignore, มี {"GEMINI_API_KEY": "..."})
  static const String _apiKey = String.fromEnvironment('GEMINI_API_KEY');

  static const String _baseUrl =
      'https://generativelanguage.googleapis.com/v1beta/models';

  /// ลำดับ model ที่จะลอง (fallback ตามลำดับ)
  static const List<String> _modelCandidates = [
    'gemini-3.5-flash',
    'gemini-3.7-flash',
    'gemini-flash-latest',
    'gemini-3.5-flash-lite',
  ];

  /// ตรวจสอบเนื้อหารายงานเหตุการณ์ด้วย Gemini AI
  ///
  /// [incidentType] — ประเภทเหตุการณ์ที่เลือก เช่น 'dogs', 'slippery'
  /// [description] — รายละเอียดที่ผู้ใช้กรอก (อาจว่างได้)
  /// [typeLabelTh] — ชื่อประเภทภาษาไทย เช่น '🐶 สุนัขจรจัด/ดุร้าย'
  ///
  /// คืน [ModerationResult.apiError] ถ้าทุก model ล้มเหลว (fail-safe)
  static Future<ModerationResult> validateReport({
    required String incidentType,
    required String description,
    required String typeLabelTh,
  }) async {
    if (_apiKey.isEmpty || _apiKey == 'YOUR_GEMINI_API_KEY') {
      debugPrint('[AiModeration] ⚠️ API Key ยังไม่ได้ตั้งค่า → fail-safe');
      return ModerationResult.apiError('API Key not configured');
    }

    final prompt = _buildPrompt(
      incidentType: incidentType,
      description: description,
      typeLabelTh: typeLabelTh,
    );

    String? lastError;
    for (final modelName in _modelCandidates) {
      debugPrint('[AiModeration] 🔄 ลอง model: $modelName');
      try {
        // key แบบใหม่ (AQ.) ส่งทาง header x-goog-api-key ตามเอกสาร Google — ห้ามส่งซ้ำใน ?key=
        final url = Uri.parse('$_baseUrl/$modelName:generateContent');

        final body = jsonEncode({
          'contents': [
            {
              'parts': [
                {'text': prompt}
              ]
            }
          ],
          'generationConfig': {
            'temperature': 0.0,
            // model รุ่น thinking ใช้ token คิดก่อนตอบ → 512 ทำให้ JSON ขาด/ว่าง
            'maxOutputTokens': 2048,
            'responseMimeType': 'application/json',
          },
        });

        final response = await http
            .post(
              url,
              headers: {
                'Content-Type': 'application/json',
                'x-goog-api-key': _apiKey,
              },
              body: body,
            )
            .timeout(const Duration(seconds: 15));

        debugPrint('[AiModeration] HTTP ${response.statusCode} ($modelName)');

        if (response.statusCode == 401 || response.statusCode == 403) {
          // key ใช้ไม่ได้/ถูกระงับ — ลอง model อื่นไม่ช่วย
          lastError = 'HTTP ${response.statusCode} (API key ถูกปฏิเสธ): ${response.body}';
          debugPrint('[AiModeration] ❌ $lastError');
          break;
        }

        if (response.statusCode == 404 || response.statusCode == 400) {
          lastError = 'HTTP ${response.statusCode}: ${response.body}';
          debugPrint('[AiModeration] ❌ $lastError');
          continue;
        }

        if (response.statusCode != 200) {
          lastError = 'HTTP ${response.statusCode}: ${response.body}';
          debugPrint('[AiModeration] ❌ $lastError');
          continue;
        }

        // Parse response
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final candidates = json['candidates'] as List<dynamic>?;
        if (candidates == null || candidates.isEmpty) {
          lastError = 'No candidates in response';
          continue;
        }

        final content = candidates[0]['content'] as Map<String, dynamic>?;
        final parts = content?['parts'] as List<dynamic>?;
        // model รุ่น thinking อาจแยกคำตอบเป็นหลาย part (part ความคิดมี thought: true) → รวมเฉพาะคำตอบ
        final text = (parts ?? const [])
            .whereType<Map<String, dynamic>>()
            .where((p) => p['thought'] != true)
            .map((p) => (p['text'] as String?) ?? '')
            .join();
        final finishReason = candidates[0]['finishReason'];
        if (finishReason != null && finishReason != 'STOP') {
          debugPrint('[AiModeration] ⚠️ finishReason=$finishReason ($modelName)');
        }

        debugPrint('[AiModeration] ✅ Model "$modelName" ตอบกลับ: $text');

        if (text.trim().isEmpty) {
          lastError = 'Empty response from $modelName';
          continue;
        }

        return _parseResponse(text);
      } catch (e) {
        lastError = e.toString();
        debugPrint('[AiModeration] ❌ Error ($modelName): $lastError');
        continue;
      }
    }

    debugPrint(
      '[AiModeration] 🚫 ทุก model ล้มเหลว → fail-safe. Last: $lastError',
    );
    return ModerationResult.apiError(lastError ?? 'All models failed');
  }

  /// สร้าง prompt สำหรับส่งให้ Gemini
  static String _buildPrompt({
    required String incidentType,
    required String description,
    required String typeLabelTh,
  }) {
    final desc =
        description.trim().isEmpty ? '(ไม่ได้กรอก)' : description.trim();
    return '''
You are an AI content moderation system for a running/cycling safety app in Chiang Mai, Thailand.
Your job is to check if a user-submitted incident report is appropriate and relevant.

Incident Data:
- Type: $typeLabelTh ($incidentType)
- User Description: "$desc"

Moderation Rules:
1. Content must relate to running/cycling path safety
2. No profanity, inappropriate content, or spam
3. If type is valid but description is empty → PASS (valid=true)
4. If description clearly contradicts the selected type → FAIL (valid=false)
5. No personal data (phone numbers, emails, etc.) → FAIL (valid=false)
6. Promotional content or advertisements → FAIL (valid=false)
7. Threats or harmful content → FAIL (valid=false)

IMPORTANT: Output ONLY a raw JSON object. Do NOT use markdown. Do NOT use code blocks. Do NOT add any text before or after the JSON.

Also give "confidence": a number from 0.0 to 1.0 describing how certain you are of your decision
(whether valid OR invalid) — NOT how detailed the report is.
Confidence calibration:
- A relevant report that matches the selected type (even with a short or empty description) → 0.90–1.00
- A clear violation (profanity, spam, personal data, contradiction) → 0.90–1.00
- Use values below 0.80 ONLY when the content is genuinely ambiguous and a human should check it.

Output format (exactly this, no extra text):
{"valid": true, "confidence": 0.93, "reason": "short reason in English", "user_message": ""}

If valid=false, set user_message to a polite ${tr('Thai', 'English')} explanation.
Example: {"valid": false, "confidence": 0.97, "reason": "contains phone number", "user_message": "กรุณาอย่าใส่ข้อมูลส่วนตัว เช่น เบอร์โทรศัพท์"}
''';

  }

  /// แปลง JSON response จาก Gemini
  static ModerationResult _parseResponse(String text) {
    try {
      final jsonStr = _extractJson(text);
      if (jsonStr == null) {
        debugPrint('[AiModeration] ⚠️ ไม่พบ JSON ใน response');
        return ModerationResult.apiError('Invalid JSON response');
      }

      final Map<String, dynamic> data =
          jsonDecode(jsonStr) as Map<String, dynamic>;

      final isValid = data['valid'] as bool? ?? true;
      final reason = (data['reason'] as String?) ?? '';
      final userMsg = (data['user_message'] as String?) ?? '';
      final rawConfidence = data['confidence'] as num?;
      if (rawConfidence == null) {
        // ไม่มีคะแนนความเชื่อมั่น → ตัดสินไม่ได้ (เดิมใช้ 0.5 ทำให้ pending ทุกครั้งแบบเงียบ ๆ)
        debugPrint('[AiModeration] ⚠️ response ไม่มี confidence: $jsonStr');
        return ModerationResult.apiError('Missing confidence');
      }
      final confidence = rawConfidence.toDouble().clamp(0.0, 1.0).toDouble();

      if (!isValid) {
        debugPrint('[AiModeration] ❌ ไม่ผ่าน: $reason');
        return ModerationResult.rejected(
          reason,
          userMsg.isEmpty
              ? tr('เนื้อหาไม่ผ่านการตรวจสอบ กรุณาแก้ไขและลองใหม่', 'Content did not pass moderation. Please edit and try again')
              : userMsg,
          confidence: confidence,
        );
      }

      debugPrint('[AiModeration] ✅ ผ่าน: $reason');
      return ModerationResult.passed(confidence: confidence, reason: reason);
    } catch (e) {
      debugPrint('[AiModeration] ⚠️ Parse error: $e');
      return ModerationResult.apiError('Parse error: $e');
    }
  }

  /// ดึง JSON string จากข้อความ (รองรับ markdown code block)
  static String? _extractJson(String text) {
    final trimmed = text.trim();
    if (trimmed.startsWith('{') && trimmed.endsWith('}')) return trimmed;

    final codeBlock = RegExp(
      r'```(?:json)?\s*([\s\S]*?)\s*```',
    ).firstMatch(trimmed);
    if (codeBlock != null) return codeBlock.group(1)?.trim();

    final jsonBlock = RegExp(r'\{[\s\S]*\}').firstMatch(trimmed);
    if (jsonBlock != null) return jsonBlock.group(0);

    return null;
  }
}


