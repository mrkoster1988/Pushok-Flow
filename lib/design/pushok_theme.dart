import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// Единые визуальные правила Pushok (Flow, Proxy, Pushok ИИ).
/// Цвета сверены с пользовательским эталонным скриншотом Proxy.
abstract final class PushokPalette {
  static const background = Color(0xFF061827);
  static const surface = Color(0xFF102D40);
  static const surfaceRaised = Color(0xFF143449);
  static const border = Color(0xFF365B70);
  static const teal = Color(0xFF39C8C3);
  static const cyan = Color(0xFF69BBD9);
  static const violet = Color(0xFF8872CF);
  static const orange = Color(0xFFFFAD73);
  static const green = Color(0xFF087C56);
  static const red = Color(0xFFA92F45);
  static const text = Color(0xFFE4EDF5);
  static const muted = Color(0xFF91A9BC);
  // Дополнительная премиальная палитра по утверждённым макетам Flow.
  static const glowCyan = Color(0xFF00ECF5);
  static const electricBlue = Color(0xFF198FFF);
  static const glowViolet = Color(0xFF8C48FF);
  static const midnight = Color(0xFF020B22);
  static const mint = Color(0xFF13F1B2);
}

ThemeData buildPushokTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: PushokPalette.teal,
    brightness: Brightness.dark,
    surface: PushokPalette.surface,
  ).copyWith(primary: PushokPalette.teal, onPrimary: PushokPalette.background,
    secondary: PushokPalette.cyan, onSurface: PushokPalette.text,
    error: PushokPalette.red);
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: PushokPalette.background,
    colorScheme: scheme,
    appBarTheme: const AppBarTheme(backgroundColor: PushokPalette.background,
      foregroundColor: PushokPalette.text, elevation: 0, centerTitle: false),
    iconTheme: const IconThemeData(color: PushokPalette.teal),
    textTheme: const TextTheme(bodyMedium: TextStyle(color: PushokPalette.text)),
    dividerColor: PushokPalette.border,
    cardTheme: CardThemeData(color: PushokPalette.surface, elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: PushokPalette.border))),
    inputDecorationTheme: InputDecorationTheme(
      filled: true, fillColor: PushokPalette.surface,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: PushokPalette.border)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: PushokPalette.border)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: PushokPalette.teal)),
      labelStyle: const TextStyle(color: PushokPalette.muted),
    ),
    filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(
      backgroundColor: PushokPalette.green, foregroundColor: PushokPalette.text,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14))),
    outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(
      foregroundColor: PushokPalette.teal,
      side: const BorderSide(color: PushokPalette.border),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)))),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) =>
        states.contains(WidgetState.selected) ? PushokPalette.teal : PushokPalette.muted),
      trackColor: WidgetStateProperty.resolveWith((states) =>
        states.contains(WidgetState.selected) ? PushokPalette.teal.withValues(alpha: 0.28) : PushokPalette.surfaceRaised),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: PushokPalette.background,
      indicatorColor: PushokPalette.surface,
      height: 72,
      labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
        fontSize: 11,
        color: states.contains(WidgetState.selected) ? PushokPalette.teal : PushokPalette.muted)),
      iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(
        color: states.contains(WidgetState.selected) ? PushokPalette.teal : PushokPalette.muted)),
    ),
  );
}

class PushokPanel extends StatelessWidget {
  const PushokPanel({super.key, required this.child, this.padding = const EdgeInsets.all(16)});
  final Widget child;
  final EdgeInsets padding;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity, padding: padding,
    decoration: BoxDecoration(
      gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
        colors: [Color(0xFF123450), Color(0xFF06182F)]),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: PushokPalette.glowCyan.withValues(alpha: .50), width: 1),
      boxShadow: [BoxShadow(color: PushokPalette.electricBlue.withValues(alpha: .12),
        blurRadius: 18, spreadRadius: 0)],
    ),
    child: child,
  );
}

class PushokStatusChip extends StatelessWidget {
  const PushokStatusChip({super.key, required this.label, required this.color, required this.icon});
  final String label;
  final Color color;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 10),
    decoration: BoxDecoration(color: color.withValues(alpha: .17),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: color.withValues(alpha: .4))),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 15, color: color), const SizedBox(width: 6),
      Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12)),
    ]),
  );
}


/// Медленный свет и тонкие волны. Перерисовывается только декоративный слой;
/// содержимое страницы не перестраивается на каждом кадре.
class PushokNeonBackdrop extends StatefulWidget {
  const PushokNeonBackdrop({super.key, required this.child});
  final Widget child;

  @override
  State<PushokNeonBackdrop> createState() => _PushokNeonBackdropState();
}

class _PushokNeonBackdropState extends State<PushokNeonBackdrop>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _phase;
  late final _FlowWavePainter _painter;
  bool _foreground = true;
  bool _dependenciesReady = false;
  bool _motionEnabled = false;

  @override
  void initState() {
    super.initState();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    _phase = AnimationController(vsync: this,
      duration: const Duration(seconds: 24));
    _painter = _FlowWavePainter(_phase);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _dependenciesReady = true;
    _motionEnabled = TickerMode.of(context) &&
      !MediaQuery.disableAnimationsOf(context);
    _syncAnimation();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _syncAnimation();
  }

  void _syncAnimation() {
    if (_foreground && _dependenciesReady && _motionEnabled) {
      if (!_phase.isAnimating) _phase.repeat();
    } else {
      // Keep the current phase so returning to the app never jumps to frame 0.
      _phase.stop(canceled: false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _phase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(children: [
    const Positioned.fill(child: DecoratedBox(decoration: BoxDecoration(
      gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
        colors: [Color(0xFF030C20), Color(0xFF07192E), Color(0xFF03091B)])))),
    Positioned.fill(child: IgnorePointer(child: RepaintBoundary(
      child: CustomPaint(painter: _painter),
    ))),
    RepaintBoundary(child: widget.child),
  ]);
}

class _FlowWavePainter extends CustomPainter {
  _FlowWavePainter(this.phase) : super(repaint: phase);

  final Animation<double> phase;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final angle = phase.value * math.pi * 2;
    canvas.save();
    canvas.clipRect(Offset.zero & size);

    // Elliptical gradients create depth without a costly full-screen blur.
    void aurora(Offset center, double width, double height, Color color,
        double opacity) {
      final bounds = Rect.fromCenter(center: center,
        width: width, height: height);
      canvas.drawOval(bounds, Paint()..shader = RadialGradient(
        colors: [color.withValues(alpha: opacity),
          color.withValues(alpha: opacity * .32),
          color.withValues(alpha: 0)],
        stops: const [0, .42, 1],
      ).createShader(bounds));
    }

    aurora(Offset(size.width * (.14 + .11 * math.sin(angle)),
      size.height * (.21 + .045 * math.cos(angle))),
      size.width * 1.6, size.height * .78, PushokPalette.glowCyan, .115);
    aurora(Offset(size.width * (.94 + .08 * math.cos(angle + .7)),
      size.height * (.48 + .07 * math.sin(angle))),
      size.width * 1.55, size.height * .88, PushokPalette.electricBlue, .12);
    aurora(Offset(size.width * (.32 + .17 * math.sin(angle + 2.1)),
      size.height * (.88 + .045 * math.cos(angle + 1.4))),
      size.width * 1.9, size.height * .7, PushokPalette.glowViolet, .115);

    void wave(double baseline, Color color, double offset, double strength) {
      final height = size.height * baseline;
      final swell = math.sin(angle + offset);
      final drift = math.cos(angle + offset);
      final path = Path()..moveTo(-28, height + swell * 12);
      path.cubicTo(size.width * .23, height - 45 + drift * 20,
        size.width * .59, height + 55 - swell * 18,
        size.width + 28, height - 18 + drift * 12);
      final strokeBounds = Rect.fromLTWH(0, height - 80, size.width, 160);
      canvas.drawPath(path, Paint()
        ..color = color.withValues(alpha: .075 * strength)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 15
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 11));
      canvas.drawPath(path, Paint()
        ..shader = LinearGradient(colors: [
          color.withValues(alpha: .06 * strength),
          color.withValues(alpha: .4 * strength),
          color.withValues(alpha: .12 * strength),
        ], stops: const [0, .46, 1]).createShader(strokeBounds)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1);
      canvas.save();
      canvas.translate(0, 7 + drift * 2);
      canvas.drawPath(path, Paint()
        ..color = color.withValues(alpha: .065 * strength)
        ..style = PaintingStyle.stroke
        ..strokeWidth = .6);
      canvas.restore();
    }

    wave(.22, PushokPalette.glowCyan, .2, .85);
    wave(.84, PushokPalette.glowViolet, 2.2, 1);
    wave(.91, PushokPalette.electricBlue, 3.9, .9);

    // Deterministic, widely spaced specks drift gently; no random flashing.
    for (var i = 0; i < 9; i++) {
      final seed = i * 2.399963;
      final x = size.width * (.07 + ((i * .137) % .86)) +
        math.sin(angle + seed) * 7;
      final y = size.height * (.08 + ((i * .213) % .82)) +
        math.cos(angle + seed) * 10;
      final visibility = .11 + .05 * math.sin(angle + seed);
      canvas.drawCircle(Offset(x, y), i.isEven ? 1 : .7,
        Paint()..color = PushokPalette.cyan.withValues(alpha: visibility));
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _FlowWavePainter oldDelegate) =>
    oldDelegate.phase != phase;
}

class PushokNeonButton extends StatelessWidget {
  const PushokNeonButton({super.key, required this.label, required this.onPressed,
    this.icon = Icons.power_settings_new, this.positive = false});
  final String label;
  final VoidCallback? onPressed;
  final IconData icon;
  final bool positive;
  @override
  Widget build(BuildContext context) {
    final accent = positive ? PushokPalette.mint : PushokPalette.glowCyan;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [accent, PushokPalette.electricBlue, accent]),
        borderRadius: BorderRadius.circular(28),
        boxShadow: [BoxShadow(color: accent.withValues(alpha: .38), blurRadius: 24)]),
      padding: const EdgeInsets.all(2),
      child: FilledButton.icon(
        style: FilledButton.styleFrom(backgroundColor: PushokPalette.midnight,
          foregroundColor: Colors.white, minimumSize: const Size.fromHeight(54),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26))),
        onPressed: onPressed,
        icon: Icon(icon, color: accent),
        label: Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
      ),
    );
  }
}
