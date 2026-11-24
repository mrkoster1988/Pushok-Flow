import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../design/pushok_theme.dart';

/// TCP-connect latency to the public Pushok service. This is NOT ICMP ping,
/// WireGuard handshake RTT, a bandwidth test or a proof of tunnel routing.
class FlowNetworkLatency extends StatefulWidget {
  const FlowNetworkLatency({super.key, required this.active, this.measure});

  final bool active;
  /// Injectable to keep widget tests offline and deterministic.
  final Future<int?> Function()? measure;

  @override
  State<FlowNetworkLatency> createState() => _FlowNetworkLatencyState();
}

class _FlowNetworkLatencyState extends State<FlowNetworkLatency>
    with WidgetsBindingObserver {
  Timer? _timer;
  int _request = 0;
  bool _foreground = true;
  bool _busy = false;
  int? _milliseconds;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    _restart();
  }

  @override
  void didUpdateWidget(covariant FlowNetworkLatency oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active != oldWidget.active || widget.measure != oldWidget.measure) {
      _restart();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _restart();
  }

  void _restart() {
    _timer?.cancel();
    _request++;
    _milliseconds = null;
    _busy = false;
    if (!widget.active || !_foreground) return;
    // No periodic work when a tunnel is down or the app is backgrounded.
    unawaited(_probe());
    _timer = Timer.periodic(const Duration(seconds: 45), (_) {
      if (mounted && widget.active && _foreground && !_busy) unawaited(_probe());
    });
  }

  Future<void> _probe() async {
    if (!mounted || !_foreground || !widget.active || _busy) return;
    final epoch = ++_request;
    setState(() => _busy = true);
    int? value;
    try {
      value = await (widget.measure ?? _tcpConnect)().timeout(
        const Duration(seconds: 5));
    } catch (_) {
      value = null;
    }
    if (!mounted || epoch != _request || !_foreground || !widget.active) return;
    setState(() {
      _busy = false;
      // Bound malformed results from platform or test injections.
      _milliseconds = value != null && value >= 0 && value <= 5000 ? value : null;
    });
  }

  /// The host is fixed; no private URI, credentials, or config leaves the app.
  static Future<int?> _tcpConnect() async {
    final clock = Stopwatch()..start();
    final socket = await Socket.connect(
      'pushok.shop', 443, timeout: const Duration(seconds: 3));
    clock.stop();
    socket.destroy();
    return clock.elapsedMilliseconds;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _request++;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Отклик сети к pushok.shop, без передачи приватных данных',
    child: Row(children: [
      const Icon(Icons.network_ping_outlined, color: PushokPalette.teal, size: 18),
      const SizedBox(width: 7),
      Expanded(child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Отклик сети', style: TextStyle(
            fontSize: 11, color: PushokPalette.muted)),
          Text(
            !widget.active ? '—'
              : _busy && _milliseconds == null ? 'Проверяем…'
              : _milliseconds == null ? 'Нет ответа'
              : '$_milliseconds мс',
            key: const Key('home_latency_value'),
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
        ],
      )),
      IconButton(
        key: const Key('home_refresh_latency'),
        tooltip: 'Проверить отклик сети',
        onPressed: widget.active && _foreground && !_busy ? () => unawaited(_probe()) : null,
        icon: const Icon(Icons.refresh, size: 18)),
    ]),
  );
}
