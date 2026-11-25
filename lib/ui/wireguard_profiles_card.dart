import 'package:material_ui/material_ui.dart';

import '../design/pushok_theme.dart';
import '../platform/wireguard_profiles.dart';

/// Only profile names and selection metadata are displayed here. Opening the
/// protected editor, deleting with confirmation and connecting belong to the
/// caller, so merely selecting a list item cannot start a tunnel.
class WireGuardProfilesCard extends StatelessWidget {
  const WireGuardProfilesCard({
    super.key,
    this.catalog,
    this.loading = false,
    this.error,
    this.mutationsEnabled = false,
    this.onRefresh,
    this.onAdd,
    this.onEdit,
    this.onSelect,
    this.onDelete,
  });

  final WireGuardProfiles? catalog;
  final bool loading;
  final String? error;
  final bool mutationsEnabled;
  final VoidCallback? onRefresh;
  final VoidCallback? onAdd;
  final ValueChanged<WireGuardProfileSummary>? onEdit;
  final ValueChanged<WireGuardProfileSummary>? onSelect;
  final ValueChanged<WireGuardProfileSummary>? onDelete;

  bool get _canChange => mutationsEnabled && !loading &&
      error == null && catalog != null;

  Widget _entry(WireGuardProfileSummary profile) {
    final selected = profile.id == catalog?.activeProfileId;
    return PushokPanel(
      key: ValueKey('wireguard_profile_${profile.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Padding(
              padding: EdgeInsets.only(top: 3),
              child: Icon(Icons.dns_outlined, color: PushokPalette.glowCyan),
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(profile.name,
              key: ValueKey('wireguard_profile_name_${profile.id}'),
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700))),
          ]),
          if (profile.isManaged) ...[
            const SizedBox(height: 8),
            Text('Из подписки «${profile.subscriptionName}»',
              key: ValueKey('managed_wireguard_profile_${profile.id}'),
              style: const TextStyle(color: PushokPalette.muted)),
          ],
          if (selected) ...[
            const SizedBox(height: 10),
            Align(alignment: Alignment.centerLeft,
              child: PushokStatusChip(
                key: ValueKey('active_wireguard_profile_${profile.id}'),
                label: 'Выбран',
                color: PushokPalette.mint,
                icon: Icons.check_circle_outline,
              )),
          ],
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (!selected) OutlinedButton.icon(
              key: ValueKey('select_wireguard_profile_${profile.id}'),
              onPressed: _canChange && onSelect != null
                  ? () => onSelect!(profile) : null,
              icon: const Icon(Icons.check_circle_outline),
              label: const Text('Выбрать'),
            ),
            if (!profile.isManaged) OutlinedButton.icon(
              key: ValueKey('edit_wireguard_profile_${profile.id}'),
              onPressed: _canChange && onEdit != null
                  ? () => onEdit!(profile) : null,
              icon: const Icon(Icons.edit_outlined),
              label: const Text('Изменить'),
            ),
            if (!profile.isManaged) OutlinedButton.icon(
              key: ValueKey('delete_wireguard_profile_${profile.id}'),
              onPressed: _canChange && onDelete != null
                  ? () => onDelete!(profile) : null,
              icon: const Icon(Icons.delete_outline),
              label: const Text('Удалить'),
            ),
          ]),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final profiles = catalog?.profiles;
    return Column(
      key: const Key('wireguard_profiles_card'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PushokPanel(child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              const Expanded(child: Text('Профили подключения',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800))),
              IconButton(
                key: const Key('refresh_wireguard_profiles'),
                tooltip: 'Обновить список профилей',
                onPressed: loading ? null : onRefresh,
                icon: const Icon(Icons.refresh),
              ),
            ]),
            const SizedBox(height: 8),
            const Text('Выбранный профиль используется при нажатии «Подключить». '
              'Для изменения профилей отключите туннель.',
              style: TextStyle(color: PushokPalette.muted)),
            if (loading) const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Row(children: [
                SizedBox(width: 18, height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(width: 10),
                Expanded(child: Text('Читаем список профилей…')),
              ]),
            ),
            if (error != null) Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Semantics(liveRegion: true, child: Text(error!,
                key: const Key('wireguard_profiles_error'),
                style: const TextStyle(color: PushokPalette.orange))),
            ),
            if (!loading && error == null && profiles == null) const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text('Список профилей пока недоступен.'),
            ),
            if (profiles != null && !loading && error == null) ...[
              const SizedBox(height: 12),
              Text(profiles.isEmpty
                  ? 'Профилей пока нет. Добавьте профиль .conf.'
                  : 'Сохранено ${profiles.length} из ${WireGuardProfiles.maxProfiles}',
                key: const Key('wireguard_profiles_count'),
                style: const TextStyle(color: PushokPalette.muted)),
            ],
            if (catalog?.isFull ?? false) const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('Достигнут лимит 20 профилей. Удалите ненужный, чтобы добавить новый.',
                style: TextStyle(color: PushokPalette.orange)),
            ),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              key: const Key('add_wireguard_profile'),
              onPressed: _canChange && !(catalog?.isFull ?? true)
                  ? onAdd : null,
              icon: const Icon(Icons.add),
              label: const Text('Добавить профиль', textAlign: TextAlign.center),
            ),
          ],
        )),
        for (final profile in profiles ?? const <WireGuardProfileSummary>[]) ...[
          const SizedBox(height: 12),
          _entry(profile),
        ],
      ],
    );
  }
}
