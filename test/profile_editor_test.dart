import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pushok_flow/design/pushok_theme.dart';
import 'package:pushok_flow/ui/wireguard_profile_editor.dart';

// Local UI fixture only; native parsing and key validation belong to the bridge.
const _config = '[Interface]\nPrivateKey = ui-test-key\n'
    'Address = 10.0.0.2/32\n[Peer]\nPublicKey = ui-test-peer\n';
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
    ('blank', ' \n ', 'Вставьте конфигурацию WireGuard перед сохранением.'),
    ('oversized', 'x' * 65537, 'Профиль слишком большой: максимум 65 536 символов.'),
    ('UUID', ' 00000000-0000-4000-8000-000000000000\n',
      'Вставлен UUID. Для WireGuard нужен полный текст файла .conf '
      'с разделами [Interface] и [Peer].'),
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
    ('INVALID_CONFIG', 'Некорректный профиль WireGuard. Проверьте конфигурацию.'),
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
        'Нужен полный текстовый профиль WireGuard .conf с разделами [Interface] и [Peer].'),
      ('PROFILE_IMPORT_BUSY', 'Выбор файла уже открыт. Завершите его и попробуйте ещё раз.'),
      ('PROFILE_IMPORT_INTERRUPTED', 'Импорт прерван. Выберите файл ещё раз.'),
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
      ('PROFILE_QR_MULTIPLE', 'На изображении несколько QR-кодов.'),
      ('PROFILE_QR_IMAGE_TOO_LARGE', 'Изображение слишком большое.'),
      ('PROFILE_IMPORT_INVALID', 'В QR-коде нет полного профиля WireGuard.'),
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
    expect(find.textContaining('В WGDashboard'), findsOneWidget);
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
