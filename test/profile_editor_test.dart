import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pushok_flow/design/pushok_theme.dart';
import 'package:pushok_flow/ui/subscription_editor.dart';
import 'package:pushok_flow/ui/wireguard_profile_editor.dart';

// Local UI fixture only; native parsing and key validation belong to the bridge.
const _config = '[Interface]\nPrivateKey = ui-test-key\n'
    'Address = 10.0.0.2/32\n[Peer]\nPublicKey = ui-test-peer\n';
// Reserved example domain and synthetic UUID: never a usable connection.
const _vless = 'vless://00000000-0000-4000-8000-000000000001@example.invalid:443'
    '?type=tcp&security=tls&sni=example.invalid&flow=xtls-rprx-vision#UI%20fixture';
const _vlessWs = 'vless://00000000-0000-4000-8000-000000000001@example.invalid:443'
    '?type=ws&security=tls&sni=example.invalid&host=example.invalid&path=%2Fflow%3Fx%3Da%252Fb#WS';
const _vlessGrpc = 'vless://00000000-0000-4000-8000-000000000001@example.invalid:443'
    '?type=grpc&security=tls&sni=example.invalid&serviceName=FlowService#GRPC';
const _field = Key('wireguard_profile_field');
const _name = Key('wireguard_profile_name');
const _save = Key('save_wireguard_profile');
const _paste = Key('paste_wireguard_profile');
const _import = Key('import_wireguard_profile');
const _scanQr = Key('scan_wireguard_profile_qr');
const _qrImage = Key('import_wireguard_profile_qr_image');
const _info = Key('info_wireguard_profile');
const _close = Key('close_wireguard_profile');
const _visibility = Key('toggle_wireguard_profile_visibility');
const _copyImportError = Key('copy_profile_import_error');
const _copyImportNotice = Key('profile_import_copy_notice');

void _captureClipboardWrites(List<String> writes,
    {Future<void> Function()? onWrite, String? pasteText}) {
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') {
      writes.add((call.arguments as Map)['text'] as String);
      await onWrite?.call();
    }
    if (call.method == 'Clipboard.getData' && pasteText != null) {
      return {'text': pasteText};
    }
    return null;
  });
  addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
}

Future<void> _openEditor(
  WidgetTester tester, {
  required Future<void> Function(String, String) onSave,
  String initialConfig = '',
  String initialName = 'Мой профиль',
  String? initialError,
  bool connectAfterSave = false,
  ValueChanged<String?>? onResult,
  Future<String?> Function()? onImport,
  Future<String?> Function()? onScanQr,
  Future<String?> Function()? onImportQrImage,
  Future<void> Function()? onCancelImport,
  Future<void> Function(String, String)? onSaveSubscription,
  VoidCallback? onSubscriptionSaved,
  VoidCallback? onClose,
  VoidCallback? onCompleted,
  double textScale = 1,
}) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pumpWidget(MaterialApp(
    theme: buildPushokTheme(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: Scaffold(body: Builder(builder: (context) => Center(
      child: TextButton(
        onPressed: () async {
          final result = await showModalBottomSheet<String>(
            context: context,
            isScrollControlled: true,
            useSafeArea: true,
            isDismissible: false,
            enableDrag: false,
            builder: (_) => WireGuardProfileEditor(
              initialConfig: initialConfig,
              initialName: initialName,
              initialError: initialError,
              onSave: onSave,
              onImport: onImport,
              onScanQr: onScanQr,
              onImportQrImage: onImportQrImage,
              onCancelImport: onCancelImport,
              onSaveSubscription: onSaveSubscription,
              onSubscriptionSaved: onSubscriptionSaved,
              onClose: onClose,
              onCompleted: onCompleted,
              connectAfterSave: connectAfterSave,
            ),
          );
          onResult?.call(result);
        },
        child: const Text('Открыть редактор'),
      ),
    ))),
  ));
  await tester.tap(find.text('Открыть редактор'));
  await tester.pumpAndSettle();
}

Future<void> _tapEditorKey(WidgetTester tester, Key key) async {
  final finder = find.byKey(key);
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
}

Future<void> _tapSave(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(_save));
  await _tapEditorKey(tester, _save);
  await tester.pump();
}

void main() {
  testWidgets('Inline profile callbacks complete once without returning a String through the enclosing route',
      (tester) async {
    final saved = Completer<void>();
    var saves = 0;
    var closes = 0;
    var completed = 0;
    final results = <String?>[];
    await _openEditor(tester,
      initialConfig: _vless,
      onSave: (_, _) { saves++; return saved.future; },
      onClose: () { closes++; },
      onCompleted: () { completed++; },
      onResult: results.add,
    );
    final oldSave = tester.widget<FilledButton>(find.byKey(_save)).onPressed!;
    final oldBack = tester.widget<IconButton>(find.byKey(_close)).onPressed!;
    expect(find.byTooltip('Вернуться к подписке'), findsOneWidget);
    oldSave();
    oldSave();
    oldBack();
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(saves, 1);
    expect(closes, 0);
    expect(completed, 0);
    expect(results, isEmpty);
    saved.complete();
    await tester.pump();
    expect(completed, 1);
    expect(results, isEmpty);
    // The embedding parent owns removal. Even before it rebuilds, no old action
    // may save again, return twice or close the parent's route.
    oldSave();
    oldBack();
    await tester.pump();
    expect(saves, 1);
    expect(closes, 0);
    expect(completed, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('Inline profile return cancels import and invalidates closing-frame results and buttons',
      (tester) async {
    final qr = Completer<String?>();
    var cancels = 0;
    var closes = 0;
    var saves = 0;
    await _openEditor(tester,
      initialConfig: _vless,
      onSave: (_, _) async { saves++; },
      onImportQrImage: () => qr.future,
      onCancelImport: () async {
        cancels++;
        throw PlatformException(code: 'PRIVATE_CANCEL_FAILURE', message: _config);
      },
      onClose: () { closes++; },
      onCompleted: () => fail('No save expected'),
    );
    final oldSave = tester.widget<FilledButton>(find.byKey(_save)).onPressed!;
    final oldBack = tester.widget<IconButton>(find.byKey(_close)).onPressed!;
    final oldReveal = tester.widget<IconButton>(find.byKey(_visibility)).onPressed!;
    await _tapEditorKey(tester, _qrImage);
    await tester.pump();
    oldBack();
    oldBack();
    oldSave();
    oldReveal();
    qr.complete(_config);
    await tester.pump();
    expect(closes, 1);
    expect(cancels, 1);
    expect(saves, 0);
    final field = tester.widget<TextField>(find.byKey(_field));
    expect(field.controller!.text, _vless);
    expect(field.obscureText, isTrue);
    expect(find.textContaining('PRIVATE_CANCEL_FAILURE'), findsNothing);
    expect(find.byKey(const Key('wireguard_profile_notice')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(cancels, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Inline profile save failure preserves the draft and completes only after an explicit retry',
      (tester) async {
    var saves = 0;
    var completed = 0;
    await _openEditor(tester,
      initialConfig: _vless,
      onSave: (_, _) async {
        if (++saves == 1) {
          throw PlatformException(code: 'INVALID_VLESS_CONFIG',
            message: 'PRIVATE_SERVER_MESSAGE', details: _vless);
        }
      },
      onClose: () {},
      onCompleted: () { completed++; },
    );
    await _tapSave(tester);
    await tester.pumpAndSettle();
    expect(saves, 1);
    expect(completed, 0);
    expect(tester.widget<TextField>(find.byKey(_field)).controller!.text, _vless);
    expect(find.byKey(const Key('wireguard_profile_error')), findsOneWidget);
    expect(find.textContaining('PRIVATE_SERVER_MESSAGE'), findsNothing);
    expect(tester.widget<IconButton>(find.byKey(_close)).onPressed, isNotNull);
    await _tapSave(tester);
    await tester.pump();
    expect(saves, 2);
    expect(completed, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  const subscriptionUrl = 'https://example.invalid/sub/PRIVATE%2FTOKEN?key=a%2Bb+c';
  const offerSubscription = Key('open_imported_subscription');
  const discardSubscription = Key('discard_imported_subscription');
  const subscriptionUrlField = Key('subscription_url');
  const subscriptionNameField = Key('subscription_name');
  const subscriptionSave = Key('save_subscription');
  const subscriptionBack = Key('close_subscription_editor');

  for (final source in [
    ('file', _import, 'Файл'), ('camera', _scanQr, 'Камера QR'),
    ('photo', _qrImage, 'QR из фото'), ('clipboard', _paste, 'Буфер обмена'),
    ('manual', _save, 'Ввод вручную'),
  ]) {
    testWidgets('Inline ${source.$1} subscription failure keeps provenance and clears on return',
        (tester) async {
      final writes = <String>[];
      _captureClipboardWrites(writes, pasteText: subscriptionUrl);
      var failSave = true;
      var profilesSaved = 0;
      var subscriptionsSaved = 0;
      await _openEditor(tester,
        initialConfig: source.$1 == 'manual' ? subscriptionUrl : _config,
        initialName: 'PRIVATE_PROFILE_NAME',
        onImport: () async => subscriptionUrl,
        onScanQr: () async => subscriptionUrl,
        onImportQrImage: () async => subscriptionUrl,
        onSaveSubscription: (_, _) async {
          if (failSave) throw PlatformException(code: 'SUBSCRIPTION_TLS_ERROR',
            message: subscriptionUrl, details: 'PRIVATE_NATIVE_DETAILS');
          subscriptionsSaved++;
        },
        onSave: (_, _) async { profilesSaved++; });
      await _tapEditorKey(tester, source.$2);
      await tester.pumpAndSettle();
      await _tapEditorKey(tester, offerSubscription);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('copy_subscription_error')), findsNothing);
      await _tapEditorKey(tester, subscriptionSave);
      await tester.pumpAndSettle();
      expect(writes, isEmpty);
      final oldCopy = tester.widget<TextButton>(find.byKey(
        const Key('copy_subscription_error'))).onPressed!;
      await _tapEditorKey(tester, const Key('copy_subscription_error'));
      await tester.pumpAndSettle();
      expect(writes.single, contains('Источник: ${source.$3}'));
      expect(writes.single, contains('Код: SUBSCRIPTION_TLS_ERROR'));
      expect(writes.single, isNot(contains('PRIVATE')));
      expect(writes.single, isNot(contains('example.invalid')));
      expect(writes.single, isNot(contains('ui-test-key')));
      await _tapEditorKey(tester, subscriptionBack);
      await tester.pumpAndSettle();
      oldCopy();
      expect(writes.length, 1);
      expect(find.byType(SubscriptionEditor), findsNothing);
      await _tapEditorKey(tester, offerSubscription);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('copy_subscription_error')), findsNothing);
      expect(find.byKey(const Key('subscription_error_copy_notice')), findsNothing);
      failSave = false;
      await _tapEditorKey(tester, subscriptionSave);
      await tester.pumpAndSettle();
      oldCopy();
      expect(writes.length, 1);
      expect(subscriptionsSaved, 1);
      expect(profilesSaved, 0);
      expect(find.byType(WireGuardProfileEditor), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final source in [
    ('file', _import), ('camera', _scanQr), ('photo', _qrImage), ('clipboard', _paste),
  ]) {
    testWidgets('HTTPS ${source.$1} offers a masked subscription without replacing the profile',
        (tester) async {
      final writes = <String>[];
      _captureClipboardWrites(writes, pasteText: subscriptionUrl);
      var saves = 0;
      var subscriptions = 0;
      await _openEditor(tester, initialConfig: _config, initialName: 'Мой сервер',
        onImport: () async => subscriptionUrl,
        onScanQr: () async => subscriptionUrl,
        onImportQrImage: () async => subscriptionUrl,
        onSaveSubscription: (_, _) async { subscriptions++; },
        onSave: (_, _) async { saves++; },
      );
      await _tapEditorKey(tester, source.$2);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byKey(_field)).controller!.text, _config);
      expect(tester.widget<TextField>(find.byKey(_name)).controller!.text, 'Мой сервер');
      expect(tester.widget<TextField>(find.byKey(_field)).obscureText, isTrue);
      expect(tester.widget<FilledButton>(find.byKey(_save)).onPressed, isNull);
      expect(find.byType(SubscriptionEditor), findsNothing);
      expect(find.byKey(const Key('wireguard_profile_error')), findsNothing);
      expect(find.textContaining('PRIVATE'), findsNothing);
      expect(subscriptions, 0);
      expect(saves, 0);

      await _tapEditorKey(tester, offerSubscription);
      await tester.pumpAndSettle();
      expect(find.byType(SubscriptionEditor), findsOneWidget);
      final url = tester.widget<TextField>(find.byKey(subscriptionUrlField));
      expect(url.controller!.text, subscriptionUrl);
      expect(url.obscureText, isTrue);
      expect(url.readOnly, isTrue);
      expect(url.enableInteractiveSelection, isFalse);
      expect(subscriptions, 0);
      expect(writes, isEmpty);

      // System back returns to the existing draft in the same route.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(SubscriptionEditor), findsNothing);
      expect(tester.widget<TextField>(find.byKey(_field)).controller!.text, _config);
      expect(tester.widget<TextField>(find.byKey(_name)).controller!.text, 'Мой сервер');
      expect(tester.widget<FilledButton>(find.byKey(_save)).onPressed, isNull);
      await _tapEditorKey(tester, discardSubscription);
      await tester.pumpAndSettle();
      expect(find.byKey(offerSubscription), findsNothing);
      expect(tester.widget<FilledButton>(find.byKey(_save)).onPressed, isNotNull);
      expect(subscriptions, 0);
      expect(saves, 0);
      await _tapEditorKey(tester, _close);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Confirmed QR subscription closes with no profile result and submits once',
      (tester) async {
    final pending = Completer<void>();
    var subscriptions = 0;
    var profiles = 0;
    var completions = 0;
    var closed = false;
    String? result = 'not closed';
    await _openEditor(tester, initialConfig: _config, connectAfterSave: true,
      onImportQrImage: () async => subscriptionUrl,
      onSave: (_, _) async { profiles++; },
      onSaveSubscription: (url, name) {
        expect(url, subscriptionUrl);
        expect(name, 'Магазин');
        subscriptions++;
        return pending.future;
      },
      onSubscriptionSaved: () { completions++; },
      onResult: (value) { closed = true; result = value; },
    );
    await _tapEditorKey(tester, _qrImage);
    await tester.pumpAndSettle();
    await _tapEditorKey(tester, offerSubscription);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(subscriptionNameField));
    await tester.enterText(find.byKey(subscriptionNameField), '  Магазин  ');
    await _tapEditorKey(tester, subscriptionSave);
    await tester.pump();
    await _tapEditorKey(tester, subscriptionSave);
    await tester.pump();
    expect(subscriptions, 1);
    expect(profiles, 0);
    expect(tester.widget<IconButton>(find.byKey(subscriptionBack)).onPressed, isNull);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(SubscriptionEditor), findsOneWidget);
    expect(closed, isFalse);
    pending.complete();
    await tester.pumpAndSettle();
    expect(completions, 1);
    expect(closed, isTrue);
    expect(result, isNull);
    expect(profiles, 0);
    expect(find.byType(WireGuardProfileEditor), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Failed subscription stays retryable and Back restores the untouched profile',
      (tester) async {
    var calls = 0;
    await _openEditor(tester, initialConfig: _config, initialName: 'Дом',
      onScanQr: () async => subscriptionUrl,
      onSave: (_, _) async => fail('The profile must not be saved'),
      onSaveSubscription: (_, _) async {
        calls++;
        throw PlatformException(code: 'SUBSCRIPTION_NETWORK_ERROR',
            message: 'PRIVATE_NATIVE_DETAILS');
      },
    );
    await _tapEditorKey(tester, _scanQr);
    await tester.pumpAndSettle();
    await _tapEditorKey(tester, offerSubscription);
    await tester.pumpAndSettle();
    await _tapEditorKey(tester, subscriptionSave);
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.byKey(const Key('subscription_editor_error')), findsOneWidget);
    // Finder.textContaining also inspects masked EditableText controllers.
    // Check visible messages separately from the required private draft value.
    expect(find.byWidgetPredicate((widget) => widget is Text &&
        (widget.data ?? widget.textSpan?.toPlainText() ?? '').contains('PRIVATE')), findsNothing);
    final hiddenUrl = tester.widget<TextField>(find.byKey(subscriptionUrlField));
    expect(hiddenUrl.controller!.text, subscriptionUrl);
    expect(hiddenUrl.obscureText, isTrue);
    expect(hiddenUrl.readOnly, isTrue);
    expect(hiddenUrl.enableInteractiveSelection, isFalse);
    expect(tester.widget<FilledButton>(find.byKey(subscriptionSave)).onPressed, isNotNull);
    await _tapEditorKey(tester, subscriptionBack);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(_field)).controller!.text, _config);
    expect(tester.widget<TextField>(find.byKey(_name)).controller!.text, 'Дом');
    await _tapEditorKey(tester, _close);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Queued subscription opening cannot navigate after app switching',
      (tester) async {
    await _openEditor(tester, initialConfig: _config,
      onImportQrImage: () async => subscriptionUrl,
      onSave: (_, _) async => fail('The profile must not be saved'),
      onSaveSubscription: (_, _) async => fail('A scan must not fetch servers'),
    );
    await _tapEditorKey(tester, _qrImage);
    await tester.pumpAndSettle();
    final queued = tester.widget<OutlinedButton>(find.byKey(offerSubscription)).onPressed!;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    queued();
    await tester.pump();
    expect(find.byType(SubscriptionEditor), findsNothing);
    expect(tester.widget<OutlinedButton>(find.byKey(offerSubscription)).onPressed, isNull);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.byType(SubscriptionEditor), findsNothing);
    expect(tester.widget<TextField>(find.byKey(_field)).controller!.text, _config);
    await _tapEditorKey(tester, _close);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Old profile callbacks cannot act on the inline subscription route',
      (tester) async {
    var scans = 0;
    await _openEditor(tester, initialConfig: _config,
      onScanQr: () async { scans++; return subscriptionUrl; },
      onSave: (_, _) async => fail('An old callback must not save'),
      onSaveSubscription: (_, _) async => fail('Opening a draft must not fetch'),
    );
    final oldScan = tester.widget<OutlinedButton>(find.byKey(_scanQr)).onPressed!;
    final oldSave = tester.widget<FilledButton>(find.byKey(_save)).onPressed!;
    final oldReveal = tester.widget<IconButton>(find.byKey(_visibility)).onPressed!;
    final oldClose = tester.widget<IconButton>(find.byKey(_close)).onPressed!;
    await _tapEditorKey(tester, _scanQr);
    await tester.pumpAndSettle();
    final oldDiscard = tester.widget<TextButton>(find.byKey(discardSubscription)).onPressed!;
    final open = tester.widget<OutlinedButton>(find.byKey(offerSubscription)).onPressed!;
    open();
    oldScan(); oldSave(); oldReveal(); oldDiscard(); oldClose();
    await tester.pumpAndSettle();
    expect(scans, 1);
    expect(find.byType(SubscriptionEditor), findsOneWidget);
    await _tapEditorKey(tester, subscriptionBack);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(_field)).obscureText, isTrue);
    expect(tester.widget<TextField>(find.byKey(_field)).controller!.text, _config);
    expect(find.byKey(offerSubscription), findsOneWidget);
    await _tapEditorKey(tester, _close);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Subscription callbacks cannot reveal in background or submit after Back',
      (tester) async {
    await _openEditor(tester, initialConfig: _config,
      onImportQrImage: () async => subscriptionUrl,
      onSave: (_, _) async => fail('The profile must not be saved'),
      onSaveSubscription: (_, _) async => fail('An old callback must not fetch'),
    );
    await _tapEditorKey(tester, _qrImage);
    await tester.pumpAndSettle();
    await _tapEditorKey(tester, offerSubscription);
    await tester.pumpAndSettle();
    final reveal = tester.widget<IconButton>(
        find.byKey(const Key('toggle_subscription_url_visibility'))).onPressed!;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    reveal();
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(subscriptionUrlField)).obscureText, isTrue);
    final save = tester.widget<FilledButton>(find.byKey(subscriptionSave)).onPressed!;
    final back = tester.widget<IconButton>(find.byKey(subscriptionBack)).onPressed!;
    back();
    save();
    reveal();
    await tester.pumpAndSettle();
    expect(find.byType(SubscriptionEditor), findsNothing);
    expect(tester.widget<TextField>(find.byKey(_field)).controller!.text, _config);
    await _tapEditorKey(tester, _close);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  for (final failure in [
    ('PROFILE_TELEGRAM_LINK', 'Это ссылка прокси Telegram.'),
    ('PROFILE_VMESS_LINK', 'Обнаружена ссылка VMess.'),
    ('PROFILE_TROJAN_LINK', 'Обнаружена ссылка Trojan.'),
    ('PROFILE_SHADOWSOCKS_LINK', 'Обнаружена ссылка Shadowsocks или ShadowsocksR.'),
    ('SUBSCRIPTION_URL_INVALID', 'Для подписки нужна полная HTTPS-ссылка'),
  ]) {
    testWidgets('${failure.$1} explains a photo failure without exposing the payload',
        (tester) async {
      final copied = <String>[];
      _captureClipboardWrites(copied);
      await _openEditor(tester, initialConfig: _config,
        onSave: (_, _) async => fail('A failed import must not save'),
        onImportQrImage: () async => throw PlatformException(code: failure.$1,
            message: 'PRIVATE_NATIVE_DETAILS', details: subscriptionUrl),
        onSaveSubscription: (_, _) async => fail('A failed import must not fetch'),
      );
      await _tapEditorKey(tester, _qrImage);
      await tester.pumpAndSettle();
      expect(find.textContaining(failure.$2), findsOneWidget);
      expect(find.textContaining('PRIVATE'), findsNothing);
      expect(find.byKey(offerSubscription), findsNothing);
      expect(tester.widget<TextField>(find.byKey(_field)).controller!.text, _config);
      await _tapEditorKey(tester, _copyImportError);
      await tester.pumpAndSettle();
      expect(copied.single, contains('Источник: QR из фото'));
      expect(copied.single, contains('Код: ${failure.$1}'));
      expect(copied.single, isNot(contains('PRIVATE')));
      expect(copied.single, isNot(contains('example.invalid')));
      await _tapEditorKey(tester, _close);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('VLESS paste stays masked and saves the complete link only after an explicit action',
      (tester) async {
    var clipboardReads = 0;
    String? saved;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') {
        clipboardReads++;
        return {'text': _vless};
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await _openEditor(tester, onSave: (config, _) async { saved = config; });
    expect(find.text('Профиль подключения'), findsOneWidget);
    expect(clipboardReads, 0);
    await _tapEditorKey(tester, _paste);
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byKey(_field));
    expect(field.controller!.text, _vless);
    expect(field.obscureText, isTrue);
    expect(field.readOnly, isTrue);
    expect(field.enableInteractiveSelection, isFalse);
    expect(clipboardReads, 1);
    expect(saved, isNull);
    expect(find.byWidgetPredicate((widget) => widget is Text &&
        (widget.data?.contains('00000000-0000-4000-8000-000000000001') ?? false)),
        findsNothing);
    await _tapSave(tester);
    await tester.pumpAndSettle();
    expect(saved, _vless);
    expect(tester.takeException(), isNull);
  });

  for (final source in [
    ('file TCP', _import, _vless),
    ('camera WebSocket', _scanQr, _vlessWs),
    ('image gRPC', _qrImage, _vlessGrpc),
  ]) {
    testWidgets('VLESS ${source.$1} import preserves the name and requires explicit save',
        (tester) async {
      String? saved;
      await _openEditor(tester, initialConfig: _config, initialName: 'Мой сервер',
        onImport: () async => source.$3,
        onScanQr: () async => source.$3,
        onImportQrImage: () async => source.$3,
        onSave: (config, _) async { saved = config; },
      );
      await _tapEditorKey(tester, source.$2);
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(find.byKey(_field));
      expect(field.controller!.text, source.$3);
      expect(field.obscureText, isTrue);
      expect(field.readOnly, isTrue);
      expect(field.controller!.selection, const TextSelection.collapsed(offset: -1));
      expect(tester.widget<TextField>(find.byKey(_name)).controller!.text, 'Мой сервер');
      expect(saved, isNull);
      await _tapSave(tester);
      await tester.pumpAndSettle();
      expect(saved, source.$3);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Unsupported clipboard links leave the existing profile draft intact',
      (tester) async {
    var link = 'vmess://PRIVATE_UNSUPPORTED_CONTENT';
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async =>
        call.method == 'Clipboard.getData' ? {'text': link} : null);
    addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    var saves = 0;
    await _openEditor(tester, initialConfig: _config,
      onSave: (_, _) async { saves++; },
    );
    for (final unsupported in [
      'vmess://PRIVATE_UNSUPPORTED_CONTENT',
      'trojan://PRIVATE_UNSUPPORTED_CONTENT',
      'ss://PRIVATE_UNSUPPORTED_CONTENT',
      'https://example.invalid/sub/PRIVATE_UNSUPPORTED_CONTENT',
    ]) {
      link = unsupported;
      await _tapEditorKey(tester, _paste);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byKey(_field)).controller!.text, _config);
      expect(tester.widget<TextField>(find.byKey(_field)).obscureText, isTrue);
      expect(find.byKey(const Key('wireguard_profile_error')), findsOneWidget);
      expect(find.textContaining('PRIVATE_UNSUPPORTED_CONTENT'), findsNothing);
      expect(saves, 0);
    }
    expect(find.textContaining('Найдена HTTPS-ссылка.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Explicit save trims the name without changing the hidden configuration',
      (tester) async {
    String? savedConfig;
    String? savedName;
    await _openEditor(tester, initialConfig: _config, initialName: 'Прежнее название',
      onSave: (config, name) async { savedConfig = config; savedName = name; },
    );
    final nameField = tester.widget<TextField>(find.byKey(_name));
    expect(nameField.controller!.text, 'Прежнее название');
    expect(nameField.autofillHints, isNull);
    expect(nameField.enableSuggestions, isFalse);
    expect(nameField.enableIMEPersonalizedLearning, isFalse);
    await tester.ensureVisible(find.byKey(_name));
    await tester.enterText(find.byKey(_name), '  Дом  ');
    await tester.pump();
    expect(tester.widget<TextField>(find.byKey(_field)).obscureText, isTrue);
    expect(savedName, isNull);
    await _tapSave(tester);
    await tester.pumpAndSettle();
    expect(savedName, 'Дом');
    expect(savedConfig, _config);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Invalid names are rejected before the save callback and retain the draft',
      (tester) async {
    var saves = 0;
    await _openEditor(tester, initialConfig: _config,
      onSave: (_, name) async { saves++; },
    );
    for (final invalid in ['', '   ', '🐈' * 65, 'Дом\u0000Работа',
        'Дом\nРабота', 'Дом\u0085Работа', 'Дом\u2028Работа']) {
      // Controller assignment also covers pasted/platform text that does not
      // pass through the single-line input formatter.
      tester.widget<TextField>(find.byKey(_name)).controller!.text = invalid;
      await _tapSave(tester);
      await tester.pumpAndSettle();
      expect(saves, 0);
      expect(find.text('Укажите название: от 1 до 64 символов без переносов строк.'),
        findsOneWidget);
      expect(tester.widget<TextField>(find.byKey(_field)).controller!.text, _config);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('Unicode names use codepoints and imports preserve the chosen name',
      (tester) async {
    String? savedName;
    await _openEditor(tester, initialName: '🐈' * 64,
      onImport: () async => _config,
      onSave: (_, name) async { savedName = name; },
    );
    await _tapEditorKey(tester, _import);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(_name)).controller!.text, '🐈' * 64);
    expect(savedName, isNull);
    await _tapSave(tester);
    await tester.pumpAndSettle();
    expect(savedName, '🐈' * 64);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Named profile failures keep both inputs and expose only safe codes',
      (tester) async {
    for (final failure in [
      ('PROFILE_NAME_INVALID', 'Укажите название: от 1 до 64 символов без переносов строк.'),
      ('PROFILE_LIMIT_REACHED', 'Можно сохранить до 20 профилей. Удалите ненужный и попробуйте снова.'),
      ('PROFILE_NOT_FOUND', 'Этот профиль уже недоступен. Закройте редактор и обновите список.'),
      ('VPN_ACTIVE', 'Для изменения профилей сначала отключите туннель.'),
      ('PROFILE_STORE_UNAVAILABLE',
        'Не удалось записать профили. Перезапустите приложение перед повторной попыткой.'),
    ]) {
      await _openEditor(tester, initialConfig: _config, initialName: 'Дом',
        onSave: (_, name) async => throw PlatformException(
          code: failure.$1, message: 'PRIVATE_NATIVE_DETAIL', details: _config),
      );
      await _tapSave(tester);
      await tester.pumpAndSettle();
      expect(find.text(failure.$2), findsOneWidget);
      expect(find.textContaining('PRIVATE_NATIVE_DETAIL'), findsNothing);
      expect(tester.widget<TextField>(find.byKey(_name)).controller!.text, 'Дом');
      expect(tester.widget<TextField>(find.byKey(_field)).controller!.text, _config);
      await _tapEditorKey(tester, _close);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('App switching clears name input focus and selection while preserving both drafts',
      (tester) async {
    addTearDown(() => tester.binding
      .handleAppLifecycleStateChanged(AppLifecycleState.resumed));
    await _openEditor(tester, initialConfig: _config, initialName: 'Дом',
      onSave: (_, name) async {},
    );
    await tester.ensureVisible(find.byKey(_name));
    await tester.enterText(find.byKey(_name), 'Работа');
    await tester.pump();
    final field = tester.widget<TextField>(find.byKey(_name));
    field.controller!.value = field.controller!.value.copyWith(
      selection: const TextSelection(baseOffset: 0, extentOffset: 3),
      composing: const TextRange(start: 0, end: 3),
    );
    expect(field.focusNode!.hasFocus, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(field.focusNode!.hasFocus, isFalse);
    expect(field.controller!.selection, const TextSelection.collapsed(offset: -1));
    expect(field.controller!.value.composing, TextRange.empty);
    expect(field.controller!.text, 'Работа');
    expect(tester.widget<TextField>(find.byKey(_field)).controller!.text, _config);
    expect(tester.widget<TextField>(find.byKey(_field)).obscureText, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(field.controller!.text, 'Работа');
    expect(field.focusNode!.hasFocus, isFalse);
    // Even a return before FocusManager commits the queued unfocus must finish
    // cleanup; it cannot depend on an inactive-only post-frame callback.
    await tester.ensureVisible(find.byKey(_name));
    await tester.enterText(find.byKey(_name), 'Работа');
    await tester.pump();
    expect(field.focusNode!.hasFocus, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(field.focusNode!.hasFocus, isFalse);
    expect(field.controller!.selection, const TextSelection.collapsed(offset: -1));
    expect(field.controller!.value.composing, TextRange.empty);
    expect(field.controller!.text, 'Работа');
    await _tapEditorKey(tester, _close);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Masked paste and save preserve multiline config without a keyboard',
      (tester) async {
    var clipboardReads = 0;
    String? saved;
    String? result;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') {
        clipboardReads++;
        return {'text': _config};
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));

    await _openEditor(tester,
      onSave: (config, name) async { saved = config; },
      onResult: (value) => result = value,
    );
    expect(clipboardReads, 0);
    expect(tester.widget<TextField>(find.byKey(_field)).obscureText, isTrue);
    expect(tester.widget<TextField>(find.byKey(_field)).readOnly, isTrue);
    await _tapEditorKey(tester, _field);
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isFalse);
    await _tapEditorKey(tester, _paste);
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byKey(_field));
    expect(clipboardReads, 1);
    expect(field.controller!.text, _config);
    expect(field.obscureText, isTrue);
    expect(field.readOnly, isTrue);
    expect(field.maxLines, 1);
    expect(field.autofillHints, isNull);
    await _tapEditorKey(tester, _visibility);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(_field)).obscureText, isFalse);
    expect(tester.widget<TextField>(find.byKey(_field)).readOnly, isFalse);
    await _tapEditorKey(tester, _visibility);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(_field)).obscureText, isTrue);
    expect(tester.widget<TextField>(find.byKey(_field)).readOnly, isTrue);
    expect(tester.testTextInput.isVisible, isFalse);
    await _tapSave(tester);
    await tester.pumpAndSettle();
    expect(saved, _config);
    expect(result, _config);
    expect(find.byType(WireGuardProfileEditor), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Every non-resumed state hides the draft and rejects a queued reveal',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    addTearDown(() => tester.binding
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed));
    const draft = '$_config\n# Unsaved local edit\n';
    String? saved;
    await _openEditor(tester,
      initialConfig: _config,
      onSave: (config, name) async { saved = config; },
    );

    for (final transition in const [
      (AppLifecycleState.inactive,
        [AppLifecycleState.inactive], [AppLifecycleState.resumed]),
      (AppLifecycleState.hidden,
        [AppLifecycleState.inactive, AppLifecycleState.hidden],
        [AppLifecycleState.inactive, AppLifecycleState.resumed]),
      (AppLifecycleState.paused,
        [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused],
        [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]),
      (AppLifecycleState.detached,
        [AppLifecycleState.inactive, AppLifecycleState.hidden,
          AppLifecycleState.paused, AppLifecycleState.detached],
        [AppLifecycleState.resumed]),
    ]) {
      final state = transition.$1;
      await _tapEditorKey(tester, _visibility);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byKey(_field)).obscureText, isFalse);
      await tester.enterText(find.byKey(_field), draft);
      final controller = tester.widget<TextField>(find.byKey(_field)).controller!;
      controller.value = controller.value.copyWith(
        selection: TextSelection(baseOffset: 0, extentOffset: draft.length),
        composing: const TextRange(start: 1, end: 4),
      );
      final queuedReveal = tester.widget<IconButton>(find.byKey(_visibility)).onPressed!;

      for (final next in transition.$2) {
        tester.binding.handleAppLifecycleStateChanged(next);
      }
      tester.binding.handleAppLifecycleStateChanged(state);
      // Call the previously captured action before a rebuild can disable it.
      queuedReveal();
      for (final next in transition.$3) {
        tester.binding.handleAppLifecycleStateChanged(next);
      }
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(find.byKey(_field));
      expect(field.obscureText, isTrue, reason: state.name);
      expect(field.readOnly, isTrue);
      expect(field.controller!.text, draft);
      expect(field.controller!.selection.isCollapsed, isTrue);
      expect(field.controller!.value.composing, TextRange.empty);
      expect(field.focusNode!.hasFocus, isFalse);
      expect(tester.testTextInput.isVisible, isFalse);
    }

    // Returning to the app never reveals automatically; a new tap still works.
    await _tapEditorKey(tester, _visibility);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(_field)).obscureText, isFalse);
    await _tapSave(tester);
    await tester.pumpAndSettle();
    expect(saved, draft);
    expect(tester.takeException(), isNull);
  });

  testWidgets('A pending paste can finish in the background without revealing or altering its text',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    addTearDown(() => tester.binding
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed));
    const pasted = '[Interface]\r\nPrivateKey = pasted-test-key\r\n\r\n'
        '[Peer]\r\nPublicKey = pasted-test-peer\r\n';
    final pending = Completer<Object?>();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') return pending.future;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    String? saved;
    await _openEditor(tester,
      initialConfig: _config,
      onSave: (config, name) async { saved = config; },
    );
    await _tapEditorKey(tester, _visibility);
    await tester.pumpAndSettle();
    await _tapEditorKey(tester, _paste);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(tester.widget<TextField>(find.byKey(_field)).obscureText, isTrue);

    pending.complete({'text': pasted});
    await tester.pumpAndSettle();
    var field = tester.widget<TextField>(find.byKey(_field));
    expect(field.controller!.text, pasted);
    expect(field.obscureText, isTrue);
    expect(field.controller!.selection.isCollapsed, isTrue);
    expect(tester.widget<IconButton>(find.byKey(_visibility)).onPressed, isNull);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    field = tester.widget<TextField>(find.byKey(_field));
    expect(field.obscureText, isTrue);
    expect(field.controller!.text, pasted);
    await _tapSave(tester);
    await tester.pumpAndSettle();
    expect(saved, pasted);
    expect(tester.takeException(), isNull);
  });

  testWidgets('A save failure after leaving the app preserves a hidden draft and safe feedback',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    addTearDown(() => tester.binding
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed));
    final pending = Completer<void>();
    String? submitted;
    await _openEditor(tester,
      initialConfig: _config,
      onSave: (config, name) { submitted = config; return pending.future; },
    );
    await _tapEditorKey(tester, _visibility);
    await tester.pumpAndSettle();
    await _tapSave(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(tester.widget<TextField>(find.byKey(_field)).obscureText, isTrue);
    expect(tester.widget<TextField>(find.byKey(_field)).enabled, isFalse);
    expect(tester.widget<TextField>(find.byKey(_name)).enabled, isFalse);
    pending.completeError(PlatformException(code: 'PROFILE_SAVE_FAILED',
        message: 'SENSITIVE_SAVE_DETAIL', details: {'privateKey': 'SENSITIVE_SAVE_DETAIL'}));
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byKey(_field));
    expect(field.obscureText, isTrue);
    expect(field.controller!.text, _config);
    expect(submitted, _config);
    expect(find.byKey(const Key('wireguard_profile_error')), findsOneWidget);
    expect(find.textContaining('SENSITIVE_SAVE_DETAIL'), findsNothing);
    expect(tester.widget<FilledButton>(find.byKey(_save)).onPressed, isNotNull);
    await _tapEditorKey(tester, _close);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('A pending paste after disposal cannot change the next screen',
      (tester) async {
    final pending = Completer<Object?>();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') return pending.future;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await _openEditor(tester,
      initialConfig: _config,
      onSave: (_, name) async {},
    );
    await _tapEditorKey(tester, _paste);
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: Text('Следующий экран')),
    ));
    pending.complete({'text': _config});
    await tester.pumpAndSettle();
    expect(find.text('Следующий экран'), findsOneWidget);
    expect(find.byType(WireGuardProfileEditor), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final invalid in [
    ('blank', ' \n ', 'Добавьте конфигурацию подключения перед сохранением.'),
    ('oversized', 'x' * 65537, 'Профиль слишком большой: максимум 65 536 символов.'),
    ('UUID', ' 00000000-0000-4000-8000-000000000000\n',
      'Вставлен только UUID. '
          'Нужен профиль .conf с разделами [Interface] и [Peer].'),
  ]) {
    testWidgets('${invalid.$1} input never reaches the save callback', (tester) async {
      var saves = 0;
      await _openEditor(tester,
        initialConfig: invalid.$2,
        onSave: (_, name) async { saves++; },
      );
      await _tapSave(tester);
      await tester.pumpAndSettle();
      expect(saves, 0);
      expect(find.text(invalid.$3), findsOneWidget);
      expect(find.byType(WireGuardProfileEditor), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final failure in [
    ('INVALID_CONFIG', 'Некорректный профиль подключения. Проверьте конфигурацию или ссылку.'),
    ('INVALID_VLESS_CONFIG', 'Импортируйте профиль .conf.'),
    ('UNSUPPORTED_PROFILE',
      'Этот формат пока не поддерживается. Добавьте профиль .conf.'),
    ('UNSUPPORTED_TRANSPORT',
      'Для подключения нужен профиль .conf.'),
    ('UNSUPPORTED_SECURITY',
      'Для подключения нужен профиль .conf.'),
    ('UNSUPPORTED_PROFILE_OPTION',
      'Для подключения нужен профиль .conf.'),
    ('PROFILE_SAVE_FAILED',
      'Не удалось сохранить профиль. Проверьте конфигурацию и попробуйте снова.'),
    ('UNEXPECTED_NATIVE_CODE', 'Не удалось сохранить профиль. Попробуйте ещё раз.'),
  ]) {
    testWidgets('${failure.$1} shows safe feedback without backend details',
        (tester) async {
      const secret = 'BACKEND_SECRET_MUST_NOT_REACH_UI';
      await _openEditor(tester,
        initialConfig: _config,
        onSave: (_, name) async => throw PlatformException(
          code: failure.$1,
          message: secret,
          details: {'privateKey': secret},
        ),
      );
      await _tapSave(tester);
      await tester.pumpAndSettle();
      expect(find.text(failure.$2), findsOneWidget);
      expect(find.textContaining(secret), findsNothing);
      expect(tester.widget<FilledButton>(find.byKey(_save)).onPressed, isNotNull);
      expect(find.byType(WireGuardProfileEditor), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Successful save returns the saved draft through the modal result',
      (tester) async {
    String? saved;
    String? result;
    await _openEditor(tester,
      initialConfig: _config,
      connectAfterSave: true,
      onSave: (config, name) async { saved = config; },
      onResult: (value) => result = value,
    );
    expect(find.text('Сохранить и подключить'), findsOneWidget);
    await _tapSave(tester);
    await tester.pumpAndSettle();
    expect(saved, _config);
    expect(result, _config);
    expect(find.byType(WireGuardProfileEditor), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Pending save blocks double submission, edits, close and system back',
      (tester) async {
    final pending = Completer<void>();
    var saves = 0;
    String? result;
    await _openEditor(tester,
      initialConfig: _config,
      onSave: (_, name) {
        saves++;
        return pending.future;
      },
      onResult: (value) => result = value,
    );
    await _tapSave(tester);
    await _tapEditorKey(tester, _save);
    await tester.pump();
    expect(saves, 1);
    expect(tester.widget<TextField>(find.byKey(_field)).enabled, isFalse);
    expect(tester.widget<FilledButton>(find.byKey(_save)).onPressed, isNull);
    expect(tester.widget<OutlinedButton>(find.byKey(_paste)).onPressed, isNull);
    expect(tester.widget<IconButton>(find.byKey(_close)).onPressed, isNull);
    expect(tester.widget<IconButton>(find.byKey(_visibility)).onPressed, isNull);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(WireGuardProfileEditor), findsOneWidget);
    expect(result, isNull);

    pending.complete();
    await tester.pumpAndSettle();
    expect(result, _config);
    expect(find.byType(WireGuardProfileEditor), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Save completion after disposal does not update or pop another screen',
      (tester) async {
    final pending = Completer<void>();
    await _openEditor(tester,
      initialConfig: _config,
      onSave: (_, name) => pending.future,
    );
    await _tapSave(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Recovery feedback is visible and cancelling does not save a draft',
      (tester) async {
    const recovery = 'Сохранённый профиль не удалось открыть. Добавьте профиль заново.';
    var saves = 0;
    var closed = false;
    String? result;
    await _openEditor(tester,
      initialError: recovery,
      onSave: (_, name) async { saves++; },
      onResult: (value) { closed = true; result = value; },
    );
    expect(find.text(recovery), findsOneWidget);
    await _tapEditorKey(tester, _close);
    await tester.pumpAndSettle();
    expect(saves, 0);
    expect(closed, isTrue);
    expect(result, isNull);
  });

  testWidgets('Save stays above the system navigation area and remains tappable',
      (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 48);
    tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 48);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    String? saved;
    String? result;
    await _openEditor(tester,
      initialConfig: _config,
      onSave: (config, name) async { saved = config; },
      onResult: (value) => result = value,
    );
    await tester.ensureVisible(find.byKey(_save));
    await tester.pumpAndSettle();
    final safeBottom = (tester.view.physicalSize.height - tester.view.padding.bottom)
        / tester.view.devicePixelRatio;
    expect(tester.getRect(find.byKey(_save)).bottom, lessThanOrEqualTo(safeBottom));
    await _tapEditorKey(tester, _save);
    await tester.pumpAndSettle();
    expect(saved, _config);
    expect(result, _config);
    expect(find.byType(WireGuardProfileEditor), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Expanded config remains usable with a keyboard on a compact phone',
      (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    String? result;
    await _openEditor(tester,
      initialConfig: _config,
      onSave: (_, name) async {},
      onResult: (value) => result = value,
    );
    await tester.ensureVisible(find.byKey(_visibility));
    await tester.pumpAndSettle();
    await _tapEditorKey(tester, _visibility);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(_field)).obscureText, isFalse);
    expect(tester.takeException(), isNull);
    await _tapSave(tester);
    await tester.pumpAndSettle();
    expect(result, _config);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Import replaces only a hidden draft until explicit save',
      (tester) async {
    const imported = '$_config\n# Imported draft\r\n';
    var reads = 0;
    var saves = 0;
    var cancels = 0;
    String? saved;
    String? result;
    await _openEditor(tester,
      initialConfig: _config,
      connectAfterSave: true,
      onImport: () async { reads++; return imported; },
      onCancelImport: () async { cancels++; },
      onSave: (config, name) async { saves++; saved = config; },
      onResult: (value) => result = value,
    );
    expect(reads, 0);
    await _tapEditorKey(tester, _visibility);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(_import));
    await _tapEditorKey(tester, _import);
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byKey(_field));
    expect(reads, 1);
    expect(saves, 0);
    expect(result, isNull);
    expect(field.controller!.text, imported);
    expect(field.obscureText, isTrue);
    expect(field.readOnly, isTrue);
    expect(field.focusNode!.hasFocus, isFalse);
    expect(field.controller!.selection, const TextSelection.collapsed(offset: -1));
    expect(find.text('Файл прочитан. Сохраните профиль.'), findsOneWidget);
    await _tapSave(tester);
    await tester.pumpAndSettle();
    expect(saves, 1);
    expect(saved, imported);
    expect(result, imported);
    expect(cancels, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Picker cancellation preserves the current draft without saving',
      (tester) async {
    var saves = 0;
    var cancels = 0;
    await _openEditor(tester,
      initialConfig: _config,
      onImport: () async => null,
      onCancelImport: () async { cancels++; },
      onSave: (_, name) async { saves++; },
    );
    await _tapEditorKey(tester, _import);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(_field)).controller!.text, _config);
    expect(find.byKey(const Key('wireguard_profile_error')), findsNothing);
    expect(find.byKey(const Key('wireguard_profile_notice')), findsNothing);
    expect(saves, 0);
    await _tapEditorKey(tester, _close);
    await tester.pumpAndSettle();
    expect(cancels, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Import errors preserve the draft and expose only safe messages',
      (tester) async {
    const secret = 'PRIVATE_FILE_PATH_AND_KEY';
    for (final failure in [
      ('PROFILE_IMPORT_TOO_LARGE', 'Файл слишком большой: максимум 65 536 байт.'),
      ('PROFILE_IMPORT_INVALID',
        'Нужен текстовый профиль .conf.'),
      ('PROFILE_IMPORT_BUSY', 'Выбор файла уже открыт. Завершите его и попробуйте ещё раз.'),
      ('PROFILE_IMPORT_SOURCE_BUSY',
        'Источник файлов пока занят. Попробуйте QR камерой или вставьте текст профиля.'),
      ('PROFILE_IMPORT_INTERRUPTED', 'Импорт прерван. Выберите файл ещё раз.'),
      ('PROFILE_IMPORT_TIMEOUT',
        'Источник файла не ответил вовремя. Повторите импорт или выберите файл из другого приложения.'),
      ('PROFILE_IMPORT_UNAVAILABLE',
        'Не удалось открыть выбор файла. Вставьте конфигурацию вручную.'),
      ('PROFILE_IMPORT_FAILED',
        'Не удалось прочитать файл. Выберите его заново или вставьте конфигурацию.'),
      ('UNEXPECTED_IMPORT_ERROR',
        'Не удалось прочитать файл. Выберите его заново или вставьте конфигурацию.'),
    ]) {
      var saves = 0;
      await _openEditor(tester,
        initialConfig: _config,
        onImport: () async => throw PlatformException(code: failure.$1,
          message: secret, details: {'uri': secret, 'privateKey': secret}),
        onSave: (_, name) async { saves++; },
      );
      await _tapEditorKey(tester, _import);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byKey(_field)).controller!.text, _config);
      expect(find.text(failure.$2), findsOneWidget);
      expect(find.textContaining(secret), findsNothing);
      expect(find.byKey(const Key('wireguard_profile_notice')), findsNothing);
      expect(saves, 0);
      expect(tester.widget<OutlinedButton>(find.byKey(_import)).onPressed, isNotNull);
      await tester.ensureVisible(find.byKey(_close));
      await _tapEditorKey(tester, _close);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('Malformed import results cannot overwrite an existing draft',
      (tester) async {
    // Native parsing validates full .conf syntax; the editor also rejects values
    // it already knows cannot be saved if an older/faulty bridge returns them.
    for (final invalid in [' \n ', 'x' * 65537,
        '00000000-0000-4000-8000-000000000000']) {
      var saves = 0;
      await _openEditor(tester,
        initialConfig: _config,
        onImport: () async => invalid,
        onSave: (_, name) async { saves++; },
      );
      await _tapEditorKey(tester, _import);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byKey(_field)).controller!.text, _config);
      expect(find.byKey(const Key('wireguard_profile_error')), findsOneWidget);
      expect(find.byKey(const Key('wireguard_profile_notice')), findsNothing);
      expect(saves, 0);
      await tester.ensureVisible(find.byKey(_close));
      await _tapEditorKey(tester, _close);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('Pending import blocks concurrent edits and stale action callbacks',
      (tester) async {
    final pending = Completer<String?>();
    var reads = 0;
    var saves = 0;
    var clipboardReads = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') {
        clipboardReads++;
        return {'text': _config};
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await _openEditor(tester,
      initialConfig: _config,
      onImport: () { reads++; return pending.future; },
      onSave: (_, name) async { saves++; },
    );
    final queuedImport = tester.widget<OutlinedButton>(find.byKey(_import)).onPressed!;
    final queuedPaste = tester.widget<OutlinedButton>(find.byKey(_paste)).onPressed!;
    final queuedSave = tester.widget<FilledButton>(find.byKey(_save)).onPressed!;
    final queuedReveal = tester.widget<IconButton>(find.byKey(_visibility)).onPressed!;
    queuedImport();
    queuedImport();
    queuedPaste();
    queuedSave();
    queuedReveal();
    await tester.pump();
    expect(reads, 1);
    expect(saves, 0);
    expect(clipboardReads, 0);
    expect(tester.widget<TextField>(find.byKey(_field)).enabled, isFalse);
    expect(tester.widget<TextField>(find.byKey(_field)).obscureText, isTrue);
    expect(tester.widget<OutlinedButton>(find.byKey(_import)).onPressed, isNull);
    expect(tester.widget<OutlinedButton>(find.byKey(_paste)).onPressed, isNull);
    expect(tester.widget<FilledButton>(find.byKey(_save)).onPressed, isNull);
    expect(tester.widget<IconButton>(find.byKey(_close)).onPressed, isNotNull);
    pending.complete(_config);
    await tester.pumpAndSettle();
    await _tapEditorKey(tester, _close);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Closing a pending import cancels once and rejects its closing-frame reply',
      (tester) async {
    final pending = Completer<String?>();
    var cancels = 0;
    var saves = 0;
    await _openEditor(tester,
      initialConfig: _config,
      onImport: () => pending.future,
      onCancelImport: () async { cancels++; },
      onSave: (_, name) async { saves++; },
    );
    await _tapEditorKey(tester, _import);
    await tester.pump();
    await _tapEditorKey(tester, _close);
    await tester.pump(const Duration(milliseconds: 20));
    expect(cancels, 1);
    pending.complete('$_config\n# Late file\n');
    await tester.pumpAndSettle();
    expect(find.byType(WireGuardProfileEditor), findsNothing);
    expect(find.text('Файл прочитан. Сохраните профиль.'), findsNothing);
    expect(saves, 0);
    expect(cancels, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Disposal tolerates cancellation failure and a late import error',
      (tester) async {
    final pending = Completer<String?>();
    var cancels = 0;
    await _openEditor(tester,
      initialConfig: _config,
      onImport: () => pending.future,
      onCancelImport: () async {
        cancels++;
        throw PlatformException(code: 'CANCEL_FAILED', message: 'PRIVATE_CANCEL_DETAIL');
      },
      onSave: (_, name) async {},
    );
    await _tapEditorKey(tester, _import);
    await tester.pump();
    // Replacing one MaterialApp with another can retain its Navigator/routes.
    // Remove the old tree first so this actually exercises editor disposal.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: Text('Следующий экран')),
    ));
    pending.completeError(PlatformException(code: 'PROFILE_IMPORT_FAILED',
      message: 'PRIVATE_FILE_DETAIL'));
    await tester.pumpAndSettle();
    expect(cancels, 1);
    expect(find.text('Следующий экран'), findsOneWidget);
    expect(find.textContaining('PRIVATE_'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('File result before resume stays masked and cannot trigger queued save',
      (tester) async {
    final pending = Completer<String?>();
    const imported = '$_config\n# Before resume\n';
    var saves = 0;
    addTearDown(() => tester.binding
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed));
    await _openEditor(tester,
      initialConfig: _config,
      onImport: () => pending.future,
      onSave: (_, name) async { saves++; },
    );
    final queuedSave = tester.widget<FilledButton>(find.byKey(_save)).onPressed!;
    final queuedImport = tester.widget<OutlinedButton>(find.byKey(_import)).onPressed!;
    await _tapEditorKey(tester, _visibility);
    await tester.pumpAndSettle();
    await _tapEditorKey(tester, _import);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    pending.complete(imported);
    await tester.pumpAndSettle();
    queuedSave();
    queuedImport();
    await tester.pump();
    var field = tester.widget<TextField>(find.byKey(_field));
    expect(field.controller!.text, imported);
    expect(field.obscureText, isTrue);
    expect(field.focusNode!.hasFocus, isFalse);
    expect(saves, 0);
    expect(tester.widget<FilledButton>(find.byKey(_save)).onPressed, isNull);
    expect(tester.widget<OutlinedButton>(find.byKey(_import)).onPressed, isNull);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    field = tester.widget<TextField>(find.byKey(_field));
    expect(field.obscureText, isTrue);
    expect(field.controller!.text, imported);
    await _tapSave(tester);
    await tester.pumpAndSettle();
    expect(saves, 1);
    expect(tester.takeException(), isNull);
  });

  for (final source in [('camera', _scanQr), ('image', _qrImage)]) {
    testWidgets('${source.$1} QR replaces only the masked draft and preserves its name',
        (tester) async {
      const imported = '$_config\n# QR draft\r\n';
      var cameraReads = 0;
      var imageReads = 0;
      var saves = 0;
      String? saved;
      await _openEditor(tester, initialConfig: _config, initialName: 'Мой сервер',
        onScanQr: () async { cameraReads++; return imported; },
        onImportQrImage: () async { imageReads++; return imported; },
        onSave: (config, name) async { saves++; saved = config; },
      );
      await _tapEditorKey(tester, _visibility);
      await tester.pumpAndSettle();
      await _tapEditorKey(tester, source.$2);
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(find.byKey(_field));
      expect(cameraReads, source.$1 == 'camera' ? 1 : 0);
      expect(imageReads, source.$1 == 'image' ? 1 : 0);
      expect(field.controller!.text, imported);
      expect(field.obscureText, isTrue);
      expect(field.readOnly, isTrue);
      expect(field.controller!.selection, const TextSelection.collapsed(offset: -1));
      expect(tester.widget<TextField>(find.byKey(_name)).controller!.text, 'Мой сервер');
      expect(find.text('QR-код прочитан. Сохраните профиль.'), findsOneWidget);
      expect(saves, 0);
      await _tapSave(tester);
      await tester.pumpAndSettle();
      expect(saves, 1);
      expect(saved, imported);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Cancelling either QR source preserves both existing inputs without saving',
      (tester) async {
    for (final key in [_scanQr, _qrImage]) {
      var saves = 0;
      await _openEditor(tester, initialConfig: _config, initialName: 'Дом',
        onScanQr: () async => null,
        onImportQrImage: () async => null,
        onSave: (_, name) async { saves++; },
      );
      await _tapEditorKey(tester, key);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byKey(_field)).controller!.text, _config);
      expect(tester.widget<TextField>(find.byKey(_field)).obscureText, isTrue);
      expect(tester.widget<TextField>(find.byKey(_name)).controller!.text, 'Дом');
      expect(find.byKey(const Key('wireguard_profile_notice')), findsNothing);
      expect(find.byKey(const Key('wireguard_profile_error')), findsNothing);
      expect(saves, 0);
      await _tapEditorKey(tester, _close);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('QR permission and decoding failures keep the draft and expose no native data',
      (tester) async {
    for (final failure in [
      ('PROFILE_QR_CAMERA_DENIED', 'Для сканирования нужен доступ к камере.'),
      ('PROFILE_QR_UNAVAILABLE', 'Сканирование QR недоступно.'),
      ('PROFILE_QR_NOT_FOUND', 'На изображении не найден QR-код.'),
      ('PROFILE_QR_MULTIPLE',
        'Нужен один полный QR-код. Части составного кода и несколько кодов одновременно не поддерживаются.'),
      ('PROFILE_QR_IMAGE_TOO_LARGE', 'Изображение слишком большое.'),
      ('PROFILE_IMPORT_INVALID', 'В QR-коде нет поддерживаемого профиля.'),
      ('INVALID_VLESS_CONFIG', 'В этой версии доступен WireGuard.'),
      ('UNSUPPORTED_PROFILE', 'Этот формат пока не поддерживается.'),
      ('UNSUPPORTED_TRANSPORT', 'Для подключения нужен профиль .conf.'),
      ('UNSUPPORTED_SECURITY', 'Для подключения нужен профиль .conf.'),
      ('UNSUPPORTED_PROFILE_OPTION', 'Для подключения нужен профиль .conf.'),
      ('UNKNOWN_QR_ERROR', 'Не удалось прочитать QR-код.'),
    ]) {
      var saves = 0;
      await _openEditor(tester, initialConfig: _config, initialName: 'Дом',
        onScanQr: () async => throw PlatformException(code: failure.$1,
          message: 'PRIVATE_QR_CONTENT', details: {'payload': 'PRIVATE_QR_CONTENT'}),
        onSave: (_, name) async { saves++; },
      );
      await _tapEditorKey(tester, _scanQr);
      await tester.pumpAndSettle();
      expect(find.textContaining(failure.$2), findsOneWidget);
      expect(find.textContaining('PRIVATE_QR_CONTENT'), findsNothing);
      expect(tester.widget<TextField>(find.byKey(_field)).controller!.text, _config);
      expect(tester.widget<TextField>(find.byKey(_name)).controller!.text, 'Дом');
      expect(tester.widget<TextField>(find.byKey(_field)).obscureText, isTrue);
      expect(tester.widget<OutlinedButton>(find.byKey(_scanQr)).onPressed, isNotNull);
      expect(saves, 0);
      await _tapEditorKey(tester, _close);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
  });

  for (final source in [
    ('file', _import, 'PROFILE_IMPORT_INVALID', 'Файл'),
    ('camera', _scanQr, 'PROFILE_QR_CAMERA_DENIED', 'Камера QR'),
    ('image', _qrImage, 'PROFILE_QR_NOT_FOUND', 'QR из фото'),
    ('file timeout', _import, 'PROFILE_IMPORT_TIMEOUT', 'Файл'),
    ('image timeout', _qrImage, 'PROFILE_IMPORT_TIMEOUT', 'QR из фото'),
    ('file source busy', _import, 'PROFILE_IMPORT_SOURCE_BUSY', 'Файл'),
    ('image source busy', _qrImage, 'PROFILE_IMPORT_SOURCE_BUSY', 'QR из фото'),
    ('camera multiple', _scanQr, 'PROFILE_QR_MULTIPLE', 'Камера QR'),
  ]) {
    final kind = source.$1;
    testWidgets('$kind error copies fixed diagnostics only after an explicit tap',
        (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final writes = <String>[];
      _captureClipboardWrites(writes);
      final code = source.$3;
      final label = source.$4;
      Future<String?> fail() async => throw PlatformException(code: code,
          message: 'PRIVATE_NATIVE_MESSAGE',
          details: {'address': 'PRIVATE_SERVER', 'privateKey': 'PRIVATE_KEY'});
      await _openEditor(tester, textScale: 2.2,
        initialConfig: _vless, initialName: 'PRIVATE_PROFILE_NAME',
        onImport: fail, onScanQr: fail, onImportQrImage: fail,
        onSave: (_, _) async {},
      );
      expect(find.byKey(_copyImportError), findsNothing);
      expect(writes, isEmpty);
      await _tapEditorKey(tester, source.$2);
      await tester.pumpAndSettle();
      final message = tester.widget<Text>(
          find.byKey(const Key('wireguard_profile_error'))).data!;
      expect(writes, isEmpty);
      expect(find.byKey(_copyImportError), findsOneWidget);
      await tester.ensureVisible(find.byKey(_copyImportError));
      await tester.pumpAndSettle();
      final button = tester.getRect(find.byKey(_copyImportError));
      expect(button.left, greaterThanOrEqualTo(0));
      expect(button.right, lessThanOrEqualTo(360));
      expect(find.byKey(_copyImportError).hitTestable(), findsOneWidget);
      await _tapEditorKey(tester, _copyImportError);
      await tester.pumpAndSettle();
      expect(writes, [
        'Pushok Flow — ошибка импорта профиля\n'
        'Источник: $label\nКод: $code\n$message',
      ]);
      for (final private in ['PRIVATE_', _vless, 'example.invalid',
          '00000000-0000-4000-8000-000000000001']) {
        expect(writes.single, isNot(contains(private)));
      }
      expect(find.text('Текст ошибки скопирован.'), findsOneWidget);
      expect(tester.widget<TextField>(find.byKey(_field)).controller!.text, _vless);
      expect(tester.widget<TextField>(find.byKey(_field)).obscureText, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Unknown native codes and unexpected exceptions cannot enter copied diagnostics',
      (tester) async {
    final writes = <String>[];
    _captureClipboardWrites(writes);
    for (final failure in [
      PlatformException(code: 'PRIVATE_UNKNOWN_CODE\nPRIVATE_KEY',
          message: 'PRIVATE_NATIVE_MESSAGE', details: {'uri': 'PRIVATE_DOCUMENT_URI'}),
      StateError('PRIVATE_UNEXPECTED_EXCEPTION'),
    ]) {
      await _openEditor(tester, initialConfig: _config,
        onImportQrImage: () async => throw failure,
        onSave: (_, _) async {},
      );
      await _tapEditorKey(tester, _qrImage);
      await tester.pumpAndSettle();
      final before = writes.length;
      await _tapEditorKey(tester, _copyImportError);
      await tester.pumpAndSettle();
      expect(writes, hasLength(before + 1));
      expect(writes.last, contains('Код: PROFILE_IMPORT_FAILED'));
      expect(writes.last, contains('Источник: QR из фото'));
      expect(writes.last, contains('Не удалось прочитать QR-код.'));
      expect(writes.last, isNot(contains('PRIVATE_')));
      expect(writes.last, isNot(contains('ui-test-key')));
      expect(find.textContaining('PRIVATE_'), findsNothing);
      await _tapEditorKey(tester, _close);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('Client-side import validation exports a safe code without the returned value',
      (tester) async {
    final writes = <String>[];
    _captureClipboardWrites(writes);
    for (final invalid in [
      ('https://private.example.invalid/subscription/PRIVATE_SUBSCRIPTION', 'UNSUPPORTED_PROFILE'),
      ('00000000-0000-4000-8000-000000000002', 'INVALID_VLESS_CONFIG'),
      ('PRIVATE_PROFILE' * 6000, 'PROFILE_IMPORT_TOO_LARGE'),
    ]) {
      await _openEditor(tester, initialConfig: _config,
        onImport: () async => invalid.$1,
        onSave: (_, _) async {},
      );
      await _tapEditorKey(tester, _import);
      await tester.pumpAndSettle();
      await _tapEditorKey(tester, _copyImportError);
      await tester.pumpAndSettle();
      final code = invalid.$2;
      expect(writes.last, contains('Код: $code'));
      expect(writes.last, contains('Источник: Файл'));
      expect(writes.last, isNot(contains(invalid.$1)));
      expect(writes.last, isNot(contains('PRIVATE_')));
      expect(writes.last, isNot(contains('example.invalid')));
      expect(tester.widget<TextField>(find.byKey(_field)).controller!.text, _config);
      await _tapEditorKey(tester, _close);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('Retry clears old import diagnostics and cancellation or success never restores them',
      (tester) async {
    final writes = <String>[];
    _captureClipboardWrites(writes);
    final retry = Completer<String?>();
    var reads = 0;
    await _openEditor(tester, initialConfig: _config,
      onImportQrImage: () async {
        reads++;
        if (reads == 1 || reads == 3) {
          throw PlatformException(code: 'PROFILE_QR_NOT_FOUND');
        }
        if (reads == 2) return retry.future;
        return _vlessGrpc;
      },
      onSave: (_, _) async {},
    );
    await _tapEditorKey(tester, _qrImage);
    await tester.pumpAndSettle();
    final oldCopy = tester.widget<TextButton>(find.byKey(_copyImportError)).onPressed!;
    await _tapEditorKey(tester, _copyImportError);
    await tester.pumpAndSettle();
    expect(writes, hasLength(1));
    expect(find.byKey(_copyImportNotice), findsOneWidget);

    await _tapEditorKey(tester, _qrImage);
    await tester.pump();
    expect(find.byKey(_copyImportError), findsNothing);
    expect(find.byKey(_copyImportNotice), findsNothing);
    oldCopy();
    await tester.pump();
    expect(writes, hasLength(1));
    retry.complete(null);
    await tester.pumpAndSettle();
    oldCopy();
    await tester.pump();
    expect(writes, hasLength(1));
    expect(find.byKey(_copyImportError), findsNothing);
    expect(find.byKey(const Key('wireguard_profile_error')), findsNothing);
    expect(tester.widget<TextField>(find.byKey(_field)).controller!.text, _config);

    await _tapEditorKey(tester, _qrImage);
    await tester.pumpAndSettle();
    expect(find.byKey(_copyImportError), findsOneWidget);
    oldCopy();
    await tester.pump();
    expect(writes, hasLength(1));
    await _tapEditorKey(tester, _qrImage);
    await tester.pumpAndSettle();
    expect(find.byKey(_copyImportError), findsNothing);
    expect(find.byKey(_copyImportNotice), findsNothing);
    expect(find.text('QR-код прочитан. Сохраните профиль.'), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(_field)).controller!.text, _vlessGrpc);
    expect(tester.widget<TextField>(find.byKey(_field)).obscureText, isTrue);
    expect(writes, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Editing, pasting and saving remove an earlier import diagnostic',
      (tester) async {
    final writes = <String>[];
    _captureClipboardWrites(writes, pasteText: _vless);
    for (final action in ['name', 'config', 'paste', 'save']) {
      await _openEditor(tester, initialConfig: _config,
        onImportQrImage: () async => throw PlatformException(code: 'PROFILE_QR_NOT_FOUND'),
        onSave: (_, _) async => throw PlatformException(code: 'INVALID_CONFIG'),
      );
      await _tapEditorKey(tester, _qrImage);
      await tester.pumpAndSettle();
      final oldCopy = tester.widget<TextButton>(find.byKey(_copyImportError)).onPressed!;
      await _tapEditorKey(tester, _copyImportError);
      await tester.pumpAndSettle();
      final copies = writes.length;
      if (action == 'name') {
        await tester.ensureVisible(find.byKey(_name));
        await tester.enterText(find.byKey(_name), 'Новое название');
      } else if (action == 'config') {
        await _tapEditorKey(tester, _visibility);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(_field));
        await tester.enterText(find.byKey(_field), _vless);
      } else if (action == 'paste') {
        await _tapEditorKey(tester, _paste);
      } else {
        await _tapSave(tester);
      }
      await tester.pumpAndSettle();
      oldCopy();
      await tester.pump();
      expect(writes, hasLength(copies), reason: action);
      expect(find.byKey(_copyImportError), findsNothing, reason: action);
      expect(find.byKey(_copyImportNotice), findsNothing, reason: action);
      await _tapEditorKey(tester, _close);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('An import error before resume cannot copy until a new foreground action',
      (tester) async {
    addTearDown(() => tester.binding
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed));
    final writes = <String>[];
    _captureClipboardWrites(writes);
    final read = Completer<String?>();
    await _openEditor(tester, initialConfig: _config,
      onImportQrImage: () => read.future,
      onSave: (_, _) async {},
    );
    await _tapEditorKey(tester, _qrImage);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    read.completeError(PlatformException(code: 'PROFILE_QR_NOT_FOUND',
        message: 'PRIVATE_BACKGROUND_ERROR'));
    await tester.pumpAndSettle();
    expect(writes, isEmpty);
    expect(tester.widget<TextButton>(find.byKey(_copyImportError)).onPressed, isNull);
    expect(tester.widget<TextField>(find.byKey(_field)).obscureText, isTrue);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    final queuedCopy = tester.widget<TextButton>(find.byKey(_copyImportError)).onPressed!;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    queuedCopy();
    await tester.pumpAndSettle();
    expect(writes, isEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    await _tapEditorKey(tester, _copyImportError);
    await tester.pumpAndSettle();
    expect(writes, hasLength(1));
    expect(writes.single, isNot(contains('PRIVATE_')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('A pending clipboard response cannot restore diagnostics after successful import',
      (tester) async {
    final writes = <String>[];
    final copied = Completer<void>();
    _captureClipboardWrites(writes, onWrite: () => copied.future);
    var reads = 0;
    await _openEditor(tester, initialConfig: _config,
      onImportQrImage: () async {
        if (++reads == 1) throw PlatformException(code: 'PROFILE_QR_NOT_FOUND');
        return _vlessWs;
      },
      onSave: (_, _) async {},
    );
    await _tapEditorKey(tester, _qrImage);
    await tester.pumpAndSettle();
    await _tapEditorKey(tester, _copyImportError);
    await tester.pump();
    expect(writes, hasLength(1));
    expect(tester.widget<TextButton>(find.byKey(_copyImportError)).onPressed, isNull);
    await _tapEditorKey(tester, _qrImage);
    await tester.pump();
    expect(find.byKey(_copyImportError), findsNothing);
    copied.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(_copyImportNotice), findsNothing);
    expect(find.byKey(const Key('wireguard_profile_error')), findsNothing);
    expect(find.text('QR-код прочитан. Сохраните профиль.'), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(_field)).controller!.text, _vlessWs);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Clipboard failures preserve the import error and permit a safe retry',
      (tester) async {
    final writes = <String>[];
    var failCopy = true;
    _captureClipboardWrites(writes, onWrite: () async {
      if (failCopy) {
        throw PlatformException(code: 'PRIVATE_CLIPBOARD_CODE',
            message: 'PRIVATE_CLIPBOARD_MESSAGE', details: {'key': 'PRIVATE_KEY'});
      }
    });
    await _openEditor(tester, initialConfig: _config,
      onImport: () async => throw PlatformException(code: 'PROFILE_IMPORT_INVALID'),
      onSave: (_, _) async {},
    );
    await _tapEditorKey(tester, _import);
    await tester.pumpAndSettle();
    final error = tester.widget<Text>(
        find.byKey(const Key('wireguard_profile_error'))).data;
    await _tapEditorKey(tester, _copyImportError);
    await tester.pumpAndSettle();
    expect(find.text('Не удалось скопировать текст ошибки. Попробуйте ещё раз.'), findsOneWidget);
    expect(find.textContaining('PRIVATE_'), findsNothing);
    expect(tester.widget<Text>(find.byKey(const Key('wireguard_profile_error'))).data, error);
    expect(tester.widget<TextField>(find.byKey(_field)).controller!.text, _config);
    expect(tester.widget<TextButton>(find.byKey(_copyImportError)).onPressed, isNotNull);
    failCopy = false;
    await _tapEditorKey(tester, _copyImportError);
    await tester.pumpAndSettle();
    expect(writes, hasLength(2));
    expect(writes[0], writes[1]);
    expect(find.text('Текст ошибки скопирован.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('A late clipboard completion after disposal cannot show feedback on another screen',
      (tester) async {
    final writes = <String>[];
    final copied = Completer<void>();
    _captureClipboardWrites(writes, onWrite: () => copied.future);
    await _openEditor(tester, initialConfig: _config,
      onScanQr: () async => throw PlatformException(code: 'PROFILE_QR_NOT_FOUND'),
      onSave: (_, _) async {},
    );
    await _tapEditorKey(tester, _scanQr);
    await tester.pumpAndSettle();
    await _tapEditorKey(tester, _copyImportError);
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: Text('Следующий экран')),
    ));
    copied.completeError(PlatformException(code: 'PRIVATE_CLIPBOARD_FAILURE'));
    await tester.pumpAndSettle();
    expect(writes, hasLength(1));
    expect(find.text('Следующий экран'), findsOneWidget);
    expect(find.byKey(_copyImportNotice), findsNothing);
    expect(find.textContaining('PRIVATE_'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('A pending QR scan blocks every competing import and stale callbacks',
      (tester) async {
    final pending = Completer<String?>();
    var cameraReads = 0;
    var imageReads = 0;
    var fileReads = 0;
    var saves = 0;
    await _openEditor(tester, initialConfig: _config,
      onScanQr: () { cameraReads++; return pending.future; },
      onImportQrImage: () async { imageReads++; return _config; },
      onImport: () async { fileReads++; return _config; },
      onSave: (_, name) async { saves++; },
    );
    final camera = tester.widget<OutlinedButton>(find.byKey(_scanQr)).onPressed!;
    final image = tester.widget<OutlinedButton>(find.byKey(_qrImage)).onPressed!;
    final file = tester.widget<OutlinedButton>(find.byKey(_import)).onPressed!;
    final save = tester.widget<FilledButton>(find.byKey(_save)).onPressed!;
    camera();
    camera();
    image();
    file();
    save();
    await tester.pump();
    expect(cameraReads, 1);
    expect(imageReads, 0);
    expect(fileReads, 0);
    expect(saves, 0);
    for (final key in [_paste, _import, _scanQr, _qrImage]) {
      expect(tester.widget<OutlinedButton>(find.byKey(key)).onPressed, isNull);
    }
    expect(tester.widget<FilledButton>(find.byKey(_save)).onPressed, isNull);
    expect(tester.widget<IconButton>(find.byKey(_info)).onPressed, isNull);
    pending.complete(_config);
    await tester.pumpAndSettle();
    await _tapEditorKey(tester, _close);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Closing a pending QR scan cancels once and cannot replace a newer editor draft',
      (tester) async {
    final pending = Completer<String?>();
    var cancels = 0;
    var saves = 0;
    await _openEditor(tester, initialConfig: _config,
      onScanQr: () => pending.future,
      onCancelImport: () async { cancels++; },
      onSave: (_, name) async { saves++; },
    );
    await _tapEditorKey(tester, _scanQr);
    await tester.pump();
    await _tapEditorKey(tester, _close);
    await tester.pumpAndSettle();
    expect(cancels, 1);
    const newer = '$_config\n# Another editor\n';
    await _openEditor(tester, initialConfig: newer,
      onSave: (_, name) async { saves++; },
    );
    pending.complete('$_config\n# Late QR\n');
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(_field)).controller!.text, newer);
    expect(find.byKey(const Key('wireguard_profile_notice')), findsNothing);
    expect(saves, 0);
    expect(cancels, 1);
    await _tapEditorKey(tester, _close);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('QR result before resume stays hidden and cannot run an earlier save callback',
      (tester) async {
    final pending = Completer<String?>();
    const imported = '$_config\n# QR before resume\n';
    var saves = 0;
    addTearDown(() => tester.binding
      .handleAppLifecycleStateChanged(AppLifecycleState.resumed));
    await _openEditor(tester, initialConfig: _config,
      onScanQr: () => pending.future,
      onSave: (_, name) async { saves++; },
    );
    final queuedSave = tester.widget<FilledButton>(find.byKey(_save)).onPressed!;
    await _tapEditorKey(tester, _scanQr);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    pending.complete(imported);
    await tester.pumpAndSettle();
    queuedSave();
    await tester.pump();
    expect(tester.widget<TextField>(find.byKey(_field)).controller!.text, imported);
    expect(tester.widget<TextField>(find.byKey(_field)).obscureText, isTrue);
    expect(tester.widget<FilledButton>(find.byKey(_save)).onPressed, isNull);
    expect(saves, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(_field)).obscureText, isTrue);
    await _tapSave(tester);
    await tester.pumpAndSettle();
    expect(saves, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('QR actions and guidance remain usable on a compact phone with large text',
      (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 48);
    tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 48);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    var cameraReads = 0;
    var imageReads = 0;
    String? saved;
    await _openEditor(tester, textScale: 2.2,
      onImport: () async => _config,
      onScanQr: () async { cameraReads++; return _config; },
      onImportQrImage: () async { imageReads++; return _config; },
      onSave: (config, name) async { saved = config; },
    );
    for (final key in [_scanQr, _qrImage]) {
      await tester.ensureVisible(find.byKey(key));
      await tester.pumpAndSettle();
      final rect = tester.getRect(find.byKey(key));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(360));
      expect(find.byKey(key).hitTestable(), findsOneWidget);
      await _tapEditorKey(tester, key);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    expect(cameraReads, 1);
    expect(imageReads, 1);
    expect(saved, isNull);
    await _tapEditorKey(tester, _info);
    await tester.pumpAndSettle();
    expect(find.textContaining('QR из панели сервера'), findsOneWidget);
    expect(find.textContaining('WireGuard нужен полный профиль .conf'), findsOneWidget);
    expect(find.textContaining('В 3x-ui'), findsNothing);
    expect(find.textContaining('на видео он может выглядеть чёрным'), findsOneWidget);
    expect(find.textContaining('Конфигурация и ключи в него не входят.'), findsOneWidget);
    expect(find.textContaining('QR из фото'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Понятно'));
    await tester.pump();
    await tester.tap(find.text('Понятно'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(_save));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byKey(_save)).bottom, lessThanOrEqualTo(592));
    await _tapSave(tester);
    await tester.pumpAndSettle();
    expect(saved, _config);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Import and save remain reachable on a compact phone with large text',
      (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 48);
    tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 48);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    String? saved;
    await _openEditor(tester,
      textScale: 2.2,
      onImport: () async => _config,
      onSave: (config, name) async { saved = config; },
    );
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.byKey(_import));
    await tester.pumpAndSettle();
    final importRect = tester.getRect(find.byKey(_import));
    expect(importRect.left, greaterThanOrEqualTo(0));
    expect(importRect.right, lessThanOrEqualTo(360));
    await _tapEditorKey(tester, _import);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(_save));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byKey(_save)).bottom, lessThanOrEqualTo(592));
    await _tapEditorKey(tester, _save);
    await tester.pumpAndSettle();
    expect(saved, _config);
    expect(tester.takeException(), isNull);
  });
}
