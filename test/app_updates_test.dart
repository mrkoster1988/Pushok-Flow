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
}) => {
  'installedVersion': '0.24.0',
  'installedBuild': 24,
  'phase': phase,
  if (['available', 'downloading', 'ready'].contains(phase)) ...{
    'availableVersion': '0.25.0',
    'availableBuild': 25,
  },
  'downloadedBytes': downloaded,
  'totalBytes': total,
  'installPermissionGranted': permission,
  'errorCode': error,
};

class _UpdatesBridge {
  Map<String, Object?> state = _status();
  final calls = <String>[];
  Completer<Map<String, Object?>>? checkGate;
  Completer<Map<String, Object?>>? downloadGate;
  Completer<Map<String, Object?>>? statusGate;
  PlatformException? checkError;

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
        state = checkGate == null
            ? _status(phase: 'available') : await checkGate!.future;
        return state;
      case 'downloadUpdate':
        state = _status(phase: 'downloading', total: 4096);
        state = downloadGate == null
            ? _status(phase: 'ready') : await downloadGate!.future;
        return state;
      case 'openInstallPermission':
      case 'installUpdate':
        return Map<String, Object?>.of(state);
      default:
        throw MissingPluginException(call.method);
    }
  }
}

Future<void> _withCard(WidgetTester tester,
    Future<void> Function() body, {bool isAndroid = true, bool settle = true}) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.binding.setSurfaceSize(const Size(390, 844));
  await tester.pumpWidget(MaterialApp(
    theme: buildPushokTheme(),
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
      {..._status(), 'totalBytes': -1},
    ];
    for (final data in invalid) {
      expect(() => UpdateStatus.fromMap(data), throwsFormatException);
    }
    expect(() => UpdateStatus.fromMap(null), throwsFormatException);
  });

  test('Unknown error codes are normalized without retaining exception text', () {
    final status = UpdateStatus.fromMap({
      ..._status(phase: 'error', error: 'SECRET_NATIVE_DETAIL'),
      'message': 'SECRET_NATIVE_DETAIL',
      'details': 'SECRET_NATIVE_DETAIL',
    });
    expect(status.errorCode, 'UPDATE_UNKNOWN');
  });

  test('Unsupported platforms never invoke update or installer channels', () async {
    final updates = AppUpdates(isAndroid: false);
    for (final status in await Future.wait([
      updates.updateStatus(),
      updates.checkForUpdates(),
      updates.downloadUpdate(),
      updates.openInstallPermission(),
      updates.installUpdate(),
    ])) {
      expect(status.phase, UpdatePhase.unavailable);
      expect(status.errorCode, 'UNSUPPORTED_PLATFORM');
    }
    expect(bridge.calls, isEmpty);
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

  testWidgets('Checking, downloading, permission and installation require separate taps', (tester) async {
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

  testWidgets('Download polling pauses in background and stops when the APK is ready', (tester) async {
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
      expect(bridge.count('updateStatus'), completedReads);
      expect(bridge.count('downloadUpdate'), 0);
      expect(bridge.count('installUpdate'), 0);
    });
  });

  testWidgets('Reopening an ongoing check offers a refresh without automatically checking again', (tester) async {
    bridge.state = _status(phase: 'checking');
    await _withCard(tester, () async {
      expect(find.byKey(const Key('refresh_app_update_status')), findsOneWidget);
      final initialReads = bridge.count('updateStatus');
      await tester.pump(const Duration(seconds: 5));
      expect(bridge.count('updateStatus'), initialReads);
      bridge.state = _status(phase: 'available');
      await tester.tap(find.byKey(const Key('refresh_app_update_status')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('download_app_update')), findsOneWidget);
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
}
