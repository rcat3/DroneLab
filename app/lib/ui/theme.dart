import 'package:flutter/material.dart';

/// KatCorp's look, as on the board and the installer page: near black, green
/// terminal lettering for headings, hot pink for what's pressed.
abstract final class Kc {
  static const bg = Color(0xFF050506);
  static const dock = Color(0xFF08080A);
  static const panel = Color(0xFF111014);
  static const raised = Color(0xFF1C1A21);
  static const line = Color(0xFF2A2630);
  static const text = Color(0xFFE9E4EE);
  static const muted = Color(0xFFA59CAD);
  static const dim = Color(0xFF7D7486);
  static const off = Color(0xFF3A3442);         // an indicator that's off
  static const green = Color(0xFF33FF33);
  static const darkGreen = Color(0xFF1E9C45);
  static const visor = Color(0xFF0C4A20);
  static const pink = Color(0xFFFF40C0);
  static const red = Color(0xFFD7263D);
  static const softRed = Color(0xFFFF6B7D);
  static const warn = Color(0xFFFFC940);        // something to see to, not an error
  static const otherAir = Color(0xFFC4BCCC);    // voice on another channel, not heard

  /// The board's Terminal letters (unscii 8). Each letter's as wide as it's
  /// tall, so it reads bigger than other fonts: sizes are scaled down to suit.
  static TextStyle term(double size, {Color color = text, List<Shadow>? shadows}) =>
      TextStyle(fontFamily: 'Unscii', fontSize: size * 0.7, color: color, height: 1.15, shadows: shadows);

  static List<Shadow> glow(Color c) => [Shadow(color: c.withValues(alpha: 0.5), blurRadius: 10)];

  static ThemeData theme() {
    const scheme = ColorScheme.dark(
      primary: pink,
      onPrimary: bg,
      secondary: green,
      onSecondary: bg,
      tertiary: otherAir,
      error: red,
      onError: Colors.white,
      surface: bg,
      onSurface: text,
      onSurfaceVariant: muted,
      surfaceContainerLowest: bg,
      surfaceContainerLow: dock,
      surfaceContainer: panel,
      surfaceContainerHigh: panel,
      surfaceContainerHighest: raised,
      outline: line,
      outlineVariant: line,
    );
    final stadium = WidgetStatePropertyAll<OutlinedBorder>(const StadiumBorder());
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      canvasColor: bg,
      dividerColor: line,
      dividerTheme: const DividerThemeData(color: line, space: 1, thickness: 1),
      appBarTheme: AppBarTheme(
        backgroundColor: bg,
        surfaceTintColor: Colors.transparent,
        foregroundColor: muted,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleSpacing: 16,
        shape: const Border(bottom: BorderSide(color: line)),
        titleTextStyle: term(24, color: green, shadows: glow(green)),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: dock,
        surfaceTintColor: Colors.transparent,
        indicatorColor: pink.withValues(alpha: 0.14),
        height: 68,
        labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
            color: s.contains(WidgetState.selected) ? pink : dim)),
        iconTheme: WidgetStateProperty.resolveWith(
            (s) => IconThemeData(color: s.contains(WidgetState.selected) ? pink : dim)),
      ),
      cardTheme: const CardThemeData(
        color: panel,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)), side: BorderSide(color: line)),
      ),
      listTileTheme: const ListTileThemeData(iconColor: muted, subtitleTextStyle: TextStyle(color: muted, fontSize: 13)),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? line : pink),
          foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? dim : bg),
          textStyle: const WidgetStatePropertyAll(TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
          minimumSize: const WidgetStatePropertyAll(Size(64, 44)),
          shape: stadium,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          foregroundColor: const WidgetStatePropertyAll(text),
          backgroundColor: const WidgetStatePropertyAll(panel),
          side: const WidgetStatePropertyAll(BorderSide(color: line)),
          minimumSize: const WidgetStatePropertyAll(Size(64, 40)),
          shape: stadium,
        ),
      ),
      textButtonTheme: const TextButtonThemeData(style: ButtonStyle(foregroundColor: WidgetStatePropertyAll(pink))),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? pink : panel),
          foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected)
              ? bg
              : s.contains(WidgetState.disabled)
                  ? off
                  : muted),
          side: const WidgetStatePropertyAll(BorderSide(color: line)),
          textStyle: WidgetStatePropertyAll(term(15)),
          minimumSize: const WidgetStatePropertyAll(Size(48, 44)),
          padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 6)),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: panel,
        selectedColor: pink.withValues(alpha: 0.14),
        disabledColor: panel,
        side: WidgetStateBorderSide.resolveWith(
            (s) => BorderSide(color: s.contains(WidgetState.selected) ? pink : line)),
        labelStyle: WidgetStateTextStyle.resolveWith(
            (s) => TextStyle(color: s.contains(WidgetState.selected) ? pink : text, fontSize: 14)),
        checkmarkColor: pink,
        shape: const StadiumBorder(),
        showCheckmark: false,
      ),
      switchTheme: SwitchThemeData(
        // Dimmed when it can't be changed, as Mute speaker on Tx while it's
        // forced, the thumb too, so off and can't-change don't look alike
        thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected)
            ? bg
            : s.contains(WidgetState.disabled)
                ? muted.withValues(alpha: 0.3)
                : muted),
        trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled)
            ? (s.contains(WidgetState.selected) ? pink.withValues(alpha: 0.35) : line.withValues(alpha: 0.5))
            : s.contains(WidgetState.selected)
                ? pink
                : line),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? pink : Colors.transparent),
        checkColor: const WidgetStatePropertyAll(bg),
        side: const BorderSide(color: muted, width: 2),
      ),
      sliderTheme: const SliderThemeData(
          activeTrackColor: pink, thumbColor: pink, inactiveTrackColor: line, valueIndicatorColor: pink),
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: bg,
        border: OutlineInputBorder(borderSide: BorderSide(color: line), borderRadius: BorderRadius.all(Radius.circular(10))),
        enabledBorder:
            OutlineInputBorder(borderSide: BorderSide(color: line), borderRadius: BorderRadius.all(Radius.circular(10))),
        focusedBorder:
            OutlineInputBorder(borderSide: BorderSide(color: pink), borderRadius: BorderRadius.all(Radius.circular(10))),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: panel,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        dragHandleColor: line,
      ),
      dialogTheme: const DialogThemeData(backgroundColor: panel, surfaceTintColor: Colors.transparent),
      snackBarTheme: const SnackBarThemeData(
          backgroundColor: raised, contentTextStyle: TextStyle(color: text), behavior: SnackBarBehavior.floating),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: pink),
    );
  }
}
