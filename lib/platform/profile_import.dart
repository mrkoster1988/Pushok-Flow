import 'dart:convert';

import 'subscriptions.dart';

/// A transient value for the protected editor. Never include it in diagnostics.
abstract final class ProfileImportPayload {
  static const _maxBytes = 65536;

  static String? read(Object? raw) {
    if (raw == null) return null;
    // Older native bridges returned only already-validated profile text.
    if (raw is String) return _text(raw);
    const invalid = FormatException('Invalid imported connection data');
    if (raw is! Map) throw invalid;
    final kind = raw['kind'];
    if (kind == 'profile') {
      if (raw.length != 2 || !raw.containsKey('config')) throw invalid;
      final value = _text(raw['config']);
      final scheme = RegExp(r'^([A-Za-z][A-Za-z0-9+.-]*):')
          .firstMatch(value.trim())?.group(1)?.toLowerCase();
      if (scheme != null && scheme != 'vless') throw invalid;
      return value;
    }
    if (kind == 'subscription') {
      if (raw.length != 2 || !raw.containsKey('url')) throw invalid;
      final value = _text(raw['url']);
      if (!SubscriptionDraft.validUrl(value)) throw invalid;
      return value;
    }
    throw invalid;
  }

  static String _text(Object? value) {
    const invalid = FormatException('Invalid imported connection data');
    if (value is! String || value.trim().isEmpty ||
        value.length > _maxBytes || utf8.encode(value).length > _maxBytes ||
        RegExp(r'[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]')
            .hasMatch(value)) throw invalid;
    return value;
  }
}
