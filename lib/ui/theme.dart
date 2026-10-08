import 'package:flutter/material.dart';

const accent = Color(0xFFD3F76B);
const surface = Color(0xFF161918);
const muted = Color(0xFF9DA39F);
ThemeData mumpaTheme() => ThemeData(
  useMaterial3: true,
  brightness: Brightness.dark,
  scaffoldBackgroundColor: const Color(0xFF0D100E),
  colorScheme: const ColorScheme.dark(
    primary: accent,
    onPrimary: Color(0xFF142006),
    surface: surface,
    onSurface: Color(0xFFF4F6F2),
    secondary: accent,
    error: Color(0xFFFF9292),
  ),
  fontFamily: 'Manrope',
  textTheme: const TextTheme(
    headlineLarge: TextStyle(
      fontSize: 40,
      fontWeight: FontWeight.w800,
      letterSpacing: -1.5,
    ),
    headlineMedium: TextStyle(
      fontSize: 30,
      fontWeight: FontWeight.w800,
      letterSpacing: -1,
    ),
    titleLarge: TextStyle(
      fontSize: 22,
      fontWeight: FontWeight.w800,
      letterSpacing: -.5,
    ),
    titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
    bodyMedium: TextStyle(fontSize: 13, height: 1.5),
    bodySmall: TextStyle(fontSize: 11, color: muted, height: 1.5),
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
      textStyle: const TextStyle(
        fontWeight: FontWeight.w800,
        fontFamily: 'Manrope',
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
    ),
  ),
  outlinedButtonTheme: OutlinedButtonThemeData(
    style: OutlinedButton.styleFrom(
      foregroundColor: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      side: const BorderSide(color: Color(0xFF414840)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
    ),
  ),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: const Color(0xFF202521),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide.none,
    ),
    hintStyle: const TextStyle(color: muted, fontSize: 13),
    contentPadding: const EdgeInsets.all(16),
  ),
  dividerTheme: const DividerThemeData(color: Color(0xFF2B302C), space: 1),
  dialogTheme: DialogThemeData(
    backgroundColor: surface,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
  ),
  navigationBarTheme: const NavigationBarThemeData(
    backgroundColor: Color(0xFF111512),
    indicatorColor: Color(0xFF303D23),
    height: 66,
  ),
  sliderTheme: const SliderThemeData(
    trackHeight: 3,
    thumbShape: RoundSliderThumbShape(enabledThumbRadius: 5),
    overlayShape: RoundSliderOverlayShape(overlayRadius: 12),
  ),
  tooltipTheme: const TooltipThemeData(
    waitDuration: Duration(milliseconds: 500),
  ),
);
