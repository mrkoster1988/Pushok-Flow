/// Civil labels for Pushok service events (all issued after Moscow adopted UTC+3).
/// Keep the original instant for comparisons, durations and API calls.
String formatMoscowDate(DateTime instant, {bool includeTime = false}) {
  final clock = instant.toUtc().add(const Duration(hours: 3));
  String two(int number) => number.toString().padLeft(2, '0');
  final day = '${two(clock.day)}.${two(clock.month)}.${clock.year}';
  return includeTime ? '$day, ${two(clock.hour)}:${two(clock.minute)} МСК' : day;
}
