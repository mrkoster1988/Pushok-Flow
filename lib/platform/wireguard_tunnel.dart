import 'package:flutter/services.dart';

import 'tunnel_diagnostics.dart';
import 'wireguard_profiles.dart';
import 'profile_import.dart';

class WireGuardTunnel {
  static const _channel = MethodChannel('shop.pushok.flow/app_routes');

  static Future<bool> get connected async {
    final state = await _channel.invokeMapMethod<String, dynamic>('vpnStatus');
    return state?['connected'] == true;
  }

  static Future<bool> connect(String config, {String? expectedProfileId}) async {
    final state = await _channel.invokeMapMethod<String, dynamic>(
      'connectWireGuard', {'config': config,
        if (expectedProfileId != null) 'expectedProfileId': expectedProfileId});
    return state?['connected'] == true;
  }

  /// Native preflight refreshes the lease before loading keys or opening Android consent.
  static Future<bool> connectManaged(String profileId) async {
    final state = await _channel.invokeMapMethod<String, dynamic>(
      'connectWireGuard', {'expectedProfileId': profileId});
    return state?['connected'] == true;
  }

  static Future<void> saveProfile(String config, {
    String? profileId,
    String? name,
    bool createNew = false,
  }) async {
    await _channel.invokeMethod('saveWireGuardProfile', {
      'config': config,
      if (profileId != null) 'profileId': profileId,
      if (name != null) 'name': name,
      if (createNew) 'createNew': true,
    });
  }

  static Future<String?> loadProfile({String? profileId}) =>
      _channel.invokeMethod<String>('loadWireGuardProfile',
          profileId == null ? null : {'profileId': profileId});

  static Future<WireGuardProfiles> listProfiles() async =>
      WireGuardProfiles.fromPlatform(
          await _channel.invokeMethod<Object?>('listWireGuardProfiles'));

  static Future<void> selectProfile(String profileId) async {
    await _channel.invokeMethod('selectWireGuardProfile', {'profileId': profileId});
  }

  /// Reads an explicit file into a draft; subscription URLs require confirmation.
  static Future<String?> importProfile() => _import('importWireGuardProfile');

  /// Scans a QR locally into a protected draft; does not save or connect.
  static Future<String?> scanProfileQr() => _import('scanWireGuardProfileQr');

  /// Reads a QR from one explicitly selected image without opening the camera.
  static Future<String?> importProfileQrImage() => _import('importWireGuardProfileQrImage');

  static Future<String?> _import(String method) async => ProfileImportPayload.read(
      await _channel.invokeMethod<Object?>(method));

  static Future<void> cancelProfileImport() async {
    await _channel.invokeMethod('cancelWireGuardProfileImport');
  }

  static Future<void> deleteProfile({String? profileId}) async {
    await _channel.invokeMethod('deleteWireGuardProfile',
        profileId == null ? null : {'profileId': profileId});
  }

  static Future<bool> get savedProfileExists async =>
      await _channel.invokeMethod<bool>('savedProfileExists') ?? false;

  static Future<TunnelDiagnostics> diagnostics() async =>
      TunnelDiagnostics.fromPlatform(await _channel.invokeMethod<Object?>('vpnStatus'));

  static Future<void> disconnect() async {
    await _channel.invokeMethod('disconnectWireGuard');
  }
}
