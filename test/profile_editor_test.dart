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

  for (final invalid in [
    ('blank', ' \n ', 'Вставьте конфигурацию WireGuard перед сохранением.'),
    ('oversized', 'x' * 65537, 'Профиль слишком большой: максимум 65 536 символов.'),
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
