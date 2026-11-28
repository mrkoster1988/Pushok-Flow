import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pushok_flow/models/app_release_history.dart';
import 'package:pushok_flow/models/app_version.dart';
import 'package:pushok_flow/platform/app_updates.dart';

Map<String, Object?> _notes({String version = '0.49.0', int build = 49,
  List<Object?> changes = const ['Проверочное изменение.'], Object? publishedOn}) => {
  'versionName': version, 'versionCode': build, 'changes': changes,
  'publishedOn': publishedOn,
};

Map<Object?, Object?> _status(Object? notes, {bool newer = true}) => {
  'installedVersion': '0.48.0', 'installedBuild': 48,
  'phase': newer ? 'available' : 'current',
  if (newer) ...{'availableVersion': '0.49.0', 'availableBuild': 49},
  'automaticUpdatesEnabled': true, 'installWaitingReason': null,
  'releaseNotes': notes,
};

void main() {
  test('Bundled diagnostics identity matches the actual Android release version', () {
    final spec = File('pubspec.yaml').readAsStringSync();
    final version = RegExp(r'^version:\s*(\S+)\s*$', multiLine: true).firstMatch(spec);
    expect(version?.group(1), '$appVersionName+$appVersionCode');
    expect(bundledAppReleaseHistory.first.matches(appVersionName, appVersionCode), isTrue);
  });

  test('Optional descriptions match the exact target version and build', () {
    final available = UpdateStatus.fromMap(_status(_notes(publishedOn: '2026-11-23')));
    expect(available.releaseNotes!.versionName, '0.49.0');
    expect(available.releaseNotes!.versionCode, 49);
    expect(available.releaseNotes!.publishedOn, '2026-11-23');
    expect(available.hasNewerVersion, isTrue);
    expect(UpdateStatus.fromMap(_status(_notes(build: 50))).releaseNotes, isNull);
    expect(UpdateStatus.fromMap(_status(_notes(version: '0.50.0'))).releaseNotes, isNull);
    final installed = _notes(version: '0.48.0', build: 48);
    expect(UpdateStatus.fromMap(_status(installed)).releaseNotes, isNull);
    expect(UpdateStatus.fromMap(_status(installed, newer: false)).releaseNotes!.versionCode, 48);
    expect(UpdateStatus.fromMap(_status(_notes(), newer: false)).releaseNotes, isNull);
  });

  test('Malformed optional descriptions never invalidate update availability', () {
    final invalid = <Object?>[
      null, 'raw release text', <Object?>[], <String, Object?>{},
      {..._notes(), 'versionCode': '49'}, {..._notes(), 'versionName': 49},
      {..._notes(), 'changes': 'raw text'},
      _notes(changes: []), _notes(changes: List.filled(9, 'Изменение.')),
      _notes(changes: ['']), _notes(changes: ['   ']), _notes(changes: [1]),
      _notes(changes: ['x' * 601]), _notes(changes: List.filled(8, 'x' * 501)),
      _notes(changes: ['строка\nподмена']), _notes(changes: ['строка\u0000']),
      _notes(changes: ['строка\u007f']), _notes(changes: ['строка\u202eподмена']),
      _notes(changes: ['строка\u2066подмена']), _notes(changes: ['\ud800']),
      _notes(changes: ['\udc00']), _notes(changes: ['\ud800x']),
      _notes(publishedOn: 20261123), _notes(publishedOn: '23.11.2026'),
      _notes(publishedOn: '2026-02-30'), _notes(publishedOn: '2026-13-01'),
      _notes(publishedOn: '2026-11-23T12:00:00Z'),
    ];
    for (final notes in invalid) {
      final status = UpdateStatus.fromMap(_status(notes));
      expect(status.phase, UpdatePhase.available);
      expect(status.availableBuild, 49);
      expect(status.errorCode, isNull);
      expect(status.releaseNotes, isNull);
    }
  });

  test('Descriptions stay bounded and immutable across pending or failed phases', () {
    final input = <Object?>['  Новое описание 🙂  '];
    final status = UpdateStatus.fromMap(_status(_notes(changes: input)));
    input[0] = 'Changed after decoding';
    expect(status.releaseNotes!.changes, ['Новое описание 🙂']);
    expect(() => status.releaseNotes!.changes.add('mutated'), throwsUnsupportedError);
    expect(status.withPhase(UpdatePhase.checking).releaseNotes, same(status.releaseNotes));
    final failed = status.withPhase(UpdatePhase.error, errorCode: 'UPDATE_NETWORK_ERROR');
    expect(failed.releaseNotes!.matches(failed.availableVersion!, failed.availableBuild!), isTrue);
    expect(UpdateStatus.fromMap(_status(_notes(changes: List.filled(8, 'x' * 500))))
      .releaseNotes!.changes, hasLength(8));
    expect(UpdateStatus.fromMap(_status(_notes(changes: ['x' * 600])))
      .releaseNotes!.changes.single, hasLength(600));
    expect(UpdateStatus.fromMap(_status(_notes(publishedOn: '2028-02-29')))
      .releaseNotes!.publishedOn, '2028-02-29');
  });

  test('Bundled history contains recent Android versions with exact lookup', () {
    expect(bundledAppReleaseHistory.map((notes) => notes.versionCode), [77, 76, 75, 74, 73, 72, 71, 70, 69, 68, 67, 66, 65, 64, 63, 62, 61, 60]);
    for (final notes in bundledAppReleaseHistory) {
      expect(bundledAppRelease(notes.versionName, notes.versionCode), same(notes));
      expect(bundledAppRelease(notes.versionName, notes.versionCode + 1), isNull);
      expect(AppReleaseNotes.fromPlatform({
        'versionName': notes.versionName, 'versionCode': notes.versionCode,
        'changes': notes.changes, 'publishedOn': notes.publishedOn,
      }, expectedVersion: notes.versionName, expectedBuild: notes.versionCode), isNotNull);
    }
    expect(bundledAppRelease('0.99.0', 99), isNull);
  });
}
