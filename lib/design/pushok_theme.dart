import 'package:flutter/material.dart';

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


/// Декоративные неоновые волны из утверждённого референса.
/// Рисуются программно: не блокируют касания и не требуют сети.
class PushokNeonBackdrop extends StatelessWidget {
  const PushokNeonBackdrop({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Stack(children: [
    const Positioned.fill(child: DecoratedBox(decoration: BoxDecoration(
      gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
        colors: [Color(0xFF031128), Color(0xFF071A38), Color(0xFF030C20)])))),
    Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _FlowWavePainter()))),
    child,
  ]);
}

class _FlowWavePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    void wave(double height, Color color, double shift) {
      final path = Path()..moveTo(-30, height);
      path.cubicTo(size.width * .25, height - 82 + shift,
          size.width * .56, height + 86 - shift,
          size.width + 30, height - 26);
      canvas.drawPath(path, Paint()..color = color.withValues(alpha: .18)
        ..style = PaintingStyle.stroke..strokeWidth = 26..maskFilter = const MaskFilter.blur(BlurStyle.normal, 21));
      canvas.drawPath(path, Paint()..color = color.withValues(alpha: .78)
        ..style = PaintingStyle.stroke..strokeWidth = 2.1);
    }
    wave(size.height * .19, PushokPalette.glowCyan, 8);
    wave(size.height * .88, PushokPalette.glowViolet, -16);
    wave(size.height * .92, PushokPalette.electricBlue, 24);
  }
  @override
  bool shouldRepaint(covariant _FlowWavePainter oldDelegate) => false;
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