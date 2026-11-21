import 'package:material_ui/material_ui.dart';

import '../design/pushok_theme.dart';
import '../platform/android_app_routes.dart';

/// Filtering is local and never changes the saved exclusions. The parent owns
/// confirmed native data, mutation acknowledgement and clear confirmation.
class AppRoutesView extends StatefulWidget {
  const AppRoutesView({
    super.key,
    required this.apps,
    required this.selectedPackages,
    required this.isAndroid,
    required this.loading,
    required this.saving,
    required this.loaded,
    required this.canEdit,
    required this.query,
    required this.onlySelected,
    required this.onQueryChanged,
    required this.onFilterChanged,
    required this.onToggle,
    this.error,
    this.disabledReason,
    this.onRefresh,
    this.onClear,
  });

  final List<InstalledApp> apps;
  final Set<String> selectedPackages;
  final bool isAndroid;
  final bool loading;
  final bool saving;
  final bool loaded;
  final bool canEdit;
  final String query;
  final bool onlySelected;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<bool> onFilterChanged;
  final void Function(String packageName, bool selected) onToggle;
  final String? error;
  final String? disabledReason;
  final VoidCallback? onRefresh;
  final VoidCallback? onClear;

  @override
  State<AppRoutesView> createState() => _AppRoutesViewState();
}

class _AppRoutesViewState extends State<AppRoutesView> {
  late final TextEditingController _search;

  @override
  void initState() {
    super.initState();
    _search = TextEditingController(text: widget.query);
  }

  @override
  void didUpdateWidget(covariant AppRoutesView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_search.text != widget.query) {
      _search.value = TextEditingValue(text: widget.query,
        selection: TextSelection.collapsed(offset: widget.query.length));
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool get _canChange => widget.isAndroid && widget.canEdit && widget.loaded &&
      !widget.loading && !widget.saving && widget.error == null;

  Widget _header() => PushokPanel(
    padding: const EdgeInsets.all(14),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Expanded(child: Text('Приложения без туннеля',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800))),
        if (widget.isAndroid) IconButton(
          key: const Key('refresh_routes'),
          tooltip: 'Обновить список приложений',
          onPressed: widget.loading || widget.saving ? null : widget.onRefresh,
          icon: const Icon(Icons.refresh),
        ),
      ]),
      const SizedBox(height: 8),
      Text(widget.isAndroid
          ? 'Отмеченные приложения подключаются напрямую. '
              'Правила применяются при следующем подключении.'
          : 'Исключения приложений доступны в приложении для Android.',
        style: const TextStyle(color: PushokPalette.muted)),
      if (widget.isAndroid) ...[
        const SizedBox(height: 14),
        TextField(
          key: const Key('route_search'),
          controller: _search,
          onChanged: widget.onQueryChanged,
          textInputAction: TextInputAction.search,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: 'Поиск приложений',
            hintText: 'Название или пакет',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: widget.query.isEmpty ? null : IconButton(
              key: const Key('clear_route_search'),
              tooltip: 'Очистить поиск',
              onPressed: () {
                _search.clear();
                widget.onQueryChanged('');
              },
              icon: const Icon(Icons.close),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 4, children: [
          ChoiceChip(
            key: const Key('routes_filter_all'),
            label: const Text('Все'),
            selected: !widget.onlySelected,
            onSelected: (_) => widget.onFilterChanged(false),
          ),
          ChoiceChip(
            key: const Key('routes_filter_selected'),
            label: const Text('Выбранные'),
            selected: widget.onlySelected,
            onSelected: (_) => widget.onFilterChanged(true),
          ),
        ]),
        const SizedBox(height: 8),
        Text(widget.loaded
            ? (widget.error == null
                ? 'Исключений: ${widget.selectedPackages.length}'
                : 'Последний список: ${widget.selectedPackages.length} исключений')
            : 'Исключения ещё не загружены',
          key: const Key('route_count'),
          style: const TextStyle(color: PushokPalette.muted)),
        if (widget.loaded && widget.selectedPackages.isNotEmpty) Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const Key('clear_route_selections'),
            onPressed: _canChange ? widget.onClear : null,
            icon: const Icon(Icons.clear_all),
            label: const Text('Снять все исключения'),
          ),
        ),
        if (widget.loading || widget.saving) Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Row(children: [
            const SizedBox(width: 18, height: 18,
              child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 10),
            Expanded(child: Text(widget.saving
                ? 'Сохраняем исключения…' : 'Обновляем список…')),
          ]),
        ),
        if (widget.error != null) Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Semantics(liveRegion: true,
            child: Text(widget.error!, key: const Key('routes_error'),
              style: const TextStyle(color: PushokPalette.orange))),
        ),
        if (widget.disabledReason != null && !widget.saving) Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(widget.disabledReason!, key: const Key('routes_disabled_reason'),
            style: const TextStyle(color: PushokPalette.muted)),
        ),
      ],
    ]),
  );

  Widget _entry(InstalledApp app, {required bool missing}) => Padding(
    key: ValueKey('route_entry_${app.packageName}'),
    padding: const EdgeInsets.only(top: 8),
    child: PushokPanel(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: SwitchListTile.adaptive(
        key: ValueKey('route_toggle_${app.packageName}'),
        contentPadding: EdgeInsets.zero,
        title: Text(app.label),
        subtitle: Text(missing
            ? 'Нет в списке приложений. Сохранённое исключение.'
            : app.packageName),
        value: widget.selectedPackages.contains(app.packageName),
        onChanged: _canChange ? (value) => widget.onToggle(app.packageName, value) : null,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final installedPackages = widget.apps.map((app) => app.packageName).toSet();
    // Launcher queries omit apps without an available launcher activity. Keep
    // every saved package visible so it can be removed without clearing others.
    final entries = <InstalledApp>[
      ...widget.apps,
      for (final package in widget.selectedPackages.difference(installedPackages))
        InstalledApp(packageName: package, label: package),
    ]..sort(InstalledApp.compare);
    final query = widget.query.trim().toLowerCase();
    final visible = entries.where((app) =>
      (!widget.onlySelected || widget.selectedPackages.contains(app.packageName)) &&
      (query.isEmpty || app.label.toLowerCase().contains(query) ||
          app.packageName.toLowerCase().contains(query))).toList();

    String? emptyMessage;
    if (widget.loaded && !widget.loading && widget.error == null && visible.isEmpty) {
      if (query.isNotEmpty) {
        emptyMessage = 'Ничего не найдено. Измените запрос или фильтр.';
      } else if (widget.onlySelected) {
        emptyMessage = 'Исключений пока нет. Выберите приложения в списке «Все».';
      } else {
        emptyMessage = 'В списке пока нет приложений. Попробуйте обновить его.';
      }
    }

    return CustomScrollView(
      key: const Key('routes_list'),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      slivers: [
        SliverToBoxAdapter(child: _header()),
        if (widget.isAndroid && emptyMessage != null) SliverToBoxAdapter(
          child: Padding(padding: const EdgeInsets.only(top: 12),
            child: PushokPanel(child: Text(emptyMessage,
              key: const Key('routes_empty')))),
        ),
        if (widget.isAndroid && widget.loaded) SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) => _entry(visible[index],
              missing: !installedPackages.contains(visible[index].packageName)),
            childCount: visible.length,
            findChildIndexCallback: (key) {
              if (key is! ValueKey<String>) return null;
              final index = visible.indexWhere((app) => key.value == 'route_entry_${app.packageName}');
              return index < 0 ? null : index;
            },
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 16)),
      ],
    );
  }
}
