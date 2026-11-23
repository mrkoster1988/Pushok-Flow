import 'package:flutter/services.dart';

enum FlowAccountState { signedOut, pending, connected }

Map<Object?, Object?> _accountMap(Object? value, Set<String> keys) {
  if (value is! Map || value.keys.any((key) => key is! String || !keys.contains(key))) {
    throw const FormatException('Invalid account metadata');
  }
  return Map<Object?, Object?>.from(value);
}

int? _accountTime(Object? value) {
  if (value == null) return null;
  if (value is! int || value <= 0 || value > 8640000000000000) {
    throw const FormatException('Invalid account timestamp');
  }
  return value;
}

String _accountText(Object? value, int maximum) {
  if (value is! String || value.isEmpty || value.length > maximum ||
      value.runes.any((rune) => rune < 32 || rune == 127)) {
    throw const FormatException('Invalid account text');
  }
  return value;
}

class FlowWallet {
  const FlowWallet({required this.rubles, required this.bonuses, required this.stars});
  final int rubles;
  final int bonuses;
  final int stars;

  factory FlowWallet.fromPlatform(Object? value) {
    final map = _accountMap(value, {'RUB', 'BONUS', 'XTR'});
    if (map.length != 3 || map.values.any((item) => item is! int)) {
      throw const FormatException('Invalid wallet metadata');
    }
    return FlowWallet(rubles: map['RUB']! as int, bonuses: map['BONUS']! as int,
      stars: map['XTR']! as int);
  }

  @override
  String toString() => 'FlowWallet(redacted)';
}

class FlowAccountProfile {
  const FlowAccountProfile({required this.id, required this.displayName,
    required this.role, required this.phoneVerified, required this.wallet});
  final String id;
  final String displayName;
  final String role;
  final bool phoneVerified;
  final FlowWallet wallet;

  factory FlowAccountProfile.fromPlatform(Object? value) {
    final map = _accountMap(value, {'id', 'displayName', 'role', 'phoneVerified', 'wallet'});
    final id = _accountText(map['id'], 36);
    final role = _accountText(map['role'], 32);
    if (!RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
            .hasMatch(id) || !RegExp(r'^[a-z_]+$').hasMatch(role) || map['phoneVerified'] is! bool) {
      throw const FormatException('Invalid account profile');
    }
    return FlowAccountProfile(id: id, displayName: _accountText(map['displayName'], 512),
      role: role, phoneVerified: map['phoneVerified']! as bool,
      wallet: FlowWallet.fromPlatform(map['wallet']));
  }

  String get roleLabel => switch (role) {
    'developer' || 'owner' => 'Разработчик',
    'admin' || 'administrator' => 'Администратор',
    'moderator' => 'Модератор',
    'operator' => 'Оператор',
    'friend' || 'friends' => 'Друзья',
    'advertiser' => 'Рекламодатель',
    'user' => 'Пользователь',
    _ => 'Участник',
  };

  @override
  String toString() => 'FlowAccountProfile(redacted)';
}

class FlowAccountPending {
  const FlowAccountPending({required this.userCode, required this.expiresAt,
    required this.nextPollAt});
  final String userCode;
  final int expiresAt;
  final int nextPollAt;

  factory FlowAccountPending.fromPlatform(Object? value) {
    final map = _accountMap(value, {'userCode', 'expiresAt', 'nextPollAt'});
    final code = map['userCode'];
    final expires = _accountTime(map['expiresAt']);
    final nextPoll = _accountTime(map['nextPollAt']);
    if (code is! String || !RegExp(r'^[A-HJ-NP-Z2-9]{12}$').hasMatch(code) ||
        expires == null || nextPoll == null) {
      throw const FormatException('Invalid pending account request');
    }
    return FlowAccountPending(userCode: code, expiresAt: expires, nextPollAt: nextPoll);
  }

  String get displayCode => '${userCode.substring(0, 4)} · '
      '${userCode.substring(4, 8)} · ${userCode.substring(8)}';

  @override
  String toString() => 'FlowAccountPending(redacted)';
}

class FlowAccountStatus {
  const FlowAccountStatus({required this.state, this.busy = false, this.errorCode,
    this.pending, this.profile, this.refreshedAt, this.sessionExpiresAt, this.stale = false,
    this.recoveryAvailable = false});
  final FlowAccountState state;
  final bool busy;
  final String? errorCode;
  final FlowAccountPending? pending;
  final FlowAccountProfile? profile;
  final int? refreshedAt;
  final int? sessionExpiresAt;
  final bool stale;
  final bool recoveryAvailable;

  factory FlowAccountStatus.fromPlatform(Object? value) {
    final map = _accountMap(value, {'state', 'busy', 'errorCode', 'pending', 'profile',
      'refreshedAt', 'sessionExpiresAt', 'stale', 'recoveryAvailable'});
    final state = switch (map['state']) {
      'signed_out' => FlowAccountState.signedOut,
      'pending' => FlowAccountState.pending,
      'connected' => FlowAccountState.connected,
      _ => throw const FormatException('Invalid account state'),
    };
    if (map['busy'] is! bool || map['stale'] is! bool ||
        (map.containsKey('recoveryAvailable') && map['recoveryAvailable'] is! bool)) {
      throw const FormatException('Invalid account flags');
    }
    final errorCode = map['errorCode'];
    if (errorCode != null && (errorCode is! String ||
        !RegExp(r'^[A-Z][A-Z0-9_]{0,63}$').hasMatch(errorCode))) {
      throw const FormatException('Invalid account error');
    }
    final pending = map['pending'] == null ? null : FlowAccountPending.fromPlatform(map['pending']);
    final profile = map['profile'] == null ? null : FlowAccountProfile.fromPlatform(map['profile']);
    final refreshedAt = _accountTime(map['refreshedAt']);
    final sessionExpiresAt = _accountTime(map['sessionExpiresAt']);
    final recoveryAvailable = map['recoveryAvailable'] == true;
    if ((state == FlowAccountState.pending) != (pending != null) ||
        (state != FlowAccountState.connected && (profile != null || sessionExpiresAt != null || refreshedAt != null)) ||
        (state == FlowAccountState.connected && sessionExpiresAt == null) ||
        (profile != null && refreshedAt == null) ||
        (recoveryAvailable && state != FlowAccountState.signedOut)) {
      throw const FormatException('Contradictory account metadata');
    }
    return FlowAccountStatus(state: state, busy: map['busy']! as bool,
      errorCode: errorCode as String?, pending: pending, profile: profile,
      refreshedAt: refreshedAt, sessionExpiresAt: sessionExpiresAt, stale: map['stale']! as bool,
      recoveryAvailable: recoveryAvailable);
  }

  @override
  String toString() => 'FlowAccountStatus(${state.name})';
}

class FlowAccount {
  FlowAccount({required this.isAndroid});
  final bool isAndroid;
  static const _channel = MethodChannel('shop.pushok.flow/account');

  Future<FlowAccountStatus> _status(String method, {Map<String, Object?>? arguments}) async {
    if (!isAndroid) throw MissingPluginException();
    return FlowAccountStatus.fromPlatform(await _channel.invokeMethod<Object?>(method, arguments));
  }

  Future<FlowAccountStatus> status() => _status('status');
  Future<FlowAccountStatus> beginLogin() => _status('beginLogin');
  Future<FlowAccountStatus> pollLogin() => _status('pollLogin');
  Future<FlowAccountStatus> cancelLogin(String userCode) =>
      _status('cancelLogin', arguments: {'userCode': userCode});
  Future<FlowAccountStatus> refresh() => _status('refresh');
  Future<FlowAccountStatus> logout() => _status('logout');
  Future<FlowAccountStatus> recoverLocalAccount() => _status('recoverLocalAccount');
  Future<void> openLogin() async {
    if (!isAndroid) throw MissingPluginException();
    await _channel.invokeMethod<void>('openLogin');
  }
}

String flowAccountErrorMessage(Object error) {
  final code = error is PlatformException ? error.code : error is String ? error : null;
  return switch (code) {
    'FLOW_SERVICE_UNAVAILABLE' || 'FLOW_ACCOUNT_SERVICE_UNAVAILABLE' || 'FLOW_PROTOCOL_UNSUPPORTED' =>
      'Вход из Flow ещё недоступен на сервере. Можно открыть существующий кабинет MTProxy.',
    'FLOW_LOGIN_EXPIRED' || 'FLOW_DEVICE_EXPIRED' =>
      'Время подтверждения истекло. Начните вход заново.',
    'FLOW_LOGIN_DENIED' || 'FLOW_DEVICE_DENIED' => 'Подключение аккаунта отклонено в кабинете.',
    'FLOW_LOGIN_SLOW_DOWN' || 'FLOW_RATE_LIMITED' => 'Слишком частые запросы. Повторим проверку чуть позже.',
    'FLOW_SESSION_EXPIRED' || 'FLOW_UNAUTHORIZED' || 'FLOW_ACCOUNT_UNAUTHORIZED' =>
      'Сессия аккаунта завершена. Войдите через Telegram снова.',
    'FLOW_ACCOUNT_BLOCKED' => 'Доступ к аккаунту ограничен. Откройте кабинет MTProxy.',
    'FLOW_NETWORK_ERROR' || 'FLOW_ACCOUNT_NETWORK_ERROR' || 'FLOW_TIMEOUT' =>
      'Не удалось связаться с кабинетом. Сохранённые данные остаются доступны.',
    'FLOW_OPEN_FAILED' || 'FLOW_LOGIN_OPEN_FAILED' =>
      'Не удалось открыть Telegram или браузер. Повторите открытие подтверждения.',
    'FLOW_LOGOUT_REMOTE_FAILED' =>
      'На этом устройстве вход завершён. Сервер не подтвердил отзыв сессии; она истечёт автоматически.',
    'FLOW_STORE_UNAVAILABLE' =>
      'Локальное хранилище аккаунта недоступно. Восстановите вход и затем войдите через Telegram снова.',
    'FLOW_RECOVERY_NOT_REQUIRED' =>
      'Состояние аккаунта изменилось. Восстановление больше не требуется.',
    'FLOW_INTERRUPTED' =>
      'Состояние входа изменилось. Проверьте текущий аккаунт и повторите действие при необходимости.',
    'FLOW_BUSY' => 'Дождитесь завершения текущего действия с аккаунтом.',
    _ => 'Не удалось выполнить действие с аккаунтом. Повторите попытку.',
  };
}

/// Integer arithmetic preserves signed wallet minimum units without rounding.
String formatFlowWalletAmount(int value, {bool fractional = true}) {
  final number = BigInt.from(value);
  final absolute = number.abs();
  final whole = (fractional ? absolute ~/ BigInt.from(100) : absolute).toString();
  final groups = <String>[];
  for (var end = whole.length; end > 0; end -= 3) {
    groups.insert(0, whole.substring(end > 3 ? end - 3 : 0, end));
  }
  final fraction = fractional ? ',${(absolute % BigInt.from(100)).toString().padLeft(2, '0')}' : '';
  return '${number.isNegative ? '−' : ''}${groups.join(' ')}$fraction';
}
