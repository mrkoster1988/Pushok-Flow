import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'design/pushok_theme.dart';
import 'dart:io' show Platform;
import 'dart:async' show Timer, unawaited;
import 'platform/android_app_routes.dart';
import 'ai/pushok_ai_memory.dart';
import 'platform/wireguard_tunnel.dart';
import 'platform/wireguard_profiles.dart';
import 'platform/profile_privacy.dart';
import 'platform/tunnel_diagnostics.dart';
import 'ui/wireguard_profile_editor.dart';
import 'ui/wireguard_profiles_card.dart';
import 'ui/app_updates_card.dart';
import 'ui/tunnel_diagnostics_card.dart';
import 'ui/app_routes_view.dart';

void main() => runApp(const PushokFlowApp());

class PushokFlowApp extends StatelessWidget {
  const PushokFlowApp({super.key, this.isAndroid});
  // Tests exercise the real Android channel flow without requiring an emulator.
  final bool? isAndroid;
  static const bg = PushokPalette.background;
  static const panel = PushokPalette.surface;
  static const teal = PushokPalette.teal;
  static const secondary = PushokPalette.muted;
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Pushok Flow', debugShowCheckedModeBanner: false,
        theme: buildPushokTheme(),
        home: FlowHome(isAndroid: isAndroid),
      );
}

class FlowHome extends StatefulWidget {
  const FlowHome({super.key, this.isAndroid});
  final bool? isAndroid;
  @override
  State<FlowHome> createState() => _FlowHomeState();
}

class _FlowHomeState extends State<FlowHome> with WidgetsBindingObserver {
  int tab = 0;
  List<InstalledApp> installed = [];
  Set<String> bypassPackages = {};
  bool loadingApps = false;
  String? routeError;
  String? connectionError;
  WireGuardProfiles? _profiles;
  String? _profilesError;
  String? lastErrorCode;
  TunnelDiagnostics _diagnostics = const TunnelDiagnostics.unavailable();
  bool _diagnosticsStale = true;
  Timer? _healthPoll;
  bool connected = false;
  bool connecting = false;
  bool _profileBusy = false;
  bool _profileEditorOpen = false;
  bool _statusRefreshing = false;
  bool _savingRoute = false;
  bool _routeConfirmationOpen = false;
  bool _routesLoaded = false;
  bool _routesStale = true;
  int _routeEpoch = 0;
  String _routeQuery = '';
  bool _onlySelectedRoutes = false;
  int _statusEpoch = 0;
  int _profileRequestEpoch = 0;
  int _tunnelIntentEpoch = 0;
  bool _foreground = true;
  Map<String, int> feedback = {};
  String? feedbackMessage;
  bool get _isAndroid => widget.isAndroid ?? Platform.isAndroid;
  bool get _nativeBusy => _diagnostics.isKnown &&
      _diagnostics.transitioning && !_diagnosticsStale;
  bool get _tunnelConfirmed => connected && _diagnostics.isKnown &&
      !_diagnosticsStale && !_nativeBusy && !connecting;
  bool get _canManageProfiles => _isAndroid && _foreground &&
      !connected && !connecting && !_nativeBusy && !_profileBusy &&
      !_savingRoute && !_routeConfirmationOpen &&
      !_profileEditorOpen && !_statusRefreshing && _profiles != null &&
      _profilesError == null && _diagnostics.isKnown && !_diagnosticsStale;
  bool get _canEditRoutes => _isAndroid && _foreground && _routesLoaded &&
      !_routesStale && !loadingApps && !_savingRoute && !_routeConfirmationOpen &&
      routeError == null && !connected && !connecting && !_nativeBusy &&
      !_profileBusy && !_profileEditorOpen && !_statusRefreshing &&
      _diagnostics.isKnown && !_diagnosticsStale;

  void _showNotice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), showCloseIcon: true));
  }

  String _connectionMessage(Object error, {bool disconnecting = false}) {
    if (error is PlatformException) {
      switch (error.code) {
        case 'VPN_DENIED':
          return 'Разрешение VPN отклонено. Нажмите «Подключить» и разрешите VPN.';
        case 'VPN_REQUEST_INTERRUPTED':
          return 'Запрос разрешения VPN прерван. Повторите подключение.';
        case 'VPN_BUSY':
          return 'Подключение уже изменяется. Дождитесь завершения.';
        case 'INVALID_CONFIG':
          return 'Профиль WireGuard некорректен. Откройте его настройки и проверьте данные.';
        case 'PROFILE_LOAD_FAILED':
          return 'Не удалось открыть сохранённый профиль. Откройте «Серверы» и повторите проверку.';
        case 'PROFILE_CHANGED':
        case 'PROFILE_NOT_FOUND':
          return 'Выбранный профиль изменился. Проверьте выбор в «Серверах» и подключитесь снова.';
        case 'PROFILE_STORE_UNAVAILABLE':
          return 'Не удалось записать профили. Перезапустите приложение перед повторной попыткой.';
        case 'ROUTES_STORE_UNAVAILABLE':
          return 'Не удалось записать исключения. Перезапустите приложение перед подключением.';
        case 'ROUTES_LOAD_FAILED':
          return 'Не удалось прочитать исключения. Проверьте раздел «Маршруты» перед подключением.';
        case 'WG_DISCONNECT_FAILED':
          return 'Не удалось отключить VPN. Повторите попытку.';
      }
    }
    return disconnecting
        ? 'Не удалось отключить VPN. Повторите попытку.'
        : 'Не удалось установить WireGuard-туннель. Проверьте профиль и доступность сервера.';
  }

  Future<void> _toggleTunnel({String? profile}) async {
    if (!_isAndroid || !_foreground || connecting || _nativeBusy || _profileBusy ||
        _profileEditorOpen || _savingRoute || _routeConfirmationOpen) return;
    final tunnelIntent = ++_tunnelIntentEpoch;
    final disconnecting = connected;
    final requestEpoch = _profileRequestEpoch;
    var needsProfile = false;
    _statusEpoch++;
    setState(() {
      connecting = true;
      connectionError = null;
      _diagnosticsStale = true;
    });
    try {
      if (disconnecting) {
        await WireGuardTunnel.disconnect();
        if (mounted) setState(() {
          connected = false;
          _diagnostics = const TunnelDiagnostics(isKnown: true, connected: false,
              statistics: TunnelStatistics.inactive());
        });
      } else {
        // Only this explicit action transfers a saved configuration into Dart.
        // Native code verifies this ID and content again under its operation
        // lease, so a different Activity cannot switch profiles in between.
        final catalog = await WireGuardTunnel.listProfiles();
        if (!mounted || !_foreground || requestEpoch != _profileRequestEpoch) return;
        final active = catalog.activeProfile;
        if (active == null) {
          needsProfile = true;
          setState(() { _profiles = catalog; _profilesError = null; });
        } else {
          final config = profile ?? await WireGuardTunnel.loadProfile(profileId: active.id);
          if (!mounted || !_foreground || requestEpoch != _profileRequestEpoch) return;
          if (config == null || config.trim().isEmpty) {
            throw PlatformException(code: 'PROFILE_NOT_FOUND');
          }
          final ok = await WireGuardTunnel.connect(config, expectedProfileId: active.id);
          if (!mounted) return;
          setState(() {
            connected = ok;
            _diagnostics = TunnelDiagnostics(isKnown: true, connected: ok);
          });
          if (!ok) {
            final message = _connectionMessage(StateError('not connected'));
            setState(() => connectionError = message);
            _showNotice(message);
          }
        }
      }
    } catch (error) {
      if (mounted) {
        final message = _connectionMessage(error, disconnecting: disconnecting);
        setState(() => connectionError = message);
        _showNotice(message);
      }
    } finally {
      if (mounted) {
        setState(() => connecting = false);
        await _refreshProfileStatus();
      }
    }
    if (needsProfile && mounted && _foreground && requestEpoch == _profileRequestEpoch) {
      await _editProfile(connectAfterSave: true, tunnelIntent: tunnelIntent);
    }
  }

  @override
  void dispose() {
    _healthPoll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    _loadRoutes();
    _refreshProfileStatus();
    _loadAiFeedback();
    _startHealthPolling();
  }

  void _startHealthPolling() {
    _healthPoll?.cancel();
    if (!_isAndroid || !_foreground) return;
    _healthPoll = Timer.periodic(const Duration(seconds: 10), (_) {
      if ((connected || _nativeBusy || !_diagnostics.isKnown) &&
          !connecting && mounted && _foreground) _refreshProfileStatus();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.resumed) {
      _startHealthPolling();
      _refreshProfileStatus();
      _loadRoutes();
    } else {
      // A request made before losing focus must not open the editor later,
      // even if the user returns before a native response arrives.
      _profileRequestEpoch++;
      // A sample requested before app switching is no longer a fresh reading.
      _statusEpoch++;
      _routeEpoch++;
      setState(() {
        _diagnosticsStale = true;
        _routesStale = true;
        loadingApps = false;
      });
      _healthPoll?.cancel();
    }
  }

  Future<void> _loadAiFeedback() async {
    if (!_isAndroid) return;
    try {
      final data = await PushokAiMemory.summary();
      if (mounted) setState(() => feedback = data);
    } catch (_) { if (mounted) setState(() => feedbackMessage = 'Память недоступна на этом устройстве.'); }
  }

  Future<void> _rateConnection(bool helpful) async {
    try {
      final data = await PushokAiMemory.record(category: 'connection', helpful: helpful);
      if (mounted) setState(() { feedback = data; feedbackMessage = 'Ответ сохранён только на устройстве.'; });
    } catch (_) { if (mounted) setState(() => feedbackMessage = 'Не удалось сохранить оценку.'); }
  }

  Future<void> _clearAiFeedback() async {
    try {
      await PushokAiMemory.clear();
      if (mounted) setState(() { feedback = {}; feedbackMessage = 'Локальная память очищена.'; });
    } catch (_) {
      if (mounted) setState(() => feedbackMessage = 'Не удалось очистить память.');
    }
  }

  Future<void> _refreshProfileStatus() async {
    if (!_isAndroid || !mounted || !_foreground || connecting || _statusRefreshing ||
        _profileBusy || _profileEditorOpen || _savingRoute) return;
    setState(() => _statusRefreshing = true);
    final epoch = _statusEpoch;
    try {
      try {
        final catalog = await WireGuardTunnel.listProfiles()
            .timeout(const Duration(seconds: 5));
        if (mounted && _foreground && epoch == _statusEpoch) {
          setState(() { _profiles = catalog; _profilesError = null; });
        }
      } catch (error) { // A profile-store error must not prevent status refresh.
        if (mounted && _foreground && epoch == _statusEpoch) {
          setState(() => _profilesError = error is PlatformException &&
              error.code == 'PROFILE_STORE_UNAVAILABLE'
                  ? 'Не удалось записать профили. Перезапустите приложение перед повторной попыткой.'
                  : 'Не удалось прочитать сохранённые профили. Повторите проверку.');
        }
      }
      if (!mounted || !_foreground || epoch != _statusEpoch) return;
      try {
        final info = await WireGuardTunnel.diagnostics()
            .timeout(const Duration(seconds: 5));
        if (mounted && _foreground && epoch == _statusEpoch) setState(() {
          _diagnostics = info;
          _diagnosticsStale = !info.isKnown;
          if (info.isKnown) {
            connected = info.connected;
          } else if (info.connected) {
            // Retain an explicit last-known UP state for the Disconnect action.
            // An unknown read must never claim a successful disconnect.
            connected = true;
          }
          lastErrorCode = info.lastErrorCode;
        });
      } catch (_) {
        if (mounted && _foreground && epoch == _statusEpoch) setState(() {
          _diagnostics = TunnelDiagnostics.unavailable(connected: connected);
          _diagnosticsStale = true;
          lastErrorCode = null;
        });
      }
    } finally {
      if (mounted) {
        setState(() => _statusRefreshing = false);
        // Coalesce a resume/connect refresh behind an older in-flight sample.
        if (_foreground && !connecting && epoch != _statusEpoch) {
          unawaited(_refreshProfileStatus());
        }
      }
    }
  }

  Future<void> _editProfile({WireGuardProfileSummary? profile,
      bool connectAfterSave = false, int? tunnelIntent}) async {
    if (!_canManageProfiles) return;
    if (profile == null && _profiles!.isFull) {
      _showNotice('Можно сохранить до 20 профилей. Удалите ненужный профиль.');
      return;
    }
    _statusEpoch++;
    setState(() => _profileBusy = true);
    final requestEpoch = _profileRequestEpoch;
    ProfilePrivacy? protection;
    String? saved;
    int? saveIntentEpoch;
    try {
      try {
        protection = await ProfilePrivacy.acquire();
      } catch (_) {
        // Never expose platform messages/details or open an unprotected editor.
        if (mounted && _foreground && requestEpoch == _profileRequestEpoch) {
          _showNotice('Не удалось защитить экран профиля. Закройте и снова откройте приложение.');
        }
        return;
      }
      if (!mounted || !_foreground || requestEpoch != _profileRequestEpoch) return;
      var draft = '';
      try {
        if (profile != null) {
          final stored = await WireGuardTunnel.loadProfile(profileId: profile.id);
          if (stored == null || stored.trim().isEmpty) {
            throw PlatformException(code: 'PROFILE_NOT_FOUND');
          }
          draft = stored;
        }
      } catch (error) {
        // Never turn an unreadable existing profile into an empty editable draft.
        if (mounted && _foreground && requestEpoch == _profileRequestEpoch) {
          _showNotice(error is PlatformException && error.code == 'PROFILE_STORE_UNAVAILABLE'
              ? _profileActionMessage(error)
              : 'Не удалось открыть профиль. Обновите список и попробуйте снова.');
        }
        return;
      }
      if (!mounted || !_foreground || requestEpoch != _profileRequestEpoch) return;
      if (connected || connecting || _nativeBusy) {
        _showNotice('Для изменения профиля отключите VPN.');
        return;
      }
      setState(() { _profileBusy = false; _profileEditorOpen = true; });
      final navigator = Navigator.of(context);
      final localizations = MaterialLocalizations.of(context);
      final route = ModalBottomSheetRoute<String>(
        capturedThemes: InheritedTheme.capture(from: context, to: navigator.context),
        settings: const RouteSettings(name: 'wireguard-profile'),
        barrierLabel: localizations.scrimLabel,
        barrierOnTapHint: localizations.scrimOnTapHint(localizations.bottomSheetLabel),
        modalBarrierColor: Theme.of(context).bottomSheetTheme.modalBarrierColor,
        isScrollControlled: true,
        useSafeArea: true,
        isDismissible: false,
        enableDrag: false,
        backgroundColor: PushokPalette.midnight,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          side: BorderSide(color: PushokPalette.glowCyan),
        ),
        builder: (context) => WireGuardProfileEditor(
          initialConfig: draft,
          initialName: profile?.name ?? (_profiles!.profiles.isEmpty
              ? 'Мой профиль' : 'Профиль ${_profiles!.profiles.length + 1}'),
          connectAfterSave: connectAfterSave,
          onImport: WireGuardTunnel.importProfile,
          onCancelImport: WireGuardTunnel.cancelProfileImport,
          onSave: (config, name) async {
            if (!mounted || !_foreground) {
              throw PlatformException(code: 'PROFILE_SAVE_INTERRUPTED');
            }
            // Choosing a file leaves the app temporarily. A new explicit Save
            // after returning authorizes connect-after-save for that foreground
            // session, while later app switching still invalidates the intent.
            saveIntentEpoch = _profileRequestEpoch;
            await WireGuardTunnel.saveProfile(config, profileId: profile?.id,
                name: name, createNew: profile == null);
            if (mounted) {
              _statusEpoch++;
              setState(() => connectionError = null);
            }
          },
        ),
      );
      // Route.completed also resolves when the Navigator is disposed. Unlike
      // push()/popped, it waits until the closing animation and overlay are gone.
      // Do not disable protection while the last frame of the key is visible.
      unawaited(navigator.push<String>(route));
      saved = await route.completed;
      // Also submit a frame without the editor before unprotecting the window
      // when the Navigator was removed without a closing animation.
      await WidgetsBinding.instance.endOfFrame;
    } finally {
      if (protection != null) {
        try {
          await protection.release();
        } catch (_) {
          // Fail closed: native protection stays enabled if cleanup cannot finish.
          if (mounted && _foreground) {
            _showNotice('Защита экрана осталась включённой. Для снимков других экранов перезапустите приложение.');
          }
        }
      }
      if (mounted) {
        _statusEpoch++;
        setState(() { _profileBusy = false; _profileEditorOpen = false; });
        await _refreshProfileStatus();
      }
    }
    if (!mounted || saved == null) return;
    if (connectAfterSave) {
      // A slow save must not start VPN permission UI after app switching.
      if (!_foreground || saveIntentEpoch != _profileRequestEpoch) {
        if (_foreground) _showNotice('Профиль сохранён. Нажмите «Подключить», когда будете готовы.');
        return;
      }
      // The user may act while the post-save catalog refresh is pending.
      // An older Save-and-Connect intent must never toggle a newer tunnel off.
      if (tunnelIntent != _tunnelIntentEpoch || connected || connecting) return;
      await _toggleTunnel(profile: saved);
    } else {
      _showNotice('Профиль сохранён на устройстве. Можно подключаться.');
    }
  }

  String _profileActionMessage(Object error) {
    if (error is PlatformException) {
      if (error.code == 'VPN_ACTIVE' || error.code == 'VPN_BUSY') {
        return 'Сначала отключите туннель и дождитесь завершения операции.';
      }
      if (error.code == 'PROFILE_NOT_FOUND') {
        return 'Профиль уже недоступен. Обновите список.';
      }
      if (error.code == 'PROFILE_STORE_UNAVAILABLE') {
        return 'Не удалось записать профили. Перезапустите приложение перед повторной попыткой.';
      }
      if (error.code == 'VPN_STATE_UNAVAILABLE') {
        return 'Не удалось проверить состояние туннеля. Обновите список и повторите попытку.';
      }
    }
    return 'Не удалось изменить профили. Повторите проверку и попробуйте снова.';
  }

  Future<void> _selectProfile(WireGuardProfileSummary profile) async {
    if (!_canManageProfiles || profile.id == _profiles!.activeProfileId) return;
    _statusEpoch++;
    setState(() => _profileBusy = true);
    try {
      await WireGuardTunnel.selectProfile(profile.id);
      if (mounted) {
        _statusEpoch++;
        setState(() => connectionError = null);
        _showNotice('Выбран профиль «${profile.name}».');
      }
    } catch (error) {
      _showNotice(_profileActionMessage(error));
    } finally {
      if (mounted) {
        _statusEpoch++;
        setState(() => _profileBusy = false);
        await _refreshProfileStatus();
      }
    }
  }

  Future<void> _deleteProfile(WireGuardProfileSummary profile) async {
    if (!_canManageProfiles) return;
    final intentEpoch = _profileRequestEpoch;
    final remaining = _profiles!.profiles.where((p) => p.id != profile.id).toList();
    final fallback = profile.id == _profiles!.activeProfileId && remaining.isNotEmpty
        ? '\n\nДля следующего подключения будет выбран «${remaining.first.name}».'
        : '';
    _statusEpoch++;
    setState(() => _profileBusy = true);
    try {
      final confirmed = await showDialog<bool>(context: context,
        builder: (context) => AlertDialog(
          title: const Text('Удалить профиль?'),
          content: Text('«${profile.name}» будет удалён с этого устройства.$fallback'),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Отмена')),
            TextButton(key: const Key('confirm_delete_wireguard_profile'),
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Удалить')),
          ],
        ));
      // Confirmation from an earlier foreground session cannot delete on return.
      if (confirmed != true || !mounted || !_foreground ||
          intentEpoch != _profileRequestEpoch || connected || connecting || _nativeBusy) return;
      await WireGuardTunnel.deleteProfile(profileId: profile.id);
      if (mounted) {
        _statusEpoch++;
        setState(() => connectionError = null);
        _showNotice('Профиль удалён.');
      }
    } catch (error) {
      _showNotice(_profileActionMessage(error));
    } finally {
      if (mounted) {
        _statusEpoch++;
        setState(() => _profileBusy = false);
        await _refreshProfileStatus();
      }
    }
  }

  Future<void> _loadRoutes() async {
    if (!_isAndroid || !mounted || !_foreground || _savingRoute ||
        _routeConfirmationOpen) return;
    final epoch = ++_routeEpoch;
    setState(() {
      loadingApps = true;
      _routesStale = true;
      routeError = null;
    });
    try {
      final values = await Future.wait<Object>([
        AndroidAppRoutes.installedApps().timeout(const Duration(seconds: 10)),
        AndroidAppRoutes.getBypass().timeout(const Duration(seconds: 5)),
      ], eagerError: true);
      if (mounted && _foreground && epoch == _routeEpoch && !_savingRoute) {
        setState(() {
          installed = values[0] as List<InstalledApp>;
          bypassPackages = values[1] as Set<String>;
          _routesLoaded = true;
          _routesStale = false;
          routeError = null;
        });
      }
    } catch (error) {
      if (mounted && _foreground && epoch == _routeEpoch) {
        setState(() => routeError = _routeErrorMessage(error));
      }
    } finally {
      // An old response must not stop the newer request's loading indicator.
      if (mounted && epoch == _routeEpoch) setState(() => loadingApps = false);
    }
  }

  String _routeErrorMessage(Object error, {bool saving = false}) {
    if (error is PlatformException) {
      switch (error.code) {
        case 'ROUTES_CHANGED':
          return 'Список исключений изменился. Проверьте обновлённый выбор и повторите действие.';
        case 'ROUTES_STORE_UNAVAILABLE':
          return 'Не удалось записать исключения. Перезапустите приложение перед повторной попыткой.';
        case 'VPN_ACTIVE':
          return 'Для изменения исключений отключите туннель.';
        case 'VPN_BUSY':
          return 'Дождитесь завершения операции с туннелем и повторите действие.';
        case 'VPN_STATE_UNAVAILABLE':
          return 'Не удалось уточнить состояние туннеля. Повторите проверку.';
      }
    }
    return saving
        ? 'Не удалось сохранить исключения. Повторите проверку списка.'
        : 'Не удалось прочитать приложения и исключения. Повторите проверку.';
  }

  Future<void> _refreshRoutes() async {
    await Future.wait([_loadRoutes(), _refreshProfileStatus()]);
  }

  Future<void> _saveBypass(Set<String> updated, {required Set<String> expected}) async {
    if (!_canEditRoutes) return;
    final epoch = ++_routeEpoch;
    final foregroundEpoch = _profileRequestEpoch;
    _statusEpoch++;
    setState(() { _savingRoute = true; _routesStale = true; });
    try {
      // Compare with the set the user actually saw. A second Activity must not
      // have its newer changes overwritten by this whole-set operation.
      await AndroidAppRoutes.setBypass(updated, expectedPackages: expected);
      if (mounted && _foreground && epoch == _routeEpoch &&
          foregroundEpoch == _profileRequestEpoch) {
        setState(() { bypassPackages = Set.of(updated); routeError = null; });
      }
    } catch (error) {
      if (mounted && _foreground && foregroundEpoch == _profileRequestEpoch) {
        final message = _routeErrorMessage(error, saving: true);
        setState(() => routeError = message);
        _showNotice(message);
      }
    } finally {
      if (mounted) {
        _statusEpoch++;
        setState(() => _savingRoute = false);
        // Re-read even after success: acknowledge only the authoritative native
        // set. On a failed durable write the native store stays unavailable.
        await _refreshRoutes();
      }
    }
  }

  Future<void> _setBypass(String packageName, bool value) async {
    if (!_canEditRoutes) return;
    final expected = Set<String>.of(bypassPackages);
    final updated = Set<String>.of(expected);
    if (value) { updated.add(packageName); } else { updated.remove(packageName); }
    await _saveBypass(updated, expected: expected);
  }

  Future<void> _clearBypass() async {
    if (!_canEditRoutes || bypassPackages.isEmpty) return;
    final expected = Set<String>.of(bypassPackages);
    final intentEpoch = _profileRequestEpoch;
    var confirmed = false;
    setState(() => _routeConfirmationOpen = true);
    try {
      confirmed = await showDialog<bool>(context: context,
        builder: (context) => AlertDialog(
          title: const Text('Очистить исключения?'),
          content: Text('Будут удалены все исключения: ${expected.length}. '
              'Изменение действует при следующем подключении.'),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Отмена')),
            TextButton(key: const Key('confirm_clear_route_selections'),
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Очистить')),
          ],
        )) ?? false;
    } finally {
      if (mounted) setState(() => _routeConfirmationOpen = false);
    }
    if (confirmed && mounted && _foreground && intentEpoch == _profileRequestEpoch) {
      await _saveBypass(<String>{}, expected: expected);
    } else if (mounted && _foreground && _routesStale) {
      // Resume may have skipped its refresh while this confirmation was open.
      await _refreshRoutes();
    }
  }

  String? get _routeDisabledReason {
    if (_savingRoute) return 'Сохраняем исключения…';
    if (connected || connecting || _nativeBusy) {
      return 'Для изменения исключений отключите туннель.';
    }
    if (_diagnosticsStale || !_diagnostics.isKnown || _statusRefreshing) {
      return 'Состояние туннеля уточняется. Повторите проверку, если ожидание затянулось.';
    }
    if (_profileBusy || _profileEditorOpen) return 'Завершите работу с профилем.';
    if (_routesStale && !loadingApps && routeError == null) {
      return 'Обновите список перед изменением исключений.';
    }
    return null;
  }

  Widget card(Widget child) => PushokPanel(child: child);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Pushok Flow', style: const TextStyle(fontWeight: FontWeight.w700)), actions: [IconButton(icon: const Icon(Icons.info_outline), tooltip: 'Информация', onPressed: () => showAboutDialog(context: context, applicationName: 'Pushok Flow', applicationVersion: '0.29.0'))]),
      body: PushokNeonBackdrop(child: SafeArea(child: Padding(
        padding: const EdgeInsets.all(14),
        child: [home(), routes(), servers(), assistant(), profile()][tab],
      ))),
      bottomNavigationBar: NavigationBar(
        backgroundColor: PushokFlowApp.bg,
        indicatorColor: PushokFlowApp.panel,
        selectedIndex: tab,
        onDestinationSelected: (v) {
          setState(() => tab = v);
          if (v == 1) unawaited(_refreshRoutes());
          if (v == 2) unawaited(_refreshProfileStatus());
        },
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), label: 'Главная'),
          NavigationDestination(icon: Icon(Icons.alt_route_outlined), label: 'Маршруты'),
          NavigationDestination(icon: Icon(Icons.dns_outlined), label: 'Серверы'),
          NavigationDestination(icon: Icon(Icons.auto_awesome_outlined), label: 'Pushok ИИ'),
          NavigationDestination(icon: Icon(Icons.person_outline), label: 'Профиль'),
        ],
      ),
    );
  }

  Widget home() => LayoutBuilder(builder: (context, constraints) => ListView(children: [
    const SizedBox(height: 6),
    // Маскот — оригинальное изображение, предоставленное владельцем бренда.
    Center(child: Column(children: [
      Image.asset('assets/mascot/pushok.png', height: constraints.maxHeight < 540 ? 126 : 160,
        fit: BoxFit.contain, semanticLabel: 'Фирменный рыжий котёнок Pushok'),
      const SizedBox(height: 2),
      const Text('Твой интернет. Твои правила.', textAlign: TextAlign.center,
        style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
    ])),
    const SizedBox(height: 18),
    Center(child: AnimatedContainer(
      duration: const Duration(milliseconds: 450),
      width: constraints.maxWidth < 340 ? 176 : 202,
      height: constraints.maxWidth < 340 ? 176 : 202,
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(shape: BoxShape.circle,
        gradient: LinearGradient(colors: _tunnelConfirmed
          ? [PushokPalette.mint, PushokPalette.glowCyan]
          : [PushokPalette.glowCyan, PushokPalette.electricBlue, PushokPalette.glowViolet]),
        boxShadow: [BoxShadow(color: (_tunnelConfirmed ? PushokPalette.mint : PushokPalette.glowCyan)
          .withValues(alpha: .45), blurRadius: 30, spreadRadius: 3)]),
      child: Material(color: PushokPalette.midnight, shape: const CircleBorder(), child: InkWell(
        key: const Key('pushok_connect_button'),
        customBorder: const CircleBorder(),
        onTap: connecting || _nativeBusy || _profileBusy || _profileEditorOpen ||
            _savingRoute || _routeConfirmationOpen || !_isAndroid
            ? null : () => _toggleTunnel(),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(_tunnelConfirmed ? Icons.check_circle_outline
              : connected ? Icons.info_outline : Icons.power_settings_new,
            color: _tunnelConfirmed ? PushokPalette.mint : PushokPalette.glowCyan, size: 54),
          const SizedBox(height: 10),
          Text(connecting ? (connected ? 'Отключение' : 'Подключение') : connected ? 'Отключить' : 'Подключить',
            textAlign: TextAlign.center, style: const TextStyle(color: Colors.white,
              fontWeight: FontWeight.w800, fontSize: 20)),
          if (!connected && !connecting) const Text('трафик',
            style: TextStyle(color: PushokPalette.muted, fontSize: 13)),
        ]),
      )),
    )),
    const SizedBox(height: 18),
    Center(child: PushokStatusChip(
      label: connecting ? (connected ? 'Отключение туннеля' : 'Соединение устанавливается')
          : _nativeBusy ? 'Состояние изменяется'
          : _isAndroid && (_diagnosticsStale || !_diagnostics.isKnown)
              ? 'Статус уточняется'
              : connected ? 'Туннель включён' : 'Статус: отключено',
      icon: connecting || _nativeBusy ? Icons.sync
          : _diagnosticsStale ? Icons.info_outline
          : connected ? Icons.shield_outlined : Icons.circle,
      color: connecting || _nativeBusy ? PushokPalette.glowCyan
          : _diagnosticsStale ? PushokPalette.muted
          : connected ? PushokPalette.mint : PushokPalette.orange)),
    if (connectionError != null) Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Semantics(liveRegion: true, child: Text(connectionError!,
        key: const Key('connection_error'), textAlign: TextAlign.center,
        style: const TextStyle(color: PushokPalette.orange))),
    ),
    if (_isAndroid) ...[
      const SizedBox(height: 14),
      TunnelDiagnosticsCard(
        diagnostics: _diagnostics,
        refreshing: _statusRefreshing,
        stale: _diagnosticsStale,
        onRefresh: connecting || _profileBusy || _profileEditorOpen || !_foreground
            ? null : _refreshProfileStatus,
      ),
    ],
    if (lastErrorCode != null) Padding(padding: const EdgeInsets.all(8),
      child: Text('Pushok ИИ · код диагностики: $lastErrorCode',
        style: const TextStyle(color: PushokPalette.muted))),
  ]));

  Widget routes() => AppRoutesView(
    apps: installed,
    selectedPackages: bypassPackages,
    isAndroid: _isAndroid,
    loading: loadingApps,
    saving: _savingRoute,
    loaded: _routesLoaded,
    canEdit: _canEditRoutes,
    query: _routeQuery,
    onlySelected: _onlySelectedRoutes,
    error: routeError,
    disabledReason: _isAndroid ? _routeDisabledReason : null,
    onQueryChanged: (value) => setState(() => _routeQuery = value),
    onFilterChanged: (value) => setState(() => _onlySelectedRoutes = value),
    onToggle: _setBypass,
    onRefresh: !_isAndroid || !_foreground || loadingApps || _savingRoute ||
        _routeConfirmationOpen || _profileBusy || _profileEditorOpen
            ? null : _refreshRoutes,
    onClear: _canEditRoutes && bypassPackages.isNotEmpty ? _clearBypass : null,
  );
  Widget servers() => ListView(children: [
    WireGuardProfilesCard(
      catalog: _profiles,
      // Confirmation and the protected editor block actions without pretending
      // that a catalog read is running behind the modal route.
      loading: _statusRefreshing,
      error: !_isAndroid ? 'Профили WireGuard доступны в приложении для Android.'
          : _profilesError,
      mutationsEnabled: _canManageProfiles,
      onRefresh: !_isAndroid || _statusRefreshing || _profileBusy ||
          _profileEditorOpen || !_foreground ? null : _refreshProfileStatus,
      onAdd: () => _editProfile(),
      onEdit: (profile) => _editProfile(profile: profile),
      onSelect: _selectProfile,
      onDelete: _deleteProfile,
    ),
    if (connected || connecting || _nativeBusy) const Padding(
      padding: EdgeInsets.only(top: 12),
      child: Text('Для изменения профилей отключите туннель.',
          style: TextStyle(color: PushokPalette.muted)),
    ),
  ]);
  Widget assistant() => ListView(children: [
    card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const ListTile(leading: Icon(Icons.smart_toy_outlined, color: PushokFlowApp.teal),
        title: Text('Pushok ИИ'), subtitle: Text('Локальная память результатов')),
      const Text('Оцените последнее подключение. Сохраняются только счётчики результатов; IP, сайты, конфигурации и ключи не собираются.',
        style: TextStyle(color: PushokFlowApp.secondary)),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: [
        FilledButton.icon(onPressed: _isAndroid ? () => _rateConnection(true) : null,
          icon: const Icon(Icons.thumb_up_alt_outlined), label: const Text('Помогло')),
        OutlinedButton.icon(onPressed: _isAndroid ? () => _rateConnection(false) : null,
          icon: const Icon(Icons.thumb_down_alt_outlined), label: const Text('Не помогло')),
      ]),
      const SizedBox(height: 12),
      Text('Положительных оценок: ${feedback['connection_helpful'] ?? 0}'),
      Text('Отрицательных оценок: ${feedback['connection_unhelpful'] ?? 0}'),
      const SizedBox(height: 8),
      OutlinedButton.icon(onPressed: _isAndroid ? _clearAiFeedback : null,
        icon: const Icon(Icons.delete_outline), label: const Text('Очистить память Pushok ИИ')),
      if (feedbackMessage != null) Text(feedbackMessage!, style: const TextStyle(color: PushokFlowApp.secondary)),
      const SizedBox(height: 12),
      const Text('Статистика WireGuard доступна на главной. Автоматическое обучение '
        'и проверка доступности сайтов — следующие этапы.',
        style: TextStyle(color: PushokFlowApp.secondary)),
    ])),
  ]);
  Widget profile() => ListView(children: [
    card(const ListTile(leading: Icon(Icons.person_outline), title: Text('Pushok ID'),
      subtitle: Text('Единая авторизация — в разработке'))),
    const SizedBox(height: 12),
    AppUpdatesCard(isAndroid: _isAndroid),
  ]);
}
