import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'design/pushok_theme.dart';
import 'models/app_version.dart';
import 'dart:io' show Platform, Socket, SocketException;
import 'platform/app_updates.dart';
import 'dart:async' show Timer, unawaited;
import 'platform/android_app_routes.dart';
import 'platform/route_recommendations.dart';
import 'ai/pushok_ai_memory.dart';
import 'platform/wireguard_tunnel.dart';
import 'platform/wireguard_profiles.dart';
import 'platform/profile_privacy.dart';
import 'platform/subscriptions.dart';
import 'platform/subscription_diagnostics.dart';
import 'platform/tunnel_diagnostics.dart';
import 'ui/wireguard_profile_editor.dart';
import 'ui/wireguard_profiles_card.dart';
import 'ui/subscriptions_card.dart';
import 'ui/subscription_editor.dart';
import 'ui/app_updates_card.dart';
import 'ui/account_card.dart';
import 'ui/telegram_proxy_action.dart';
import 'ui/browser_sites_page.dart';
import 'ui/flow_connection_vitals.dart';
import 'ui/flow_settings_menu.dart';
import 'ui/device_traffic_page.dart';
import 'ui/app_information_sheet.dart';
import 'ui/app_routes_view.dart';
import 'ui/route_recommendations_card.dart';
import 'ui/animated_pushok_mascot.dart';

void main() => runApp(const PushokFlowApp());

class PushokFlowApp extends StatelessWidget {
  const PushokFlowApp({super.key, this.isAndroid, this.animationsEnabled = true});
  // Tests exercise the real Android channel flow without requiring an emulator.
  final bool? isAndroid;
  final bool animationsEnabled;
  static const bg = PushokPalette.background;
  static const panel = PushokPalette.surface;
  static const teal = PushokPalette.teal;
  static const secondary = PushokPalette.muted;
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Pushok Flow', debugShowCheckedModeBanner: false,
        theme: buildPushokTheme(),
        builder: (context, child) {
          final media = MediaQuery.of(context);
          return MediaQuery(
            data: media.copyWith(
              disableAnimations: media.disableAnimations || !animationsEnabled),
            child: child ?? const SizedBox.shrink(),
          );
        },
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
  // Only Home is top level; the former tabs are grouped under Settings.
  int tab = 0;
  bool _settingsOpen = false;
  bool _settingsLanding = false;
  List<InstalledApp> installed = [];
  Set<String> bypassPackages = {};
  Set<String> unavailableBypassPackages = {};
  bool loadingApps = false;
  String? routeError;
  String? connectionError;
  WireGuardProfiles? _profiles;
  String? _profilesError;
  late final FlowSubscriptions _subscriptionBridge;
  final _homeAccountKey = GlobalKey<PushokAccountCardState>();
  bool _homeAccountAuthorized = false;
  SubscriptionStatus? _subscriptions;
  String? _subscriptionsError;
  SubscriptionDiagnostic? _subscriptionsDiagnostic;
  bool _subscriptionActionFailure = false;
  final _subscriptionDiagnostics = <String, SubscriptionDiagnostic>{};
  bool _subscriptionsLoading = false;
  bool _subscriptionsBusy = false;
  bool _subscriptionsSavingAutoUpdate = false;
  int? _pendingSubscriptionReading;
  int _pendingSubscriptionReadSequence = 0;
  int _pendingSubscriptionLinkSequence = 0;
  int? _pendingSubscriptionLinkIntentEpoch;
  bool _openingPushok = false;
  int _subscriptionEpoch = 0;
  Timer? _subscriptionPoll;
  SubscriptionDraft? _pendingSubscriptionLink;
  String? lastErrorCode;
  TunnelDiagnostics _diagnostics = const TunnelDiagnostics.unavailable();
  bool _diagnosticsStale = true;
  final _informationRevision = ValueNotifier<int>(0);
  bool _informationOpen = false;
  Timer? _healthPoll;
  // Ownership drives Stop/edit guards; actual local UP comes only from diagnostics.
  bool _ownsTunnel = false;
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
  bool _onlyUnavailableRoutes = false;
  bool _onlyRecommendedRoutes = false;
  late final RouteRecommendations _recommendationBridge;
  RecommendationStatus _recommendations = const RecommendationStatus.empty();
  bool _recommendationsLoading = false;
  bool _recommendationsRefreshing = false;
  bool _recommendationsSavingAutoUpdate = false;
  int _recommendationEpoch = 0;
  Timer? _recommendationPoll;
  int _statusEpoch = 0;
  int _profileRequestEpoch = 0;
  int _tunnelIntentEpoch = 0;
  bool _foreground = true;
  Map<String, int> feedback = {};
  String? feedbackMessage;
  bool get _isAndroid => widget.isAndroid ?? Platform.isAndroid;
  bool get _nativeBusy => _diagnostics.isKnown &&
      _diagnostics.transitioning && !_diagnosticsStale;
  TunnelRecovery get _recovery => _diagnostics.isKnown && !_diagnosticsStale
      ? _diagnostics.recovery : TunnelRecovery.none;
  bool get _recovering => _recovery != TunnelRecovery.none;
  bool get _tunnelConfirmed => _ownsTunnel && _diagnostics.connected && _diagnostics.isKnown &&
      !_diagnosticsStale && !_nativeBusy && !connecting;
  // A new connection requires a current DOWN observation. On startup/resume,
  // the last screen state cannot authorize reconfiguring an existing tunnel.
  // Keep Disconnect available for a last-known UP even when status reads fail.
  bool get _canToggleTunnel => _isAndroid && _foreground && !_informationOpen &&
      !connecting && (!_nativeBusy || (_ownsTunnel && _diagnostics.managedRecovery == 'switching')) &&
      !_profileBusy && !_profileEditorOpen &&
      !_savingRoute && !_routeConfirmationOpen &&
      (_ownsTunnel || (!_nativeBusy && !_statusRefreshing && _diagnostics.isKnown &&
          !_diagnosticsStale && !_diagnostics.ownsTunnel));
  // An isolated service can survive a restart of this UI process. Unknown
  // startup state must forbid Connect but still allow an explicit recovery Stop.
  bool get _canRecoverTunnel => _isAndroid && _foreground && _informationOpen &&
      !connecting && !_nativeBusy && !_profileBusy && !_profileEditorOpen &&
      !_savingRoute && !_routeConfirmationOpen && !_statusRefreshing &&
      (!_diagnostics.isKnown || _diagnosticsStale || _recovering);
  bool get _canManageProfiles => _isAndroid && _foreground &&
      !_informationOpen &&
      !_ownsTunnel && !connecting && !_nativeBusy && !_profileBusy &&
      !_savingRoute && !_routeConfirmationOpen &&
      !_profileEditorOpen && !_statusRefreshing && _profiles != null &&
      _profilesError == null && _diagnostics.isKnown && !_diagnosticsStale;
  bool get _canEditRoutes => _isAndroid && _foreground && _routesLoaded &&
      !_routesStale && !loadingApps && !_savingRoute && !_routeConfirmationOpen &&
      routeError == null && !_ownsTunnel && !connecting && !_nativeBusy &&
      !_profileBusy && !_profileEditorOpen && !_statusRefreshing &&
      _diagnostics.isKnown && !_diagnosticsStale;

  void _showNotice(String message, {SnackBarAction? action}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), action: action, showCloseIcon: true));
  }

  void _openRoutesForRepair({required bool onlyUnavailable}) {
    if (!mounted || !_foreground || _informationOpen || _profileEditorOpen ||
        _routeConfirmationOpen) return;
    setState(() {
      _settingsOpen = true;
      _settingsLanding = false;
      tab = 1;
      _routeQuery = '';
      _onlySelectedRoutes = !onlyUnavailable;
      _onlyUnavailableRoutes = onlyUnavailable;
      _onlyRecommendedRoutes = false;
    });
    unawaited(_refreshRoutes());
    unawaited(_readRecommendations(checkAutomatically: true));
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
        case 'UPDATE_INSTALLING':
          return 'Android завершает обновление Pushok Flow. Подключитесь после установки.';
        case 'VPN_STATE_UNAVAILABLE':
          return 'Не удалось уточнить состояние туннеля. Обновите диагностику и повторите действие.';
        case 'INVALID_CONFIG':
          return 'Профиль подключения некорректен. Откройте его настройки и проверьте данные.';
        case 'INVALID_VLESS_CONFIG':
        case 'UNSUPPORTED_PROFILE':
        case 'UNSUPPORTED_TRANSPORT':
        case 'UNSUPPORTED_SECURITY':
        case 'UNSUPPORTED_PROFILE_OPTION':
          return 'Добавьте профиль .conf.';
        case 'PROFILE_LOAD_FAILED':
          return 'Не удалось открыть сохранённый профиль. Откройте «Серверы» и повторите проверку.';
        case 'PROFILE_READ_TIMEOUT':
          return 'Не удалось вовремя прочитать профили. Повторите подключение.';
        case 'PROFILE_CHANGED':
        case 'PROFILE_NOT_FOUND':
          return 'Выбранный профиль изменился. Проверьте выбор в «Серверах» и подключитесь снова.';
        case 'PROFILE_STORE_UNAVAILABLE':
          return 'Не удалось записать профили. Перезапустите приложение перед повторной попыткой.';
        case 'SUBSCRIPTION_EXPIRED':
        case 'SUBSCRIPTION_REVOKED':
        case 'SUBSCRIPTION_AUTH_REQUIRED':
        case 'SUBSCRIPTION_NETWORK_ERROR':
        case 'SUBSCRIPTION_TLS_ERROR':
        case 'SUBSCRIPTION_INVALID':
        case 'SUBSCRIPTION_BUSY':
        case 'SUBSCRIPTION_STORE_FAILED':
          return subscriptionErrorMessage(error);
        case 'ROUTES_STORE_UNAVAILABLE':
          return 'Не удалось записать исключения. Перезапустите приложение перед подключением.';
        case 'ROUTES_LOAD_FAILED':
          return 'Не удалось прочитать исключения. Проверьте раздел «Маршруты» перед подключением.';
        case 'ROUTES_APPS_UNAVAILABLE':
          return 'Android не подтвердил доступность некоторых приложений. Откройте «Маршруты» и проверьте исключения.';
        case 'ROUTES_APPS_CHECK_FAILED':
          return 'Не удалось проверить приложения в исключениях. Откройте «Маршруты» и повторите проверку.';
        case 'WG_DISCONNECT_FAILED':
        case 'XRAY_DISCONNECT_FAILED':
          return 'Не удалось отключить VPN. Повторите попытку.';
      }
    }
    return disconnecting
        ? 'Не удалось отключить VPN. Повторите попытку.'
        : 'Не удалось установить туннель. Проверьте профиль и доступность сервера.';
  }

  Future<T> _withProfileReadDeadline<T>(Future<T> read) => read.timeout(
    const Duration(seconds: 5),
    onTimeout: () => throw PlatformException(code: 'PROFILE_READ_TIMEOUT'),
  );

  Future<void> _toggleTunnel({String? profile}) async {
    if (!_canToggleTunnel) return;
    final tunnelIntent = ++_tunnelIntentEpoch;
    final disconnecting = _ownsTunnel;
    final requestEpoch = _profileRequestEpoch;
    var needsProfile = false;
    var nativeOperationStarted = false;
    _statusEpoch++;
    setState(() {
      connecting = true;
      connectionError = null;
      _diagnosticsStale = true;
    });
    _notifyInformation();
    try {
      if (disconnecting) {
        nativeOperationStarted = true;
        await WireGuardTunnel.disconnect();
        if (mounted) setState(() {
          _ownsTunnel = false;
          _diagnostics = const TunnelDiagnostics(isKnown: true, connected: false,
              statistics: TunnelStatistics.inactive());
        });
      } else {
        // Managed keys stay native; an explicit manual-profile Connect loads its raw config.
        // Native code verifies the selected ID and content again under its operation lease.
        final catalog = await _withProfileReadDeadline(WireGuardTunnel.listProfiles());
        if (!mounted || !_foreground || requestEpoch != _profileRequestEpoch) return;
        final active = catalog.activeProfile;
        if (active == null) {
          needsProfile = true;
          setState(() { _profiles = catalog; _profilesError = null; });
        } else {
          final config = active.isManaged ? null : profile ?? await _withProfileReadDeadline(
            WireGuardTunnel.loadProfile(profileId: active.id));
          if (!mounted || !_foreground || requestEpoch != _profileRequestEpoch) return;
          if (!active.isManaged && (config == null || config.trim().isEmpty)) {
            throw PlatformException(code: 'PROFILE_NOT_FOUND');
          }
          // Native connection and Android consent own their completion. Only the
          // preceding read-only preparation has a Dart deadline.
          nativeOperationStarted = true;
          final ok = active.isManaged ? await WireGuardTunnel.connectManaged(active.id)
              : await WireGuardTunnel.connect(config!, expectedProfileId: active.id);
          if (!mounted) return;
          setState(() {
            _ownsTunnel = ok;
            // The connect acknowledgement is not a protocol/traffic sample.
            // The following status read supplies the actual engine metadata.
            _diagnostics = TunnelDiagnostics(isKnown: false, connected: false, ownsTunnel: ok,
                protocol: TunnelProtocol.unknown);
          });
          if (!ok) {
            final message = _connectionMessage(StateError('not connected'));
            setState(() => connectionError = message);
            _showNotice(message);
          }
        }
      }
    } catch (error) {
      // A failed preparation from before app switching is no longer a current
      // intent. Android consent may legitimately pause a native operation.
      if (mounted && (nativeOperationStarted ||
          (_foreground && requestEpoch == _profileRequestEpoch))) {
        final shopLoginNeeded = !disconnecting && _foreground &&
            !_homeAccountAuthorized &&
            error is PlatformException && error.code == 'SHOP_LOGIN_REQUIRED';
        if (shopLoginNeeded) {
          // A retained Shop profile needs the original verified owner to
          // reconnect after logout. Start native login only after the actual
          // Shop ownership gate rejects it; other managed profiles are intact.
          _homeAccountKey.currentState?.requestConnection();
        } else {
          final message = _connectionMessage(error, disconnecting: disconnecting);
          setState(() => connectionError = message);
          final routeFailureCode = !disconnecting && error is PlatformException ? error.code : null;
          final routeFailure = const {'ROUTES_APPS_UNAVAILABLE', 'ROUTES_APPS_CHECK_FAILED'}
              .contains(routeFailureCode);
          _showNotice(message, action: routeFailure ? SnackBarAction(
            key: const Key('open_routes_after_connection_error'),
            label: 'Маршруты',
            onPressed: () => _openRoutesForRepair(
              onlyUnavailable: routeFailureCode == 'ROUTES_APPS_UNAVAILABLE'),
          ) : null);
          if (routeFailure) unawaited(_loadRoutes());
        }
      }
    } finally {
      if (mounted) {
        setState(() => connecting = false);
        _notifyInformation();
        await _refreshProfileStatus();
      }
    }
    if (needsProfile && mounted && _foreground && requestEpoch == _profileRequestEpoch) {
      await _editProfile(connectAfterSave: true, tunnelIntent: tunnelIntent);
    }
  }

  /// Existing profiles (manual or subscribed) still use the established
  /// connection path and its server-side entitlement checks. Only an empty
  /// catalog starts the verified account → Shop → import → connect sequence.
  void _handlePowerTap() {
    _linkEpoch++;
    _lastPing = null;
    _pingMs = null;
    if (!_canToggleTunnel) return;
    if (_ownsTunnel || _profiles?.activeProfile != null) {
      unawaited(_toggleTunnel());
    } else {
      _homeAccountKey.currentState?.requestConnection(allowGuest: true);
    }
  }

  Future<void> _connectAfterShopReady() async {
    if (!mounted || !_foreground || _ownsTunnel) return;
    await _readSubscriptions();
    // A subscription import is committed natively before this callback. Read
    // the resulting catalog and tunnel status before asking for Android consent.
    for (var attempt = 0; attempt < 3 && mounted && _foreground; attempt++) {
      await _refreshProfileStatus();
      if (_canToggleTunnel && _profiles?.activeProfile != null) break;
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    if (!mounted || !_foreground || _ownsTunnel) return;
    if (_canToggleTunnel && _profiles?.activeProfile != null) {
      await _toggleTunnel();
    } else {
      _showNotice('Профиль получен. Нажмите «Подключить» ещё раз, '
          'когда обновится состояние соединения.');
    }
  }

  Future<void> _disconnectForRecovery() async {
    if (!_canRecoverTunnel) return;
    _statusEpoch++;
    _tunnelIntentEpoch++;
    setState(() {
      connecting = true;
      connectionError = null;
      _diagnosticsStale = true;
    });
    _notifyInformation();
    try {
      // The native stop path attempts both engines without requiring a readable
      // preliminary status. This action never loads a profile or starts a tunnel.
      await WireGuardTunnel.disconnect();
      if (mounted) setState(() {
        _ownsTunnel = false;
        _diagnostics = const TunnelDiagnostics(isKnown: true, connected: false,
            protocol: TunnelProtocol.unknown, statistics: TunnelStatistics.inactive());
      });
    } catch (error) {
      if (mounted) {
        final message = _connectionMessage(error, disconnecting: true);
        setState(() => connectionError = message);
        _showNotice(message);
      }
    } finally {
      if (mounted) {
        setState(() => connecting = false);
        _notifyInformation();
        await _refreshProfileStatus();
      }
    }
  }

  @override
  void dispose() {
    _healthPoll?.cancel();
    _recommendationEpoch++;
    _recommendationPoll?.cancel();
    _informationRevision.dispose();
    _subscriptionEpoch++;
    _subscriptionPoll?.cancel();
    _subscriptionBridge.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _recommendationBridge = RouteRecommendations(isAndroid: _isAndroid);
    _subscriptionBridge = FlowSubscriptions(isAndroid: _isAndroid);
    _subscriptionBridge.listenForPendingLinks(() {
      unawaited(_takePendingSubscriptionLink());
    });
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    _loadRoutes();
    unawaited(_refreshProfileStatus().then((_) =>
      _readSubscriptions(checkAutomatically: true)));
    _loadAiFeedback();
    _startHealthPolling();
  }

  bool _updateOffered = false;
  int? _pingMs;
  bool _pingPending = false;
  DateTime? _lastPing;
  int _linkEpoch = 0;

  Future<void> _homeUpdateStatus() async {
    if (!_isAndroid) return;
    try {
      final status = await AppUpdates(isAndroid: true).updateStatus();
      if (mounted && _foreground && _updateOffered != status.hasNewerVersion) {
        setState(() => _updateOffered = status.hasNewerVersion);
      }
    } catch (_) { /* Offline: retain the last confirmed update state. */ }
  }

  Future<void> _measurePing() async {
    if (!Platform.isAndroid || !_foreground || !_tunnelConfirmed || _pingPending) return;
    final now = DateTime.now();
    if (_lastPing != null && now.difference(_lastPing!) < const Duration(seconds: 8)) return;
    _lastPing = now;
    final epoch = _linkEpoch;
    _pingPending = true;
    Socket? socket;
    int? elapsed;
    try {
      final clock = Stopwatch()..start();
      socket = await Socket.connect('pushok.shop', 443, timeout: const Duration(seconds: 3));
      elapsed = clock.elapsedMilliseconds;
    } on SocketException {
      elapsed = null;
    } finally {
      socket?.destroy();
      _pingPending = false;
      if (mounted && _foreground && _tunnelConfirmed && epoch == _linkEpoch && _pingMs != elapsed) {
        setState(() => _pingMs = elapsed);
      }
    }
  }

  void _startHealthPolling() {
    _healthPoll?.cancel();
    unawaited(_homeUpdateStatus());
    if (!_isAndroid || !_foreground) return;
    _healthPoll = Timer.periodic(const Duration(seconds: 10), (_) {
      unawaited(_homeUpdateStatus());
      if ((_ownsTunnel || _nativeBusy || !_diagnostics.isKnown) &&
          !connecting && mounted && _foreground) _refreshProfileStatus();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _linkEpoch++;
    _lastPing = null;
    _pingMs = null;
    _foreground = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.resumed) {
      _startHealthPolling();
      unawaited(_refreshProfileStatus().then((_) =>
        _readSubscriptions(checkAutomatically: true)));
      _loadRoutes();
      if (tab == 1) unawaited(_readRecommendations(checkAutomatically: true));
    } else {
      // A request made before losing focus must not open the editor later,
      // even if the user returns before a native response arrives.
      _profileRequestEpoch++;
      // A sample requested before app switching is no longer a fresh reading.
      _statusEpoch++;
      _routeEpoch++;
      _recommendationEpoch++;
      _subscriptionEpoch++;
      _pendingSubscriptionReading = null;
      _subscriptionPoll?.cancel();
      _recommendationPoll?.cancel();
      setState(() {
        _diagnosticsStale = true;
        _routesStale = true;
        loadingApps = false;
        _recommendationsLoading = false;
        _recommendationsRefreshing = false;
        _recommendationsSavingAutoUpdate = false;
        _subscriptionsLoading = false;
      });
      _healthPoll?.cancel();
    }
    _notifyInformation();
  }

  Future<void> _loadAiFeedback() async {
    if (!_isAndroid) return;
    try {
      final data = await PushokAiMemory.summary();
      if (mounted) setState(() => feedback = data);
    } catch (_) { if (mounted) setState(() => feedbackMessage = 'Память недоступна на этом устройстве.'); }
  }

  void _setSubscriptionFailure(Object error,
      SubscriptionDiagnosticOperation operation) {
    final diagnostic = SubscriptionDiagnostic.fromError(error,
      operation: operation, source: SubscriptionDiagnosticSource.savedSubscription);
    _subscriptionsDiagnostic = diagnostic;
    _subscriptionActionFailure = operation != SubscriptionDiagnosticOperation.readStatus;
    _subscriptionsError = diagnostic.message;
  }

  bool get _canCopySubscriptionDiagnostic => mounted && _foreground &&
      !_subscriptionsBusy && !_subscriptionsLoading && !_subscriptionsSavingAutoUpdate &&
      !(_subscriptions?.busy ?? false);

  // Native status contains only the last per-provider code, not the operation
  // that produced it. Keep known context while that same failure remains, and
  // use a generic refresh label for restored or otherwise unobserved failures.
  void _acceptSubscriptions(SubscriptionStatus status, {
    SubscriptionDiagnosticOperation? operation,
    String? affectedSubscriptionId,
    bool preserveActionFailure = false,
  }) {
    final previousErrors = _subscriptions?.refreshErrors ?? const <String, String>{};
    _subscriptionDiagnostics.removeWhere((id, _) => !status.refreshErrors.containsKey(id));
    for (final entry in status.refreshErrors.entries) {
      final previous = _subscriptionDiagnostics[entry.key];
      final explicitRefresh = operation == SubscriptionDiagnosticOperation.manualRefresh &&
          affectedSubscriptionId == entry.key &&
          ((_subscriptionsDiagnostic?.operation == SubscriptionDiagnosticOperation.manualRefresh &&
            _subscriptionsDiagnostic?.code == entry.value) || previousErrors[entry.key] != entry.value);
      final newAutomaticFailure = operation == SubscriptionDiagnosticOperation.automaticRefresh &&
          previousErrors[entry.key] != entry.value;
      if (explicitRefresh || newAutomaticFailure || previous?.code != entry.value) {
        _subscriptionDiagnostics[entry.key] = SubscriptionDiagnostic.fromCode(entry.value,
          operation: explicitRefresh || newAutomaticFailure
              ? operation! : SubscriptionDiagnosticOperation.refreshServers,
          source: SubscriptionDiagnosticSource.savedSubscription);
      }
    }
    _subscriptions = status;
    if (preserveActionFailure && _subscriptionActionFailure && _subscriptionsDiagnostic != null) {
      // A state reread is not a new action outcome. A stale native summary must
      // not replace the exception that the user just observed from this action.
      _subscriptionsError = _subscriptionsDiagnostic!.message;
    } else if (status.errorCode != null) {
      final diagnostic = SubscriptionDiagnostic.fromCode(status.errorCode,
        operation: SubscriptionDiagnosticOperation.readStatus,
        source: SubscriptionDiagnosticSource.savedSubscription);
      if (_subscriptionsDiagnostic?.code != diagnostic.code) {
        _subscriptionsDiagnostic = diagnostic;
        _subscriptionActionFailure = false;
      }
      _subscriptionsError = _subscriptionsDiagnostic!.message;
    } else if (!preserveActionFailure) {
      _subscriptionsError = null;
      _subscriptionsDiagnostic = null;
      _subscriptionActionFailure = false;
    }
  }

  Future<void> _readSubscriptions({bool checkAutomatically = false,
      SubscriptionDiagnosticOperation? diagnosticOperation,
      String? affectedSubscriptionId, bool preserveActionFailure = false}) async {
    if (!_isAndroid || !mounted || !_foreground || _subscriptionsLoading ||
        _subscriptionsBusy || _subscriptionsSavingAutoUpdate) return;
    final epoch = ++_subscriptionEpoch;
    _subscriptionPoll?.cancel();
    var received = false;
    setState(() => _subscriptionsLoading = true);
    try {
      final status = await _subscriptionBridge.status();
      if (!mounted || !_foreground || epoch != _subscriptionEpoch) return;
      received = true;
      setState(() {
        _acceptSubscriptions(status, operation: diagnosticOperation,
          affectedSubscriptionId: affectedSubscriptionId,
          preserveActionFailure: preserveActionFailure);
      });
    } catch (error) {
      if (mounted && _foreground && epoch == _subscriptionEpoch) {
        setState(() => _setSubscriptionFailure(error, SubscriptionDiagnosticOperation.readStatus));
      }
    } finally {
      if (mounted && epoch == _subscriptionEpoch) {
        setState(() => _subscriptionsLoading = false);
      }
    }
    if (!mounted || !_foreground || epoch != _subscriptionEpoch) return;
    if (_subscriptions?.busy ?? false) {
      _subscriptionPoll = Timer(const Duration(seconds: 1), () {
        if (mounted && _foreground) unawaited(_readSubscriptions(
          preserveActionFailure: _subscriptionActionFailure));
      });
    }
    await _takePendingSubscriptionLink();
    if (!mounted || !_foreground || epoch != _subscriptionEpoch) return;
    if (checkAutomatically && _pendingSubscriptionLink == null &&
        received && (_subscriptions?.automaticUpdatesEnabled ?? false) &&
        !_subscriptions!.busy && _subscriptions!.subscriptions.isNotEmpty && _canManageProfiles) {
      await _changeSubscriptions(_subscriptionBridge.refreshDue, automatic: true);
    }
  }

  Future<void> _changeSubscriptions(Future<SubscriptionStatus> Function() action,
      {bool automatic = false, String? subscriptionId,
      SubscriptionDiagnosticOperation operation = SubscriptionDiagnosticOperation.manualRefresh}) async {
    if (!_canManageProfiles || _subscriptionsBusy || _subscriptionsSavingAutoUpdate ||
        (_subscriptions?.busy ?? false)) return;
    final epoch = ++_subscriptionEpoch;
    final diagnosticOperation = automatic
        ? SubscriptionDiagnosticOperation.automaticRefresh : operation;
    _subscriptionPoll?.cancel();
    _statusEpoch++;
    setState(() {
      _subscriptionsLoading = false;
      _subscriptionsBusy = true;
      _subscriptionsError = null;
      _subscriptionsDiagnostic = null;
      _subscriptionActionFailure = false;
      _profileBusy = true;
    });
    try {
      final status = await action();
      if (mounted && _foreground && epoch == _subscriptionEpoch) setState(() {
        _acceptSubscriptions(status, operation: diagnosticOperation,
          affectedSubscriptionId: subscriptionId);
      });
      if (!automatic && status.errorCode == null && status.refreshErrors.isEmpty &&
          mounted && _foreground && epoch == _subscriptionEpoch) {
        FlowSubscription? changed;
        for (final subscription in status.subscriptions) {
          if (subscription.id == subscriptionId) changed = subscription;
        }
        _showNotice(operation == SubscriptionDiagnosticOperation.deleteSubscription
            ? 'Подписка удалена с устройства.'
            : switch (changed?.effectiveState(DateTime.now())) {
                SubscriptionAccessState.expired =>
                  'Срок подписки истёк. После продления обновите её в Flow.',
                SubscriptionAccessState.revoked =>
                  'Провайдер отозвал доступ. Обратитесь к нему для восстановления подписки.',
                _ => 'Список серверов обновлён.',
              });
      }
    } catch (error) {
      if (mounted && _foreground && epoch == _subscriptionEpoch) {
        setState(() => _setSubscriptionFailure(error, diagnosticOperation));
      }
    } finally {
      if (mounted) {
        _statusEpoch++;
        setState(() { _subscriptionsBusy = false; _profileBusy = false; });
        await _refreshProfileStatus();
        final sameOperation = mounted && _foreground && epoch == _subscriptionEpoch;
        await _readSubscriptions(
          diagnosticOperation: sameOperation ? diagnosticOperation : null,
          affectedSubscriptionId: sameOperation ? subscriptionId : null,
          preserveActionFailure: _subscriptionActionFailure);
      }
    }
  }

  Future<void> _setSubscriptionAutomaticUpdates(bool enabled) async {
    if (!_isAndroid || !mounted || !_foreground || _subscriptionsSavingAutoUpdate ||
        _subscriptions == null || (enabled && (_subscriptionsBusy ||
            _subscriptionsLoading || _subscriptions!.busy))) return;
    // OFF can cancel a native automatic download. Saving this preference must
    // neither wait for that download nor release its profile-mutation guard.
    final epoch = ++_subscriptionEpoch;
    _subscriptionPoll?.cancel();
    setState(() {
      _subscriptionsLoading = false;
      _subscriptionsSavingAutoUpdate = true;
      _subscriptionsError = null;
      _subscriptionsDiagnostic = null;
      _subscriptionActionFailure = false;
    });
    try {
      final status = await _subscriptionBridge.setAutomaticUpdates(enabled);
      if (mounted && _foreground && epoch == _subscriptionEpoch) setState(() {
        _acceptSubscriptions(status,
          operation: SubscriptionDiagnosticOperation.setAutomaticUpdates);
      });
    } catch (error) {
      if (mounted && _foreground && epoch == _subscriptionEpoch) {
        setState(() => _setSubscriptionFailure(error,
          SubscriptionDiagnosticOperation.setAutomaticUpdates));
      }
    } finally {
      if (mounted) {
        setState(() => _subscriptionsSavingAutoUpdate = false);
        if (epoch != _subscriptionEpoch || (_subscriptions?.busy ?? false)) {
          await _readSubscriptions(preserveActionFailure: _subscriptionActionFailure);
        }
      }
    }
  }

  Future<void> _takePendingSubscriptionLink() async {
    if (!_isAndroid || !mounted || !_foreground || _pendingSubscriptionReading != null) return;
    final request = ++_pendingSubscriptionReadSequence;
    final intentEpoch = _profileRequestEpoch;
    _pendingSubscriptionReading = request;
    bool current() => mounted && _foreground && intentEpoch == _profileRequestEpoch &&
        request == _pendingSubscriptionReadSequence;
    try {
      final draft = await _subscriptionBridge.takePendingLink();
      if (!mounted) return;
      if (draft != null && request > _pendingSubscriptionLinkSequence) setState(() {
        // Native already consumed this link. Keep a late reply as a masked offer,
        // but never navigate from an old intent or replace a newer received link.
        _pendingSubscriptionLinkSequence = request;
        _pendingSubscriptionLink = draft;
        _pendingSubscriptionLinkIntentEpoch = current() ? intentEpoch : null;
        if (current()) { tab = 2; _settingsOpen = true; _settingsLanding = false; }
      });
    } catch (_) {
      // A broken external link cannot reveal native message/details or replace
      // an existing saved subscription. A later explicit link can be retried.
    } finally {
      if (_pendingSubscriptionReading == request) _pendingSubscriptionReading = null;
    }
    if (current() && _pendingSubscriptionLinkIntentEpoch == intentEpoch &&
        _pendingSubscriptionLink != null &&
        _subscriptions != null && !_subscriptions!.busy &&
        _canManageProfiles && !_subscriptionsBusy) {
      await _addSubscription(draft: _pendingSubscriptionLink);
    }
  }

  Future<void> _addSubscription({SubscriptionDraft? draft}) async {
    if (!_canManageProfiles || _subscriptionsBusy || _subscriptions == null ||
        _subscriptions!.busy) return;
    if (_subscriptions!.subscriptions.length >= SubscriptionStatus.maxSubscriptions) {
      _showNotice('Можно добавить до пяти подписок. Удалите ненужную.');
      return;
    }
    final intentEpoch = _profileRequestEpoch;
    _statusEpoch++;
    setState(() => _profileBusy = true);
    ProfilePrivacy? protection;
    bool? saved;
    var profileSaved = false;
    FlowSubscription? addedSubscription;
    try {
      try {
        protection = await ProfilePrivacy.acquire();
      } catch (_) {
        if (mounted && _foreground) {
          _showNotice('Не удалось защитить экран подписки. Перезапустите приложение.');
        }
        return;
      }
      if (!mounted || !_foreground || intentEpoch != _profileRequestEpoch) return;
      setState(() {
        _profileBusy = false;
        _profileEditorOpen = true;
        if (draft != null && identical(draft, _pendingSubscriptionLink)) {
          _pendingSubscriptionLink = null;
        }
      });
      final navigator = Navigator.of(context);
      final localizations = MaterialLocalizations.of(context);
      final route = ModalBottomSheetRoute<bool>(
        capturedThemes: InheritedTheme.capture(from: context, to: navigator.context),
        settings: const RouteSettings(name: 'flow-subscription'),
        barrierLabel: localizations.scrimLabel,
        barrierOnTapHint: localizations.scrimOnTapHint(localizations.bottomSheetLabel),
        modalBarrierColor: Theme.of(context).bottomSheetTheme.modalBarrierColor,
        isScrollControlled: true, useSafeArea: true,
        isDismissible: false, enableDrag: false,
        backgroundColor: PushokPalette.midnight,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          side: BorderSide(color: PushokPalette.glowCyan)),
        builder: (context) => SubscriptionEditor(draft: draft,
          initialSource: draft == null ? SubscriptionDiagnosticSource.manualInput
              : SubscriptionDiagnosticSource.externalLink,
          onScanQr: WireGuardTunnel.scanProfileQr,
          onImportQrImage: WireGuardTunnel.importProfileQrImage,
          onCancelImport: WireGuardTunnel.cancelProfileImport,
          profileEditorBuilder: (config, onClose, onCompleted) => WireGuardProfileEditor(
            key: const Key('subscription_profile_editor'),
            initialConfig: config,
            initialName: (_profiles?.profiles.isEmpty ?? true)
                ? 'Мой профиль' : 'Профиль ${_profiles!.profiles.length + 1}',
            onImport: WireGuardTunnel.importProfile,
            onScanQr: WireGuardTunnel.scanProfileQr,
            onImportQrImage: WireGuardTunnel.importProfileQrImage,
            onCancelImport: WireGuardTunnel.cancelProfileImport,
            onClose: onClose,
            onCompleted: () { profileSaved = true; onCompleted(); },
            onSave: _saveProfileFromSubscriptionDraft,
          ),
          onSave: (url, name) async {
            addedSubscription = await _saveSubscriptionDraft(url, name);
          }),
      );
      unawaited(navigator.push<bool>(route));
      saved = await route.completed;
      await WidgetsBinding.instance.endOfFrame;
    } finally {
      if (protection != null) {
        try { await protection.release(); }
        catch (_) {
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
    if (saved == true && mounted && _foreground) {
      setState(() { tab = 2; _settingsOpen = true; _settingsLanding = false; });
      _showNotice(profileSaved
          ? 'Профиль добавлен. Выберите сервер и подключитесь на главной.'
          : _subscriptionSavedNotice(addedSubscription));
    }
  }

  Future<void> _saveProfileFromSubscriptionDraft(String config, String name) async {
    if (!mounted || !_foreground || !_profileEditorOpen) {
      throw PlatformException(code: 'PROFILE_SAVE_INTERRUPTED');
    }
    if (_ownsTunnel || connecting || _nativeBusy) {
      throw PlatformException(code: 'VPN_ACTIVE');
    }
    // A handoff always creates a new manual profile. Native validation and its
    // atomic catalog limit still apply; existing selection is left untouched.
    await WireGuardTunnel.saveProfile(config, name: name, createNew: true);
    if (mounted) {
      _statusEpoch++;
      setState(() => connectionError = null);
    }
  }

  String _subscriptionSavedNotice(FlowSubscription? subscription) {
    return switch (subscription?.effectiveState(DateTime.now())) {
      SubscriptionAccessState.expired =>
        'Подписка добавлена, но её срок истёк. После продления обновите её в Flow.',
      SubscriptionAccessState.revoked =>
        'Подписка добавлена, но доступ отозван. Обратитесь к провайдеру.',
      SubscriptionAccessState.active =>
        'Подписка добавлена. Выберите сервер и подключитесь на главной.',
      null => 'Подписка добавлена. Проверьте её состояние в списке подписок.',
    };
  }

  Future<FlowSubscription?> _saveSubscriptionDraft(String url, String name) async {
    if (!mounted || !_foreground || _ownsTunnel || connecting || _nativeBusy) {
      throw PlatformException(code: 'VPN_ACTIVE');
    }
    // A slow read from before confirmation must not overwrite the imported list.
    _subscriptionEpoch++;
    _subscriptionPoll?.cancel();
    final previousIds = _subscriptions?.subscriptions.map((item) => item.id).toSet();
    setState(() { _subscriptionsLoading = false; _subscriptionsBusy = true; });
    try {
      final status = await _subscriptionBridge.importSubscription(url, name);
      if (mounted) setState(() {
        _acceptSubscriptions(status,
          operation: SubscriptionDiagnosticOperation.addSubscription);
      });
      // The profile editor also works before subscription status is known.
      // Do not attribute another existing subscription's access state to this import.
      if (previousIds == null) return null;
      final added = status.subscriptions.where((item) => !previousIds.contains(item.id)).toList();
      return added.length == 1 ? added.single : null;
    } finally {
      if (mounted) setState(() => _subscriptionsBusy = false);
    }
  }

  Future<void> _deleteSubscription(FlowSubscription subscription) async {
    if (!_canManageProfiles || _subscriptionsBusy || (_subscriptions?.busy ?? false)) return;
    final intentEpoch = _profileRequestEpoch;
    setState(() => _profileBusy = true);
    bool? confirmed;
    try {
      confirmed = await showDialog<bool>(context: context,
        builder: (context) => AlertDialog(
          title: const Text('Удалить подписку из Flow?'),
          content: Text('«${subscription.name}» и её серверы будут удалены с этого устройства. '
            'Оплаченный доступ и автопродление в магазине сохранятся.'),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Отмена')),
            TextButton(key: const Key('confirm_delete_subscription'),
              onPressed: () => Navigator.of(context).pop(true), child: const Text('Удалить')),
          ],
        ));
    } finally {
      if (mounted) setState(() => _profileBusy = false);
    }
    if (confirmed != true || !mounted || !_foreground ||
        intentEpoch != _profileRequestEpoch) return;
    await _changeSubscriptions(() => _subscriptionBridge.deleteSubscription(subscription.id),
      subscriptionId: subscription.id, operation: SubscriptionDiagnosticOperation.deleteSubscription);
  }

  Future<void> _openPushokAccount() => _openPushokDestination();

  Future<void> _openPushokHub() => _openPushokDestination(hub: true);

  Future<void> _openPushokDestination({bool hub = false}) async {
    if (!_isAndroid || !mounted || !_foreground || _openingPushok) return;
    setState(() => _openingPushok = true);
    try {
      if (hub) {
        await _subscriptionBridge.openPushokHub();
      } else {
        await _subscriptionBridge.openPushokAccount();
      }
    } catch (_) {
      if (mounted && _foreground) {
        final username = hub ? FlowSubscriptions.hubUsername : FlowSubscriptions.botUsername;
        _showNotice('Не удалось открыть ${hub ? 'Pushok' : 'кабинет MTProxy'}. '
          'Найдите $username в Telegram.');
      }
    } finally {
      if (mounted) setState(() => _openingPushok = false);
    }
  }

  Future<void> _readRecommendations({bool checkAutomatically = false}) =>
      _requestRecommendations(refresh: false,
          checkAutomatically: checkAutomatically);

  Future<void> _refreshRecommendations() => _requestRecommendations(refresh: true);

  Future<void> _requestRecommendations({required bool refresh,
      bool automatic = false, bool checkAutomatically = false}) async {
    if (!_isAndroid || !mounted || !_foreground || tab != 1 ||
        _recommendationsLoading || _recommendationsRefreshing ||
        _recommendationsSavingAutoUpdate ||
        (automatic && !_recommendations.autoUpdateEnabled) ||
        (refresh && _recommendations.busy)) return;
    final epoch = ++_recommendationEpoch;
    _recommendationPoll?.cancel();
    setState(() {
      _recommendationsLoading = !refresh;
      _recommendationsRefreshing = refresh;
    });
    RecommendationStatus status;
    try {
      status = await (automatic
          ? _recommendationBridge.refreshRecommendationsIfDue()
          : refresh ? _recommendationBridge.refreshRecommendations()
              : _recommendationBridge.recommendationStatus());
    } on RecommendationFailure catch (failure) {
      status = _recommendations.withError(failure.code);
    }
    if (!mounted || !_foreground || tab != 1 || epoch != _recommendationEpoch) return;
    _acceptRecommendations(status);
    // Only a route entry/resume may request an automatic check. Busy polling
    // calls the local read without this flag, so it never becomes a retry loop.
    if (checkAutomatically && status.autoUpdateEnabled && !status.busy &&
        status.errorCode == null) {
      await _requestRecommendations(refresh: true, automatic: true);
    }
  }

  Future<void> _setRecommendationAutoUpdate(bool enabled) async {
    if (!_isAndroid || !mounted || !_foreground || tab != 1 ||
        _recommendationsLoading || _recommendationsSavingAutoUpdate ||
        enabled == _recommendations.autoUpdateEnabled) return;
    // Invalidate a pending refresh before asking native to cancel an automatic
    // request. Its late snapshot cannot turn the user's switch back on.
    final epoch = ++_recommendationEpoch;
    _recommendationPoll?.cancel();
    setState(() {
      _recommendationsSavingAutoUpdate = true;
      _recommendationsRefreshing = false;
    });
    RecommendationStatus status;
    try {
      status = await _recommendationBridge.setAutoUpdateEnabled(enabled);
    } on RecommendationFailure catch (failure) {
      status = _recommendations.withError(failure.code);
    }
    if (!mounted || !_foreground || tab != 1 || epoch != _recommendationEpoch) return;
    _acceptRecommendations(status);
    if (enabled && status.autoUpdateEnabled && !status.busy && status.errorCode == null) {
      await _requestRecommendations(refresh: true, automatic: true);
    }
  }

  void _acceptRecommendations(RecommendationStatus status) {
    setState(() {
      _recommendations = status;
      _recommendationsLoading = false;
      _recommendationsRefreshing = false;
      _recommendationsSavingAutoUpdate = false;
    });
    // A refresh can outlive Activity focus. Polling only reads the local
    // snapshot and never starts another network request.
    if (status.busy) {
      _recommendationPoll = Timer(const Duration(seconds: 1), () {
        unawaited(_readRecommendations());
      });
    }
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
    _notifyInformation();
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
            _ownsTunnel = info.ownsTunnel;
          } else if (info.ownsTunnel) {
            // Retain explicit last-known ownership for the Disconnect action.
            // An unknown read must never claim a successful disconnect.
            _ownsTunnel = true;
          }
          lastErrorCode = info.lastErrorCode;
        });
      } catch (_) {
        if (mounted && _foreground && epoch == _statusEpoch) setState(() {
          _diagnostics = TunnelDiagnostics.unavailable(ownsTunnel: _ownsTunnel);
          _diagnosticsStale = true;
          lastErrorCode = null;
        });
      }
    } finally {
      if (mounted) {
        setState(() => _statusRefreshing = false);
        if (_tunnelConfirmed) {
          unawaited(_measurePing());
        } else {
          _linkEpoch++;
          _pingMs = null;
        }
        _notifyInformation();
        // Coalesce a resume/connect refresh behind an older in-flight sample.
        if (_foreground && !connecting && epoch != _statusEpoch) {
          unawaited(_refreshProfileStatus());
        }
      }
    }
  }

  Future<void> _editProfile({WireGuardProfileSummary? profile,
      bool connectAfterSave = false, int? tunnelIntent}) async {
    if (!_canManageProfiles || (profile?.isManaged ?? false)) return;
    if (profile == null && _profiles!.isFull) {
      _showNotice('Можно сохранить до 20 профилей. Удалите ненужный профиль.');
      return;
    }
    _statusEpoch++;
    setState(() => _profileBusy = true);
    final requestEpoch = _profileRequestEpoch;
    ProfilePrivacy? protection;
    String? saved;
    var subscriptionSaved = false;
    FlowSubscription? addedSubscription;
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
      if (_ownsTunnel || connecting || _nativeBusy) {
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
          onScanQr: WireGuardTunnel.scanProfileQr,
          onImportQrImage: WireGuardTunnel.importProfileQrImage,
          onCancelImport: WireGuardTunnel.cancelProfileImport,
          onSaveSubscription: (url, name) async {
            addedSubscription = await _saveSubscriptionDraft(url, name);
          },
          onSubscriptionSaved: () => subscriptionSaved = true,
          onSave: (config, name) async {
            if (!mounted || !_foreground) {
              throw PlatformException(code: 'PROFILE_SAVE_INTERRUPTED');
            }
            // A file picker or QR scanner leaves the editor temporarily. A new explicit Save
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
    if (!mounted) return;
    if (subscriptionSaved) {
      if (_foreground) {
        setState(() { tab = 2; _settingsOpen = true; _settingsLanding = false; });
        _showNotice(_subscriptionSavedNotice(addedSubscription));
      }
      return;
    }
    if (saved == null) return;
    if (connectAfterSave) {
      // A slow save must not start VPN permission UI after app switching.
      if (!_foreground || saveIntentEpoch != _profileRequestEpoch) {
        if (_foreground) _showNotice('Профиль сохранён. Нажмите «Подключить», когда будете готовы.');
        return;
      }
      // The user may act while the post-save catalog refresh is pending.
      // An older Save-and-Connect intent must never toggle a newer tunnel off.
      if (tunnelIntent != _tunnelIntentEpoch || _ownsTunnel || connecting) return;
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
      if (error.code == 'PROFILE_MANAGED') {
        return 'Этот сервер обновляется вместе с подпиской. Откройте раздел «Подписки».';
      }
      if (error.code == 'SUBSCRIPTION_EXPIRED' || error.code == 'SUBSCRIPTION_REVOKED') {
        return subscriptionErrorMessage(error);
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
    if (!_canManageProfiles || profile.isManaged) return;
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
          intentEpoch != _profileRequestEpoch || _ownsTunnel || connecting || _nativeBusy) return;
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
        AndroidAppRoutes.getBypassStatus().timeout(const Duration(seconds: 5)),
      ], eagerError: true);
      if (mounted && _foreground && epoch == _routeEpoch && !_savingRoute) {
        setState(() {
          installed = values[0] as List<InstalledApp>;
          final status = values[1] as BypassStatus;
          bypassPackages = status.packages;
          unavailableBypassPackages = status.unavailablePackages;
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
        case 'ROUTES_APPS_CHECK_FAILED':
          return 'Не удалось проверить доступность приложений. Повторите проверку списка.';
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
    if (_ownsTunnel || connecting || _nativeBusy) {
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

  void _notifyInformation() {
    if (mounted) _informationRevision.value++;
  }

  Future<void> _openInformation() async {
    if (!mounted || !_foreground || _informationOpen || connecting ||
        _profileBusy || _profileEditorOpen) return;
    // Close the Routes search keyboard before presenting the scrollable panel.
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _informationOpen = true);
    unawaited(_refreshProfileStatus());
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: PushokPalette.midnight,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          side: BorderSide(color: PushokPalette.border),
        ),
        builder: (sheetContext) => ValueListenableBuilder<int>(
          valueListenable: _informationRevision,
          builder: (context, revision, child) => AppInformationSheet(
            version: appVersionName,
            isAndroid: _isAndroid,
            diagnostics: _diagnostics,
            refreshing: _statusRefreshing,
            stale: _diagnosticsStale,
            disconnecting: connecting,
            connectionError: connectionError,
            lastErrorCode: lastErrorCode,
            onRefresh: !_foreground || connecting || _profileBusy ||
                _profileEditorOpen || _savingRoute || _statusRefreshing
                    ? null : _refreshProfileStatus,
            onClose: () => Navigator.of(sheetContext).pop(),
            onDisconnect: _canRecoverTunnel ? _disconnectForRecovery : null,
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _informationOpen = false);
      } else {
        _informationOpen = false;
      }
    }
  }

  void _selectTab(int value) {
    final enteringRoutes = value == 1 && (!_settingsOpen || _settingsLanding || value != tab);
    if (value != tab) {
      _recommendationEpoch++;
      _recommendationPoll?.cancel();
    }
    setState(() {
      if (value != tab) {
        _recommendationsLoading = false;
        _recommendationsRefreshing = false;
        _recommendationsSavingAutoUpdate = false;
      }
      tab = value;
      _settingsOpen = value != 0;
      _settingsLanding = false;
    });
    if (value == 1) {
      unawaited(_refreshRoutes());
      unawaited(_readRecommendations(checkAutomatically: enteringRoutes));
    }
    if (value == 2) {
      unawaited(_refreshProfileStatus().then((_) =>
        _readSubscriptions(checkAutomatically: true)));
    }
  }

  void _openSettings() {
    if (!_foreground || _profileEditorOpen || _routeConfirmationOpen ||
        _informationOpen) return;
    setState(() { _settingsOpen = true; _settingsLanding = true; });
  }

  void _backFromSettings() {
    if (_profileEditorOpen || _routeConfirmationOpen || _informationOpen) return;
    if (_settingsLanding) {
      setState(() { _settingsOpen = false; _settingsLanding = false; tab = 0; });
    } else {
      _recommendationEpoch++;
      _recommendationPoll?.cancel();
      setState(() { _settingsLanding = true; });
    }
  }

  String _settingsTitle() => switch (tab) {
    1 => 'Маршруты',
    2 => 'Серверы и подписки',
    3 => 'Pushok ИИ',
    4 => 'Аккаунт и обновления',
    5 => 'Справка',
    6 => 'Обновление',
    7 => 'IP и трафик',
    8 => 'Сайты напрямую',
    _ => 'Настройки',
  };

  Widget _settingsContent() {
    if (_settingsLanding) return FlowSettingsMenu(onSelect: _selectTab);
    return switch (tab) {
      8 => const BrowserSitesPage(),
      7 => const DeviceTrafficPage(),
      6 => ListView(children: [AppUpdatesCard(isAndroid: _isAndroid)]),
      1 => routes(),
      2 => servers(),
      3 => assistant(),
      4 => profile(),
      5 => FlowHelpPage(
        onDiagnostics: connecting || _profileBusy || _profileEditorOpen
            ? null : _openInformation),
      _ => FlowSettingsMenu(onSelect: _selectTab),
    };
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<void>(
      canPop: !_settingsOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _settingsOpen) _backFromSettings();
      },
      child: Scaffold(
      extendBodyBehindAppBar: !_settingsOpen,
      appBar: AppBar(
        backgroundColor: _settingsOpen ? null : Colors.transparent,
        leading: _settingsOpen ? IconButton(
          key: const Key('flow_settings_back'),
          tooltip: _settingsLanding ? 'На главную' : 'Назад к настройкам',
          icon: const Icon(Icons.arrow_back),
          onPressed: _backFromSettings,
        ) : null,
        title: Text(_settingsOpen
            ? (_settingsLanding ? 'Настройки' : _settingsTitle())
            : 'Pushok Flow',
          style: const TextStyle(fontWeight: FontWeight.w700)),
        actions: _settingsOpen && !_settingsLanding && tab == 5 ? [
          IconButton(
            key: const Key('open_app_information'),
            icon: const Icon(Icons.info_outline),
            tooltip: 'Диагностика',
            onPressed: connecting || _profileBusy || _profileEditorOpen
                ? null : _openInformation,
          ),
        ] : !_settingsOpen ? [
          if (_isAndroid) TelegramProxyAction(subscriptions: _subscriptionBridge),
          Center(child: Text(appVersionName, style: const TextStyle(fontWeight: FontWeight.w600))),
          if (_updateOffered) TextButton(onPressed: () => _selectTab(6), child: const Text('Обновить')),
          IconButton(
          key: const Key('flow_settings_button'),
          icon: const Icon(Icons.settings_outlined),
          tooltip: 'Настройки',
          onPressed: _openSettings,
        )] : _settingsLanding && _isAndroid ? [TelegramProxyAction(subscriptions: _subscriptionBridge, inSettings: true)] : [],
      ),
      body: PushokNeonBackdrop(child: SafeArea(child: Padding(
        padding: EdgeInsets.fromLTRB(14, _settingsOpen ? 14 : kToolbarHeight + 4, 14, 12),
        child: _settingsOpen ? _settingsContent() : home(),
      ))),
    ));
  }


  Widget home() => LayoutBuilder(builder: (context, constraints) => SingleChildScrollView(
    key: const Key('flow_home_screen'),
    child: ConstrainedBox(constraints: BoxConstraints(minHeight: constraints.maxHeight),
      child: Column(mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Column(children: [
      Center(child: AnimatedPushokMascot(
        key: const Key('pushok_mascot'),
        height: constraints.maxHeight < 590 ? 84 : 112,
        connected: _tunnelConfirmed)),
      const SizedBox(height: 10),
      Center(child: GestureDetector(
        onVerticalDragEnd: (drag) {
          if ((drag.primaryVelocity ?? 0) < -220 && _canToggleTunnel && !_ownsTunnel) _handlePowerTap();
        },
        child: AnimatedContainer(
        duration: const Duration(milliseconds: 450),
        width: (constraints.maxWidth * .63).clamp(174.0, 258.0).toDouble(),
        height: (constraints.maxWidth * .63).clamp(174.0, 258.0).toDouble(),
        padding: const EdgeInsets.all(5),
        decoration: BoxDecoration(shape: BoxShape.circle,
          gradient: LinearGradient(colors: _tunnelConfirmed
            ? [PushokPalette.mint, PushokPalette.glowCyan]
            : [PushokPalette.glowCyan, PushokPalette.electricBlue, PushokPalette.glowViolet]),
          boxShadow: [BoxShadow(color: PushokPalette.glowViolet.withValues(alpha: .28), blurRadius: 40, spreadRadius: 6, offset: const Offset(6, 5)),
            BoxShadow(color: (_tunnelConfirmed ? PushokPalette.mint : PushokPalette.glowCyan)
            .withValues(alpha: .55), blurRadius: 28, spreadRadius: 3)]),
        child: Material(color: PushokPalette.midnight, shape: const CircleBorder(), child: InkWell(
          key: const Key('pushok_connect_button'),
          customBorder: const CircleBorder(),
          onTap: _canToggleTunnel ? _handlePowerTap : null,
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(_tunnelConfirmed ? Icons.check_circle_outline
                : _ownsTunnel ? Icons.info_outline : Icons.power_settings_new,
              color: _tunnelConfirmed ? PushokPalette.mint : PushokPalette.glowCyan, size: 54),
            const SizedBox(height: 8),
            Text(connecting ? (_ownsTunnel ? 'Отключение' : 'Подключение')
                : _ownsTunnel ? 'Отключить' : 'Подключить',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white,
                fontWeight: FontWeight.w800, fontSize: 18)),
          ]),
        )),
      ))),
      ]),
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: 13),
      // The power button controls login, provisioning and eventual connect.
      // The compact status below is informational, not another login step.
      PushokAccountCard(
        key: _homeAccountKey,
        isAndroid: _isAndroid,
        compactHome: true,
        onAccountChanged: (value) {
          if (mounted && _homeAccountAuthorized != value) {
            setState(() => _homeAccountAuthorized = value);
          }
        },
        onReadyToConnect: () => unawaited(_connectAfterShopReady()),
        onShopSynced: () {
          unawaited(_readSubscriptions());
          unawaited(_refreshProfileStatus());
        },
        onOpenCabinet: _isAndroid && _foreground && !_openingPushok
            ? _openPushokAccount : null,
        onOpenHub: _isAndroid && _foreground && !_openingPushok
            ? _openPushokHub : null,
      ),
      Padding(padding: const EdgeInsets.only(top: 10), child: FlowConnectionVitals(
        pingMs: _tunnelConfirmed ? _pingMs : null,
        renew: _isAndroid && _homeAccountAuthorized && _foreground
            ? () => _homeAccountKey.currentState?.openRenewal() : null,
        selected: _profiles?.activeProfile,
        selectionCurrent: _foreground && !_statusRefreshing &&
            !_profileBusy && !_profileEditorOpen && !_diagnosticsStale &&
            _profilesError == null && _profiles != null,
        subscriptions: _subscriptionsError == null ? _subscriptions : null,
        diagnostics: _diagnostics,
        diagnosticsCurrent: _foreground && !_diagnosticsStale &&
            _diagnostics.isKnown && !_statusRefreshing,
        confirmedConnected: _tunnelConfirmed,
        connecting: connecting,
        nativeBusy: _nativeBusy,
        ownsTunnel: _ownsTunnel,
        recovery: _recovery,
        isAndroid: _isAndroid,
      ),
      ),
      ]),
    ])),
  ));

  Widget routes() => AppRoutesView(
    apps: installed,
    selectedPackages: bypassPackages,
    unavailablePackages: unavailableBypassPackages,
    recommendedPackages: _recommendations.rulesVersion == 0
        ? RecommendationStatus.bundledPackages
        : {..._recommendations.packages, ...RecommendationStatus.compatibilityPackages},
    availabilityCurrent: !_routesStale && !loadingApps && routeError == null,
    isAndroid: _isAndroid,
    loading: loadingApps,
    saving: _savingRoute,
    loaded: _routesLoaded,
    canEdit: _canEditRoutes,
    query: _routeQuery,
    onlySelected: _onlySelectedRoutes,
    onlyUnavailable: _onlyUnavailableRoutes,
    onlyRecommended: _onlyRecommendedRoutes,
    error: routeError,
    disabledReason: _isAndroid ? _routeDisabledReason : null,
    onQueryChanged: (value) => setState(() => _routeQuery = value),
    onFilterChanged: (value) => setState(() {
      _onlySelectedRoutes = value;
      _onlyUnavailableRoutes = false;
      _onlyRecommendedRoutes = false;
    }),
    onUnavailableFilterChanged: (value) => setState(() {
      _onlyUnavailableRoutes = value;
      _onlySelectedRoutes = false;
      _onlyRecommendedRoutes = false;
    }),
    onRecommendedFilterChanged: (value) => setState(() {
      _onlyRecommendedRoutes = value;
      _onlySelectedRoutes = false;
      _onlyUnavailableRoutes = false;
    }),
    onToggle: _setBypass,
    onRefresh: !_isAndroid || !_foreground || loadingApps || _savingRoute ||
        _routeConfirmationOpen || _profileBusy || _profileEditorOpen
            ? null : _refreshRoutes,
    onClear: _canEditRoutes && bypassPackages.isNotEmpty ? _clearBypass : null,
    recommendationsCard: RouteRecommendationsCard(
      status: _recommendations,
      loading: _recommendationsLoading,
      refreshing: _recommendationsRefreshing,
      savingAutoUpdate: _recommendationsSavingAutoUpdate,
      onRefresh: _foreground ? _refreshRecommendations : null,
      onAutoUpdateChanged: _isAndroid && _foreground ? _setRecommendationAutoUpdate : null,
    ),
  );
  Widget servers() => SingleChildScrollView(child: Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
    SubscriptionsCard(
      status: _subscriptions,
      loading: _subscriptionsLoading,
      busy: _subscriptionsBusy,
      savingAutoUpdate: _subscriptionsSavingAutoUpdate,
      error: !_isAndroid ? 'Подписки доступны в приложении для Android.' : _subscriptionsError,
      errorDiagnostic: _isAndroid ? _subscriptionsDiagnostic : null,
      refreshDiagnostics: _subscriptionDiagnostics,
      isCurrentErrorDiagnostic: (diagnostic) => _canCopySubscriptionDiagnostic &&
          _subscriptionsError != null && identical(diagnostic, _subscriptionsDiagnostic),
      isCurrentRefreshDiagnostic: (id, diagnostic) => _canCopySubscriptionDiagnostic &&
          _subscriptions?.refreshErrors[id] == diagnostic.code &&
          identical(diagnostic, _subscriptionDiagnostics[id]),
      mutationsEnabled: _canManageProfiles,
      pendingLink: _pendingSubscriptionLink != null,
      onAdd: () => _addSubscription(),
      onRefreshList: _isAndroid && _foreground ? _readSubscriptions : null,
      onRefresh: (subscription) => _changeSubscriptions(
        () => _subscriptionBridge.refreshSubscription(subscription.id),
        subscriptionId: subscription.id),
      onDelete: _deleteSubscription,
      onAutomaticUpdatesChanged: _isAndroid && _foreground
          ? _setSubscriptionAutomaticUpdates : null,
      onOpenAccount: _isAndroid && _foreground && !_openingPushok
          ? _openPushokAccount : null,
      onOpenPendingLink: () => _addSubscription(draft: _pendingSubscriptionLink),
    ),
    const SizedBox(height: 12),
    WireGuardProfilesCard(
      catalog: _profiles,
      // Confirmation and the protected editor block actions without pretending
      // that a catalog read is running behind the modal route.
      loading: _statusRefreshing,
      error: !_isAndroid ? 'Профили подключения доступны в приложении для Android.'
          : _profilesError,
      mutationsEnabled: _canManageProfiles,
      onRefresh: !_isAndroid || _statusRefreshing || _profileBusy ||
          _profileEditorOpen || !_foreground ? null : _refreshProfileStatus,
      onAdd: () => _editProfile(),
      onEdit: (profile) => _editProfile(profile: profile),
      onSelect: _selectProfile,
      onDelete: _deleteProfile,
    ),
    if (_ownsTunnel || connecting || _nativeBusy) const Padding(
      padding: EdgeInsets.only(top: 12),
      child: Text('Для изменения профилей отключите туннель.',
          style: TextStyle(color: PushokPalette.muted)),
    ),
  ]));
  Widget assistant() => ListView(children: [
    ListTile(leading:const Icon(Icons.chat_bubble_outline),title:const Text('Чат с Pushok ИИ'),
      subtitle:const Text('Поддержка и предложения по развитию'),
      onTap:() async {
        try { await _subscriptionBridge.openSupport(); }
        catch (_) { if (mounted) _showNotice('Не удалось открыть поддержку.'); }
      }),
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
      const Text('Диагностика связи доступна по кнопке ⓘ справа сверху. Автоматическое обучение '
        'и проверка доступности сайтов — следующие этапы.',
        style: TextStyle(color: PushokFlowApp.secondary)),
    ])),
  ]);
  Widget profile() => ListView(children: [
    PushokAccountCard(isAndroid: _isAndroid,
      onShopSynced: () {
        unawaited(_readSubscriptions());
        unawaited(_refreshProfileStatus());
      },
      onOpenCabinet: _isAndroid && _foreground && !_openingPushok ? _openPushokAccount : null,
      onOpenHub: _isAndroid && _foreground && !_openingPushok ? _openPushokHub : null),
    const SizedBox(height: 12),
    AppUpdatesCard(isAndroid: _isAndroid),
  ]);
}
