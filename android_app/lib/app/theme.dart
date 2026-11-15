/// Visual identity.
///
/// The game shell is playful and loud; the private shell is calm and dark. They
/// share a type ramp but never share a scaffold, so it is always obvious which
/// half of the app you are in.
library;

import 'package:flutter/material.dart';

class SpColors {
  const SpColors._();

  // Game shell.
  static const Color ink = Color(0xFF101322);
  static const Color surface = Color(0xFF191D33);
  static const Color mint = Color(0xFF35E6B2);
  static const Color grape = Color(0xFF8A7BFF);
  static const Color sun = Color(0xFFFFD166);
  static const Color coral = Color(0xFFFF6B6B);
  static const Color sky = Color(0xFF5AC8FA);

  // Private shell.
  static const Color privateInk = Color(0xFF07090F);
  static const Color privateSurface = Color(0xFF11151F);
  static const Color privateLine = Color(0xFF1F2633);
  static const Color privateAccent = Color(0xFF7CE7C4);

  static const List<Color> pegPalette = [
    mint,
    grape,
    sun,
    coral,
    sky,
    Colors.white,
    Color(0xFFB8C4D9),
    Color(0xFF9C6BFF),
  ];
}

ThemeData buildGameTheme() {
  final base = ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: SpColors.mint,
      brightness: Brightness.dark,
      surface: SpColors.surface,
    ),
    scaffoldBackgroundColor: SpColors.ink,
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'Roboto'),
    cardTheme: CardThemeData(
      color: SpColors.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        textStyle: const TextStyle(
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

ThemeData buildPrivateTheme() {
  final base = ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: SpColors.privateAccent,
      brightness: Brightness.dark,
      surface: SpColors.privateSurface,
    ),
    scaffoldBackgroundColor: SpColors.privateInk,
  );
  return base.copyWith(
    appBarTheme: const AppBarTheme(
      backgroundColor: SpColors.privateInk,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      color: SpColors.privateSurface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: SpColors.privateLine),
      ),
    ),
    dividerColor: SpColors.privateLine,
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(50),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
  );
}
