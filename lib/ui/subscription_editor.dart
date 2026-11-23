import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../design/pushok_theme.dart';
import '../platform/subscription_diagnostics.dart';
import '../platform/subscriptions.dart';
import '../platform/wireguard_profiles.dart';
import 'subscription_diagnostic_copy.dart';

enum _SubscriptionQrSource { camera, image }

/// Transient credentials stay in memory and are never part of UI feedback.
class _ImportedProfileDraft {
  const _ImportedProfileDraft(this.config);
  final String config;
}

/// The caller owns a ProfilePrivacy lease for this route and its closing frame.
class SubscriptionEditor extends StatefulWidget {
  const SubscriptionEditor({super.key, this.draft,
    this.initialSource = SubscriptionDiagnosticSource.manualInput,
    required this.onSave, this.onClose, this.onCompleted,
    this.onScanQr, this.onImportQrImage, this.onCancelImport,
    this.profileEditorBuilder});
  final SubscriptionDraft? draft;
  final SubscriptionDiagnosticSource initialSource;
  final Future<void> Function(String url, String name) onSave;
  final Future<String?> Function()? onScanQr;
  final Future<String?> Function()? onImportQrImage;
  final Future<void> Function()? onCancelImport;
  /// Inline import keeps the original profile draft in the same protected route.
  final VoidCallback? onClose;
  final VoidCallback? onCompleted;
  /// Opens only after an explicit choice, within this same protected route.
  final Widget Function(String config, VoidCallback onClose,
      VoidCallback onCompleted)? profileEditorBuilder;

  @override
  State<SubscriptionEditor> createState() => _SubscriptionEditorState();
}

class _SubscriptionEditorState extends State<SubscriptionEditor>
    with WidgetsBindingObserver {
  late final TextEditingController _url;
  late final TextEditingController _name;
  final _urlFocus = FocusNode();
  final _nameFocus = FocusNode();
  bool _visible = false;
  bool _saving = false;
  bool _pasting = false;
  bool _importing = false;
  bool _importCancelSent = false;
  bool _clearSelectionAfterUnfocus = false;
  _SubscriptionQrSource? _importSource;
  bool _closing = false;
  bool _foreground = true;
  int _inputEpoch = 0;
  int _importEpoch = 0;
  String? _error;
  String? _notice;
  SubscriptionDiagnostic? _diagnostic;
  _ImportedProfileDraft? _profileDraft;
  _ImportedProfileDraft? _editingProfile;
  int _profileActionEpoch = 0;
  late SubscriptionDiagnosticSource _inputSource;
  bool get _busy => _saving || _pasting || _importing || _closing ||
      _editingProfile != null;
  bool get _canAct {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    return _foreground &&
        (lifecycle == null || lifecycle == AppLifecycleState.resumed) &&
        ModalRoute.of(context)?.isCurrent != false;
  }

  @override
  void initState() {
    super.initState();
    _url = TextEditingController(text: widget.draft?.url ?? '');
    _name = TextEditingController(text: widget.draft?.name ?? 'Моя подписка');
    _inputSource = widget.initialSource;
    _urlFocus.addListener(_finishInputCleanup);
    _nameFocus.addListener(_finishInputCleanup);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    _cancelPendingImport();
    _inputEpoch++;
    _profileActionEpoch++;
    WidgetsBinding.instance.removeObserver(this);
    _urlFocus.removeListener(_finishInputCleanup);
    _nameFocus.removeListener(_finishInputCleanup);
    _url.dispose();
    _name.dispose();
    _urlFocus.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    final foreground = state == AppLifecycleState.resumed;
    setState(() {
      _foreground = foreground;
      _profileActionEpoch++;
      if (!foreground) {
        _visible = false;
        _inputEpoch++;
      }
    });
    if (!foreground) _clearInputSelection();
  }

  void _clearInputSelection() {
    _clearSelectionAfterUnfocus = true;
    _urlFocus.unfocus();
    _nameFocus.unfocus();
    _url.clearComposing();
    _name.clearComposing();
    _finishInputCleanup();
  }

  void _finishInputCleanup() {
    if (!mounted || !_clearSelectionAfterUnfocus ||
        _urlFocus.hasFocus || _nameFocus.hasFocus) return;
    _clearSelectionAfterUnfocus = false;
    // EditableText can repair the selection while an unfocus is still pending.
    for (final controller in [_url, _name]) {
      controller.value = controller.value.copyWith(
        selection: const TextSelection.collapsed(offset: -1),
        composing: TextRange.empty);
    }
  }

  void _clearFeedback() {
    _error = null;
    _notice = null;
    _diagnostic = null;
    _profileDraft = null;
    _profileActionEpoch++;
  }

  void _setFailure(String? code, String message, {SubscriptionDiagnosticSource? source}) {
    setState(() {
      _clearFeedback();
      _error = message;
      _notice = null;
      _diagnostic = SubscriptionDiagnostic.fromCode(code,
        operation: SubscriptionDiagnosticOperation.addSubscription,
        source: source ?? _inputSource);
    });
  }

  bool _isProfileCandidate(String text) {
    if (text.length > 65536) return false;
    final trimmed = text.trim();
    final scheme = RegExp(r'^([A-Za-z][A-Za-z0-9+.-]*)://')
        .firstMatch(trimmed)?.group(1)?.toLowerCase();
    if (scheme != null) return scheme == 'vless';
    return RegExp(r'^\[Interface\]\s*$', multiLine: true).hasMatch(trimmed);
  }

  bool _offerProfile(String config) {
    if (widget.profileEditorBuilder == null || !_isProfileCandidate(config)) return false;
    _clearInputSelection();
    setState(() {
      _clearFeedback();
      _visible = false;
      _profileDraft = _ImportedProfileDraft(config);
      _notice = 'Найдено отдельное подключение. Открыть редактор профиля?';
    });
    return true;
  }

  void _openProfile(_ImportedProfileDraft draft, int epoch) {
    if (!mounted || _busy || !_canAct || epoch != _profileActionEpoch ||
        !identical(_profileDraft, draft) || widget.profileEditorBuilder == null) return;
    _clearInputSelection();
    // Reopening the same offer creates a new child session. A callback captured
    // by the earlier child must not close or complete the newly opened editor.
    setState(() {
      _visible = false;
      _editingProfile = _ImportedProfileDraft(draft.config);
    });
  }

  void _discardProfile(_ImportedProfileDraft draft, int epoch) {
    if (!mounted || _busy || !_canAct || epoch != _profileActionEpoch ||
        !identical(_profileDraft, draft)) return;
    setState(_clearFeedback);
  }

  void _complete() {
    if (!mounted || _closing) return;
    _closing = true;
    _inputEpoch++;
    _profileActionEpoch++;
    _profileDraft = null;
    _editingProfile = null;
    _visible = false;
    if (widget.onCompleted != null) {
      widget.onCompleted!();
    } else {
      Navigator.of(context).pop<bool>(true);
    }
  }

  Future<void> _paste() async {
    if (!mounted || _busy || !_canAct) return;
    final epoch = _inputEpoch;
    setState(() { _pasting = true; _clearFeedback(); });
    try {
      final value = await Clipboard.getData(Clipboard.kTextPlain);
      if (!mounted || _closing || !_canAct || epoch != _inputEpoch) return;
      final raw = value?.text;
      final text = raw?.trim();
      if (text == null || text.isEmpty) {
        _setFailure('SUBSCRIPTION_CLIPBOARD_EMPTY', 'В буфере обмена нет ссылки подписки.',
          source: SubscriptionDiagnosticSource.clipboard);
      } else if (_offerProfile(raw!)) {
        return;
      } else if (!SubscriptionDraft.validUrl(text)) {
        _setFailure('SUBSCRIPTION_URL_INVALID', 'Скопируйте полную HTTPS-ссылку подписки.',
          source: SubscriptionDiagnosticSource.clipboard);
      } else {
        setState(() { _url.text = text; _inputSource = SubscriptionDiagnosticSource.clipboard; });
      }
    } catch (_) {
      if (mounted && !_closing && _canAct && epoch == _inputEpoch) {
        _setFailure('SUBSCRIPTION_CLIPBOARD_UNAVAILABLE', 'Не удалось прочитать буфер обмена.',
          source: SubscriptionDiagnosticSource.clipboard);
      }
    } finally {
      if (mounted) setState(() => _pasting = false);
    }
  }

  void _cancelPendingImport() {
    if (!_importing || _importCancelSent) return;
    _importCancelSent = true;
    _importEpoch++;
    // Invalidate before the route's closing animation can receive a native reply.
    unawaited(_cancelImport());
  }

  Future<void> _cancelImport() async {
    try {
      await widget.onCancelImport?.call();
    } catch (_) {
      // The local epoch also rejects late results if native cancellation fails.
    }
  }

  Future<void> _importQr(_SubscriptionQrSource source) async {
    final diagnosticSource = source == _SubscriptionQrSource.camera
        ? SubscriptionDiagnosticSource.cameraQr : SubscriptionDiagnosticSource.imageQr;
    final read = source == _SubscriptionQrSource.camera
        ? widget.onScanQr : widget.onImportQrImage;
    if (!mounted || _busy || !_canAct || read == null) return;
    final epoch = ++_importEpoch;
    _clearInputSelection();
    setState(() {
      _importing = true;
      _importSource = source;
      _importCancelSent = false;
      _visible = false;
      _clearFeedback();
    });
    try {
      final value = await read();
      if (!mounted || _closing || epoch != _importEpoch || value == null ||
          ModalRoute.of(context)?.isCurrent == false) return;
      final url = value.trim();
      final uri = url.length <= 4096 ? Uri.tryParse(url) : null;
      if (uri != null &&
          const {'t.me', 'telegram.me', 'www.t.me', 'www.telegram.me'}
              .contains(uri.host.toLowerCase()) &&
          const {'/proxy', '/socks'}.contains(uri.path)) {
        _setFailure('PROFILE_TELEGRAM_LINK', _qrError('PROFILE_TELEGRAM_LINK', source),
          source: diagnosticSource);
        return;
      }
      if (!SubscriptionDraft.validUrl(url)) {
        if (_offerProfile(value)) return;
        final profile = _isProfileCandidate(value);
        _setFailure(profile ? 'UNSUPPORTED_PROFILE' : 'SUBSCRIPTION_URL_INVALID', profile
            ? 'Это QR-код отдельного подключения. Добавьте его через '
              '«Серверы → Профили подключения → Добавить профиль». '
              'Для подписки нужен QR с HTTPS-ссылкой.'
            : _qrError('SUBSCRIPTION_URL_INVALID', source), source: diagnosticSource);
        return;
      }
      // Android can return the QR before onResume. Only fill the masked draft;
      // importing servers always requires a later, explicit foreground action.
      _url.value = TextEditingValue(text: url,
        selection: const TextSelection.collapsed(offset: -1));
      setState(() {
        _visible = false;
        _inputSource = diagnosticSource;
        _notice = 'QR-код прочитан. Проверьте название и нажмите «Добавить подписку».';
      });
    } on PlatformException catch (error) {
      if (mounted && !_closing && epoch == _importEpoch) {
        _setFailure(error.code, _qrError(error.code, source), source: diagnosticSource);
      }
    } catch (_) {
      if (mounted && !_closing && epoch == _importEpoch) {
        _setFailure(null, _qrError(null, source), source: diagnosticSource);
      }
    } finally {
      if (mounted && !_closing && epoch == _importEpoch) {
        setState(() { _importing = false; _importSource = null; });
      }
    }
  }

  String _qrError(String? code, _SubscriptionQrSource source) => switch (code) {
    'PROFILE_QR_CAMERA_DENIED' =>
      'Для сканирования нужен доступ к камере. Можно выбрать фото с QR-кодом.',
    'PROFILE_QR_UNAVAILABLE' || 'PROFILE_IMPORT_UNAVAILABLE' =>
      'Импорт QR сейчас недоступен. Вставьте HTTPS-ссылку подписки.',
    'PROFILE_QR_NOT_FOUND' => source == _SubscriptionQrSource.image
      ? 'На изображении не найден QR-код. Выберите другое фото.'
      : 'QR-код не найден. Повторите сканирование или выберите фото.',
    'PROFILE_QR_MULTIPLE' =>
      'Нужен один полный QR-код. Части составного кода и несколько кодов одновременно не поддерживаются.',
    'PROFILE_QR_IMAGE_TOO_LARGE' =>
      'Изображение слишком большое. Выберите уменьшенную копию или вставьте ссылку подписки.',
    'PROFILE_IMPORT_BUSY' =>
      'Импорт QR уже открыт. Завершите его и попробуйте ещё раз.',
    'PROFILE_IMPORT_SOURCE_BUSY' =>
      'Источник фото пока занят. Попробуйте сканирование камерой или вставьте ссылку подписки.',
    'PROFILE_IMPORT_INTERRUPTED' =>
      'Импорт прерван. Сканируйте QR-код или выберите фото ещё раз.',
    'PROFILE_IMPORT_TIMEOUT' =>
      'Источник QR не ответил вовремя. Повторите импорт или вставьте ссылку подписки.',
    'PROFILE_IMPORT_TOO_LARGE' =>
      'QR-код содержит слишком много данных. Выберите QR подписки с одной HTTPS-ссылкой.',
    'SUBSCRIPTION_URL_INVALID' =>
      'Для подписки нужен QR с полной HTTPS-ссылкой на публичный сервер, без логина и пароля в адресе. Проверьте QR-код в панели.',
    'PROFILE_TELEGRAM_LINK' =>
      'Это ссылка прокси Telegram. Для подписки Flow нужен QR-код с HTTPS-ссылкой подписки.',
    'PROFILE_VMESS_LINK' || 'PROFILE_TROJAN_LINK' || 'PROFILE_SHADOWSOCKS_LINK' ||
    'UNSUPPORTED_TRANSPORT' || 'UNSUPPORTED_SECURITY' ||
    'UNSUPPORTED_PROFILE_OPTION' || 'INVALID_VLESS_CONFIG' =>
      'Это QR-код отдельного подключения. Для подписки нужен QR с HTTPS-ссылкой. Выберите QR подписки в панели.',
    'PROFILE_IMPORT_INVALID' || 'UNSUPPORTED_PROFILE' =>
      'В QR-коде нет HTTPS-ссылки подписки. Выберите QR подписки в панели или у провайдера.',
    _ => 'Не удалось прочитать QR-код. Повторите сканирование, выберите фото или вставьте ссылку подписки.',
  };

  Future<void> _save() async {
    if (!mounted || _busy || !_canAct || _profileDraft != null) return;
    final url = _url.text.trim();
    final name = _name.text.trim();
    if (_offerProfile(_url.text)) return;
    if (!WireGuardProfiles.isValidName(name)) {
      _setFailure('PROFILE_NAME_INVALID', 'Укажите название: от 1 до 64 символов.');
      return;
    }
    if (!SubscriptionDraft.validUrl(url)) {
      _setFailure('SUBSCRIPTION_URL_INVALID', 'Нужна полная HTTPS-ссылка подписки.');
      return;
    }
    _clearInputSelection();
    setState(() { _saving = true; _clearFeedback(); _visible = false; });
    try {
      await widget.onSave(url, name);
      if (!mounted || _closing) return;
      _complete();
    } catch (error) {
      if (mounted && !_closing) {
        _saving = false;
        _setFailure(error is PlatformException ? error.code : null,
          subscriptionErrorMessage(error));
      }
    }
  }

  void _closeEditor() {
    if (!mounted || _saving || _pasting || _closing ||
        _editingProfile != null || !_canAct) return;
    _closing = true;
    _inputEpoch++;
    _profileActionEpoch++;
    _profileDraft = null;
    _visible = false;
    _cancelPendingImport();
    _clearInputSelection();
    if (widget.onClose != null) {
      widget.onClose!();
    } else {
      Navigator.of(context).pop();
    }
  }

  void _toggleVisibility() {
    if (!mounted || _busy || !_canAct) return;
    setState(() => _visible = !_visible);
    if (!_visible) _clearInputSelection();
  }

  @override
  Widget build(BuildContext context) {
    final editing = _editingProfile;
    if (editing != null && widget.profileEditorBuilder != null) {
      return widget.profileEditorBuilder!(editing.config, () {
        if (!mounted || _closing || !_canAct ||
            !identical(_editingProfile, editing)) return;
        setState(() {
          _editingProfile = null;
          _profileActionEpoch++;
        });
      }, () {
        if (!mounted || _closing || !identical(_editingProfile, editing)) return;
        _complete();
      });
    }
    final diagnostic = _diagnostic;
    final profile = _profileDraft;
    final profileEpoch = _profileActionEpoch;
    final host = SubscriptionDraft.validUrl(_url.text.trim())
        ? Uri.parse(_url.text.trim()).host : null;
    return PopScope<Object?>(canPop: !_saving && !_closing && widget.onClose == null,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          _closing = true;
          _inputEpoch++;
          _profileActionEpoch++;
          _profileDraft = null;
          _visible = false;
          _cancelPendingImport();
        } else if (widget.onClose != null) {
          _closeEditor();
        }
      },
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SafeArea(top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            child: Column(mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  const Expanded(child: Text('Добавить подписку',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800))),
                  IconButton(key: const Key('close_subscription_editor'),
                    tooltip: widget.onClose == null ? 'Закрыть' : 'Вернуться к профилю',
                    onPressed: _saving || _pasting || _closing || !_canAct
                        ? null : _closeEditor,
                    icon: Icon(widget.onClose == null ? Icons.close : Icons.arrow_back)),
                ]),
                const SizedBox(height: 8),
                const Text('HTTPS-ссылка подписки от провайдера или из вашей панели.',
                  style: TextStyle(color: PushokPalette.muted)),
                const SizedBox(height: 16),
                TextField(key: const Key('subscription_name'), controller: _name,
                  focusNode: _nameFocus, enabled: !_busy && _canAct, maxLines: 1,
                  autocorrect: false, enableSuggestions: false,
                  enableIMEPersonalizedLearning: false, autofillHints: null,
                  onChanged: (_) => setState(_clearFeedback),
                  decoration: const InputDecoration(labelText: 'Название подписки')),
                const SizedBox(height: 16),
                TextField(key: const Key('subscription_url'), controller: _url,
                  focusNode: _urlFocus, enabled: !_busy && _canAct, maxLines: 1,
                  readOnly: !_visible, obscureText: !_visible,
                  enableInteractiveSelection: _visible, keyboardType: TextInputType.url,
                  autocorrect: false, enableSuggestions: false,
                  enableIMEPersonalizedLearning: false, autofillHints: null,
                  smartDashesType: SmartDashesType.disabled,
                  smartQuotesType: SmartQuotesType.disabled,
                  onChanged: (_) => setState(() {
                    _clearFeedback();
                    _inputSource = SubscriptionDiagnosticSource.manualInput;
                  }),
                  decoration: InputDecoration(labelText: 'HTTPS-ссылка подписки',
                    helperText: widget.onScanQr != null || widget.onImportQrImage != null
                        ? 'Добавьте QR, вставьте ссылку или откройте поле значком глаза.'
                        : 'Вставьте ссылку или откройте поле значком глаза.',
                    helperMaxLines: 2,
                    suffixIcon: IconButton(key: const Key('toggle_subscription_url_visibility'),
                      tooltip: _visible ? 'Скрыть ссылку' : 'Показать ссылку',
                      onPressed: _busy || !_canAct ? null : _toggleVisibility,
                      icon: Icon(_visible ? Icons.visibility_off_outlined : Icons.visibility_outlined)))),
                const SizedBox(height: 10),
                Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8,
                  children: [
                    if (widget.onScanQr != null) OutlinedButton.icon(
                      key: const Key('scan_subscription_qr'),
                      onPressed: _busy || !_canAct ? null
                          : () => _importQr(_SubscriptionQrSource.camera),
                      icon: const Icon(Icons.qr_code_scanner),
                      label: const Text('Сканировать QR')),
                    if (widget.onImportQrImage != null) OutlinedButton.icon(
                      key: const Key('import_subscription_qr_image'),
                      onPressed: _busy || !_canAct ? null
                          : () => _importQr(_SubscriptionQrSource.image),
                      icon: const Icon(Icons.image_outlined),
                      label: const Text('QR из фото')),
                    OutlinedButton.icon(key: const Key('paste_subscription_url'),
                      onPressed: _busy || !_canAct ? null : _paste,
                      icon: const Icon(Icons.content_paste_outlined),
                      label: const Text('Вставить')),
                  ]),
                if (_importing) ...[
                  const SizedBox(height: 12),
                  Row(key: const Key('subscription_qr_progress'), children: [
                    const SizedBox(width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 10),
                    Expanded(child: Text(_importSource == _SubscriptionQrSource.camera
                        ? 'Сканируем QR-код…' : 'Читаем QR из фото…')),
                  ]),
                ],
                if (host != null) ...[
                  const SizedBox(height: 10),
                  Text('Источник серверов: $host', key: const Key('subscription_source_host'),
                    style: const TextStyle(color: PushokPalette.muted)),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Semantics(liveRegion: true, child: Text(_error!,
                    key: const Key('subscription_editor_error'),
                    style: const TextStyle(color: PushokPalette.orange))),
                  if (diagnostic != null) SubscriptionDiagnosticCopy(
                    key: const Key('subscription_editor_diagnostic'),
                    diagnostic: diagnostic,
                    buttonKey: const Key('copy_subscription_error'),
                    noticeKey: const Key('subscription_error_copy_notice'),
                    enabled: !_busy && _canAct,
                    isCurrentError: () => mounted && !_busy && _canAct &&
                        identical(_diagnostic, diagnostic)),
                ],
                if (_notice != null) ...[
                  const SizedBox(height: 12),
                  Semantics(liveRegion: true, child: Text(_notice!,
                    key: const Key('subscription_editor_notice'),
                    style: const TextStyle(color: PushokPalette.mint))),
                ],
                if (profile != null && widget.profileEditorBuilder != null) ...[
                  const SizedBox(height: 10),
                  OutlinedButton.icon(key: const Key('open_imported_profile'),
                    onPressed: _busy || !_canAct ? null
                        : () => _openProfile(profile, profileEpoch),
                    icon: const Icon(Icons.add_circle_outline),
                    label: const Text('Добавить как профиль')),
                  TextButton(key: const Key('discard_imported_profile'),
                    onPressed: _busy || !_canAct ? null
                        : () => _discardProfile(profile, profileEpoch),
                    child: const Text('Отменить импорт профиля')),
                  const SizedBox(height: 6),
                  const Text('Черновик подписки сохранён. Профиль будет проверен при сохранении.',
                    style: TextStyle(color: PushokPalette.muted, fontSize: 12)),
                ],
                const SizedBox(height: 16),
                FilledButton.icon(key: const Key('save_subscription'),
                  onPressed: _busy || !_canAct || profile != null ? null : _save,
                  icon: _saving ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.add_link),
                  label: Text(_saving ? 'Загружаем серверы…' : 'Добавить подписку')),
                const SizedBox(height: 8),
                const Text('Подключение включается отдельно на главной.',
                  style: TextStyle(color: PushokPalette.muted, fontSize: 12)),
              ]),
          )),
      ));
  }
}
