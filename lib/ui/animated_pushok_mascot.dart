import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// The original portrait remains visible throughout the animation. Only the
/// eyes use the generated closed-eye frame, avoiding any body/outline jitter.
class AnimatedPushokMascot extends StatefulWidget {
  const AnimatedPushokMascot({
    super.key,
    required this.height,
    this.connected = false,
  });

  final double height;
  final bool connected;

  @override
  State<AnimatedPushokMascot> createState() => _AnimatedPushokMascotState();
}

class _AnimatedPushokMascotState extends State<AnimatedPushokMascot>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const _idleImage = AssetImage('assets/mascot/pushok.png');
  static const _blinkImage = AssetImage('assets/mascot/pushok_blink.png');
  static const _cycleSeconds = 20.0;
  late final AnimationController _phase;
  bool _foreground = true;
  bool _dependenciesReady = false;
  bool _tickerEnabled = false;
  bool _reducedMotion = false;
  bool _imagesRequested = false;
  bool _blinkReady = false;
  double? _reactionStart;

  bool get _canAnimate => _dependenciesReady && _foreground &&
    _tickerEnabled && !_reducedMotion;

  @override
  void initState() {
    super.initState();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    _phase = AnimationController(vsync: this,
      duration: const Duration(seconds: 20))..addListener(_finishReaction);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _dependenciesReady = true;
    _tickerEnabled = TickerMode.of(context);
    _reducedMotion = MediaQuery.disableAnimationsOf(context);
    _syncAnimation();
    if (!_imagesRequested) {
      _imagesRequested = true;
      _precachePortraits();
    }
  }

  Future<void> _precachePortraits() async {
    var loaded = true;
    await Future.wait([
      precacheImage(_idleImage, context, onError: (error, stackTrace) {
        loaded = false;
      }),
      precacheImage(_blinkImage, context, onError: (error, stackTrace) {
        loaded = false;
      }),
    ]);
    if (mounted && loaded) setState(() => _blinkReady = true);
  }

  @override
  void didUpdateWidget(covariant AnimatedPushokMascot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.connected && !oldWidget.connected && _canAnimate) {
      _reactionStart = _phase.value;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _syncAnimation();
  }

  void _syncAnimation() {
    if (_canAnimate) {
      if (!_phase.isAnimating) _phase.repeat();
    } else {
      _phase.stop(canceled: false);
      if (_reducedMotion) _reactionStart = null;
    }
  }

  double get _reactionSeconds => _reactionStart == null ? .48 :
    ((_phase.value - _reactionStart! + 1) % 1) * _cycleSeconds;

  void _finishReaction() {
    if (_reactionStart != null && _reactionSeconds >= .48) {
      _reactionStart = null;
    }
  }

  void _greet() {
    if (_canAnimate) setState(() => _reactionStart = _phase.value);
  }

  double _blinkOpacity() {
    if (!_blinkReady || _reducedMotion) return 0;
    final seconds = _phase.value * _cycleSeconds;
    // One quick double blink and two singles make a calm, non-uniform rhythm.
    for (final start in const [3.6, 9.4, 9.68, 16.8]) {
      final elapsed = seconds - start;
      if (elapsed < 0 || elapsed > .16) continue;
      if (elapsed < .035) return Curves.easeOut.transform(elapsed / .035);
      if (elapsed < .105) return 1;
      final opening = ((elapsed - .105) / .055).clamp(0.0, 1.0).toDouble();
      return 1 - Curves.easeIn.transform(opening);
    }
    return 0;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _phase.removeListener(_finishReaction);
    _phase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final portrait = RepaintBoundary(child: FittedBox(
      fit: BoxFit.contain,
      child: SizedBox(width: 400, height: 422, child: Stack(
        fit: StackFit.expand,
        children: [
          const Image(image: _idleImage, fit: BoxFit.fill,
            gaplessPlayback: true, excludeFromSemantics: true),
          if (_blinkReady && !_reducedMotion) AnimatedBuilder(
            animation: _phase,
            child: const RepaintBoundary(child: _ClosedEyes()),
            builder: (context, child) => Opacity(
              opacity: _blinkOpacity(), child: child),
          ),
        ],
      )),
    ));

    return Semantics(
      key: const Key('animated_pushok_mascot'),
      image: true,
      button: !_reducedMotion,
      label: 'Фирменный рыжий котёнок Pushok',
      onTap: _reducedMotion ? null : _greet,
      child: ExcludeSemantics(child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTap: _reducedMotion ? null : _greet,
        child: SizedBox(height: widget.height, width: widget.height * 400 / 422,
          child: AnimatedBuilder(
            animation: _phase,
            child: portrait,
            builder: (context, child) {
              if (_reducedMotion) return child!;
              final angle = _phase.value * math.pi * 2;
              final seconds = _phase.value * _cycleSeconds;
              final reaction = (_reactionSeconds / .48).clamp(0.0, 1.0);
              final hop = math.sin(reaction * math.pi);
              final tiltProgress = ((seconds - 12) / 2.4).clamp(0.0, 1.0);
              final tilt = math.sin(tiltProgress * math.pi) * .014;
              final scale = 1 + math.sin(angle * 5) * .003;
              final dy = (math.sin(angle * 4) * 1.2 - hop * 5) *
                widget.height / 160;
              return Transform.translate(offset: Offset(0, dy),
                child: Transform.rotate(
                  angle: tilt + math.sin(reaction * math.pi * 2) * .025,
                  alignment: const Alignment(0, .6),
                  child: Transform.scale(scale: scale, child: child),
                ),
              );
            },
          ),
        ),
      )),
    );
  }
}

/// The generated frame has the same aspect ratio, but its body registration
/// differs slightly. Feathered eye patches keep every other original pixel.
class _ClosedEyes extends StatelessWidget {
  const _ClosedEyes();

  @override
  Widget build(BuildContext context) => const Stack(children: [
    _EyePatch(bounds: Rect.fromLTWH(126, 105, 74, 66)),
    _EyePatch(bounds: Rect.fromLTWH(202, 86, 68, 66)),
  ]);
}

class _EyePatch extends StatelessWidget {
  const _EyePatch({required this.bounds});

  final Rect bounds;

  @override
  Widget build(BuildContext context) => Positioned.fromRect(
    rect: bounds,
    child: ClipRect(child: ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (rect) => const RadialGradient(
        colors: [Colors.white, Colors.white, Colors.transparent],
        stops: [0, .72, 1],
      ).createShader(rect),
      child: Stack(clipBehavior: Clip.none, children: [
        Positioned(left: -bounds.left, top: -bounds.top,
          width: 400, height: 422,
          child: const Image(
            image: _AnimatedPushokMascotState._blinkImage,
            fit: BoxFit.fill,
            gaplessPlayback: true,
            excludeFromSemantics: true,
            filterQuality: FilterQuality.medium,
          ),
        ),
      ]),
    )),
  );
}
