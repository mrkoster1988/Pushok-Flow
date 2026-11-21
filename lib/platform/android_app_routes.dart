import 'package:flutter/services.dart';

/// Settings-only bridge. Does not start or claim to start a VPN tunnel.
class AndroidAppRoutes {
  static const MethodChannel _channel = MethodChannel('shop.pushok.flow/app_routes');
  static const maxPackages = 4096;
  static const maxPackageLength = 255;
  static const maxLabelLength = 1024;
  static final _packagePattern = RegExp(r'^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)+$');

  static bool _validPackage(Object? value) => value is String &&
      value.length <= maxPackageLength && _packagePattern.stringMatch(value) == value;

  static bool _validLabel(Object? value) {
    if (value is! String || value.isEmpty || value != value.trim()) return false;
    final points = value.runes;
    return points.length <= maxLabelLength && !points.any((point) =>
        point <= 0x1f || (point >= 0x7f && point <= 0x9f) ||
        point == 0x2028 || point == 0x2029 ||
        (point >= 0xd800 && point <= 0xdfff));
  }

  static List<String> _packageList(Object? raw) {
    if (raw is! List || raw.length > maxPackages) {
      throw const FormatException('Invalid Android route list.');
    }
    final packages = <String>{};
    for (final value in raw) {
      if (!_validPackage(value) || !packages.add(value as String)) {
        throw const FormatException('Invalid Android route list.');
      }
    }
    return packages.toList()..sort();
  }

  static Future<List<InstalledApp>> installedApps() async {
    final raw = await _channel.invokeMethod<Object?>('installedApps');
    if (raw is! List || raw.length > maxPackages) {
      throw const FormatException('Invalid Android application list.');
    }
    final apps = <InstalledApp>[];
    final packages = <String>{};
    for (final item in raw) {
      if (item is! Map || item.length != 2 ||
          !item.containsKey('packageName') || !item.containsKey('label') ||
          !_validPackage(item['packageName']) || !_validLabel(item['label']) ||
          !packages.add(item['packageName'] as String)) {
        throw const FormatException('Invalid Android application list.');
      }
      apps.add(InstalledApp(packageName: item['packageName'] as String,
        label: item['label'] as String));
    }
    apps.sort(InstalledApp.compare);
    return List.unmodifiable(apps);
  }

  static Future<Set<String>> getBypass() async => Set.unmodifiable(
      _packageList(await _channel.invokeMethod<Object?>('getBypass')));

  /// expectedPackages makes the write conditional on the last confirmed list.
  /// Older callers may omit it; this does not start or reconnect the tunnel.
  static Future<void> setBypass(Set<String> packageNames, {
    Set<String>? expectedPackages,
  }) async {
    final packages = _packageList(packageNames.toList());
    final expected = expectedPackages == null
        ? null : _packageList(expectedPackages.toList());
    await _channel.invokeMethod<void>('setBypass', {
      'packages': packages,
      if (expected != null) 'expectedPackages': expected,
    });
  }
}

class InstalledApp {
  const InstalledApp({required this.packageName, required this.label});
  final String packageName;
  final String label;

  static int compare(InstalledApp first, InstalledApp second) {
    final byName = first.label.toLowerCase().compareTo(second.label.toLowerCase());
    return byName == 0 ? first.packageName.compareTo(second.packageName) : byName;
  }
}
