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
    bool stale = false, bool recoveryAvailable = false, int? nextPollAt,
    Map<String, Object?>? profile, String userCode = _code}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return {
    'state': state, 'busy': false, 'errorCode': error,
    'pending': state == 'pending' ? {
      'userCode': userCode, 'expiresAt': now + 300000, 'nextPollAt': nextPollAt ?? now + 5000,
    } : null,
    'profile': state == 'connected' ? profile ?? _profile() : null,
    'refreshedAt': state == 'connected' ? now : null,
    'sessionExpiresAt': state == 'connected' ? now + 43200000 : null,
    'stale': stale,
    'recoveryAvailable': recoveryAvailable,
  };
}

class _AccountBridge {
  Map<String, Object?> state = _state();
  final calls = <MethodCall>[];
  final gates = <String, Completer<Object?>>{};
  Object? statusError;
  String? logoutError;
  String? recoveryError;
  String sessionUserCode = _code;

  int count(String method) => calls.where((call) => call.method == method).length;

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    if (call.method == 'cancelLogin') {
      expect(call.arguments, isA<Map>());
      expect((call.arguments as Map).keys, ['userCode']);
      expect((call.arguments as Map)['userCode'], matches(RegExp(r'^[A-HJ-NP-Z2-9]{12}$')),
        reason: 'Cancellation transports only the displayed public confirmation code.');
    } else {
      expect(call.arguments, isNull, reason: 'Flutter must never transport credentials or destination URLs.');
    }
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
        final code = state['state'] == 'pending'
          ? (state['pending'] as Map)['userCode'] : sessionUserCode;
        if (state['state'] != 'signed_out' && (call.arguments as Map)['userCode'] != code) {
          return {...state, 'errorCode': 'FLOW_INTERRUPTED'};
        }
        state = _state();
        return state;
      case 'refresh': return Map<String, Object?>.from(state);
      case 'logout':
        state = _state(error: logoutError);
        return state;
      case 'recoverLocalAccount':
        if (state['recoveryAvailable'] != true) {
          return {...state, 'errorCode': 'FLOW_RECOVERY_NOT_REQUIRED'};
        }
        state = _state(error: recoveryError, recoveryAvailable: recoveryError != null);
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
      Size size = const Size(390, 844), VoidCallback? onOpenCabinet,
      DateTime Function()? now}) async {
  _resume(tester);
  await tester.binding.setSurfaceSize(size);
  await tester.pumpWidget(MaterialApp(theme: buildPushokTheme(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)), child: child!),
    home: Scaffold(body: SingleChildScrollView(padding: const EdgeInsets.all(16),
      child: PushokAccountCard(isAndroid: isAndroid, onOpenCabinet: onOpenCabinet, now: now))),
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
      {..._state(), 'recoveryAvailable': 1}, {..._state(), 'recoveryAvailable': null},
      {...connected, 'recoveryAvailable': true}, {...pending, 'recoveryAvailable': true},
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

  test('Recovery metadata is explicit and remains compatible with older snapshots', () {
    final legacy = _state()..remove('recoveryAvailable');
    expect(FlowAccountStatus.fromPlatform(legacy).recoveryAvailable, isFalse);
    expect(FlowAccountStatus.fromPlatform(_state(error: 'FLOW_STORE_UNAVAILABLE',
      recoveryAvailable: true)).recoveryAvailable, isTrue);
    expect(flowAccountErrorMessage('FLOW_STORE_UNAVAILABLE'), isNot(contains('Перезапустите')));
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
    await account.cancelLogin(_code);
    await account.refresh();
    await account.logout();
    await account.recoverLocalAccount();
    expect(bridge.calls.map((call) => call.method),
        ['status', 'beginLogin', 'openLogin', 'pollLogin', 'cancelLogin', 'refresh', 'logout',
          'recoverLocalAccount']);
    expect(bridge.calls.singleWhere((call) => call.method == 'cancelLogin').arguments, {'userCode': _code});
    expect(bridge.calls.where((call) => call.method != 'cancelLogin')
      .every((call) => call.arguments == null), isTrue);
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

  testWidgets('An open connected card marks its cache stale without a network refresh', (tester) async {
    var now = DateTime.now();
    bridge.state = _state(state: 'connected');
    bridge.state['refreshedAt'] = now.millisecondsSinceEpoch;
    await _withCard(tester, () async {
      expect(find.byKey(const Key('account_stale')), findsNothing);
      final calls = bridge.calls.length;
      now = now.add(const Duration(minutes: 5));
      await tester.pump(const Duration(minutes: 5));
      expect(find.byKey(const Key('account_stale')), findsOneWidget);
      expect(find.text('Проверочный аккаунт'), findsOneWidget);
      expect(bridge.calls.length, calls, reason: 'A cache age label needs no native or network request.');
    }, now: () => now);
  });

  testWidgets('Pending expiry wins over a later slow-down poll deadline', (tester) async {
    var now = DateTime.now();
    bridge.state = _state(state: 'pending', error: 'FLOW_LOGIN_SLOW_DOWN');
    bridge.state['pending'] = {
      'userCode': _code,
      'expiresAt': now.millisecondsSinceEpoch + 2000,
      'nextPollAt': now.millisecondsSinceEpoch + 60000,
    };
    await _withCard(tester, () async {
      expect(find.byKey(const Key('flow_account_code')), findsOneWidget);
      bridge.state = _state(error: 'FLOW_LOGIN_EXPIRED');
      now = now.add(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('flow_account_code')), findsNothing);
      expect(find.byKey(const Key('flow_account_waiting')), findsNothing);
      expect(find.textContaining('Время подтверждения истекло'), findsOneWidget);
      expect(bridge.count('status'), 2);
      expect(bridge.count('pollLogin'), 0);
      expect(bridge.count('beginLogin'), 0);
      expect(bridge.count('openLogin'), 0);
    }, now: () => now);
  });

  testWidgets('Session expiry hides cached identity and reads native state only once', (tester) async {
    var now = DateTime.now();
    bridge.state = _state(state: 'connected');
    bridge.state['refreshedAt'] = now.millisecondsSinceEpoch;
    bridge.state['sessionExpiresAt'] = now.millisecondsSinceEpoch + 2000;
    await _withCard(tester, () async {
      expect(find.text('Проверочный аккаунт'), findsOneWidget);
      final gate = Completer<Object?>();
      bridge.gates['status'] = gate;
      now = now.add(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(find.text('Проверочный аккаунт'), findsNothing,
        reason: 'An expired cache is hidden even while the native reply is in flight.');
      expect(find.byKey(const Key('account_wallet_rub')), findsNothing);
      gate.complete(_state(error: 'FLOW_SESSION_EXPIRED'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Сессия аккаунта завершена'), findsOneWidget);
      now = now.add(const Duration(minutes: 1));
      await tester.pump(const Duration(minutes: 1));
      expect(bridge.count('status'), 2);
      expect(bridge.count('refresh'), 0);
      expect(bridge.count('beginLogin'), 0);
    }, now: () => now);
  });

  testWidgets('Expiry bridge failure leaves no stale identity or automatic retry loop', (tester) async {
    var now = DateTime.now();
    bridge.state = _state(state: 'connected');
    bridge.state['refreshedAt'] = now.millisecondsSinceEpoch;
    bridge.state['sessionExpiresAt'] = now.millisecondsSinceEpoch + 2000;
    await _withCard(tester, () async {
      bridge.statusError = MissingPluginException('PRIVATE_NATIVE_DETAILS');
      now = now.add(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.text('Проверочный аккаунт'), findsNothing);
      expect(find.byKey(const Key('account_wallet_rub')), findsNothing);
      expect(find.textContaining('PRIVATE'), findsNothing);
      now = now.add(const Duration(minutes: 1));
      await tester.pump(const Duration(minutes: 1));
      expect(bridge.count('status'), 2);
      expect(bridge.count('refresh'), 0);
      expect(bridge.count('beginLogin'), 0);
    }, now: () => now);
  });

  testWidgets('Clock deadlines pause in background and resume from durable native status', (tester) async {
    var now = DateTime.now();
    bridge.state = _state(state: 'pending');
    bridge.state['pending'] = {
      'userCode': _code,
      'expiresAt': now.millisecondsSinceEpoch + 2000,
      'nextPollAt': now.millisecondsSinceEpoch + 60000,
    };
    await _withCard(tester, () async {
      _pause(tester);
      bridge.state = _state(error: 'FLOW_LOGIN_EXPIRED');
      now = now.add(const Duration(minutes: 1));
      await tester.pump(const Duration(minutes: 1));
      expect(bridge.count('status'), 1);
      expect(bridge.count('pollLogin'), 0);
      _resume(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('flow_account_code')), findsNothing);
      expect(find.textContaining('Время подтверждения истекло'), findsOneWidget);
      expect(bridge.count('status'), 2);
      expect(bridge.count('beginLogin'), 0);
    }, now: () => now);
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

  for (final replyBeforeCancel in [true, false]) {
    testWidgets('Cancel supersedes a waiting poll; old reply before clear=$replyBeforeCancel', (tester) async {
      bridge.state = _state(state: 'pending');
      final poll = Completer<Object?>();
      final cancel = Completer<Object?>();
      bridge.gates['pollLogin'] = poll;
      bridge.gates['cancelLogin'] = cancel;
      await _withCard(tester, () async {
        await tester.pump(const Duration(seconds: 6));
        await tester.pump();
        expect(bridge.count('pollLogin'), 1);
        final button = tester.widget<TextButton>(find.byKey(const Key('cancel_flow_login')));
        expect(button.onPressed, isNotNull);
        button.onPressed!();
        button.onPressed!(); // A queued second tap must not submit a second clear.
        await tester.pump();
        expect(bridge.count('cancelLogin'), 1);
        expect(find.byKey(const Key('flow_account_code')), findsNothing);
        expect(find.byKey(const Key('flow_account_waiting')), findsNothing);
        expect(find.text('Отменяем вход…'), findsOneWidget);
        expect(find.byKey(const Key('begin_flow_login')), findsNothing);
        if (replyBeforeCancel) {
          poll.complete(_state(state: 'connected'));
          await tester.pump();
          expect(find.text('Проверочный аккаунт'), findsNothing);
          expect(find.text('Отменяем вход…'), findsOneWidget);
          expect(find.byType(LinearProgressIndicator), findsOneWidget);
        }
        bridge.state = _state();
        cancel.complete(bridge.state);
        await tester.pumpAndSettle();
        if (!replyBeforeCancel) {
          poll.complete(_state(state: 'connected'));
          await tester.pumpAndSettle();
        }
        expect(find.text('Проверочный аккаунт'), findsNothing);
        expect(find.byKey(const Key('flow_account_code')), findsNothing);
        expect(find.byKey(const Key('begin_flow_login')), findsOneWidget);
        await tester.pump(const Duration(seconds: 10));
        expect(bridge.count('pollLogin'), 1);
        expect(bridge.count('cancelLogin'), 1);
      });
    });
  }

  testWidgets('Logout supersedes a held refresh and hides identity until native clear', (tester) async {
    bridge.state = _state(state: 'connected');
    final refresh = Completer<Object?>();
    final logout = Completer<Object?>();
    bridge.gates['refresh'] = refresh;
    bridge.gates['logout'] = logout;
    await _withCard(tester, () async {
      await tester.tap(find.byKey(const Key('refresh_flow_account')));
      await tester.pump();
      expect(bridge.count('refresh'), 1);
      final button = tester.widget<TextButton>(find.byKey(const Key('logout_flow_account')));
      expect(button.onPressed, isNotNull);
      button.onPressed!();
      button.onPressed!();
      await tester.pump();
      expect(bridge.count('logout'), 1);
      expect(find.text('Проверочный аккаунт'), findsNothing);
      expect(find.byKey(const Key('account_wallet_rub')), findsNothing);
      expect(find.text('Выходим из аккаунта…'), findsOneWidget);
      expect(find.byKey(const Key('begin_flow_login')), findsNothing);
      bridge.state = _state();
      logout.complete(bridge.state);
      await tester.pumpAndSettle();
      refresh.complete(_state(state: 'connected'));
      await tester.pumpAndSettle();
      expect(find.text('Проверочный аккаунт'), findsNothing);
      expect(find.byKey(const Key('account_wallet_rub')), findsNothing);
      expect(find.byKey(const Key('begin_flow_login')), findsOneWidget);
      expect(bridge.count('logout'), 1);
    });
  });

  for (final state in ['pending', 'connected']) {
    testWidgets('Native busy $state metadata still allows deliberate local clear', (tester) async {
      bridge.state = {..._state(state: state), 'busy': true};
      await _withCard(tester, () async {
        final key = state == 'pending' ? 'cancel_flow_login' : 'logout_flow_account';
        expect(tester.widget<TextButton>(find.byKey(Key(key))).onPressed, isNotNull);
        await tester.tap(find.byKey(Key(key)));
        await tester.pumpAndSettle();
        expect(bridge.count(state == 'pending' ? 'cancelLogin' : 'logout'), 1);
        expect(find.byKey(const Key('begin_flow_login')), findsOneWidget);
      });
    });
  }

  testWidgets('Uncertain durable clear stays masked and reports store failure truthfully', (tester) async {
    bridge.state = _state(state: 'connected');
    bridge.logoutError = 'FLOW_STORE_UNAVAILABLE';
    await _withCard(tester, () async {
      await tester.tap(find.byKey(const Key('logout_flow_account')));
      await tester.pumpAndSettle();
      expect(find.text('Проверочный аккаунт'), findsNothing);
      expect(find.byKey(const Key('account_wallet_rub')), findsNothing);
      expect(find.text('Выход ещё не подтверждён.'), findsOneWidget);
      expect(find.textContaining('Локальное хранилище аккаунта недоступно'), findsOneWidget);
      expect(find.byKey(const Key('begin_flow_login')), findsNothing);
      await tester.tap(find.byKey(const Key('retry_flow_account_clear')));
      await tester.pumpAndSettle();
      expect(bridge.count('logout'), 2);
      expect(find.text('Выход ещё не подтверждён.'), findsOneWidget);
      expect(find.byKey(const Key('begin_flow_login')), findsNothing);
    });
  });

  testWidgets('Lost clear reply permits retry without restoring cached identity', (tester) async {
    bridge.state = _state(state: 'connected');
    final logout = Completer<Object?>();
    bridge.gates['logout'] = logout;
    await _withCard(tester, () async {
      await tester.tap(find.byKey(const Key('logout_flow_account')));
      await tester.pump();
      logout.completeError(PlatformException(code: 'FLOW_NETWORK_ERROR', message: 'PRIVATE_DETAILS'));
      await tester.pumpAndSettle();
      expect(find.text('Проверочный аккаунт'), findsNothing);
      expect(find.textContaining('PRIVATE'), findsNothing);
      expect(find.text('Выход ещё не подтверждён.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('retry_flow_account_clear')));
      await tester.pumpAndSettle();
      expect(bridge.count('logout'), 2);
      expect(find.byKey(const Key('begin_flow_login')), findsOneWidget);
    });
  });

  for (final newerState in ['pending', 'connected']) {
    testWidgets('Qualified cancel preserves a newer $newerState account after a lost reply', (tester) async {
      const newerCode = '89GH23JK45MN';
      bridge.state = _state(state: 'pending');
      final cancel = Completer<Object?>();
      bridge.gates['cancelLogin'] = cancel;
      await _withCard(tester, () async {
        await tester.tap(find.byKey(const Key('cancel_flow_login')));
        await tester.pump();
        expect(find.byKey(const Key('flow_account_code')), findsNothing);
        cancel.completeError(PlatformException(code: 'FLOW_NETWORK_ERROR'));
        await tester.pumpAndSettle();
        expect(find.text('Отмена входа ещё не подтверждена.'), findsOneWidget);
        bridge.state = _state(state: newerState, userCode: newerCode,
          profile: {..._profile(), 'displayName': 'Другой аккаунт'});
        bridge.sessionUserCode = newerCode;
        _pause(tester);
        _resume(tester);
        await tester.pumpAndSettle();
        expect(find.text('Другой аккаунт'), findsNothing);
        expect(find.text('89GH · 23JK · 45MN'), findsNothing);
        await tester.tap(find.byKey(const Key('retry_flow_account_clear')));
        await tester.pumpAndSettle();
        final cancellations = bridge.calls.where((call) => call.method == 'cancelLogin').toList();
        expect(cancellations, hasLength(2));
        expect(cancellations.map((call) => call.arguments),
          [{'userCode': _code}, {'userCode': _code}],
          reason: 'Retry must target the originally displayed request, even after resume.');
        expect(bridge.state['state'], newerState);
        expect(find.byKey(const Key('flow_account_clearing')), findsNothing);
        expect(find.byKey(const Key('begin_flow_login')), findsNothing);
        expect(find.textContaining('Состояние входа изменилось'), findsOneWidget);
        expect(find.text(newerState == 'pending' ? '89GH · 23JK · 45MN' : 'Другой аккаунт'), findsOneWidget);
        expect(bridge.count('logout'), 0);
      });
    });
  }

  testWidgets('Resume reconciles an outstanding local clear and ignores its late reply', (tester) async {
    bridge.state = _state(state: 'connected');
    final logout = Completer<Object?>();
    bridge.gates['logout'] = logout;
    await _withCard(tester, () async {
      await tester.tap(find.byKey(const Key('logout_flow_account')));
      await tester.pump();
      _pause(tester);
      bridge.state = _state();
      _resume(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('begin_flow_login')), findsOneWidget);
      logout.complete(_state(state: 'connected'));
      await tester.pumpAndSettle();
      expect(find.text('Проверочный аккаунт'), findsNothing);
      expect(find.byKey(const Key('begin_flow_login')), findsOneWidget);
      expect(bridge.count('logout'), 1);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('Disposing the card during local clear ignores the eventual reply', (tester) async {
    bridge.state = _state(state: 'pending');
    final cancel = Completer<Object?>();
    bridge.gates['cancelLogin'] = cancel;
    await _withCard(tester, () async {
      await tester.tap(find.byKey(const Key('cancel_flow_login')));
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      cancel.complete(_state(state: 'connected'));
      await tester.pump(const Duration(seconds: 10));
      expect(bridge.count('cancelLogin'), 1);
      expect(bridge.count('pollLogin'), 0);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('Storage recovery requires confirmation and never starts a login automatically', (tester) async {
    bridge.state = _state(error: 'FLOW_STORE_UNAVAILABLE', recoveryAvailable: true);
    await _withCard(tester, () async {
      expect(find.byKey(const Key('begin_flow_login')), findsNothing);
      expect(bridge.count('recoverLocalAccount'), 0);
      final button = tester.widget<FilledButton>(find.byKey(const Key('recover_flow_account')));
      button.onPressed!();
      button.onPressed!();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(bridge.count('recoverLocalAccount'), 0);
      await tester.tap(find.byKey(const Key('cancel_account_recovery')));
      await tester.pumpAndSettle();
      expect(bridge.count('recoverLocalAccount'), 0);
      await tester.tap(find.byKey(const Key('recover_flow_account')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm_account_recovery')));
      await tester.pumpAndSettle();
      expect(bridge.calls.map((call) => call.method), ['status', 'recoverLocalAccount']);
      expect(find.byKey(const Key('flow_account_error')), findsNothing);
      expect(find.byKey(const Key('flow_account_recovery_needed')), findsNothing);
      expect(tester.widget<FilledButton>(find.byKey(const Key('begin_flow_login'))).onPressed, isNotNull);
      await tester.tap(find.byKey(const Key('begin_flow_login')));
      await tester.pumpAndSettle();
      expect(bridge.count('beginLogin'), 1);
      expect(find.byKey(const Key('flow_account_code')), findsOneWidget);
    });
  });

  testWidgets('Failed storage recovery stays masked and permits an explicit retry', (tester) async {
    bridge.state = _state(error: 'FLOW_STORE_UNAVAILABLE', recoveryAvailable: true);
    bridge.recoveryError = 'FLOW_STORE_UNAVAILABLE';
    await _withCard(tester, () async {
      await tester.tap(find.byKey(const Key('recover_flow_account')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm_account_recovery')));
      await tester.pumpAndSettle();
      expect(find.text('Восстановление ещё не подтверждено.'), findsOneWidget);
      expect(find.byKey(const Key('begin_flow_login')), findsNothing);
      expect(find.byKey(const Key('flow_account_code')), findsNothing);
      expect(find.byKey(const Key('account_display_name')), findsNothing);
      expect(bridge.count('beginLogin'), 0);
      bridge.recoveryError = null;
      await tester.tap(find.byKey(const Key('retry_flow_account_clear')));
      await tester.pumpAndSettle();
      expect(bridge.count('recoverLocalAccount'), 2);
      expect(bridge.count('beginLogin'), 0);
      expect(find.byKey(const Key('begin_flow_login')), findsOneWidget);
      expect(find.byKey(const Key('flow_account_clearing')), findsNothing);
    });
  });

  testWidgets('Recovery dialog from before background cannot clear a resumed account', (tester) async {
    bridge.state = _state(error: 'FLOW_STORE_UNAVAILABLE', recoveryAvailable: true);
    await _withCard(tester, () async {
      await tester.tap(find.byKey(const Key('recover_flow_account')));
      await tester.pumpAndSettle();
      _pause(tester);
      bridge.state = _state(state: 'connected');
      _resume(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm_account_recovery')));
      await tester.pumpAndSettle();
      expect(bridge.count('recoverLocalAccount'), 0);
      expect(find.text('Проверочный аккаунт'), findsOneWidget);
      expect(bridge.count('beginLogin'), 0);
      expect(bridge.count('logout'), 0);
    });
  });

  testWidgets('Native refusal of stale recovery preserves a newer busy login', (tester) async {
    bridge.state = _state(error: 'FLOW_STORE_UNAVAILABLE', recoveryAvailable: true);
    await _withCard(tester, () async {
      await tester.tap(find.byKey(const Key('recover_flow_account')));
      await tester.pumpAndSettle();
      bridge.state = {..._state(state: 'pending', userCode: '89GH23JK45LM'), 'busy': true};
      await tester.tap(find.byKey(const Key('confirm_account_recovery')));
      await tester.pumpAndSettle();
      expect(bridge.count('recoverLocalAccount'), 1);
      expect(find.text('89GH · 23JK · 45LM'), findsOneWidget);
      expect(find.byKey(const Key('flow_account_clearing')), findsNothing);
      expect(find.textContaining('Восстановление больше не требуется'), findsOneWidget);
      expect(bridge.count('cancelLogin'), 0);
      expect(bridge.count('beginLogin'), 0);
    });
  });

  testWidgets('Resume reconciles recovery and ignores a late failed reply', (tester) async {
    bridge.state = _state(error: 'FLOW_STORE_UNAVAILABLE', recoveryAvailable: true);
    final recovery = Completer<Object?>();
    bridge.gates['recoverLocalAccount'] = recovery;
    await _withCard(tester, () async {
      await tester.tap(find.byKey(const Key('recover_flow_account')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm_account_recovery')));
      await tester.pump();
      expect(bridge.count('recoverLocalAccount'), 1);
      _pause(tester);
      bridge.state = _state();
      _resume(tester);
      await tester.pumpAndSettle();
      recovery.complete(_state(error: 'FLOW_STORE_UNAVAILABLE', recoveryAvailable: true));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('begin_flow_login')), findsOneWidget);
      expect(find.byKey(const Key('flow_account_clearing')), findsNothing);
      expect(find.byKey(const Key('flow_account_error')), findsNothing);
      expect(bridge.count('beginLogin'), 0);
    });
  });

  testWidgets('Storage failure during logout offers recovery without exposing cached profile', (tester) async {
    bridge.state = _state(state: 'connected');
    final logout = Completer<Object?>();
    bridge.gates['logout'] = logout;
    await _withCard(tester, () async {
      await tester.tap(find.byKey(const Key('logout_flow_account')));
      await tester.pump();
      bridge.state = _state(error: 'FLOW_STORE_UNAVAILABLE', recoveryAvailable: true);
      logout.complete(bridge.state);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('account_display_name')), findsNothing);
      expect(find.byKey(const Key('retry_flow_account_clear')), findsNothing);
      expect(find.byKey(const Key('recover_flow_account')), findsOneWidget);
      await tester.tap(find.byKey(const Key('recover_flow_account')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm_account_recovery')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('begin_flow_login')), findsOneWidget);
      expect(bridge.count('recoverLocalAccount'), 1);
      expect(bridge.count('logout'), 1);
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
