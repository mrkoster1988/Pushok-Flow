/// Metadata for the Servers screen. Configuration text and native error details
/// never belong in this model.
class WireGuardProfileSummary {
  const WireGuardProfileSummary({required this.id, required this.name});

  final String id;
  final String name;
}

class WireGuardProfiles {
  const WireGuardProfiles.empty()
      : profiles = const [],
        activeProfileId = null;

  WireGuardProfiles._(List<WireGuardProfileSummary> items, this.activeProfileId)
      : profiles = List.unmodifiable(items);

  static const maxProfiles = 20;
  static const maxNameLength = 64;
  static final _idPattern = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
  static final _nameControls = RegExp(r'[\u0000-\u001f\u007f-\u009f\u2028\u2029]');

  final List<WireGuardProfileSummary> profiles;
  final String? activeProfileId;

  bool get isFull => profiles.length >= maxProfiles;

  WireGuardProfileSummary? get activeProfile {
    for (final profile in profiles) {
      if (profile.id == activeProfileId) return profile;
    }
    return null;
  }

  static bool isValidName(String name) => name.isNotEmpty &&
      name == name.trim() && name.runes.length <= maxNameLength &&
      !_nameControls.hasMatch(name) &&
      !name.runes.any((rune) => rune >= 0xd800 && rune <= 0xdfff);

  /// A partial or contradictory list must not allow edits against a guessed
  /// active profile. Fail as one unit with a constant, non-sensitive message.
  factory WireGuardProfiles.fromPlatform(Object? value) {
    const invalid = FormatException('Invalid profile catalog');
    if (value is! Map || value.length != 2 ||
        !value.containsKey('profiles') || !value.containsKey('activeProfileId')) {
      throw invalid;
    }
    final entries = value['profiles'];
    final active = value['activeProfileId'];
    if (entries is! List || entries.length > maxProfiles ||
        (active != null && active is! String)) throw invalid;
    final profiles = <WireGuardProfileSummary>[];
    final ids = <String>{};
    for (final entry in entries) {
      if (entry is! Map || entry.length != 2 ||
          !entry.containsKey('id') || !entry.containsKey('name')) throw invalid;
      final id = entry['id'];
      final name = entry['name'];
      if (id is! String || !_idPattern.hasMatch(id) || !ids.add(id) ||
          name is! String || !isValidName(name)) throw invalid;
      profiles.add(WireGuardProfileSummary(id: id, name: name));
    }
    if (profiles.isEmpty ? active != null : active == null || !ids.contains(active)) {
      throw invalid;
    }
    return WireGuardProfiles._(profiles, active as String?);
  }
}
