import 'dart:async';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import '../platform/subscriptions.dart';

class TelegramProxyAction extends StatefulWidget {
  const TelegramProxyAction({super.key, required this.subscriptions, this.inSettings = false});
  final FlowSubscriptions subscriptions;
  final bool inSettings;
  @override
  State<TelegramProxyAction> createState() => _TelegramProxyActionState();
}

class _TelegramProxyActionState extends State<TelegramProxyAction> with WidgetsBindingObserver {
  String _state = 'loading';
  bool _busy = false;
  bool _asking = false;
  bool _returned = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_read());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _returned = true;
      unawaited(_read());
    }
  }

  Future<void> _read() async {
    String state;
    try { state = await widget.subscriptions.telegramProxyState(); }
    catch (_) { state = 'ready'; }
    if (!mounted) return;
    setState(() => _state = state);
    if (state == 'pending' && !_busy) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
          unawaited(_confirm());
        }
      });
    }
  }

  Future<void> _confirm() async {
    if (_asking || !mounted || _state != 'pending') return;
    _asking = true;
    try {
      final answer = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Прокси подключён?'),
          content: const Text('В Telegram у прокси Pushok должен появиться статус «Подключён».'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Пока нет')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Прокси подключён')),
          ],
        ),
      );
      if (answer == null || !mounted) return;
      await widget.subscriptions.confirmTelegramProxy(answer);
      if (mounted) setState(() => _state = answer ? 'confirmed' : 'ready');
    } catch (_) {
      _message('Не удалось сохранить выбор. Попробуйте ещё раз.');
    } finally { _asking = false; }
  }

  void _message(String text) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _open() async {
    if (_state == 'pending') { await _confirm(); return; }
    if (_busy) return;
    setState(() => _busy = true);
    _returned = false;
    try {
      await widget.subscriptions.openTelegramProxy();
      if (mounted) setState(() => _state = 'pending');
    } on PlatformException catch (e) {
      _message(e.code == 'MTPROXY_NO_TELEGRAM'
          ? 'Для подключения MTProxy установите Telegram.'
          : 'Не удалось открыть прокси Pushok. Попробуйте ещё раз.');
    } catch (_) {
      _message('Не удалось открыть настройки прокси Telegram.');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        if (_returned && _state == 'pending') unawaited(_confirm());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_state == 'loading' || _state == 'confirmed' && !widget.inSettings) {
      return const SizedBox.shrink();
    }
    return Tooltip(
      message: widget.inSettings ? 'Настроить MTProxy в Telegram' : 'Включить MTProxy',
      child: TextButton(
        key: const Key('flow_mtproxy_action'),
        onPressed: _busy ? null : _open,
        child: const Text('MTProxy'),
      ),
    );
  }
}
