import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../design/pushok_theme.dart';
import '../platform/subscription_diagnostics.dart';

/// Exports only a fixed diagnostic after an explicit, current foreground action.
class SubscriptionDiagnosticCopy extends StatefulWidget {
  const SubscriptionDiagnosticCopy({super.key, required this.diagnostic,
    required this.buttonKey, required this.noticeKey, this.errorIdentity, this.isCurrentError,
    this.enabled = true});

  final SubscriptionDiagnostic diagnostic;
  final Key buttonKey;
  final Key noticeKey;
  /// An in-memory failure identity; it is never included in the copied report.
  final Object? errorIdentity;
  final bool Function()? isCurrentError;
  final bool enabled;

  @override
  State<SubscriptionDiagnosticCopy> createState() => _SubscriptionDiagnosticCopyState();
}

class _SubscriptionDiagnosticCopyState extends State<SubscriptionDiagnosticCopy>
    with WidgetsBindingObserver {
  bool _foreground = true;
  bool _copying = false;
  bool _copyFailed = false;
  String? _notice;
  int _epoch = 0;
  Object get _identity => widget.errorIdentity ?? widget.diagnostic;
  bool get _canCopy {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    return widget.enabled && _foreground && (widget.isCurrentError?.call() ?? true) &&
        (lifecycle == null || lifecycle == AppLifecycleState.resumed) &&
        ModalRoute.of(context)?.isCurrent != false;
  }

  @override
  void initState() {
    super.initState();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didUpdateWidget(covariant SubscriptionDiagnosticCopy oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((oldWidget.errorIdentity ?? oldWidget.diagnostic) != _identity ||
        oldWidget.enabled != widget.enabled ||
        oldWidget.diagnostic.code != widget.diagnostic.code ||
        oldWidget.diagnostic.operation != widget.diagnostic.operation ||
        oldWidget.diagnostic.source != widget.diagnostic.source) {
      _resetCopy();
    }
  }

  void _resetCopy() {
    _epoch++;
    _copying = false;
    _copyFailed = false;
    _notice = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    setState(() {
      _foreground = state == AppLifecycleState.resumed;
      if (!_foreground) _resetCopy();
    });
  }

  @override
  void dispose() {
    _epoch++;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _copy(SubscriptionDiagnostic diagnostic, Object identity, int epoch) async {
    bool current() => mounted && epoch == _epoch && identity == _identity && _canCopy;
    if (!current() || _copying) return;
    setState(() { _copying = true; _copyFailed = false; _notice = null; });
    try {
      // No input, subscription name/ID, host, URL or exception details reach here.
      await Clipboard.setData(ClipboardData(text: diagnostic.clipboardText));
      if (current()) setState(() => _notice = 'Отчёт скопирован.');
    } catch (_) {
      if (current()) setState(() {
        _copyFailed = true;
        _notice = 'Не удалось скопировать отчёт. Попробуйте ещё раз.';
      });
    } finally {
      if (mounted && epoch == _epoch && identity == _identity) {
        setState(() => _copying = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final diagnostic = widget.diagnostic;
    final identity = _identity;
    final epoch = _epoch;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      TextButton.icon(key: widget.buttonKey,
        onPressed: !_canCopy || _copying ? null : () => _copy(diagnostic, identity, epoch),
        icon: _copying
            ? const SizedBox(width: 16, height: 16,
                child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.copy_outlined),
        label: const Text('Скопировать ошибку')),
      if (_notice != null) Semantics(liveRegion: true,
        child: Text(_notice!, key: widget.noticeKey,
          style: TextStyle(color: _copyFailed ? PushokPalette.orange : PushokPalette.mint))),
    ]);
  }
}
