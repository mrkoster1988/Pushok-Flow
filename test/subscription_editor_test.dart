import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pushok_flow/design/pushok_theme.dart';
import 'package:pushok_flow/platform/subscription_diagnostics.dart';
import 'package:pushok_flow/platform/subscriptions.dart';
import 'package:pushok_flow/ui/subscription_editor.dart';
import 'package:pushok_flow/ui/wireguard_profile_editor.dart';

// Synthetic documentation addresses only; these widgets never make a request.
const _oldUrl = 'https://198.51.100.53/sub/OLD_SYNTHETIC_TOKEN';
const _qrUrl = 'https://198.51.100.54:2096/sub/QR_SYNTHETIC_TOKEN?key=a%2Bb+c';
const _newerUrl = 'https://198.51.100.55/sub/NEWER_SYNTHETIC_TOKEN';
const _draftName = 'Мой провайдер';
const _vless = 'vless://00000000-0000-4000-8000-000000000001@198.51.100.53:443'
    '?type=tcp&security=tls&sni=example.invalid#SYNTHETIC_PROFILE_SECRET';
const _wireguard = '[Interface]\nPrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n'
    'Address = 10.0.0.2/32\n[Peer]\nPublicKey = BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=\n'
    'AllowedIPs = 0.0.0.0/0\nEndpoint = 198.51.100.53:51820\n';
const _url = Key('subscription_url');
const _name = Key('subscription_name');
const _camera = Key('scan_subscription_qr');
const _photo = Key('import_subscription_qr_image');
const _paste = Key('paste_subscription_url');
const _save = Key('save_subscription');
const _close = Key('close_subscription_editor');
const _reveal = Key('toggle_subscription_url_visibility');
const _error = Key('subscription_editor_error');
const _notice = Key('subscription_editor_notice');
const _copyError = Key('copy_subscription_error');
const _copyNotice = Key('subscription_error_copy_notice');
const _openProfile = Key('open_imported_profile');
const _discardProfile = Key('discard_imported_profile');
const _profileField = Key('wireguard_profile_field');
const _profileSave = Key('save_wireguard_profile');
const _profileBack = Key('close_wireguard_profile');

void _resume(WidgetTester tester) {
  if (tester.binding.lifecycleState == AppLifecycleState.paused) {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  }
  if (tester.binding.lifecycleState == AppLifecycleState.hidden) {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  }
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
}

Future<void> _open(
  WidgetTester tester, {
  SubscriptionDraft? draft = const SubscriptionDraft(url: _oldUrl, name: _draftName),
  required Future<void> Function(String url, String name) onSave,
  Future<String?> Function()? onScanQr,
  Future<String?> Function()? onImportQrImage,
  Future<void> Function()? onCancelImport,
  ValueChanged<bool?>? onResult,
  double textScale = 1,
  SubscriptionDiagnosticSource initialSource = SubscriptionDiagnosticSource.manualInput,
  Widget Function(String, VoidCallback, VoidCallback)? profileEditorBuilder,
}) async {
  _resume(tester);
  await tester.pumpWidget(MaterialApp(
    theme: buildPushokTheme(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: Scaffold(body: Builder(builder: (context) => Center(child: TextButton(
      onPressed: () async {
        final result = await showModalBottomSheet<bool>(
          context: context, isScrollControlled: true, useSafeArea: true,
          isDismissible: false, enableDrag: false,
          builder: (_) => SubscriptionEditor(
            draft: draft, initialSource: initialSource, onSave: onSave, onScanQr: onScanQr,
            onImportQrImage: onImportQrImage, onCancelImport: onCancelImport,
            profileEditorBuilder: profileEditorBuilder,
          ),
        );
        onResult?.call(result);
      },
      child: const Text('Открыть подписку'),
    )))),
  ));
  await tester.tap(find.text('Открыть подписку'));
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Key key) async {
  final finder = find.byKey(key);
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
}

TextField _field(WidgetTester tester, Key key) =>
    tester.widget<TextField>(find.byKey(key));

void _expectMaskedDraft(WidgetTester tester, String value,
    [String name = _draftName]) {
  final field = _field(tester, _url);
  expect(field.controller!.text, value);
  expect(field.obscureText, isTrue);
  expect(field.readOnly, isTrue);
  expect(field.enableInteractiveSelection, isFalse);
  expect(_field(tester, _name).controller!.text, name);
}

void _mockClipboard(Future<Object?> Function(MethodCall call) handler) {
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, handler);
  addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
}

void main() {
  for (final source in [
    ('camera', _camera, _vless), ('photo', _photo, _wireguard),
    ('clipboard', _paste, _vless), ('manual', _save, _vless),
  ]) {
    testWidgets('Reverse profile ${source.$1} handoff stays private until a separate explicit save',
        (tester) async {
      var subscriptions = 0;
      var builds = 0;
      final profiles = <(String, String)>[];
      final results = <bool?>[];
      final writes = <String>[];
      _mockClipboard((call) async {
        if (call.method == 'Clipboard.getData') return {'text': source.$3};
        if (call.method == 'Clipboard.setData') writes.add((call.arguments as Map)['text'] as String);
        return null;
      });
      await _open(tester,
        onSave: (_, _) async { subscriptions++; },
        onScanQr: () async => source.$3,
        onImportQrImage: () async => source.$3,
        onResult: results.add,
        profileEditorBuilder: (config, close, completed) {
          builds++;
          return WireGuardProfileEditor(
            key: const Key('subscription_profile_editor'),
            initialConfig: config, onClose: close, onCompleted: completed,
            onSave: (config, name) async => profiles.add((config, name)),
          );
        },
      );
      if (source.$1 == 'manual') {
        await _tap(tester, _reveal);
        await tester.enterText(find.byKey(_url), source.$3);
      }
      await _tap(tester, source.$2);
      await tester.pumpAndSettle();
      _expectMaskedDraft(tester, source.$1 == 'manual' ? source.$3 : _oldUrl);
      expect(find.byKey(_openProfile), findsOneWidget);
      expect(find.byKey(_copyError), findsNothing);
      expect(builds, 0);
      expect(profiles, isEmpty);
      expect(subscriptions, 0);
      expect(writes, isEmpty);
      expect(tester.widget<FilledButton>(find.byKey(_save)).onPressed, isNull);
      expect(find.byWidgetPredicate((widget) => widget is Text &&
        ['SYNTHETIC_PROFILE_SECRET', 'PrivateKey', '198.51.100.53:443']
          .any((secret) => (widget.data ?? widget.textSpan?.toPlainText() ?? '').contains(secret))),
        findsNothing);
      await _tap(tester, _openProfile);
      await tester.pumpAndSettle();
      final field = _field(tester, _profileField);
      expect(field.controller!.text, source.$3);
      expect(field.obscureText, isTrue);
      expect(field.enableInteractiveSelection, isFalse);
      expect(profiles, isEmpty);
      expect(results, isEmpty);
      await _tap(tester, _profileSave);
      await tester.pumpAndSettle();
      expect(profiles, [(source.$3, 'Мой профиль')]);
      expect(subscriptions, 0);
      expect(results, [true]);
      expect(writes, isEmpty);
      expect(find.byType(SubscriptionEditor), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final systemBack in [false, true]) {
    testWidgets('Reverse profile ${systemBack ? 'system back' : 'back button'} restores the subscription draft and rejects old actions',
        (tester) async {
      var saves = 0;
      final results = <bool?>[];
      final childCallbacks = <(VoidCallback, VoidCallback)>[];
      await _open(tester,
        onSave: (_, _) async { saves++; },
        onScanQr: () async => _vless,
        onResult: results.add,
        profileEditorBuilder: (config, close, completed) {
          childCallbacks.add((close, completed));
          return WireGuardProfileEditor(
            initialConfig: config, onClose: close, onCompleted: completed,
            onSave: (_, _) async { saves++; },
          );
        },
      );
      final oldSubscriptionSave = tester.widget<FilledButton>(find.byKey(_save)).onPressed!;
      final oldSubscriptionClose = tester.widget<IconButton>(find.byKey(_close)).onPressed!;
      await _tap(tester, _camera);
      final oldOpen = tester.widget<OutlinedButton>(find.byKey(_openProfile)).onPressed!;
      await _tap(tester, _openProfile);
      await tester.pumpAndSettle();
      oldSubscriptionSave();
      oldSubscriptionClose();
      final oldSave = tester.widget<FilledButton>(find.byKey(_profileSave)).onPressed!;
      final oldClose = tester.widget<IconButton>(find.byKey(_profileBack)).onPressed!;
      if (systemBack) {
        await tester.binding.handlePopRoute();
      } else {
        oldClose();
      }
      // Before the parent's next frame, the old child still exists but is closed.
      oldSave();
      oldClose();
      oldOpen();
      await tester.pumpAndSettle();
      _expectMaskedDraft(tester, _oldUrl);
      expect(find.byKey(_openProfile), findsOneWidget);
      expect(find.byType(WireGuardProfileEditor), findsNothing);
      expect(saves, 0);
      expect(results, isEmpty);
      final firstChild = childCallbacks.first;
      await _tap(tester, _openProfile);
      await tester.pumpAndSettle();
      firstChild.$1();
      firstChild.$2();
      await tester.pump();
      expect(find.byType(WireGuardProfileEditor), findsOneWidget);
      expect(results, isEmpty);
      await _tap(tester, _profileBack);
      await tester.pumpAndSettle();
      _expectMaskedDraft(tester, _oldUrl);
      await _tap(tester, _discardProfile);
      oldOpen();
      await tester.pumpAndSettle();
      expect(find.byKey(_openProfile), findsNothing);
      expect(tester.widget<FilledButton>(find.byKey(_save)).onPressed, isNotNull);
      expect(saves, 0);
      await _tap(tester, _close);
      await tester.pumpAndSettle();
      expect(results, [null]);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Reverse profile offer invalidates captured actions on input import failure and lifecycle changes',
      (tester) async {
    final laterQr = Completer<String?>();
    var reads = 0;
    var builds = 0;
    addTearDown(() => _resume(tester));
    await _open(tester,
      onSave: (_, _) async => fail('A subscription must not be saved'),
      onScanQr: () async => _vless,
      onImportQrImage: () => ++reads == 1 ? laterQr.future
          : Future.error(PlatformException(code: 'PROFILE_QR_NOT_FOUND', message: _vless)),
      profileEditorBuilder: (config, close, completed) {
        builds++;
        return WireGuardProfileEditor(initialConfig: config,
          onClose: close, onCompleted: completed,
          onSave: (_, _) async => fail('A profile must not be saved'));
      },
    );
    await _tap(tester, _camera);
    final beforeEdit = tester.widget<OutlinedButton>(find.byKey(_openProfile)).onPressed!;
    _field(tester, _name).onChanged!('Changed');
    beforeEdit();
    await tester.pump();
    expect(builds, 0);
    expect(find.byKey(_openProfile), findsNothing);
    await _tap(tester, _camera);
    final beforeImport = tester.widget<OutlinedButton>(find.byKey(_openProfile)).onPressed!;
    await _tap(tester, _photo);
    beforeImport();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    laterQr.complete(_wireguard);
    await tester.pumpAndSettle();
    _expectMaskedDraft(tester, _oldUrl);
    expect(tester.widget<OutlinedButton>(find.byKey(_openProfile)).onPressed, isNull);
    beforeImport();
    _resume(tester);
    await tester.pump();
    beforeImport();
    expect(builds, 0);
    final beforeBackground = tester.widget<OutlinedButton>(find.byKey(_openProfile)).onPressed!;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    beforeBackground();
    _resume(tester);
    beforeBackground();
    await tester.pump();
    expect(builds, 0);
    final beforeFailure = tester.widget<OutlinedButton>(find.byKey(_openProfile)).onPressed!;
    await _tap(tester, _photo);
    await tester.pumpAndSettle();
    beforeFailure();
    await tester.pump();
    expect(find.byKey(_error), findsOneWidget);
    expect(find.byKey(_openProfile), findsNothing);
    expect(builds, 0);
    expect(find.textContaining('SYNTHETIC_PROFILE_SECRET'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Reverse profile cancellation and unsupported or oversized QR values clear the offer without changing the draft',
      (tester) async {
    String? value = _vless;
    var builds = 0;
    await _open(tester,
      onSave: (_, _) async => fail('No save expected'),
      onScanQr: () async => value,
      profileEditorBuilder: (_, _, _) { builds++; return const SizedBox.shrink(); },
    );
    for (final invalid in <String?>[
      null, 'vless://${'x' * 65537}', 'vmess://SYNTHETIC_UNSUPPORTED',
      'trojan://SYNTHETIC_UNSUPPORTED', '[Interfaces]\nPrivateKey = SYNTHETIC_UNSUPPORTED',
    ]) {
      value = _vless;
      await _tap(tester, _camera);
      final oldOpen = tester.widget<OutlinedButton>(find.byKey(_openProfile)).onPressed!;
      value = invalid;
      await _tap(tester, _camera);
      await tester.pumpAndSettle();
      oldOpen();
      await tester.pump();
      _expectMaskedDraft(tester, _oldUrl);
      expect(find.byKey(_openProfile), findsNothing);
      expect(find.byKey(_error), invalid == null ? findsNothing : findsOneWidget);
      expect(builds, 0);
      expect(find.textContaining('SYNTHETIC_UNSUPPORTED'), findsNothing);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('Reverse profile save blocks back and duplicate callbacks until native completion',
      (tester) async {
    final pending = Completer<void>();
    var saves = 0;
    final results = <bool?>[];
    await _open(tester,
      onSave: (_, _) async => fail('No subscription save expected'),
      onScanQr: () async => _vless, onResult: results.add,
      profileEditorBuilder: (config, close, completed) => WireGuardProfileEditor(
        initialConfig: config, onClose: close, onCompleted: completed,
        onSave: (_, _) { saves++; return pending.future; },
      ),
    );
    await _tap(tester, _camera);
    await _tap(tester, _openProfile);
    final save = tester.widget<FilledButton>(find.byKey(_profileSave)).onPressed!;
    final back = tester.widget<IconButton>(find.byKey(_profileBack)).onPressed!;
    save();
    back();
    save();
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(WireGuardProfileEditor), findsOneWidget);
    expect(saves, 1);
    expect(results, isEmpty);
    expect(tester.widget<IconButton>(find.byKey(_profileBack)).onPressed, isNull);
    pending.complete();
    await tester.pumpAndSettle();
    expect(results, [true]);
    expect(tester.takeException(), isNull);
  });

  for (final source in [('camera', _camera), ('photo', _photo)]) {
    testWidgets(source.$1 + ' fills only the masked subscription draft until explicit save',
        (tester) async {
      final saved = <(String, String)>[];
      final results = <bool?>[];
      var cameraReads = 0;
      var photoReads = 0;
      await _open(tester,
        onScanQr: () async { cameraReads++; return _qrUrl; },
        onImportQrImage: () async { photoReads++; return _qrUrl; },
        onSave: (url, name) async => saved.add((url, name)),
        onResult: results.add,
      );
      await _tap(tester, source.$2);
      await tester.pumpAndSettle();
      expect(cameraReads, source.$2 == _camera ? 1 : 0);
      expect(photoReads, source.$2 == _photo ? 1 : 0);
      _expectMaskedDraft(tester, _qrUrl);
      expect(_field(tester, _url).controller!.selection.isValid, isFalse);
      expect(_field(tester, _url).controller!.value.composing, TextRange.empty);
      expect(find.byKey(_notice), findsOneWidget);
      expect(find.text('Источник серверов: 198.51.100.54'), findsOneWidget);
      // Text finders also inspect an obscured EditableText's private controller.
      expect(find.byWidgetPredicate((widget) => widget is Text &&
        (widget.data ?? widget.textSpan?.toPlainText() ?? '').contains('QR_SYNTHETIC_TOKEN')),
        findsNothing);
      expect(saved, isEmpty);
      expect(results, isEmpty);
      await _tap(tester, _save);
      await tester.pumpAndSettle();
      expect(saved, [(_qrUrl, _draftName)]);
      expect(results, [true]);
      expect(find.byType(SubscriptionEditor), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Cancelling ' + source.$1 + ' preserves typed values and hides the link',
        (tester) async {
      var saves = 0;
      var cancels = 0;
      await _open(tester,
        onScanQr: () async => null,
        onImportQrImage: () async => null,
        onCancelImport: () async { cancels++; },
        onSave: (_, _) async { saves++; },
      );
      await _tap(tester, _reveal);
      await tester.enterText(find.byKey(_url), _newerUrl);
      await tester.enterText(find.byKey(_name), 'Изменённое название');
      await _tap(tester, source.$2);
      await tester.pumpAndSettle();
      _expectMaskedDraft(tester, _newerUrl, 'Изменённое название');
      expect(find.byKey(_error), findsNothing);
      expect(find.byKey(_notice), findsNothing);
      expect(saves, 0);
      expect(cancels, 0);
      expect(tester.widget<OutlinedButton>(find.byKey(source.$2)).onPressed, isNotNull);
      await _tap(tester, _close);
      await tester.pumpAndSettle();
      expect(cancels, 0);
      expect(tester.takeException(), isNull);
    });

    for (final resultBeforeResume in [true, false]) {
      testWidgets(source.$1 + ' result ' +
          (resultBeforeResume ? 'before' : 'after') +
          ' resume survives native activity switching without automatic save',
          (tester) async {
        final reply = Completer<String?>();
        var saves = 0;
        var cancels = 0;
        addTearDown(() => _resume(tester));
        await _open(tester,
          onScanQr: () => reply.future, onImportQrImage: () => reply.future,
          onCancelImport: () async { cancels++; },
          onSave: (url, name) async {
            expect(url, _qrUrl);
            expect(name, _draftName);
            saves++;
          },
        );
        final queuedSave = tester.widget<FilledButton>(find.byKey(_save)).onPressed!;
        final queuedReveal = tester.widget<IconButton>(find.byKey(_reveal)).onPressed!;
        await _tap(tester, source.$2);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        if (resultBeforeResume) {
          reply.complete(_qrUrl);
          await tester.pumpAndSettle();
          _expectMaskedDraft(tester, _qrUrl);
          expect(_field(tester, _url).enabled, isFalse);
          expect(_field(tester, _name).enabled, isFalse);
          expect(tester.widget<FilledButton>(find.byKey(_save)).onPressed, isNull);
          queuedSave();
          queuedReveal();
          await tester.pump();
          _expectMaskedDraft(tester, _qrUrl);
          expect(saves, 0);
        }
        _resume(tester);
        await tester.pump();
        if (!resultBeforeResume) reply.complete(_qrUrl);
        await tester.pumpAndSettle();
        _expectMaskedDraft(tester, _qrUrl);
        expect(saves, 0);
        expect(cancels, 0);
        expect(tester.widget<FilledButton>(find.byKey(_save)).onPressed, isNotNull);
        await _tap(tester, _save);
        await tester.pumpAndSettle();
        expect(saves, 1);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('QR failures preserve the draft, expose fixed guidance and allow a retry',
      (tester) async {
    final failures = <(Key, Object, String)>[
      (_camera, PlatformException(code: 'PROFILE_QR_CAMERA_DENIED',
        message: 'PRIVATE_NATIVE_DETAILS', details: _qrUrl), 'доступ к камере'),
      (_photo, PlatformException(code: 'PROFILE_QR_NOT_FOUND',
        message: 'PRIVATE_NATIVE_DETAILS', details: _qrUrl), 'не найден QR-код'),
      (_photo, PlatformException(code: 'PROFILE_QR_MULTIPLE',
        message: 'PRIVATE_NATIVE_DETAILS', details: _qrUrl), 'один полный QR-код'),
      (_camera, PlatformException(code: 'PROFILE_IMPORT_TIMEOUT',
        message: 'PRIVATE_NATIVE_DETAILS', details: _qrUrl), 'не ответил вовремя'),
      (_photo, PlatformException(code: 'PROFILE_IMPORT_SOURCE_BUSY',
        message: 'PRIVATE_NATIVE_DETAILS', details: _qrUrl), 'Источник фото пока занят'),
      (_photo, const FormatException('PRIVATE_NATIVE_DETAILS ' + _qrUrl), 'Не удалось прочитать QR-код'),
      (_camera, StateError('PRIVATE_NATIVE_DETAILS ' + _qrUrl), 'Не удалось прочитать QR-код'),
    ];
    for (final failure in failures) {
      var reads = 0;
      var saves = 0;
      Future<String?> read() async {
        if (++reads == 1) throw failure.$2;
        return _qrUrl;
      }
      await _open(tester, onScanQr: read, onImportQrImage: read,
        onSave: (_, _) async { saves++; });
      await _tap(tester, failure.$1);
      await tester.pumpAndSettle();
      _expectMaskedDraft(tester, _oldUrl);
      final message = tester.widget<Text>(find.byKey(_error)).data!;
      expect(message, contains(failure.$3));
      expect(message, isNot(contains('PRIVATE_NATIVE_DETAILS')));
      expect(message, isNot(contains('SYNTHETIC_TOKEN')));
      expect(find.byKey(_notice), findsNothing);
      expect(tester.widget<OutlinedButton>(find.byKey(failure.$1)).onPressed, isNotNull);
      await _tap(tester, failure.$1);
      await tester.pumpAndSettle();
      expect(reads, 2);
      _expectMaskedDraft(tester, _qrUrl);
      expect(find.byKey(_error), findsNothing);
      expect(find.byKey(_notice), findsOneWidget);
      expect(saves, 0);
      await _tap(tester, _close);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('Single profiles and non-subscription links never replace the subscription draft',
      (tester) async {
    for (final input in [
      (_vless, 'Это QR-код отдельного подключения'),
      (_wireguard, 'Это QR-код отдельного подключения'),
      ('http://198.51.100.54/sub/QR_SYNTHETIC_TOKEN', 'полной HTTPS-ссылкой'),
      ('https://t.me/proxy?server=198.51.100.54&port=443&secret=SYNTHETIC_PROFILE_SECRET',
        'ссылка прокси Telegram'),
    ]) {
      var saves = 0;
      await _open(tester, onScanQr: () async => input.$1,
        onSave: (_, _) async { saves++; });
      await _tap(tester, _camera);
      await tester.pumpAndSettle();
      _expectMaskedDraft(tester, _oldUrl);
      final message = tester.widget<Text>(find.byKey(_error)).data!;
      expect(message, contains(input.$2));
      expect(message, isNot(contains('SYNTHETIC_PROFILE_SECRET')));
      expect(message, isNot(contains('SYNTHETIC_TOKEN')));
      expect(message, isNot(contains('PrivateKey')));
      expect(find.byKey(_notice), findsNothing);
      expect(saves, 0);
      await _tap(tester, _close);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('Pending QR and saving reject duplicate imports and stale competing callbacks',
      (tester) async {
    final qr = Completer<String?>();
    final saved = Completer<void>();
    var cameraReads = 0;
    var photoReads = 0;
    var clipboardReads = 0;
    var saves = 0;
    var cancels = 0;
    _mockClipboard((call) async {
      if (call.method == 'Clipboard.getData') {
        clipboardReads++;
        return {'text': _newerUrl};
      }
      return null;
    });
    await _open(tester,
      onScanQr: () { cameraReads++; return qr.future; },
      onImportQrImage: () async { photoReads++; return _newerUrl; },
      onCancelImport: () async { cancels++; },
      onSave: (url, name) { saves++; expect(url, _qrUrl); return saved.future; },
    );
    final camera = tester.widget<OutlinedButton>(find.byKey(_camera)).onPressed!;
    final photo = tester.widget<OutlinedButton>(find.byKey(_photo)).onPressed!;
    final paste = tester.widget<OutlinedButton>(find.byKey(_paste)).onPressed!;
    final save = tester.widget<FilledButton>(find.byKey(_save)).onPressed!;
    final reveal = tester.widget<IconButton>(find.byKey(_reveal)).onPressed!;
    final close = tester.widget<IconButton>(find.byKey(_close)).onPressed!;
    camera();
    camera();
    photo();
    paste();
    save();
    reveal();
    await tester.pump();
    expect(cameraReads, 1);
    expect(photoReads, 0);
    expect(clipboardReads, 0);
    expect(saves, 0);
    for (final key in [_camera, _photo, _paste]) {
      expect(tester.widget<OutlinedButton>(find.byKey(key)).onPressed, isNull);
    }
    expect(_field(tester, _url).enabled, isFalse);
    expect(_field(tester, _name).enabled, isFalse);
    expect(tester.widget<FilledButton>(find.byKey(_save)).onPressed, isNull);
    expect(tester.widget<IconButton>(find.byKey(_reveal)).onPressed, isNull);
    expect(tester.widget<IconButton>(find.byKey(_close)).onPressed, isNotNull);
    qr.complete(_qrUrl);
    await tester.pumpAndSettle();
    expect(saves, 0);
    await _tap(tester, _save);
    camera();
    photo();
    paste();
    save();
    reveal();
    close();
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(saves, 1);
    expect(cameraReads, 1);
    expect(photoReads, 0);
    expect(clipboardReads, 0);
    expect(cancels, 0);
    expect(find.byType(SubscriptionEditor), findsOneWidget);
    expect(find.text('Загружаем серверы…'), findsOneWidget);
    expect(tester.widget<IconButton>(find.byKey(_close)).onPressed, isNull);
    _expectMaskedDraft(tester, _qrUrl);
    saved.complete();
    await tester.pumpAndSettle();
    expect(find.byType(SubscriptionEditor), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final back in [false, true]) {
    testWidgets((back ? 'System back' : 'Close button') +
        ' cancels one pending import and rejects its reply in a later editor',
        (tester) async {
      final reply = Completer<String?>();
      var cancels = 0;
      var saves = 0;
      final results = <bool?>[];
      await _open(tester,
        onScanQr: () => reply.future,
        onCancelImport: () async { cancels++; },
        onSave: (_, _) async { saves++; },
        onResult: results.add,
      );
      final oldSave = tester.widget<FilledButton>(find.byKey(_save)).onPressed!;
      final oldClose = tester.widget<IconButton>(find.byKey(_close)).onPressed!;
      await _tap(tester, _camera);
      if (back) {
        await tester.binding.handlePopRoute();
      } else {
        oldClose();
        oldClose();
      }
      await tester.pumpAndSettle();
      expect(cancels, 1);
      expect(results, [null]);
      await _open(tester, draft: const SubscriptionDraft(url: _newerUrl, name: 'Новый черновик'),
        onSave: (_, _) async { saves++; });
      if (back) {
        reply.completeError(PlatformException(code: 'PROFILE_QR_NOT_FOUND',
          message: 'PRIVATE_LATE_ERROR', details: _qrUrl));
      } else {
        reply.complete(_qrUrl);
      }
      oldSave();
      oldClose();
      await tester.pumpAndSettle();
      _expectMaskedDraft(tester, _newerUrl, 'Новый черновик');
      expect(find.byKey(_error), findsNothing);
      expect(find.byKey(_notice), findsNothing);
      expect(find.textContaining('PRIVATE_LATE_ERROR'), findsNothing);
      expect(saves, 0);
      expect(cancels, 1);
      expect(results, [null]);
      await _tap(tester, _close);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Unmount cancels once and absorbs native cancellation and late-result failures',
      (tester) async {
    final reply = Completer<String?>();
    var cancels = 0;
    var saves = 0;
    await _open(tester,
      onImportQrImage: () => reply.future,
      onCancelImport: () async { cancels++; throw StateError('PRIVATE_CANCEL_FAILURE'); },
      onSave: (_, _) async { saves++; },
    );
    await _tap(tester, _photo);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(cancels, 1);
    reply.completeError(PlatformException(code: 'PROFILE_IMPORT_INTERRUPTED',
      message: 'PRIVATE_LATE_ERROR', details: _qrUrl));
    await tester.pumpAndSettle();
    expect(cancels, 1);
    expect(saves, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Manual URL paste and editing still require explicit confirmation',
      (tester) async {
    var clipboardReads = 0;
    var qrReads = 0;
    final saved = <(String, String)>[];
    _mockClipboard((call) async {
      if (call.method == 'Clipboard.getData') {
        clipboardReads++;
        return {'text': '  $_qrUrl  '};
      }
      return null;
    });
    await _open(tester, draft: null,
      onScanQr: () async { qrReads++; return _qrUrl; },
      onImportQrImage: () async { qrReads++; return _qrUrl; },
      onSave: (url, name) async => saved.add((url, name)),
    );
    await _tap(tester, _paste);
    await tester.pumpAndSettle();
    _expectMaskedDraft(tester, _qrUrl, 'Моя подписка');
    expect(clipboardReads, 1);
    expect(saved, isEmpty);
    await _tap(tester, _reveal);
    await tester.enterText(find.byKey(_url), _newerUrl);
    await tester.enterText(find.byKey(_name), 'Вручную');
    await _tap(tester, _save);
    await tester.pumpAndSettle();
    expect(saved, [(_newerUrl, 'Вручную')]);
    expect(qrReads, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('A clipboard reply from before app switching cannot replace the draft',
      (tester) async {
    final clipboard = Completer<Object?>();
    var saves = 0;
    addTearDown(() => tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed));
    _mockClipboard((call) async =>
      call.method == 'Clipboard.getData' ? clipboard.future : null);
    await _open(tester, onScanQr: () async => _qrUrl,
      onSave: (_, _) async { saves++; });
    await _tap(tester, _paste);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    clipboard.complete({'text': _newerUrl});
    await tester.pumpAndSettle();
    _expectMaskedDraft(tester, _oldUrl);
    expect(find.byKey(_error), findsNothing);
    await _tap(tester, _camera);
    await tester.pumpAndSettle();
    _expectMaskedDraft(tester, _qrUrl);
    expect(saves, 0);
    await _tap(tester, _close);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  for (final source in [(_camera, 'Камера QR'), (_photo, 'QR из фото')]) {
    testWidgets('Subscription ${source.$2} failure copies only fixed diagnostics after a tap',
        (tester) async {
      final writes = <String>[];
      _mockClipboard((call) async {
        if (call.method == 'Clipboard.setData') writes.add((call.arguments as Map)['text'] as String);
        return null;
      });
      Future<String?> failRead() async => throw PlatformException(code: 'PROFILE_QR_NOT_FOUND',
        message: 'PRIVATE_EXCEPTION $_qrUrl', details: {'name': _draftName, 'config': _vless});
      await _open(tester, onSave: (_, _) async {}, onScanQr: failRead, onImportQrImage: failRead);
      expect(find.byKey(_copyError), findsNothing);
      await _tap(tester, source.$1);
      await tester.pumpAndSettle();
      expect(writes, isEmpty);
      expect(find.byKey(_copyError), findsOneWidget);
      await _tap(tester, _copyError);
      await tester.pumpAndSettle();
      expect(writes.single, startsWith('Pushok Flow — ошибка подписки\nВерсия: '));
      expect(writes.single, contains('Источник: ${source.$2}'));
      expect(writes.single, contains('Код: PROFILE_QR_NOT_FOUND'));
      for (final value in [_oldUrl, _qrUrl, _draftName, 'PRIVATE_EXCEPTION', '198.51.100.', 'vless://']) {
        expect(writes.single, isNot(contains(value)));
      }
      expect(find.text('Отчёт скопирован.'), findsOneWidget);
      _expectMaskedDraft(tester, _oldUrl);
    });
  }

  for (final source in [
    ('manual', 'Ввод вручную'), ('external', 'Внешняя ссылка'),
    ('camera', 'Камера QR'), ('photo', 'QR из фото'),
    ('clipboard', 'Буфер обмена'), ('edited', 'Ввод вручную'),
  ]) {
    testWidgets('Subscription load failure preserves ${source.$1} input provenance',
        (tester) async {
      final writes = <String>[];
      _mockClipboard((call) async {
        if (call.method == 'Clipboard.setData') writes.add((call.arguments as Map)['text'] as String);
        if (call.method == 'Clipboard.getData') return {'text': _qrUrl};
        return null;
      });
      await _open(tester,
        initialSource: source.$1 == 'external'
            ? SubscriptionDiagnosticSource.externalLink : SubscriptionDiagnosticSource.manualInput,
        onScanQr: () async => _qrUrl, onImportQrImage: () async => _qrUrl,
        onSave: (_, _) async => throw PlatformException(code: 'SUBSCRIPTION_TLS_ERROR',
          message: 'PRIVATE_LOAD $_oldUrl', details: _draftName));
      if (source.$1 == 'camera' || source.$1 == 'edited') await _tap(tester, _camera);
      if (source.$1 == 'photo') await _tap(tester, _photo);
      if (source.$1 == 'clipboard') await _tap(tester, _paste);
      await tester.pumpAndSettle();
      if (source.$1 == 'edited') {
        await _tap(tester, _reveal);
        await tester.enterText(find.byKey(_url), _newerUrl);
      }
      // Renaming does not change where the URL came from.
      await tester.enterText(find.byKey(_name), 'PRIVATE_RENAMED');
      await _tap(tester, _save);
      await tester.pumpAndSettle();
      expect(writes, isEmpty);
      await _tap(tester, _copyError);
      await tester.pumpAndSettle();
      expect(writes.single, contains('Источник: ${source.$2}'));
      expect(writes.single, contains('Код: SUBSCRIPTION_TLS_ERROR'));
      for (final value in ['PRIVATE_', '198.51.100.', 'https://', _draftName]) {
        expect(writes.single, isNot(contains(value)));
      }
      expect(_field(tester, _url).obscureText, isTrue);
    });
  }

  for (final failedRead in [false, true]) {
    testWidgets('Clipboard ${failedRead ? 'failure' : 'empty value'} has a safe subscription diagnostic',
        (tester) async {
      final writes = <String>[];
      _mockClipboard((call) async {
        if (call.method == 'Clipboard.setData') writes.add((call.arguments as Map)['text'] as String);
        if (call.method == 'Clipboard.getData') {
          if (failedRead) throw PlatformException(code: 'PRIVATE_CLIPBOARD_CODE', message: _qrUrl);
          return {'text': '   '};
        }
        return null;
      });
      var saves = 0;
      await _open(tester, onSave: (_, _) async { saves++; });
      await _tap(tester, _paste);
      await tester.pumpAndSettle();
      expect(writes, isEmpty);
      await _tap(tester, _copyError);
      await tester.pumpAndSettle();
      expect(writes.single, contains('Источник: Буфер обмена'));
      expect(writes.single, contains(failedRead
          ? 'Код: SUBSCRIPTION_CLIPBOARD_UNAVAILABLE' : 'Код: SUBSCRIPTION_CLIPBOARD_EMPTY'));
      expect(writes.single, isNot(contains('PRIVATE_')));
      expect(writes.single, isNot(contains('198.51.100.')));
      _expectMaskedDraft(tester, _oldUrl);
      expect(saves, 0);
    });
  }

  testWidgets('Unknown subscription errors never copy native code messages or details',
      (tester) async {
    final writes = <String>[];
    var attempts = 0;
    _mockClipboard((call) async {
      if (call.method == 'Clipboard.setData') writes.add((call.arguments as Map)['text'] as String);
      return null;
    });
    await _open(tester, onSave: (_, _) async {
      if (attempts++ == 0) throw PlatformException(code: 'PRIVATE_CODE',
        message: _oldUrl, details: _draftName);
      throw StateError('PRIVATE_ERROR $_newerUrl');
    });
    for (var attempt = 0; attempt < 2; attempt++) {
      await _tap(tester, _save);
      await tester.pumpAndSettle();
      await _tap(tester, _copyError);
      await tester.pumpAndSettle();
      for (final value in ['PRIVATE_', 'https://', _draftName]) {
        expect(writes.last, isNot(contains(value)));
      }
      expect(writes.last, contains('Код: '));
    }
    expect(writes.length, 2);
  });

  testWidgets('Editing retry and successful QR import invalidate old copy callbacks',
      (tester) async {
    final writes = <String>[];
    _mockClipboard((call) async {
      if (call.method == 'Clipboard.setData') writes.add((call.arguments as Map)['text'] as String);
      return null;
    });
    var failSave = true;
    final pendingQr = Completer<String?>();
    await _open(tester, onScanQr: () => pendingQr.future,
      onSave: (_, _) async {
        if (failSave) throw PlatformException(code: 'SUBSCRIPTION_NETWORK_ERROR');
      });
    await _tap(tester, _save);
    await tester.pumpAndSettle();
    final firstCopy = tester.widget<TextButton>(find.byKey(_copyError)).onPressed!;
    await tester.enterText(find.byKey(_name), 'Новое имя');
    firstCopy();
    await tester.pumpAndSettle();
    expect(writes, isEmpty);
    expect(find.byKey(_copyError), findsNothing);
    await _tap(tester, _save);
    await tester.pumpAndSettle();
    final secondCopy = tester.widget<TextButton>(find.byKey(_copyError)).onPressed!;
    await _tap(tester, _camera);
    secondCopy();
    await tester.pump();
    expect(find.byKey(_copyError), findsNothing);
    expect(writes, isEmpty);
    pendingQr.complete(_qrUrl);
    await tester.pumpAndSettle();
    secondCopy();
    expect(writes, isEmpty);
    expect(find.byKey(_copyError), findsNothing);
    failSave = false;
    await _tap(tester, _save);
    await tester.pumpAndSettle();
    firstCopy();
    secondCopy();
    expect(writes, isEmpty);
    expect(find.byType(SubscriptionEditor), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Failed copying keeps the subscription error and supports an explicit retry',
      (tester) async {
    var copyFails = true;
    final writes = <String>[];
    _mockClipboard((call) async {
      if (call.method == 'Clipboard.setData') {
        writes.add((call.arguments as Map)['text'] as String);
        if (copyFails) throw PlatformException(code: 'PRIVATE_CLIPBOARD', message: _qrUrl);
      }
      return null;
    });
    await _open(tester, onSave: (_, _) async => throw PlatformException(code: 'SUBSCRIPTION_TLS_ERROR'));
    await _tap(tester, _save);
    await tester.pumpAndSettle();
    await _tap(tester, _copyError);
    await tester.pumpAndSettle();
    expect(find.text('Не удалось скопировать отчёт. Попробуйте ещё раз.'), findsOneWidget);
    expect(find.byKey(_error), findsOneWidget);
    expect(tester.widget<TextButton>(find.byKey(_copyError)).onPressed, isNotNull);
    expect(find.textContaining('PRIVATE_CLIPBOARD'), findsNothing);
    _expectMaskedDraft(tester, _oldUrl);
    copyFails = false;
    await _tap(tester, _copyError);
    await tester.pumpAndSettle();
    expect(writes.length, 2);
    expect(writes.first, writes.last);
    expect(find.text('Отчёт скопирован.'), findsOneWidget);
  });

  testWidgets('Subscription diagnostic copy requires a fresh foreground action', (tester) async {
    final writes = <String>[];
    final pendingCopy = Completer<void>();
    _mockClipboard((call) async {
      if (call.method == 'Clipboard.setData') {
        writes.add((call.arguments as Map)['text'] as String);
        await pendingCopy.future;
      }
      return null;
    });
    addTearDown(() => _resume(tester));
    await _open(tester, onSave: (_, _) async => throw PlatformException(code: 'SUBSCRIPTION_NETWORK_ERROR'));
    await _tap(tester, _save);
    await tester.pumpAndSettle();
    final oldCopy = tester.widget<TextButton>(find.byKey(_copyError)).onPressed!;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    oldCopy();
    await tester.pump();
    expect(writes, isEmpty);
    expect(tester.widget<TextButton>(find.byKey(_copyError)).onPressed, isNull);
    _resume(tester);
    await tester.pump();
    oldCopy();
    await tester.pump();
    expect(writes, isEmpty);
    await _tap(tester, _copyError);
    expect(writes.length, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    pendingCopy.complete();
    await tester.pump();
    _resume(tester);
    await tester.pumpAndSettle();
    expect(find.byKey(_copyNotice), findsNothing);
    expect(find.byKey(_error), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('A delayed clipboard result cannot restore an edited subscription diagnostic',
      (tester) async {
    final pendingCopy = Completer<void>();
    _mockClipboard((call) async {
      if (call.method == 'Clipboard.setData') await pendingCopy.future;
      return null;
    });
    await _open(tester, onSave: (_, _) async => throw PlatformException(code: 'SUBSCRIPTION_NETWORK_ERROR'));
    await _tap(tester, _save);
    await tester.pumpAndSettle();
    await _tap(tester, _copyError);
    expect(tester.widget<TextButton>(find.byKey(_copyError)).onPressed, isNull);
    await tester.enterText(find.byKey(_name), 'Новое имя');
    await tester.pump();
    expect(find.byKey(_copyError), findsNothing);
    pendingCopy.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(_copyNotice), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Both QR controls stay usable on a compact phone with large text',
      (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var cameraReads = 0;
    var photoReads = 0;
    var saves = 0;
    await _open(tester, textScale: 1.6,
      onScanQr: () async { cameraReads++; return _qrUrl; },
      onImportQrImage: () async { photoReads++; return _qrUrl; },
      onSave: (_, _) async { saves++; },
    );
    for (final key in [_camera, _photo]) {
      await _tap(tester, key);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    _expectMaskedDraft(tester, _qrUrl);
    expect(cameraReads, 1);
    expect(photoReads, 1);
    expect(saves, 0);
    await _tap(tester, _save);
    await tester.pumpAndSettle();
    expect(saves, 1);
    expect(tester.takeException(), isNull);
  });
}
