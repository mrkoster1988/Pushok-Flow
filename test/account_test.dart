import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pushok_flow/design/pushok_theme.dart';
import 'package:pushok_flow/platform/account.dart';
import 'package:pushok_flow/ui/account_card.dart';

const _id = '10000000-0000-4000-8000-000000000001';
const _code = '23AB45CD67EF';

Map<String, Object?> _profile() => {
  'id': _id, 'displayName': 'Проверочный аккаунт', 'role': 'user',
  'phoneVerified': true, 'wallet': {'RUB': 123456, 'BONUS': -129, 'XTR': 42},
};

Map<String, Object?> _state({String state = 'signed_out', String? error,
    bool stale = false, int? nextPollAt, Map<String, Object?>? profile}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return {
    'state': state, 'busy': false, 'errorCode': error,
    'pending': state == 'pending' ? {
      'userCode': _code, 'expiresAt': now + 300000, 'nextPollAt': nextPollAt ?? now + 5000,
    } : null,
    'profile': state == 'connected' ? profile ?? _profile() : null,
    'refreshedAt': state == 'connected' ? now : null,
    'sessionExpiresAt': state == 'connected' ? now + 43200000 : null,
    'stale': stale,
  };
}

class _AccountBridge {
  Map<String, Object?> state = _state();
  final calls = <MethodCall>[];
  final gates = <String, Completer<Object?>>{};
  Object? statusError;
  String? logoutError;

  int count(String method) => calls.where((call) => call.method == method).length;

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    expect(call.arguments, isNull, reason: 'Flutter must never transport credentials or destination URLs.');
    final gate = gates.remove(call.method);
    if (gate != null) return gate.future;
    switch (call.method) {
      case 'status':
        if (statusError != null) throw statusError!;
        return Map<String, Object?>.from(state);
      case 'beginLogin':
        state = _state(state: 'pending');
        return state;
      case 'pollLogin':
        if (state['state'] == 'pending') state = _state(state: 'pending');
        return Map<String, Object?>.from(state);
      case 'cancelLogin':
        state = _state();
        return state;
      case 'refresh': return Map<String, Object?>.from(state);
      case 'logout':
        state = _state(error: logoutError);
        return state;
      case 'openLogin': return true;
      default: throw MissingPluginException();
    }
  }
}

void _resume(WidgetTester tester) {
  final binding = tester.binding;
  if (binding.lifecycleState == AppLifecycleState.paused) {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  }
  if (binding.lifecycleState == AppLifecycleState.hidden) {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  }
  if (binding.lifecycleState != AppLifecycleState.resumed) {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  }
}

void _pause(WidgetTester tester) {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
}

Future<void> _withCard(WidgetTester tester, Future<void> Function() body,
    {bool isAndroid = true, bool settle = true, double textScale = 1,
      Size size = const Size(390, 844), VoidCallback? onOpenCabinet}) async {
  _resume(tester);
  await tester.binding.setSurfaceSize(size);
  await tester.pumpWidget(MaterialApp(theme: buildPushokTheme(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)), child: child!),
    home: Scaffold(body: SingleChildScrollView(padding: const EdgeInsets.all(16),
      child: PushokAccountCard(isAndroid: isAndroid, onOpenCabinet: onOpenCabinet))),
  ));
  if (settle) { await tester.pumpAndSettle(); } else { await tester.pump(); }
  try { await body(); }
  finally {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    _resume(tester);
    await tester.binding.setSurfaceSize(null);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('shop.pushok.flow/account');
  late _AccountBridge bridge;

  setUp(() {
    bridge = _AccountBridge();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, bridge.handle);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('Profile metadata accepts signed wallet units and redacts diagnostics', () {
    final status = FlowAccountStatus.fromPlatform(_state(state: 'connected'));
    expect(status.state, FlowAccountState.connected);
    expect(status.profile!.wallet.bonuses, -129);
    expect(status.profile!.roleLabel, 'Пользователь');
    expect(status.profile.toString(), isNot(contains(_id)));
    expect(status.profile.toString(), isNot(contains('Проверочный')));
    expect(status.profile!.wallet.toString(), isNot(contains('123456')));
    final pending = FlowAccountStatus.fromPlatform(_state(state: 'pending')).pending!;
    expect(pending.displayCode, '23AB · 45CD · 67EF');
    expect(pending.toString(), isNot(contains(_code)));
  });

  test('Strict metadata rejects credentials, malformed states and raw errors', () {
    final connected = _state(state: 'connected');
    final pending = _state(state: 'pending');
    final cases = <Object?>[
      null, <Object?>[], {..._state(), 'access_token': 'PRIVATE_TOKEN'},
      {..._state(), 'state': 'approved'}, {..._state(), 'busy': 1},
      {..._state(), 'stale': 'false'}, {..._state(), 'errorCode': 'token=PRIVATE_TOKEN'},
      {..._state(), 'errorCode': 'X' * 65}, {..._state(), 'profile': _profile()},
      {..._state(), 'sessionExpiresAt': 1000}, {...pending, 'pending': null},
      {...connected, 'pending': pending['pending']},
      {...connected, 'sessionExpiresAt': null}, {...connected, 'refreshedAt': null},
      {...connected, 'sessionExpiresAt': 0},
      {...connected, 'profile': {..._profile(), 'telegramUserId': 42}},
      {...connected, 'profile': {..._profile(), 'phone': '+PRIVATE'}},
      {...connected, 'profile': {..._profile(), 'id': 'not-a-uuid'}},
      {...connected, 'profile': {..._profile(), 'displayName': 'name\nPRIVATE'}},
      {...connected, 'profile': {..._profile(), 'phoneVerified': 1}},
      {...connected, 'profile': {..._profile(), 'wallet': {'RUB': 1.0, 'BONUS': 0, 'XTR': 0}}},
      {...connected, 'profile': {..._profile(), 'wallet': {'RUB': 1, 'BONUS': 0}}},
      {...pending, 'pending': {...pending['pending']! as Map, 'deviceCode': 'PRIVATE_DEVICE'}},
      {...pending, 'pending': {...pending['pending']! as Map, 'userCode': 'invalid'}},
    ];
    for (final value in cases) {
      expect(() => FlowAccountStatus.fromPlatform(value), throwsFormatException);
    }
  });

  test('Wallet formatting keeps integer precision, signed minor units and whole Stars', () {
    expect(formatFlowWalletAmount(0), '0,00');
    expect(formatFlowWalletAmount(1), '0,01');
    expect(formatFlowWalletAmount(-1), '−0,01');
    expect(formatFlowWalletAmount(123456), '1 234,56');
    expect(formatFlowWalletAmount(-129), '−1,29');
    expect(formatFlowWalletAmount(42, fractional: false), '42');
    expect(formatFlowWalletAmount(-1000, fractional: false), '−1 000');
    expect(formatFlowWalletAmount(9223372036854775807), '92 233 720 368 547 758,07');
    expect(formatFlowWalletAmount(-9223372036854775808), '−92 233 720 368 547 758,08');
  });

  test('Bridge exposes only fixed native operations, without credentials or links', () async {
    final account = FlowAccount(isAndroid: true);
    await account.status();
    await account.beginLogin();
    await account.openLogin();
    await account.pollLogin();
    await account.cancelLogin();
    await account.refresh();
    await account.logout();
    expect(bridge.calls.map((call) => call.method),
        ['status', 'beginLogin', 'openLogin', 'pollLogin', 'cancelLogin', 'refresh', 'logout']);
    expect(bridge.calls.every((call) => call.arguments == null), isTrue);
  });

  test('Error display never includes platform messages or arbitrary server bodies', () {
    for (final error in [
      PlatformException(code: 'FLOW_NETWORK_ERROR', message: 'PRIVATE_TOKEN', details: 'PRIVATE_BODY'),
      PlatformException(code: 'UNKNOWN', message: 'PRIVATE_TOKEN'),
      const FormatException('PRIVATE_TOKEN'), 'token=PRIVATE_TOKEN',
    ]) {
      expect(flowAccountErrorMessage(error), isNot(contains('PRIVATE')));
    }
    expect(flowAccountErrorMessage('FLOW_LOGOUT_REMOTE_FAILED'), contains('На этом устройстве вход завершён'));
    expect(flowAccountErrorMessage('FLOW_SERVICE_UNAVAILABLE'), contains('существующий кабинет MTProxy'));
  });

  testWidgets('Opening profile does not begin login; explicit login shows public confirmation code', (tester) async {
    await _withCard(tester, () async {
      expect(bridge.count('status'), 1);
      expect(bridge.count('beginLogin'), 0);
      await tester.tap(find.byKey(const Key('begin_flow_login')));
      await tester.pumpAndSettle();
      expect(bridge.count('beginLogin'), 1);
      expect(find.byKey(const Key('flow_account_waiting')), findsOneWidget);
      expect(find.text('23AB · 45CD · 67EF'), findsOneWidget);
      expect(bridge.count('pollLogin'), 0);
      await tester.tap(find.byKey(const Key('cancel_flow_login')));
      await tester.pumpAndSettle();
      expect(bridge.count('cancelLogin'), 1);
      expect(find.byKey(const Key('flow_account_code')), findsNothing);
      await tester.pump(const Duration(seconds: 10));
      expect(bridge.count('pollLogin'), 0);
    });
  });

  testWidgets('Polling pauses in background and refreshes durable status on return', (tester) async {
    bridge.state = _state(state: 'pending');
    await _withCard(tester, () async {
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(bridge.count('pollLogin'), 1);
      _pause(tester);
      await tester.pump(const Duration(seconds: 30));
      expect(bridge.count('pollLogin'), 1);
      bridge.state = _state(state: 'connected');
      _resume(tester);
      await tester.pumpAndSettle();
      expect(bridge.count('status'), 2);
      expect(find.text('Проверочный аккаунт'), findsOneWidget);
      expect(find.byKey(const Key('flow_account_code')), findsNothing);
      await tester.pump(const Duration(seconds: 10));
      expect(bridge.count('pollLogin'), 1);
    });
    await tester.pump(const Duration(seconds: 30));
    expect(bridge.count('pollLogin'), 1);
  });

  testWidgets('Late response from before leaving Flow cannot overwrite resumed account', (tester) async {
    final gate = Completer<Object?>();
    bridge.gates['beginLogin'] = gate;
    await _withCard(tester, () async {
      await tester.tap(find.byKey(const Key('begin_flow_login')));
      await tester.pump();
      _pause(tester);
      bridge.state = _state(state: 'connected');
      _resume(tester);
      await tester.pumpAndSettle();
      expect(find.text('Проверочный аккаунт'), findsOneWidget);
      gate.complete(_state(state: 'pending'));
      await tester.pumpAndSettle();
      expect(find.text('Проверочный аккаунт'), findsOneWidget);
      expect(find.byKey(const Key('flow_account_code')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('Disposed account screen ignores an in-flight native reply', (tester) async {
    final gate = Completer<Object?>();
    bridge.gates['status'] = gate;
    await _withCard(tester, () async {
      await tester.pumpWidget(const SizedBox.shrink());
      gate.complete(_state(state: 'pending'));
      await tester.pump(const Duration(seconds: 10));
      expect(bridge.count('pollLogin'), 0);
      expect(tester.takeException(), isNull);
    }, settle: false);
  });

  testWidgets('Returning cached data preserves balances and displays offline state', (tester) async {
    bridge.state = _state(state: 'connected', stale: true, error: 'FLOW_NETWORK_ERROR');
    await _withCard(tester, () async {
      expect(bridge.count('refresh'), 1);
      expect(find.text('Проверочный аккаунт'), findsOneWidget);
      expect(find.byKey(const Key('account_stale')), findsOneWidget);
      expect(find.text('1 234,56 ₽'), findsOneWidget);
      expect(find.text('−1,29'), findsOneWidget);
      expect(find.text('42'), findsOneWidget);
      expect(find.textContaining('Сохранённые данные остаются доступны'), findsOneWidget);
      expect(bridge.count('beginLogin'), 0);
    });
  });

  testWidgets('Local logout removes profile even when remote revocation is unavailable', (tester) async {
    bridge.state = _state(state: 'connected');
    bridge.logoutError = 'FLOW_LOGOUT_REMOTE_FAILED';
    await _withCard(tester, () async {
      await tester.tap(find.byKey(const Key('logout_flow_account')));
      await tester.pumpAndSettle();
      expect(bridge.count('logout'), 1);
      expect(find.text('Проверочный аккаунт'), findsNothing);
      expect(find.byKey(const Key('begin_flow_login')), findsOneWidget);
      expect(find.textContaining('На этом устройстве вход завершён'), findsOneWidget);
      expect(find.byKey(const Key('account_wallet_rub')), findsNothing);
    });
  });

  testWidgets('Bridge failure leaves existing cabinet action usable without leaking details', (tester) async {
    bridge.statusError = MissingPluginException('PRIVATE_NATIVE_DETAILS');
    var opened = 0;
    await _withCard(tester, () async {
      expect(find.textContaining('PRIVATE'), findsNothing);
      expect(find.byKey(const Key('flow_account_error')), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const Key('begin_flow_login'))).onPressed, isNull);
      await tester.ensureVisible(find.byKey(const Key('open_pushok_account')));
      await tester.tap(find.byKey(const Key('open_pushok_account')));
      expect(opened, 1);
    }, onOpenCabinet: () => opened++);
  });

  testWidgets('Non-Android preview never invokes native account operations', (tester) async {
    await _withCard(tester, () async {
      expect(bridge.calls, isEmpty);
      expect(find.text('Вход доступен в приложении для Android.'), findsOneWidget);
    }, isAndroid: false);
  });

  for (final size in [const Size(360, 640), const Size(390, 844)]) {
    for (final state in ['pending', 'connected']) {
      testWidgets('$state account fits $size with large text and wallet amounts', (tester) async {
        bridge.state = _state(state: state, profile: {..._profile(),
          'displayName': 'Длинное отображаемое имя пользователя кабинета MTProxy',
          'wallet': {'RUB': 9223372036854775807, 'BONUS': -9223372036854775808, 'XTR': 9223372036854775807},
        });
        await _withCard(tester, () async {
          expect(tester.takeException(), isNull);
          await tester.ensureVisible(find.byKey(const Key('open_pushok_account')));
          expect(tester.takeException(), isNull);
        }, size: size, textScale: 1.5);
      });
    }
  }
}
