import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../design/pushok_theme.dart';
import '../platform/wireguard_profiles.dart';

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
    this.connectAfterSave = false,
    this.initialError,
  });

  final String initialConfig;
  final String initialName;
  final Future<void> Function(String config, String name) onSave;
  final Future<String?> Function()? onImport;
  final Future<String?> Function()? onScanQr;
  final Future<String?> Function()? onImportQrImage;
  final Future<void> Function()? onCancelImport;
  final bool connectAfterSave;
  final String? initialError;

  @override
  State<WireGuardProfileEditor> createState() => _WireGuardProfileEditorState();
}

class _WireGuardProfileEditorState extends State<WireGuardProfileEditor>
    with WidgetsBindingObserver {
  static const _maxConfigLength = 65536;
  static const _unsupportedProfile =
      'Этот формат пока не поддерживается. Добавьте WireGuard .conf или ссылку VLESS из 3x-ui.';
  static const _unsupportedTransport =
      'Этот вариант VLESS пока не поддерживается. Нужен TCP (Raw) с TLS или REALITY либо WebSocket или gRPC с TLS.';
  static const _invalidVless =
      'Некорректная ссылка VLESS. Скопируйте полную ссылку клиента из 3x-ui.';
  static const _unsupportedSecurity =
      'Для VLESS нужен TLS с проверкой сертификата или REALITY. REALITY доступен только с TCP (Raw).';
  static const _unsupportedOption =
      'В ссылке VLESS есть параметры, которые пока не поддерживаются. Проверьте варианты подключения в подсказке ⓘ.';
  static const _safeImportCodes = {
    'PROFILE_IMPORT_TOO_LARGE',
    'PROFILE_IMPORT_INVALID',
    'PROFILE_IMPORT_BUSY',
    'PROFILE_IMPORT_INTERRUPTED',
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
  bool _resumed = true;
  String? _error;
  String? _notice;
  _ProfileImportFailure? _importFailure;
  bool _copyingImportError = false;
  String? _importCopyNotice;

  bool get _busy => _saving || _pasting || _importing;
  bool get _canReveal {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    return _resumed &&
        (lifecycle == null || lifecycle == AppLifecycleState.resumed);
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
      if (!resumed) _showConfig = false;
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
    if (scheme == 'http' || scheme == 'https') {
      return (code: 'UNSUPPORTED_PROFILE',
          message: 'Это ссылка подписки. Откройте «Серверы → Подписки → Добавить подписку».');
    }
    if (scheme != null && scheme != 'vless') {
      return (code: 'UNSUPPORTED_PROFILE', message: _unsupportedProfile);
    }
    return null;
  }

  void _clearImportFeedback() {
    _importFailure = null;
    _importCopyNotice = null;
  }

  void _setImportFailure(String? code, _ProfileImportSource source,
      {String? validationMessage}) {
    final safeCode = _safeImportCodes.contains(code) ? code! : 'PROFILE_IMPORT_FAILED';
    final message = validationMessage ?? _importError(safeCode, source);
    setState(() {
      _error = message;
      _notice = null;
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
    setState(() {
      _pasting = true;
      _error = null;
      _notice = null;
      _clearImportFeedback();
    });
    try {
      // Clipboard access happens only after the user presses «Вставить».
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (!mounted || _saving) return;
      final config = data?.text;
      if (config == null || config.trim().isEmpty) {
        setState(() => _error = 'В буфере обмена нет конфигурации.');
        return;
      }
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
      if (mounted) {
        setState(() => _error =
            'Не удалось прочитать буфер обмена. Введите конфигурацию вручную.');
      }
    } finally {
      if (mounted) setState(() => _pasting = false);
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
      if (!mounted || epoch != _importEpoch || config == null) return;
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
      if (!mounted || epoch != _importEpoch) return;
      _setImportFailure(error.code, source);
    } catch (_) {
      if (mounted && epoch == _importEpoch) {
        _setImportFailure(null, source);
      }
    } finally {
      if (mounted && epoch == _importEpoch) {
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
            ? 'Нужен текстовый профиль WireGuard .conf или полная ссылка VLESS из 3x-ui.'
            : 'В QR-коде нет поддерживаемого профиля. Нужен WireGuard .conf или полная ссылка VLESS.',
        'UNSUPPORTED_PROFILE' => _unsupportedProfile,
        'UNSUPPORTED_TRANSPORT' => _unsupportedTransport,
        'UNSUPPORTED_SECURITY' => _unsupportedSecurity,
        'UNSUPPORTED_PROFILE_OPTION' => _unsupportedOption,
        'INVALID_VLESS_CONFIG' => _invalidVless,
        'PROFILE_IMPORT_BUSY' => file
            ? 'Выбор файла уже открыт. Завершите его и попробуйте ещё раз.'
            : 'Импорт профиля уже открыт. Завершите его и попробуйте ещё раз.',
        'PROFILE_IMPORT_INTERRUPTED' => file
            ? 'Импорт прерван. Выберите файл ещё раз.'
            : 'Импорт прерван. Сканируйте QR-код или выберите фото ещё раз.',
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
          'Выберите изображение с одним полным QR-кодом профиля. Несколько или составные QR-коды не поддерживаются.',
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
          'В 3x-ui откройте нужного клиента и скопируйте его полную ссылку VLESS '
          'или откройте QR-код. Поддерживаются TCP (Raw) с TLS или REALITY, '
          'включая XTLS Vision. WebSocket и gRPC поддерживаются только с TLS, без Vision. '
          'Проверка сертификата TLS обязательна. REALITY доступен только с TCP (Raw). '
          'Другие протоколы, транспорты и ссылки подписки пока не поддерживаются.\n\n'
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
    if (!mounted || _busy || !_canReveal) return;
    setState(() {
      _error = null;
      _notice = null;
      _clearImportFeedback();
    });
    final config = _controller.text;
    final name = _nameController.text.trim();
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
      if (!mounted) return;
      // An explicit completion can pop; PopScope only vetoes user back attempts.
      Navigator.of(context).pop<String>(config);
    } on PlatformException catch (error) {
      if (!mounted) return;
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
      if (!mounted) return;
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
    final importFailure = _importFailure;
    return PopScope<String>(
      canPop: !_saving,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _cancelPendingImport();
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
                      tooltip: 'Закрыть',
                      onPressed: _saving || _pasting
                          ? null : () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  const Text('WireGuard .conf или VLESS из 3x-ui: добавьте профиль из QR-кода, файла или буфера обмена. '
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
                    enabled: !_busy,
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
                    enabled: !_busy,
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
                    onPressed: _busy || !_canReveal ? null : _save,
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
