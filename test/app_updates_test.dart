import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pushok_flow/design/pushok_theme.dart';
import 'package:pushok_flow/platform/app_updates.dart';
import 'package:pushok_flow/ui/app_updates_card.dart';

Map<String, Object?> _status({
  String phase = 'idle',
  bool permission = false,
  int downloaded = 0,
  int total = 0,
  String? error,
  int? checkedAt,
  String? checkStage,
  bool automatic = true,
  String? waitingReason,
  String installedVersion = '0.24.0',
  int installedBuild = 24,
  String availableVersion = '0.25.0',
  int availableBuild = 25,
  Object? releaseNotes,
}) => {
  'installedVersion': installedVersion,
  'installedBuild': installedBuild,
  'phase': phase,
  if (['available', 'downloading', 'ready', 'installing'].contains(phase)) ...{
    'availableVersion': availableVersion,
    'availableBuild': availableBuild,
  },
  'downloadedBytes': downloaded,
  'totalBytes': total,
  'installPermissionGranted': permission,
  'errorCode': error,
  'checkedAtMillis': checkedAt,
  'checkStage': checkStage,
  'automaticUpdatesEnabled': automatic,
  'installWaitingReason': waitingReason,
  'releaseNotes': releaseNotes,
};

Map<String, Object?> _notes({String version = '0.50.0', int build = 50,
  List<String> changes = const ['Новое проверочное изменение.']}) => {
  'versionName': version, 'versionCode': build, 'changes': changes,
  'publishedOn': '2026-11-23',
};

class _UpdatesBridge {
  Map<String, Object?> state = _status();
  final calls = <String>[];
  Completer<Map<String, Object?>>? checkGate;
  Completer<Map<String, Object?>>? downloadGate;
  Completer<Map<String, Object?>>? statusGate;
  Completer<void>? automaticGate;
  PlatformException? checkError;
  PlatformException? automaticError;
  final automaticArguments = <Object?>[];

  int count(String method) => calls.where((call) => call == method).length;

  Future<Object?> handle(MethodCall call) async {
    calls.add(call.method);
    switch (call.method) {
      case 'updateStatus':
        final gate = statusGate;
        if (gate != null) {
          statusGate = null;
          return gate.future;
        }
        return Map<String, Object?>.of(state);
      case 'checkForUpdates':
        if (checkError != null) throw checkError!;
        state = {...state, 'phase': 'checking', 'checkStage': 'release',
          'errorCode': null};
        state = checkGate == null
            ? _status(phase: 'available', automatic: state['automaticUpdatesEnabled'] as bool)
            : await checkGate!.future;
        return state;
      case 'downloadUpdate':
        state = _status(phase: 'downloading', total: 4096,
          automatic: state['automaticUpdatesEnabled'] as bool);
        state = downloadGate == null
            ? _status(phase: 'ready', automatic: state['automaticUpdatesEnabled'] as bool)
            : await downloadGate!.future;
        return state;
      case 'setAutomaticUpdates':
        automaticArguments.add(call.arguments);
        if (automaticGate != null) await automaticGate!.future;
        if (automaticError != null) throw automaticError!;
        state = {...state, 'automaticUpdatesEnabled': (call.arguments as Map)['enabled']};
        return Map<String, Object?>.of(state);
      case 'openInstallPermission':
      case 'installUpdate':
        return Map<String, Object?>.of(state);
      default:
        throw MissingPluginException(call.method);
    }
  }
}

Future<void> _withCard(WidgetTester tester,
    Future<void> Function() body, {bool isAndroid = true, bool settle = true,
      double textScale = 1, Size size = const Size(390, 844)}) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.binding.setSurfaceSize(size);
  await tester.pumpWidget(MaterialApp(
    theme: buildPushokTheme(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: Scaffold(body: SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: AppUpdatesCard(isAndroid: isAndroid),
    )),
  ));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
  try {
    await body();
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.binding.setSurfaceSize(null);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('shop.pushok.flow/updates');
  late _UpdatesBridge bridge;

  setUp(() {
    bridge = _UpdatesBridge();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, bridge.handle);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('Status decoding handles progress without assuming a known file size', () {
    final downloading = UpdateStatus.fromMap(_status(
        phase: 'downloading', downloaded: 1024, total: 4096));
    expect(downloading.installedVersion, '0.24.0');
    expect(downloading.availableVersion, '0.25.0');
    expect(downloading.availableBuild, 25);
    expect(downloading.downloadProgress, .25);
    expect(UpdateStatus.fromMap(_status(phase: 'downloading', downloaded: 10))
        .downloadProgress, isNull);
    expect(UpdateStatus.fromMap(_status(
        phase: 'downloading', downloaded: 8192, total: 4096))
        .downloadProgress, 1);
  });

  test('Malformed status cannot enable a misleading download or installation', () {
    final invalid = <Map<String, Object?>>[
      {..._status(), 'phase': 'unexpected'},
      {..._status(), 'installedVersion': 24},
      {..._status(), 'installedBuild': '24'},
      {..._status(), 'phase': 'ready'},
      {..._status(phase: 'ready'), 'availableBuild': 23},
      {..._status(phase: 'ready'), 'availableVersion': 'https://SECRET.example'},
      {..._status(), 'installPermissionGranted': 'true'},
      {..._status()}..remove('automaticUpdatesEnabled'),
      {..._status(), 'automaticUpdatesEnabled': 'true'},
      {..._status(), 'automaticUpdatesEnabled': null},
      {..._status(), 'automaticUpdatesEnabled': 1},
      {..._status()}..remove('installWaitingReason'),
      {..._status(), 'installWaitingReason': 'SECRET_NATIVE_DETAIL'},
      {..._status(), 'installWaitingReason': 1},
      {..._status(), 'phase': 'installing'},
      {..._status(phase: 'installing'), 'availableBuild': 24},
      {..._status(), 'totalBytes': -1},
      {..._status(), 'checkedAtMillis': '1000'},
      {..._status(), 'checkedAtMillis': 0},
      {..._status(), 'checkedAtMillis': -1},
      {..._status(), 'checkedAtMillis': 8640000000000001},
      {..._status(phase: 'checking'), 'checkStage': 'SECRET_NATIVE_DETAIL'},
      {..._status(phase: 'checking'), 'checkStage': 1},
      {..._status(phase: 'available'), 'checkStage': 'manifest'},
    ];
    for (final data in invalid) {
      expect(() => UpdateStatus.fromMap(data), throwsFormatException);
    }
    expect(() => UpdateStatus.fromMap(null), throwsFormatException);
  });

  test('Automatic updates default on and installation never changes the reported installed version', () {
    final initial = UpdateStatus.fromMap(_status());
    expect(initial.automaticUpdatesEnabled, isTrue);
    expect(initial.installWaitingReason, isNull);
    final installing = UpdateStatus.fromMap(_status(phase: 'installing'));
    expect(installing.phase, UpdatePhase.installing);
    expect(installing.installedVersion, '0.24.0');
    expect(installing.installedBuild, 24);
    expect(installing.availableVersion, '0.25.0');
    final disabled = UpdateStatus.fromMap(_status(automatic: false));
    expect(disabled.withPhase(UpdatePhase.checking).automaticUpdatesEnabled, isFalse);
    expect(disabled.withPhase(UpdatePhase.error,
      errorCode: 'UPDATE_NETWORK_ERROR').automaticUpdatesEnabled, isFalse);
    for (final reason in ['permission', 'confirmation', 'connection', 'foreground', 'unsupported']) {
      for (final phase in ['ready', 'checking', 'downloading']) {
        expect(UpdateStatus.fromMap(_status(phase: phase,
          waitingReason: reason)).installWaitingReason, reason);
      }
    }
    for (final code in ['UPDATE_INSTALL_FAILED', 'UPDATE_SCHEDULER_UNAVAILABLE']) {
      expect(UpdateStatus.fromMap(_status(phase: 'error', error: code)).errorCode, code);
    }
  });

  test('A late poll cannot restore automatic updates after a durable opt-out', () async {
    final updates = AppUpdates(isAndroid: true);
    await updates.updateStatus();
    final oldRead = Completer<Map<String, Object?>>();
    bridge.statusGate = oldRead;
    final oldResponse = updates.updateStatus();
    await Future<void>.delayed(Duration.zero);
    expect((await updates.setAutomaticUpdates(false)).automaticUpdatesEnabled, isFalse);
    expect(bridge.automaticArguments, [{'enabled': false}]);
    oldRead.complete(_status(automatic: true));
    await oldResponse;
    bridge.checkError = PlatformException(code: 'UPDATE_NETWORK_ERROR');
    expect((await updates.checkForUpdates()).automaticUpdatesEnabled, isFalse);
    expect(bridge.count('installUpdate'), 0);
    expect(bridge.count('openInstallPermission'), 0);
  });

  test('Unknown error codes are normalized without retaining exception text', () {
    final status = UpdateStatus.fromMap({
      ..._status(phase: 'error', error: 'SECRET_NATIVE_DETAIL'),
      'message': 'SECRET_NATIVE_DETAIL',
      'details': 'SECRET_NATIVE_DETAIL',
    });
    expect(status.errorCode, 'UPDATE_UNKNOWN');
  });

  test('Successful check time is optional and survives pending or failed phases', () {
    expect(UpdateStatus.fromMap(_status()).checkedAtMillis, isNull);
    final timestamp = DateTime(2026, 11, 22, 0, 35).millisecondsSinceEpoch;
    final checked = UpdateStatus.fromMap(_status(
        phase: 'current', checkedAt: timestamp));
    final pending = checked.withPhase(UpdatePhase.checking);
    expect(pending.checkedAtMillis, timestamp);
    expect(pending.checkStage, isNull);
    final staged = UpdateStatus.fromMap(_status(
        phase: 'checking', checkedAt: timestamp, checkStage: 'manifest'));
    expect(staged.checkStage, 'manifest');
    final failed = staged.withPhase(UpdatePhase.error,
        errorCode: 'UPDATE_METADATA_STALE');
    expect(failed.checkedAtMillis, timestamp);
    expect(failed.checkStage, isNull);
    for (final code in ['UPDATE_METADATA_STALE', 'UPDATE_RATE_LIMITED']) {
      expect(UpdateStatus.fromMap(_status(phase: 'error', error: code))
          .errorCode, code);
    }
  });

  test('A late status read cannot replace the fallback from a completed check', () async {
    final updates = AppUpdates(isAndroid: true);
    await updates.updateStatus();
    final oldRead = Completer<Map<String, Object?>>();
    bridge.statusGate = oldRead;
    final oldResponse = updates.updateStatus();
    // Wait until the platform has accepted the delayed read before checking.
    await Future<void>.delayed(Duration.zero);
    expect(bridge.statusGate, isNull);
    expect((await updates.checkForUpdates()).phase, UpdatePhase.available);
    oldRead.complete(_status(phase: 'current'));
    await oldResponse;
    bridge.checkError = PlatformException(code: 'UPDATE_NETWORK_ERROR');
    final failed = await updates.checkForUpdates();
    expect(failed.phase, UpdatePhase.error);
    expect(failed.availableVersion, '0.25.0');
    expect(failed.availableBuild, 25);
  });

  test('Unsupported platforms never invoke update or installer channels', () async {
    final updates = AppUpdates(isAndroid: false);
    for (final status in await Future.wait([
      updates.updateStatus(),
      updates.checkForUpdates(),
      updates.downloadUpdate(),
      updates.openInstallPermission(),
      updates.installUpdate(),
      updates.setAutomaticUpdates(false),
    ])) {
      expect(status.phase, UpdatePhase.unavailable);
      expect(status.errorCode, 'UNSUPPORTED_PLATFORM');
    }
    expect(bridge.calls, isEmpty);
  });

  test('Late native notes cannot replace the version retained after a failed recheck', () async {
    bridge.state = _status(phase: 'available', installedVersion: '0.49.0', installedBuild: 49,
      availableVersion: '0.50.0', availableBuild: 50, releaseNotes: _notes());
    final updates = AppUpdates(isAndroid: true);
    await updates.updateStatus();
    final oldRead = Completer<Map<String, Object?>>();
    bridge.statusGate = oldRead;
    final oldResponse = updates.updateStatus();
    await Future<void>.delayed(Duration.zero);
    final oldState = Map<String, Object?>.of(bridge.state);
    bridge.checkGate = Completer<Map<String, Object?>>()..complete(_status(
      phase: 'available', installedVersion: '0.49.0', installedBuild: 49,
      availableVersion: '0.51.0', availableBuild: 51,
      releaseNotes: _notes(version: '0.51.0', build: 51, changes: ['Описание версии 51.'])));
    expect((await updates.checkForUpdates()).releaseNotes!.versionCode, 51);
    oldRead.complete(oldState);
    await oldResponse;
    bridge.checkError = PlatformException(code: 'UPDATE_NETWORK_ERROR');
    final failed = await updates.checkForUpdates();
    expect(failed.availableBuild, 51);
    expect(failed.releaseNotes!.versionCode, 51);
    expect(failed.releaseNotes!.changes, ['Описание версии 51.']);
  });

  test('Missing native support and malformed channel data return safe states', () async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel,
        (_) async => throw MissingPluginException('SECRET_NATIVE_DETAIL'));
    expect((await AppUpdates(isAndroid: true).updateStatus()).phase,
        UpdatePhase.unavailable);
    messenger.setMockMethodCallHandler(channel, (_) async => {'phase': 'ready'});
    final invalid = await AppUpdates(isAndroid: true).updateStatus();
    expect(invalid.phase, UpdatePhase.error);
    expect(invalid.errorCode, 'UPDATE_STATUS_INVALID');
  });

  testWidgets('Automatic updates start enabled and permission setup always needs an explicit tap', (tester) async {
    await _withCard(tester, () async {
      final automatic = find.byKey(const Key('automatic_app_updates'));
      expect(tester.widget<SwitchListTile>(automatic).value, isTrue);
      expect(find.text('Проверка и загрузка в фоне'), findsOneWidget);
      expect(find.byKey(const Key('allow_app_update_install')), findsOneWidget);
      expect(bridge.calls, ['updateStatus']);
      await tester.tap(find.byKey(const Key('allow_app_update_install')));
      await tester.pumpAndSettle();
      expect(bridge.count('openInstallPermission'), 1);
      expect(bridge.count('downloadUpdate'), 0);
      expect(bridge.count('installUpdate'), 0);
      expect(bridge.count('setAutomaticUpdates'), 0);
      await tester.tap(find.byKey(const Key('info_automatic_app_updates')));
      await tester.pumpAndSettle();
      expect(find.textContaining('примерно раз в 6 часов'), findsOneWidget);
      expect(find.textContaining('включая мобильную сеть'), findsOneWidget);
      expect(find.textContaining('если Android позволяет'), findsOneWidget);
      await tester.tap(find.text('Понятно'));
      await tester.pumpAndSettle();
    });
  });

  testWidgets('Disabling automatic updates waits for saved settings and preserves manual updates', (tester) async {
    await _withCard(tester, () async {
      final automatic = find.byKey(const Key('automatic_app_updates'));
      bridge.automaticGate = Completer<void>();
      await tester.tap(automatic);
      await tester.pump();
      expect(bridge.automaticArguments, [{'enabled': false}]);
      expect(tester.widget<SwitchListTile>(automatic).value, isTrue);
      expect(tester.widget<SwitchListTile>(automatic).onChanged, isNull);
      bridge.automaticGate!.complete();
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(automatic).value, isFalse);
      expect(find.text('Обновления по кнопке'), findsOneWidget);
      expect(find.byKey(const Key('allow_app_update_install')), findsNothing);
      final readsAfterDisable = bridge.count('updateStatus');
      await tester.pump(const Duration(seconds: 5));
      expect(bridge.count('updateStatus'), readsAfterDisable);
      await tester.tap(find.byKey(const Key('check_app_updates')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('download_app_update')), findsOneWidget);
      expect(tester.widget<SwitchListTile>(automatic).value, isFalse);
      expect(bridge.count('checkForUpdates'), 1);
      expect(bridge.count('installUpdate'), 0);
    });
  });

  testWidgets('Failed automatic setting write preserves the prior setting and hides native details', (tester) async {
    bridge.automaticError = PlatformException(code: 'UPDATE_STORAGE_ERROR',
      message: 'SECRET_NATIVE_DETAIL');
    await _withCard(tester, () async {
      final automatic = find.byKey(const Key('automatic_app_updates'));
      await tester.tap(automatic);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(automatic).value, isTrue);
      expect(find.byKey(const Key('app_update_error')), findsOneWidget);
      expect(find.textContaining('SECRET'), findsNothing);
      expect(find.byKey(const Key('check_app_updates')), findsOneWidget);
      expect(bridge.count('installUpdate'), 0);
      expect(bridge.count('openInstallPermission'), 0);
    });
  });

  testWidgets('Opt-out during a pending download cannot be undone by its late result', (tester) async {
    bridge.state = _status(phase: 'available', permission: true);
    final response = Completer<Map<String, Object?>>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'downloadUpdate') {
        bridge.calls.add(call.method);
        bridge.state = _status(phase: 'downloading', permission: true, total: 4096);
        return response.future;
      }
      return bridge.handle(call);
    });
    await _withCard(tester, () async {
      await tester.tap(find.byKey(const Key('download_app_update')));
      await tester.pump();
      final automatic = find.byKey(const Key('automatic_app_updates'));
      expect(tester.widget<SwitchListTile>(automatic).onChanged, isNotNull);
      await tester.tap(automatic);
      await tester.pump();
      expect(tester.widget<SwitchListTile>(automatic).value, isFalse);
      bridge.state = _status(phase: 'ready', permission: true, automatic: false);
      response.complete(_status(phase: 'ready', permission: true, automatic: true));
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(automatic).value, isFalse);
      expect(find.byKey(const Key('install_app_update')), findsOneWidget);
      expect(bridge.automaticArguments, [{'enabled': false}]);
      expect(bridge.count('downloadUpdate'), 1);
      expect(bridge.count('installUpdate'), 0);
    });
  });

  testWidgets('Installing polls the actual package version without claiming an early success', (tester) async {
    bridge.state = _status(phase: 'installing', permission: true);
    await _withCard(tester, () async {
      expect(find.text('Установлена версия 0.24.0'), findsOneWidget);
      expect(find.text('Устанавливаем версию 0.25.0…'), findsOneWidget);
      expect(find.text('Установлена версия 0.25.0'), findsNothing);
      expect(find.byKey(const Key('install_app_update')), findsNothing);
      expect(find.byKey(const Key('check_app_updates')), findsNothing);
      final initialReads = bridge.count('updateStatus');
      bridge.state = {..._status(phase: 'current', permission: true),
        'installedVersion': '0.25.0', 'installedBuild': 25};
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(bridge.count('updateStatus'), initialReads + 1);
      expect(find.text('Установлена версия 0.25.0'), findsOneWidget);
      expect(find.byKey(const Key('app_update_installing')), findsNothing);
      await tester.pump(const Duration(seconds: 3));
      expect(bridge.count('updateStatus'), initialReads + 1);
      expect(bridge.count('installUpdate'), 0);
      expect(bridge.count('openInstallPermission'), 0);
    }, settle: false);
  });

  testWidgets('An idle card observes background download through slow local polling without a tap', (tester) async {
    await _withCard(tester, () async {
      final initialReads = bridge.count('updateStatus');
      bridge.state = _status(phase: 'downloading', downloaded: 1024, total: 4096);
      await tester.pump(const Duration(seconds: 4));
      expect(bridge.count('updateStatus'), initialReads);
      expect(find.byKey(const Key('app_update_progress')), findsNothing);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(bridge.count('updateStatus'), initialReads + 1);
      expect(tester.widget<LinearProgressIndicator>(
        find.byKey(const Key('app_update_progress'))).value, .25);
      bridge.state = _status(phase: 'downloading', downloaded: 2048, total: 4096);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(bridge.count('updateStatus'), initialReads + 2);
      expect(tester.widget<LinearProgressIndicator>(
        find.byKey(const Key('app_update_progress'))).value, .5);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      final pausedReads = bridge.count('updateStatus');
      await tester.pump(const Duration(seconds: 10));
      expect(bridge.count('updateStatus'), pausedReads);
      expect(bridge.count('checkForUpdates'), 0);
      expect(bridge.count('downloadUpdate'), 0);
      expect(bridge.count('installUpdate'), 0);
      expect(bridge.count('openInstallPermission'), 0);
    });
  });

  const waitingMessages = {
    'permission': 'Один раз разрешите установку обновлений',
    'confirmation': 'Android ждёт вашего подтверждения',
    'connection': 'Автоустановка ждёт отключения активного подключения',
    'foreground': 'когда вы свернёте Pushok Flow',
    'unsupported': 'Эта версия Android требует подтверждения',
  };
  for (final entry in waitingMessages.entries) {
    testWidgets('Ready update explains ${entry.key} without launching Android UI', (tester) async {
      bridge.state = _status(phase: 'ready', permission: entry.key != 'permission',
        waitingReason: entry.key);
      await _withCard(tester, () async {
        expect(find.textContaining(entry.value), findsOneWidget);
        expect(find.text('Установлена версия 0.24.0'), findsOneWidget);
        expect(find.text('Установлена версия 0.25.0'), findsNothing);
        expect(find.byKey(const Key('app_update_installing')), findsNothing);
        if (entry.key == 'permission') {
          expect(find.byKey(const Key('allow_app_update_install')), findsOneWidget);
          expect(find.byKey(const Key('install_app_update')), findsNothing);
        } else {
          expect(find.byKey(const Key('install_app_update')), findsOneWidget);
        }
        expect(bridge.calls, ['updateStatus']);
      });
    });
  }

  testWidgets('A connection can defer automatic installation without hiding manual installation', (tester) async {
    bridge.state = _status(phase: 'ready', permission: true,
        waitingReason: 'connection');
    await _withCard(tester, () async {
      expect(find.textContaining('установить обновление вручную'), findsOneWidget);
      await tester.tap(find.byKey(const Key('install_app_update')));
      await tester.pumpAndSettle();
      expect(bridge.count('installUpdate'), 1);
      expect(bridge.count('setAutomaticUpdates'), 0);
      expect(bridge.count('downloadUpdate'), 0);
    });
  });

  testWidgets('Manual checking, downloading, permission and installation remain separate actions', (tester) async {
    await _withCard(tester, () async {
      expect(find.text('Установлена версия 0.24.0'), findsOneWidget);
      expect(bridge.calls, ['updateStatus']);
      await tester.pump(const Duration(seconds: 3));
      expect(bridge.calls, ['updateStatus']);

      await tester.tap(find.byKey(const Key('check_app_updates')));
      await tester.pumpAndSettle();
      expect(find.text('Доступна версия 0.25.0'), findsOneWidget);
      expect(bridge.count('downloadUpdate'), 0);

      bridge.downloadGate = Completer<Map<String, Object?>>();
      await tester.tap(find.byKey(const Key('download_app_update')));
      await tester.pump();
      expect(bridge.count('downloadUpdate'), 1);
      expect(find.byKey(const Key('app_update_progress')), findsOneWidget);
      bridge.state = _status(phase: 'downloading', downloaded: 1024, total: 4096);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(tester.widget<LinearProgressIndicator>(
          find.byKey(const Key('app_update_progress'))).value, .25);
      expect(bridge.count('installUpdate'), 0);

      bridge.downloadGate!.complete(_status(phase: 'ready'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('allow_app_update_install')), findsOneWidget);
      expect(find.byKey(const Key('install_app_update')), findsNothing);
      await tester.tap(find.byKey(const Key('allow_app_update_install')));
      await tester.pumpAndSettle();
      expect(bridge.count('openInstallPermission'), 1);
      expect(bridge.count('installUpdate'), 0);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      bridge.state = _status(phase: 'ready', permission: true);
      final readsBeforeResume = bridge.count('updateStatus');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(bridge.count('updateStatus'), readsBeforeResume + 1);
      expect(find.byKey(const Key('allow_app_update_install')), findsNothing);
      expect(find.byKey(const Key('install_app_update')), findsOneWidget);
      expect(bridge.count('installUpdate'), 0);
      await tester.tap(find.byKey(const Key('install_app_update')));
      await tester.pumpAndSettle();
      expect(bridge.count('installUpdate'), 1);
    });
  });

  testWidgets('Download polling pauses in background and slows when the APK is ready', (tester) async {
    bridge.state = _status(phase: 'downloading', downloaded: 1024, total: 4096);
    await _withCard(tester, () async {
      final firstReads = bridge.count('updateStatus');
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(bridge.count('updateStatus'), firstReads + 1);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      final backgroundReads = bridge.count('updateStatus');
      await tester.pump(const Duration(seconds: 5));
      expect(bridge.count('updateStatus'), backgroundReads);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(bridge.count('updateStatus'), backgroundReads + 1);
      bridge.state = _status(phase: 'ready', permission: true);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('install_app_update')), findsOneWidget);
      final completedReads = bridge.count('updateStatus');
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(bridge.count('updateStatus'), completedReads + 1);
      expect(bridge.count('downloadUpdate'), 0);
      expect(bridge.count('installUpdate'), 0);
    });
  });

  testWidgets('Reopening an ongoing check follows its stages and result without a second check', (tester) async {
    bridge.state = _status(phase: 'checking', checkStage: 'release');
    await _withCard(tester, () async {
      expect(find.text('Ищем новую версию…'), findsOneWidget);
      final initialReads = bridge.count('updateStatus');
      bridge.state = _status(phase: 'checking', checkStage: 'manifest');
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(bridge.count('updateStatus'), initialReads + 1);
      expect(find.text('Проверяем сведения об обновлении…'), findsOneWidget);
      bridge.state = _status(phase: 'available');
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('download_app_update')), findsOneWidget);
      final completedReads = bridge.count('updateStatus');
      await tester.pump(const Duration(seconds: 3));
      expect(bridge.count('updateStatus'), completedReads);
      expect(bridge.count('checkForUpdates'), 0);
      expect(bridge.count('downloadUpdate'), 0);
    }, settle: false);
  });

  testWidgets('Repeated taps cannot start concurrent operations or update a disposed card', (tester) async {
    bridge.checkGate = Completer<Map<String, Object?>>();
    await _withCard(tester, () async {
      final check = find.byKey(const Key('check_app_updates'));
      await tester.tap(check);
      await tester.tap(check);
      await tester.pump();
      expect(bridge.count('checkForUpdates'), 1);
      expect(find.text('Проверяем обновления…'), findsOneWidget);
      bridge.checkGate!.complete(_status(phase: 'available'));
      await tester.pumpAndSettle();

      bridge.downloadGate = Completer<Map<String, Object?>>();
      final download = find.byKey(const Key('download_app_update'));
      await tester.tap(download);
      await tester.tap(download);
      await tester.pump();
      expect(bridge.count('downloadUpdate'), 1);
      await tester.pumpWidget(const SizedBox.shrink());
      bridge.downloadGate!.complete(_status(phase: 'ready', permission: true));
      await tester.pump();
      final readsAfterDispose = bridge.count('updateStatus');
      await tester.pump(const Duration(seconds: 5));
      expect(bridge.count('updateStatus'), readsAfterDispose);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('A late progress poll cannot replace a completed download', (tester) async {
    bridge.state = _status(phase: 'available');
    bridge.downloadGate = Completer<Map<String, Object?>>();
    await _withCard(tester, () async {
      await tester.tap(find.byKey(const Key('download_app_update')));
      await tester.pump();
      final oldPoll = Completer<Map<String, Object?>>();
      bridge.statusGate = oldPoll;
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      bridge.downloadGate!.complete(_status(phase: 'ready', permission: true));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('install_app_update')), findsOneWidget);

      oldPoll.complete(_status(phase: 'downloading', downloaded: 1024, total: 4096));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('install_app_update')), findsOneWidget);
      expect(find.byKey(const Key('app_update_progress')), findsNothing);
    });
  });

  testWidgets('A pending read before a pause cannot block or replace the resumed read', (tester) async {
    bridge.state = _status(phase: 'available');
    await _withCard(tester, () async {
      final oldRead = Completer<Map<String, Object?>>();
      bridge.statusGate = oldRead;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(bridge.statusGate, isNull);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      bridge.state = _status(phase: 'ready', permission: true);
      final readsBeforeResume = bridge.count('updateStatus');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(bridge.count('updateStatus'), readsBeforeResume + 1);
      expect(find.byKey(const Key('install_app_update')), findsOneWidget);

      oldRead.complete(_status(phase: 'checking', checkStage: 'release'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('install_app_update')), findsOneWidget);
      expect(find.byKey(const Key('app_update_check_stage')), findsNothing);
      expect(bridge.count('checkForUpdates'), 0);
      expect(bridge.count('installUpdate'), 0);
    });
  });

  testWidgets('Checking polls stop in background and a background result is not displayed', (tester) async {
    bridge.state = _status(phase: 'checking', checkStage: 'release');
    await _withCard(tester, () async {
      final oldRead = Completer<Map<String, Object?>>();
      bridge.statusGate = oldRead;
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      final backgroundReads = bridge.count('updateStatus');
      oldRead.complete(_status(phase: 'available'));
      await tester.pump(const Duration(seconds: 5));
      expect(find.byKey(const Key('download_app_update')), findsNothing);
      expect(bridge.count('updateStatus'), backgroundReads);

      bridge.state = _status(phase: 'ready', permission: true);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('install_app_update')), findsOneWidget);
      expect(bridge.count('checkForUpdates'), 0);
    }, settle: false);
  });

  testWidgets('An old check completion after resume cannot replace the new native snapshot', (tester) async {
    final response = Completer<Map<String, Object?>>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'checkForUpdates') {
        bridge.calls.add(call.method);
        bridge.state = _status(phase: 'checking', checkStage: 'release');
        return response.future;
      }
      return bridge.handle(call);
    });
    await _withCard(tester, () async {
      await tester.tap(find.byKey(const Key('check_app_updates')));
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      bridge.state = _status(phase: 'ready', permission: true);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(find.byKey(const Key('install_app_update')), findsOneWidget);
      expect(tester.widget<FilledButton>(
          find.byKey(const Key('install_app_update'))).onPressed, isNull);

      response.complete(_status(phase: 'current'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('install_app_update')), findsOneWidget);
      expect(tester.widget<FilledButton>(
          find.byKey(const Key('install_app_update'))).onPressed, isNotNull);
      expect(find.text('Новых версий не найдено.'), findsNothing);
      expect(bridge.count('checkForUpdates'), 1);
      expect(bridge.count('installUpdate'), 0);
    });
  });

  testWidgets('The last successful check time remains historical during a failed recheck', (tester) async {
    final timestamp = DateTime(2026, 11, 22, 0, 35).millisecondsSinceEpoch;
    bridge.state = _status(phase: 'current', checkedAt: timestamp);
    bridge.checkGate = Completer<Map<String, Object?>>();
    await _withCard(tester, () async {
      const label = 'Последняя успешная проверка: 22.11.2026, 00:35';
      expect(find.text(label), findsOneWidget);
      expect(find.text('Новых версий не найдено.'), findsOneWidget);
      expect(find.textContaining('последняя опубликованная'), findsNothing);
      await tester.tap(find.byKey(const Key('check_app_updates')));
      await tester.pump();
      expect(find.text(label), findsOneWidget);
      expect(find.text('Новых версий не найдено.'), findsNothing);

      bridge.checkGate!.complete(_status(phase: 'error',
          error: 'UPDATE_METADATA_STALE', checkedAt: timestamp));
      await tester.pumpAndSettle();
      expect(find.text(label), findsOneWidget);
      expect(find.textContaining('Не удалось получить свежие сведения'), findsOneWidget);
      expect(find.text('Новых версий не найдено.'), findsNothing);
      expect(find.byKey(const Key('check_app_updates')), findsOneWidget);
    });
  });

  for (final phase in ['available', 'ready']) {
    testWidgets('A failed recheck retains the $phase action and previous check time', (tester) async {
      final timestamp = DateTime(2026, 11, 22, 0, 35).millisecondsSinceEpoch;
      bridge.state = _status(phase: phase, permission: true, checkedAt: timestamp);
      bridge.checkGate = Completer<Map<String, Object?>>();
      final primary = Key(phase == 'ready' ? 'install_app_update' : 'download_app_update');
      await _withCard(tester, () async {
        expect(find.byKey(primary), findsOneWidget);
        expect(find.byKey(const Key('check_app_updates')), findsOneWidget);
        await tester.tap(find.byKey(const Key('check_app_updates')));
        await tester.pump();
        bridge.checkGate!.complete(_status(phase: phase, permission: true,
            checkedAt: timestamp, error: 'UPDATE_METADATA_STALE'));
        await tester.pumpAndSettle();
        expect(find.byKey(primary), findsOneWidget);
        expect(tester.widget<FilledButton>(find.byKey(primary)).onPressed, isNotNull);
        expect(find.byKey(const Key('app_update_error')), findsOneWidget);
        expect(find.byKey(const Key('app_update_checked_at')), findsOneWidget);
        expect(bridge.count('checkForUpdates'), 1);
        expect(bridge.count('downloadUpdate'), 0);
        expect(bridge.count('installUpdate'), 0);
      });
    });
  }

  testWidgets('A first rate-limited check has no success timestamp or current claim', (tester) async {
    bridge.checkError = PlatformException(code: 'UPDATE_RATE_LIMITED',
        message: 'SECRET_NATIVE_DETAIL');
    await _withCard(tester, () async {
      await tester.tap(find.byKey(const Key('check_app_updates')));
      await tester.pumpAndSettle();
      expect(find.textContaining('временно ограничил проверки'), findsOneWidget);
      expect(find.textContaining('SECRET'), findsNothing);
      expect(find.byKey(const Key('app_update_checked_at')), findsNothing);
      expect(find.text('Новых версий не найдено.'), findsNothing);
      expect(find.byKey(const Key('check_app_updates')), findsOneWidget);
    });
  });

  for (final phase in ['checking', 'available', 'ready', 'installing']) {
    testWidgets('The $phase card fits 320 pixels with enlarged text', (tester) async {
      bridge.state = _status(phase: phase, permission: true,
          checkedAt: DateTime(2026, 11, 22, 0, 35).millisecondsSinceEpoch,
          checkStage: phase == 'checking' ? 'manifest' : null,
          error: phase == 'ready' ? 'UPDATE_METADATA_STALE' : null);
      await _withCard(tester, () async {
        expect(find.byKey(const Key('app_update_checked_at')), findsOneWidget);
        if (phase != 'checking' && phase != 'installing') {
          final check = find.byKey(const Key('check_app_updates'));
          await tester.ensureVisible(check);
          await tester.pumpAndSettle();
          expect(tester.getRect(check).width, lessThanOrEqualTo(320));
        }
        expect(tester.takeException(), isNull);
        expect(bridge.count('checkForUpdates'), 0);
      }, settle: phase != 'checking' && phase != 'installing',
        textScale: 2, size: const Size(320, 568));
    });
  }

  testWidgets('Network failures show a safe message and allow another check', (tester) async {
    bridge.checkError = PlatformException(code: 'UPDATE_NETWORK_ERROR',
        message: 'SECRET_NATIVE_DETAIL', details: 'https://SECRET.example');
    await _withCard(tester, () async {
      await tester.tap(find.byKey(const Key('check_app_updates')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app_update_error')), findsOneWidget);
      expect(find.textContaining('Проверьте интернет'), findsOneWidget);
      expect(find.textContaining('SECRET'), findsNothing);
      expect(find.text('Установлена версия 0.24.0'), findsOneWidget);

      bridge.checkError = null;
      await tester.tap(find.byKey(const Key('check_app_updates')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app_update_error')), findsNothing);
      expect(find.byKey(const Key('download_app_update')), findsOneWidget);
    });
  });

  for (final code in ['UPDATE_SIGNATURE_MISMATCH', 'SECRET_UNKNOWN_CODE']) {
    testWidgets('$code is safe and never suggests uninstalling the app', (tester) async {
      bridge.state = _status(phase: 'error', error: code);
      await _withCard(tester, () async {
        final message = tester.widget<Text>(
            find.byKey(const Key('app_update_error'))).data!;
        expect(message, isNot(contains('SECRET')));
        expect(message.toLowerCase(), allOf(
          isNot(contains('удалить')),
          isNot(contains('удаление')),
          isNot(contains('переустанов')),
        ));
        expect(find.byKey(const Key('install_app_update')), findsNothing);
        expect(find.byKey(const Key('check_app_updates')), findsOneWidget);
      });
    });
  }

  testWidgets('Unavailable compatibility metadata is an error rather than an unpublished release', (tester) async {
    bridge.state = {
      ..._status(phase: 'unavailable', error: 'UPDATE_INCOMPATIBLE'),
      'installedVersion': '0.0.0',
      'installedBuild': 0,
      'message': 'SECRET_NATIVE_DETAIL',
    };
    await _withCard(tester, () async {
      expect(find.byKey(const Key('app_update_error')), findsOneWidget);
      expect(find.textContaining('Не удалось проверить совместимость'), findsOneWidget);
      expect(find.text('Новая версия пока не опубликована.'), findsNothing);
      expect(find.byKey(const Key('installed_app_version')), findsNothing);
      expect(find.textContaining('SECRET'), findsNothing);
      expect(find.byKey(const Key('check_app_updates')), findsOneWidget);
      expect(find.byKey(const Key('download_app_update')), findsNothing);
      expect(find.byKey(const Key('install_app_update')), findsNothing);
    });
  });

  testWidgets('A compact non-Android layout is readable without contacting native code', (tester) async {
    await _withCard(tester, () async {
      await tester.binding.setSurfaceSize(const Size(320, 568));
      await tester.pumpAndSettle();
      expect(find.text('Обновления доступны в приложении Android.'), findsOneWidget);
      expect(find.byType(FilledButton), findsNothing);
      expect(bridge.calls, isEmpty);
      expect(tester.takeException(), isNull);
    }, isAndroid: false);
  });

  testWidgets('Installed changes and the recent history are available without a network check', (tester) async {
    bridge.state = _status(phase: 'current', automatic: false, permission: true,
      installedVersion: '0.59.0', installedBuild: 59);
    await _withCard(tester, () async {
      expect(find.byKey(const Key('current_release_notes')), findsOneWidget);
      expect(find.text('Что нового в установленной версии 0.59.0'), findsOneWidget);
      expect(find.text('Добавлено получение личной WireGuard-подписки через аккаунт Pushok и Shop без QR. Подключение не запускается автоматически.'), findsOneWidget);
      expect(find.byKey(const Key('available_release_notes')), findsNothing);
      expect(find.byKey(const ValueKey('history_release_53')), findsNothing);
      final history = find.byKey(const Key('app_release_history'));
      await tester.ensureVisible(history);
      await tester.tap(find.text('История обновлений'));
      await tester.pumpAndSettle();
      for (final build in [59, 58, 57, 56, 55]) {
        expect(find.byKey(ValueKey('history_release_$build')), findsOneWidget);
      }
      expect(bridge.count('checkForUpdates'), 0);
      expect(bridge.count('downloadUpdate'), 0);
      await tester.ensureVisible(history);
      await tester.tap(find.text('История обновлений'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('history_release_53')), findsNothing);
      expect(find.byKey(const Key('current_release_notes')), findsOneWidget);
    });
  });

  testWidgets('Newer release changes appear before download and remain distinct from installed changes', (tester) async {
    bridge.state = _status(phase: 'available', automatic: false, permission: true,
      installedVersion: '0.55.0', installedBuild: 55,
      availableVersion: '0.56.0', availableBuild: 56,
      releaseNotes: _notes(version: '0.56.0', build: 56, changes: ['Будущее изменение.', '<b>Обычный текст без HTML.</b>']));
    await _withCard(tester, () async {
      expect(find.text('Изменения в версии 0.56.0'), findsOneWidget);
      expect(find.text('Будущее изменение.'), findsOneWidget);
      expect(find.text('<b>Обычный текст без HTML.</b>'), findsOneWidget);
      expect(find.text('Опубликовано 23.11.2026'), findsOneWidget);
      expect(find.text('Что нового в установленной версии 0.55.0'), findsOneWidget);
      final notes = find.byKey(const Key('available_release_notes'));
      final download = find.byKey(const Key('download_app_update'));
      expect(tester.getBottomLeft(notes).dy, lessThan(tester.getTopLeft(download).dy));
      expect(tester.widget<FilledButton>(download).onPressed, isNotNull);
      expect(bridge.count('checkForUpdates'), 0);
      expect(bridge.count('downloadUpdate'), 0);
    });
  });

  testWidgets('Missing or mismatched notes do not borrow installed changes for a newer version', (tester) async {
    bridge.state = _status(phase: 'available', automatic: false, permission: true,
      installedVersion: '0.55.0', installedBuild: 55,
      availableVersion: '0.99.0', availableBuild: 99,
      releaseNotes: _notes(version: '0.55.0', build: 55, changes: ['Неверная версия описания.']));
    await _withCard(tester, () async {
      expect(find.byKey(const Key('available_release_notes_missing')), findsOneWidget);
      expect(find.byKey(const Key('available_release_notes')), findsNothing);
      expect(find.text('Неверная версия описания.'), findsNothing);
      expect(find.byKey(const Key('current_release_notes')), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const Key('download_app_update'))).onPressed, isNotNull);
    });
  });

  testWidgets('Matching bundled notes describe a newer release when older native metadata has no notes', (tester) async {
    bridge.state = _status(phase: 'available', automatic: false, permission: true,
      installedVersion: '0.55.0', installedBuild: 55,
      availableVersion: '0.56.0', availableBuild: 56);
    await _withCard(tester, () async {
      expect(find.text('Изменения в версии 0.56.0'), findsOneWidget);
      expect(find.text('Что нового в установленной версии 0.55.0'), findsOneWidget);
      expect(find.byKey(const Key('available_release_notes_missing')), findsNothing);
    });
  });

  testWidgets('A resumed update snapshot replaces descriptions and ignores an older delayed reply', (tester) async {
    final oldState = _status(phase: 'available', automatic: false, permission: true,
      installedVersion: '0.50.0', installedBuild: 50,
      availableVersion: '0.51.0', availableBuild: 51,
      releaseNotes: _notes(version: '0.51.0', build: 51, changes: ['Старое описание версии 51.']));
    bridge.state = oldState;
    await _withCard(tester, () async {
      final oldRead = Completer<Map<String, Object?>>();
      bridge.statusGate = oldRead;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      bridge.state = _status(phase: 'available', automatic: false, permission: true,
        installedVersion: '0.50.0', installedBuild: 50,
        availableVersion: '0.52.0', availableBuild: 52,
        releaseNotes: _notes(version: '0.52.0', build: 52, changes: ['Актуальное описание версии 52.']));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('Актуальное описание версии 52.'), findsOneWidget);
      oldRead.complete(oldState);
      await tester.pumpAndSettle();
      expect(find.text('Актуальное описание версии 52.'), findsOneWidget);
      expect(find.text('Старое описание версии 51.'), findsNothing);
      expect(find.text('Изменения в версии 0.51.0'), findsNothing);
      expect(bridge.count('checkForUpdates'), 0);
    });
  });

  testWidgets('Long notes and expanded history fit a narrow screen with enlarged text', (tester) async {
    bridge.state = _status(phase: 'available', automatic: false, permission: true,
      installedVersion: '0.55.0', installedBuild: 55,
      availableVersion: '0.56.0', availableBuild: 56,
      releaseNotes: _notes(version: '0.56.0', build: 56, changes: ['x' * 600, ...List.filled(7, 'Длинное описание изменения. ' * 17)]));
    await _withCard(tester, () async {
      expect(find.byKey(const Key('available_release_notes')), findsOneWidget);
      expect(tester.takeException(), isNull);
      final download = find.byKey(const Key('download_app_update'));
      await tester.ensureVisible(download);
      await tester.pumpAndSettle();
      expect(tester.getRect(download).width, lessThanOrEqualTo(320));
      await tester.ensureVisible(find.byKey(const Key('app_release_history')));
      await tester.tap(find.text('История обновлений'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('history_release_55')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(bridge.count('downloadUpdate'), 0);
    }, textScale: 2, size: const Size(320, 568));
  });
}
