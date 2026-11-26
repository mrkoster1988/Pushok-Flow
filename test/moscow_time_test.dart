import 'package:flutter_test/flutter_test.dart';
import 'package:pushok_flow/models/moscow_time.dart';

void main() {
  test('Moscow midnight moves the date without moving the expiry instant', () {
    final instant = DateTime.parse('2027-01-01T05:05:00+08:00');
    expect(formatMoscowDate(instant), '01.01.2027');
    expect(formatMoscowDate(instant.toLocal(), includeTime: true), '01.01.2027, 00:05 МСК');
  });
}
