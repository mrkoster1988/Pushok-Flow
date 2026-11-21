import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../design/pushok_theme.dart';

/// Edits a local draft and returns it only after the caller saves it successfully.
class WireGuardProfileEditor extends StatefulWidget {
  const WireGuardProfileEditor({
    super.key,
    required this.initialConfig,
    required this.onSave,
    this.onImport,
    this.onCancelImport,
    this.connectAfterSave = false,
    this.initialError,
  });

  final String initialConfig;
  final Future<void> Function(String) onSave;
  final Future<String?> Function()? onImport;
  final Future<void> Function()? onCancelImport;
  final bool connectAfterSave;
  final String? initialError;

  @override
  State<WireGuardProfileEditor> createState() => _WireGuardProfileEditorState();
}

class _WireGuardProfileEditorState extends State<WireGuardProfileEditor>
    with WidgetsBindingObserver {
  static const _maxConfigLength = 65536;
  late final TextEditingController _controller;
  final FocusNode _focusNode = FocusNode();
  bool _showConfig = false;
  bool _saving = false;
  bool _pasting = false;
  bool _importing = false;
  bool _importCancelSent = false;
  int _importEpoch = 0;
  bool _resumed = true;
  String? _error;
  String? _notice;

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
    _controller.dispose();
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
    _focusNode.unfocus();
    // Clear only input state. The complete multiline draft must remain intact.
    _controller.value = _controller.value.copyWith(
      selection: const TextSelection.collapsed(offset: -1),
      composing: TextRange.empty,
    );
  }

  String? _validationError(String config) {
    if (config.trim().isEmpty) {
      return 'Вставьте конфигурацию WireGuard перед сохранением.';
    }
    if (config.length > _maxConfigLength) {
      return 'Профиль слишком большой: максимум 65 536 символов.';
    }
    if (RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
        r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$').hasMatch(config.trim())) {
      return 'Вставлен UUID. Для WireGuard нужен полный текст файла .conf '
          'с разделами [Interface] и [Peer].';
    }
    return null;
  }

  Future<void> _paste() async {
    if (!mounted || _busy || !_canReveal) return;
    setState(() => _pasting = true);
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
        setState(() => _error = validation);
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

  Future<void> _import() async {
    final read = widget.onImport;
    if (!mounted || _busy || !_canReveal || read == null) return;
    final epoch = ++_importEpoch;
    _clearInputSelection();
    setState(() {
      _importing = true;
      _importCancelSent = false;
      _showConfig = false;
      _error = null;
      _notice = null;
    });
    try {
      final config = await read();
      if (!mounted || epoch != _importEpoch || config == null) return;
      final validation = _validationError(config);
      if (validation != null) {
        setState(() => _error = validation);
        return;
      }
      // Android may deliver the result before onResume. Only replace the masked
      // draft; never reveal, save, or connect as a consequence of selecting a file.
      _controller.value = TextEditingValue(text: config,
          selection: const TextSelection.collapsed(offset: -1));
      setState(() {
        _showConfig = false;
        _notice = 'Файл прочитан. Сохраните профиль.';
      });
    } on PlatformException catch (error) {
      if (!mounted || epoch != _importEpoch) return;
      setState(() => _error = switch (error.code) {
        'PROFILE_IMPORT_TOO_LARGE' =>
          'Файл слишком большой: максимум 65 536 байт.',
        'PROFILE_IMPORT_INVALID' =>
          'Нужен полный текстовый профиль WireGuard .conf с разделами [Interface] и [Peer].',
        'PROFILE_IMPORT_BUSY' =>
          'Выбор файла уже открыт. Завершите его и попробуйте ещё раз.',
        'PROFILE_IMPORT_INTERRUPTED' =>
          'Импорт прерван. Выберите файл ещё раз.',
        'PROFILE_IMPORT_UNAVAILABLE' =>
          'Не удалось открыть выбор файла. Вставьте конфигурацию вручную.',
        _ => 'Не удалось прочитать файл. Выберите его заново или вставьте конфигурацию.',
      });
    } catch (_) {
      if (mounted && epoch == _importEpoch) {
        setState(() => _error =
            'Не удалось прочитать файл. Выберите его заново или вставьте конфигурацию.');
      }
    } finally {
      if (mounted && epoch == _importEpoch) setState(() => _importing = false);
    }
  }

  Future<void> _save() async {
    if (!mounted || _busy || !_canReveal) return;
    final config = _controller.text;
    final validation = _validationError(config);
    if (validation != null) {
      setState(() => _error = validation);
      return;
    }
    _focusNode.unfocus();
    setState(() {
      _saving = true;
      _error = null;
      _notice = null;
    });
    try {
      await widget.onSave(config);
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
            'Некорректный профиль WireGuard. Проверьте конфигурацию.',
          'PROFILE_SAVE_FAILED' =>
            'Не удалось сохранить профиль. Проверьте конфигурацию и попробуйте снова.',
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
                    const Expanded(child: Text('Профиль WireGuard',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800))),
                    IconButton(
                      key: const Key('close_wireguard_profile'),
                      tooltip: 'Закрыть',
                      onPressed: _saving || _pasting
                          ? null : () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  const Text('Выберите файл .conf или вставьте полный текст профиля от вашего VPN-провайдера '
                    'с разделами [Interface] и [Peer]. '
                    'Профиль сохраняется только на этом устройстве.',
                    style: TextStyle(color: PushokPalette.muted)),
                  const SizedBox(height: 8),
                  const Text('При переключении приложений профиль скрывается.',
                    style: TextStyle(color: PushokPalette.muted, fontSize: 12)),
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
                        setState(() { _error = null; _notice = null; });
                      }
                    },
                    decoration: InputDecoration(
                      labelText: 'Конфигурация WireGuard',
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
                      onPressed: _busy || !_canReveal ? null : _import,
                      icon: _importing
                          ? const SizedBox(width: 18, height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.file_open_outlined),
                      label: const Text('Из файла .conf'),
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
