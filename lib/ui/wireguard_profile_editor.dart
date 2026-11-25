import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../design/pushok_theme.dart';
import '../platform/subscription_diagnostics.dart';
import '../platform/subscriptions.dart';
import '../platform/wireguard_profiles.dart';
import 'subscription_editor.dart';

enum _ProfileImportSource { file, cameraQr, imageQr }

/// Contains only fixed UI messages and an allowlisted code, never a profile.
class _ProfileImportFailure {
  const _ProfileImportFailure(this.code, this.source, this.message);

  final String code;
  final _ProfileImportSource source;
  final String message;

  String get clipboardText {
    final label = switch (source) {
      _ProfileImportSource.file => 'Файл',
      _ProfileImportSource.cameraQr => 'Камера QR',
      _ProfileImportSource.imageQr => 'QR из фото',
    };
    return 'Pushok Flow — ошибка импорта профиля\n'
        'Источник: $label\nКод: $code\n$message';
  }
}

/// Edits a local draft and returns it only after the caller saves it successfully.
class WireGuardProfileEditor extends StatefulWidget {
  const WireGuardProfileEditor({
    super.key,
    required this.initialConfig,
    required this.onSave,
    this.initialName = 'Мой профиль',
    this.onImport,
    this.onScanQr,
    this.onImportQrImage,
    this.onCancelImport,
    this.onSaveSubscription,
    this.onSubscriptionSaved,
    this.connectAfterSave = false,
    this.initialError,
    this.onClose,
    this.onCompleted,
  });

  final String initialConfig;
  final String initialName;
  final Future<void> Function(String config, String name) onSave;
  final Future<String?> Function()? onImport;
  final Future<String?> Function()? onScanQr;
  final Future<String?> Function()? onImportQrImage;
  final Future<void> Function()? onCancelImport;
  final Future<void> Function(String url, String name)? onSaveSubscription;
  final VoidCallback? onSubscriptionSaved;
  final bool connectAfterSave;
  final String? initialError;
  /// Inline editors remain inside the caller's protected route.
  final VoidCallback? onClose;
  final VoidCallback? onCompleted;

  @override
  State<WireGuardProfileEditor> createState() => _WireGuardProfileEditorState();
}

class _WireGuardProfileEditorState extends State<WireGuardProfileEditor>
    with WidgetsBindingObserver {
  static const _maxConfigLength = 65536;
  static const _unsupportedProfile =
      'Этот формат пока не поддерживается. Добавьте профиль WireGuard .conf.';
  static const _unsupportedTransport =
      'Для подключения нужен профиль WireGuard .conf.';
  static const _invalidVless =
      'В этой версии доступен WireGuard. Импортируйте профиль .conf.';
  static const _unsupportedSecurity =
      'Для подключения нужен профиль WireGuard .conf.';
  static const _unsupportedOption =
      'Для подключения нужен профиль WireGuard .conf.';
  static const _safeImportCodes = {
    'PROFILE_IMPORT_TOO_LARGE',
    'PROFILE_IMPORT_INVALID',
    'PROFILE_IMPORT_BUSY',
    'PROFILE_IMPORT_SOURCE_BUSY',
    'PROFILE_IMPORT_INTERRUPTED',
    'PROFILE_IMPORT_TIMEOUT',
    'PROFILE_IMPORT_UNAVAILABLE',
    'PROFILE_IMPORT_FAILED',
    'PROFILE_QR_CAMERA_DENIED',
    'PROFILE_QR_UNAVAILABLE',
    'PROFILE_QR_NOT_FOUND',
    'PROFILE_QR_MULTIPLE',
    'PROFILE_QR_IMAGE_TOO_LARGE',
    'UNSUPPORTED_PROFILE',
    'UNSUPPORTED_TRANSPORT',
    'UNSUPPORTED_SECURITY',
    'UNSUPPORTED_PROFILE_OPTION',
    'INVALID_VLESS_CONFIG',
    'SUBSCRIPTION_URL_INVALID',
    'PROFILE_TELEGRAM_LINK',
    'PROFILE_VMESS_LINK',
    'PROFILE_TROJAN_LINK',
    'PROFILE_SHADOWSOCKS_LINK',
  };
  late final TextEditingController _controller;
  late final TextEditingController _nameController;
  final FocusNode _focusNode = FocusNode();
  final FocusNode _nameFocusNode = FocusNode();
  bool _clearNameAfterUnfocus = false;
  bool _showConfig = false;
  bool _saving = false;
  bool _pasting = false;
  bool _importing = false;
  _ProfileImportSource? _importSource;
  bool _importCancelSent = false;
  int _importEpoch = 0;
  int _inputEpoch = 0;
  bool _closing = false;
  bool _resumed = true;
  String? _error;
  String? _notice;
  _ProfileImportFailure? _importFailure;
  bool _copyingImportError = false;
  String? _importCopyNotice;
  SubscriptionDraft? _subscriptionDraft;
  SubscriptionDiagnosticSource _subscriptionSource = SubscriptionDiagnosticSource.manualInput;
  bool _editingSubscription = false;

  bool get _busy => _saving || _pasting || _importing || _editingSubscription || _closing;
  bool get _canReveal {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    return _resumed &&
        (lifecycle == null || lifecycle == AppLifecycleState.resumed) &&
        ModalRoute.of(context)?.isCurrent != false;
  }

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialConfig);
    _nameController = TextEditingController(text: widget.initialName);
    _nameFocusNode.addListener(_finishNameInputCleanup);
    _error = widget.initialError;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _resumed = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    _inputEpoch++;
    _cancelPendingImport();
    WidgetsBinding.instance.removeObserver(this);
    _focusNode.dispose();
    _nameFocusNode.removeListener(_finishNameInputCleanup);
    _nameFocusNode.dispose();
    _controller.dispose();
    _nameController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    final resumed = state == AppLifecycleState.resumed;
    setState(() {
      _resumed = resumed;
      if (!resumed) {
        _showConfig = false;
      }
    });
    if (!resumed) _clearInputSelection();
  }

  void _clearInputSelection() {
    _clearNameAfterUnfocus = true;
    _focusNode.unfocus();
    _nameFocusNode.unfocus();
    // Clear only input state. The complete multiline draft must remain intact.
    _controller.value = _controller.value.copyWith(
      selection: const TextSelection.collapsed(offset: -1),
      composing: TextRange.empty,
    );
    _nameController.clearComposing();
    _finishNameInputCleanup();
  }

  void _finishNameInputCleanup() {
    if (!mounted || !_clearNameAfterUnfocus || _nameFocusNode.hasFocus) return;
    _clearNameAfterUnfocus = false;
    // FocusManager commits unfocus asynchronously. While the name field still
    // has focus, EditableText repairs an invalid selection to the text end.
    // Clear it after actual focus loss; no frame or resumed app is required.
    _nameController.value = _nameController.value.copyWith(
      selection: const TextSelection.collapsed(offset: -1),
      composing: TextRange.empty,
    );
  }

  ({String code, String message})? _validationError(String config) {
    if (config.trim().isEmpty) {
      return (code: 'PROFILE_IMPORT_INVALID',
          message: 'Добавьте конфигурацию WireGuard или ссылку VLESS перед сохранением.');
    }
    if (config.length > _maxConfigLength) {
      return (code: 'PROFILE_IMPORT_TOO_LARGE',
          message: 'Профиль слишком большой: максимум 65 536 символов.');
    }
    if (RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
        r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$').hasMatch(config.trim())) {
      return (code: 'INVALID_VLESS_CONFIG',
          message: 'Вставлен только UUID. Нужна полная ссылка VLESS из 3x-ui '
              'или профиль WireGuard .conf с разделами [Interface] и [Peer].');
    }
    // Only reject unsupported schemes here. Native code validates every VLESS
    // field; UI parsing must not normalize, log, or partly accept credentials.
    final scheme = RegExp(r'^([A-Za-z][A-Za-z0-9+.-]*)://')
        .firstMatch(config.trim())?.group(1)?.toLowerCase();
    if (scheme == 'http') {
      return (code: 'SUBSCRIPTION_URL_INVALID',
          message: _importError('SUBSCRIPTION_URL_INVALID', _ProfileImportSource.file));
    }
    final protocolCode = switch (scheme) {
      'vmess' => 'PROFILE_VMESS_LINK',
      'trojan' => 'PROFILE_TROJAN_LINK',
      'ss' || 'ssr' => 'PROFILE_SHADOWSOCKS_LINK',
      'tg' => 'PROFILE_TELEGRAM_LINK',
      _ => null,
    };
    if (protocolCode != null || _isTelegramProxy(config.trim())) {
      final code = protocolCode ?? 'PROFILE_TELEGRAM_LINK';
      return (code: code, message: _importError(code, _ProfileImportSource.file));
    }
    if (scheme == 'https') {
      if (!SubscriptionDraft.validUrl(config.trim())) {
        return (code: 'SUBSCRIPTION_URL_INVALID',
            message: _importError('SUBSCRIPTION_URL_INVALID', _ProfileImportSource.file));
      }
      return (code: 'UNSUPPORTED_PROFILE',
          message: 'Найдена HTTPS-ссылка. Добавьте её через «Серверы → Подписки → Добавить подписку».');
    }
    if (scheme != null && scheme != 'vless') {
      return (code: 'UNSUPPORTED_PROFILE', message: _unsupportedProfile);
    }
    return null;
  }

  void _clearImportFeedback() {
    _importFailure = null;
    _importCopyNotice = null;
    _subscriptionDraft = null;
  }

  bool _isTelegramProxy(String text) {
    final uri = Uri.tryParse(text);
    return uri != null &&
        const {'t.me', 'telegram.me', 'www.t.me', 'www.telegram.me'}
            .contains(uri.host.toLowerCase()) &&
        const {'/proxy', '/socks'}.contains(uri.path);
  }

  bool _offerSubscription(String text,
      {SubscriptionDiagnosticSource source = SubscriptionDiagnosticSource.manualInput}) {
    final url = text.trim();
    if (widget.onSaveSubscription == null || !SubscriptionDraft.validUrl(url) ||
        _isTelegramProxy(url)) return false;
    // Keep the original profile and its name untouched. Scanning does not
    // navigate, download, save, or authorize connecting to anything.
    setState(() {
      _showConfig = false;
      _error = null;
      _importFailure = null;
      _importCopyNotice = null;
      _subscriptionDraft = SubscriptionDraft(url: url);
      _subscriptionSource = source;
      _notice = 'Найдена HTTPS-ссылка. Добавить её как подписку?';
    });
    return true;
  }

  void _openSubscription() {
    if (!mounted || _busy || !_canReveal || _editingSubscription ||
        _subscriptionDraft == null || widget.onSaveSubscription == null ||
        ModalRoute.of(context)?.isCurrent == false) return;
    _clearInputSelection();
    setState(() { _showConfig = false; _editingSubscription = true; });
  }

  void _discardSubscription() {
    if (!mounted || _busy || !_canReveal) return;
    setState(() { _subscriptionDraft = null; _notice = null; });
  }

  void _closeEditor() {
    // An old profile button cannot close an inline subscription during save.
    if (!mounted || _saving || _pasting || _editingSubscription ||
        _closing || !_canReveal) return;
    setState(_beginClosing);
    if (widget.onClose != null) {
      widget.onClose!();
    } else {
      Navigator.of(context).pop();
    }
  }

  void _beginClosing() {
    _closing = true;
    _inputEpoch++;
    _showConfig = false;
    _cancelPendingImport();
    _clearInputSelection();
  }

  void _complete([String? config]) {
    if (!mounted || _closing) return;
    setState(_beginClosing);
    if (widget.onCompleted != null) {
      widget.onCompleted!();
    } else {
      Navigator.of(context).pop<String>(config);
    }
  }

  void _setImportFailure(String? code, _ProfileImportSource source,
      {String? validationMessage}) {
    final safeCode = _safeImportCodes.contains(code) ? code! : 'PROFILE_IMPORT_FAILED';
    final message = validationMessage ?? _importError(safeCode, source);
    setState(() {
      _error = message;
      _notice = null;
      _subscriptionDraft = null;
      _importFailure = _ProfileImportFailure(safeCode, source, message);
      _importCopyNotice = null;
    });
  }

  Future<void> _copyImportError(_ProfileImportFailure failure) async {
    if (!mounted || _busy || _copyingImportError || !_canReveal ||
        !identical(_importFailure, failure) ||
        ModalRoute.of(context)?.isCurrent == false) return;
    setState(() {
      _copyingImportError = true;
      _importCopyNotice = null;
    });
    try {
      // This is an explicit export of fixed diagnostics. No controller text,
      // profile name, native message/details or unknown error code is read.
      await Clipboard.setData(ClipboardData(text: failure.clipboardText));
      if (mounted && identical(_importFailure, failure)) {
        setState(() => _importCopyNotice = 'Текст ошибки скопирован.');
      }
    } catch (_) {
      if (mounted && identical(_importFailure, failure)) {
        setState(() => _importCopyNotice =
            'Не удалось скопировать текст ошибки. Попробуйте ещё раз.');
      }
    } finally {
      if (mounted) setState(() => _copyingImportError = false);
    }
  }

  Future<void> _paste() async {
    if (!mounted || _busy || !_canReveal) return;
    final epoch = _inputEpoch;
    setState(() {
      _pasting = true;
      _error = null;
      _notice = null;
      _clearImportFeedback();
    });
    try {
      // Clipboard access happens only after the user presses «Вставить».
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (!mounted || _saving || _closing || epoch != _inputEpoch ||
          ModalRoute.of(context)?.isCurrent == false) return;
      final config = data?.text;
      if (config == null || config.trim().isEmpty) {
        setState(() => _error = 'В буфере обмена нет конфигурации.');
        return;
      }
      if (_offerSubscription(config, source: SubscriptionDiagnosticSource.clipboard)) return;
      final validation = _validationError(config);
      if (validation != null) {
        setState(() => _error = validation.message);
        return;
      }
      _controller.value = TextEditingValue(
        text: config,
        selection: TextSelection.collapsed(offset: config.length),
      );
      setState(() { _error = null; _notice = null; });
    } catch (_) {
      if (mounted && !_closing && epoch == _inputEpoch) {
        setState(() => _error =
            'Не удалось прочитать буфер обмена. Введите конфигурацию вручную.');
      }
    } finally {
      if (mounted && !_closing) setState(() => _pasting = false);
    }
  }

  void _cancelPendingImport() {
    if (!_importing || _importCancelSent) return;
    _importCancelSent = true;
    _importEpoch++;
    // Invalidate the draft immediately, before the closing route animation.
    // A native cancellation failure must not keep this route or expose details.
    unawaited(_cancelImport());
  }

  Future<void> _cancelImport() async {
    try {
      await widget.onCancelImport?.call();
    } catch (_) {
      // Native request generations and the local epoch also reject late replies.
    }
  }

  Future<void> _import(_ProfileImportSource source) async {
    final read = switch (source) {
      _ProfileImportSource.file => widget.onImport,
      _ProfileImportSource.cameraQr => widget.onScanQr,
      _ProfileImportSource.imageQr => widget.onImportQrImage,
    };
    if (!mounted || _busy || !_canReveal || read == null) return;
    final epoch = ++_importEpoch;
    _clearInputSelection();
    setState(() {
      _importing = true;
      _importSource = source;
      _importCancelSent = false;
      _showConfig = false;
      _error = null;
      _notice = null;
      _clearImportFeedback();
    });
    try {
      final config = await read();
      if (!mounted || _closing || epoch != _importEpoch || config == null ||
          ModalRoute.of(context)?.isCurrent == false) return;
      if (_offerSubscription(config, source: switch (source) {
        _ProfileImportSource.file => SubscriptionDiagnosticSource.file,
        _ProfileImportSource.cameraQr => SubscriptionDiagnosticSource.cameraQr,
        _ProfileImportSource.imageQr => SubscriptionDiagnosticSource.imageQr,
      })) return;
      final validation = _validationError(config);
      if (validation != null) {
        _setImportFailure(validation.code, source,
            validationMessage: validation.message);
        return;
      }
      // Android may deliver the result before onResume. Only replace the masked
      // draft; never reveal, save, or connect after selecting a file or scanning a QR.
      _controller.value = TextEditingValue(text: config,
          selection: const TextSelection.collapsed(offset: -1));
      setState(() {
        _showConfig = false;
        _notice = source == _ProfileImportSource.file
            ? 'Файл прочитан. Сохраните профиль.'
            : 'QR-код прочитан. Сохраните профиль.';
      });
    } on PlatformException catch (error) {
      if (!mounted || _closing || epoch != _importEpoch) return;
      _setImportFailure(error.code, source);
    } catch (_) {
      if (mounted && !_closing && epoch == _importEpoch) {
        _setImportFailure(null, source);
      }
    } finally {
      if (mounted && !_closing && epoch == _importEpoch) {
        setState(() { _importing = false; _importSource = null; });
      }
    }
  }

  String _importError(String? code, _ProfileImportSource source) {
    final file = source == _ProfileImportSource.file;
    return switch (code) {
        'PROFILE_IMPORT_TOO_LARGE' =>
          file ? 'Файл слишком большой: максимум 65 536 байт.'
              : 'Профиль слишком большой: максимум 65 536 байт.',
        'PROFILE_IMPORT_INVALID' => file
            ? 'Нужен текстовый профиль WireGuard .conf.'
            : 'В QR-коде нет поддерживаемого профиля. Нужен WireGuard .conf.',
        'UNSUPPORTED_PROFILE' => _unsupportedProfile,
        'SUBSCRIPTION_URL_INVALID' =>
          'Для подписки нужна полная HTTPS-ссылка на публичный сервер, без логина и пароля в адресе. Проверьте ссылку в панели.',
        'PROFILE_TELEGRAM_LINK' =>
          'Это ссылка прокси Telegram. Она подключается внутри Telegram; для Flow нужен профиль WireGuard или HTTPS-ссылка на подписку WireGuard.',
        'PROFILE_VMESS_LINK' =>
          'Обнаружена ссылка VMess. Этот протокол пока не поддерживается в Flow. Импортируйте профиль WireGuard .conf.',
        'PROFILE_TROJAN_LINK' =>
          'Обнаружена ссылка Trojan. Этот протокол пока не поддерживается в Flow. Добавьте профиль WireGuard .conf.',
        'PROFILE_SHADOWSOCKS_LINK' =>
          'Обнаружена ссылка Shadowsocks или ShadowsocksR. Эти протоколы пока не поддерживаются в Flow. Добавьте профиль WireGuard .conf.',
        'UNSUPPORTED_TRANSPORT' => _unsupportedTransport,
        'UNSUPPORTED_SECURITY' => _unsupportedSecurity,
        'UNSUPPORTED_PROFILE_OPTION' => _unsupportedOption,
        'INVALID_VLESS_CONFIG' => _invalidVless,
        'PROFILE_IMPORT_BUSY' => file
            ? 'Выбор файла уже открыт. Завершите его и попробуйте ещё раз.'
            : 'Импорт профиля уже открыт. Завершите его и попробуйте ещё раз.',
        'PROFILE_IMPORT_SOURCE_BUSY' =>
          'Источник файлов пока занят. Попробуйте QR камерой или вставьте текст профиля.',
        'PROFILE_IMPORT_INTERRUPTED' => file
            ? 'Импорт прерван. Выберите файл ещё раз.'
            : 'Импорт прерван. Сканируйте QR-код или выберите фото ещё раз.',
        'PROFILE_IMPORT_TIMEOUT' =>
          'Источник файла не ответил вовремя. Повторите импорт или выберите файл из другого приложения.',
        'PROFILE_IMPORT_UNAVAILABLE' => file
            ? 'Не удалось открыть выбор файла. Вставьте конфигурацию вручную.'
            : 'Импорт QR сейчас недоступен. Выберите файл или вставьте конфигурацию либо ссылку.',
        'PROFILE_QR_CAMERA_DENIED' =>
          'Для сканирования нужен доступ к камере. Можно выбрать фото с QR-кодом.',
        'PROFILE_QR_UNAVAILABLE' =>
          'Сканирование QR недоступно. Выберите фото с QR-кодом или вставьте ссылку.',
        'PROFILE_QR_NOT_FOUND' =>
          'На изображении не найден QR-код. Выберите другое фото.',
        'PROFILE_QR_MULTIPLE' =>
          'Нужен один полный QR-код. Части составного кода и несколько кодов одновременно не поддерживаются.',
        'PROFILE_QR_IMAGE_TOO_LARGE' =>
          'Изображение слишком большое. Выберите уменьшенную копию или вставьте профиль.',
        _ => file
            ? 'Не удалось прочитать файл. Выберите его заново или вставьте конфигурацию.'
            : 'Не удалось прочитать QR-код. Повторите сканирование или вставьте профиль.',
      };
  }

  void _showImportHelp() {
    if (!mounted || _busy || !_canReveal) return;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Как добавить профиль'),
        scrollable: true,
        content: const Text(
          'Если QR содержит HTTPS-ссылку подписки, Flow предложит добавить её как подписку. '
          'Ссылка остаётся скрытой, а серверы загружаются только после нажатия «Добавить подписку». '
          'Можно вернуться к исходному черновику профиля без изменений.\n\n'
          'Если код открыт на другом устройстве, нажмите «Сканировать QR». '
          'Если он сохранён на этом телефоне, нажмите «QR из фото» и выберите изображение. '
          'Ссылку можно вставить кнопкой «Вставить» или импортировать из текстового файла.\n\n'
          'Для WireGuard нужен полный профиль .conf с разделами [Interface] и [Peer]. '
          'Подходит обычный QR WireGuard из WGDashboard, файл .conf или его полный текст. '
          'Профили Amnezia пока не поддерживаются.\n\n'
          'Распознавание выполняется на устройстве. Профиль сначала появляется '
          'как скрытый черновик: проверьте название и нажмите «Сохранить профиль» '
          'или «Сохранить и подключить». При переключении приложений текст скрывается.\n\n'
          'Редактор защищён от снимков и записи экрана: на видео он может выглядеть чёрным. '
          'Если импорт не удался, нажмите «Скопировать ошибку» и передайте текст для проверки. '
          'Конфигурация и ключи в него не входят.',
        ),
        actions: [TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Понятно'),
        )],
      ),
    );
  }

  Future<void> _save() async {
    if (!mounted || _busy || !_canReveal || _subscriptionDraft != null) return;
    setState(() {
      _error = null;
      _notice = null;
      _clearImportFeedback();
    });
    final config = _controller.text;
    final name = _nameController.text.trim();
    if (_offerSubscription(config)) return;
    if (!WireGuardProfiles.isValidName(name)) {
      setState(() => _error = 'Укажите название: от 1 до 64 символов без переносов строк.');
      return;
    }
    final validation = _validationError(config);
    if (validation != null) {
      setState(() => _error = validation.message);
      return;
    }
    _focusNode.unfocus();
    _nameFocusNode.unfocus();
    setState(() {
      _saving = true;
      _error = null;
      _notice = null;
    });
    try {
      await widget.onSave(config, name);
      if (!mounted || _closing) return;
      // An explicit completion can pop; PopScope only vetoes user back attempts.
      _complete(config);
    } on PlatformException catch (error) {
      if (!mounted || _closing) return;
      setState(() {
        _saving = false;
        // Platform messages/details can contain configuration data: use codes only.
        _error = switch (error.code) {
          'INVALID_CONFIG' =>
            'Некорректный профиль подключения. Проверьте конфигурацию или ссылку.',
          'INVALID_VLESS_CONFIG' => _invalidVless,
          'UNSUPPORTED_PROFILE' => _unsupportedProfile,
          'UNSUPPORTED_TRANSPORT' => _unsupportedTransport,
          'UNSUPPORTED_SECURITY' => _unsupportedSecurity,
          'UNSUPPORTED_PROFILE_OPTION' => _unsupportedOption,
          'PROFILE_SAVE_FAILED' =>
            'Не удалось сохранить профиль. Проверьте конфигурацию и попробуйте снова.',
          'PROFILE_NAME_INVALID' =>
            'Укажите название: от 1 до 64 символов без переносов строк.',
          'PROFILE_LIMIT_REACHED' =>
            'Можно сохранить до 20 профилей. Удалите ненужный и попробуйте снова.',
          'PROFILE_NOT_FOUND' =>
            'Этот профиль уже недоступен. Закройте редактор и обновите список.',
          'VPN_ACTIVE' =>
            'Для изменения профилей сначала отключите туннель.',
          'PROFILE_STORE_UNAVAILABLE' =>
            'Не удалось записать профили. Перезапустите приложение перед повторной попыткой.',
          _ => 'Не удалось сохранить профиль. Попробуйте ещё раз.',
        };
      });
    } catch (_) {
      if (!mounted || _closing) return;
      setState(() {
        _saving = false;
        _error = 'Не удалось сохранить профиль. Попробуйте ещё раз.';
      });
    }
  }

  void _toggleVisibility() {
    // A previously queued tap must not reveal a profile after the app left
    // the foreground, even if the button has not rebuilt yet.
    if (!mounted || _busy || !_canReveal) return;
    setState(() => _showConfig = !_showConfig);
    if (!_showConfig) _clearInputSelection();
  }

  @override
  Widget build(BuildContext context) {
    if (_editingSubscription && _subscriptionDraft != null &&
        widget.onSaveSubscription != null) {
      return SubscriptionEditor(
        key: const Key('profile_subscription_editor'),
        draft: _subscriptionDraft,
        initialSource: _subscriptionSource,
        onSave: (url, name) async {
          if (!mounted || !_editingSubscription || !_canReveal) {
            throw PlatformException(code: 'SUBSCRIPTION_INTERRUPTED');
          }
          await widget.onSaveSubscription!(url, name);
        },
        onClose: () {
          if (mounted && !_closing && _canReveal) {
            setState(() => _editingSubscription = false);
          }
        },
        onCompleted: () {
          if (!mounted || _closing || !_editingSubscription) return;
          widget.onSubscriptionSaved?.call();
          _complete();
        },
      );
    }
    final importFailure = _importFailure;
    return PopScope<Object?>(
      canPop: !_saving && !_closing && widget.onClose == null,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          _beginClosing();
        } else if (widget.onClose != null) {
          _closeEditor();
        }
      },
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: Container(
          decoration: BoxDecoration(
            color: PushokPalette.midnight,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border.all(color: PushokPalette.glowCyan.withValues(alpha: .45)),
          ),
          // ModalBottomSheetRoute's safe area does not include the bottom edge.
          child: SafeArea(
            top: false,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    const Expanded(child: Text('Профиль подключения',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800))),
                    IconButton(
                      key: const Key('info_wireguard_profile'),
                      tooltip: 'Как добавить профиль',
                      onPressed: _busy || !_canReveal ? null : _showImportHelp,
                      icon: const Icon(Icons.info_outline),
                    ),
                    IconButton(
                      key: const Key('close_wireguard_profile'),
                      tooltip: widget.onClose == null ? 'Закрыть' : 'Вернуться к подписке',
                      onPressed: _saving || _pasting || _closing || !_canReveal
                          ? null : _closeEditor,
                      icon: Icon(widget.onClose == null ? Icons.close : Icons.arrow_back),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  const Text('WireGuard .conf или HTTPS-ссылка подписки WireGuard: используйте QR-код, файл или буфер обмена. '
                    'Профиль сохраняется только на этом устройстве.',
                    style: TextStyle(color: PushokPalette.muted)),
                  const SizedBox(height: 8),
                  const Text('При переключении приложений профиль скрывается.',
                    style: TextStyle(color: PushokPalette.muted, fontSize: 12)),
                  const SizedBox(height: 16),
                  TextField(
                    key: const Key('wireguard_profile_name'),
                    controller: _nameController,
                    focusNode: _nameFocusNode,
                    enabled: !_busy && _canReveal,
                    maxLines: 1,
                    keyboardType: TextInputType.text,
                    textInputAction: TextInputAction.done,
                    autofillHints: null,
                    autocorrect: false,
                    enableSuggestions: false,
                    enableIMEPersonalizedLearning: false,
                    smartDashesType: SmartDashesType.disabled,
                    smartQuotesType: SmartQuotesType.disabled,
                    onChanged: (_) {
                      if (_error != null) {
                        setState(() {
                          _error = null;
                          _clearImportFeedback();
                        });
                      }
                    },
                    decoration: const InputDecoration(
                      labelText: 'Название профиля',
                      helperText: 'До 64 символов, например «Дом» или «Работа».',
                      helperMaxLines: 2,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    key: const Key('wireguard_profile_field'),
                    controller: _controller,
                    focusNode: _focusNode,
                    enabled: !_busy && _canReveal,
                    // A masked field must be single-line. Keyboard edits there
                    // would remove every newline from a WireGuard configuration.
                    // Explicit paste assigns the controller without that formatter.
                    readOnly: !_showConfig,
                    obscureText: !_showConfig,
                    maxLines: _showConfig ? 6 : 1,
                    keyboardType: TextInputType.multiline,
                    textInputAction: _showConfig
                        ? TextInputAction.newline : TextInputAction.done,
                    enableInteractiveSelection: _showConfig,
                    autofillHints: null,
                    autocorrect: false,
                    enableSuggestions: false,
                    enableIMEPersonalizedLearning: false,
                    smartDashesType: SmartDashesType.disabled,
                    smartQuotesType: SmartQuotesType.disabled,
                    onChanged: (_) {
                      if (_error != null || _notice != null) {
                        setState(() {
                          _error = null;
                          _notice = null;
                          _clearImportFeedback();
                        });
                      }
                    },
                    decoration: InputDecoration(
                      labelText: 'Конфигурация или ссылка',
                      helperText: _showConfig ? null
                          : 'Добавьте профиль кнопками ниже или откройте его значком глаза.',
                      helperMaxLines: 2,
                      suffixIcon: IconButton(
                        key: const Key('toggle_wireguard_profile_visibility'),
                        tooltip: _showConfig ? 'Скрыть конфигурацию' : 'Показать конфигурацию',
                        onPressed: _busy || !_canReveal ? null : _toggleVisibility,
                        icon: Icon(_showConfig
                            ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 8,
                    runSpacing: 8,
                    children: [OutlinedButton.icon(
                      key: const Key('paste_wireguard_profile'),
                      onPressed: _busy || !_canReveal ? null : _paste,
                      icon: _pasting
                          ? const SizedBox(width: 18, height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.content_paste_outlined),
                      label: const Text('Вставить'),
                    ),
                    if (widget.onImport != null) OutlinedButton.icon(
                      key: const Key('import_wireguard_profile'),
                      onPressed: _busy || !_canReveal
                          ? null : () => _import(_ProfileImportSource.file),
                      icon: _importing && _importSource == _ProfileImportSource.file
                          ? const SizedBox(width: 18, height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.file_open_outlined),
                      label: const Text('Из файла'),
                    ),
                    if (widget.onScanQr != null) OutlinedButton.icon(
                      key: const Key('scan_wireguard_profile_qr'),
                      onPressed: _busy || !_canReveal
                          ? null : () => _import(_ProfileImportSource.cameraQr),
                      icon: _importing && _importSource == _ProfileImportSource.cameraQr
                          ? const SizedBox(width: 18, height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.qr_code_scanner),
                      label: const Text('Сканировать QR'),
                    ),
                    if (widget.onImportQrImage != null) OutlinedButton.icon(
                      key: const Key('import_wireguard_profile_qr_image'),
                      onPressed: _busy || !_canReveal
                          ? null : () => _import(_ProfileImportSource.imageQr),
                      icon: _importing && _importSource == _ProfileImportSource.imageQr
                          ? const SizedBox(width: 18, height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.image_outlined),
                      label: const Text('QR из фото'),
                    ),
                    ],
                  ),
                  if (_notice != null) ...[
                    const SizedBox(height: 12),
                    Semantics(liveRegion: true,
                      child: Text(_notice!, key: const Key('wireguard_profile_notice'),
                        style: const TextStyle(color: PushokPalette.mint))),
                  ],
                  if (_subscriptionDraft != null && widget.onSaveSubscription != null) ...[
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      key: const Key('open_imported_subscription'),
                      onPressed: _busy || !_canReveal ? null : _openSubscription,
                      icon: const Icon(Icons.add_link),
                      label: const Text('Добавить как подписку'),
                    ),
                    TextButton(
                      key: const Key('discard_imported_subscription'),
                      onPressed: _busy || !_canReveal ? null : _discardSubscription,
                      child: const Text('Отменить импорт ссылки'),
                    ),
                    const SizedBox(height: 6),
                    const Text('Исходный черновик профиля остаётся на этом экране. Серверы ещё не загружались.',
                      style: TextStyle(color: PushokPalette.muted, fontSize: 12)),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Semantics(
                      liveRegion: true,
                      child: Text(_error!,
                        key: const Key('wireguard_profile_error'),
                        style: const TextStyle(color: PushokPalette.orange)),
                    ),
                    if (importFailure != null) ...[
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          key: const Key('copy_profile_import_error'),
                          onPressed: _busy || _copyingImportError || !_canReveal
                              ? null : () => _copyImportError(importFailure),
                          icon: _copyingImportError
                              ? const SizedBox(width: 18, height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.copy_outlined),
                          label: const Text('Скопировать ошибку'),
                        ),
                      ),
                      if (_importCopyNotice != null) Semantics(
                        liveRegion: true,
                        child: Text(_importCopyNotice!,
                          key: const Key('profile_import_copy_notice'),
                          style: const TextStyle(color: PushokPalette.muted, fontSize: 12)),
                      ),
                    ],
                  ],
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    key: const Key('save_wireguard_profile'),
                    onPressed: _busy || !_canReveal || _subscriptionDraft != null ? null : _save,
                    icon: _saving
                        ? const SizedBox(width: 18, height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : Icon(widget.connectAfterSave
                            ? Icons.power_settings_new : Icons.save_outlined),
                    label: Text(widget.connectAfterSave
                        ? 'Сохранить и подключить' : 'Сохранить профиль'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
