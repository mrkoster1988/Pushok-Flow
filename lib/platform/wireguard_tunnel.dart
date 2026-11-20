import 'package:flutter/services.dart';

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

  static Future<void> deleteProfile() async {
    await _channel.invokeMethod('deleteWireGuardProfile');
  }

  static Future<bool> get savedProfileExists async =>
      await _channel.invokeMethod<bool>('savedProfileExists') ?? false;

  static Future<Map<dynamic, dynamic>> diagnostics() async =>
      await _channel.invokeMethod<Map<dynamic, dynamic>>('vpnStatus') ?? {};

  static Future<void> disconnect() async {
    await _channel.invokeMethod('disconnectWireGuard');
  }
}
