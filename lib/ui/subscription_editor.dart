import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../design/pushok_theme.dart';
import '../platform/subscriptions.dart';
import '../platform/wireguard_profiles.dart';

/// The caller owns a ProfilePrivacy lease for this route and its closing frame.
class SubscriptionEditor extends StatefulWidget {
  const SubscriptionEditor({super.key, this.draft,
    required this.onSave, this.onClose, this.onCompleted});
  final SubscriptionDraft? draft;
  final Future<void> Function(String url, String name) onSave;
  /// Inline import keeps the original profile draft in the same protected route.
  final VoidCallback? onClose;
  final VoidCallback? onCompleted;

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
  bool _closing = false;
  bool _foreground = true;
  int _inputEpoch = 0;
  String? _error;
  bool get _busy => _saving || _pasting || _closing;

  @override
  void initState() {
    super.initState();
    _url = TextEditingController(text: widget.draft?.url ?? '');
    _name = TextEditingController(text: widget.draft?.name ?? 'Моя подписка');
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    _inputEpoch++;
    WidgetsBinding.instance.removeObserver(this);
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
      if (!foreground) {
        _visible = false;
        _inputEpoch++;
      }
    });
    if (!foreground) {
      _urlFocus.unfocus();
      _nameFocus.unfocus();
      for (final controller in [_url, _name]) {
        controller.value = controller.value.copyWith(
          selection: const TextSelection.collapsed(offset: -1),
          composing: TextRange.empty);
      }
    }
  }

  Future<void> _paste() async {
    if (!mounted || _busy || !_foreground) return;
    final epoch = _inputEpoch;
    setState(() { _pasting = true; _error = null; });
    try {
      final value = await Clipboard.getData(Clipboard.kTextPlain);
      if (!mounted || !_foreground || epoch != _inputEpoch) return;
      final text = value?.text?.trim();
      if (text == null || text.isEmpty) {
        setState(() => _error = 'В буфере обмена нет ссылки подписки.');
      } else if (!SubscriptionDraft.validUrl(text)) {
        setState(() => _error = 'Скопируйте полную HTTPS-ссылку подписки.');
      } else {
        setState(() => _url.text = text);
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Не удалось прочитать буфер обмена.');
    } finally {
      if (mounted) setState(() => _pasting = false);
    }
  }

  Future<void> _save() async {
    if (!mounted || _busy || !_foreground) return;
    final url = _url.text.trim();
    final name = _name.text.trim();
    if (!WireGuardProfiles.isValidName(name)) {
      setState(() => _error = 'Укажите название: от 1 до 64 символов.');
      return;
    }
    if (!SubscriptionDraft.validUrl(url)) {
      setState(() => _error = 'Нужна полная HTTPS-ссылка подписки.');
      return;
    }
    _urlFocus.unfocus();
    _nameFocus.unfocus();
    setState(() { _saving = true; _error = null; _visible = false; });
    try {
      await widget.onSave(url, name);
      if (!mounted || _closing) return;
      if (widget.onCompleted != null) {
        widget.onCompleted!();
      } else {
        Navigator.of(context).pop<bool>(true);
      }
    } catch (error) {
      if (mounted) setState(() {
        _saving = false;
        _error = subscriptionErrorMessage(error);
      });
    }
  }

  void _closeEditor() {
    if (!mounted || _busy || !_foreground) return;
    _closing = true;
    _inputEpoch++;
    _visible = false;
    if (widget.onClose != null) {
      widget.onClose!();
    } else {
      Navigator.of(context).pop();
    }
  }

  void _toggleVisibility() {
    if (!mounted || _busy || !_foreground) return;
    setState(() => _visible = !_visible);
    if (!_visible) _urlFocus.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final host = SubscriptionDraft.validUrl(_url.text.trim())
        ? Uri.parse(_url.text.trim()).host : null;
    return PopScope<Object?>(canPop: !_saving && !_closing && widget.onClose == null,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          _closing = true;
          _inputEpoch++;
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
                    onPressed: _busy || !_foreground ? null : _closeEditor,
                    icon: Icon(widget.onClose == null ? Icons.close : Icons.arrow_back)),
                ]),
                const SizedBox(height: 8),
                const Text('HTTPS-ссылка подписки от провайдера или из вашей панели.',
                  style: TextStyle(color: PushokPalette.muted)),
                const SizedBox(height: 16),
                TextField(key: const Key('subscription_name'), controller: _name,
                  focusNode: _nameFocus, enabled: !_busy, maxLines: 1,
                  autocorrect: false, enableSuggestions: false,
                  enableIMEPersonalizedLearning: false, autofillHints: null,
                  onChanged: (_) => setState(() => _error = null),
                  decoration: const InputDecoration(labelText: 'Название подписки')),
                const SizedBox(height: 16),
                TextField(key: const Key('subscription_url'), controller: _url,
                  focusNode: _urlFocus, enabled: !_busy, maxLines: 1,
                  readOnly: !_visible, obscureText: !_visible,
                  enableInteractiveSelection: _visible, keyboardType: TextInputType.url,
                  autocorrect: false, enableSuggestions: false,
                  enableIMEPersonalizedLearning: false, autofillHints: null,
                  smartDashesType: SmartDashesType.disabled,
                  smartQuotesType: SmartQuotesType.disabled,
                  onChanged: (_) => setState(() => _error = null),
                  decoration: InputDecoration(labelText: 'HTTPS-ссылка подписки',
                    helperText: 'Вставьте ссылку или откройте поле значком глаза.',
                    helperMaxLines: 2,
                    suffixIcon: IconButton(key: const Key('toggle_subscription_url_visibility'),
                      tooltip: _visible ? 'Скрыть ссылку' : 'Показать ссылку',
                      onPressed: _busy || !_foreground ? null : _toggleVisibility,
                      icon: Icon(_visible ? Icons.visibility_off_outlined : Icons.visibility_outlined)))),
                const SizedBox(height: 10),
                Align(alignment: Alignment.centerRight,
                  child: OutlinedButton.icon(key: const Key('paste_subscription_url'),
                    onPressed: _busy || !_foreground ? null : _paste,
                    icon: const Icon(Icons.content_paste_outlined), label: const Text('Вставить'))),
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
                ],
                const SizedBox(height: 16),
                FilledButton.icon(key: const Key('save_subscription'),
                  onPressed: _busy || !_foreground ? null : _save,
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
