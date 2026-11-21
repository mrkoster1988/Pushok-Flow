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
const _save = Key('save_wireguard_profile');
const _paste = Key('paste_wireguard_profile');
const _close = Key('close_wireguard_profile');
const _visibility = Key('toggle_wireguard_profile_visibility');

Future<void> _openEditor(
  WidgetTester tester, {
  required Future<void> Function(String) onSave,
  String initialConfig = '',
  String? initialError,
  bool connectAfterSave = false,
  ValueChanged<String?>? onResult,
}) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pumpWidget(MaterialApp(
    theme: buildPushokTheme(),
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
              initialError: initialError,
              onSave: onSave,
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

Future<void> _tapSave(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(_save));
  await tester.tap(find.byKey(_save));
  await tester.pump();
}

void main() {
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
      onSave: (config) async { saved = config; },
      onResult: (value) => result = value,
    );
    expect(clipboardReads, 0);
    expect(tester.widget<TextField>(find.byKey(_field)).obscureText, isTrue);
    expect(tester.widget<TextField>(find.byKey(_field)).readOnly, isTrue);
    await tester.tap(find.byKey(_field));
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isFalse);
    await tester.tap(find.byKey(_paste));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byKey(_field));
    expect(clipboardReads, 1);
    expect(field.controller!.text, _config);
    expect(field.obscureText, isTrue);
    expect(field.readOnly, isTrue);
    expect(field.maxLines, 1);
    expect(field.autofillHints, isNull);
    await tester.tap(find.byKey(_visibility));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(_field)).obscureText, isFalse);
    expect(tester.widget<TextField>(find.byKey(_field)).readOnly, isFalse);
    await tester.tap(find.byKey(_visibility));
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
      onSave: (config) async { saved = config; },
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
      await tester.tap(find.byKey(_visibility));
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
    await tester.tap(find.byKey(_visibility));
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
      onSave: (config) async { saved = config; },
    );
    await tester.tap(find.byKey(_visibility));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_paste));
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
      onSave: (config) { submitted = config; return pending.future; },
    );
    await tester.tap(find.byKey(_visibility));
    await tester.pumpAndSettle();
    await _tapSave(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(tester.widget<TextField>(find.byKey(_field)).obscureText, isTrue);
    expect(tester.widget<TextField>(find.byKey(_field)).enabled, isFalse);
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
    await tester.tap(find.byKey(_close));
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
      onSave: (_) async {},
    );
    await tester.tap(find.byKey(_paste));
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
        onSave: (_) async { saves++; },
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
        onSave: (_) async => throw PlatformException(
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
      onSave: (config) async { saved = config; },
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
      onSave: (_) {
        saves++;
        return pending.future;
      },
      onResult: (value) => result = value,
    );
    await _tapSave(tester);
    await tester.tap(find.byKey(_save));
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
      onSave: (_) => pending.future,
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
      onSave: (_) async { saves++; },
      onResult: (value) { closed = true; result = value; },
    );
    expect(find.text(recovery), findsOneWidget);
    await tester.tap(find.byKey(_close));
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
      onSave: (config) async { saved = config; },
      onResult: (value) => result = value,
    );
    await tester.ensureVisible(find.byKey(_save));
    await tester.pumpAndSettle();
    final safeBottom = (tester.view.physicalSize.height - tester.view.padding.bottom)
        / tester.view.devicePixelRatio;
    expect(tester.getRect(find.byKey(_save)).bottom, lessThanOrEqualTo(safeBottom));
    await tester.tap(find.byKey(_save));
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
      onSave: (_) async {},
      onResult: (value) => result = value,
    );
    await tester.tap(find.byKey(_visibility));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await _tapSave(tester);
    await tester.pumpAndSettle();
    expect(result, _config);
    expect(tester.takeException(), isNull);
  });
}
