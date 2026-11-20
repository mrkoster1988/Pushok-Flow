import 'dart:io';

import 'package:flutter/services.dart';

enum UpdatePhase {
  idle,
  checking,
  available,
  current,
  downloading,
  ready,
  error,
  unavailable,
}

/// Only codes cross into the presentation layer; native exception details and
/// remote release metadata are never used as user-facing error messages.
const _knownErrorCodes = <String>{
  'UPDATE_BUSY',
  'UPDATE_NETWORK_ERROR',
  'UPDATE_METADATA_INVALID',
  'UPDATE_INCOMPATIBLE',
  'UPDATE_SIGNATURE_MISMATCH',
  'UPDATE_DOWNLOAD_FAILED',
  'UPDATE_CHECKSUM_MISMATCH',
  'UPDATE_APK_INVALID',
  'UPDATE_STORAGE_ERROR',
  'UPDATE_NOT_READY',
  'UPDATE_INTERRUPTED',
  'UPDATE_UNAVAILABLE',
  'INSTALL_PERMISSION_REQUIRED',
  'INSTALLER_UNAVAILABLE',
  'UPDATES_UNAVAILABLE',
  'UPDATE_STATUS_INVALID',
  'UNSUPPORTED_PLATFORM',
  'UPDATE_UNKNOWN',
};

String _safeErrorCode(Object? code) =>
    code is String && _knownErrorCodes.contains(code) ? code : 'UPDATE_UNKNOWN';

class UpdateStatus {
  const UpdateStatus({
    required this.installedVersion,
    required this.installedBuild,
    required this.phase,
    this.availableVersion,
    this.availableBuild,
    this.downloadedBytes = 0,
    this.totalBytes = 0,
    this.errorCode,
    this.installPermissionGranted = false,
  });

  const UpdateStatus.unavailable({this.errorCode = 'UNSUPPORTED_PLATFORM'})
      : installedVersion = '',
        installedBuild = 0,
        phase = UpdatePhase.unavailable,
        availableVersion = null,
        availableBuild = null,
        downloadedBytes = 0,
        totalBytes = 0,
        installPermissionGranted = false;

  final String installedVersion;
  final int installedBuild;
  final UpdatePhase phase;
  final String? availableVersion;
  final int? availableBuild;
  final int downloadedBytes;
  final int totalBytes;
  final String? errorCode;
  final bool installPermissionGranted;

  double? get downloadProgress => totalBytes <= 0
      ? null
      : (downloadedBytes / totalBytes).clamp(0.0, 1.0).toDouble();

  factory UpdateStatus.fromMap(Map<Object?, Object?>? data) {
    if (data == null) throw const FormatException('Missing update status');

    String? version(Object? value) {
      if (value == null) return null;
      if (value is! String || value.length > 64 ||
          !RegExp(r'^\d+(?:\.\d+){1,3}(?:-[A-Za-z0-9.-]+)?(?:\+[A-Za-z0-9.-]+)?$')
              .hasMatch(value)) {
        throw const FormatException('Invalid update version');
      }
      return value;
    }

    int number(Object? value, {int? fallback}) {
      if (value == null && fallback != null) return fallback;
      if (value is! int || value < 0) {
        throw const FormatException('Invalid update counter');
      }
      return value;
    }

    final installedVersion = version(data['installedVersion']);
    if (installedVersion == null) {
      throw const FormatException('Missing installed version');
    }
    final installedBuild = number(data['installedBuild']);
    final phaseName = data['phase'];
    final matchingPhases = UpdatePhase.values.where((p) => p.name == phaseName);
    if (matchingPhases.isEmpty) {
      throw const FormatException('Invalid update phase');
    }
    final phase = matchingPhases.single;
    final availableVersion = version(data['availableVersion']);
    final availableBuild = data['availableBuild'] == null
        ? null : number(data['availableBuild']);
    if ({UpdatePhase.available, UpdatePhase.downloading, UpdatePhase.ready}
        .contains(phase) &&
        (availableVersion == null || availableBuild == null ||
            availableBuild <= installedBuild)) {
      throw const FormatException('Missing newer update');
    }
    final permission = data['installPermissionGranted'];
    if (permission != null && permission is! bool) {
      throw const FormatException('Invalid install permission');
    }

    return UpdateStatus(
      installedVersion: installedVersion,
      installedBuild: installedBuild,
      phase: phase,
      availableVersion: availableVersion,
      availableBuild: availableBuild,
      downloadedBytes: number(data['downloadedBytes'], fallback: 0),
      totalBytes: number(data['totalBytes'], fallback: 0),
      errorCode: data['errorCode'] == null ? null : _safeErrorCode(data['errorCode']),
      installPermissionGranted: permission == true,
    );
  }

  UpdateStatus withPhase(UpdatePhase nextPhase, {String? errorCode}) =>
      UpdateStatus(
        installedVersion: installedVersion,
        installedBuild: installedBuild,
        phase: nextPhase,
        availableVersion: availableVersion,
        availableBuild: availableBuild,
        downloadedBytes: downloadedBytes,
        totalBytes: totalBytes,
        errorCode: errorCode,
        installPermissionGranted: installPermissionGranted,
      );
}

class AppUpdates {
  AppUpdates({bool? isAndroid}) : _isAndroid = isAndroid ?? Platform.isAndroid;

  static const _channel = MethodChannel('shop.pushok.flow/updates');
  final bool _isAndroid;
  UpdateStatus _lastStatus = const UpdateStatus.unavailable();

  Future<UpdateStatus> updateStatus() => _invoke('updateStatus');
  Future<UpdateStatus> checkForUpdates() => _invoke('checkForUpdates');
  Future<UpdateStatus> downloadUpdate() => _invoke('downloadUpdate');
  Future<UpdateStatus> openInstallPermission() => _invoke('openInstallPermission');
  Future<UpdateStatus> installUpdate() => _invoke('installUpdate');

  Future<UpdateStatus> _invoke(String method) async {
    if (!_isAndroid) return const UpdateStatus.unavailable();
    try {
      final data = await _channel.invokeMapMethod<Object?, Object?>(method);
      final status = UpdateStatus.fromMap(data);
      _lastStatus = status;
      return status;
    } on MissingPluginException {
      return _lastStatus.withPhase(UpdatePhase.unavailable,
          errorCode: 'UPDATES_UNAVAILABLE');
    } on PlatformException catch (error) {
      return _lastStatus.withPhase(UpdatePhase.error,
          errorCode: _safeErrorCode(error.code));
    } on FormatException {
      return _lastStatus.withPhase(UpdatePhase.error,
          errorCode: 'UPDATE_STATUS_INVALID');
    } catch (_) {
      return _lastStatus.withPhase(UpdatePhase.error,
          errorCode: 'UPDATE_UNKNOWN');
    }
  }
}
