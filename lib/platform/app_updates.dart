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
  'UPDATE_METADATA_STALE',
  'UPDATE_RATE_LIMITED',
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
    this.checkedAtMillis,
    this.checkStage,
  });

  const UpdateStatus.unavailable({this.errorCode = 'UNSUPPORTED_PLATFORM'})
      : installedVersion = '',
        installedBuild = 0,
        phase = UpdatePhase.unavailable,
        availableVersion = null,
        availableBuild = null,
        downloadedBytes = 0,
        totalBytes = 0,
        installPermissionGranted = false,
        checkedAtMillis = null,
        checkStage = null;

  final String installedVersion;
  final int installedBuild;
  final UpdatePhase phase;
  final String? availableVersion;
  final int? availableBuild;
  final int downloadedBytes;
  final int totalBytes;
  final String? errorCode;
  final bool installPermissionGranted;
  /// The last successful native verification, never the start of a request.
  final int? checkedAtMillis;
  final String? checkStage;

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
    final checkedAtMillis = data['checkedAtMillis'] == null
        ? null : number(data['checkedAtMillis']);
    if (checkedAtMillis != null &&
        (checkedAtMillis == 0 || checkedAtMillis > 8640000000000000)) {
      throw const FormatException('Invalid update check time');
    }
    final checkStage = data['checkStage'];
    if (checkStage != null && (checkStage is! String ||
        phase != UpdatePhase.checking ||
        !const {'release', 'manifest'}.contains(checkStage))) {
      throw const FormatException('Invalid update check stage');
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
      checkedAtMillis: checkedAtMillis,
      checkStage: checkStage,
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
        checkedAtMillis: checkedAtMillis,
        checkStage: nextPhase == UpdatePhase.checking &&
            phase == UpdatePhase.checking ? checkStage : null,
      );
}

class AppUpdates {
  AppUpdates({bool? isAndroid}) : _isAndroid = isAndroid ?? Platform.isAndroid;

  static const _channel = MethodChannel('shop.pushok.flow/updates');
  final bool _isAndroid;
  UpdateStatus _lastStatus = const UpdateStatus.unavailable();
  int _operationRevision = 0;
  int _statusRequest = 0;

  Future<UpdateStatus> updateStatus() {
    final revision = _operationRevision;
    final request = ++_statusRequest;
    return _invoke('updateStatus', accept: () =>
        revision == _operationRevision && request == _statusRequest);
  }

  Future<UpdateStatus> checkForUpdates() => _operation('checkForUpdates');
  Future<UpdateStatus> downloadUpdate() => _operation('downloadUpdate');
  Future<UpdateStatus> openInstallPermission() => _operation('openInstallPermission');
  Future<UpdateStatus> installUpdate() => _operation('installUpdate');

  Future<UpdateStatus> _operation(String method) async {
    final revision = ++_operationRevision;
    try {
      return await _invoke(method,
          accept: () => revision == _operationRevision);
    } finally {
      // A late poll from this operation must not become the fallback for a
      // future channel error after its final result has already been accepted.
      if (revision == _operationRevision) _operationRevision++;
    }
  }

  Future<UpdateStatus> _invoke(String method,
      {required bool Function() accept}) async {
    if (!_isAndroid) return const UpdateStatus.unavailable();
    try {
      final data = await _channel.invokeMapMethod<Object?, Object?>(method);
      final status = UpdateStatus.fromMap(data);
      if (accept()) _lastStatus = status;
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
