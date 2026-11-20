import 'package:flutter/services.dart';

/// Settings-only bridge. Does not start or claim to start a VPN tunnel.
class AndroidAppRoutes {
  static const MethodChannel _channel = MethodChannel('shop.pushok.flow/app_routes');

  static Future<List<InstalledApp>> installedApps() async {
    final raw = await _channel.invokeListMethod<Map<dynamic, dynamic>>('installedApps');
    return (raw ?? []).map((item) => InstalledApp(
      packageName: item['packageName'] as String,
      label: item['label'] as String,
    )).toList()..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
  }

  static Future<Set<String>> getBypass() async =>
      (await _channel.invokeListMethod<String>('getBypass') ?? []).toSet();

  static Future<void> setBypass(Set<String> packageNames) =>
      _channel.invokeMethod<void>('setBypass', {'packages': packageNames.toList()});
}

class InstalledApp {
  const InstalledApp({required this.packageName, required this.label});
  final String packageName;
  final String label;
}
