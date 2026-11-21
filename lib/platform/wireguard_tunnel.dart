import 'package:flutter/services.dart';

import 'tunnel_diagnostics.dart';

class WireGuardTunnel {
  static const _channel = MethodChannel('shop.pushok.flow/app_routes');

  static Future<bool> get connected async {
    final state = await _channel.invokeMapMethod<String, dynamic>('vpnStatus');
    return state?['connected'] == true;
  }

  static Future<bool> connect(String config) async {
    final state = await _channel.invokeMapMethod<String, dynamic>(
      'connectWireGuard', {'config': config});
    return state?['connected'] == true;
  }

  static Future<void> saveProfile(String config) async {
    await _channel.invokeMethod('saveWireGuardProfile', {'config': config});
  }

  static Future<String?> loadProfile() =>
      _channel.invokeMethod<String>('loadWireGuardProfile');

  /// Reads one explicitly selected file into a draft; does not save or connect.
  static Future<String?> importProfile() =>
      _channel.invokeMethod<String>('importWireGuardProfile');

  static Future<void> cancelProfileImport() async {
    await _channel.invokeMethod('cancelWireGuardProfileImport');
  }

  static Future<void> deleteProfile() async {
    await _channel.invokeMethod('deleteWireGuardProfile');
  }

  static Future<bool> get savedProfileExists async =>
      await _channel.invokeMethod<bool>('savedProfileExists') ?? false;

  static Future<TunnelDiagnostics> diagnostics() async =>
      TunnelDiagnostics.fromPlatform(await _channel.invokeMethod<Object?>('vpnStatus'));

  static Future<void> disconnect() async {
    await _channel.invokeMethod('disconnectWireGuard');
  }
}
