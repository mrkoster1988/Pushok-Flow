import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../design/pushok_theme.dart';
import '../models/app_release_history.dart';
import '../platform/app_updates.dart';

class AppUpdatesCard extends StatefulWidget {
  const AppUpdatesCard({super.key, this.isAndroid});

  final bool? isAndroid;

  @override
  State<AppUpdatesCard> createState() => _AppUpdatesCardState();
}

class _AppUpdatesCardState extends State<AppUpdatesCard>
    with WidgetsBindingObserver {
  late final AppUpdates _updates;
  UpdateStatus? _status;
  Timer? _pollTimer;
  bool _operationPending = false;
  bool _automaticSettingPending = false;
  int _automaticSettingRevision = 0;
  int? _activeRefresh;
  int _refreshSequence = 0;
  bool _refreshAgain = false;
  bool _foreground = true;
  int _revision = 0;
  int _lifecycleRevision = 0;

  @override
  void initState() {
    super.initState();
    _updates = AppUpdates(isAndroid: widget.isAndroid);
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    unawaited(_refreshStatus());
  }

  @override
  void dispose() {
    _revision++;
    _pollTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleRevision++;
    _revision++;
    _foreground = state == AppLifecycleState.resumed;
    _pollTimer?.cancel();
    // An old read can remain pending across a pause. It must neither block the
    // resume read nor overwrite the state that the resume read observes.
    _activeRefresh = null;
    _refreshAgain = false;
    if (_foreground) unawaited(_refreshStatus());
  }

  void _schedulePoll() {
    _pollTimer?.cancel();
    final status = _status;
    if (!mounted || !_foreground || status == null) return;
    final active = {UpdatePhase.checking, UpdatePhase.downloading, UpdatePhase.installing}
        .contains(status.phase);
    if (!active && !status.automaticUpdatesEnabled &&
        !(status.phase == UpdatePhase.ready && status.installWaitingReason == 'connection')) return;
    // Observe native background work without starting it from the presentation
    // layer. Idle polling is slower; all polling stops when the app loses focus.
    _pollTimer = Timer(Duration(seconds: active ? 1 : 5), () {
      unawaited(_refreshStatus());
    });
  }

  Future<void> _refreshStatus() async {
    if (!mounted || !_foreground) return;
    if (_activeRefresh != null) {
      _refreshAgain = true;
      return;
    }
    final request = ++_refreshSequence;
    _activeRefresh = request;
    final revision = _revision;
    try {
      final status = await _updates.updateStatus();
      if (!mounted || !_foreground || revision != _revision ||
          _activeRefresh != request) return;
      setState(() => _status = status);
    } finally {
      if (_activeRefresh == request) {
        _activeRefresh = null;
        if (mounted) {
          if (_refreshAgain && _foreground) {
            _refreshAgain = false;
            unawaited(_refreshStatus());
          } else {
            _schedulePoll();
          }
        }
      }
    }
  }

  Future<void> _run(Future<UpdateStatus> Function() action,
      {UpdatePhase? pendingPhase}) async {
    if (_operationPending || _automaticSettingPending || !mounted || !_foreground) return;
    final lifecycleRevision = _lifecycleRevision;
    final settingRevision = _automaticSettingRevision;
    _revision++;
    _pollTimer?.cancel();
    _activeRefresh = null;
    _refreshAgain = false;
    setState(() {
      _operationPending = true;
      if (pendingPhase != null) _status = _status!.withPhase(pendingPhase);
    });
    _schedulePoll();
    final status = await action();
    if (!mounted) return;
    // A status poll started during the operation must not overwrite its result.
    _revision++;
    _activeRefresh = null;
    _refreshAgain = false;
    if (!_foreground || lifecycleRevision != _lifecycleRevision ||
        settingRevision != _automaticSettingRevision) {
      // Native work may finish while Android's permission/installer UI is in
      // front, or after a pause/resume. Obtain a new snapshot on return.
      _operationPending = false;
      if (_foreground) unawaited(_refreshStatus());
      return;
    }
    setState(() {
      _operationPending = false;
      _status = status;
    });
    _schedulePoll();
  }

  Future<void> _setAutomaticUpdates(bool enabled) async {
    if (!mounted || !_foreground || _automaticSettingPending || _status == null ||
        enabled == _status!.automaticUpdatesEnabled) return;
    final lifecycleRevision = _lifecycleRevision;
    final settingRevision = ++_automaticSettingRevision;
    _revision++;
    _pollTimer?.cancel();
    _activeRefresh = null;
    _refreshAgain = false;
    setState(() => _automaticSettingPending = true);
    final status = await _updates.setAutomaticUpdates(enabled);
    if (!mounted || settingRevision != _automaticSettingRevision) return;
    _revision++;
    _activeRefresh = null;
    _refreshAgain = false;
    if (!_foreground || lifecycleRevision != _lifecycleRevision) {
      _automaticSettingPending = false;
      if (_foreground) unawaited(_refreshStatus());
      return;
    }
    setState(() {
      _automaticSettingPending = false;
      _status = status;
    });
    _schedulePoll();
  }

  void _showAutomaticUpdateHelp() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Автообновление'),
        scrollable: true,
        content: const Text(
          'Pushok Flow проверяет новые версии в фоне примерно раз в 6 часов '
          'и загружает их при доступном интернете, включая мобильную сеть. '
          'Android выбирает время запуска, поэтому проверка может произойти позже.\n\n'
          'Проверенный файл устанавливается автоматически, если Android позволяет. '
          'Установка ждёт отключения активного подключения и выхода из Pushok Flow. '
          'На некоторых устройствах потребуется ваше подтверждение.\n\n'
          'Один раз разрешите установку обновлений для Pushok Flow в настройках Android. '
          'Они откроются только по кнопке «Разрешить установку». '
          'Удалять приложение не нужно.\n\n'
          'Если автообновление выключено, проверить, скачать и установить новую '
          'версию можно вручную в этом разделе.',
        ),
        actions: [TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Понятно'),
        )],
      ),
    );
  }

  String _errorMessage(String? code) {
    switch (code) {
      case 'UPDATE_BUSY':
        return 'Обновление уже выполняется. Подождите немного.';
      case 'UPDATE_NETWORK_ERROR':
        return 'Не удалось проверить обновления. Проверьте интернет и попробуйте снова.';
      case 'UPDATE_METADATA_INVALID':
        return 'Не удалось получить сведения об обновлении. Попробуйте позже.';
      case 'UPDATE_METADATA_STALE':
        return 'Не удалось получить свежие сведения об обновлении. Попробуйте ещё раз.';
      case 'UPDATE_RATE_LIMITED':
        return 'Сервис обновлений временно ограничил проверки. Попробуйте позже.';
      case 'UPDATE_INCOMPATIBLE':
        return 'Это обновление не подходит для вашего устройства. Дождитесь совместимой версии.';
      case 'UPDATE_SIGNATURE_MISMATCH':
        return 'Это обновление несовместимо с установленным приложением. Дождитесь совместимой версии.';
      case 'UPDATE_DOWNLOAD_FAILED':
        return 'Не удалось скачать обновление. Проверьте интернет и попробуйте снова.';
      case 'UPDATE_CHECKSUM_MISMATCH':
      case 'UPDATE_APK_INVALID':
        return 'Файл обновления не прошёл проверку. Скачайте его заново.';
      case 'UPDATE_STORAGE_ERROR':
        return 'Не удалось сохранить обновление. Проверьте свободное место и попробуйте снова.';
      case 'UPDATE_INSTALL_FAILED':
        return 'Android не установил обновление. Попробуйте установить его ещё раз.';
      case 'UPDATE_SCHEDULER_UNAVAILABLE':
        return 'Не удалось настроить фоновые обновления. Попробуйте ещё раз или обновите приложение вручную.';
      case 'UPDATE_NOT_READY':
        return 'Обновление ещё не готово к установке. Скачайте его заново.';
      case 'UPDATE_INTERRUPTED':
        return 'Обновление прервано. Попробуйте ещё раз.';
      case 'INSTALL_PERMISSION_REQUIRED':
        return 'Разрешите Pushok Flow устанавливать обновления в настройках Android.';
      case 'INSTALLER_UNAVAILABLE':
        return 'Не удалось открыть установку Android. Попробуйте ещё раз.';
      case 'UPDATE_STATUS_INVALID':
        return 'Не удалось получить состояние обновления. Попробуйте ещё раз.';
      default:
        return 'Не удалось обновить приложение. Попробуйте ещё раз.';
    }
  }

  String _bytes(int count) => count < 1024 * 1024
      ? '${(count / 1024).ceil()} КБ'
      : '${(count / (1024 * 1024)).toStringAsFixed(1).replaceAll('.', ',')} МБ';

  String _checkTime(int milliseconds) {
    final time = DateTime.fromMillisecondsSinceEpoch(milliseconds);
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(time.day)}.${two(time.month)}.${time.year}, '
        '${two(time.hour)}:${two(time.minute)}';
  }

  Widget _button({required Key key, required String label,
      required IconData icon, required Future<UpdateStatus> Function() action,
      UpdatePhase? pendingPhase}) => FilledButton.icon(
    key: key,
    onPressed: _operationPending || _automaticSettingPending || !_foreground ? null
        : () => _run(action, pendingPhase: pendingPhase),
    icon: Icon(icon),
    label: Text(label, textAlign: TextAlign.center),
  );

  String _readyMessage(UpdateStatus status) {
    if (!status.installPermissionGranted || status.installWaitingReason == 'permission') {
      return 'Файл проверен. Один раз разрешите установку обновлений для Pushok Flow '
          'в настройках Android, затем вернитесь сюда.';
    }
    return switch (status.installWaitingReason) {
      'confirmation' => 'Файл проверен. Android ждёт вашего подтверждения установки.',
      'connection' => 'Файл проверен. Автоустановка ждёт отключения активного подключения. '
          'Вы можете установить обновление вручную кнопкой ниже.',
      'foreground' => 'Файл проверен. Автоустановка продолжится, когда вы свернёте Pushok Flow.',
      'unsupported' => 'Файл проверен. Эта версия Android требует подтверждения установки.',
      _ => status.automaticUpdatesEnabled
          ? 'Файл проверен. Обновление установится автоматически, если Android позволяет.'
          : 'Файл проверен. Можно установить обновление поверх текущей версии.',
    };
  }

  Widget _releaseNotes(AppReleaseNotes notes, {required String heading, required Key key}) =>
    Column(key: key, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(heading, style: const TextStyle(fontWeight: FontWeight.w700)),
      if (notes.publishedOn != null) ...[
        const SizedBox(height: 4),
        Text('Опубликовано ${notes.publishedOn!.substring(8, 10)}.'
          '${notes.publishedOn!.substring(5, 7)}.${notes.publishedOn!.substring(0, 4)}',
          style: const TextStyle(color: PushokPalette.muted)),
      ],
      for (final change in notes.changes) Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('•', style: TextStyle(color: PushokPalette.teal)),
          const SizedBox(width: 8),
          Expanded(child: Text(change)),
        ]),
      ),
    ]);

  List<Widget> _releaseHistory(UpdateStatus status) {
    final currentNotes = bundledAppRelease(status.installedVersion, status.installedBuild) ??
      (!status.hasNewerVersion && status.releaseNotes?.matches(
        status.installedVersion, status.installedBuild) == true ? status.releaseNotes : null);
    final history = bundledAppReleaseHistory
      .where((notes) => notes.versionCode <= status.installedBuild).toList();
    if (currentNotes == null && history.isEmpty) return const [];
    return [
      const SizedBox(height: 16),
      const Divider(),
      if (currentNotes != null) ...[
        const SizedBox(height: 12),
        _releaseNotes(currentNotes, heading: 'Что нового в установленной версии ${currentNotes.versionName}',
          key: const Key('current_release_notes')),
        const SizedBox(height: 8),
      ],
      if (history.isNotEmpty) ExpansionTile(
        key: const Key('app_release_history'),
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        title: const Text('История обновлений'),
        children: [
          for (final notes in history) Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 16),
            child: _releaseNotes(notes, heading: 'Версия ${notes.versionName}'
              '${notes.matches(status.installedVersion, status.installedBuild) ? ' · установлена' : ''}',
              key: ValueKey('history_release_${notes.versionCode}')),
          ),
        ],
      ),
    ];
  }

  List<Widget> _body(UpdateStatus status) {
    final body = <Widget>[];
    final unavailableError = status.phase == UpdatePhase.unavailable &&
        status.errorCode == 'UPDATE_INCOMPATIBLE';
    switch (status.phase) {
      case UpdatePhase.idle:
        body.add(Text(status.automaticUpdatesEnabled
            ? 'Новые версии проверяются и загружаются в фоне.'
            : 'Новые версии можно скачать и установить здесь.',
            style: const TextStyle(color: PushokPalette.muted)));
        break;
      case UpdatePhase.checking:
        body.add(Row(children: [
          const SizedBox(width: 18, height: 18,
              child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 12),
          Expanded(child: Semantics(liveRegion: true, child: Text(
            switch (status.checkStage) {
              'release' => 'Ищем новую версию…',
              'manifest' => 'Проверяем сведения об обновлении…',
              _ => 'Проверяем обновления…',
            },
            key: const Key('app_update_check_stage'),
          ))),
        ]));
        break;
      case UpdatePhase.available:
        body.add(Text('Доступна версия ${status.availableVersion}',
            key: const Key('available_update_version'),
            style: const TextStyle(color: PushokPalette.mint,
                fontWeight: FontWeight.w700)));
        break;
      case UpdatePhase.current:
        if (status.errorCode == null) {
          body.add(const Text('Новых версий не найдено.',
              style: TextStyle(color: PushokPalette.mint)));
        }
        break;
      case UpdatePhase.downloading:
        body.addAll([
          Text('Скачиваем версию ${status.availableVersion}…'),
          const SizedBox(height: 12),
          LinearProgressIndicator(
            key: const Key('app_update_progress'),
            value: status.downloadProgress,
            semanticsLabel: 'Загрузка обновления',
            semanticsValue: status.downloadProgress == null ? null
                : '${(status.downloadProgress! * 100).round()}%',
          ),
          const SizedBox(height: 8),
          Text(status.totalBytes > 0
              ? '${_bytes(status.downloadedBytes)} из ${_bytes(status.totalBytes)}'
              : 'Загружено ${_bytes(status.downloadedBytes)}',
              style: const TextStyle(color: PushokPalette.muted)),
        ]);
        break;
      case UpdatePhase.ready:
        body.addAll([
          Text('Версия ${status.availableVersion} готова к установке.',
              style: const TextStyle(color: PushokPalette.mint,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text(_readyMessage(status), key: const Key('app_update_install_waiting'),
              style: const TextStyle(color: PushokPalette.muted)),
        ]);
        break;
      case UpdatePhase.installing:
        body.add(Row(children: [
          const SizedBox(width: 18, height: 18,
              child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 12),
          Expanded(child: Semantics(liveRegion: true, child: Text(
            'Устанавливаем версию ${status.availableVersion}…',
            key: const Key('app_update_installing'),
          ))),
        ]));
        break;
      case UpdatePhase.unavailable:
        if (!unavailableError) {
          body.add(Text(switch (status.errorCode) {
            'UNSUPPORTED_PLATFORM' => 'Обновления доступны в приложении Android.',
            'UPDATES_UNAVAILABLE' => 'Обновления пока недоступны в этой сборке приложения.',
            _ => 'Новая версия пока не опубликована.',
          }, style: const TextStyle(color: PushokPalette.muted)));
        }
        break;
      case UpdatePhase.error:
        break;
    }

    if (status.hasNewerVersion) {
      final notes = status.releaseNotes?.matches(status.availableVersion!, status.availableBuild!) == true
        ? status.releaseNotes : bundledAppRelease(status.availableVersion!, status.availableBuild!);
      body.add(const SizedBox(height: 12));
      body.add(notes == null
        ? const Text('Описание изменений пока недоступно.',
          key: Key('available_release_notes_missing'), style: TextStyle(color: PushokPalette.muted))
        : _releaseNotes(notes, heading: 'Изменения в версии ${notes.versionName}',
          key: const Key('available_release_notes')));
    }

    if (status.checkedAtMillis != null) {
      if (body.isNotEmpty) body.add(const SizedBox(height: 12));
      body.add(Text(
        'Последняя успешная проверка: ${_checkTime(status.checkedAtMillis!)}',
        key: const Key('app_update_checked_at'),
        style: const TextStyle(color: PushokPalette.muted),
      ));
    }

    if (status.phase == UpdatePhase.error || unavailableError ||
        (status.errorCode != null && status.phase != UpdatePhase.unavailable)) {
      if (body.isNotEmpty) body.add(const SizedBox(height: 12));
      body.add(Semantics(liveRegion: true, child: Text(
        unavailableError
            ? 'Не удалось проверить совместимость с установленным приложением. Попробуйте ещё раз.'
            : _errorMessage(status.errorCode),
        key: const Key('app_update_error'),
        style: const TextStyle(color: PushokPalette.orange),
      )));
    }

    if (status.automaticUpdatesEnabled && !status.installPermissionGranted &&
        {UpdatePhase.idle, UpdatePhase.current, UpdatePhase.available}.contains(status.phase)) {
      body.addAll([
        const SizedBox(height: 12),
        const Text('Для установки нужно один раз разрешить её в Android.',
            style: TextStyle(color: PushokPalette.muted)),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: const Key('allow_app_update_install'),
          onPressed: _operationPending || _automaticSettingPending || !_foreground
              ? null : () => _run(_updates.openInstallPermission),
          icon: const Icon(Icons.settings_outlined),
          label: const Text('Разрешить установку', textAlign: TextAlign.center),
        ),
      ]);
    }

    Widget? action;
    if (status.phase == UpdatePhase.available) {
      action = _button(key: const Key('download_app_update'), label: 'Скачать',
          icon: Icons.download_outlined, action: _updates.downloadUpdate,
          pendingPhase: UpdatePhase.downloading);
    } else if (status.phase == UpdatePhase.ready) {
      action = status.installPermissionGranted
          ? _button(key: const Key('install_app_update'),
              label: status.installWaitingReason == 'confirmation'
                  ? 'Подтвердить установку' : 'Установить обновление',
              icon: Icons.system_update_alt,
              action: _updates.installUpdate)
          : _button(key: const Key('allow_app_update_install'),
              label: 'Разрешить установку', icon: Icons.settings_outlined,
              action: _updates.openInstallPermission);
    } else if (status.phase != UpdatePhase.downloading &&
        status.phase != UpdatePhase.checking &&
        status.phase != UpdatePhase.installing && status.phase != UpdatePhase.ready &&
        status.errorCode != 'UNSUPPORTED_PLATFORM' &&
        status.errorCode != 'UPDATES_UNAVAILABLE') {
      action = _button(key: const Key('check_app_updates'),
          label: 'Проверить обновления', icon: Icons.refresh,
          action: _updates.checkForUpdates, pendingPhase: UpdatePhase.checking);
    }
    if (action != null) body.addAll([const SizedBox(height: 16), action]);
    if (status.phase == UpdatePhase.available || status.phase == UpdatePhase.ready) {
      body.addAll([
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: const Key('check_app_updates'),
          onPressed: _operationPending || _automaticSettingPending || !_foreground ? null
              : () => _run(_updates.checkForUpdates,
                  pendingPhase: UpdatePhase.checking),
          icon: const Icon(Icons.refresh),
          label: const Text('Проверить обновления', textAlign: TextAlign.center),
        ),
      ]);
    }
    return body;
  }

  @override
  Widget build(BuildContext context) => PushokPanel(
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        const Icon(Icons.system_update_alt),
        const SizedBox(width: 12),
        const Expanded(child: Text('Версия и обновления',
            style: TextStyle(fontWeight: FontWeight.w700))),
        IconButton(
          key: const Key('info_automatic_app_updates'),
          tooltip: 'Об автообновлении',
          onPressed: _showAutomaticUpdateHelp,
          icon: const Icon(Icons.info_outline),
        ),
      ]),
      const SizedBox(height: 12),
      if (_status == null)
        const Text('Определяем версию…',
            style: TextStyle(color: PushokPalette.muted))
      else ...[
        if (_status!.installedVersion.isNotEmpty && _status!.installedBuild > 0) ...[
          Text('Установлена версия ${_status!.installedVersion}',
              key: const Key('installed_app_version')),
          SwitchListTile.adaptive(
            key: const Key('automatic_app_updates'),
            contentPadding: EdgeInsets.zero,
            value: _status!.automaticUpdatesEnabled,
            onChanged: _automaticSettingPending || !_foreground
                ? null : _setAutomaticUpdates,
            title: const Text('Автообновление'),
            subtitle: Text(_automaticSettingPending ? 'Сохраняем настройку…'
                : _status!.automaticUpdatesEnabled ? 'Проверка и загрузка в фоне'
                : 'Обновления по кнопке',
                style: const TextStyle(color: PushokPalette.muted)),
          ),
          const SizedBox(height: 12),
        ],
        ..._body(_status!),
        ..._releaseHistory(_status!),
      ],
    ]),
  );
}
