import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../design/pushok_theme.dart';

/// Edits a local draft and returns it only after the caller saves it successfully.
class WireGuardProfileEditor extends StatefulWidget {
  const WireGuardProfileEditor({
    super.key,
    required this.initialConfig,
    required this.onSave,
    this.connectAfterSave = false,
    this.initialError,
  });

  final String initialConfig;
  final Future<void> Function(String) onSave;
  final bool connectAfterSave;
  final String? initialError;

  @override
  State<WireGuardProfileEditor> createState() => _WireGuardProfileEditorState();
}

class _WireGuardProfileEditorState extends State<WireGuardProfileEditor> {
  static const _maxConfigLength = 65536;
  late final TextEditingController _controller;
  bool _showConfig = false;
  bool _saving = false;
  bool _pasting = false;
  String? _error;

  bool get _busy => _saving || _pasting;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialConfig);
    _error = widget.initialError;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
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
    if (_busy) return;
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
      setState(() => _error = null);
    } catch (_) {
      if (mounted) {
        setState(() => _error =
            'Не удалось прочитать буфер обмена. Введите конфигурацию вручную.');
      }
    } finally {
      if (mounted) setState(() => _pasting = false);
    }
  }

  Future<void> _save() async {
    if (_busy) return;
    final config = _controller.text;
    final validation = _validationError(config);
    if (validation != null) {
      setState(() => _error = validation);
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _saving = true;
      _error = null;
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
    if (_busy) return;
    if (_showConfig) FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _showConfig = !_showConfig);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<String>(
      canPop: !_saving,
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
                      onPressed: _busy ? null : () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ]),
                  const SizedBox(height: 8),
                const Text('Вставьте полный текст файла .conf от вашего VPN-провайдера '
                  'с разделами [Interface] и [Peer]. '
                    'Профиль сохраняется только на этом устройстве.',
                    style: TextStyle(color: PushokPalette.muted)),
                  const SizedBox(height: 16),
                  TextField(
                    key: const Key('wireguard_profile_field'),
                    controller: _controller,
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
                    autocorrect: false,
                    enableSuggestions: false,
                    enableIMEPersonalizedLearning: false,
                    smartDashesType: SmartDashesType.disabled,
                    smartQuotesType: SmartQuotesType.disabled,
                    onChanged: (_) {
                      if (_error != null) setState(() => _error = null);
                    },
                    decoration: InputDecoration(
                      labelText: 'Конфигурация WireGuard',
                      helperText: _showConfig ? null
                          : 'Вставьте профиль кнопкой ниже или откройте его значком глаза.',
                      helperMaxLines: 2,
                      suffixIcon: IconButton(
                        key: const Key('toggle_wireguard_profile_visibility'),
                        tooltip: _showConfig ? 'Скрыть конфигурацию' : 'Показать конфигурацию',
                        onPressed: _busy ? null : _toggleVisibility,
                        icon: Icon(_showConfig
                            ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      key: const Key('paste_wireguard_profile'),
                      onPressed: _busy ? null : _paste,
                      icon: _pasting
                          ? const SizedBox(width: 18, height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.content_paste_outlined),
                      label: const Text('Вставить'),
                    ),
                  ),
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
                    onPressed: _busy ? null : _save,
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
