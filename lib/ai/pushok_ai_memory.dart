import 'package:flutter/services.dart';

/// Bounded, on-device feedback. No packet contents or destination addresses.
class PushokAiMemory {
  static const _channel = MethodChannel('shop.pushok.flow/app_routes');

  static Future<Map<String, int>> summary() async {
    final result = await _channel.invokeMapMethod<String, dynamic>('aiFeedbackSummary');
    return result?.map((key, value) => MapEntry(key, (value as num).toInt())) ?? {};
  }

  static Future<Map<String, int>> record({
    required String category,
    required bool helpful,
  }) async {
    if (!const {'connection', 'routing', 'server'}.contains(category)) {
      throw ArgumentError.value(category, 'category');
    }
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'aiFeedbackRecord', {'category': category, 'helpful': helpful});
    return result?.map((key, value) => MapEntry(key, (value as num).toInt())) ?? {};
  }

  static Future<void> clear() async => _channel.invokeMethod('aiFeedbackClear');
}
