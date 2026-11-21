import 'package:flutter/services.dart';

/// Owns one native screen-protection lease. It never carries profile contents.
class ProfilePrivacy {
  ProfilePrivacy._(this._token);

  static const _channel = MethodChannel('shop.pushok.flow/profile_privacy');
  final String _token;
  Future<void>? _release;

  /// Android acknowledges only after protecting the current window.
  /// Callers must not open the profile editor if this fails or is unavailable.
  static Future<ProfilePrivacy> acquire() async {
    final token = await _channel.invokeMethod<String>('acquire');
    if (token == null || token.isEmpty) {
      throw PlatformException(code: 'PROFILE_PROTECTION_UNAVAILABLE');
    }
    return ProfilePrivacy._(token);
  }

  /// Call after the editor's transition and removal from the overlay complete.
  /// Repeated cleanup cannot release another editor's native lease.
  Future<void> release() => _release ??= _releaseOnce();

  Future<void> _releaseOnce() async {
    final released = await _channel.invokeMethod<bool>('release', {'token': _token});
    if (released != true) {
      throw PlatformException(code: 'PROFILE_PROTECTION_RELEASE_FAILED');
    }
  }
}
