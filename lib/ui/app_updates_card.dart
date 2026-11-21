import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../design/pushok_theme.dart';
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
  bool _refreshPending = false;
  bool _refreshAgain = false;
  bool _foreground = true;
  int _revision = 0;

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
    _foreground = state == AppLifecycleState.resumed;
    _pollTimer?.cancel();
    if (_foreground) unawaited(_refreshStatus());
  }

  void _schedulePoll() {
    _pollTimer?.cancel();
    if (!mounted || !_foreground || _status?.phase != UpdatePhase.downloading) {
      return;
    }
    _pollTimer = Timer(const Duration(seconds: 1), () {
      unawaited(_refreshStatus());
    });
  }

  Future<void> _refreshStatus() async {
    if (!mounted || !_foreground) return;
    if (_refreshPending) {
      _refreshAgain = true;
      return;
    }
    _refreshPending = true;
    final revision = _revision;
    try {
      final status = await _updates.updateStatus();
      if (!mounted || revision != _revision) return;
      setState(() => _status = status);
    } finally {
      _refreshPending = false;
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

  Future<void> _run(Future<UpdateStatus> Function() action,
      {UpdatePhase? pendingPhase}) async {
    if (_operationPending || !mounted || !_foreground) return;
    _revision++;
    _pollTimer?.cancel();
    setState(() {
      _operationPending = true;
      if (pendingPhase != null) _status = _status!.withPhase(pendingPhase);
    });
    _schedulePoll();
    final status = await action();
    if (!mounted) return;
    // A status poll started during the operation must not overwrite its result.
    _revision++;
    setState(() {
      _operationPending = false;
      _status = status;
    });
    _schedulePoll();
  }

  String _errorMessage(String? code) {
    switch (code) {
      case 'UPDATE_BUSY':
        return 'Обновление уже выполняется. Подождите немного.';
      case 'UPDATE_NETWORK_ERROR':
        return 'Не удалось проверить обновления. Проверьте интернет и попробуйте снова.';
      case 'UPDATE_METADATA_INVALID':
        return 'Не удалось получить сведения об обновлении. Попробуйте позже.';
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

  Widget _button({required Key key, required String label,
      required IconData icon, required Future<UpdateStatus> Function() action,
      UpdatePhase? pendingPhase}) => FilledButton.icon(
    key: key,
    onPressed: _operationPending ? null
        : () => _run(action, pendingPhase: pendingPhase),
    icon: Icon(icon),
    label: Text(label, textAlign: TextAlign.center),
  );

  List<Widget> _body(UpdateStatus status) {
    final body = <Widget>[];
    final unavailableError = status.phase == UpdatePhase.unavailable &&
        status.errorCode == 'UPDATE_INCOMPATIBLE';
    switch (status.phase) {
      case UpdatePhase.idle:
        body.add(const Text('Новые версии можно скачать и установить здесь.',
            style: TextStyle(color: PushokPalette.muted)));
        break;
      case UpdatePhase.checking:
        body.add(const Row(children: [
          SizedBox(width: 18, height: 18,
              child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 12),
          Expanded(child: Text('Проверяем обновления…')),
        ]));
        break;
      case UpdatePhase.available:
        body.add(Text('Доступна версия ${status.availableVersion}',
            key: const Key('available_update_version'),
            style: const TextStyle(color: PushokPalette.mint,
                fontWeight: FontWeight.w700)));
        break;
      case UpdatePhase.current:
        body.add(const Text('Установлена последняя опубликованная версия.',
            style: TextStyle(color: PushokPalette.mint)));
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
          Text(status.installPermissionGranted
              ? 'Android попросит подтвердить обновление. Удалять приложение не нужно.'
              : 'Разрешите установку обновлений для Pushok Flow в настройках Android, затем вернитесь сюда.',
              style: const TextStyle(color: PushokPalette.muted)),
        ]);
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

    Widget? action;
    if (status.phase == UpdatePhase.available) {
      action = _button(key: const Key('download_app_update'), label: 'Скачать',
          icon: Icons.download_outlined, action: _updates.downloadUpdate,
          pendingPhase: UpdatePhase.downloading);
    } else if (status.phase == UpdatePhase.ready) {
      action = status.installPermissionGranted
          ? _button(key: const Key('install_app_update'),
              label: 'Установить обновление', icon: Icons.system_update_alt,
              action: _updates.installUpdate)
          : _button(key: const Key('allow_app_update_install'),
              label: 'Разрешить установку', icon: Icons.settings_outlined,
              action: _updates.openInstallPermission);
    } else if (status.phase == UpdatePhase.checking && !_operationPending) {
      // A check may have been started by a previous instance of this card.
      // Status can be refreshed explicitly without another network check.
      action = _button(key: const Key('refresh_app_update_status'),
          label: 'Обновить статус', icon: Icons.refresh,
          action: _updates.updateStatus);
    } else if (status.phase != UpdatePhase.downloading &&
        status.phase != UpdatePhase.checking &&
        status.errorCode != 'UNSUPPORTED_PLATFORM' &&
        status.errorCode != 'UPDATES_UNAVAILABLE') {
      action = _button(key: const Key('check_app_updates'),
          label: 'Проверить обновления', icon: Icons.refresh,
          action: _updates.checkForUpdates, pendingPhase: UpdatePhase.checking);
    }
    if (action != null) body.addAll([const SizedBox(height: 16), action]);
    return body;
  }

  @override
  Widget build(BuildContext context) => PushokPanel(
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Row(children: [
        Icon(Icons.system_update_alt),
        SizedBox(width: 12),
        Expanded(child: Text('Версия и обновления',
            style: TextStyle(fontWeight: FontWeight.w700))),
      ]),
      const SizedBox(height: 12),
      if (_status == null)
        const Text('Определяем версию…',
            style: TextStyle(color: PushokPalette.muted))
      else ...[
        if (_status!.installedVersion.isNotEmpty && _status!.installedBuild > 0) ...[
          Text('Установлена версия ${_status!.installedVersion}',
              key: const Key('installed_app_version')),
          const SizedBox(height: 12),
        ],
        ..._body(_status!),
      ],
    ]),
  );
}
